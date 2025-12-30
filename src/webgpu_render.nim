# ==============================================================================
# EMERGENT GARDEN - WEBGPU RENDER MODULE
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
var renderBindGroup: GPUBindGroup
var glowBindGroup: GPUBindGroup
var renderParamsBuffer: GPUBuffer
var bindGroupLayout: GPUBindGroupLayout  # Store original layout for bind group creation
var isInitialized: bool = false

# Current parity for which buffer set to read from
var activeParity*: int = 0

# ==============================================================================
# SECTION 3: SHADER SOURCE
# ==============================================================================

const RENDER_SHADER = staticRead("../web/shaders/render.wgsl")

# Glow shader - larger particles with Gaussian falloff
const GLOW_SHADER = """
struct RenderParams {
  resolution: vec2f,
  baseSize: f32,
  padding: f32,
};

const OFFSETS = array<vec2f, 6>(
  vec2f(-1.0, -1.0),
  vec2f( 1.0, -1.0),
  vec2f(-1.0,  1.0),
  vec2f(-1.0,  1.0),
  vec2f( 1.0, -1.0),
  vec2f( 1.0,  1.0),
);

const COLORS = array<vec3f, 6>(
  vec3f(1.0, 0.4, 0.4),
  vec3f(0.4, 1.0, 0.4),
  vec3f(0.4, 0.7, 1.0),
  vec3f(1.0, 1.0, 0.4),
  vec3f(1.0, 0.4, 1.0),
  vec3f(0.4, 1.0, 1.0),
);

@group(0) @binding(0) var<storage, read> px: array<f32>;
@group(0) @binding(1) var<storage, read> py: array<f32>;
@group(0) @binding(2) var<storage, read> species: array<u32>;
@group(0) @binding(3) var<storage, read> density: array<f32>;
@group(0) @binding(4) var<uniform> params: RenderParams;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) color: vec3f,
  @location(1) offset: vec2f,
};

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;
  let particleId = id / 6u;
  let cornerId = id % 6u;

  let particleX = px[particleId];
  let particleY = py[particleId];
  let particleSpecies = species[particleId];

  let offset = OFFSETS[cornerId];

  // Glow is 12 pixels radius
  let glowRadius = 12.0;
  let worldPos = vec2f(particleX, particleY) + offset * glowRadius;

  let normalizedPos = (worldPos / params.resolution) * 2.0 - 1.0;
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, 0.0, 1.0);
  output.offset = offset;
  output.color = COLORS[min(particleSpecies, 5u)];

  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let l = length(input.offset);

  // Gaussian falloff: exp(-6 * l^2) / 64
  let alpha = exp(-6.0 * l * l) / 64.0;

  // Premultiplied alpha for additive blending
  return vec4f(input.color * alpha, alpha);
}
"""

# ==============================================================================
# SECTION 4: INITIALIZATION
# ==============================================================================

# Forward declaration
proc updateBindGroup*(parity: int)

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

  let canvasFormat = getPreferredCanvasFormat()
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

  # Create render params uniform buffer (resolution, baseSize)
  let paramsSize = 16  # vec2f + f32 + padding = 16 bytes
  let paramsDesc = newJsObject()
  paramsDesc["size"] = paramsSize.toJs
  paramsDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  paramsDesc["label"] = "Render Params Buffer".cstring.toJs
  renderParamsBuffer = webgpu_init.device.createBuffer(paramsDesc)

  # Create bind group layout
  let layoutDesc = newJsObject()
  layoutDesc["label"] = "Render Bind Group Layout".cstring.toJs

  let entries = newJsArray()

  # Binding 0: px (storage buffer, read-only)
  let entry0 = newJsObject()
  entry0["binding"] = 0.toJs
  entry0["visibility"] = gpuShaderStageVertex.toJs
  let buffer0 = newJsObject()
  buffer0["type"] = "read-only-storage".cstring.toJs
  entry0["buffer"] = buffer0
  discard entries.push(entry0)

  # Binding 1: py (storage buffer, read-only)
  let entry1 = newJsObject()
  entry1["binding"] = 1.toJs
  entry1["visibility"] = gpuShaderStageVertex.toJs
  let buffer1 = newJsObject()
  buffer1["type"] = "read-only-storage".cstring.toJs
  entry1["buffer"] = buffer1
  discard entries.push(entry1)

  # Binding 2: species (storage buffer, read-only)
  let entry2 = newJsObject()
  entry2["binding"] = 2.toJs
  entry2["visibility"] = gpuShaderStageVertex.toJs
  let buffer2 = newJsObject()
  buffer2["type"] = "read-only-storage".cstring.toJs
  entry2["buffer"] = buffer2
  discard entries.push(entry2)

  # Binding 3: density (storage buffer, read-only)
  let entry3 = newJsObject()
  entry3["binding"] = 3.toJs
  entry3["visibility"] = gpuShaderStageVertex.toJs
  let buffer3 = newJsObject()
  buffer3["type"] = "read-only-storage".cstring.toJs
  entry3["buffer"] = buffer3
  discard entries.push(entry3)

  # Binding 4: render params (uniform buffer)
  let entry4 = newJsObject()
  entry4["binding"] = 4.toJs
  entry4["visibility"] = gpuShaderStageVertex.toJs
  let buffer4 = newJsObject()
  buffer4["type"] = "uniform".cstring.toJs
  entry4["buffer"] = buffer4
  discard entries.push(entry4)

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

  glowPipeline = webgpu_init.device.createRenderPipeline(glowPipelineDesc)

  # Create initial bind group with buffer set A
  updateBindGroup(0)

  isInitialized = true
  {.emit: "console.log('WebGPU render pipeline initialized with glow');".}
  return true

