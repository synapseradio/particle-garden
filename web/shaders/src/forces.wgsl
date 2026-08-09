// =============================================================================
// PARTICLE FORCES + DENSITY SHADER (Half-Neighbor with Newton's 3rd Law)
// =============================================================================
//
// This shader reads the SORTED AoS buffer (particlesSorted[]), which the
// scatter pass fills in spatial order, so neighbour sweeps touch memory
// sequentially. Struct layout and cache behaviour: particle.wgsl and
// web/shaders/README.md.
//
// ALGORITHM:
// Computes inter-particle forces AND local density using half-neighbor iteration.
// Each pair (i,j) is computed ONCE, with force applied to both particles via atomics.
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
//
// =============================================================================

//! import particle
//! import fixed_point
//! import sim_params

// SimParams is generated from src/gpu_types.nim (SimParamsLayout) and provided
// by the sim_params module imported above.
@group(0) @binding(0) var<uniform> params: SimParams;

@group(0) @binding(1) var<storage, read> particlesSorted: array<Particle>;

// Index mapping: sortedIdx → originalIdx (needed to write results back to original buffers)
@group(0) @binding(2) var<storage, read> sortedToOriginal: array<u32>;
@group(0) @binding(3) var<storage, read> cellStartOffsets: array<u32>;
@group(0) @binding(4) var<storage, read> cellParticleCounts: array<u32>;

// Fixed-point atomic accumulators; rationale and scales in fixed_point.wgsl.
@group(0) @binding(5) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;
@group(0) @binding(6) var<storage, read_write> densityDeltaFixed: array<atomic<i32>>;

// The second density channel: every neighbour, no species gate. Encoded at the
// crowd scale rather than the velocity one — see fixed_point.wgsl for why a
// neighbour count needs the coarser of the two.
@group(0) @binding(7) var<storage, read_write> crowdDensityDeltaFixed: array<atomic<i32>>;

const MIN_DISTANCE_SQ: f32 = {{TUNABLE_MIN_DISTANCE_SQ}};  // Prevents division-by-zero when particles overlap

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
//
// `attenuation` is the crowding term, and it multiplies the ATTRACTION term
// alone. A negative matrix entry turns that term repulsive, so the gate below
// leaves it at full strength: damping repulsion would partly cancel the cap the
// term exists to serve.
fn exponentialForce(r: f32, attraction: f32, alpha: f32, beta: f32, attenuation: f32) -> f32 {
  let repulsion = exp(-alpha * r);
  let attract = exp(-beta * r);
  let crowding = select(1.0, attenuation, attraction > 0.0);
  return -repulsion + attraction * attract * 2.0 * crowding;
}

