/**
 * Pass 2c: Add block offsets to local prefix sums
 *
 * Each element needs the sum of all blocks before it added to its local offset.
 * This completes the global exclusive prefix sum.
 *
 * Final result: gridOffsets[i] = sum of gridCounts[0..i-1]
 */

//! import scan_params

@group(0) @binding(0) var<uniform> params: ScanParams;
@group(0) @binding(1) var<storage, read_write> offsets: array<u32>;     // Local offsets → final offsets
@group(0) @binding(2) var<storage, read> blockOffsets: array<u32>;      // Scanned block totals

@compute @workgroup_size({{WORKGROUP_SIZE}})
fn main(
  @builtin(global_invocation_id) globalId: vec3<u32>,
  @builtin(workgroup_id) workgroupId: vec3<u32>
) {
  let gid = globalId.x;

  if (gid >= params.numCells) {
    return;
  }

  let blockIdx = workgroupId.x;
  offsets[gid] = offsets[gid] + blockOffsets[blockIdx];
}
