// =============================================================================
// RD STEP: one Gray-Scott reaction-diffusion substep
// =============================================================================
//
// WHY THIS EXISTS:
// Advances the two-channel field one explicit-Euler Gray-Scott step. The frame
// runs eight of these per rendered frame, alternating orientation (Forward reads
// fieldA writes fieldB, Reverse reads fieldB writes fieldA) because a shader cannot
// read and write the same storage texture in one dispatch. Forward and Reverse are
// the SAME pipeline (this file, entry rdStep); the executor gives each its own bind
// group with the source/destination textures swapped.
//
// THE MATH MIRRORS field_core.grayScottStep EXACTLY (the natively-tested authority):
//   reaction = A * B^2
//   A' = A + dt*(Da*lapA - reaction + feed*(1 - A))
//   B' = B + dt*(Db*lapB + reaction - (feed + kill)*B)
// with the 5-point Laplacian from field_core.laplacian5:
//   lap = north + south + east + west - 4*center
// Neighbor reads wrap toroidally, matching the wrapping particle world.
//
// REACTION SEAM: reactionKind is a pipeline-override constant (default 0 =
// Gray-Scott). It is the seam a future Lenia reaction slots into without touching
// this file's bindings — FieldParams has no reactionKind field and its layout is
// fixed, so the selector lives here as an override rather than a uniform member.
//
// CHANNELS: .r = activator (A), .g = inhibitor (B).
//
// BINDING MANIFEST:
// +-------+-------------------------------------+-------------+--------+
// | Bind  | Shader Type                         | Resource    | Access |
// +-------+-------------------------------------+-------------+--------+
// |   0   | texture_2d<f32>                     | src view    | sample |
// |   1   | texture_storage_2d<rg16float,write> | dst view    | write  |
// |   2   | uniform FieldParams                 | fieldParams | read   |
// +-------+-------------------------------------+-------------+--------+
// =============================================================================

//! import field_params

@group(0) @binding(0) var srcField: texture_2d<f32>;
// rgba16float (see field-resolve.wgsl): rg16float is not a storage-capable
// format in WebGPU. Only .rg is meaningful (.r = activator, .g = inhibitor).
@group(0) @binding(1) var dstField: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var<uniform> params: FieldParams;

// reactionKind: 0 = Gray-Scott (the only reaction implemented this stage). A
// future Lenia reaction is another value; the pipeline is created with the
// default, so behavior is unchanged until a caller overrides it.
override reactionKind: u32 = 0u;

const FIELD_DIMS: vec2<i32> = vec2<i32>({{FIELD_W}}, {{FIELD_H}});

fn loadCell(coord: vec2<i32>) -> vec2<f32> {
  // Toroidal wrap so the field is seamless, matching the wrapping world.
  let wrapped = (coord + FIELD_DIMS) % FIELD_DIMS;
  return textureLoad(srcField, wrapped, 0).xy;
}

@compute @workgroup_size({{WORKGROUP_SIZE_FIELD_X}}, {{WORKGROUP_SIZE_FIELD_Y}}, 1)
fn rdStep(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let cellX = i32(globalId.x);
  let cellY = i32(globalId.y);
  if (cellX >= FIELD_DIMS.x || cellY >= FIELD_DIMS.y) {
    return;
  }

  let center = loadCell(vec2<i32>(cellX, cellY));
  let north = loadCell(vec2<i32>(cellX, cellY - 1));
  let south = loadCell(vec2<i32>(cellX, cellY + 1));
  let east = loadCell(vec2<i32>(cellX + 1, cellY));
  let west = loadCell(vec2<i32>(cellX - 1, cellY));

  // 5-point Laplacian per channel (field_core.laplacian5), computed for both
  // activator (.x) and inhibitor (.y) at once.
  let laplacian = north + south + east + west - 4.0 * center;

  let activator = center.x;
  let inhibitor = center.y;

  var nextA = activator;
  var nextB = inhibitor;

  if (reactionKind == 0u) {
    // Gray-Scott — mirrors field_core.grayScottStep.
    let reaction = activator * inhibitor * inhibitor;
    nextA = activator + params.deltaT * (
      params.diffusionA * laplacian.x - reaction + params.feed * (1.0 - activator));
    nextB = inhibitor + params.deltaT * (
      params.diffusionB * laplacian.y + reaction - (params.feed + params.kill) * inhibitor);
  }

  textureStore(dstField, vec2<i32>(cellX, cellY), vec4<f32>(nextA, nextB, 0.0, 1.0));
}
