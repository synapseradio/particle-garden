// =============================================================================
// BIN-SCATTER-VELOCITIES: Physical Scatter of Velocities and Species (Pass 3b)
// =============================================================================
//
// WHY THIS EXISTS (Cache Optimization):
// This is the second pass of the physical bin-scatter optimization. Pass 3a
// scattered positions and built the reverseIndices mapping. This pass uses
// reverseIndices to scatter velocities and species data into sorted order.
//
// Split from bin-scatter-positions due to WebGPU's 8-storage-buffer limit.
// Together, these two passes enable the forces shader to read ALL particle
// data sequentially, maximizing L1 cache utilization.
//
// ALGORITHM:
// 1. Each thread processes one particle by its ORIGINAL index
// 2. Look up the sorted destination index via reverseIndices[originalIdx]
// 3. Read velocity and species from unsorted source buffers
// 4. Write to sorted destination buffers at sortedIdx
//
// BINDING MANIFEST:
// +-------+---------------------------+-----------------+--------+
// | Bind  | Shader Type               | JS Buffer       | Access |
// +-------+---------------------------+-----------------+--------+
// |   0   | uniform GridParams        | gridParams      | read   |
// |   1   | storage array<f32>        | srcVx           | read   |
// |   2   | storage array<f32>        | srcVy           | read   |
// |   3   | storage array<u32>        | srcSpecies      | read   |
// |   4   | storage array<u32>        | reverseIndices  | read   |
// |   5   | storage array<f32>        | dstVxSorted     | write  |
// |   6   | storage array<f32>        | dstVySorted     | write  |
// |   7   | storage array<u32>        | dstSpeciesSorted| write  |
// +-------+---------------------------+-----------------+--------+
// TOTAL: 7 storage buffers (under 8-buffer WebGPU limit)
//
// THREAD MAPPING: One thread per particle (global_invocation_id.x = originalIdx)
// =============================================================================

struct GridParams {
  gridW: u32,
  gridH: u32,
  canvasWidth: f32,
  canvasHeight: f32,
  particleCount: u32,
  padding0: u32,
  padding1: u32,
  padding2: u32,
};

@group(0) @binding(0) var<uniform> params: GridParams;
@group(0) @binding(1) var<storage, read> srcVx: array<f32>;
@group(0) @binding(2) var<storage, read> srcVy: array<f32>;
@group(0) @binding(3) var<storage, read> srcSpecies: array<u32>;
@group(0) @binding(4) var<storage, read> reverseIndices: array<u32>;
@group(0) @binding(5) var<storage, read_write> dstVxSorted: array<f32>;
@group(0) @binding(6) var<storage, read_write> dstVySorted: array<f32>;
@group(0) @binding(7) var<storage, read_write> dstSpeciesSorted: array<u32>;

@compute @workgroup_size(128)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let originalIdx = global_id.x;

  // Bounds check
  if (originalIdx >= params.particleCount) {
    return;
  }

  // Look up where this particle should go in sorted order
  // reverseIndices was populated by bin-scatter-positions
  let sortedIdx = reverseIndices[originalIdx];

  // Physical scatter: copy velocity and species data to sorted buffers
  // This enables sequential memory access in forces pass (L1 cache hits)
  dstVxSorted[sortedIdx] = srcVx[originalIdx];
  dstVySorted[sortedIdx] = srcVy[originalIdx];
  dstSpeciesSorted[sortedIdx] = srcSpecies[originalIdx];
}
