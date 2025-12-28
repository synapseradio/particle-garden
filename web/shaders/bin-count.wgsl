/**
 * Pass 1: Count particles per cell using atomic increments.
 *
 * Each thread processes one particle:
 * 1. Read particle position from source buffers (SoA layout)
 * 2. Compute cell index (cx, cy) from position and grid dimensions
 * 3. Clamp to grid bounds
 * 4. Atomically increment cellCounts[cy * gridW + cx]
 *
 * This shader must be dispatched with workgroup size matching particle count
 * (rounded up to multiple of 64 for typical GPU workgroup size).
 *
 * Memory layout (Struct-of-Arrays):
 * - px: Float32Array with [x0, x1, x2, ...]
 * - py: Float32Array with [y0, y1, y2, ...]
 * - cellCounts: Uint32Array with [count0, count1, ...] for each grid cell
 */

struct GridParams {
  gridW: u32,           // Grid width in cells
  gridH: u32,           // Grid height in cells
  canvasWidth: f32,     // Canvas width in pixels
  canvasHeight: f32,    // Canvas height in pixels
  particleCount: u32,   // Number of active particles
  padding0: u32,        // Align to 16 bytes
  padding1: u32,
  padding2: u32,
};

@group(0) @binding(0) var<uniform> params: GridParams;
@group(0) @binding(1) var<storage, read> px: array<f32>;
@group(0) @binding(2) var<storage, read> py: array<f32>;
@group(0) @binding(3) var<storage, read_write> cellCounts: array<atomic<u32>>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let particleIdx = global_id.x;

  // Bounds check - return early if beyond particle count
  if (particleIdx >= params.particleCount) {
    return;
  }

  // Read particle position (SoA layout)
  let posX = px[particleIdx];
  let posY = py[particleIdx];

  // Compute cell coordinates using floating-point grid transform
  let invCellW = f32(params.gridW) / params.canvasWidth;
  let invCellH = f32(params.gridH) / params.canvasHeight;

  var cx = u32(posX * invCellW);
  var cy = u32(posY * invCellH);

  // Clamp to grid bounds (matches grid.js behavior for out-of-bounds particles)
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
