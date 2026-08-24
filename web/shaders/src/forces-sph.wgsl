// =============================================================================
// SPH FLUID FORCES SHADER (Lagged-Density, Half-Neighbor with Newton's 3rd Law)
// =============================================================================
//
// WHY THIS EXISTS:
// The fluid coupling's force pass, dispatched wherever fluidStrength is not
// zero. It clones forces.wgsl's binding layout and its sorted-buffer neighbor
// traversal (so the executor's bind-group recipe and the shared grid/scatter/
// integrate passes serve it unchanged), and carries smoothed-particle
// hydrodynamics instead of the species force: a Tait pressure force through the
// spiky gradient, a symmetric velocity-diffusion term (physical viscosity plus
// XSPH smoothing), and a fresh kernel density written back for the next frame.
// It runs ALONGSIDE forces.wgsl rather than in place of it — both accumulate
// into velocityDelta, and integrate reads their sum.
//
// SINGLE-PASS, LAGGED DENSITY:
// True SPH needs two passes (compute density, then pressure). This pipeline has
// one force pass, so pressure reads the LAGGED density carried in each
// particle's density field (bin-scatter copies the whole struct, so the sorted
// buffer holds last frame's smoothed density), while this pass computes the
// FRESH density for next frame. Lagging one frame — combined with integrate's
// 0.7 temporal smoothing of the density field — is what damps the pressure
// feedback loop into stability at gamma = 7.
//
// STABILITY CHOICES:
//   - Density used for pressure is floored at rest density, so pressure is
//     purely repulsive (P >= 0). This dodges the tensile instability of
//     negative pressure and the init blowup when the lagged density is still 0.
//   - Every pairwise term is equal-and-opposite, so the half-neighbor atomic
//     scatter conserves momentum exactly (same pattern as forces.wgsl).
//   - The velocity-diffusion coefficient is density-normalized and the pressure
//     acceleration is clamped, bounding the per-frame fixed-point delta well
//     inside the i32 range. The integrate pass's velocity soft-cap is the final
//     backstop against NaN.
//
// NORMALIZATION:
//   - Density is normalized by the self-weight W(0, h): an isolated particle
//     reads exactly rest density 1.0, so the numbers stay O(1) at any radius.
//   - The spiky gradient is normalized by its value at r=0, so the pressure
//     magnitude is radius-independent and SPH_FORCE_SCALE reads in px/frame^2.
//   - The stored density is the physical one Tait consumes. It is private to
//     this pass, so nothing outside needs it in another range.
//
// THREAD MAPPING: One particle per thread (sorted index space)
//
// THIS PASS IS COUPLING-OWNED, which constrains it three ways:
//
// - It runs only while `fluidStrength` is nonzero, and that strength multiplies
//   its ENTIRE velocity contribution at one site. A term that escapes the
//   multiplier makes the frame's zero-strength skip observable.
// - It writes nothing the world reads. Kernel density goes to its own buffer;
//   the `density` the renderer reads belongs to forces.wgsl.
// - No mouse, no blast. forces.wgsl runs in every world and applies both once.
// =============================================================================

//! import particle
//! import fixed_point
//! import sim_params
//! import sph_kernels

@group(0) @binding(0) var<uniform> params: SimParams;
@group(0) @binding(1) var<storage, read> particlesSorted: array<Particle>;
@group(0) @binding(2) var<storage, read> sortedToOriginal: array<u32>;
@group(0) @binding(3) var<storage, read> cellStartOffsets: array<u32>;
@group(0) @binding(4) var<storage, read> cellParticleCounts: array<u32>;
@group(0) @binding(5) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;
@group(0) @binding(6) var<storage, read_write> sphDensityDeltaFixed: array<atomic<i32>>;

const MIN_DISTANCE_SQ: f32 = {{TUNABLE_MIN_DISTANCE_SQ}};      // Prevents division-by-zero when particles overlap

