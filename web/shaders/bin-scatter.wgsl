/**
 * Pass 3: Build sorted index mapping using atomic write-slot allocation.
 *
 * Each thread processes one particle:
 * 1. Read particle position from source buffers
 * 2. Compute cell index (cx, cy) from position
 * 3. Atomically increment fillOffsets[cell] to get unique write slot
 * 4. Write original particle index to sortedIndices at the allocated slot
 *
 * After this pass, sortedIndices[sortedIdx] = originalIdx, enabling the
 * forces pass to iterate particles in spatially-sorted order while reading
 * from the original unsorted buffers.
 *
 * ARCHITECTURAL NOTE:
 * The forces pass reads particle data using indirect indexing:
 *   jIdx = sortedIndices[j]; data = pxA[jIdx]
 * This means we don't need to physically scatter particle data - we only
 * need the index mapping. This keeps bin-scatter under the 8-storage-buffer
 * WebGPU limit.
 *
 * BINDING MANIFEST:
 * ┌─────────┬──────────────────────────┬─────────────────┬────────┐
 * │ Binding │ Shader Type              │ JS Buffer       │ Access │
 * ├─────────┼──────────────────────────┼─────────────────┼────────┤
 * │ 0       │ uniform GridParams       │ gridParams      │ read   │
 * │ 1       │ storage array<f32>       │ srcPx           │ read   │
 * │ 2       │ storage array<f32>       │ srcPy           │ read   │
 * │ 3       │ storage array<u32>       │ sortedIndices   │ write  │
 * │ 4       │ storage array<atomic>    │ fillPointers    │ r/w    │
 * └─────────┴──────────────────────────┴─────────────────┴────────┘
 * TOTAL: 4 storage buffers (under 8-buffer limit)
 *
 * NOTE: fillPointers is initialized from gridOffsets by JS before dispatch.
 * Each thread atomically increments fillPointers[cell] to get its write slot.
 */

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
@group(0) @binding(3) var<storage, read_write> sortedIndices: array<u32>;
@group(0) @binding(4) var<storage, read_write> fillOffsets: array<atomic<u32>>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let particleIdx = global_id.x;

  // Bounds check
  if (particleIdx >= params.particleCount) {
    return;
  }

  // Read particle position
  let posX = srcPx[particleIdx];
  let posY = srcPy[particleIdx];

  // Compute cell coordinates (must match bin-count.wgsl exactly)
  let invCellW = f32(params.gridW) / params.canvasWidth;
  let invCellH = f32(params.gridH) / params.canvasHeight;

  var cx = u32(posX * invCellW);
  var cy = u32(posY * invCellH);

  // Clamp to grid bounds
  if (cx >= params.gridW) {
    cx = params.gridW - 1u;
  }
  if (cy >= params.gridH) {
    cy = params.gridH - 1u;
  }

  // Compute linear cell index
  let cellIdx = cy * params.gridW + cx;

  // Atomically allocate write slot within this cell's range
  let dstIdx = atomicAdd(&fillOffsets[cellIdx], 1u);

  // Write sorted index mapping: sortedIndices[sortedIdx] = originalIdx
  // Forces pass will use this to read particle data in spatially-sorted order
  sortedIndices[dstIdx] = particleIdx;
}
