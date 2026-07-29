//! import grid_params

fn computeCellIndex(pos: vec2<f32>, params: GridParams) -> u32 {
  let invCellW = f32(params.gridW) / params.canvasWidth;
  let invCellH = f32(params.gridH) / params.canvasHeight;

  var cx = u32(pos.x * invCellW);
  var cy = u32(pos.y * invCellH);

  if (cx >= params.gridW) {
    cx = params.gridW - 1u;
  }
  if (cy >= params.gridH) {
    cy = params.gridH - 1u;
  }

  return cy * params.gridW + cx;
}
