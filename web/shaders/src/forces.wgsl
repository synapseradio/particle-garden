// =============================================================================
// PARTICLE FORCES + DENSITY SHADER (Half-Neighbor with Newton's 3rd Law)
// =============================================================================
//
// WHY THIS EXISTS (Cache Optimization):
// This shader reads particle data from SORTED AoS buffer (particlesSorted[])
// instead of using indirect indexing. The physical scatter pass copies entire
// particle structs into spatially-sorted order, enabling SEQUENTIAL memory
// access patterns here.
//
// AoS CACHE BEHAVIOR:
// - Each Particle is 32 bytes (2 particles per 64-byte cache line)
// - Reading particlesSorted[j] loads pos, vel, species, density in one fetch
// - No separate buffer reads needed - all particle data is colocated
//
// ALGORITHM:
// Computes inter-particle forces AND local density using half-neighbor iteration.
// Each pair (i,j) is computed ONCE, with force applied to both particles via atomics.
//
// HALF-NEIGHBOR PATTERN (the key optimization):
// Think of it like shaking hands at a party: each person only needs to shake
// hands with people they haven't met yet. If Alice shakes Bob's hand, Bob doesn't
// need to shake Alice's hand separately - that would duplicate the interaction.
//
// For particle i, we ONLY check:
// +---+---+---+
// |   |   |   |  Top row: SKIP (those particles will check us when it's their turn)
// +---+---+---+
// |   | i | Y |  Same cell: only j>i (avoid i checking i). Right: all particles.
// +---+---+---+
// | Y | Y | Y |  Bottom row: all three cells (they haven't checked us yet).
// +---+---+---+
//
// This gives us 5 cells instead of 9, cutting work nearly in half.
// Each pair (i,j) is computed EXACTLY ONCE, with forces applied to both via atomics.
//
// BINDING MANIFEST:
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
// TOTAL: 6 storage buffers (under 8-buffer limit)
//
// THREAD MAPPING: One particle per thread (sorted index space)
// =============================================================================

//! import particle
//! import fixed_point
//! import sim_params

// SimParams is generated from src/gpu_types.nim (SimParamsLayout) and provided
// by the sim_params module imported above.
@group(0) @binding(0) var<uniform> params: SimParams;

// SORTED buffer: particles reordered by spatial grid position for sequential memory access
@group(0) @binding(1) var<storage, read> particlesSorted: array<Particle>;

// Index mapping: sortedIdx → originalIdx (needed to write results back to original buffers)
@group(0) @binding(2) var<storage, read> sortedToOriginal: array<u32>;
@group(0) @binding(3) var<storage, read> cellStartOffsets: array<u32>;
@group(0) @binding(4) var<storage, read> cellParticleCounts: array<u32>;

// WHY FIXED-POINT? GPUs don't support atomic operations on floats (yet).
// We can't just write "atomicAdd(&someFloat, 0.5)" - hardware doesn't support it.
// Solution: scale floats by 65536, convert to integers, use atomic integer ops,
// then scale back down when reading. Like counting money in cents instead of dollars.
@group(0) @binding(5) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;
@group(0) @binding(6) var<storage, read_write> densityDeltaFixed: array<atomic<i32>>;

const MIN_DISTANCE_SQ: f32 = {{TUNABLE_MIN_DISTANCE_SQ}};  // Prevents division-by-zero when particles overlap
const MOUSE_RANGE_SQ: f32 = {{TUNABLE_MOUSE_RANGE_SQ}};  // 300² - mouse influence radius squared

