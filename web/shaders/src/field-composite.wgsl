// =============================================================================
// FIELD COMPOSITE: draw the reaction-diffusion field as a fullscreen backdrop
// =============================================================================
// The bloom-OFF quality floor. Samples the field texture across the screen,
// maps the two concentration channels through the same procedural colormap the
// HDR tonemap path uses (the shared colormap module), and runs the result
// through the same exposure/ACES/grade transform (the shared tonemap_grade
// module), so the field looks the same whether bloom is on or off. Drawn as
// the present-pass backdrop under the particles/glow/trails. Only active in
// reaction-diffusion mode.
//
// The colormap selection, fieldOpacity, and grade knobs arrive through the
// shared TonemapParams uniform (the render loop writes it every frame), so
// this LDR floor and the HDR tonemap read one authority for both.
//
// CHANNELS: field .r = activator (A), .g = inhibitor (B).
// =============================================================================

//! import colormap
//! import tonemap_params
//! import tonemap_grade

@group(0) @binding(0) var fieldTexture: texture_2d<f32>;
@group(0) @binding(1) var fieldSampler: sampler;
@group(0) @binding(2) var<uniform> params: TonemapParams;

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
  let field = textureSample(fieldTexture, fieldSampler, input.uv).xy;
  let colormapIndex = u32(params.colormapIndex + 0.5);
  // The field's light contribution, exactly as the bloom-on path forms it.
  let fieldLight = applyColormap(colormapIndex, field.x, field.y) * params.fieldOpacity;
  // Opaque backdrop: graded through the shared tonemap_grade authority so
  // toggling bloom never shifts the field's tonality; alpha stays 1.
  return vec4f(tonemapGrade(fieldLight, params), 1.0);
}
