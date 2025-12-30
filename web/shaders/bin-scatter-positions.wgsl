// =============================================================================
// BIN-SCATTER-POSITIONS: Physical Scatter of Particle Positions (Pass 3a)
// =============================================================================
//
// WHY THIS EXISTS (Cache Optimization):
// The previous bin-scatter.wgsl only created sortedIndices[] - a mapping from
// sorted position to original index. The forces pass then read particles via
// indirection: `px[sortedIndices[j]]`, causing RANDOM memory access patterns
// and L3 cache misses on every neighbor lookup.
//
// This shader PHYSICALLY COPIES position data into sorted buffers. The forces
// pass then reads sequentially: `pxSorted[j]`, achieving SEQUENTIAL memory
// access and L1 cache hits - a major performance win.
//
// ALGORITHM:
// 1. Each thread processes one particle by its original index
// 2. Read particle position from unsorted source buffers
// 3. Compute cell index from position (same algorithm as bin-count.wgsl)
// 4. Atomically increment fillOffsets[cell] to allocate a unique write slot
// 5. Write position data to sorted buffers at the allocated slot
// 6. Build BOTH index mappings:
//    - sortedIndices[dstIdx] = originalIdx (sorted -> original, for integrate)
//    - reverseIndices[originalIdx] = dstIdx (original -> sorted, for velocity scatter)
//
// BINDING MANIFEST:
// +-------+---------------------------+-----------------+--------+
// | Bind  | Shader Type               | JS Buffer       | Access |
// +-------+---------------------------+-----------------+--------+
// |   0   | uniform GridParams        | gridParams      | read   |
// |   1   | storage array<f32>        | srcPx           | read   |
// |   2   | storage array<f32>        | srcPy           | read   |
// |   3   | storage array<f32>        | dstPxSorted     | write  |
// |   4   | storage array<f32>        | dstPySorted     | write  |
// |   5   | storage array<u32>        | sortedIndices   | write  |
// |   6   | storage array<u32>        | reverseIndices  | write  |
// |   7   | storage array<atomic<u32>>| fillPointers    | r/w    |
// +-------+---------------------------+-----------------+--------+
// TOTAL: 7 storage buffers (under 8-buffer WebGPU limit)
//
// THREAD MAPPING: One thread per particle (global_invocation_id.x = particleIdx)
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
@group(0) @binding(1) var<storage, read> srcPx: array<f32>;
@group(0) @binding(2) var<storage, read> srcPy: array<f32>;
@group(0) @binding(3) var<storage, read_write> dstPxSorted: array<f32>;
@group(0) @binding(4) var<storage, read_write> dstPySorted: array<f32>;
@group(0) @binding(5) var<storage, read_write> sortedIndices: array<u32>;
@group(0) @binding(6) var<storage, read_write> reverseIndices: array<u32>;
@group(0) @binding(7) var<storage, read_write> fillOffsets: array<atomic<u32>>;

@compute @workgroup_size(128)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let particleIdx = global_id.x;

  // Bounds check
  if (particleIdx >= params.particleCount) {
    return;
  }

  // Read particle position from unsorted source buffers
  let posX = srcPx[particleIdx];
  let posY = srcPy[particleIdx];

  // Compute cell coordinates (must match bin-count.wgsl exactly)
  let invCellW = f32(params.gridW) / params.canvasWidth;
  let invCellH = f32(params.gridH) / params.canvasHeight;

  var cx = u32(posX * invCellW);
  var cy = u32(posY * invCellH);

  // Clamp to grid bounds (handle edge cases)
  if (cx >= params.gridW) {
    cx = params.gridW - 1u;
  }
  if (cy >= params.gridH) {
    cy = params.gridH - 1u;
  }

  // Compute linear cell index
  let cellIdx = cy * params.gridW + cx;

  // Atomically allocate write slot within this cell's range
  // fillOffsets was initialized from gridOffsets (exclusive prefix sum)
  let dstIdx = atomicAdd(&fillOffsets[cellIdx], 1u);

  // Physical scatter: copy position data to sorted buffers
  // This enables sequential memory access in forces pass (L1 cache hits)
  dstPxSorted[dstIdx] = posX;
  dstPySorted[dstIdx] = posY;

  // Build BOTH index mappings:
  // sortedIndices: sorted -> original (used by integrate to write back)
  sortedIndices[dstIdx] = particleIdx;
  // reverseIndices: original -> sorted (used by bin-scatter-velocities)
  reverseIndices[particleIdx] = dstIdx;
}
