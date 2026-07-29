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
// and force passes always sample; fieldB trails it. A half-float texture cannot be a
// read_write storage texture (only r32* can), so resolve cannot update a texture in
// place — it reads one and writes the other.
//
// RESOLVE IS THE FRAME'S FIRST PING-PONG SWAP. It reads the front (srcField =
// fieldA, holding last frame's final substep) and writes the trail (dstField =
// fieldB). The rd-step substeps that follow start by writing back to fieldA and
// alternate from there, so an ODD substep count is what lands the live field back
// on fieldA at frame end. src/field_core.nim asserts that parity statically; an
// even count would end on fieldB, where nothing reads it, throwing away one full
// substep every frame.
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
// |   0   | texture_2d<f32>                       | fieldA view  | sample |
// |   1   | texture_storage_2d<rgba16float,write> | fieldB view  | write  |
// |   2   | storage atomic<i32>                   | fieldDeposit | r/w    |
// |   3   | storage atomic<u32>                   | aliveCells   | r/w    |
// +-------+---------------------------------------+--------------+--------+
//
// Binding 3: one u32 census the frame clears at its top; each cell above the
// aliveness threshold adds one. Written here because this is the per-cell
// pass that already reads the resolved inhibitor. One frame stale.
// =============================================================================

//! import fixed_point
//! import field_grid

@group(0) @binding(0) var srcField: texture_2d<f32>;
// rgba16float, not rg16float: WebGPU does not permit rg16float as a write-only
// storage texture (it is not in the storage-capable format list). rgba16float is
// the nearest storage+sampled+filterable half-float format; only .rg is used
// (.r = activator, .g = inhibitor), .ba are ignored padding.
@group(0) @binding(1) var dstField: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var<storage, read_write> fieldDeposit: array<atomic<i32>>;
@group(0) @binding(3) var<storage, read_write> aliveCells: array<atomic<u32>>;

const RD_DEPOSIT_CELL_MAX: f32 = {{RD_DEPOSIT_CELL_MAX}};
const RD_DEPOSIT_FRAME_SCALE: f32 = {{RD_DEPOSIT_FRAME_SCALE}};
const FIELD_ALIVE_THRESHOLD: f32 = {{FIELD_ALIVE_THRESHOLD}};

@compute @workgroup_size({{WORKGROUP_SIZE_FIELD_X}}, {{WORKGROUP_SIZE_FIELD_Y}}, 1)
fn resolveField(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let cellX = globalId.x;
  let cellY = globalId.y;
  if (cellX >= FIELD_DIMS_U.x || cellY >= FIELD_DIMS_U.y) {
    return;
  }

  let coord = vec2<i32>(i32(cellX), i32(cellY));
  // .x = activator, .y = inhibitor, .zw = reserved state channels.
  let current = textureLoad(srcField, coord, 0);

  // One i32 per cell: fieldCellIndex is the same addressing field-deposit.wgsl
  // writes with, shared through field_grid so the two sides cannot disagree.
  // See that file for what a second channel would cost on both sides.
  let cellIndex = fieldCellIndex(coord);
  // Mirrors field_core.resolveCellDeposit in the same order: cap, scale,
  // fold, floor. RD_DEPOSIT_MAX bounds one particle; nothing bounds how many
  // share a cell, so an input that gathers a crowd into one place drives this
  // past the range explicit Euler integrates stably. The cap is on what
  // arrives, never on what the reaction produces. The frame scale holds the
  // deposit rate per FIELD STEP invariant under RD_STEPS_PER_FRAME — the fold
  // lands once per frame while the reaction runs 1 + RD_STEPS_PER_FRAME
  // steps, so an unscaled fold would strengthen deposits whenever the substep
  // count fell.
  let depositB = RD_DEPOSIT_FRAME_SCALE * min(
    f32(atomicLoad(&fieldDeposit[cellIndex])) * INV_FIXED_POINT_SCALE,
    RD_DEPOSIT_CELL_MAX);

  // This pass is the deposit buffer's single reset owner: it consumes each
  // cell and zeroes it in the same invocation. One thread owns each cell, so a
  // plain store is race-free and no frame-level clear is needed.
  atomicStore(&fieldDeposit[cellIndex], 0);

  // RESERVED STATE CHANNELS. The ping-pong textures are rgba16float because
  // WebGPU does not permit rg16float as a write-only storage format, so .b and
  // .a are already allocated and already paid for. They are carried through
  // rather than overwritten with literals, so a future multi-channel reaction
  // can occupy them without a format change. Nothing reads or writes them
  // meaningfully today — this reserves an addressable slot, nothing more.
  // Floors the fold at 0.0, mirroring field_core.resolveCellDeposit in the
  // same order (cap, fold, floor): the cap above bounds excess only from
  // above, so enough eroders sharing a cell still drive this negative
  // without the floor.
  let resolvedInhibitor = max(0.0, current.y + depositB);
  textureStore(dstField, coord,
    vec4<f32>(current.x, resolvedInhibitor, current.z, current.w));

  if (resolvedInhibitor > FIELD_ALIVE_THRESHOLD) {
    atomicAdd(&aliveCells[0], 1u);
  }
}
