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
// the swap chain. The field is sampled HERE (binding 4) and folded into the HDR
// light BEFORE exposure and the ACES tonemap, so the field is graded with
// everything else rather than shown as a raw LDR backdrop.
// params.fieldOpacity gates and scales that contribution, and it is the user's
// slider: at its zero the pass costs nothing.
// The output alpha is a coverage term (how lit the pixel is); where the field
// contributes it is fully covered, so the field reads as the backdrop.
// =============================================================================

//! import tonemap_params
//! import tonemap_grade
//! import colormap
//! import camera_transform

@group(0) @binding(0) var trailTexture: texture_2d<f32>;
@group(0) @binding(1) var bloomTexture: texture_2d<f32>;
@group(0) @binding(2) var texSampler: sampler;
@group(0) @binding(3) var<uniform> params: TonemapParams;
@group(0) @binding(4) var fieldTexture: texture_2d<f32>;
@group(0) @binding(5) var<uniform> cam: Camera;

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

  // Reaction-diffusion field contribution. The colormapped field joins the HDR
  // light so it is graded through exposure/ACES with the particles and bloom.
  //
  // Both terms carry fieldOpacity as a factor — the light multiplies by it and
  // colormapFieldCoverage clamps its product — so at the slider's zero they are
  // provably zero and the guard skips the sample and both colormap evaluations.
  // It reads from a uniform, so the branch is coherent across the draw and
  // costs nothing at any other opacity.
  //
  // Coverage follows how much field is actually HERE, which is what makes the
  // field read as light in the world rather than as a backdrop the particles
  // sit on. A flat 1.0 would let an empty field claim every pixel.
  // The field lives in the WORLD, so its sample goes through the camera while
  // the trail and bloom — which are screen-space render targets — do not. At
  // the default camera this reduces to input.uv exactly.
  var fieldLight = vec3f(0.0);
  var fieldCoverage = 0.0;
  if (params.fieldOpacity > 0.0) {
    let fieldUv = cameraScreenUvToFieldUv(input.uv, cam,
      vec2f(cam.worldWidth, cam.worldHeight));
    let fieldSample = textureSample(fieldTexture, texSampler, fieldUv).xy;
    let colormapIndex = u32(params.colormapIndex + 0.5);
    fieldLight =
      applyColormap(colormapIndex, fieldSample.x, fieldSample.y) * params.fieldOpacity;
    fieldCoverage = colormapFieldCoverage(colormapIndex, fieldSample.x,
      fieldSample.y, params.fieldOpacity);
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
