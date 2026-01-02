// =============================================================================
// MODULE: cell_index
// =============================================================================
// Cell index computation for spatial hashing.
//
// Used by: bin-count, bin-scatter (and potentially forces for toroidal wrapping)
//
// ALGORITHM:
// 1. Divide world space by grid dimensions to get cell size
// 2. Floor particle position to cell coordinates
// 3. Clamp to grid bounds (handles out-of-bounds particles)
// 4. Compute linear index: cellY * gridW + cellX
// =============================================================================

//! import grid_params

// Compute linear cell index from particle position
fn computeCellIndex(pos: vec2<f32>, params: GridParams) -> u32 {
  // Inverse cell dimensions (world-to-cell transform)
  let invCellW = f32(params.gridW) / params.canvasWidth;
  let invCellH = f32(params.gridH) / params.canvasHeight;

  // Compute cell coordinates
  var cx = u32(pos.x * invCellW);
  var cy = u32(pos.y * invCellH);

  // Clamp to grid bounds (handles edge cases)
  if (cx >= params.gridW) {
    cx = params.gridW - 1u;
  }
  if (cy >= params.gridH) {
    cy = params.gridH - 1u;
  }

  // Linear index (row-major order)
  return cy * params.gridW + cx;
}
