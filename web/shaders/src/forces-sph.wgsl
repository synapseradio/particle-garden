// =============================================================================
// SPH FLUID FORCES SHADER (Lagged-Density, Half-Neighbor with Newton's 3rd Law)
// =============================================================================
//
// WHY THIS EXISTS:
// The SPH fluid mode's force pass. It clones forces.wgsl's binding layout, its
// sorted-buffer neighbor traversal, and its fixed-point self-reset contract
// exactly (so the executor's bind-group recipe and the shared grid/scatter/
// integrate passes serve it unchanged), then replaces the particle-life force
// math with smoothed-particle-hydrodynamics: a Tait pressure force through the
// spiky gradient, a symmetric velocity-diffusion term (physical viscosity plus
// XSPH smoothing), and a fresh kernel density written back for the next frame.
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
// STABILITY CHOICES (see the report for the rationale and the tuning knobs):
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
//   - The stored density is scaled by SPH_DENSITY_GLOW_GAIN so it lands in the
//     same numeric range particle-life densities occupy, letting the shared
//     glow pass read both modes comparably. Pressure recovers the physical
//     (unscaled) density by dividing the lagged value back out.
//
// BINDING MANIFEST (identical to forces.wgsl — a clone of its 7-entry layout):
// +-------+---------------------------+------------------------+--------+
// | Bind  | Shader Type               | JS Buffer              | Access |
// +-------+---------------------------+------------------------+--------+
// |   0   | uniform SimParams         | simParams              | read   |
// |   1   | storage array<Particle>   | particlesSorted        | read   |
// |   2   | storage array<u32>        | sortedToOriginal       | read   |
// |   3   | storage array<u32>        | cellStartOffsets       | read   |
// |   4   | storage array<u32>        | cellParticleCounts     | read   |
// |   5   | storage atomic<i32>       | velocityDeltaFixed     | r/w    |
// |   6   | storage atomic<i32>       | densityDeltaFixed      | r/w    |
// +-------+---------------------------+------------------------+--------+
//
// THREAD MAPPING: One particle per thread (sorted index space)
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
@group(0) @binding(6) var<storage, read_write> densityDeltaFixed: array<atomic<i32>>;

const MIN_DISTANCE_SQ: f32 = {{TUNABLE_MIN_DISTANCE_SQ}};      // Prevents division-by-zero when particles overlap
const MOUSE_RANGE_SQ: f32 = {{TUNABLE_MOUSE_RANGE_SQ}};   // 300^2 - mouse influence radius squared

