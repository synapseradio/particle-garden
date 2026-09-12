// =============================================================================
// MODULE: lr_grid
// =============================================================================
// The long-range mesh's grid contract, decided once: the toroidal wrap, the
// row-major cell index over the LIVE width, the species stride, and the
// cloud-in-cell assignment the deposit writes with and the force reads with.
// Every shader in the chain imports this rather than spelling its own, so the
// mesh's addressing is one decision rather than an agreement between files.
//
// Used by: lr-deposit, lr-fft-rows, lr-fft-cols, lr-kernel, lr-force.
//
// NOTHING HERE IS A COMPILE-TIME SIZE. field_grid can bake its dimensions in
// because the chemical field has one; this mesh's size is a control, so every
// function takes the live dimensions from the LrParams uniform its caller
// binds. The allocation behind them is the ceiling in memory_layout, and the
// tail past the live region is never read.
//
// Mirrors src/long_range_core.nim (lrWrapCell, lrAssign, lrSamplePotential),
// which tests/test_long_range_core.nim measures. Change one side and the other
// in the same diff; the pairing is held by review.

//! import lr_params

// Mirrors long_range_core.lrWrapCell per axis. Floor-mod, because WGSL's `%`
// truncates: the single-mod spelling `(cell + dims) % dims` survives only one
// span of negativity, while this lands every integer coordinate in range at
// any span.
fn lrWrapCell(cell: vec2<i32>, dims: vec2<i32>) -> vec2<i32> {
  return ((cell % dims) + dims) % dims;
}

// Row-major linear index into one species' slice of the mesh, over the LIVE
// width. The deposit writes and the force reads through this one function, so
// the two sides cannot disagree on addressing.
fn lrCellIndex(cell: vec2<i32>, gridW: u32) -> u32 {
  return u32(cell.y) * gridW + u32(cell.x);
}

// Where a species' slice starts. The stride is the LIVE cell count, not the
// allocated one, which is what keeps the used region compact at every mesh
// size.
fn lrSpeciesBase(species: u32, params: LrParams) -> u32 {
  return species * params.gridW * params.gridH;
}

// One particle's cloud-in-cell footprint: the four cells whose centres bracket
// its position, already wrapped, and the bilinear weights that sum to one.
//
// CIC rather than nearest-cell because the force is a GRADIENT of this field,
// and nearest-cell assignment puts a step at every cell boundary — which in an
// instrument reads as particles falling into lanes spaced at the cell size.
//
// The force reads the SAME four cells with the SAME four weights. That pairing
// is what makes the population's impulses sum to the grid's own quantity, and
// so what makes momentum cancel exactly under a symmetric matrix.
struct LrAssignment {
  cells: vec4<u32>,    // (x0,y0), (x1,y0), (x0,y1), (x1,y1)
  weights: vec4<f32>,  // in the same order
};

fn lrAssign(pos: vec2<f32>, params: LrParams) -> LrAssignment {
  let dims = vec2<i32>(i32(params.gridW), i32(params.gridH));
  let cellSize = vec2<f32>(params.worldWidth / f32(params.gridW),
                           params.worldHeight / f32(params.gridH));
  // Cell centres sit at (i + 0.5) cells, so the four cells whose centres
  // bracket a position are found by shifting half a cell before the floor.
  let uv = pos / cellSize - vec2<f32>(0.5, 0.5);
  let base = vec2<i32>(floor(uv));
  let frac = uv - vec2<f32>(base);

  let low = lrWrapCell(base, dims);
  let high = lrWrapCell(base + vec2<i32>(1, 1), dims);

  var assignment: LrAssignment;
  assignment.cells = vec4<u32>(
    lrCellIndex(vec2<i32>(low.x, low.y), params.gridW),
    lrCellIndex(vec2<i32>(high.x, low.y), params.gridW),
    lrCellIndex(vec2<i32>(low.x, high.y), params.gridW),
    lrCellIndex(vec2<i32>(high.x, high.y), params.gridW));
  assignment.weights = vec4<f32>(
    (1.0 - frac.x) * (1.0 - frac.y),
    frac.x * (1.0 - frac.y),
    (1.0 - frac.x) * frac.y,
    frac.x * frac.y);
  return assignment;
}

// A bin index folded into [-extent/2, extent/2): the signed wavenumber index
// the bin stands for. Bins above the half point are the negative frequencies,
// not high positive ones.
fn lrFoldBin(index: u32, extent: u32) -> f32 {
  if (index >= extent / 2u) {
    return f32(i32(index) - i32(extent));
  }
  return f32(index);
}

// The physical wavenumber a bin stands for, in radians per WORLD unit.
//
// THIS IS THE LANDMINE, not a detail. A power-of-two grid over a 16:9 world
// cannot have square cells — square would be 512 x 288, and 288 is not a power
// of two — so taking the wavenumber from the bin index instead of the world's
// extent stretches the force along one axis by the ratio of the cell's sides,
// with no other symptom and nothing else to catch it.
fn lrWavenumber(bin: vec2<u32>, params: LrParams) -> vec2<f32> {
  let TWO_PI: f32 = 6.283185307179586;
  let m = lrFoldBin(bin.x, params.gridW);
  let n = lrFoldBin(bin.y, params.gridH);
  return vec2<f32>(TWO_PI * m / params.worldWidth,
                   TWO_PI * n / params.worldHeight);
}

// G(k) = exp(-|k|^2 sigma^2 / 2) / (|k|^2 + 1/lambda^2) / (W*H), G(0) = 0.
//
// G(0) is exactly zero at every reach. In the unscreened limit that is forced,
// since the kernel has no finite value there; at a finite reach it is the
// choice that keeps the force answering density CONTRAST rather than absolute
// density, so adding particles uniformly moves nothing.
//
// The inverse transform's 1/(W*H) rides here rather than in a pass of its own,
// where a multiply already happens.
fn lrKernel(k: vec2<f32>, params: LrParams) -> f32 {
  let kSq = dot(k, k);
  if (kSq == 0.0) {
    return 0.0;
  }
  return exp(-kSq * params.softening * params.softening * 0.5) *
    params.invCells / (kSq + params.invReachSq);
}
