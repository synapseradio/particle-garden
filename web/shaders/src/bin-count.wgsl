// =============================================================================
// BIN-COUNT: Count particles per cell using atomic increments (Pass 1)
// =============================================================================
//
// WHY THIS EXISTS:
// First pass of spatial hashing - counts how many particles fall into each grid
// cell. These counts feed into prefix sum to compute cell offsets for scattering.
//
// ALGORITHM:
// 1. Each thread processes one particle
// 2. Read particle position from AoS buffer
// 3. Compute cell index from position and grid dimensions
// 4. Clamp to grid bounds (handles edge cases)
// 5. Atomically increment cellCounts[cellIdx]
//
// BINDING MANIFEST:
// +-------+---------------------------+-----------------+--------+
// | Bind  | Shader Type               | JS Buffer       | Access |
// +-------+---------------------------+-----------------+--------+
// |   0   | uniform GridParams        | gridParams      | read   |
// |   1   | storage array<Particle>   | particles       | read   |
// |   2   | storage array<atomic<u32>>| cellCounts      | r/w    |
// +-------+---------------------------+-----------------+--------+
//
// THREAD MAPPING: One thread per particle (global_invocation_id.x = particleIdx)
// =============================================================================

//! import particle
//! import grid_params
//! import cell_index

@group(0) @binding(0) var<uniform> params: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read_write> cellCounts: array<atomic<u32>>;

@compute @workgroup_size(128)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let particleIdx = global_id.x;

  // Bounds check - return early if beyond particle count
  if (particleIdx >= params.particleCount) {
    return;
  }

  // Read particle position from AoS buffer
  let p = particles[particleIdx];

  // Compute cell index using shared function
  let cellIdx = computeCellIndex(p.pos, params);

  // Atomic increment - this is the core counting operation
  atomicAdd(&cellCounts[cellIdx], 1u);
}
