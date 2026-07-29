// =============================================================================
// MODULE: field_grid
// =============================================================================
// The reaction-diffusion field's grid contract, decided once: dimensions,
// toroidal wrap, world-to-cell mapping, row-major cell index, and the
// central-difference inhibitor gradient. Every shader that touches the field
// imports this instead of spelling its own, so the field's edge behaviour is
// one decision rather than an agreement between files.
//
// Used by: fade, render, rd-step, field-force, field-deposit, field-resolve,
// field-seed.
//
// The field's ping-pong textures are rgba16float: WebGPU does not permit
// rg16float as a write-only storage texture (not in the storage-capable
// format list), and rgba16float is the nearest storage+sampled+filterable
// half-float format. Only .rg is used — .r = activator, .g = inhibitor —
// .ba are reserved padding.

// One fact, two spellings for WGSL's sake: compute passes bounds-check and
// index with u32 invocation ids, everything else does signed cell arithmetic.
// Both derive from the same {{FIELD_W}}/{{FIELD_H}} substitution.
const FIELD_DIMS: vec2<i32> = vec2<i32>({{FIELD_W}}, {{FIELD_H}});
const FIELD_DIMS_U: vec2<u32> = vec2<u32>({{FIELD_W}}u, {{FIELD_H}}u);

// Mirrors field_core.fieldWrap per axis. Floor-mod, because WGSL's `%`
// truncates: the single-mod spelling `(cell + dims) % dims` survives only one
// span of negativity, while this lands every integer coordinate in range at
// any span.
fn fieldWrap(cell: vec2<i32>) -> vec2<i32> {
  return ((cell % FIELD_DIMS) + FIELD_DIMS) % FIELD_DIMS;
}

// World position -> field cell. The field spans the full world rect, so this
// is a straight normalize-and-scale; the clamp absorbs a position sitting
// exactly on the far edge. A position that can leave the world rect
// (reprojection) instead floors into a cell and wraps — see fade.wgsl.
fn fieldCellFor(pos: vec2<f32>, worldSize: vec2<f32>) -> vec2<i32> {
  let cellF = pos / worldSize * vec2<f32>(FIELD_DIMS);
  return clamp(vec2<i32>(cellF), vec2<i32>(0), FIELD_DIMS - vec2<i32>(1));
}

// Row-major linear index into the per-cell deposit buffer. field-deposit
// writes and field-resolve reads through this one function, so the two sides
// cannot disagree on addressing.
fn fieldCellIndex(cell: vec2<i32>) -> u32 {
  return u32(cell.y) * FIELD_DIMS_U.x + u32(cell.x);
}

// The inhibitor channel (.g) at a wrapped cell, so a read across the seam is
// continuous on the torus.
fn fieldInhibitorAt(field: texture_2d<f32>, cell: vec2<i32>) -> f32 {
  return textureLoad(field, fieldWrap(cell), 0).y;
}

// Central-difference gradient of the inhibitor about a cell. +y is south,
// matching the texture's row order.
fn fieldInhibitorGradient(field: texture_2d<f32>, cell: vec2<i32>) -> vec2<f32> {
  let east = fieldInhibitorAt(field, cell + vec2<i32>(1, 0));
  let west = fieldInhibitorAt(field, cell - vec2<i32>(1, 0));
  let south = fieldInhibitorAt(field, cell + vec2<i32>(0, 1));
  let north = fieldInhibitorAt(field, cell - vec2<i32>(0, 1));
  return vec2<f32>((east - west) * 0.5, (south - north) * 0.5);
}
