/**
 * 65,536 cells / 256 per block = 256 blocks: small enough for one workgroup.
 * Blelloch scan (citation in prefix-sum-local.wgsl).
 */

//! import scan_params

@group(0) @binding(0) var<uniform> params: ScanParams;
@group(0) @binding(1) var<storage, read> blockSums: array<u32>;      // Input: per-block totals
@group(0) @binding(2) var<storage, read_write> blockOffsets: array<u32>; // Output: exclusive scan of block sums

const BLOCK_SIZE: u32 = 256u;

// Shared memory for local scan
var<workgroup> temp: array<u32, BLOCK_SIZE>;

@compute @workgroup_size({{WORKGROUP_SIZE}})
fn main(
  @builtin(local_invocation_id) localId: vec3<u32>,
  @builtin(workgroup_id) workgroupId: vec3<u32>
) {
  if (workgroupId.x != 0u) {
    return;
  }

  let tid = localId.x;

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

  if (tid < params.numBlocks) {
    blockOffsets[tid] = temp[tid];
  }
}
