# ==============================================================================
# PARTICLE GARDEN - WEBGPU RENDER MODULE
# ==============================================================================
#
# GPU-only particle rendering using WebGPU render pipeline.
# Reads particle data directly from compute shader storage buffers.
# Zero CPU readback - all data stays on GPU.
#
# ARCHITECTURE:
# - Uses instanced quads (6 vertices per particle)
# - Vertex shader pulls data from storage buffers via instance_index
# - Fragment shader creates circular point sprites with soft edges
#
# ==============================================================================

from std/jsffi import JsObject, toJs, `[]`, `[]=`
import std/dom
import bindings/js_interop
import bindings/webgpu
import bindings/typed_arrays
import bindings/dom_extensions
import bindings/window
import config
import webgpu_init

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  RenderTiming* = ref object of JsObject
    packTimeMs* {.exportc.}: float    # Always 0 - no CPU packing
    uploadTimeMs* {.exportc.}: float  # Always 0 - no upload

# ==============================================================================
# SECTION 2: MODULE STATE
# ==============================================================================

var canvas*: HTMLCanvasElement
var gpuContext: GPUCanvasContext
var renderPipeline: GPURenderPipeline
var glowPipeline: GPURenderPipeline
var fadePipeline: GPURenderPipeline
var blitPipeline: GPURenderPipeline
var renderBindGroup: GPUBindGroup
var glowBindGroup: GPUBindGroup
var renderParamsBuffer: GPUBuffer
var fadeParamsBuffer: GPUBuffer
var bindGroupLayout: GPUBindGroupLayout  # Store original layout for bind group creation
var isInitialized: bool = false

# Ping-pong trail textures (persistent across frames)
var trailTextureA: GPUTexture
var trailTextureB: GPUTexture
var trailViewA: GPUTextureView
var trailViewB: GPUTextureView
var trailParity: int = 0  # 0 = read A write B, 1 = read B write A

# Cached bind groups for trail rendering (created once, selected at runtime)
var blitBindGroupA: GPUBindGroup  # Blit from trail texture A
var blitBindGroupB: GPUBindGroup  # Blit from trail texture B
var fadeBindGroupReadA: GPUBindGroup  # Fade pass reads from A
var fadeBindGroupReadB: GPUBindGroup  # Fade pass reads from B

# Shared sampler for texture reads
var linearSampler: GPUSampler

# Depth texture for Z-ordering (larger particles behind smaller ones)
var depthTexture: GPUTexture
var depthTextureView: GPUTextureView

# Canvas format for texture creation
var canvasFormat: cstring

# Bind group layouts (needed for resize to recreate bind groups)
var fadeBindGroupLayout: GPUBindGroupLayout
var blitBindGroupLayout: GPUBindGroupLayout


# ==============================================================================
# SECTION 3: SHADER SOURCE
# ==============================================================================

const RENDER_SHADER = staticRead("../web/shaders/render.wgsl")

# Glow shader - larger particles with Gaussian falloff (AoS layout)
const GLOW_SHADER = """
// AoS Particle struct: 32 bytes, cache-aligned
struct Particle {
  pos: vec2<f32>,    // offset 0, size 8
  vel: vec2<f32>,    // offset 8, size 8
  species: u32,      // offset 16, size 4
  density: f32,      // offset 20, size 4
  _pad0: u32,        // offset 24, size 4
  _pad1: u32,        // offset 28, size 4
}

struct RenderParams {
  resolution: vec2f,       // Canvas size
  worldSize: vec2f,        // World size (physics domain)
  baseSize: f32,
  glowIntensity: f32,      // Base glow multiplier
  velocityGlowScale: f32,  // 0=off, 1=full velocity influence
  maxVelocity: f32,        // For velocity normalization
};

const OFFSETS = array<vec2f, 6>(
  vec2f(-1.0, -1.0),
  vec2f( 1.0, -1.0),
  vec2f(-1.0,  1.0),
  vec2f(-1.0,  1.0),
  vec2f( 1.0, -1.0),
  vec2f( 1.0,  1.0),
);

// AoS particle buffer
@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(0) @binding(1) var<uniform> params: RenderParams;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) offset: vec2f,
  @location(1) densityVal: f32,
  @location(2) velocityNorm: f32,  // Normalized velocity magnitude [0,1]
};

// ==========================================================================
// GLOW TUNING CONSTANTS
// ==========================================================================
//
// All compile-time constants — zero runtime cost (inlined by compiler).
// Grouped by perceptual function for easy tuning.
//
// ==========================================================================

// VELOCITY → GLOW MAPPING
// Lower LOG_SCALE = more perceptual room for slow velocities
const VELOCITY_LOG_SCALE: f32 = 5.0;

// DENSITY → GLOW MAPPING
// How local particle density affects glow intensity
const DENSITY_SCALE: f32 = 0.15;   // Multiplier on raw density
const DENSITY_MIN: f32 = 0.1;      // Floor (isolated particles still glow)
const DENSITY_MAX: f32 = 1.0;      // Ceiling

// GAUSSIAN FALLOFF
// Shape of the glow halo around each particle
const GLOW_FALLOFF: f32 = 6.0;     // Higher = tighter halo
const GLOW_DIVISOR: f32 = 24.0;    // Overall intensity scaling

// COLOR WARMTH
// Fast particles shift toward orange-white
const WARMTH_MAX: f32 = 0.4;       // Max warmth at full velocity (0-1)
const WARMTH_GREEN: f32 = 0.3;     // Green channel reduction
const WARMTH_BLUE: f32 = 0.6;      // Blue channel reduction (more = more orange)

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;
  let particleId = id / 6u;
  let cornerId = id % 6u;

  // Read particle data from AoS buffer
  let p = particles[particleId];
  let offset = OFFSETS[cornerId];

  // Glow radius scaled by canvas/world ratio
  let scale = params.resolution / params.worldSize;
  let glowRadius = 12.0;
  let worldPos = p.pos + offset * glowRadius / scale;

  let normalizedPos = (worldPos / params.worldSize) * 2.0 - 1.0;

  // Compute normalized velocity magnitude for glow and z-ordering
  let speed = length(p.vel);
  let velocityNorm = clamp(speed / params.maxVelocity, 0.0, 1.0);
  output.velocityNorm = velocityNorm;

  // Z-ordering: FAST particles go BEHIND (higher Z), SLOW in front (lower Z)
  // Position hash prevents z-fighting between similar particles
  let posHash = fract(sin(dot(p.pos, vec2f(12.9898, 78.233))) * 43758.5453);
  let velZ = velocityNorm * 0.8;  // Fast = 0.8, slow = 0
  let densityZ = clamp(p.density * 0.1, 0.0, 0.19);
  let zDepth = clamp(velZ + densityZ + posHash * 0.001, 0.01, 0.99);
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, zDepth, 1.0);
  output.offset = offset;
  output.densityVal = p.density;

  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let l = length(input.offset);

  // Density factor: high density = more glow
  let densityFactor = clamp(input.densityVal * DENSITY_SCALE, DENSITY_MIN, DENSITY_MAX);

  // Velocity factor: logarithmic compression with low-end bias
  let logVel = log(1.0 + input.velocityNorm * VELOCITY_LOG_SCALE) / log(1.0 + VELOCITY_LOG_SCALE);
  let velocityFactor = 1.0 + logVel * params.velocityGlowScale;

  // Combined glow with Gaussian falloff
  let alpha = exp(-GLOW_FALLOFF * l * l) * params.glowIntensity * densityFactor * velocityFactor / GLOW_DIVISOR;

  // Color shift: fast particles glow warm (orange-white)
  let warmth = logVel * params.velocityGlowScale * WARMTH_MAX;
  let r = alpha;
  let g = alpha * (1.0 - warmth * WARMTH_GREEN);
  let b = alpha * (1.0 - warmth * WARMTH_BLUE);
  return vec4f(r, g, b, alpha);
}
"""