// SPH tuning constants held in the shader (the runtime tunables — rest density,
// stiffness, viscosity, gamma — arrive through SimParams; XSPH epsilon through
// the bundler placeholder below).
const SPH_XSPH_EPSILON: f32 = {{TUNABLE_SPH_XSPH_EPSILON}};  // Velocity-smoothing blend weight
// Pressure acceleration gain (px/frame^2), the primary aesthetic knob, and the
// per-pair clamp guarding the fixed-point i32 delta from overflow. Both arrive
// from src/sph_core.nim: the stable stiffness ceiling served to the panel is
// fitted against this gain, so a number changed here alone would leave that
// ceiling describing a fluid other than the one this shader runs.
const SPH_FORCE_SCALE: f32 = {{TUNABLE_SPH_FORCE_SCALE}};
const SPH_MAX_PRESSURE_ACCEL: f32 = {{TUNABLE_SPH_MAX_PRESSURE_ACCEL}};
// Ceiling on the density fed to Tait, in multiples of rest density. Tait raises
// (density/rest) to the gamma power — 7 by default — so an unbounded input lets
// a compressed cluster feed its own pressure spike: the spike flings particles
// into their neighbours, which raises those densities, which spikes again. The
// per-pair accel clamp bounds one interaction but not the number of them, so
// the ceiling belongs on the input. Settled fluid sits near 1.0 and ordinary
// compression near 1.5, so this leaves normal behaviour untouched.
const SPH_MAX_DENSITY_RATIO: f32 = {{TUNABLE_SPH_MAX_DENSITY_RATIO}};

