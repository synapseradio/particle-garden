// =============================================================================
// PARTICLE FORCES + DENSITY SHADER (Half-Neighbor with Newton's 3rd Law)
// =============================================================================
//
// WHY THIS EXISTS (Cache Optimization):
// This shader reads particle data from SORTED buffers (pxSorted, pySorted, etc.)
// instead of using indirect indexing (px[sortedIndices[j]]). The physical scatter
// passes (bin-scatter-positions, bin-scatter-velocities) copy particle data into
// spatially-sorted order, enabling SEQUENTIAL memory access patterns here.
//
// CACHE BEHAVIOR:
// - OLD: pxA[sortedIndices[j]] = random access = L3 cache misses
// - NEW: pxSorted[j] = sequential access = L1 cache hits
//
// This change alone can yield 2-3x speedup in the forces computation.
//
// ALGORITHM:
// Computes inter-particle forces AND local density using half-neighbor iteration.
// Each pair (i,j) is computed ONCE, with force applied to both particles via atomics.
//
// HALF-NEIGHBOR PATTERN:
// +---+---+---+
// |   |   |   |  Skip top row (handled by particles above)
// +---+---+---+
// |   | i | Y |  Same cell: j>i only. Right: all.
// +---+---+---+
// | Y | Y | Y |  Bottom row: all three cells.
// +---+---+---+
//
// BINDING MANIFEST:
// +-------+---------------------------+------------------+--------+
// | Bind  | Shader Type               | JS Buffer        | Access |
// +-------+---------------------------+------------------+--------+
// |   0   | uniform SimParams         | simParams        | read   |
// |   1   | storage array<f32>        | pxSorted         | read   |
// |   2   | storage array<f32>        | pySorted         | read   |
// |   3   | storage array<u32>        | speciesSorted    | read   |
// |   4   | storage array<u32>        | sortedIndices    | read   |
// |   5   | storage array<u32>        | cellOffsets      | read   |
// |   6   | storage array<u32>        | cellCounts       | read   |
// |   7   | storage array<f32>        | densityOutput    | r/w    |
// |   8   | storage atomic<i32>       | velocityDelta    | r/w    |
// +-------+---------------------------+------------------+--------+
// TOTAL: 8 storage buffers (at WebGPU per-stage limit)
//
// THREAD MAPPING: One particle per thread (sorted index space)
// =============================================================================

struct SimParams {
  dt: f32,
  worldWidth: f32,
  worldHeight: f32,
  interactionRadius: f32,
  forceMultiplier: f32,
  gridCellsX: u32,
  gridCellsY: u32,
  mouseX: f32,
  mouseY: f32,
  mouseLeftDown: f32,
  mouseRightDown: f32,
  particleCount: u32,
  attractionMatrix: array<vec4<f32>, 9>,
};

@group(0) @binding(0) var<uniform> params: SimParams;

// SORTED buffers - sequential access for cache efficiency
@group(0) @binding(1) var<storage, read> pxSorted: array<f32>;
@group(0) @binding(2) var<storage, read> pySorted: array<f32>;
@group(0) @binding(3) var<storage, read> speciesSorted: array<u32>;

// Index mapping: sortedIdx -> originalIdx (for writing velocity deltas)
@group(0) @binding(4) var<storage, read> sortedToOriginal: array<u32>;
@group(0) @binding(5) var<storage, read> cellStartOffsets: array<u32>;
@group(0) @binding(6) var<storage, read> cellParticleCounts: array<u32>;

@group(0) @binding(7) var<storage, read_write> densityOutput: array<f32>;
@group(0) @binding(8) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;

const MAX_SPECIES: u32 = 6u;
const MIN_DISTANCE_SQ: f32 = 4.0;
const REPULSION_ZONE_INV: f32 = 3.333333333;     // 1.0 / 0.3
const ATTRACTION_FALLOFF_INV: f32 = 1.428571429; // 1.0 / 0.7
const MOUSE_RANGE_SQ: f32 = 90000.0;
const FIXED_POINT_SCALE: f32 = 65536.0;

