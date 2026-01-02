// =============================================================================
// BIN-SCATTER: Physical Scatter of Entire Particles (Pass 3 - Unified AoS)
// =============================================================================
//
// WHY THIS EXISTS (Cache Optimization):
// The forces pass needs to iterate through neighbors in spatial order for cache
// efficiency. This shader PHYSICALLY COPIES entire particle structs into sorted
// buffers, enabling sequential memory access patterns in the forces pass.
//
// AoS BENEFIT:
// With SoA (Struct of Arrays), this had to be split into two passes due to
// WebGPU's 8-storage-buffer limit. With AoS, we scatter the entire Particle
// struct in one pass - simpler code and fewer dispatches.
//
// ALGORITHM:
// 1. Each thread processes one particle by its original index
// 2. Read entire Particle struct from unsorted source buffer
// 3. Compute cell index from position (same algorithm as bin-count.wgsl)
// 4. Atomically increment fillOffsets[cell] to allocate a unique write slot
// 5. Write entire Particle struct to sorted buffer at the allocated slot
// 6. Build BOTH index mappings:
//    - sortedIndices[dstIdx] = originalIdx (sorted -> original)
//    - reverseIndices[originalIdx] = dstIdx (original -> sorted)
//
// BINDING MANIFEST:
// +-------+---------------------------+------------------+--------+
// | Bind  | Shader Type               | JS Buffer        | Access |
// +-------+---------------------------+------------------+--------+
// |   0   | uniform GridParams        | gridParams       | read   |
// |   1   | storage array<Particle>   | srcParticles     | read   |
// |   2   | storage array<Particle>   | dstParticlesSorted| write |
// |   3   | storage array<u32>        | sortedIndices    | write  |
// |   4   | storage array<u32>        | reverseIndices   | write  |
// |   5   | storage array<atomic<u32>>| fillPointers     | r/w    |
// +-------+---------------------------+------------------+--------+
// TOTAL: 5 storage buffers (well under 8-buffer limit)
//
// THREAD MAPPING: One thread per particle (global_invocation_id.x = originalIdx)
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

@compute @workgroup_size(128)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let originalIdx = global_id.x;

  // Bounds check
  if (originalIdx >= params.particleCount) {
    return;
  }

  // Read entire particle from unsorted source buffer
  let p = srcParticles[originalIdx];

  // Compute cell index using shared function
  let cellIdx = computeCellIndex(p.pos, params);

  // Atomically allocate write slot within this cell's range
  // fillOffsets was initialized from gridOffsets (exclusive prefix sum)
  let dstIdx = atomicAdd(&fillOffsets[cellIdx], 1u);

  // Physical scatter: copy entire particle struct to sorted buffer
  // This enables sequential memory access in forces pass (L1 cache hits)
  dstParticlesSorted[dstIdx] = p;

  // Build BOTH index mappings:
  // sortedIndices: sorted -> original (used by integrate to write back)
  sortedIndices[dstIdx] = originalIdx;
  // reverseIndices: original -> sorted (used by forces for density writeback)
  reverseIndices[originalIdx] = dstIdx;
}
