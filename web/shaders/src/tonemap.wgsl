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
// the swap chain. In reaction-diffusion the field is sampled HERE (binding 4)
// and folded into the HDR light BEFORE exposure and the ACES tonemap, so the
// field is graded with everything else rather than shown as a raw LDR backdrop
// (S10). params.fieldOpacity gates and scales that contribution; it is 0 in the
// particle-life / SPH modes, which have no field, so those paths are unchanged.
// The output alpha is a coverage term (how lit the pixel is); where the field
// contributes it is fully covered, so the field reads as the backdrop.
// =============================================================================

//! import tonemap_params
//! import tonemap_grade
//! import colormap

@group(0) @binding(0) var trailTexture: texture_2d<f32>;
@group(0) @binding(1) var bloomTexture: texture_2d<f32>;
@group(0) @binding(2) var texSampler: sampler;
@group(0) @binding(3) var<uniform> params: TonemapParams;
@group(0) @binding(4) var fieldTexture: texture_2d<f32>;

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

  // Reaction-diffusion field contribution (fieldOpacity is 0 in modes without a
  // field, which skips this entirely). The colormapped field joins the HDR light
  // so it is graded through exposure/ACES with the particles and bloom, and its
  // presence makes the pixel fully covered so it reads as the backdrop.
  var fieldLight = vec3f(0.0, 0.0, 0.0);
  var fieldCoverage = 0.0;
  if (params.fieldOpacity > 0.0) {
    let fieldSample = textureSample(fieldTexture, texSampler, input.uv).xy;
    let colormapIndex = u32(params.colormapIndex + 0.5);
    fieldLight = applyColormap(colormapIndex, fieldSample.x, fieldSample.y) * params.fieldOpacity;
    fieldCoverage = 1.0;
  }

  // Emissive light: crisp particles plus the blurred glow plus the field.
  let light = trail.rgb + bloom * params.bloomIntensity + fieldLight;
  // Exposure -> ACES -> grade, from the shared tonemap_grade module (the one
  // authority field-composite.wgsl also runs, so bloom on/off stays in parity).
  let color = tonemapGrade(light, params);

  // Coverage alpha: bright, particle-covered pixels paint over the background;
  // where the field contributes it fully covers, so it reads as the backdrop;
  // empty pixels in field-free modes stay transparent over the flat clear.
  let coverage = clamp(max(max(trail.a, luminance(bloom)), fieldCoverage), 0.0, 1.0);
  return vec4f(color, coverage);
}
