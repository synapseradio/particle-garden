// =============================================================================
// RD STEP: one Gray-Scott reaction-diffusion substep
// =============================================================================
//
// WHY THIS EXISTS:
// Advances the two-channel field one explicit-Euler Gray-Scott step. The frame runs
// RD_STEPS_PER_FRAME of these per rendered frame, alternating orientation because a
// shader cannot read and write the same storage texture in one dispatch. The two
// orientations are named for their DESTINATION: ToFront reads fieldB and writes
// fieldA, ToTrail reads fieldA and writes fieldB. They are the SAME pipeline (this
// file, entry rdStep); the executor gives each its own bind group with the
// source/destination textures swapped.
//
// The sequence starts ToFront, because field-resolve.wgsl has already performed the
// frame's first swap (front -> trail), and must END ToFront, because fieldA is what
// field-force.wgsl, the renderer, and the next frame's resolve all read. That is why
// src/field_core.nim statically asserts RD_STEPS_PER_FRAME is odd.
//
// THE MATH MIRRORS field_core.grayScottStep EXACTLY (the natively-tested authority):
//   reaction = A * B^2
//   A' = A + dt*(Da*lapA - reaction + feed*(1 - A))
//   B' = B + dt*(Db*lapB + reaction - (feed + kill)*B)
// with the normalized 9-point Laplacian from field_core.laplacian9:
//   lap = 0.2*(north + south + east + west) + 0.05*(ne + nw + se + sw) - center
// The -1 center weight keeps explicit Euler stable at Da=1, dt=1; the -4-center
// 5-point form diverges at these rates.
// Neighbor reads wrap toroidally, matching the wrapping particle world.
//
// REACTION SEAM: which reaction runs is read from the ReactionParams uniform, as
// a value from the named constant set below. It arrived as a pipeline-override
// constant, which meant selecting a reaction required creating a second pipeline;
// reading it from a uniform makes a second reaction a new branch in this file and
// nothing else. RESERVED, NOT DELIVERED — REACTION_GRAY_SCOTT is the only value
// any code writes, and the other ReactionParams members are untouched by it.
//
// CHANNELS: .r = activator (A), .g = inhibitor (B). The .b and .a channels are
// RESERVED STATE CHANNELS for a multi-channel reaction and are carried through
// untouched — see field-resolve.wgsl for why they cost nothing.
//
// BINDING MANIFEST:
// +-------+-------------------------------------+----------------+--------+
// | Bind  | Shader Type                         | Resource       | Access |
// +-------+-------------------------------------+----------------+--------+
// |   0   | texture_2d<f32>                     | src view       | sample |
// |   1   | texture_storage_2d<rgba16float,write> | dst view     | write  |
// |   2   | uniform FieldParams                 | fieldParams    | read   |
// |   3   | uniform ReactionParams              | reactionParams | read   |
// +-------+-------------------------------------+----------------+--------+
// =============================================================================

//! import field_params
//! import reaction_params

@group(0) @binding(0) var srcField: texture_2d<f32>;
// rgba16float (see field-resolve.wgsl): rg16float is not a storage-capable
// format in WebGPU. Only .rg is meaningful (.r = activator, .g = inhibitor).
@group(0) @binding(1) var dstField: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var<uniform> params: FieldParams;
@group(0) @binding(3) var<uniform> reaction: ReactionParams;

// The reaction constant set. Gray-Scott is the only member with an
// implementation; a second reaction becomes a second constant and a second
// branch in rdStep, without touching a binding, a layout, or the manifest.
const REACTION_GRAY_SCOTT: u32 = 0u;

const FIELD_DIMS: vec2<i32> = vec2<i32>({{FIELD_W}}, {{FIELD_H}});

fn loadCellFull(coord: vec2<i32>) -> vec4<f32> {
  // Toroidal wrap so the field is seamless, matching the wrapping world.
  let wrapped = (coord + FIELD_DIMS) % FIELD_DIMS;
  return textureLoad(srcField, wrapped, 0);
}

fn loadCell(coord: vec2<i32>) -> vec2<f32> {
  // Only the reacting channels. Neighbors contribute to the Laplacian and
  // nothing else, so their reserved channels are never read.
  return loadCellFull(coord).xy;
}

@compute @workgroup_size({{WORKGROUP_SIZE_FIELD_X}}, {{WORKGROUP_SIZE_FIELD_Y}}, 1)
fn rdStep(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let cellX = i32(globalId.x);
  let cellY = i32(globalId.y);
  if (cellX >= FIELD_DIMS.x || cellY >= FIELD_DIMS.y) {
    return;
  }

  let centerFull = loadCellFull(vec2<i32>(cellX, cellY));
  let center = centerFull.xy;
  let north = loadCell(vec2<i32>(cellX, cellY - 1));
  let south = loadCell(vec2<i32>(cellX, cellY + 1));
  let east = loadCell(vec2<i32>(cellX + 1, cellY));
  let west = loadCell(vec2<i32>(cellX - 1, cellY));
  let ne = loadCell(vec2<i32>(cellX + 1, cellY - 1));
  let nw = loadCell(vec2<i32>(cellX - 1, cellY - 1));
  let se = loadCell(vec2<i32>(cellX + 1, cellY + 1));
  let sw = loadCell(vec2<i32>(cellX - 1, cellY + 1));

  // Normalized 9-point Laplacian per channel (field_core.laplacian9), computed
  // for both activator (.x) and inhibitor (.y) at once.
  let laplacian = 0.2 * (north + south + east + west)
    + 0.05 * (ne + nw + se + sw) - center;

  let activator = center.x;
  let inhibitor = center.y;

  var nextA = activator;
  var nextB = inhibitor;

  if (u32(reaction.reactionKind) == REACTION_GRAY_SCOTT) {
    // Gray-Scott — mirrors field_core.grayScottStep.
    let reactionTerm = activator * inhibitor * inhibitor;
    nextA = activator + params.deltaT * (
      params.diffusionA * laplacian.x - reactionTerm + params.feed * (1.0 - activator));
    nextB = inhibitor + params.deltaT * (
      params.diffusionB * laplacian.y + reactionTerm - (params.feed + params.kill) * inhibitor);
  }

  // Reserved channels carried through, never overwritten with literals: a
  // multi-channel reaction needs them to survive every substep, and writing
  // constants here would erase them RD_STEPS_PER_FRAME times per frame.
  textureStore(dstField, vec2<i32>(cellX, cellY),
    vec4<f32>(nextA, nextB, centerFull.z, centerFull.w));
}
