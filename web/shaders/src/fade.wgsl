// =============================================================================
// FADE SHADER - samples the previous trail frame and fades it toward background
// =============================================================================
// Drawn first in the offscreen pass, before the current frame's particles, so
// the persistent trail texture decays by fadeAmount each frame instead of
// being cleared outright.
//
// FadeParams comes from the generated fade_params module (FadeParamsLayout in
// src/gpu_types.nim); fadeAmount is 0.0 = instant clear, 1.0 = keep previous.
// =============================================================================

//! import fade_params

@group(0) @binding(0) var prevFrame: texture_2d<f32>;
@group(0) @binding(1) var prevSampler: sampler;
@group(0) @binding(2) var<uniform> params: FadeParams;

// Fullscreen triangle (3 vertices cover entire screen)
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
  // Convert clip space (-1 to 1) to UV space (0 to 1)
  output.uv = (POSITIONS[id] + 1.0) * 0.5;
  output.uv.y = 1.0 - output.uv.y;  // Flip Y for texture coordinates
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let prev = textureSample(prevFrame, prevSampler, input.uv);

  // Fade toward transparent (glow shows through from present pass)
  // Higher fadeAmount = MORE of previous frame = LONGER trails
  // RGB fades toward background tint, alpha fades toward 0
  let bgRgb = vec3f(0.04, 0.04, 0.06);
  let fadedRgb = mix(bgRgb, prev.rgb, params.fadeAmount);
  let fadedAlpha = prev.a * params.fadeAmount;
  return vec4f(fadedRgb, fadedAlpha);
}
