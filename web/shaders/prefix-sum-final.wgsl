/**
 * Pass 2c: Add block offsets to local prefix sums
 *
 * Each element needs the sum of all blocks before it added to its local offset.
 * This completes the global exclusive prefix sum.
 *
 * Final result: gridOffsets[i] = sum of gridCounts[0..i-1]
 *
 * BINDING MANIFEST:
 * ┌─────────┬──────────────────────────┬─────────────────┬────────┐
 * │ Binding │ Shader Type              │ JS Buffer       │ Access │
 * ├─────────┼──────────────────────────┼─────────────────┼────────┤
 * │ 0       │ uniform ScanParams       │ scanParams      │ read   │
 * │ 1       │ storage array<u32>       │ gridOffsets     │ r/w    │
 * │ 2       │ storage array<u32>       │ blockOffsets    │ read   │
 * └─────────┴──────────────────────────┴─────────────────┴────────┘
 */

struct ScanParams {
  numCells: u32,        // Total number of grid cells (gridW * gridH)
  numBlocks: u32,       // Number of workgroups (ceil(numCells / 256))
  padding1: u32,
  padding2: u32,
};

@group(0) @binding(0) var<uniform> params: ScanParams;
@group(0) @binding(1) var<storage, read_write> offsets: array<u32>;     // Local offsets → final offsets
@group(0) @binding(2) var<storage, read> blockOffsets: array<u32>;      // Scanned block totals

@compute @workgroup_size(256)
fn main(
  @builtin(global_invocation_id) globalId: vec3<u32>,
  @builtin(workgroup_id) workgroupId: vec3<u32>
) {
  let gid = globalId.x;

  if (gid >= params.numCells) {
    return;
  }

  // Add the block's offset to this element's local offset
  // blockOffsets[blockIdx] = sum of all blocks before blockIdx
  let blockIdx = workgroupId.x;
  offsets[gid] = offsets[gid] + blockOffsets[blockIdx];
}