# Fade overlay shader - samples previous frame and fades toward background
const FADE_SHADER = """
struct FadeParams {
  fadeAmount: f32,  // 0.0 = no fade (keep previous), 1.0 = instant clear
  pad0: f32,
  pad1: f32,
  pad2: f32,
};

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
"""

# Blit shader - copies texture to swap chain
const BLIT_SHADER = """
@group(0) @binding(0) var inputTexture: texture_2d<f32>;
@group(0) @binding(1) var inputSampler: sampler;

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
  return textureSample(inputTexture, inputSampler, input.uv);
}
"""

# ==============================================================================
# SECTION 4: INITIALIZATION
# ==============================================================================

# Forward declaration
proc updateBindGroup*()

proc initWebGPURender*(): bool =
  ## Initialize WebGPU render pipeline.
  ## Must be called AFTER webgpu_init.initWebGPU() succeeds.

  if webgpu_init.device.isNil:
    {.emit: "console.error('WebGPU device not initialized');".}
    return false

  # Get canvas
  canvas = document.getElementById("canvas").toHTMLCanvasElement()
  if canvas.isNil:
    {.emit: "console.error('Canvas not found');".}
    return false

  # Set canvas to window size (critical for correct particle sizing)
  canvas.width = windowInnerWidth()
  canvas.height = windowInnerHeight()

  # Configure canvas for WebGPU
  gpuContext = cast[JsObject](canvas).getContextWebGPU()
  if gpuContext.isNil:
    {.emit: "console.error('Failed to get WebGPU context');".}
    return false

  canvasFormat = getPreferredCanvasFormat()  # Store in module variable
  let configObj = newJsObject()
  configObj["device"] = webgpu_init.device.toJs
  configObj["format"] = canvasFormat.toJs
  configObj["alphaMode"] = "opaque".cstring.toJs
  gpuContext.configure(configObj)

  # Create shader module
  let shaderDesc = newJsObject()
  shaderDesc["label"] = "Particle Render Shader".cstring.toJs
  shaderDesc["code"] = RENDER_SHADER.cstring.toJs
  let shaderModule = webgpu_init.device.createShaderModule(shaderDesc)

  # Create render params uniform buffer (resolution, worldSize, baseSize, glowIntensity, padding)
  let paramsSize = 32  # vec2f + vec2f + f32 + f32 + f32 + f32 = 32 bytes
  let paramsDesc = newJsObject()
  paramsDesc["size"] = paramsSize.toJs
  paramsDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  paramsDesc["label"] = "Render Params Buffer".cstring.toJs
  renderParamsBuffer = webgpu_init.device.createBuffer(paramsDesc)

  # Create bind group layout (AoS: 2 bindings - particles + renderParams)
  let layoutDesc = newJsObject()
  layoutDesc["label"] = "Render Bind Group Layout (AoS)".cstring.toJs

  let entries = newJsArray()

  # Binding 0: particles (AoS storage buffer, read-only)
  let entry0 = newJsObject()
  entry0["binding"] = 0.toJs
  entry0["visibility"] = gpuShaderStageVertex.toJs
  let buffer0 = newJsObject()
  buffer0["type"] = "read-only-storage".cstring.toJs
  entry0["buffer"] = buffer0
  discard entries.push(entry0)

  # Binding 1: render params (uniform buffer) - needs vertex AND fragment for glow intensity
  let entry1 = newJsObject()
  entry1["binding"] = 1.toJs
  entry1["visibility"] = bitwiseOr(gpuShaderStageVertex, gpuShaderStageFragment).toJs
  let buffer1 = newJsObject()
  buffer1["type"] = "uniform".cstring.toJs
  entry1["buffer"] = buffer1
  discard entries.push(entry1)

  layoutDesc["entries"] = entries
  bindGroupLayout = webgpu_init.device.createBindGroupLayout(layoutDesc)

  # Create pipeline layout
  let pipelineLayoutDesc = newJsObject()
  let layouts = newJsArray()
  discard layouts.push(bindGroupLayout)
  pipelineLayoutDesc["bindGroupLayouts"] = layouts
  pipelineLayoutDesc["label"] = "Render Pipeline Layout".cstring.toJs
  let pipelineLayout = webgpu_init.device.createPipelineLayout(pipelineLayoutDesc)

  # Create render pipeline
  let pipelineDesc = newJsObject()
  pipelineDesc["label"] = "Particle Render Pipeline".cstring.toJs
  pipelineDesc["layout"] = pipelineLayout.toJs

  # Vertex stage
  let vertexStage = newJsObject()
  vertexStage["module"] = shaderModule.toJs
  vertexStage["entryPoint"] = "vs_main".cstring.toJs
  pipelineDesc["vertex"] = vertexStage

  # Fragment stage
  let fragmentStage = newJsObject()
  fragmentStage["module"] = shaderModule.toJs
  fragmentStage["entryPoint"] = "fs_main".cstring.toJs

  let targets = newJsArray()
  let target0 = newJsObject()
  target0["format"] = canvasFormat.toJs

  # Alpha blending for soft edges
  let blend = newJsObject()
  let colorBlend = newJsObject()
  colorBlend["srcFactor"] = "src-alpha".cstring.toJs
  colorBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  colorBlend["operation"] = "add".cstring.toJs
  blend["color"] = colorBlend
  let alphaBlend = newJsObject()
  alphaBlend["srcFactor"] = "one".cstring.toJs
  alphaBlend["dstFactor"] = "zero".cstring.toJs
  alphaBlend["operation"] = "add".cstring.toJs
  blend["alpha"] = alphaBlend
  target0["blend"] = blend

  discard targets.push(target0)
  fragmentStage["targets"] = targets
  pipelineDesc["fragment"] = fragmentStage

  # Primitive state (triangle list for quads)
  let primitive = newJsObject()
  primitive["topology"] = "triangle-list".cstring.toJs
  primitive["cullMode"] = "none".cstring.toJs
  pipelineDesc["primitive"] = primitive

  # Depth stencil state for Z-ordering (larger particles behind smaller ones)
  let depthStencil = newJsObject()
  depthStencil["format"] = "depth24plus".cstring.toJs
  depthStencil["depthWriteEnabled"] = true.toJs
  depthStencil["depthCompare"] = "less".cstring.toJs  # Lower Z = closer to camera
  pipelineDesc["depthStencil"] = depthStencil

  renderPipeline = webgpu_init.device.createRenderPipeline(pipelineDesc)

  # Create glow shader module
  let glowShaderDesc = newJsObject()
  glowShaderDesc["label"] = "Glow Render Shader".cstring.toJs
  glowShaderDesc["code"] = GLOW_SHADER.cstring.toJs
  let glowShaderModule = webgpu_init.device.createShaderModule(glowShaderDesc)

  # Create glow pipeline (same layout, different blending)
  let glowPipelineDesc = newJsObject()
  glowPipelineDesc["label"] = "Glow Render Pipeline".cstring.toJs
  glowPipelineDesc["layout"] = pipelineLayout.toJs

  # Vertex stage (same structure as particle shader)
  let glowVertexStage = newJsObject()
  glowVertexStage["module"] = glowShaderModule.toJs
  glowVertexStage["entryPoint"] = "vs_main".cstring.toJs
  glowPipelineDesc["vertex"] = glowVertexStage

  # Fragment stage with additive blending
  let glowFragmentStage = newJsObject()
  glowFragmentStage["module"] = glowShaderModule.toJs
  glowFragmentStage["entryPoint"] = "fs_main".cstring.toJs

  let glowTargets = newJsArray()
  let glowTarget0 = newJsObject()
  glowTarget0["format"] = canvasFormat.toJs

  # Additive blending for glow: src + dst
  let glowBlend = newJsObject()
  let glowColorBlend = newJsObject()
  glowColorBlend["srcFactor"] = "one".cstring.toJs
  glowColorBlend["dstFactor"] = "one".cstring.toJs
  glowColorBlend["operation"] = "add".cstring.toJs
  glowBlend["color"] = glowColorBlend
  let glowAlphaBlend = newJsObject()
  glowAlphaBlend["srcFactor"] = "one".cstring.toJs
  glowAlphaBlend["dstFactor"] = "one".cstring.toJs
  glowAlphaBlend["operation"] = "add".cstring.toJs
  glowBlend["alpha"] = glowAlphaBlend
  glowTarget0["blend"] = glowBlend

  discard glowTargets.push(glowTarget0)
  glowFragmentStage["targets"] = glowTargets
  glowPipelineDesc["fragment"] = glowFragmentStage

  # Primitive state
  let glowPrimitive = newJsObject()
  glowPrimitive["topology"] = "triangle-list".cstring.toJs
  glowPrimitive["cullMode"] = "none".cstring.toJs
  glowPipelineDesc["primitive"] = glowPrimitive

  # Depth stencil for glow (read depth, don't write - glow layers on top)
  let glowDepthStencil = newJsObject()
  glowDepthStencil["format"] = "depth24plus".cstring.toJs
  glowDepthStencil["depthWriteEnabled"] = false.toJs  # Don't overwrite particle depth
  glowDepthStencil["depthCompare"] = "less".cstring.toJs
  glowPipelineDesc["depthStencil"] = glowDepthStencil

  glowPipeline = webgpu_init.device.createRenderPipeline(glowPipelineDesc)

  # ==========================================================================
  # TRAIL RENDERING INFRASTRUCTURE
  # ==========================================================================

  # Create shared sampler for texture reads (created once, reused everywhere)
  let samplerDesc = newJsObject()
  samplerDesc["magFilter"] = "linear".cstring.toJs
  samplerDesc["minFilter"] = "linear".cstring.toJs
  samplerDesc["label"] = "Linear Sampler".cstring.toJs
  linearSampler = webgpu_init.device.createSampler(samplerDesc)

  # Create fade params uniform buffer (fadeAmount + 3 padding floats = 16 bytes)
  let fadeParamsSize = 16
  let fadeParamsDesc = newJsObject()
  fadeParamsDesc["size"] = fadeParamsSize.toJs
  fadeParamsDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  fadeParamsDesc["label"] = "Fade Params Buffer".cstring.toJs
  fadeParamsBuffer = webgpu_init.device.createBuffer(fadeParamsDesc)

  # Create fade shader module (samples previous frame texture)
  let fadeShaderDesc = newJsObject()
  fadeShaderDesc["label"] = "Fade Overlay Shader".cstring.toJs
  fadeShaderDesc["code"] = FADE_SHADER.cstring.toJs
  let fadeShaderModule = webgpu_init.device.createShaderModule(fadeShaderDesc)

  # Create fade bind group layout (texture + sampler + uniform)
  let fadeLayoutDesc = newJsObject()
  fadeLayoutDesc["label"] = "Fade Bind Group Layout".cstring.toJs
  let fadeLayoutEntries = newJsArray()

  # Binding 0: Previous frame texture
  let fadeEntry0 = newJsObject()
  fadeEntry0["binding"] = 0.toJs
  fadeEntry0["visibility"] = gpuShaderStageFragment.toJs
  let fadeTexture0 = newJsObject()
  fadeTexture0["sampleType"] = "float".cstring.toJs
  fadeEntry0["texture"] = fadeTexture0
  discard fadeLayoutEntries.push(fadeEntry0)

  # Binding 1: Sampler
  let fadeEntry1 = newJsObject()
  fadeEntry1["binding"] = 1.toJs
  fadeEntry1["visibility"] = gpuShaderStageFragment.toJs
  let fadeSampler1 = newJsObject()
  fadeSampler1["type"] = "filtering".cstring.toJs
  fadeEntry1["sampler"] = fadeSampler1
  discard fadeLayoutEntries.push(fadeEntry1)

  # Binding 2: Fade params uniform
  let fadeEntry2 = newJsObject()
  fadeEntry2["binding"] = 2.toJs
  fadeEntry2["visibility"] = gpuShaderStageFragment.toJs
  let fadeBuffer2 = newJsObject()
  fadeBuffer2["type"] = "uniform".cstring.toJs
  fadeEntry2["buffer"] = fadeBuffer2
  discard fadeLayoutEntries.push(fadeEntry2)

  fadeLayoutDesc["entries"] = fadeLayoutEntries
  fadeBindGroupLayout = webgpu_init.device.createBindGroupLayout(fadeLayoutDesc)

  # Create fade pipeline layout
  let fadePipelineLayoutDesc = newJsObject()
  let fadeLayouts = newJsArray()
  discard fadeLayouts.push(fadeBindGroupLayout)
  fadePipelineLayoutDesc["bindGroupLayouts"] = fadeLayouts
  let fadePipelineLayout = webgpu_init.device.createPipelineLayout(fadePipelineLayoutDesc)

  # Create fade pipeline (no blending needed - just outputs faded color)
  let fadePipelineDesc = newJsObject()
  fadePipelineDesc["label"] = "Fade Overlay Pipeline".cstring.toJs
  fadePipelineDesc["layout"] = fadePipelineLayout.toJs

  let fadeVertexStage = newJsObject()
  fadeVertexStage["module"] = fadeShaderModule.toJs
  fadeVertexStage["entryPoint"] = "vs_main".cstring.toJs
  fadePipelineDesc["vertex"] = fadeVertexStage

  let fadeFragmentStage = newJsObject()
  fadeFragmentStage["module"] = fadeShaderModule.toJs
  fadeFragmentStage["entryPoint"] = "fs_main".cstring.toJs

  let fadeTargets = newJsArray()
  let fadeTarget0 = newJsObject()
  fadeTarget0["format"] = canvasFormat.toJs
  discard fadeTargets.push(fadeTarget0)
  fadeFragmentStage["targets"] = fadeTargets
  fadePipelineDesc["fragment"] = fadeFragmentStage

  let fadePrimitive = newJsObject()
  fadePrimitive["topology"] = "triangle-list".cstring.toJs
  fadePrimitive["cullMode"] = "none".cstring.toJs
  fadePipelineDesc["primitive"] = fadePrimitive

  # Depth-stencil config required when render pass has depth attachment
  # Fade is fullscreen overlay - always pass depth test, don't write depth
  let fadeDepthStencil = newJsObject()
  fadeDepthStencil["format"] = "depth24plus".cstring.toJs
  fadeDepthStencil["depthWriteEnabled"] = false.toJs
  fadeDepthStencil["depthCompare"] = "always".cstring.toJs
  fadePipelineDesc["depthStencil"] = fadeDepthStencil

  fadePipeline = webgpu_init.device.createRenderPipeline(fadePipelineDesc)

  # ==========================================================================
  # BLIT PIPELINE (copies offscreen texture to swap chain)
  # ==========================================================================

  let blitShaderDesc = newJsObject()
  blitShaderDesc["label"] = "Blit Shader".cstring.toJs
  blitShaderDesc["code"] = BLIT_SHADER.cstring.toJs
  let blitShaderModule = webgpu_init.device.createShaderModule(blitShaderDesc)

  # Create blit bind group layout (texture + sampler)
  let blitLayoutDesc = newJsObject()
  blitLayoutDesc["label"] = "Blit Bind Group Layout".cstring.toJs
  let blitLayoutEntries = newJsArray()

  let blitEntry0 = newJsObject()
  blitEntry0["binding"] = 0.toJs
  blitEntry0["visibility"] = gpuShaderStageFragment.toJs
  let blitTexture0 = newJsObject()
  blitTexture0["sampleType"] = "float".cstring.toJs
  blitEntry0["texture"] = blitTexture0
  discard blitLayoutEntries.push(blitEntry0)

  let blitEntry1 = newJsObject()
  blitEntry1["binding"] = 1.toJs
  blitEntry1["visibility"] = gpuShaderStageFragment.toJs
  let blitSampler1 = newJsObject()
  blitSampler1["type"] = "filtering".cstring.toJs
  blitEntry1["sampler"] = blitSampler1
  discard blitLayoutEntries.push(blitEntry1)

  blitLayoutDesc["entries"] = blitLayoutEntries
  blitBindGroupLayout = webgpu_init.device.createBindGroupLayout(blitLayoutDesc)

  # Create blit pipeline layout
  let blitPipelineLayoutDesc = newJsObject()
  let blitLayouts = newJsArray()
  discard blitLayouts.push(blitBindGroupLayout)
  blitPipelineLayoutDesc["bindGroupLayouts"] = blitLayouts
  let blitPipelineLayout = webgpu_init.device.createPipelineLayout(blitPipelineLayoutDesc)

  # Create blit pipeline (no blending - just copy)
  let blitPipelineDesc = newJsObject()
  blitPipelineDesc["label"] = "Blit Pipeline".cstring.toJs
  blitPipelineDesc["layout"] = blitPipelineLayout.toJs

  let blitVertexStage = newJsObject()
  blitVertexStage["module"] = blitShaderModule.toJs
  blitVertexStage["entryPoint"] = "vs_main".cstring.toJs
  blitPipelineDesc["vertex"] = blitVertexStage

  let blitFragmentStage = newJsObject()
  blitFragmentStage["module"] = blitShaderModule.toJs
  blitFragmentStage["entryPoint"] = "fs_main".cstring.toJs

  let blitTargets = newJsArray()
  let blitTarget0 = newJsObject()
  blitTarget0["format"] = canvasFormat.toJs

  # Alpha blending so trail composites over glow
  let blitBlend = newJsObject()
  let blitColorBlend = newJsObject()
  blitColorBlend["srcFactor"] = "src-alpha".cstring.toJs
  blitColorBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  blitColorBlend["operation"] = "add".cstring.toJs
  blitBlend["color"] = blitColorBlend
  let blitAlphaBlend = newJsObject()
  blitAlphaBlend["srcFactor"] = "one".cstring.toJs
  blitAlphaBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  blitAlphaBlend["operation"] = "add".cstring.toJs
  blitBlend["alpha"] = blitAlphaBlend
  blitTarget0["blend"] = blitBlend

  discard blitTargets.push(blitTarget0)
  blitFragmentStage["targets"] = blitTargets
  blitPipelineDesc["fragment"] = blitFragmentStage

  let blitPrimitive = newJsObject()
  blitPrimitive["topology"] = "triangle-list".cstring.toJs
  blitPrimitive["cullMode"] = "none".cstring.toJs
  blitPipelineDesc["primitive"] = blitPrimitive

  # Depth-stencil config for compatibility with present pass (which has depth for glow)
  let blitDepthStencil = newJsObject()
  blitDepthStencil["format"] = "depth24plus".cstring.toJs
  blitDepthStencil["depthWriteEnabled"] = false.toJs
  blitDepthStencil["depthCompare"] = "always".cstring.toJs
  blitPipelineDesc["depthStencil"] = blitDepthStencil

  blitPipeline = webgpu_init.device.createRenderPipeline(blitPipelineDesc)

  # ==========================================================================
  # PERSISTENT TRAIL TEXTURES (survive across frames for ping-pong)
  # ==========================================================================

  let trailTextureDesc = newJsObject()
  let trailSize = newJsArray()
  discard trailSize.push(canvas.width.toJs)
  discard trailSize.push(canvas.height.toJs)
  trailTextureDesc["size"] = trailSize
  trailTextureDesc["format"] = canvasFormat.toJs
  trailTextureDesc["usage"] = bitwiseOr(gpuTextureUsageRenderAttachment, gpuTextureUsageTextureBinding).toJs
  trailTextureDesc["label"] = "Trail Texture A".cstring.toJs
  trailTextureA = webgpu_init.device.createTexture(trailTextureDesc)
  trailTextureDesc["label"] = "Trail Texture B".cstring.toJs
  trailTextureB = webgpu_init.device.createTexture(trailTextureDesc)

  trailViewA = trailTextureA.createView()
  trailViewB = trailTextureB.createView()

  # Create depth texture for Z-ordering (larger particles behind smaller ones)
  let depthTextureDesc = newJsObject()
  let depthSize = newJsArray()
  discard depthSize.push(canvas.width.toJs)
  discard depthSize.push(canvas.height.toJs)
  depthTextureDesc["size"] = depthSize
  depthTextureDesc["format"] = "depth24plus".cstring.toJs
  depthTextureDesc["usage"] = gpuTextureUsageRenderAttachment.toJs
  depthTextureDesc["label"] = "Depth Texture".cstring.toJs
  depthTexture = webgpu_init.device.createTexture(depthTextureDesc)
  depthTextureView = depthTexture.createView()

  # ==========================================================================
  # CLEAR TRAIL TEXTURES (ensure valid initial state for ping-pong)
  # ==========================================================================
  # WebGPU doesn't guarantee zero-initialized textures. Without clearing,
  # frame 0 reads GPU garbage when sampling the "previous frame" texture.

  let initEncoderDesc = newJsObject()
  initEncoderDesc["label"] = "Trail Texture Init".cstring.toJs
  let initEncoder = webgpu_init.device.createCommandEncoder(initEncoderDesc)

  # Transparent clear for trail textures (glow shows through from present pass)
  let bgColor = newJsObject()
  bgColor["r"] = 0.0.toJs
  bgColor["g"] = 0.0.toJs
  bgColor["b"] = 0.0.toJs
  bgColor["a"] = 0.0.toJs

  # Clear texture A
  let clearPassDescA = newJsObject()
  clearPassDescA["label"] = "Clear Trail Texture A".cstring.toJs
  let attachmentsA = newJsArray()
  let attachmentA = newJsObject()
  attachmentA["view"] = trailViewA.toJs
  attachmentA["loadOp"] = "clear".cstring.toJs
  attachmentA["clearValue"] = bgColor
  attachmentA["storeOp"] = "store".cstring.toJs
  discard attachmentsA.push(attachmentA)
  clearPassDescA["colorAttachments"] = attachmentsA
  let clearPassA = initEncoder.beginRenderPass(clearPassDescA)
  clearPassA.endPass()

  # Clear texture B
  let clearPassDescB = newJsObject()
  clearPassDescB["label"] = "Clear Trail Texture B".cstring.toJs
  let attachmentsB = newJsArray()
  let attachmentB = newJsObject()
  attachmentB["view"] = trailViewB.toJs
  attachmentB["loadOp"] = "clear".cstring.toJs
  attachmentB["clearValue"] = bgColor
  attachmentB["storeOp"] = "store".cstring.toJs
  discard attachmentsB.push(attachmentB)
  clearPassDescB["colorAttachments"] = attachmentsB
  let clearPassB = initEncoder.beginRenderPass(clearPassDescB)
  clearPassB.endPass()

  # Submit initialization commands
  let initCommandBuffer = initEncoder.finish()
  let initCommandArray = newJsArray()
  discard initCommandArray.push(cast[JsObject](initCommandBuffer))
  webgpu_init.queue.submit(initCommandArray)

  # ==========================================================================
  # PRE-CACHED BIND GROUPS (created once, selected at runtime)
  # ==========================================================================

  # Blit bind group A (reads from trail texture A)
  let blitBGA = newJsObject()
  blitBGA["label"] = "Blit Bind Group A".cstring.toJs
  blitBGA["layout"] = blitBindGroupLayout.toJs
  let blitEntriesA = newJsArray()
  let blitBGAE0 = newJsObject()
  blitBGAE0["binding"] = 0.toJs
  blitBGAE0["resource"] = trailViewA.toJs
  discard blitEntriesA.push(blitBGAE0)
  let blitBGAE1 = newJsObject()
  blitBGAE1["binding"] = 1.toJs
  blitBGAE1["resource"] = linearSampler.toJs
  discard blitEntriesA.push(blitBGAE1)
  blitBGA["entries"] = blitEntriesA
  blitBindGroupA = webgpu_init.device.createBindGroup(blitBGA)

  # Blit bind group B (reads from trail texture B)
  let blitBGB = newJsObject()
  blitBGB["label"] = "Blit Bind Group B".cstring.toJs
  blitBGB["layout"] = blitBindGroupLayout.toJs
  let blitEntriesB = newJsArray()
  let blitBGBE0 = newJsObject()
  blitBGBE0["binding"] = 0.toJs
  blitBGBE0["resource"] = trailViewB.toJs
  discard blitEntriesB.push(blitBGBE0)
  let blitBGBE1 = newJsObject()
  blitBGBE1["binding"] = 1.toJs
  blitBGBE1["resource"] = linearSampler.toJs
  discard blitEntriesB.push(blitBGBE1)
  blitBGB["entries"] = blitEntriesB
  blitBindGroupB = webgpu_init.device.createBindGroup(blitBGB)

  # Fade bind group A (reads from trail texture A)
  let fadeBGA = newJsObject()
  fadeBGA["label"] = "Fade Bind Group Read A".cstring.toJs
  fadeBGA["layout"] = fadeBindGroupLayout.toJs
  let fadeEntriesA = newJsArray()
  let fadeBGAE0 = newJsObject()
  fadeBGAE0["binding"] = 0.toJs
  fadeBGAE0["resource"] = trailViewA.toJs
  discard fadeEntriesA.push(fadeBGAE0)
  let fadeBGAE1 = newJsObject()
  fadeBGAE1["binding"] = 1.toJs
  fadeBGAE1["resource"] = linearSampler.toJs
  discard fadeEntriesA.push(fadeBGAE1)
  let fadeBGAE2 = newJsObject()
  fadeBGAE2["binding"] = 2.toJs
  let fadeBGAR2 = newJsObject()
  fadeBGAR2["buffer"] = fadeParamsBuffer.toJs
  fadeBGAE2["resource"] = fadeBGAR2
  discard fadeEntriesA.push(fadeBGAE2)
  fadeBGA["entries"] = fadeEntriesA
  fadeBindGroupReadA = webgpu_init.device.createBindGroup(fadeBGA)

  # Fade bind group B (reads from trail texture B)
  let fadeBGB = newJsObject()
  fadeBGB["label"] = "Fade Bind Group Read B".cstring.toJs
  fadeBGB["layout"] = fadeBindGroupLayout.toJs
  let fadeEntriesB = newJsArray()
  let fadeBGBE0 = newJsObject()
  fadeBGBE0["binding"] = 0.toJs
  fadeBGBE0["resource"] = trailViewB.toJs
  discard fadeEntriesB.push(fadeBGBE0)
  let fadeBGBE1 = newJsObject()
  fadeBGBE1["binding"] = 1.toJs
  fadeBGBE1["resource"] = linearSampler.toJs
  discard fadeEntriesB.push(fadeBGBE1)
  let fadeBGBE2 = newJsObject()
  fadeBGBE2["binding"] = 2.toJs
  let fadeBGBR2 = newJsObject()
  fadeBGBR2["buffer"] = fadeParamsBuffer.toJs
  fadeBGBE2["resource"] = fadeBGBR2
  discard fadeEntriesB.push(fadeBGBE2)
  fadeBGB["entries"] = fadeEntriesB
  fadeBindGroupReadB = webgpu_init.device.createBindGroup(fadeBGB)

  # Create initial bind group
  updateBindGroup()

  isInitialized = true
  {.emit: "console.log('WebGPU render pipeline initialized with glow and trails');".}
  return true

