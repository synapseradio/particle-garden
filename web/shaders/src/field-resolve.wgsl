// =============================================================================
// FIELD RESOLVE: fold the particle deposits into the field texture
// =============================================================================
//
// WHY THIS EXISTS:
// field-deposit.wgsl accumulates each particle's inhibitor contribution into an
// integer atomic buffer. This 2D per-cell pass decodes that buffer back to f32,
// adds it onto the field's inhibitor channel, and zeroes the buffer for next
// frame. It is the bridge between the particle world (a buffer indexed by cell)
// and the field world (a storage texture).
//
// PING-PONG / STABLE FRONT:
// The field lives in two rgba16float textures. fieldA is the FIXED front the render
// and force passes always sample; fieldB trails it by one substep. A half-float
// texture cannot be a read_write storage texture (only r32* can), so resolve cannot update
// a texture in place. Instead it reads the trailing copy (srcField = fieldB,
// approximately live) and writes the front (dstField = fieldA). The eight rd-step
// substeps that follow ping-pong A<->B and end back on A, so fieldA holds the live
// field at frame end and fieldB trails it — the invariant this pass relies on.
// Folding deposits onto a one-substep-old snapshot is negligible for the pattern.
//
// CHANNELS: field texture .r = activator (A), .g = inhibitor (B).
//
// The per-particle deposit amount was already applied (fixed-point) in
// field-deposit.wgsl, so resolve needs no FieldParams uniform — it just decodes
// and adds. Binding one anyway would be pruned from the auto layout as unused.
//
// BINDING MANIFEST:
// +-------+---------------------------------------+--------------+--------+
// | Bind  | Shader Type                           | Resource     | Access |
// +-------+---------------------------------------+--------------+--------+
// |   0   | texture_2d<f32>                       | fieldB view  | sample |
// |   1   | texture_storage_2d<rgba16float,write> | fieldA view  | write  |
// |   2   | storage atomic<i32>                   | fieldDeposit | r/w    |
// +-------+---------------------------------------+--------------+--------+
// =============================================================================

//! import fixed_point

@group(0) @binding(0) var srcField: texture_2d<f32>;
// rgba16float, not rg16float: WebGPU does not permit rg16float as a write-only
// storage texture (it is not in the storage-capable format list). rgba16float is
// the nearest storage+sampled+filterable half-float format; only .rg is used
// (.r = activator, .g = inhibitor), .ba are ignored padding.
@group(0) @binding(1) var dstField: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var<storage, read_write> fieldDeposit: array<atomic<i32>>;

const FIELD_W: u32 = {{FIELD_W}}u;
const FIELD_H: u32 = {{FIELD_H}}u;

@compute @workgroup_size({{WORKGROUP_SIZE_FIELD_X}}, {{WORKGROUP_SIZE_FIELD_Y}}, 1)
fn resolveField(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let cellX = globalId.x;
  let cellY = globalId.y;
  if (cellX >= FIELD_W || cellY >= FIELD_H) {
    return;
  }

  let coord = vec2<i32>(i32(cellX), i32(cellY));
  let current = textureLoad(srcField, coord, 0).xy;  // .x = activator, .y = inhibitor

  let cellIndex = cellY * FIELD_W + cellX;
  let depositA = f32(atomicLoad(&fieldDeposit[cellIndex * 2u])) * INV_FIXED_POINT_SCALE;
  let depositB = f32(atomicLoad(&fieldDeposit[cellIndex * 2u + 1u])) * INV_FIXED_POINT_SCALE;

  // Reset the deposit buffer for next frame. One thread owns each cell, so a
  // plain store is race-free (no encoder-level clearBuffer needed — the same
  // self-reset convention forces.wgsl uses for the velocity/density deltas).
  atomicStore(&fieldDeposit[cellIndex * 2u], 0);
  atomicStore(&fieldDeposit[cellIndex * 2u + 1u], 0);

  let updated = current + vec2<f32>(depositA, depositB);
  textureStore(dstField, coord, vec4<f32>(updated, 0.0, 1.0));
}
