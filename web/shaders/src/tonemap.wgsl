// =============================================================================
// TONEMAP SHADER - HDR bloom composite + ACES tonemap + colour grade
// =============================================================================
// Replaces the plain trail blit when bloom is enabled. Samples the 8-bit trail
// texture (crisp particles, transparent background) and the blurred half-res
// HDR bloom, adds them as emissive light, applies exposure, the Narkowicz ACES
// filmic tonemap, then the saturation / contrast / temperature grade, and
// writes the swap chain.
//
// The pass draws with alpha blending over whatever is already in the swap
// chain: in particle-life / SPH that is the flat background clear; in
// reaction-diffusion it is the field backdrop drawn just before this pass. The
// output alpha is a coverage term (how lit the pixel is), so empty regions let
// the background — and the RD field — show through unchanged. Proper HDR
// integration of the field is S10; here it just stays visible.
// =============================================================================

//! import tonemap_params

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

fn luminance(color: vec3f) -> f32 {
  return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

// Narkowicz 2015 ACES filmic tonemap fit — maps unbounded HDR into [0,1].
fn acesFilmic(hdr: vec3f) -> vec3f {
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  return clamp((hdr * (a * hdr + b)) / (hdr * (c * hdr + d) + e),
               vec3f(0.0), vec3f(1.0));
}

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

  // Emissive light: crisp particles plus the blurred glow, no background term.
  let light = trail.rgb + bloom * params.bloomIntensity;
  let hdr = light * params.exposure;

  var color = acesFilmic(hdr);

  // Grade: saturation around the pixel's own luminance.
  let lum = luminance(color);
  color = mix(vec3f(lum), color, params.saturation);

  // Grade: contrast around a mid-grey 0.5 pivot.
  color = (color - 0.5) * params.contrast + 0.5;

  // Grade: signed temperature — positive warms (more red, less blue).
  color = color * vec3f(1.0 + params.temperature * 0.1, 1.0,
                        1.0 - params.temperature * 0.1);

  color = clamp(color, vec3f(0.0), vec3f(1.0));

  // Coverage alpha: bright, particle-covered pixels paint over the background;
  // empty pixels stay transparent so the backdrop (RD field / clear) shows.
  let coverage = clamp(max(trail.a, luminance(bloom)), 0.0, 1.0);
  return vec4f(color, coverage);
}
