/**
 * Pass 2b: Scan block totals (sequential - only 256 elements)
 *
 * After local prefix sums, each workgroup produced a block total.
 * This pass computes exclusive prefix sum of those block totals.
 * With 65,536 cells / 256 per block = 256 blocks, this is small enough
 * to run on a single workgroup.
 *
 * BINDING MANIFEST:
 * ┌─────────┬──────────────────────────┬─────────────────┬────────┐
 * │ Binding │ Shader Type              │ JS Buffer       │ Access │
 * ├─────────┼──────────────────────────┼─────────────────┼────────┤
 * │ 0       │ uniform ScanParams       │ scanParams      │ read   │
 * │ 1       │ storage array<u32>       │ blockSums       │ read   │
 * │ 2       │ storage array<u32>       │ blockOffsets    │ write  │
 * └─────────┴──────────────────────────┴─────────────────┴────────┘
 */

//! import scan_params

@group(0) @binding(0) var<uniform> params: ScanParams;
@group(0) @binding(1) var<storage, read> blockSums: array<u32>;      // Input: per-block totals
@group(0) @binding(2) var<storage, read_write> blockOffsets: array<u32>; // Output: exclusive scan of block sums

const BLOCK_SIZE: u32 = 256u;

// Shared memory for local scan
var<workgroup> temp: array<u32, BLOCK_SIZE>;

@compute @workgroup_size(256)
fn main(
  @builtin(local_invocation_id) localId: vec3<u32>,
  @builtin(workgroup_id) workgroupId: vec3<u32>
) {
  // Only workgroup 0 does work - this is scanning at most 256 block totals
  if (workgroupId.x != 0u) {
    return;
  }

  let tid = localId.x;

  // Load block sums into shared memory (with bounds check)
  if (tid < params.numBlocks) {
    temp[tid] = blockSums[tid];
  } else {
    temp[tid] = 0u;
  }
  workgroupBarrier();

  // ========== UP-SWEEP (Reduce) ==========
  var offset = 1u;
  for (var d = BLOCK_SIZE >> 1u; d > 0u; d >>= 1u) {
    workgroupBarrier();
    if (tid < d) {
      let ai = offset * (2u * tid + 1u) - 1u;
      let bi = offset * (2u * tid + 2u) - 1u;
      temp[bi] += temp[ai];
    }
    offset <<= 1u;
  }

  // Clear last element for exclusive scan
  if (tid == 0u) {
    temp[BLOCK_SIZE - 1u] = 0u;
  }
  workgroupBarrier();

  // ========== DOWN-SWEEP (Scan) ==========
  for (var d = 1u; d < BLOCK_SIZE; d <<= 1u) {
    offset >>= 1u;
    workgroupBarrier();
    if (tid < d) {
      let ai = offset * (2u * tid + 1u) - 1u;
      let bi = offset * (2u * tid + 2u) - 1u;
      let t = temp[ai];
      temp[ai] = temp[bi];
      temp[bi] += t;
    }
  }
  workgroupBarrier();

  // Write result (exclusive prefix sum of block totals)
  if (tid < params.numBlocks) {
    blockOffsets[tid] = temp[tid];
  }
}
