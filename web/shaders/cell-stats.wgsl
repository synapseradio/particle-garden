// =============================================================================
// CELL STATISTICS SHADER (Pre-pass for Hierarchical Forces)
// =============================================================================
//
// Computes per-cell aggregate statistics for LOD (Level of Detail) force approximation:
// - Centroid (center of mass) per cell
// - Particle count per species (6 species max)
//
// These statistics allow the forces shader to approximate interactions with
// distant cells using a single centroid instead of iterating all particles.
//
// Algorithm:
// 1. Each workgroup processes one cell
// 2. Threads cooperatively sum positions and count species
// 3. Workgroup reduction computes final centroid and counts
// 4. Write results to cellStats buffer
//
// Thread mapping: One workgroup per cell, 64 threads per workgroup
//
// BINDING MANIFEST:
// ┌─────────┬──────────────────────────┬─────────────────┬────────┐
// │ Binding │ Shader Type              │ JS Buffer       │ Access │
// ├─────────┼──────────────────────────┼─────────────────┼────────┤
// │ 0       │ uniform CellStatsParams  │ cellStatsParams │ read   │
// │ 1       │ storage array<f32>       │ px              │ read   │
// │ 2       │ storage array<f32>       │ py              │ read   │
// │ 3       │ storage array<u32>       │ species         │ read   │
// │ 4       │ storage array<u32>       │ sortedIndices   │ read   │
// │ 5       │ storage array<u32>       │ cellOffsets     │ read   │
// │ 6       │ storage array<u32>       │ cellCounts      │ read   │
// │ 7       │ storage array<f32>       │ cellStats       │ write  │
// └─────────┴──────────────────────────┴─────────────────┴────────┘
// STORAGE BUFFER COUNT: 7
// =============================================================================

struct CellStatsParams {
  numCells: u32,        // Total number of grid cells
  particleCount: u32,   // Total particle count (for bounds checking)
  _pad0: u32,
  _pad1: u32,
};

@group(0) @binding(0) var<uniform> params: CellStatsParams;

// Particle data
@group(0) @binding(1) var<storage, read> px: array<f32>;
@group(0) @binding(2) var<storage, read> py: array<f32>;
@group(0) @binding(3) var<storage, read> species: array<u32>;

// Spatial grid
@group(0) @binding(4) var<storage, read> sortedIndices: array<u32>;
@group(0) @binding(5) var<storage, read> cellOffsets: array<u32>;
@group(0) @binding(6) var<storage, read> cellCounts: array<u32>;

// Output: Per-cell statistics
// Layout per cell (8 floats = 32 bytes):
//   [0] centroidX
//   [1] centroidY
//   [2] count species 0 (as f32)
//   [3] count species 1
//   [4] count species 2
//   [5] count species 3
//   [6] count species 4
//   [7] count species 5
@group(0) @binding(7) var<storage, read_write> cellStats: array<f32>;

const WORKGROUP_SIZE: u32 = 64u;
const MAX_SPECIES: u32 = 6u;
const STATS_PER_CELL: u32 = 8u;  // 2 centroid + 6 species counts

// Shared memory for workgroup reduction
var<workgroup> sharedSumX: array<f32, 64>;
var<workgroup> sharedSumY: array<f32, 64>;
var<workgroup> sharedCounts: array<array<u32, 6>, 64>;

@compute @workgroup_size(64, 1, 1)
fn computeCellStats(
  @builtin(global_invocation_id) globalId: vec3<u32>,
  @builtin(local_invocation_id) localId: vec3<u32>,
  @builtin(workgroup_id) workgroupId: vec3<u32>
) {
  let cellIdx = workgroupId.x;
  let tid = localId.x;

  // Bounds check
  if (cellIdx >= params.numCells) {
    return;
  }

  // Get cell range
  let start = cellOffsets[cellIdx];
  let count = cellCounts[cellIdx];

  // Initialize thread-local accumulators
  var localSumX: f32 = 0.0;
  var localSumY: f32 = 0.0;
  var localCounts: array<u32, 6>;
  for (var s: u32 = 0u; s < MAX_SPECIES; s++) {
    localCounts[s] = 0u;
  }

  // Each thread processes a subset of particles in this cell
  var i = tid;
  while (i < count) {
    let particleIdx = start + i;

    // Bounds check
    if (particleIdx < params.particleCount) {
      let realIdx = sortedIndices[particleIdx];

      if (realIdx < params.particleCount) {
        localSumX += px[realIdx];
        localSumY += py[realIdx];

        let sp = species[realIdx];
        if (sp < MAX_SPECIES) {
          localCounts[sp] += 1u;
        }
      }
    }

    i += WORKGROUP_SIZE;
  }

  // Store in shared memory
  sharedSumX[tid] = localSumX;
  sharedSumY[tid] = localSumY;
  for (var s: u32 = 0u; s < MAX_SPECIES; s++) {
    sharedCounts[tid][s] = localCounts[s];
  }

  workgroupBarrier();

  // Parallel reduction (power-of-two reduction)
  for (var stride: u32 = WORKGROUP_SIZE / 2u; stride > 0u; stride /= 2u) {
    if (tid < stride) {
      sharedSumX[tid] += sharedSumX[tid + stride];
      sharedSumY[tid] += sharedSumY[tid + stride];
      for (var s: u32 = 0u; s < MAX_SPECIES; s++) {
        sharedCounts[tid][s] += sharedCounts[tid + stride][s];
      }
    }
    workgroupBarrier();
  }

  // Thread 0 writes final result
  if (tid == 0u) {
    let baseIdx = cellIdx * STATS_PER_CELL;

    // Compute centroid (average position)
    let totalCount = f32(count);
    if (totalCount > 0.0) {
      cellStats[baseIdx + 0u] = sharedSumX[0] / totalCount;
      cellStats[baseIdx + 1u] = sharedSumY[0] / totalCount;
    } else {
      cellStats[baseIdx + 0u] = 0.0;
      cellStats[baseIdx + 1u] = 0.0;
    }

    // Write species counts (as f32 for shader compatibility)
    for (var s: u32 = 0u; s < MAX_SPECIES; s++) {
      cellStats[baseIdx + 2u + s] = f32(sharedCounts[0][s]);
    }
  }
}