// Kernel density encodes at SPH_DENSITY_FIXED_POINT_SCALE, not
// FIXED_POINT_SCALE; the two-scale rationale and the one-encoder-one-decoder
// invariant live in fixed_point.wgsl.

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn computeForces(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let thisSortedIdx = globalId.x;

  if (thisSortedIdx >= params.particleCount) {
    return;
  }

  let thisParticle = particlesSorted[thisSortedIdx];
  let thisOriginalIdx = sortedToOriginal[thisSortedIdx];

  // THE SMOOTHING RADIUS IS A FRACTION OF THE INTERACTION RADIUS, never a
  // length of its own. The fraction's range tops out at 1, so this product can
  // never exceed the interaction radius — which matters because the neighbour
  // sweep below visits only the cell block around a particle and the cells are
  // sized to the interaction radius (src/grid.nim), so a larger smoothing
  // radius would silently drop the neighbours that fall outside the block. The
  // constraint is unrepresentable rather than clamped. Everything
  // downstream already takes the radius as a value: both kernels recompute
  // their normalization from it (src/sph_core.nim).
  let smoothingRadius = params.interactionRadius * params.sphRadiusFraction;
  let radiusSq = smoothingRadius * smoothingRadius;
  let invCellWidth = f32(params.gridCellsX) / params.worldWidth;
  let invCellHeight = f32(params.gridCellsY) / params.worldHeight;
  let totalCells = i32(params.gridCellsX * params.gridCellsY);
  let gridWidth = i32(params.gridCellsX);
  let gridHeight = i32(params.gridCellsY);

  // Kernel self-weights: normalizers that make density O(1) and the pressure
  // magnitude radius-independent. Guarded against a zero radius.
  let selfPoly6 = sphPoly6Weight2d(0.0, smoothingRadius);
  let selfSpikyGradient = sphSpikyGradientMagnitude2d(0.0, smoothingRadius);
  let invSelfPoly6 = select(0.0, 1.0 / selfPoly6, selfPoly6 > 0.0);
  let invSelfSpikyGradient = select(0.0, 1.0 / selfSpikyGradient, selfSpikyGradient > 0.0);

  let restDensity = params.sphRestDensity;
  let stiffness = params.sphStiffness;
  let viscosity = params.sphViscosity;
  let gamma = params.sphGamma;
  let fluidStrength = params.fluidStrength;

  // Lagged density of THIS particle, from the fluid's own field. Stored as the
  // physical density the equation of state wants, so there is no glow gain to
  // divide back out. Floored at rest so pressure is purely repulsive and the
  // init state (density still 0) feels no force, ceilinged at
  // maxPressureDensity — see that constant's comment.
  let maxPressureDensity = restDensity * SPH_MAX_DENSITY_RATIO;
  let laggedDensityThis = thisParticle.sphDensity;
  let pressureDensityThis = clamp(laggedDensityThis, restDensity, maxPressureDensity);
  let pressureThis = sphTaitPressure(pressureDensityThis, restDensity, stiffness, gamma);

  // Accumulators for THIS particle (held in registers, written once at the end).
  // densityAccum starts at 1.0: the normalized self-density W(0,h)/W(0,h).
  var deltaVelocityThisX = 0.0;
  var deltaVelocityThisY = 0.0;
  var densityAccum = 1.0;

  // THIS PASS ACCUMULATES ONLY — the frame owns the delta resets. See the same
  // note in forces.wgsl: with both force models coupled, whichever ran second
  // would otherwise erase the first.

  var cellX = i32(thisParticle.pos.x * invCellWidth);
  var cellY = i32(thisParticle.pos.y * invCellHeight);
  cellX = clamp(cellX, 0, gridWidth - 1);
  cellY = clamp(cellY, 0, gridHeight - 1);

  // Half-neighbor iteration: 5 cells instead of 9 (same pattern as forces.wgsl).
  for (var neighborIdx: i32 = 0; neighborIdx < 5; neighborIdx++) {
    var offsetX: i32;
    var offsetY: i32;

    if (neighborIdx == 0) { offsetX = 0; offsetY = 0; }
    else if (neighborIdx == 1) { offsetX = 1; offsetY = 0; }
    else if (neighborIdx == 2) { offsetX = -1; offsetY = 1; }
    else if (neighborIdx == 3) { offsetX = 0; offsetY = 1; }
    else { offsetX = 1; offsetY = 1; }

    var neighborCellX = cellX + offsetX;
    var neighborCellY = cellY + offsetY;
    var toroidalOffsetX = 0.0;
    var toroidalOffsetY = 0.0;

    // Toroidal wrapping: the world wraps at the edges, so the neighbor cell
    // index wraps and the neighbor position is shifted by one world span for
    // the distance calculation.
    if (neighborCellX < 0) {
      neighborCellX += gridWidth;
      toroidalOffsetX = -params.worldWidth;
    } else if (neighborCellX >= gridWidth) {
      neighborCellX -= gridWidth;
      toroidalOffsetX = params.worldWidth;
    }

    if (neighborCellY < 0) {
      neighborCellY += gridHeight;
      toroidalOffsetY = -params.worldHeight;
    } else if (neighborCellY >= gridHeight) {
      neighborCellY -= gridHeight;
      toroidalOffsetY = params.worldHeight;
    }

    let neighborCellIndex = neighborCellY * gridWidth + neighborCellX;
    if (neighborCellIndex < 0 || neighborCellIndex >= totalCells) {
      continue;
    }

    let particlesInCell = i32(cellParticleCounts[neighborCellIndex]);
    if (particlesInCell <= 0) {
      continue;
    }

    let cellStart = i32(cellStartOffsets[neighborCellIndex]);
    if (cellStart < 0 || cellStart + particlesInCell > i32(params.particleCount)) {
      continue;
    }

    let isSameCell = (neighborIdx == 0);
    let cellEnd = cellStart + particlesInCell;

    // Iterate through particles in this cell (sequential memory access — the
    // scatter pass sorted them by cell).
    for (var otherSortedIdx: i32 = cellStart; otherSortedIdx < cellEnd; otherSortedIdx++) {
      // Same cell: only pairs where other > this (half-neighbor optimization).
      if (isSameCell && u32(otherSortedIdx) <= thisSortedIdx) {
        continue;
      }

      if (u32(otherSortedIdx) == thisSortedIdx) {
        continue;
      }

      let otherParticle = particlesSorted[otherSortedIdx];
      let otherOriginalIdx = sortedToOriginal[otherSortedIdx];

      let separationX = (otherParticle.pos.x + toroidalOffsetX) - thisParticle.pos.x;
      let separationY = (otherParticle.pos.y + toroidalOffsetY) - thisParticle.pos.y;
      let distanceSq = separationX * separationX + separationY * separationY;

      if (distanceSq > 0.0 && distanceSq < radiusSq) {
        let clampedDistSq = max(distanceSq, MIN_DISTANCE_SQ);
        let distance = sqrt(clampedDistSq);
        let invDistance = 1.0 / distance;
        let directionX = separationX * invDistance;  // Unit vector this -> other
        let directionY = separationY * invDistance;

        // Normalized kernels: both in [0, 1], radius-independent.
        let densityWeight = sphPoly6Weight2d(distance, smoothingRadius) * invSelfPoly6;
        let gradientWeight = sphSpikyGradientMagnitude2d(distance, smoothingRadius) * invSelfSpikyGradient;

        // Symmetrized Tait pressure force. Neighbor's lagged physical density,
        // floored at rest so its pressure is also purely repulsive.
        let laggedDensityOther = otherParticle.sphDensity;
        let pressureDensityOther = clamp(laggedDensityOther, restDensity, maxPressureDensity);
        let pressureOther = sphTaitPressure(pressureDensityOther, restDensity, stiffness, gamma);

        let pairPressure =
          pressureThis / (pressureDensityThis * pressureDensityThis) +
          pressureOther / (pressureDensityOther * pressureDensityOther);
        var pressureAccel = SPH_FORCE_SCALE * pairPressure * gradientWeight;
        pressureAccel = clamp(pressureAccel, -SPH_MAX_PRESSURE_ACCEL, SPH_MAX_PRESSURE_ACCEL);

        // Symmetric velocity diffusion: physical viscosity + XSPH smoothing
        // (Monaghan 1989: https://www.sciencedirect.com/science/article/pii/0021999189900326).
        // Density-normalized (by the denser of the pair, symmetric in i/j) so a
        // single pair can never move the velocity by more than (viscosity +
        // epsilon) times the velocity gap — the XSPH stability bound.
        let velocitySmoothDenom = max(max(laggedDensityThis, laggedDensityOther), 1.0);
        let velocitySmoothCoeff = (viscosity + SPH_XSPH_EPSILON) * densityWeight / velocitySmoothDenom;
        let velocityDiffX = otherParticle.vel.x - thisParticle.vel.x;
        let velocityDiffY = otherParticle.vel.y - thisParticle.vel.y;

        // Per-pair velocity delta for THIS particle: pressure repels along -dir
        // (away from other, scaled by dt like every force), plus the velocity
        // blend. The blend carries the frame as a multiple of the frame the
        // stability bound was measured at, so both halves of what fluidStrength
        // multiplies answer to Time Scale the same way; at the reference frame
        // the factor is 1 and the blend is what it always was.
        // The one site fluidStrength multiplies. Both terms are summed here, so
        // everything this pass does to a velocity passes through it.
        let frameFactor = params.dt * {{TUNABLE_INV_FRAME_DT_REFERENCE}};
        let pairDeltaVelocityX = fluidStrength *
          ((-pressureAccel * directionX) * params.dt + velocitySmoothCoeff * velocityDiffX * frameFactor);
        let pairDeltaVelocityY = fluidStrength *
          ((-pressureAccel * directionY) * params.dt + velocitySmoothCoeff * velocityDiffY * frameFactor);

        deltaVelocityThisX += pairDeltaVelocityX;
        deltaVelocityThisY += pairDeltaVelocityY;
        densityAccum += densityWeight;

        // OTHER particle receives the exact negation (Newton's 3rd law — the
        // pair conserves momentum) plus its share of this pair's density.
        let otherDeltaVxFixed = i32(-pairDeltaVelocityX * FIXED_POINT_SCALE);
        let otherDeltaVyFixed = i32(-pairDeltaVelocityY * FIXED_POINT_SCALE);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u], otherDeltaVxFixed);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u + 1u], otherDeltaVyFixed);

        // Kernel density carries NO fluidStrength: it feeds this pass's own
        // equation of state, and scaling it would change what kind of fluid
        // this is as the strength moves. Nothing outside reads it, so skipping
        // the pass at strength zero loses nothing.
        let otherDensityFixed =
          i32(densityWeight * SPH_DENSITY_FIXED_POINT_SCALE);
        atomicAdd(&sphDensityDeltaFixed[otherOriginalIdx], otherDensityFixed);
      }
    }
  }

  let thisDeltaVxFixed = i32(deltaVelocityThisX * FIXED_POINT_SCALE);
  let thisDeltaVyFixed = i32(deltaVelocityThisY * FIXED_POINT_SCALE);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u], thisDeltaVxFixed);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u + 1u], thisDeltaVyFixed);

  let thisDensityFixed =
    i32(densityAccum * SPH_DENSITY_FIXED_POINT_SCALE);
  atomicAdd(&sphDensityDeltaFixed[thisOriginalIdx], thisDensityFixed);
}