// =============================================================================
// EXPONENTIAL FORCE MODEL
// =============================================================================
// Alternative to polynomial model using exponential decay functions.
// Produces smoother force curves with longer-range interactions.
//
// Force = -exp(-alpha * r) + attraction * exp(-beta * r) * 2.0
//
// - Repulsion term: exp(-alpha * r) - strong at r=0, decays with alpha
// - Attraction term: exp(-beta * r) - broader with smaller beta
// - The 2.0 factor balances repulsion/attraction magnitudes
//
// Typical values: alpha=6.0 (steep repulsion), beta=3.0 (broad attraction)
fn exponentialForce(r: f32, attraction: f32, alpha: f32, beta: f32) -> f32 {
  let repulsion = exp(-alpha * r);
  let attract = exp(-beta * r);
  return -repulsion + attraction * attract * 2.0;
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn computeForces(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let thisSortedIdx = globalId.x;

  if (thisSortedIdx >= params.particleCount) {
    return;
  }

  let thisParticle = particlesSorted[thisSortedIdx];
  let thisOriginalIdx = sortedToOriginal[thisSortedIdx];

  // Precompute constants (avoid recomputing in inner loops)
  let radiusSq = params.interactionRadius * params.interactionRadius;
  let invRadius = 1.0 / params.interactionRadius;
  let halfWorldWidth = params.worldWidth * 0.5;
  let halfWorldHeight = params.worldHeight * 0.5;
  let invCellWidth = f32(params.gridCellsX) / params.worldWidth;
  let invCellHeight = f32(params.gridCellsY) / params.worldHeight;
  let totalCells = i32(params.gridCellsX * params.gridCellsY);
  let gridWidth = i32(params.gridCellsX);
  let gridHeight = i32(params.gridCellsY);

  // Accumulators for THIS particle (held in GPU registers, not global memory)
  var forceOnThisX = 0.0;
  var forceOnThisY = 0.0;
  var densityAccum = 0.0;

  // THIS PASS ACCUMULATES ONLY. The frame clears velocityDelta and densityDelta
  // before anything writes them (sim_registry.buildFrame opens with both clears),
  // so a self-reset here would erase whatever a co-running contributor — the
  // field force, or forces-sph — had already added.

  // Find this particle's grid cell
  var cellX = i32(thisParticle.pos.x * invCellWidth);
  var cellY = i32(thisParticle.pos.y * invCellHeight);
  cellX = clamp(cellX, 0, gridWidth - 1);
  cellY = clamp(cellY, 0, gridHeight - 1);

  // Half-neighbor iteration: 5 cells instead of 9
  // Why these specific 5? Imagine scanning left-to-right, top-to-bottom.
  // Cells 0,1,2 (top row) have already been processed by earlier threads.
  // We only need: own cell (0,0), right (1,0), and bottom-left to bottom-right (-1,1), (0,1), (1,1).
  for (var neighborIdx: i32 = 0; neighborIdx < 5; neighborIdx++) {
    var offsetX: i32;
    var offsetY: i32;

    // Map index to cell offset (unrolled for GPU performance)
    if (neighborIdx == 0) { offsetX = 0; offsetY = 0; }   // Same cell
    else if (neighborIdx == 1) { offsetX = 1; offsetY = 0; }   // Right
    else if (neighborIdx == 2) { offsetX = -1; offsetY = 1; }  // Bottom-left
    else if (neighborIdx == 3) { offsetX = 0; offsetY = 1; }   // Bottom
    else { offsetX = 1; offsetY = 1; }                          // Bottom-right

    var neighborCellX = cellX + offsetX;
    var neighborCellY = cellY + offsetY;
    var toroidalOffsetX = 0.0;
    var toroidalOffsetY = 0.0;

    // TOROIDAL WRAPPING (Pac-Man physics):
    // World wraps at edges - particles exiting right re-enter from left.
    // The GRID cells wrap (for neighbor search), but we also need to adjust
    // the POSITION we use for distance calculations.
    //
    // Example: Particle at x=5 near left edge, neighbor cell wraps to right edge.
    // Grid cell wraps: -1 → gridWidth-1 (correct cell index)
    // Position offset: subtract worldWidth so distance calc treats neighbor
    // as if it's "just to the left" instead of "way over on the right."

    // Toroidal X wrap
    if (neighborCellX < 0) {
      neighborCellX += gridWidth;          // Wrap cell index
      toroidalOffsetX = -params.worldWidth; // Adjust position for distance calc
    } else if (neighborCellX >= gridWidth) {
      neighborCellX -= gridWidth;
      toroidalOffsetX = params.worldWidth;
    }

    // Toroidal Y wrap
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

    // Iterate through particles in this cell
    // Because particles are SORTED by spatial position, this is sequential memory access.
    // The GPU loads cache lines sequentially - very efficient!
    for (var otherSortedIdx: i32 = cellStart; otherSortedIdx < cellEnd; otherSortedIdx++) {
      // For same cell, only process pairs where other > this (half-neighbor optimization)
      if (isSameCell && u32(otherSortedIdx) <= thisSortedIdx) {
        continue;
      }

      if (u32(otherSortedIdx) == thisSortedIdx) {
        continue;
      }

      // Load neighbor particle (AoS: all fields arrive in one memory fetch)
      let otherParticle = particlesSorted[otherSortedIdx];
      let otherOriginalIdx = sortedToOriginal[otherSortedIdx];

      // Compute separation vector (accounting for toroidal wrapping)
      let separationX = (otherParticle.pos.x + toroidalOffsetX) - thisParticle.pos.x;
      let separationY = (otherParticle.pos.y + toroidalOffsetY) - thisParticle.pos.y;
      let distanceSq = separationX * separationX + separationY * separationY;

      if (distanceSq > 0.0 && distanceSq < radiusSq) {
        let clampedDistSq = max(distanceSq, MIN_DISTANCE_SQ);
        let distance = sqrt(clampedDistSq);
        let invDistance = 1.0 / distance;
        let normalizedDist = distance * invRadius;  // 0.0 = touching, 1.0 = at radius edge

        // Get attraction coefficients for both directions
        // Matrix is asymmetric: Red may attract Blue, while Blue repels Red
        let matrixIdxThisToOther = thisParticle.species * MAX_SPECIES + otherParticle.species;
        let matrixIdxOtherToThis = otherParticle.species * MAX_SPECIES + thisParticle.species;
        let attractionThisToOther = params.attractionMatrix[matrixIdxThisToOther / 4u][matrixIdxThisToOther % 4u];
        let attractionOtherToThis = params.attractionMatrix[matrixIdxOtherToThis / 4u][matrixIdxOtherToThis % 4u];

        // FORCE CALCULATION (the physics):
        // Two models available, selected by params.forceModel:
        //
        // MODEL 0: POLYNOMIAL (smooth C¹-continuous curves)
        //   - Repulsion zone: smooth cubic in [0, repulsionEnd]
        //   - Attraction zone: smooth bump in [repulsionEnd, 1] peaking at attractionPeak
        //   - Zone boundaries configurable via params
        //
        // MODEL 1: EXPONENTIAL (decay functions)
        //   - Uses exp(-alpha*r) for repulsion, exp(-beta*r) for attraction
        //   - Smoother decay across full range, no hard zone boundaries
        //   - Alpha/beta control steepness of repulsion/attraction falloff
        //
        // Finally, divide by distance (invDistance) to convert force magnitude
        // into proper acceleration (like gravity: F ∝ 1/r² becomes a ∝ 1/r).

        var forceMagnitudeOnThis: f32;
        var forceMagnitudeOnOther: f32;

        if (params.forceModel == 1u) {
          // EXPONENTIAL MODEL
          forceMagnitudeOnThis = exponentialForce(normalizedDist, attractionThisToOther, params.expAlpha, params.expBeta);
          forceMagnitudeOnOther = exponentialForce(normalizedDist, attractionOtherToThis, params.expAlpha, params.expBeta);
        } else {
          // POLYNOMIAL MODEL (default)
          let repEnd = params.repulsionEnd;
          let attPeak = params.attractionPeak;

          // Force on THIS particle
          if (normalizedDist < repEnd) {
            // Repulsion zone: smooth cubic normalized to [0, repEnd]
            let t = normalizedDist / repEnd;  // Normalize to [0, 1]
            let t2 = t * t;
            forceMagnitudeOnThis = -1.0 + 3.0 * t2 - 2.0 * t2 * t;  // Hermite: f(0)=-1, f(1)=0, f'(1)=0
          } else {
            // Attraction zone: smooth bump in [repEnd, 1] peaking at attPeak
            let zoneWidth = 1.0 - repEnd;
            let peakPos = (attPeak - repEnd) / zoneWidth;  // Normalized peak position in [0, 1]
            let t = (normalizedDist - repEnd) / zoneWidth;  // Normalize to [0, 1]
            // Bump function: peaks at peakPos, zero at 0 and 1
            let leftDist = t / peakPos;
            let rightDist = (1.0 - t) / (1.0 - peakPos);
            let bump = min(leftDist, 1.0) * min(leftDist, 1.0) * min(rightDist, 1.0) * min(rightDist, 1.0);
            forceMagnitudeOnThis = attractionThisToOther * bump * 4.0;  // Scale to match old peak magnitude
          }

          // Force on OTHER particle (Newton's 3rd law: uses OTHER's attraction coefficient)
          if (normalizedDist < repEnd) {
            let t = normalizedDist / repEnd;
            let t2 = t * t;
            forceMagnitudeOnOther = -1.0 + 3.0 * t2 - 2.0 * t2 * t;
          } else {
            let zoneWidth = 1.0 - repEnd;
            let peakPos = (attPeak - repEnd) / zoneWidth;
            let t = (normalizedDist - repEnd) / zoneWidth;
            let leftDist = t / peakPos;
            let rightDist = (1.0 - t) / (1.0 - peakPos);
            let bump = min(leftDist, 1.0) * min(leftDist, 1.0) * min(rightDist, 1.0) * min(rightDist, 1.0);
            forceMagnitudeOnOther = attractionOtherToThis * bump * 4.0;
          }
        }

        forceMagnitudeOnThis *= params.forceMultiplier * invDistance;
        forceMagnitudeOnOther *= params.forceMultiplier * invDistance;

        // Accumulate force on THIS in register (no atomic needed - we own this thread)
        forceOnThisX += separationX * forceMagnitudeOnThis;
        forceOnThisY += separationY * forceMagnitudeOnThis;

        // Apply force to OTHER particle via global atomic
        // WHY ATOMICS? Multiple threads might find the same OTHER particle.
        // Example: Particle 7 is a neighbor of particles 3, 5, and 12.
        // Threads for 3, 5, and 12 all try to update particle 7 simultaneously.
        // Without atomics, updates would race and overwrite each other (data loss).
        // atomicAdd ensures all three contributions are correctly summed.
        //
        // WHY FIXED-POINT? GPU atomics only work on integers, not floats.
        // Scale by 65536, convert to int, atomic add, then scale back later.
        let forceOnOtherX = -separationX * forceMagnitudeOnOther;  // Newton's 3rd: opposite direction
        let forceOnOtherY = -separationY * forceMagnitudeOnOther;
        let deltaVxOtherFixed = i32(forceOnOtherX * params.dt * FIXED_POINT_SCALE);
        let deltaVyOtherFixed = i32(forceOnOtherY * params.dt * FIXED_POINT_SCALE);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u], deltaVxOtherFixed);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u + 1u], deltaVyOtherFixed);

        // SYMMETRIC DENSITY ACCUMULATION:
        // Density measures "crowding" - how many same-species neighbors are nearby.
        // Used for visual effects (particle size based on population pressure).
        //
        // CRITICAL: Half-neighbor iteration means each pair is processed ONCE.
        // Both particles must receive the density contribution from this pair.
        // Same atomic pattern as velocity - write to OTHER immediately,
        // accumulate THIS in register and write once at the end.
        //
        // Weighted by proximity: (1.0 - normalizedDist) means touching=1.0, at edge=0.0
        if (otherParticle.species == thisParticle.species) {
          let densityContribution = 1.0 - normalizedDist;
          densityAccum += densityContribution;  // THIS particle (register)

          // OTHER particle gets same contribution via atomic (like velocity)
          let densityFixed = i32(densityContribution * FIXED_POINT_SCALE);
          atomicAdd(&densityDeltaFixed[otherOriginalIdx], densityFixed);
        }
      }
    }
  }

  // Mouse interaction (left attracts, right repels)
  if (params.mouseLeftDown > 0.5 || params.mouseRightDown > 0.5) {
    var mouseOffsetX = params.mouseX - thisParticle.pos.x;
    var mouseOffsetY = params.mouseY - thisParticle.pos.y;

    // Toroidal wrapping for mouse distance (use shortest path around edges)
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

      forceOnThisX += mouseOffsetX * mouseForce * mouseSign;
      forceOnThisY += mouseOffsetY * mouseForce * mouseSign;
    }
  }

  // Blast effect (double-click repellent explosion)
  if (params.blastStrength > 0.01) {
    var blastOffsetX = thisParticle.pos.x - params.blastX;
    var blastOffsetY = thisParticle.pos.y - params.blastY;

    // Toroidal wrapping for blast distance
    if (blastOffsetX > halfWorldWidth) { blastOffsetX -= params.worldWidth; }
    else if (blastOffsetX < -halfWorldWidth) { blastOffsetX += params.worldWidth; }
    if (blastOffsetY > halfWorldHeight) { blastOffsetY -= params.worldHeight; }
    else if (blastOffsetY < -halfWorldHeight) { blastOffsetY += params.worldHeight; }

    let blastDistSq = blastOffsetX * blastOffsetX + blastOffsetY * blastOffsetY;
    let blastRangeSq = 40000.0;  // 200² - blast influence radius squared
    if (blastDistSq > 0.0 && blastDistSq < blastRangeSq) {
      let blastDist = sqrt(blastDistSq);
      // Powerful repulsion that breaks any formation
      let blastForce = params.blastStrength * 3000.0 * (1.0 - blastDist / 200.0) / max(blastDist, 10.0);
      forceOnThisX += blastOffsetX * blastForce;
      forceOnThisY += blastOffsetY * blastForce;
    }
  }

  // Apply accumulated force to THIS particle via single atomic
  // Why atomic for THIS? Other threads might have added forces to us while we
  // were processing (half-neighbor symmetry works both ways).
  let deltaVxThisFixed = i32(forceOnThisX * params.dt * FIXED_POINT_SCALE);
  let deltaVyThisFixed = i32(forceOnThisY * params.dt * FIXED_POINT_SCALE);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u], deltaVxThisFixed);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u + 1u], deltaVyThisFixed);

  // Apply accumulated density for THIS particle via atomic
  // Same pattern as velocity: accumulated in register, written once at end.
  // Temporal smoothing happens in integrate pass (needs previous density value).
  let densityThisFixed = i32(densityAccum * FIXED_POINT_SCALE);
  atomicAdd(&densityDeltaFixed[thisOriginalIdx], densityThisFixed);
}
