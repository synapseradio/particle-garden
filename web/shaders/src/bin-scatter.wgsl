// =============================================================================
// BIN-SCATTER: Physical Scatter of Entire Particles (Pass 3 - Unified AoS)
// =============================================================================
//
// WHY THIS EXISTS (Cache Optimization):
// The forces pass needs to iterate through neighbors in spatial order for cache
// efficiency. This shader PHYSICALLY COPIES entire particle structs into sorted
// buffers, enabling sequential memory access patterns in the forces pass.
// =============================================================================

//! import particle
//! import grid_params
//! import cell_index

@group(0) @binding(0) var<uniform> params: GridParams;
@group(0) @binding(1) var<storage, read> srcParticles: array<Particle>;
@group(0) @binding(2) var<storage, read_write> dstParticlesSorted: array<Particle>;
@group(0) @binding(3) var<storage, read_write> sortedIndices: array<u32>;
@group(0) @binding(4) var<storage, read_write> reverseIndices: array<u32>;
@group(0) @binding(5) var<storage, read_write> fillOffsets: array<atomic<u32>>;

@compute @workgroup_size({{WORKGROUP_SIZE}})
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let originalIdx = global_id.x;

  if (originalIdx >= params.particleCount) {
    return;
  }

  let p = srcParticles[originalIdx];

  let cellIdx = computeCellIndex(p.pos, params);

  // fillOffsets was initialized from gridOffsets (exclusive prefix sum)
  let dstIdx = atomicAdd(&fillOffsets[cellIdx], 1u);

  dstParticlesSorted[dstIdx] = p;

  // sortedIndices consumed by integrate.wgsl for write-back.
  sortedIndices[dstIdx] = originalIdx;
  // reverseIndices consumed by forces.wgsl for density write-back.
  reverseIndices[originalIdx] = dstIdx;
}