proc updateBindGroup*() =
  ## Update bind group to use particlesA buffer.

  let particles = webgpu_init.buffers.particlesA

  let bindGroupDesc = newJsObject()
  bindGroupDesc["label"] = "Render Bind Group AoS".cstring.toJs

  # Get the bind group layout from the pipeline
  bindGroupDesc["layout"] = renderPipeline.getBindGroupLayout(0).toJs

  let entries = newJsArray()

  # Entry 0: particles (AoS buffer)
  let e0 = newJsObject()
  e0["binding"] = 0.toJs
  let r0 = newJsObject()
  r0["buffer"] = particles.toJs
  e0["resource"] = r0
  discard entries.push(e0)

  # Entry 1: render params
  let e1 = newJsObject()
  e1["binding"] = 1.toJs
  let r1 = newJsObject()
  r1["buffer"] = renderParamsBuffer.toJs
  e1["resource"] = r1
  discard entries.push(e1)

  bindGroupDesc["entries"] = entries
  renderBindGroup = webgpu_init.device.createBindGroup(bindGroupDesc)

  # Create glow bind group (same layout and buffers)
  let glowBindGroupDesc = newJsObject()
  glowBindGroupDesc["label"] = "Glow Bind Group AoS".cstring.toJs
  glowBindGroupDesc["layout"] = glowPipeline.getBindGroupLayout(0).toJs
  glowBindGroupDesc["entries"] = entries  # Reuse same entries
  glowBindGroup = webgpu_init.device.createBindGroup(glowBindGroupDesc)

