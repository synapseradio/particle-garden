/**
 * Pass 2: Sequential prefix sum (exclusive scan) to compute cell offsets.
 *
 * This shader converts cell counts into cell offsets. Each cell's offset
 * indicates where its particles start in the sorted output array.
 *
 * ALGORITHM: Sequential exclusive scan (single-threaded for correctness)
 * - Simple: offset[0] = 0, offset[i] = offset[i-1] + count[i-1]
 * - Works for any grid size up to buffer limits
 *
 * PERFORMANCE NOTE:
 * Sequential scan is O(n) on a single GPU thread. For a 256x256 grid (65536 cells),
 * this is suboptimal but correct. A parallel Blelloch scan would be faster but
 * requires careful workgroup memory management (max 16KB = 4096 u32s).
 *
 * MEMORY LAYOUT:
 * - data (binding 1): Input cell counts (read-only for this algorithm)
 * - offsets (binding 2): Output exclusive prefix sum
 *
 * BINDING MANIFEST:
 * ┌─────────┬──────────────────────────┬─────────────────┬────────┐
 * │ Binding │ Shader Type              │ JS Buffer       │ Access │
 * ├─────────┼──────────────────────────┼─────────────────┼────────┤
 * │ 0       │ uniform ScanParams       │ scanParams      │ read   │
 * │ 1       │ storage array<u32>       │ gridCounts      │ read   │
 * │ 2       │ storage array<u32>       │ gridOffsets     │ write  │
 * └─────────┴──────────────────────────┴─────────────────┴────────┘
 */

struct ScanParams {
  numCells: u32,        // Total number of grid cells (gridW * gridH)
  padding0: u32,
  padding1: u32,
  padding2: u32,
};

@group(0) @binding(0) var<uniform> params: ScanParams;
@group(0) @binding(1) var<storage, read> data: array<u32>;      // cellCounts (read-only)
@group(0) @binding(2) var<storage, read_write> offsets: array<u32>; // cellOffsets (output)

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  // Single-threaded sequential exclusive prefix sum
  // Only thread 0 does the work
  if (global_id.x != 0u) {
    return;
  }

  let n = params.numCells;

  // Exclusive scan: offsets[i] = sum of data[0..i-1]
  var runningSum: u32 = 0u;

  for (var i: u32 = 0u; i < n; i++) {
    offsets[i] = runningSum;
    runningSum += data[i];
  }
}