// =============================================================================
// CROWDING ATTENUATION
// =============================================================================
// The fraction of its attraction a particle keeps at this local density.
// Mirrored by physics_core.crowdingAttenuation, which the native suite checks;
// read the density-ceiling block there for what the cap does and does not claim.
//
// Logarithmic because the range that matters spans two orders of magnitude — a
// few neighbours against a collapsing blob. Three properties follow by
// construction: identity at zero density, monotone decreasing in density, and
// identity at strength zero, which is today's force law exactly.
fn crowdingAttenuation(density: f32, strength: f32) -> f32 {
  return 1.0 / (1.0 + strength * log(1.0 + density));
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn computeForces(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let thisSortedIdx = globalId.x;

  if (thisSortedIdx >= params.particleCount) {
    return;
  }

  let thisParticle = particlesSorted[thisSortedIdx];
  let thisOriginalIdx = sortedToOriginal[thisSortedIdx];

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
  var crowdDensityAccum = 0.0;

  // THIS PASS ACCUMULATES ONLY. The frame clears velocityDelta and both density
  // deltas before anything writes them (sim_registry.buildFrame opens with those
  // clears), so a self-reset here would erase whatever a co-running
  // contributor — the field force, or forces-sph — had already added.

  // How much of its attraction THIS particle keeps, at the crowd density it
  // carried into this frame. Hoisted: this particle's density does not change
  // while the loop runs, so the neighbour loop reads it rather than recomputing
  // a log per pair. Each side of a half-neighbour pair is attenuated by the
  // density of the particle RECEIVING the force, so the other side's is
  // computed per pair.
  let attenuationOnThis =
    crowdingAttenuation(thisParticle.crowdDensity, params.crowdingStrength);

  var cellX = i32(thisParticle.pos.x * invCellWidth);
  var cellY = i32(thisParticle.pos.y * invCellHeight);
  cellX = clamp(cellX, 0, gridWidth - 1);
  cellY = clamp(cellY, 0, gridHeight - 1);

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

    for (var otherSortedIdx: i32 = cellStart; otherSortedIdx < cellEnd; otherSortedIdx++) {
      // For same cell, only process pairs where other > this (half-neighbor optimization)
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
        let normalizedDist = distance * invRadius;  // 0.0 = touching, 1.0 = at radius edge

        // Matrix is asymmetric: Red may attract Blue, while Blue repels Red
        let matrixIdxThisToOther = thisParticle.species * MAX_SPECIES + otherParticle.species;
        let matrixIdxOtherToThis = otherParticle.species * MAX_SPECIES + thisParticle.species;
        let attractionThisToOther = params.attractionMatrix[matrixIdxThisToOther / 4u][matrixIdxThisToOther % 4u];
        let attractionOtherToThis = params.attractionMatrix[matrixIdxOtherToThis / 4u][matrixIdxOtherToThis % 4u];

        // Force model selection: params.forceModel picks the polynomial curve
        // (default) or the exponential one defined above. invDistance converts
        // the force magnitude into an acceleration.

        var forceMagnitudeOnThis: f32;
        var forceMagnitudeOnOther: f32;

        // The crowding term for the particle receiving each half of the pair.
        let attenuationOnOther =
          crowdingAttenuation(otherParticle.crowdDensity, params.crowdingStrength);

        if (params.forceModel == 1u) {
          // EXPONENTIAL MODEL
          forceMagnitudeOnThis = exponentialForce(normalizedDist, attractionThisToOther, params.expAlpha, params.expBeta, attenuationOnThis);
          forceMagnitudeOnOther = exponentialForce(normalizedDist, attractionOtherToThis, params.expAlpha, params.expBeta, attenuationOnOther);
        } else {
          // POLYNOMIAL MODEL (default)
          let repEnd = params.repulsionEnd;
          let attPeak = params.attractionPeak;

          // Force on THIS particle
          if (normalizedDist < repEnd) {
            // Repulsion zone: smooth cubic normalized to [0, repEnd]
            let t = normalizedDist / repEnd;
            let t2 = t * t;
            forceMagnitudeOnThis = -1.0 + 3.0 * t2 - 2.0 * t2 * t;  // Hermite: f(0)=-1, f(1)=0, f'(1)=0
          } else {
            // Attraction zone: smooth bump in [repEnd, 1] peaking at attPeak
            let zoneWidth = 1.0 - repEnd;
            let peakPos = (attPeak - repEnd) / zoneWidth;  // Normalized peak position in [0, 1]
            let t = (normalizedDist - repEnd) / zoneWidth;
            // Bump function: peaks at peakPos, zero at 0 and 1
            let leftDist = t / peakPos;
            let rightDist = (1.0 - t) / (1.0 - peakPos);
            let bump = min(leftDist, 1.0) * min(leftDist, 1.0) * min(rightDist, 1.0) * min(rightDist, 1.0);
            // Scale to the model's calibrated peak magnitude, then attenuate by
            // how crowded the RECEIVING particle is. Gated on the sign: a negative entry
            // makes this branch repulsive and the crowding term never touches
            // repulsion.
            let crowdingOnThis = select(1.0, attenuationOnThis, attractionThisToOther > 0.0);
            forceMagnitudeOnThis = attractionThisToOther * bump * 4.0 * crowdingOnThis;
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
            let crowdingOnOther = select(1.0, attenuationOnOther, attractionOtherToThis > 0.0);
            forceMagnitudeOnOther = attractionOtherToThis * bump * 4.0 * crowdingOnOther;
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
        let forceOnOtherX = -separationX * forceMagnitudeOnOther;  // Newton's 3rd: opposite direction
        let forceOnOtherY = -separationY * forceMagnitudeOnOther;
        let deltaVxOtherFixed = i32(forceOnOtherX * params.dt * FIXED_POINT_SCALE);
        let deltaVyOtherFixed = i32(forceOnOtherY * params.dt * FIXED_POINT_SCALE);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u], deltaVxOtherFixed);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u + 1u], deltaVyOtherFixed);

        // Symmetric density accumulation into two channels, colony
        // (species-gated) and crowd (ungated); what each answers and why they
        // stay separate: particle.wgsl's THREE DENSITIES block. Both share one
        // proximity weight — (1.0 - normalizedDist), touching=1, at the radius
        // edge=0 — and differ only in the gate above them.
        //
        // CRITICAL: Half-neighbor iteration means each pair is processed ONCE.
        // Both particles must receive the contribution from this pair. Same
        // atomic pattern as velocity: write to OTHER immediately, accumulate
        // THIS in a register and write once at the end.
        let proximityWeight = 1.0 - normalizedDist;

        crowdDensityAccum += proximityWeight;
        atomicAdd(&crowdDensityDeltaFixed[otherOriginalIdx],
          i32(proximityWeight * CROWD_DENSITY_FIXED_POINT_SCALE));

        if (otherParticle.species == thisParticle.species) {
          densityAccum += proximityWeight;

          let densityFixed = i32(proximityWeight * FIXED_POINT_SCALE);
          atomicAdd(&densityDeltaFixed[otherOriginalIdx], densityFixed);
        }
      }
    }
  }

  // Mouse interaction (left attracts, right repels)
  if (params.mouseLeftDown > 0.5 || params.mouseRightDown > 0.5) {
    var mouseOffsetX = params.mouseX - thisParticle.pos.x;
    var mouseOffsetY = params.mouseY - thisParticle.pos.y;

    if (mouseOffsetX > halfWorldWidth) { mouseOffsetX -= params.worldWidth; }
    else if (mouseOffsetX < -halfWorldWidth) { mouseOffsetX += params.worldWidth; }
    if (mouseOffsetY > halfWorldHeight) { mouseOffsetY -= params.worldHeight; }
    else if (mouseOffsetY < -halfWorldHeight) { mouseOffsetY += params.worldHeight; }

    let mouseDistSq = mouseOffsetX * mouseOffsetX + mouseOffsetY * mouseOffsetY;
    // params.mouseRange is the 300-unit base over the camera zoom, so the
    // influence disc keeps a constant on-screen size. Peak strength stays
    // 300 at every zoom; only the extent scales.
    if (mouseDistSq > 0.0 && mouseDistSq < params.mouseRange * params.mouseRange) {
      let mouseDist = sqrt(mouseDistSq);
      let mouseForce = 300.0 * (1.0 - mouseDist / params.mouseRange) / mouseDist;

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

    if (blastOffsetX > halfWorldWidth) { blastOffsetX -= params.worldWidth; }
    else if (blastOffsetX < -halfWorldWidth) { blastOffsetX += params.worldWidth; }
    if (blastOffsetY > halfWorldHeight) { blastOffsetY -= params.worldHeight; }
    else if (blastOffsetY < -halfWorldHeight) { blastOffsetY += params.worldHeight; }

    let blastDistSq = blastOffsetX * blastOffsetX + blastOffsetY * blastOffsetY;
    let blastRangeSq = 40000.0;  // 200² - blast influence radius squared
    if (blastDistSq > 0.0 && blastDistSq < blastRangeSq) {
      let blastDist = sqrt(blastDistSq);
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

  // Temporal smoothing happens in integrate pass (needs previous density value).
  let densityThisFixed = i32(densityAccum * FIXED_POINT_SCALE);
  atomicAdd(&densityDeltaFixed[thisOriginalIdx], densityThisFixed);

  atomicAdd(&crowdDensityDeltaFixed[thisOriginalIdx],
    i32(crowdDensityAccum * CROWD_DENSITY_FIXED_POINT_SCALE));
}