# ==============================================================================
# SECTION 5: RENDER LOOP
# ==============================================================================

proc render*(particleCount: int): RenderTiming =
  ## Render particles using WebGPU with ping-pong trail rendering.
  ## Returns timing info (always 0 since no CPU work).
  ##
  ## Ping-pong architecture:
  ##   Frame N (trailParity=0): Read from A, Write to B, Blit B to screen
  ##   Frame N+1 (trailParity=1): Read from B, Write to A, Blit A to screen

  result = RenderTiming()
  result.packTimeMs = 0.0
  result.uploadTimeMs = 0.0

  if not isInitialized:
    return result

  # Update render params uniform (resolution, worldSize, baseSize, glowIntensity, velocityGlowScale, maxVelocity)
  let paramsData = newFloat32Array(8)
  paramsData[0] = float32(canvas.width)   # resolution.x
  paramsData[1] = float32(canvas.height)  # resolution.y
  paramsData[2] = float32(config.WORLD_W) # worldSize.x
  paramsData[3] = float32(config.WORLD_H) # worldSize.y
  paramsData[4] = float32(config.CONFIG.particleSize + 1)  # baseSize
  paramsData[5] = float32(config.CONFIG.glowIntensity)     # glowIntensity
  paramsData[6] = float32(config.CONFIG.velocityGlowScale) # velocityGlowScale
  paramsData[7] = float32(config.CONFIG.maxVelocity)       # maxVelocity
  webgpu_init.queue.writeBuffer(renderParamsBuffer, 0, paramsData)

  # Update fade params (fadeAmount = how much to fade toward background)
  let fadeData = newFloat32Array(4)
  fadeData[0] = float32(config.CONFIG.trailAlpha)  # fadeAmount (0 = no fade, 1 = instant clear)
  fadeData[1] = 0.0  # padding
  fadeData[2] = 0.0
  fadeData[3] = 0.0
  webgpu_init.queue.writeBuffer(fadeParamsBuffer, 0, fadeData)

  # Select pre-created resources based on trail parity (ZERO allocations)
  let writeView = if trailParity == 0: trailViewB else: trailViewA
  let fadeReadBG = if trailParity == 0: fadeBindGroupReadA else: fadeBindGroupReadB
  let blitBG = if trailParity == 0: blitBindGroupB else: blitBindGroupA

  # Create command encoder
  let encoderDesc = newJsObject()
  encoderDesc["label"] = "Render Command Encoder".cstring.toJs
  let commandEncoder = webgpu_init.device.createCommandEncoder(encoderDesc)

  # ==========================================================================
  # PASS 1: OFFSCREEN RENDER (to persistent trail texture)
  # ==========================================================================

  let offscreenPassDesc = newJsObject()
  offscreenPassDesc["label"] = "Offscreen Render Pass".cstring.toJs

  let offscreenAttachments = newJsArray()
  let offscreenAttachment = newJsObject()
  offscreenAttachment["view"] = writeView.toJs
  offscreenAttachment["loadOp"] = "clear".cstring.toJs
  # Transparent clear - glow shows through from present pass
  let clearColor = newJsObject()
  clearColor["r"] = 0.0.toJs
  clearColor["g"] = 0.0.toJs
  clearColor["b"] = 0.0.toJs
  clearColor["a"] = 0.0.toJs
  offscreenAttachment["clearValue"] = clearColor
  offscreenAttachment["storeOp"] = "store".cstring.toJs
  discard offscreenAttachments.push(offscreenAttachment)
  offscreenPassDesc["colorAttachments"] = offscreenAttachments

  # Add depth attachment for Z-ordering
  let depthAttachment = newJsObject()
  depthAttachment["view"] = depthTextureView.toJs
  depthAttachment["depthLoadOp"] = "clear".cstring.toJs
  depthAttachment["depthClearValue"] = 1.0.toJs  # Far plane
  depthAttachment["depthStoreOp"] = "store".cstring.toJs
  offscreenPassDesc["depthStencilAttachment"] = depthAttachment

  let offscreenPass = commandEncoder.beginRenderPass(offscreenPassDesc)

  # Step 1: Draw faded previous frame (if trails enabled)
  if config.CONFIG.trails:
    offscreenPass.setPipeline(fadePipeline)
    offscreenPass.setBindGroup(0, fadeReadBG)
    offscreenPass.draw(3, 1, 0, 0)  # Fullscreen triangle

  # Step 2: Draw particles (alpha blending, crisp circles)
  # NOTE: Glow is drawn in present pass (not here) to avoid accumulating in trails
  offscreenPass.setPipeline(renderPipeline)
  offscreenPass.setBindGroup(0, renderBindGroup)
  offscreenPass.draw(6 * particleCount, 1, 0, 0)

  offscreenPass.endPass()

  # ==========================================================================
  # PASS 2: BLIT TO SWAP CHAIN (always use loadOp="clear" per WebGPU spec)
  # ==========================================================================

  let currentTexture = gpuContext.getCurrentTexture()
  let swapChainView = currentTexture.createView()

  let presentPassDesc = newJsObject()
  presentPassDesc["label"] = "Present Pass".cstring.toJs

  let presentAttachments = newJsArray()
  let presentAttachment = newJsObject()
  presentAttachment["view"] = swapChainView.toJs
  presentAttachment["loadOp"] = "clear".cstring.toJs
  # Clear to actual background color (opaque) - glow draws on this, then trail alpha-blends on top
  let presentClearColor = newJsObject()
  presentClearColor["r"] = 0.04.toJs
  presentClearColor["g"] = 0.04.toJs
  presentClearColor["b"] = 0.06.toJs
  presentClearColor["a"] = 1.0.toJs
  presentAttachment["clearValue"] = presentClearColor
  presentAttachment["storeOp"] = "store".cstring.toJs
  discard presentAttachments.push(presentAttachment)
  presentPassDesc["colorAttachments"] = presentAttachments

  # Depth attachment required for glow pipeline (which has depth stencil config)
  let presentDepthAttachment = newJsObject()
  presentDepthAttachment["view"] = depthTextureView.toJs
  presentDepthAttachment["depthLoadOp"] = "clear".cstring.toJs
  presentDepthAttachment["depthClearValue"] = 1.0.toJs
  presentDepthAttachment["depthStoreOp"] = "discard".cstring.toJs  # Don't need depth after this
  presentPassDesc["depthStencilAttachment"] = presentDepthAttachment

  let presentPass = commandEncoder.beginRenderPass(presentPassDesc)

  # Step 1: Draw glow FIRST (additive blending on background)
  # Glow renders beneath particles because trail alpha-blends on top
  presentPass.setPipeline(glowPipeline)
  presentPass.setBindGroup(0, glowBindGroup)
  presentPass.draw(6 * particleCount, 1, 0, 0)

  # Step 2: Alpha-blit trail texture on top of glow
  # Trail has transparent background where no particles, so glow shows through
  presentPass.setPipeline(blitPipeline)
  presentPass.setBindGroup(0, blitBG)
  presentPass.draw(3, 1, 0, 0)  # Fullscreen triangle

  presentPass.endPass()

  # Submit
  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = newJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  webgpu_init.queue.submit(commandBufferArray)

  # Flip trail parity for next frame
  trailParity = 1 - trailParity