// SPH tuning constants held in the shader (the runtime tunables — rest density,
// stiffness, viscosity, gamma — arrive through SimParams; XSPH epsilon through
// the bundler placeholder below).
const SPH_XSPH_EPSILON: f32 = {{TUNABLE_SPH_XSPH_EPSILON}};  // Velocity-smoothing blend weight
const SPH_FORCE_SCALE: f32 = 3.0;          // Pressure acceleration gain (px/frame^2). Primary aesthetic knob.
const SPH_DENSITY_GLOW_GAIN: f32 = 2.5;    // Maps normalized density into the glow pass's density range.
const SPH_MAX_PRESSURE_ACCEL: f32 = 5000.0;  // Clamp guarding the fixed-point i32 delta from overflow.

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn computeForces(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let thisSortedIdx = globalId.x;

  if (thisSortedIdx >= params.particleCount) {
    return;
  }

  let thisParticle = particlesSorted[thisSortedIdx];
  let thisOriginalIdx = sortedToOriginal[thisSortedIdx];

  // Precompute constants (avoid recomputing in inner loops)
  let smoothingRadius = params.interactionRadius;
  let radiusSq = smoothingRadius * smoothingRadius;
  let halfWorldWidth = params.worldWidth * 0.5;
  let halfWorldHeight = params.worldHeight * 0.5;
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
  let invDensityGlowGain = 1.0 / SPH_DENSITY_GLOW_GAIN;

  let restDensity = params.sphRestDensity;
  let stiffness = params.sphStiffness;
  let viscosity = params.sphViscosity;
  let gamma = params.sphGamma;

  // Lagged, physical (unscaled) density of THIS particle, recovered from the
  // glow-scaled value carried in the density field. Floored at rest so pressure
  // is purely repulsive and the init state (density still 0) feels no force.
  let laggedDensityThis = thisParticle.density * invDensityGlowGain;
  let pressureDensityThis = max(laggedDensityThis, restDensity);
  let pressureThis = sphTaitPressure(pressureDensityThis, restDensity, stiffness, gamma);

  // Accumulators for THIS particle (held in registers, written once at the end).
  // densityAccum starts at 1.0: the normalized self-density W(0,h)/W(0,h).
  var deltaVelocityThisX = 0.0;
  var deltaVelocityThisY = 0.0;
  var densityAccum = 1.0;
  var externalForceThisX = 0.0;
  var externalForceThisY = 0.0;

  // ATOMIC INITIALIZATION: reset delta buffers for this particle (replaces a
  // clearBuffer to avoid racing the atomic writes; each thread owns its slot).
  atomicStore(&velocityDeltaFixed[thisOriginalIdx * 2u], 0);
  atomicStore(&velocityDeltaFixed[thisOriginalIdx * 2u + 1u], 0);
  atomicStore(&densityDeltaFixed[thisOriginalIdx], 0);

  // Find this particle's grid cell
  var cellX = i32(thisParticle.pos.x * invCellWidth);
  var cellY = i32(thisParticle.pos.y * invCellHeight);
  cellX = clamp(cellX, 0, gridWidth - 1);
  cellY = clamp(cellY, 0, gridHeight - 1);

  // Half-neighbor iteration: 5 cells instead of 9 (same pattern as forces.wgsl).
  for (var neighborIdx: i32 = 0; neighborIdx < 5; neighborIdx++) {
    var offsetX: i32;
    var offsetY: i32;

    if (neighborIdx == 0) { offsetX = 0; offsetY = 0; }         // Same cell
    else if (neighborIdx == 1) { offsetX = 1; offsetY = 0; }    // Right
    else if (neighborIdx == 2) { offsetX = -1; offsetY = 1; }   // Bottom-left
    else if (neighborIdx == 3) { offsetX = 0; offsetY = 1; }    // Bottom
    else { offsetX = 1; offsetY = 1; }                          // Bottom-right

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

      // Separation vector (accounting for toroidal wrapping), from this to other.
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
        let laggedDensityOther = otherParticle.density * invDensityGlowGain;
        let pressureDensityOther = max(laggedDensityOther, restDensity);
        let pressureOther = sphTaitPressure(pressureDensityOther, restDensity, stiffness, gamma);

        let pairPressure =
          pressureThis / (pressureDensityThis * pressureDensityThis) +
          pressureOther / (pressureDensityOther * pressureDensityOther);
        var pressureAccel = SPH_FORCE_SCALE * pairPressure * gradientWeight;
        pressureAccel = clamp(pressureAccel, -SPH_MAX_PRESSURE_ACCEL, SPH_MAX_PRESSURE_ACCEL);

        // Symmetric velocity diffusion: physical viscosity + XSPH smoothing.
        // Density-normalized (by the denser of the pair, symmetric in i/j) so a
        // single pair can never move the velocity by more than (viscosity +
        // epsilon) times the velocity gap — the XSPH stability bound.
        let velocitySmoothDenom = max(max(laggedDensityThis, laggedDensityOther), 1.0);
        let velocitySmoothCoeff = (viscosity + SPH_XSPH_EPSILON) * densityWeight / velocitySmoothDenom;
        let velocityDiffX = otherParticle.vel.x - thisParticle.vel.x;
        let velocityDiffY = otherParticle.vel.y - thisParticle.vel.y;

        // Per-pair velocity delta for THIS particle: pressure repels along -dir
        // (away from other, scaled by dt like every force), plus the velocity
        // blend (a direct velocity correction, not scaled by dt).
        let pairDeltaVelocityX = (-pressureAccel * directionX) * params.dt + velocitySmoothCoeff * velocityDiffX;
        let pairDeltaVelocityY = (-pressureAccel * directionY) * params.dt + velocitySmoothCoeff * velocityDiffY;

        deltaVelocityThisX += pairDeltaVelocityX;
        deltaVelocityThisY += pairDeltaVelocityY;
        densityAccum += densityWeight;

        // OTHER particle receives the exact negation (Newton's 3rd law — the
        // pair conserves momentum) plus its share of this pair's density.
        let otherDeltaVxFixed = i32(-pairDeltaVelocityX * FIXED_POINT_SCALE);
        let otherDeltaVyFixed = i32(-pairDeltaVelocityY * FIXED_POINT_SCALE);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u], otherDeltaVxFixed);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u + 1u], otherDeltaVyFixed);

        let otherDensityFixed = i32(densityWeight * SPH_DENSITY_GLOW_GAIN * FIXED_POINT_SCALE);
        atomicAdd(&densityDeltaFixed[otherOriginalIdx], otherDensityFixed);
      }
    }
  }

  // Mouse interaction (left attracts, right repels) — kept for parity with
  // particle-life so the fluid stays interactive.
  if (params.mouseLeftDown > 0.5 || params.mouseRightDown > 0.5) {
    var mouseOffsetX = params.mouseX - thisParticle.pos.x;
    var mouseOffsetY = params.mouseY - thisParticle.pos.y;

    if (mouseOffsetX > halfWorldWidth) { mouseOffsetX -= params.worldWidth; }
    else if (mouseOffsetX < -halfWorldWidth) { mouseOffsetX += params.worldWidth; }
    if (mouseOffsetY > halfWorldHeight) { mouseOffsetY -= params.worldHeight; }
    else if (mouseOffsetY < -halfWorldHeight) { mouseOffsetY += params.worldHeight; }

    let mouseDistSq = mouseOffsetX * mouseOffsetX + mouseOffsetY * mouseOffsetY;
    if (mouseDistSq > 0.0 && mouseDistSq < MOUSE_RANGE_SQ) {
      let mouseDist = sqrt(mouseDistSq);
      let mouseForce = 300.0 * (1.0 - mouseDist / 300.0) / mouseDist;

      var mouseSign = 0.0;
      if (params.mouseLeftDown > 0.5) { mouseSign += 1.0; }
      if (params.mouseRightDown > 0.5) { mouseSign -= 1.0; }

      externalForceThisX += mouseOffsetX * mouseForce * mouseSign;
      externalForceThisY += mouseOffsetY * mouseForce * mouseSign;
    }
  }

  // Blast effect (double-click repellent explosion)
  if (params.blastStrength > 0.01) {
    var blastOffsetX = thisParticle.pos.x - params.blastX;
    var blastOffsetY = thisParticle.pos.y - params.blastY;

    if (blastOffsetX > halfWorldWidth) { blastOffsetX -= params.worldWidth; }
    else if (blastOffsetX < -halfWorldWidth) { blastOffsetX += params.worldWidth; }
    if (blastOffsetY > halfWorldHeight) { blastOffsetY -= params.worldHeight; }
    else if (blastOffsetY < -halfWorldHeight) { blastOffsetY += params.worldHeight; }

    let blastDistSq = blastOffsetX * blastOffsetX + blastOffsetY * blastOffsetY;
    let blastRangeSq = {{TUNABLE_BLAST_RANGE_SQ}};  // 200^2 - blast influence radius squared
    if (blastDistSq > 0.0 && blastDistSq < blastRangeSq) {
      let blastDist = sqrt(blastDistSq);
      let blastForce = params.blastStrength * 3000.0 * (1.0 - blastDist / 200.0) / max(blastDist, 10.0);
      externalForceThisX += blastOffsetX * blastForce;
      externalForceThisY += blastOffsetY * blastForce;
    }
  }

  // Fold the external (mouse/blast) accelerations in as a dt-scaled velocity
  // delta, then commit THIS particle's accumulated velocity and fresh density.
  deltaVelocityThisX += externalForceThisX * params.dt;
  deltaVelocityThisY += externalForceThisY * params.dt;

  let thisDeltaVxFixed = i32(deltaVelocityThisX * FIXED_POINT_SCALE);
  let thisDeltaVyFixed = i32(deltaVelocityThisY * FIXED_POINT_SCALE);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u], thisDeltaVxFixed);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u + 1u], thisDeltaVyFixed);

  let thisDensityFixed = i32(densityAccum * SPH_DENSITY_GLOW_GAIN * FIXED_POINT_SCALE);
  atomicAdd(&densityDeltaFixed[thisOriginalIdx], thisDensityFixed);
}
