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

// AoS Particle struct: 32 bytes, cache-aligned
// Two particles fit in one 64-byte CPU cache line
// Four particles fit in one 128-byte GPU cache line
struct Particle {
  pos: vec2<f32>,    // offset 0, size 8
  vel: vec2<f32>,    // offset 8, size 8
  species: u32,      // offset 16, size 4
  density: f32,      // offset 20, size 4
  _pad0: u32,        // offset 24, size 4 (alignment padding)
  _pad1: u32,        // offset 28, size 4 (alignment padding)
}

struct GridParams {
  gridW: u32,           // Grid width in cells
  gridH: u32,           // Grid height in cells
  canvasWidth: f32,     // World width in pixels
  canvasHeight: f32,    // World height in pixels
  particleCount: u32,   // Number of active particles
  padding0: u32,        // Align to 16 bytes
  padding1: u32,
  padding2: u32,
};

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

  // Compute cell coordinates using floating-point grid transform
  let invCellW = f32(params.gridW) / params.canvasWidth;
  let invCellH = f32(params.gridH) / params.canvasHeight;

  var cx = u32(p.pos.x * invCellW);
  var cy = u32(p.pos.y * invCellH);

  // Clamp to grid bounds (handles out-of-bounds particles gracefully)
  if (cx >= params.gridW) {
    cx = params.gridW - 1u;
  }
  if (cy >= params.gridH) {
    cy = params.gridH - 1u;
  }

  // Compute linear cell index
  let cellIdx = cy * params.gridW + cx;

  // Atomic increment - this is the core counting operation
  atomicAdd(&cellCounts[cellIdx], 1u);
}