proc updateBindGroup*(parity: int) =
  ## Update bind group to use the correct buffer set (A or B) based on parity.

  let px = if parity == 0: webgpu_init.buffers.pxA else: webgpu_init.buffers.pxB
  let py = if parity == 0: webgpu_init.buffers.pyA else: webgpu_init.buffers.pyB
  let species = if parity == 0: webgpu_init.buffers.speciesA else: webgpu_init.buffers.speciesB
  let density = if parity == 0: webgpu_init.buffers.denA else: webgpu_init.buffers.denB

  let bindGroupDesc = newJsObject()
  bindGroupDesc["label"] = ("Render Bind Group (parity " & $parity & ")").cstring.toJs

  # Get the bind group layout from the pipeline
  bindGroupDesc["layout"] = renderPipeline.getBindGroupLayout(0).toJs

  let entries = newJsArray()

  # Entry 0: px
  let e0 = newJsObject()
  e0["binding"] = 0.toJs
  let r0 = newJsObject()
  r0["buffer"] = px.toJs
  e0["resource"] = r0
  discard entries.push(e0)

  # Entry 1: py
  let e1 = newJsObject()
  e1["binding"] = 1.toJs
  let r1 = newJsObject()
  r1["buffer"] = py.toJs
  e1["resource"] = r1
  discard entries.push(e1)

  # Entry 2: species
  let e2 = newJsObject()
  e2["binding"] = 2.toJs
  let r2 = newJsObject()
  r2["buffer"] = species.toJs
  e2["resource"] = r2
  discard entries.push(e2)

  # Entry 3: density
  let e3 = newJsObject()
  e3["binding"] = 3.toJs
  let r3 = newJsObject()
  r3["buffer"] = density.toJs
  e3["resource"] = r3
  discard entries.push(e3)

  # Entry 4: render params
  let e4 = newJsObject()
  e4["binding"] = 4.toJs
  let r4 = newJsObject()
  r4["buffer"] = renderParamsBuffer.toJs
  e4["resource"] = r4
  discard entries.push(e4)

  bindGroupDesc["entries"] = entries
  renderBindGroup = webgpu_init.device.createBindGroup(bindGroupDesc)

  # Create glow bind group (same layout and buffers)
  let glowBindGroupDesc = newJsObject()
  glowBindGroupDesc["label"] = ("Glow Bind Group (parity " & $parity & ")").cstring.toJs
  glowBindGroupDesc["layout"] = glowPipeline.getBindGroupLayout(0).toJs
  glowBindGroupDesc["entries"] = entries  # Reuse same entries
  glowBindGroup = webgpu_init.device.createBindGroup(glowBindGroupDesc)

  activeParity = parity

# ==============================================================================
# SECTION 5: RENDER LOOP
# ==============================================================================

proc render*(particleCount: int): RenderTiming =
  ## Render particles using WebGPU.
  ## Returns timing info (always 0 since no CPU work).

  result = RenderTiming()
  result.packTimeMs = 0.0
  result.uploadTimeMs = 0.0

  if not isInitialized:
    return result

  # Update render params uniform
  let paramsData = newFloat32Array(4)
  paramsData[0] = float32(canvas.width)
  paramsData[1] = float32(canvas.height)
  paramsData[2] = float32(config.CONFIG.particleSize + 1)
  paramsData[3] = 0.0  # padding
  webgpu_init.queue.writeBuffer(renderParamsBuffer, 0, paramsData)

  # Get current texture to render to
  let currentTexture = gpuContext.getCurrentTexture()
  let textureView = currentTexture.createView()

  # Create command encoder
  let encoderDesc = newJsObject()
  encoderDesc["label"] = "Render Command Encoder".cstring.toJs
  let commandEncoder = webgpu_init.device.createCommandEncoder(encoderDesc)

  # Begin render pass
  let renderPassDesc = newJsObject()
  renderPassDesc["label"] = "Particle Render Pass".cstring.toJs

  let colorAttachments = newJsArray()
  let colorAttachment = newJsObject()
  colorAttachment["view"] = textureView.toJs
  colorAttachment["loadOp"] = "clear".cstring.toJs
  colorAttachment["storeOp"] = "store".cstring.toJs
  let clearColor = newJsObject()
  clearColor["r"] = 0.04.toJs
  clearColor["g"] = 0.04.toJs
  clearColor["b"] = 0.06.toJs
  clearColor["a"] = 1.0.toJs
  colorAttachment["clearValue"] = clearColor
  discard colorAttachments.push(colorAttachment)
  renderPassDesc["colorAttachments"] = colorAttachments

  let renderPass = commandEncoder.beginRenderPass(renderPassDesc)

  # Pass 1: Draw glow (additive blending, larger radius)
  renderPass.setPipeline(glowPipeline)
  renderPass.setBindGroup(0, glowBindGroup)
  renderPass.draw(6 * particleCount, 1, 0, 0)

  # Pass 2: Draw particles (alpha blending, crisp circles)
  renderPass.setPipeline(renderPipeline)
  renderPass.setBindGroup(0, renderBindGroup)
  renderPass.draw(6 * particleCount, 1, 0, 0)

  renderPass.endPass()

  # Submit
  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = newJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  webgpu_init.queue.submit(commandBufferArray)

proc resize*() =
  ## Handle canvas resize. Must set canvas dimensions explicitly.
  canvas.width = windowInnerWidth()
  canvas.height = windowInnerHeight()

# ==============================================================================
# SECTION 6: COMPATIBILITY SHIM
# ==============================================================================

# These exist for compatibility with the current app.nim interface
proc initGL*(): bool =
  ## Compatibility shim - initializes WebGPU render instead.
  ## Returns true if WebGPU is available and initialized.
  # WebGPU init is done separately, this is called after
  return initWebGPURender()
