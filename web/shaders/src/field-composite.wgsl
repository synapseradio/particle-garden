// =============================================================================
// FIELD COMPOSITE: draw the reaction-diffusion field as a fullscreen backdrop
// =============================================================================
// The bloom-OFF quality floor. Samples the field texture across the screen,
// maps the two concentration channels through the same procedural colormap the
// HDR tonemap path uses (the shared colormap module), and runs the result
// through the same exposure/ACES/grade transform (the shared tonemap_grade
// module), so the field looks the same whether bloom is on or off. Drawn as
// the present-pass backdrop under the particles/glow/trails, on the bloom-off
// path only — with bloom on, the tonemap folds the field in instead.
//
// The colormap selection, fieldOpacity, and grade knobs arrive through the
// shared TonemapParams uniform (the render loop writes it every frame), so
// this LDR floor and the HDR tonemap read one authority for both.
//
// CHANNELS: field .r = activator (A), .g = inhibitor (B).
// =============================================================================

//! import colormap
//! import camera_transform
//! import tonemap_params
//! import tonemap_grade

@group(0) @binding(0) var fieldTexture: texture_2d<f32>;
@group(0) @binding(1) var fieldSampler: sampler;
@group(0) @binding(2) var<uniform> params: TonemapParams;
@group(0) @binding(3) var<uniform> cam: Camera;

const POSITIONS = array<vec2f, 3>(
  vec2f(-1.0, -1.0),
  vec2f( 3.0, -1.0),
  vec2f(-1.0,  3.0),
);

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
};

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;
  output.position = vec4f(POSITIONS[id], 0.0, 1.0);
  // uv (0,0) at top-left, matching the world origin (particle pos 0,0 -> cell 0,0).
  output.uv = (POSITIONS[id] + 1.0) * 0.5;
  output.uv.y = 1.0 - output.uv.y;
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  // Through the camera into field space, the same mapping tonemap.wgsl uses —
  // the two paths must agree about where the field is, not merely about how it
  // is graded. Reduces to input.uv at the default camera.
  let fieldUv = cameraScreenUvToFieldUv(input.uv, cam,
    vec2f(cam.worldWidth, cam.worldHeight));
  let field = textureSample(fieldTexture, fieldSampler, fieldUv).xy;
  let colormapIndex = u32(params.colormapIndex + 0.5);
  // The field's light contribution, exactly as the bloom-on path forms it.
  let fieldLight = applyColormap(colormapIndex, field.x, field.y) * params.fieldOpacity;
  // Graded through the shared tonemap_grade authority so toggling bloom never
  // shifts the field's tonality, and covered by the shared coverage authority
  // so toggling it never shifts what the field OCCLUDES either. A flat 1.0
  // alpha here would make the field an opaque backdrop even where no field is
  // present.
  let coverage = colormapFieldCoverage(colormapIndex, field.x, field.y,
    params.fieldOpacity);
  return vec4f(tonemapGrade(fieldLight, params), coverage);
}