proc recreateTrailTextures() =
  ## Recreate trail textures and bind groups at current canvas size.
  ## Called on resize. Destroys old resources before creating new ones.

  # Destroy old textures (safe even if nil on first call)
  if not trailTextureA.isNil:
    trailTextureA.destroy()
  if not trailTextureB.isNil:
    trailTextureB.destroy()
  if not depthTexture.isNil:
    depthTexture.destroy()

  # Create new textures at current canvas size
  let trailTextureDesc = newJsObject()
  let trailSize = newJsArray()
  discard trailSize.push(canvas.width.toJs)
  discard trailSize.push(canvas.height.toJs)
  trailTextureDesc["size"] = trailSize
  trailTextureDesc["format"] = canvasFormat.toJs
  trailTextureDesc["usage"] = bitwiseOr(gpuTextureUsageRenderAttachment, gpuTextureUsageTextureBinding).toJs
  trailTextureDesc["label"] = "Trail Texture A".cstring.toJs
  trailTextureA = webgpu_init.device.createTexture(trailTextureDesc)
  trailTextureDesc["label"] = "Trail Texture B".cstring.toJs
  trailTextureB = webgpu_init.device.createTexture(trailTextureDesc)

  trailViewA = trailTextureA.createView()
  trailViewB = trailTextureB.createView()

  # Recreate depth texture at new canvas size
  let depthTextureDesc = newJsObject()
  let depthSize = newJsArray()
  discard depthSize.push(canvas.width.toJs)
  discard depthSize.push(canvas.height.toJs)
  depthTextureDesc["size"] = depthSize
  depthTextureDesc["format"] = "depth24plus".cstring.toJs
  depthTextureDesc["usage"] = gpuTextureUsageRenderAttachment.toJs
  depthTextureDesc["label"] = "Depth Texture".cstring.toJs
  depthTexture = webgpu_init.device.createTexture(depthTextureDesc)
  depthTextureView = depthTexture.createView()

  # Clear new textures to transparent (same as initWebGPURender)
  let clearEncoderDesc = newJsObject()
  clearEncoderDesc["label"] = "Trail Texture Clear (resize)".cstring.toJs
  let clearEncoder = webgpu_init.device.createCommandEncoder(clearEncoderDesc)

  let bgColorResize = newJsObject()
  bgColorResize["r"] = 0.0.toJs
  bgColorResize["g"] = 0.0.toJs
  bgColorResize["b"] = 0.0.toJs
  bgColorResize["a"] = 0.0.toJs

  # Clear texture A
  let clearDescA = newJsObject()
  clearDescA["label"] = "Clear Trail A (resize)".cstring.toJs
  let clearAttachA = newJsArray()
  let clearAttA = newJsObject()
  clearAttA["view"] = trailViewA.toJs
  clearAttA["loadOp"] = "clear".cstring.toJs
  clearAttA["clearValue"] = bgColorResize
  clearAttA["storeOp"] = "store".cstring.toJs
  discard clearAttachA.push(clearAttA)
  clearDescA["colorAttachments"] = clearAttachA
  let clearA = clearEncoder.beginRenderPass(clearDescA)
  clearA.endPass()

  # Clear texture B
  let clearDescB = newJsObject()
  clearDescB["label"] = "Clear Trail B (resize)".cstring.toJs
  let clearAttachB = newJsArray()
  let clearAttB = newJsObject()
  clearAttB["view"] = trailViewB.toJs
  clearAttB["loadOp"] = "clear".cstring.toJs
  clearAttB["clearValue"] = bgColorResize
  clearAttB["storeOp"] = "store".cstring.toJs
  discard clearAttachB.push(clearAttB)
  clearDescB["colorAttachments"] = clearAttachB
  let clearB = clearEncoder.beginRenderPass(clearDescB)
  clearB.endPass()

  # Submit clear commands
  let clearCmdBuf = clearEncoder.finish()
  let clearCmdArr = newJsArray()
  discard clearCmdArr.push(cast[JsObject](clearCmdBuf))
  webgpu_init.queue.submit(clearCmdArr)

  # Recreate blit bind groups (reference trail texture views)
  let blitBGA = newJsObject()
  blitBGA["label"] = "Blit Bind Group A".cstring.toJs
  blitBGA["layout"] = blitBindGroupLayout.toJs
  let blitEntriesA = newJsArray()
  let blitBGAE0 = newJsObject()
  blitBGAE0["binding"] = 0.toJs
  blitBGAE0["resource"] = trailViewA.toJs
  discard blitEntriesA.push(blitBGAE0)
  let blitBGAE1 = newJsObject()
  blitBGAE1["binding"] = 1.toJs
  blitBGAE1["resource"] = linearSampler.toJs
  discard blitEntriesA.push(blitBGAE1)
  blitBGA["entries"] = blitEntriesA
  blitBindGroupA = webgpu_init.device.createBindGroup(blitBGA)

  let blitBGB = newJsObject()
  blitBGB["label"] = "Blit Bind Group B".cstring.toJs
  blitBGB["layout"] = blitBindGroupLayout.toJs
  let blitEntriesB = newJsArray()
  let blitBGBE0 = newJsObject()
  blitBGBE0["binding"] = 0.toJs
  blitBGBE0["resource"] = trailViewB.toJs
  discard blitEntriesB.push(blitBGBE0)
  let blitBGBE1 = newJsObject()
  blitBGBE1["binding"] = 1.toJs
  blitBGBE1["resource"] = linearSampler.toJs
  discard blitEntriesB.push(blitBGBE1)
  blitBGB["entries"] = blitEntriesB
  blitBindGroupB = webgpu_init.device.createBindGroup(blitBGB)

  # Recreate fade bind groups (reference trail texture views)
  let fadeBGA = newJsObject()
  fadeBGA["label"] = "Fade Bind Group Read A".cstring.toJs
  fadeBGA["layout"] = fadeBindGroupLayout.toJs
  let fadeEntriesA = newJsArray()
  let fadeBGAE0 = newJsObject()
  fadeBGAE0["binding"] = 0.toJs
  fadeBGAE0["resource"] = trailViewA.toJs
  discard fadeEntriesA.push(fadeBGAE0)
  let fadeBGAE1 = newJsObject()
  fadeBGAE1["binding"] = 1.toJs
  fadeBGAE1["resource"] = linearSampler.toJs
  discard fadeEntriesA.push(fadeBGAE1)
  let fadeBGAE2 = newJsObject()
  fadeBGAE2["binding"] = 2.toJs
  let fadeBGAR2 = newJsObject()
  fadeBGAR2["buffer"] = fadeParamsBuffer.toJs
  fadeBGAE2["resource"] = fadeBGAR2
  discard fadeEntriesA.push(fadeBGAE2)
  fadeBGA["entries"] = fadeEntriesA
  fadeBindGroupReadA = webgpu_init.device.createBindGroup(fadeBGA)

  let fadeBGB = newJsObject()
  fadeBGB["label"] = "Fade Bind Group Read B".cstring.toJs
  fadeBGB["layout"] = fadeBindGroupLayout.toJs
  let fadeEntriesB = newJsArray()
  let fadeBGBE0 = newJsObject()
  fadeBGBE0["binding"] = 0.toJs
  fadeBGBE0["resource"] = trailViewB.toJs
  discard fadeEntriesB.push(fadeBGBE0)
  let fadeBGBE1 = newJsObject()
  fadeBGBE1["binding"] = 1.toJs
  fadeBGBE1["resource"] = linearSampler.toJs
  discard fadeEntriesB.push(fadeBGBE1)
  let fadeBGBE2 = newJsObject()
  fadeBGBE2["binding"] = 2.toJs
  let fadeBGBR2 = newJsObject()
  fadeBGBR2["buffer"] = fadeParamsBuffer.toJs
  fadeBGBE2["resource"] = fadeBGBR2
  discard fadeEntriesB.push(fadeBGBE2)
  fadeBGB["entries"] = fadeEntriesB
  fadeBindGroupReadB = webgpu_init.device.createBindGroup(fadeBGB)

  # Reset trail parity to start fresh
  trailParity = 0

proc resize*() =
  ## Handle canvas resize. Recreates trail textures at new dimensions.
  canvas.width = windowInnerWidth()
  canvas.height = windowInnerHeight()

  # Recreate trail textures and bind groups at new size
  if isInitialized:
    recreateTrailTextures()

# ==============================================================================
# SECTION 6: COMPATIBILITY SHIM
# ==============================================================================

# These exist for compatibility with the current app.nim interface
proc initGL*(): bool =
  ## Compatibility shim - initializes WebGPU render instead.
  ## Returns true if WebGPU is available and initialized.
  # WebGPU init is done separately, this is called after
  return initWebGPURender()
