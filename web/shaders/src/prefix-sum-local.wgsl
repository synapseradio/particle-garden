/**
 * Pass 2a: Local prefix sum within workgroups (Blelloch up-sweep + down-sweep)
 *
 * Each workgroup processes 256 consecutive elements using shared memory.
 * Outputs:
 * - offsets: Local exclusive prefix sums within each block
 * - blockSums: Total sum for each block (for next pass)
 *
 * For 65,536 cells with workgroup size 256: dispatches 256 workgroups
 *
 * ALGORITHM: Blelloch parallel exclusive scan
 * - Up-sweep: Build tree of partial sums (reduce)
 * - Down-sweep: Distribute prefix sums back (scan)
 *
 * BINDING MANIFEST:
 * ┌─────────┬──────────────────────────┬─────────────────┬────────┐
 * │ Binding │ Shader Type              │ JS Buffer       │ Access │
 * ├─────────┼──────────────────────────┼─────────────────┼────────┤
 * │ 0       │ uniform ScanParams       │ scanParams      │ read   │
 * │ 1       │ storage array<u32>       │ gridCounts      │ read   │
 * │ 2       │ storage array<u32>       │ gridOffsets     │ write  │
 * │ 3       │ storage array<u32>       │ blockSums       │ write  │
 * └─────────┴──────────────────────────┴─────────────────┴────────┘
 */

//! import scan_params

@group(0) @binding(0) var<uniform> params: ScanParams;
@group(0) @binding(1) var<storage, read> data: array<u32>;           // cellCounts (input)
@group(0) @binding(2) var<storage, read_write> offsets: array<u32>;  // cellOffsets (output)
@group(0) @binding(3) var<storage, read_write> blockSums: array<u32>; // per-block totals

const BLOCK_SIZE: u32 = 256u;

// Shared memory for local scan
var<workgroup> temp: array<u32, BLOCK_SIZE>;

@compute @workgroup_size({{WORKGROUP_SIZE}})
fn main(
  @builtin(global_invocation_id) globalId: vec3<u32>,
  @builtin(local_invocation_id) localId: vec3<u32>,
  @builtin(workgroup_id) workgroupId: vec3<u32>
) {
  let tid = localId.x;
  let gid = globalId.x;
  let blockIdx = workgroupId.x;

  // Load data into shared memory (with bounds check)
  if (gid < params.numCells) {
    temp[tid] = data[gid];
  } else {
    temp[tid] = 0u;
  }
  workgroupBarrier();

  // ========== UP-SWEEP (Reduce) ==========
  // Build tree of partial sums
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

  // Store block sum before clearing last element
  if (tid == 0u) {
    blockSums[blockIdx] = temp[BLOCK_SIZE - 1u];
    temp[BLOCK_SIZE - 1u] = 0u;  // Clear for exclusive scan
  }
  workgroupBarrier();

  // ========== DOWN-SWEEP (Scan) ==========
  // Traverse tree to build scan
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

  // Write result (exclusive prefix sum within block)
  if (gid < params.numCells) {
    offsets[gid] = temp[tid];
  }
}
