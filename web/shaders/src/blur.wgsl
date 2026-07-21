// =============================================================================
// BLUR SHADER - separable Gaussian blur of the half-resolution HDR bloom source
// =============================================================================
// One axis per pass, ping-ponging between two half-res rgba16float targets:
// the horizontal pass reads the glow HDR target and writes target B, the
// vertical pass reads B and writes back into A. `params.direction` selects the
// axis ((1,0) or (0,1)) and `params.texelSize` is one over the target
// dimensions, so `direction * texelSize` is the per-tap UV step.
//
// The kernel weights come from bloom_core.nim (Nim, native-tested) and are
// substituted here as compile-time literals — never uniform data. WEIGHTS[0]
// is the centre tap; WEIGHTS[i] is applied to BOTH the +i and -i taps, and
// WEIGHTS[0] + 2*sum(WEIGHTS[1..]) == 1, so the blur preserves brightness.
// =============================================================================

//! import bloom_params

@group(0) @binding(0) var srcTexture: texture_2d<f32>;
@group(0) @binding(1) var srcSampler: sampler;
@group(0) @binding(2) var<uniform> params: BloomParams;

// Half kernel (centre + one side), generated from bloom_core.nim. A private
// var (not a const) so the dynamic loop index below is unambiguously legal.
var<private> WEIGHTS = array<f32, {{BLOOM_WEIGHT_COUNT}}>({{BLOOM_WEIGHTS}});

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
  let step = params.direction * params.texelSize;
  var acc = textureSample(srcTexture, srcSampler, input.uv).rgb * WEIGHTS[0];
  for (var tap: i32 = 1; tap < {{BLOOM_WEIGHT_COUNT}}; tap = tap + 1) {
    let offset = step * f32(tap);
    acc += textureSample(srcTexture, srcSampler, input.uv + offset).rgb * WEIGHTS[tap];
    acc += textureSample(srcTexture, srcSampler, input.uv - offset).rgb * WEIGHTS[tap];
  }
  return vec4f(acc, 1.0);
}