@compute @workgroup_size(128, 1, 1)
fn computeForces(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let thisSortedIdx = globalId.x;

  if (thisSortedIdx >= params.particleCount) {
    return;
  }

  // Load this particle's state from SORTED buffers (sequential read)
  let thisX = pxSorted[thisSortedIdx];
  let thisY = pySorted[thisSortedIdx];
  let thisSpecies = speciesSorted[thisSortedIdx];
  let thisOriginalIdx = sortedToOriginal[thisSortedIdx];

  // Precompute constants
  let radiusSq = params.interactionRadius * params.interactionRadius;
  let invRadius = 1.0 / params.interactionRadius;
  let halfWorldWidth = params.worldWidth * 0.5;
  let halfWorldHeight = params.worldHeight * 0.5;
  let invCellWidth = f32(params.gridCellsX) / params.worldWidth;
  let invCellHeight = f32(params.gridCellsY) / params.worldHeight;
  let totalCells = i32(params.gridCellsX * params.gridCellsY);
  let gridWidth = i32(params.gridCellsX);
  let gridHeight = i32(params.gridCellsY);

  // Accumulators for this particle (register, not memory)
  var forceOnThisX = 0.0;
  var forceOnThisY = 0.0;
  var densityAccum = 0.0;

  // Find this particle's grid cell
  var cellX = i32(thisX * invCellWidth);
  var cellY = i32(thisY * invCellHeight);
  cellX = clamp(cellX, 0, gridWidth - 1);
  cellY = clamp(cellY, 0, gridHeight - 1);

  // Half-neighbor iteration: 5 cells instead of 9
  for (var neighborIdx: i32 = 0; neighborIdx < 5; neighborIdx++) {
    var offsetX: i32;
    var offsetY: i32;

    // Unrolled offset lookup
    if (neighborIdx == 0) { offsetX = 0; offsetY = 0; }
    else if (neighborIdx == 1) { offsetX = 1; offsetY = 0; }
    else if (neighborIdx == 2) { offsetX = -1; offsetY = 1; }
    else if (neighborIdx == 3) { offsetX = 0; offsetY = 1; }
    else { offsetX = 1; offsetY = 1; }

    var neighborCellX = cellX + offsetX;
    var neighborCellY = cellY + offsetY;
    var toroidalOffsetX = 0.0;
    var toroidalOffsetY = 0.0;

    // Toroidal X wrap
    if (neighborCellX < 0) {
      neighborCellX += gridWidth;
      toroidalOffsetX = -params.worldWidth;
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

    // Iterate through particles in this cell - SEQUENTIAL access now!
    for (var otherSortedIdx: i32 = cellStart; otherSortedIdx < cellEnd; otherSortedIdx++) {
      // For same cell, only process pairs where other > this (avoid double-counting)
      if (isSameCell && u32(otherSortedIdx) <= thisSortedIdx) {
        continue;
      }

      // Skip self
      if (u32(otherSortedIdx) == thisSortedIdx) {
        continue;
      }

      // Load other particle's state from SORTED buffers (sequential read = L1 cache hit!)
      let otherX = pxSorted[otherSortedIdx];
      let otherY = pySorted[otherSortedIdx];
      let otherSpecies = speciesSorted[otherSortedIdx];
      let otherOriginalIdx = sortedToOriginal[otherSortedIdx];

      // Compute separation vector
      let separationX = (otherX + toroidalOffsetX) - thisX;
      let separationY = (otherY + toroidalOffsetY) - thisY;
      let distanceSq = separationX * separationX + separationY * separationY;

      if (distanceSq > 0.0 && distanceSq < radiusSq) {
        let clampedDistSq = max(distanceSq, MIN_DISTANCE_SQ);
        let distance = sqrt(clampedDistSq);
        let invDistance = 1.0 / distance;
        let normalizedDist = distance * invRadius;

        // Get attraction coefficients for both directions
        let matrixIdxThisToOther = thisSpecies * MAX_SPECIES + otherSpecies;
        let matrixIdxOtherToThis = otherSpecies * MAX_SPECIES + thisSpecies;
        let attractionThisToOther = params.attractionMatrix[matrixIdxThisToOther / 4u][matrixIdxThisToOther % 4u];
        let attractionOtherToThis = params.attractionMatrix[matrixIdxOtherToThis / 4u][matrixIdxOtherToThis % 4u];

        // Force on THIS particle
        var forceMagnitudeOnThis: f32;
        if (normalizedDist < 0.3) {
          forceMagnitudeOnThis = normalizedDist * REPULSION_ZONE_INV - 1.0;
        } else {
          let t = 2.0 * normalizedDist - 1.3;
          forceMagnitudeOnThis = attractionThisToOther * (1.0 - abs(t) * ATTRACTION_FALLOFF_INV);
        }
        forceMagnitudeOnThis *= params.forceMultiplier * invDistance;

        // Force on OTHER particle (Newton's 3rd law)
        var forceMagnitudeOnOther: f32;
        if (normalizedDist < 0.3) {
          forceMagnitudeOnOther = normalizedDist * REPULSION_ZONE_INV - 1.0;
        } else {
          let t = 2.0 * normalizedDist - 1.3;
          forceMagnitudeOnOther = attractionOtherToThis * (1.0 - abs(t) * ATTRACTION_FALLOFF_INV);
        }
        forceMagnitudeOnOther *= params.forceMultiplier * invDistance;

        // Accumulate force on THIS in register (no atomic needed)
        forceOnThisX += separationX * forceMagnitudeOnThis;
        forceOnThisY += separationY * forceMagnitudeOnThis;

        // Apply force to OTHER particle via global atomic
        // Write to ORIGINAL index since velocityDelta is in original order
        let forceOnOtherX = -separationX * forceMagnitudeOnOther;
        let forceOnOtherY = -separationY * forceMagnitudeOnOther;
        let deltaVxOtherFixed = i32(forceOnOtherX * params.dt * FIXED_POINT_SCALE);
        let deltaVyOtherFixed = i32(forceOnOtherY * params.dt * FIXED_POINT_SCALE);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u], deltaVxOtherFixed);
        atomicAdd(&velocityDeltaFixed[otherOriginalIdx * 2u + 1u], deltaVyOtherFixed);

        // Density: same-species neighbors
        if (otherSpecies == thisSpecies) {
          densityAccum += 1.0 - normalizedDist;
        }
      }
    }
  }

  // Mouse attraction (this particle only)
  if (params.mouseLeftDown > 0.5 || params.mouseRightDown > 0.5) {
    var mouseOffsetX = params.mouseX - thisX;
    var mouseOffsetY = params.mouseY - thisY;

    if (mouseOffsetX > halfWorldWidth) { mouseOffsetX -= params.worldWidth; }
    else if (mouseOffsetX < -halfWorldWidth) { mouseOffsetX += params.worldWidth; }
    if (mouseOffsetY > halfWorldHeight) { mouseOffsetY -= params.worldHeight; }
    else if (mouseOffsetY < -halfWorldHeight) { mouseOffsetY += params.worldHeight; }

    let mouseDistSq = mouseOffsetX * mouseOffsetX + mouseOffsetY * mouseOffsetY;
    if (mouseDistSq > 0.0 && mouseDistSq < MOUSE_RANGE_SQ) {
      let mouseDist = sqrt(mouseDistSq);
      let mouseForce = 50.0 * (1.0 - mouseDist / 300.0) / mouseDist;

      var mouseSign = 0.0;
      if (params.mouseLeftDown > 0.5) { mouseSign += 1.0; }
      if (params.mouseRightDown > 0.5) { mouseSign -= 1.0; }

      forceOnThisX += mouseOffsetX * mouseForce * mouseSign;
      forceOnThisY += mouseOffsetY * mouseForce * mouseSign;
    }
  }

  // Apply accumulated force to THIS particle via single atomic
  // Write to ORIGINAL index since velocityDelta is in original order
  let deltaVxThisFixed = i32(forceOnThisX * params.dt * FIXED_POINT_SCALE);
  let deltaVyThisFixed = i32(forceOnThisY * params.dt * FIXED_POINT_SCALE);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u], deltaVxThisFixed);
  atomicAdd(&velocityDeltaFixed[thisOriginalIdx * 2u + 1u], deltaVyThisFixed);

  // Temporal density smoothing: exponential moving average
  // Write to ORIGINAL index since density buffer is in original order
  let prevDensity = densityOutput[thisOriginalIdx];
  const DENSITY_SMOOTH_FACTOR = 0.7;
  let smoothedDensity = prevDensity * DENSITY_SMOOTH_FACTOR + densityAccum * (1.0 - DENSITY_SMOOTH_FACTOR);
  densityOutput[thisOriginalIdx] = smoothedDensity;
}
