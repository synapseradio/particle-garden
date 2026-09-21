// =============================================================================
// TONEMAP SHADER - HDR bloom composite + ACES tonemap + colour grade
// =============================================================================
// Replaces the plain trail blit when bloom is enabled. Samples the 8-bit trail
// texture (crisp particles, transparent background) and the blurred half-res
// HDR bloom, adds them as emissive light, applies exposure, the Narkowicz ACES
// filmic tonemap, then the saturation / contrast / temperature grade, and
// writes the swap chain.
//
// The pass draws with alpha blending over the flat background clear already in
// the swap chain.
// =============================================================================

//! import tonemap_params
//! import tonemap_grade

@group(0) @binding(0) var trailTexture: texture_2d<f32>;
@group(0) @binding(1) var bloomTexture: texture_2d<f32>;
@group(0) @binding(2) var texSampler: sampler;
@group(0) @binding(3) var<uniform> params: TonemapParams;

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
  output.uv = (POSITIONS[id] + 1.0) * 0.5;
  output.uv.y = 1.0 - output.uv.y;
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let trail = textureSample(trailTexture, texSampler, input.uv);
  let bloom = textureSample(bloomTexture, texSampler, input.uv).rgb;

  // Emissive light: crisp particles plus the blurred glow.
  let light = trail.rgb + bloom * params.bloomIntensity;
  // Exposure -> ACES -> grade, from the shared tonemap_grade module.
  let color = tonemapGrade(light, params);

  // Coverage alpha: bright, particle-covered pixels paint over the background;
  // empty pixels stay transparent over the flat clear.
  let coverage = clamp(max(trail.a, luminance(bloom)), 0.0, 1.0);
  return vec4f(color, coverage);
}
