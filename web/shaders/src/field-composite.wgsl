// =============================================================================
// FIELD COMPOSITE: draw the reaction-diffusion field as a fullscreen backdrop
// =============================================================================
// LDR pass. Samples the field texture (linear) across the screen and maps the two
// concentration channels to a simple colour ramp, drawn as the present-pass
// backdrop under the particles/glow/trails. Deliberately plain — S9/S10 add HDR
// bloom and a calibrated colormap. Only active in reaction-diffusion mode.
//
// CHANNELS: field .r = activator (A), .g = inhibitor (B).
// =============================================================================

@group(0) @binding(0) var fieldTexture: texture_2d<f32>;
@group(0) @binding(1) var fieldSampler: sampler;

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
  let activator = clamp(field.x, 0.0, 1.0);
  let inhibitor = clamp(field.y, 0.0, 1.0);
  // Teal-leaning ramp: inhibitor drives brightness, a touch of activator warms it.
  let color = vec3f(
    inhibitor * 0.25 + activator * 0.05,
    inhibitor * 0.85 + activator * 0.10,
    inhibitor * 1.00,
  );
  return vec4f(color, 1.0);
}
