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
import std/math
import bindings/js_interop
import bindings/webgpu
import bindings/typed_arrays
import bindings/dom_extensions
import bindings/window
import config
import webgpu_init
import gpu_profiler
import gpu_types

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
var colorBuffer: GPUBuffer
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

# Glow, fade, and composite (blit) shaders live in web/shaders/src/ and go
# through the same bundler pipeline as render.wgsl - staticRead means a
# missing/malformed bundled file is a build-time failure, not a runtime 404.
const GLOW_SHADER = staticRead("../web/shaders/glow.wgsl")
const FADE_SHADER = staticRead("../web/shaders/fade.wgsl")
const BLIT_SHADER = staticRead("../web/shaders/composite.wgsl")

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

  # Create render params uniform buffer (resolution, worldSize, baseSize, glowIntensity, etc.)
  let paramsSize = 48  # 12 floats × 4 bytes = 48 bytes (RENDER_PARAMS_F32_COUNT)
  let paramsDesc = newJsObject()
  paramsDesc["size"] = paramsSize.toJs
  paramsDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  paramsDesc["label"] = "Render Params Buffer".cstring.toJs
  renderParamsBuffer = webgpu_init.device.createBuffer(paramsDesc)

  # Create species color uniform buffer (6 vec4f for 16-byte alignment)
  let colorBufferSize = 6 * 4 * 4  # 6 species × 4 floats × 4 bytes = 96 bytes
  let colorDesc = newJsObject()
  colorDesc["size"] = colorBufferSize.toJs
  colorDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  colorDesc["label"] = "Species Colors Buffer".cstring.toJs
  colorBuffer = webgpu_init.device.createBuffer(colorDesc)

  # Create bind group layout (AoS: 3 bindings - particles + renderParams + colors)
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

  # Binding 2: species colors (uniform buffer) - vertex only
  let entry2 = newJsObject()
  entry2["binding"] = 2.toJs
  entry2["visibility"] = gpuShaderStageVertex.toJs
  let buffer2 = newJsObject()
  buffer2["type"] = "uniform".cstring.toJs
  entry2["buffer"] = buffer2
  discard entries.push(entry2)

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

  # Entry 2: species colors
  let e2 = newJsObject()
  e2["binding"] = 2.toJs
  let r2 = newJsObject()
  r2["buffer"] = colorBuffer.toJs
  e2["resource"] = r2
  discard entries.push(e2)

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

  # Update render params uniform
  # Layout matches RenderParams indices in gpu_types.nim
  let paramsData = newFloat32Array(RENDER_PARAMS_F32_COUNT)
  paramsData[RENDER_RESOLUTION_X] = float32(canvas.width)
  paramsData[RENDER_RESOLUTION_Y] = float32(canvas.height)
  paramsData[RENDER_WORLD_SIZE_X] = float32(config.WORLD_W)
  paramsData[RENDER_WORLD_SIZE_Y] = float32(config.WORLD_H)
  paramsData[RENDER_BASE_SIZE] = float32(config.CONFIG.particleSize + 1)
  paramsData[RENDER_GLOW_INTENSITY] = float32(config.CONFIG.glowIntensity)
  paramsData[RENDER_VELOCITY_GLOW_SCALE] = float32(config.CONFIG.velocityGlowScale)
  paramsData[RENDER_MAX_VELOCITY] = float32(config.CONFIG.maxVelocity)
  # Trail length scale: convert 0-100 slider to shader-friendly multiplier
  # At trailLength=0: no elongation. At trailLength=100: significant elongation
  let trailLengthScale = config.CONFIG.trailLength * 0.02  # Scale factor for motion blur
  paramsData[RENDER_TRAIL_LENGTH_SCALE] = float32(trailLengthScale)
  paramsData[RENDER_GLOW_RADIUS_SCALE] = float32(config.CONFIG.glowRadiusScale)
  paramsData[RENDER_GLOW_FALLOFF] = float32(config.CONFIG.glowFalloff)
  paramsData[RENDER_GLOW_WARMTH] = float32(config.CONFIG.glowWarmth)
  webgpu_init.queue.writeBuffer(renderParamsBuffer, 0, paramsData)

  # Update species colors uniform (pack RGB as vec4f for 16-byte alignment)
  let colorData = newFloat32Array(24)  # 6 colors × 4 floats
  for i in 0 ..< 6:
    colorData[i * 4 + 0] = config.COLORS[i * 3 + 0]
    colorData[i * 4 + 1] = config.COLORS[i * 3 + 1]
    colorData[i * 4 + 2] = config.COLORS[i * 3 + 2]
    colorData[i * 4 + 3] = 1.0  # padding/alpha
  webgpu_init.queue.writeBuffer(colorBuffer, 0, colorData)

  # Update fade params
  # Layout matches FadeParams indices in gpu_types.nim
  # Convert trail length (0-100 particle diameters) to decay factor
  # fadeAmount: higher = more of previous frame retained = longer trails
  let fadeAmount = if config.CONFIG.trailLength <= 0.0:
    0.0  # No trails: instant clear
  else:
    # Approximate frames to show trailLength worth of trail
    # At 60fps, typical particle covers ~1 diameter per 2 frames
    let framesVisible = config.CONFIG.trailLength * 2.0
    # Decay to 5% visibility over that many frames: decay^frames = 0.05
    pow(0.05, 1.0 / framesVisible)
  let fadeData = newFloat32Array(FADE_PARAMS_F32_COUNT)
  fadeData[FADE_AMOUNT] = float32(fadeAmount)
  fadeData[FADE_PAD1] = 0.0
  fadeData[FADE_PAD2] = 0.0
  fadeData[FADE_PAD3] = 0.0
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
  gpu_profiler.attachTimestamps(offscreenPassDesc, gpu_profiler.passDraw)

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
  gpu_profiler.attachTimestamps(presentPassDesc, gpu_profiler.passPresent)

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
  # GUARANTEE: Glow is ALWAYS behind particles because:
  #   - Glow draws here with depthCompare="less" (but depth just cleared to 1.0)
  #   - Trail blit uses depthCompare="always" — ignores depth entirely
  #   - So particles in trail texture always alpha-blend on top of glow
  presentPass.setPipeline(glowPipeline)
  presentPass.setBindGroup(0, glowBindGroup)
  presentPass.draw(6 * particleCount, 1, 0, 0)

  # Step 2: Alpha-blit trail texture on top of glow
  # Trail has transparent background where no particles, so glow shows through
  presentPass.setPipeline(blitPipeline)
  presentPass.setBindGroup(0, blitBG)
  presentPass.draw(3, 1, 0, 0)  # Fullscreen triangle

  presentPass.endPass()

  # Resolve pass timestamps (render encoder is the frame's final submit)
  gpu_profiler.encodeResolve(commandEncoder)

  # Submit
  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = newJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  webgpu_init.queue.submit(commandBufferArray)
  gpu_profiler.pumpReadback()

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
