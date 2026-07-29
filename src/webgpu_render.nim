# ==============================================================================
# PARTICLE GARDEN - WEBGPU RENDER MODULE
# ==============================================================================
#
# GPU-only particle rendering using WebGPU render pipeline.
# Reads particle data directly from compute shader storage buffers.
# Zero CPU readback - all data stays on GPU.
#
# ARCHITECTURE:
# - One quad per particle, six vertices each, drawn as a single instance
# - Vertex shader splits vertex_index into particle (id / 6) and corner
#   (id % 6), then reads that particle from the storage buffer
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
import gpu_profiler
import gpu_types
# webgpu_compute is imported before webgpu_render in app.nim's dependency order,
# so reading its state here does not disturb the JS-backend hoisting.
import webgpu_compute
# camera_core is pure; it owns the Camera type and the toroidal transform that
# camera_transform.wgsl mirrors. The uniform written here is that type's fields.
import camera_core
# colormap_core is pure; it supplies FIELD_DRIFT_SCALE, how far the fade pass
# displaces the trail along the field gradient. It sits beside the field's other
# render-coupling constants there rather than here, so the calibration pass has
# one place to look.
import colormap_core
# trail_core is pure; it owns the trail length -> fade multiplier mapping and
# mirrors the decay fade.wgsl runs with it. The uniform written below is that
# mapping's output, so the number the GPU receives is the one the native suite
# measures rather than a second copy of the same arithmetic.
import trail_core
# overlay_core is pure; it owns the spatial drag overlay's closed set and
# mirrors overlay.wgsl's coverage math.
import overlay_core
# canvas_input sits a layer below (app.nim's import order); it carries the
# drag-active parameter id the panel writes and the cursor the ring follows.
import canvas_input

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

# ==============================================================================
# SECTION 2: MODULE STATE
# ==============================================================================

var canvas*: HTMLCanvasElement
var gpuContext: GPUCanvasContext
var renderPipeline: GPURenderPipeline
var glowPipeline: GPURenderPipeline
var fadePipeline: GPURenderPipeline
var blitPipeline: GPURenderPipeline
var overlayPipeline: GPURenderPipeline
var overlayBindGroup: GPUBindGroup
var overlayParamsBuffer: GPUBuffer
var renderBindGroup: GPUBindGroup
var glowBindGroup: GPUBindGroup
var renderParamsBuffer: GPUBuffer
var colorBuffer: GPUBuffer
var fadeParamsBuffer: GPUBuffer
var cameraBuffer: GPUBuffer
var prevCameraBuffer: GPUBuffer
  ## The previous frame's view, in the same CameraLayout the live one uses. The
  ## fade pass binds it beside the live camera and reprojects the trail between
  ## the two.
var activeCamera: Camera
  ## The live view. Owned here because the render loop is the only thing that
  ## reads it every frame; the input handlers move it through setCamera.
var previousCamera: Camera
  ## The view the trail texture was last drawn under. The fade pass needs BOTH
  ## cameras to reproject: where a world point is now, and where it sat on the
  ## frame whose trail it is reading. Updated at the END of each render, so
  ## within a frame it still names the previous one.
var lastUploadedCamera: Camera = Camera(centerX: 0.0, centerY: 0.0, zoom: 0.0)
  ## The view the camera uniform currently holds. A frame that moved nothing
  ## skips the upload, which is most frames. Zoom 0 sits below CAMERA_ZOOM_MIN
  ## and so matches no reachable camera, which forces the first upload after
  ## the buffer is created; initWebGPURender puts it back on buffer creation so
  ## a rebuilt buffer is never left holding a stale view.
var lastUploadedPrevCamera: Camera = Camera(centerX: 0.0, centerY: 0.0, zoom: 0.0)
  ## The same record for the previous-frame buffer, armed the same way. The two
  ## buffers change on different frames — the live view moves when the user
  ## moves it, the previous view follows one frame behind — so each carries its
  ## own skip test.
let cameraData = newFloat32Array(CAMERA_PARAMS_F32_COUNT)
  ## Scratch for those uploads, allocated once and refilled in place. Shared by
  ## both because queue.writeBuffer copies what it is given before it returns.

# Staging arrays for the other per-frame uniform uploads, allocated once and
# refilled in place. Every slot each one carries is written unconditionally
# before its upload, so nothing survives a frame; the slots no writer touches
# stay at the zero they were allocated with, exactly as a freshly allocated
# array gave them.
let renderParamsData = newFloat32Array(RENDER_PARAMS_F32_COUNT)
let overlayParamsData = newFloat32Array(OVERLAY_PARAMS_F32_COUNT)
let fadeData = newFloat32Array(FADE_PARAMS_F32_COUNT)
let tonemapData = newFloat32Array(TONEMAP_PARAMS_F32_COUNT)
let colorData = newFloat32Array(24)
  ## Six species colors, one vec4f each for 16-byte alignment. Unlike the
  ## arrays above this one is also the record of what colorBuffer already
  ## holds, which is what lets a frame that changed no color skip the upload
  ## entirely — the palette moves when someone edits it, not once a frame.
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

# Reaction-diffusion field composite (LDR backdrop, present pass, bloom off).
# Reuses the blit bind-group layout (texture + sampler). The bind group is (re)built
# lazily when webgpu_init.fieldGeneration() changes, mirroring the trail-texture
# caching pattern; -1 forces a first build.
var fieldCompositePipeline: GPURenderPipeline
var fieldCompositeBindGroup: GPUBindGroup
var fieldCompositeBindGroupLayout: GPUBindGroupLayout
var cachedFieldGeneration: int = -1
var cachedRenderFieldGeneration: int = -1
  ## The same caching pattern for the render/glow bind groups, which bind the
  ## field texture so the vertex stage can light particles by it. Separate from
  ## cachedFieldGeneration because these groups are also rebuilt on resize (the
  ## pre-field placeholder view is a bloom target, and those are recreated
  ## there), so the two cannot share a counter without one path defeating the
  ## other's caching.

# ==============================================================================
# HDR BLOOM RESOURCES (S9)
# ==============================================================================
# When CONFIG.bloomEnabled is on, the glow draw is retargeted from the present
# pass into a half-resolution rgba16float HDR target, separably blurred (H then
# V ping-pong between the two half-res targets), and composited over the trail
# by the tonemap pass. Bloom off is the untouched quality floor: the glow draws
# straight into the swap chain and the plain blit presents the trail.
#
# BLOOM_DOWNSCALE is the linear divisor for the half-res targets. The glow IS
# the bloom source — there is no full-res HDR scene and no bright-pass.
const BLOOM_DOWNSCALE = 2

var glowHdrPipeline: GPURenderPipeline   # Glow -> half-res HDR target (additive, no depth)
var blurPipeline: GPURenderPipeline      # Separable Gaussian blur, one axis per pass
var tonemapPipeline: GPURenderPipeline   # HDR composite + ACES + grade -> swap chain

# Half-res HDR ping-pong targets. Glow writes A; blur H does A->B; blur V does
# B->A; tonemap samples the final blurred A.
var bloomTargetA: GPUTexture
var bloomTargetB: GPUTexture
var bloomViewA: GPUTextureView
var bloomViewB: GPUTextureView

# BloomParams uniforms: one per blur axis. Direction is constant; texelSize is
# rewritten on resize (it tracks the half-res dimensions).
var bloomParamsBufferH: GPUBuffer
var bloomParamsBufferV: GPUBuffer
var tonemapParamsBuffer: GPUBuffer

var blurBindGroupLayout: GPUBindGroupLayout
var tonemapBindGroupLayout: GPUBindGroupLayout

# Cached bloom bind groups (rebuilt on resize alongside the trail bind groups).
var blurBindGroupH: GPUBindGroup    # samples bloom A, writes bloom B (horizontal)
var blurBindGroupV: GPUBindGroup    # samples bloom B, writes bloom A (vertical)
var tonemapBindGroupTrailA: GPUBindGroup  # tonemap sampling trail A + bloom A + field
var tonemapBindGroupTrailB: GPUBindGroup  # tonemap sampling trail B + bloom A + field
# The tonemap bind groups reference the RD field texture (binding 4). The
# textures are created once, in webgpu_init's createFieldResources during
# initWebGPU — a re-seed only rewrites their contents and leaves the texture
# objects and this bind group alone. fieldGeneration bumps only on an actual
# (re)creation, which is what these groups rebuild on, mirroring
# cachedFieldGeneration for the field-composite bind group. Binding 4 falls back
# to the bloom view while the field view is nil, because the layout declares an
# entry there either way; createFieldResources runs inside initWebGPU, so the
# live path binds the real field from the first build. -1 forces a first build.
var cachedTonemapFieldGeneration: int = -1


# ==============================================================================
# SECTION 2b: BINDING CONTRACT VALIDATION
# ==============================================================================
#
# How many entries each render-side bind group layout declares, and therefore
# how many every bind group built against it must supply. Each constant is the
# one place a render layout states its width; the layout builder and every bind
# group builder check themselves against it.
#
# WebGPU rejects a bind group whose entries disagree with its layout, but it
# does so in the browser, at draw time, as a validation error that leaves a
# blank canvas behind — nim c, just happen and just check all stay green. These
# checks turn that into a named failure at the site that got the count wrong.
# They compare counts, not bindings: a layout and a shader that disagree about
# what binding 3 HOLDS still reaches the GPU.

const EXPECTED_BIND_GROUP_ENTRIES_RENDER* = 5
  ## particles + renderParams + colors + field + camera. Shared by the render
  ## and glow pipelines, so both bind groups carry all five.
const EXPECTED_BIND_GROUP_ENTRIES_FADE* = 6
  ## trail texture + sampler + fadeParams + field + camera + previous camera.
const EXPECTED_BIND_GROUP_ENTRIES_BLIT* = 2
  ## trail texture + sampler.
const EXPECTED_BIND_GROUP_ENTRIES_FIELD_COMPOSITE* = 4
  ## field texture + sampler + tonemapParams + camera.
const EXPECTED_BIND_GROUP_ENTRIES_BLUR* = 3
  ## source texture + sampler + bloomParams.
const EXPECTED_BIND_GROUP_ENTRIES_TONEMAP* = 6
  ## trail texture + bloom texture + sampler + tonemapParams + field + camera.
const EXPECTED_BIND_GROUP_ENTRIES_OVERLAY* = 3
  ## overlayParams + camera + renderParams.

proc validateEntryCount(entries: JsObject, groupName: string, expected: int) =
  ## Raise unless an entries array holds exactly the count its layout declares.
  ## Mirrors webgpu_compute.validateBindGroupEntryCount; separate because that
  ## one resolves its expectation from the compute pass name table.
  let actual = jsArrayLength(entries)
  if actual != expected:
    raise newException(CatchableError,
      "Bind group entry count mismatch for \"" & groupName & "\": expected " &
      $expected & " entries, got " & $actual)

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
const FIELD_COMPOSITE_SHADER = staticRead("../web/shaders/field-composite.wgsl")
# HDR bloom shaders (S9); staticRead-embedded like the render shaders above.
const BLUR_SHADER = staticRead("../web/shaders/blur.wgsl")
const TONEMAP_SHADER = staticRead("../web/shaders/tonemap.wgsl")
const OVERLAY_SHADER = staticRead("../web/shaders/overlay.wgsl")

const BLOOM_HDR_FORMAT = "rgba16float".cstring

func halfDimension(fullSize: int): int =
  ## Half-resolution size for the bloom targets, never below 1.
  max(1, fullSize div BLOOM_DOWNSCALE)

# ==============================================================================
# SECTION 4: INITIALIZATION
# ==============================================================================

# Forward declarations
proc updateBindGroup*()
proc createBloomTargets()
proc createBloomBindGroups()
proc currentFieldViewOrFallback(): GPUTextureView
proc createFadeBindGroups()
proc resetCamera*()

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
  let paramsSize = wgslUniformSize(RenderParamsLayout)
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
  # A fresh buffer holds no colors, so clear the record of what it holds and let
  # the next frame's alpha slot force an upload.
  colorData.fill(0.0)

  # Camera uniform: where the view sits over the toroidal world, and how big
  # that world is. Bound by both render.wgsl and glow.wgsl, which must draw a
  # particle at the same image, and by every fullscreen pass that maps a screen
  # pixel back into the world.
  let cameraDesc = newJsObject()
  cameraDesc["size"] = wgslUniformSize(CameraLayout).toJs
  cameraDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  cameraDesc["label"] = "Camera Buffer".cstring.toJs
  cameraBuffer = webgpu_init.device.createBuffer(cameraDesc)

  # The same layout again, holding the view the trail texture was drawn under.
  # A second buffer rather than more FadeParams fields: the fade pass reads a
  # Camera exactly as the renderer writes one, so the two views cannot drift
  # apart in shape.
  let prevCameraDesc = newJsObject()
  prevCameraDesc["size"] = wgslUniformSize(CameraLayout).toJs
  prevCameraDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  prevCameraDesc["label"] = "Previous Camera Buffer".cstring.toJs
  prevCameraBuffer = webgpu_init.device.createBuffer(prevCameraDesc)

  # Fresh buffers hold no view, so arm the sentinels that force the first frame
  # to upload one into each.
  lastUploadedCamera = Camera(centerX: 0.0, centerY: 0.0, zoom: 0.0)
  lastUploadedPrevCamera = Camera(centerX: 0.0, centerY: 0.0, zoom: 0.0)

  # Create bind group layout (AoS: particles + renderParams + colors + field +
  # camera). SHARED BY THE RENDER AND GLOW PIPELINES — both are built from the
  # pipelineLayout below, so every bind group for either must supply all five
  # entries, whether or not that shader reads them. glow.wgsl ignores the field
  # texture; declaring a binding a shader does not use is legal, supplying a
  # bind group that omits one the layout declares is not.
  #
  # NONE OF THIS IS CHECKED AT NIM COMPILE TIME. A mismatch between this layout,
  # the bind groups below, and the two shaders' @binding declarations surfaces
  # only as a WebGPU validation error at runtime, so the three move together.
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

  # Binding 3: the reaction-diffusion field, read in the VERTEX stage so
  # render.wgsl can light each particle by the field it stands in.
  let entry3 = newJsObject()
  entry3["binding"] = 3.toJs
  entry3["visibility"] = gpuShaderStageVertex.toJs
  let texture3 = newJsObject()
  texture3["sampleType"] = "unfilterable-float".cstring.toJs
  entry3["texture"] = texture3
  discard entries.push(entry3)

  # Binding 4: the camera, vertex only. Both pipelines read it, and must agree.
  let entry4 = newJsObject()
  entry4["binding"] = 4.toJs
  entry4["visibility"] = gpuShaderStageVertex.toJs
  let buffer4 = newJsObject()
  buffer4["type"] = "uniform".cstring.toJs
  entry4["buffer"] = buffer4
  discard entries.push(entry4)

  validateEntryCount(entries, "Render Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_RENDER)
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
  # Repeat addressing for the same reason the field sampler uses it: the world
  # wraps, and fade.wgsl reprojects through worldToScreenUv, which deliberately
  # returns UVs outside [0,1] so a trail crosses the seam without a
  # discontinuity. Clamping would smear the boundary row across everything the
  # reprojection reaches past the edge.
  samplerDesc["addressModeU"] = "repeat".cstring.toJs
  samplerDesc["addressModeV"] = "repeat".cstring.toJs
  samplerDesc["label"] = "Linear Sampler".cstring.toJs
  linearSampler = webgpu_init.device.createSampler(samplerDesc)

  # Create fade params uniform buffer (fadeAmount + fieldDriftScale + 2 pads)
  let fadeParamsSize = wgslUniformSize(FadeParamsLayout)
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

  # Binding 3: the reaction-diffusion field, which displaces the trail sample
  # along its gradient so trails bend around the pattern instead of decaying
  # straight back.
  let fadeEntry3 = newJsObject()
  fadeEntry3["binding"] = 3.toJs
  fadeEntry3["visibility"] = gpuShaderStageFragment.toJs
  let fadeTexture3 = newJsObject()
  fadeTexture3["sampleType"] = "float".cstring.toJs
  fadeEntry3["texture"] = fadeTexture3
  discard fadeLayoutEntries.push(fadeEntry3)

  # Binding 4: the live camera, and binding 5 the view the trail was drawn
  # under. Reprojecting the trail as the view moves takes both.
  let fadeEntry4 = newJsObject()
  fadeEntry4["binding"] = 4.toJs
  fadeEntry4["visibility"] = gpuShaderStageFragment.toJs
  let fadeBuffer4 = newJsObject()
  fadeBuffer4["type"] = "uniform".cstring.toJs
  fadeEntry4["buffer"] = fadeBuffer4
  discard fadeLayoutEntries.push(fadeEntry4)

  let fadeEntry5 = newJsObject()
  fadeEntry5["binding"] = 5.toJs
  fadeEntry5["visibility"] = gpuShaderStageFragment.toJs
  let fadeBuffer5 = newJsObject()
  fadeBuffer5["type"] = "uniform".cstring.toJs
  fadeEntry5["buffer"] = fadeBuffer5
  discard fadeLayoutEntries.push(fadeEntry5)

  validateEntryCount(fadeLayoutEntries, "Fade Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_FADE)
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

  validateEntryCount(blitLayoutEntries, "Blit Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_BLIT)
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
  # OVERLAY PIPELINE (spatial parameter drags)
  # ==========================================================================
  # Drawn last in both present paths, only while a spatial slider is dragged.
  # Three uniform buffers; the camera and render-params buffers are the shared
  # ones every present pass reads, so the overlay sees the same view.

  let overlayParamsDesc = newJsObject()
  overlayParamsDesc["size"] = wgslUniformSize(OverlayParamsLayout).toJs
  overlayParamsDesc["usage"] =
    bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  overlayParamsDesc["label"] = "Overlay Params Buffer".cstring.toJs
  overlayParamsBuffer = webgpu_init.device.createBuffer(overlayParamsDesc)

  let overlayShaderDesc = newJsObject()
  overlayShaderDesc["label"] = "Overlay Shader".cstring.toJs
  overlayShaderDesc["code"] = OVERLAY_SHADER.cstring.toJs
  let overlayShaderModule = webgpu_init.device.createShaderModule(overlayShaderDesc)

  let overlayLayoutDesc = newJsObject()
  overlayLayoutDesc["label"] = "Overlay Bind Group Layout".cstring.toJs
  let overlayLayoutEntries = newJsArray()
  for binding in 0 .. 2:
    let entry = newJsObject()
    entry["binding"] = binding.toJs
    entry["visibility"] = gpuShaderStageFragment.toJs
    let bufferKind = newJsObject()
    bufferKind["type"] = "uniform".cstring.toJs
    entry["buffer"] = bufferKind
    discard overlayLayoutEntries.push(entry)
  validateEntryCount(overlayLayoutEntries, "Overlay Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_OVERLAY)
  overlayLayoutDesc["entries"] = overlayLayoutEntries
  let overlayBindGroupLayout =
    webgpu_init.device.createBindGroupLayout(overlayLayoutDesc)

  let overlayPipelineLayoutDesc = newJsObject()
  let overlayLayouts = newJsArray()
  discard overlayLayouts.push(overlayBindGroupLayout)
  overlayPipelineLayoutDesc["bindGroupLayouts"] = overlayLayouts
  let overlayPipelineLayout =
    webgpu_init.device.createPipelineLayout(overlayPipelineLayoutDesc)

  let overlayPipelineDesc = newJsObject()
  overlayPipelineDesc["label"] = "Overlay Pipeline".cstring.toJs
  overlayPipelineDesc["layout"] = overlayPipelineLayout.toJs

  let overlayVertexStage = newJsObject()
  overlayVertexStage["module"] = overlayShaderModule.toJs
  overlayVertexStage["entryPoint"] = "vs_main".cstring.toJs
  overlayPipelineDesc["vertex"] = overlayVertexStage

  let overlayFragmentStage = newJsObject()
  overlayFragmentStage["module"] = overlayShaderModule.toJs
  overlayFragmentStage["entryPoint"] = "fs_main".cstring.toJs

  let overlayTargets = newJsArray()
  let overlayTarget0 = newJsObject()
  overlayTarget0["format"] = canvasFormat.toJs
  # Premultiplied alpha over the finished frame.
  let overlayBlend = newJsObject()
  let overlayColorBlend = newJsObject()
  overlayColorBlend["srcFactor"] = "one".cstring.toJs
  overlayColorBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  overlayColorBlend["operation"] = "add".cstring.toJs
  overlayBlend["color"] = overlayColorBlend
  let overlayAlphaBlend = newJsObject()
  overlayAlphaBlend["srcFactor"] = "one".cstring.toJs
  overlayAlphaBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  overlayAlphaBlend["operation"] = "add".cstring.toJs
  overlayBlend["alpha"] = overlayAlphaBlend
  overlayTarget0["blend"] = overlayBlend
  discard overlayTargets.push(overlayTarget0)
  overlayFragmentStage["targets"] = overlayTargets
  overlayPipelineDesc["fragment"] = overlayFragmentStage

  let overlayPrimitive = newJsObject()
  overlayPrimitive["topology"] = "triangle-list".cstring.toJs
  overlayPrimitive["cullMode"] = "none".cstring.toJs
  overlayPipelineDesc["primitive"] = overlayPrimitive

  # Matches the present passes' depth attachment without touching it.
  let overlayDepthStencil = newJsObject()
  overlayDepthStencil["format"] = "depth24plus".cstring.toJs
  overlayDepthStencil["depthWriteEnabled"] = false.toJs
  overlayDepthStencil["depthCompare"] = "always".cstring.toJs
  overlayPipelineDesc["depthStencil"] = overlayDepthStencil

  overlayPipeline = webgpu_init.device.createRenderPipeline(overlayPipelineDesc)

  let overlayBindGroupDesc = newJsObject()
  overlayBindGroupDesc["label"] = "Overlay Bind Group".cstring.toJs
  overlayBindGroupDesc["layout"] = overlayBindGroupLayout.toJs
  let overlayBindEntries = newJsArray()
  for (binding, buffer) in [(0, overlayParamsBuffer), (1, cameraBuffer),
      (2, renderParamsBuffer)]:
    let entry = newJsObject()
    entry["binding"] = binding.toJs
    let resource = newJsObject()
    resource["buffer"] = buffer.toJs
    entry["resource"] = resource
    discard overlayBindEntries.push(entry)
  overlayBindGroupDesc["entries"] = overlayBindEntries
  overlayBindGroup = webgpu_init.device.createBindGroup(overlayBindGroupDesc)

  # ==========================================================================
  # FIELD COMPOSITE PIPELINE (reaction-diffusion LDR backdrop)
  # ==========================================================================
  # The bloom-off quality floor for the RD field. Its bind group is texture +
  # sampler + the shared TonemapParams uniform (S10: the field-composite reads
  # the same colormapIndex / fieldOpacity the HDR tonemap does, so the field
  # looks the same under either present path). Opaque backdrop drawn first in
  # the present pass under glow/trails, so no blending. Depth matches the pass.

  let fieldLayoutDesc = newJsObject()
  fieldLayoutDesc["label"] = "Field Composite Bind Group Layout".cstring.toJs
  let fieldLayoutEntries = newJsArray()
  let fieldLayoutEntry0 = newJsObject()
  fieldLayoutEntry0["binding"] = 0.toJs
  fieldLayoutEntry0["visibility"] = gpuShaderStageFragment.toJs
  let fieldLayoutTexture0 = newJsObject()
  fieldLayoutTexture0["sampleType"] = "float".cstring.toJs
  fieldLayoutEntry0["texture"] = fieldLayoutTexture0
  discard fieldLayoutEntries.push(fieldLayoutEntry0)
  let fieldLayoutEntry1 = newJsObject()
  fieldLayoutEntry1["binding"] = 1.toJs
  fieldLayoutEntry1["visibility"] = gpuShaderStageFragment.toJs
  let fieldLayoutSampler1 = newJsObject()
  fieldLayoutSampler1["type"] = "filtering".cstring.toJs
  fieldLayoutEntry1["sampler"] = fieldLayoutSampler1
  discard fieldLayoutEntries.push(fieldLayoutEntry1)
  let fieldLayoutEntry2 = newJsObject()
  fieldLayoutEntry2["binding"] = 2.toJs
  fieldLayoutEntry2["visibility"] = gpuShaderStageFragment.toJs
  let fieldLayoutBuffer2 = newJsObject()
  fieldLayoutBuffer2["type"] = "uniform".cstring.toJs
  fieldLayoutEntry2["buffer"] = fieldLayoutBuffer2
  discard fieldLayoutEntries.push(fieldLayoutEntry2)
  # Binding 3: the camera. Same mapping the tonemap path applies, so the two
  # present paths agree about WHERE the field is, not merely how it is graded.
  let fieldLayoutEntry3 = newJsObject()
  fieldLayoutEntry3["binding"] = 3.toJs
  fieldLayoutEntry3["visibility"] = gpuShaderStageFragment.toJs
  let fieldLayoutBuffer3 = newJsObject()
  fieldLayoutBuffer3["type"] = "uniform".cstring.toJs
  fieldLayoutEntry3["buffer"] = fieldLayoutBuffer3
  discard fieldLayoutEntries.push(fieldLayoutEntry3)
  validateEntryCount(fieldLayoutEntries, "Field Composite Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_FIELD_COMPOSITE)
  fieldLayoutDesc["entries"] = fieldLayoutEntries
  fieldCompositeBindGroupLayout = webgpu_init.device.createBindGroupLayout(fieldLayoutDesc)

  let fieldPipelineLayoutDesc = newJsObject()
  let fieldPipelineLayouts = newJsArray()
  discard fieldPipelineLayouts.push(fieldCompositeBindGroupLayout)
  fieldPipelineLayoutDesc["bindGroupLayouts"] = fieldPipelineLayouts
  let fieldCompositePipelineLayout = webgpu_init.device.createPipelineLayout(fieldPipelineLayoutDesc)

  let fieldShaderDesc = newJsObject()
  fieldShaderDesc["label"] = "Field Composite Shader".cstring.toJs
  fieldShaderDesc["code"] = FIELD_COMPOSITE_SHADER.cstring.toJs
  let fieldShaderModule = webgpu_init.device.createShaderModule(fieldShaderDesc)

  let fieldPipelineDesc = newJsObject()
  fieldPipelineDesc["label"] = "Field Composite Pipeline".cstring.toJs
  fieldPipelineDesc["layout"] = fieldCompositePipelineLayout.toJs

  let fieldVertexStage = newJsObject()
  fieldVertexStage["module"] = fieldShaderModule.toJs
  fieldVertexStage["entryPoint"] = "vs_main".cstring.toJs
  fieldPipelineDesc["vertex"] = fieldVertexStage

  let fieldFragmentStage = newJsObject()
  fieldFragmentStage["module"] = fieldShaderModule.toJs
  fieldFragmentStage["entryPoint"] = "fs_main".cstring.toJs
  let fieldTargets = newJsArray()
  let fieldTarget0 = newJsObject()
  fieldTarget0["format"] = canvasFormat.toJs
  discard fieldTargets.push(fieldTarget0)
  fieldFragmentStage["targets"] = fieldTargets
  fieldPipelineDesc["fragment"] = fieldFragmentStage

  let fieldPrimitive = newJsObject()
  fieldPrimitive["topology"] = "triangle-list".cstring.toJs
  fieldPrimitive["cullMode"] = "none".cstring.toJs
  fieldPipelineDesc["primitive"] = fieldPrimitive

  let fieldDepthStencil = newJsObject()
  fieldDepthStencil["format"] = "depth24plus".cstring.toJs
  fieldDepthStencil["depthWriteEnabled"] = false.toJs
  fieldDepthStencil["depthCompare"] = "always".cstring.toJs
  fieldPipelineDesc["depthStencil"] = fieldDepthStencil

  fieldCompositePipeline = webgpu_init.device.createRenderPipeline(fieldPipelineDesc)

  # ==========================================================================
  # HDR BLOOM PIPELINES (S9): glow-to-HDR, separable blur, tonemap composite
  # ==========================================================================

  # --- Glow-to-HDR pipeline: the glow shader, retargeted to the half-res
  # rgba16float bloom source. Same layout/bindings/additive-blend as the
  # present-pass glow, but no depth attachment (bloom needs no Z-ordering).
  let glowHdrPipelineDesc = newJsObject()
  glowHdrPipelineDesc["label"] = "Glow HDR Pipeline".cstring.toJs
  glowHdrPipelineDesc["layout"] = pipelineLayout.toJs
  let glowHdrVertex = newJsObject()
  glowHdrVertex["module"] = glowShaderModule.toJs
  glowHdrVertex["entryPoint"] = "vs_main".cstring.toJs
  glowHdrPipelineDesc["vertex"] = glowHdrVertex
  let glowHdrFragment = newJsObject()
  glowHdrFragment["module"] = glowShaderModule.toJs
  glowHdrFragment["entryPoint"] = "fs_main".cstring.toJs
  let glowHdrTargets = newJsArray()
  let glowHdrTarget0 = newJsObject()
  glowHdrTarget0["format"] = BLOOM_HDR_FORMAT.toJs
  let glowHdrBlend = newJsObject()
  let glowHdrColorBlend = newJsObject()
  glowHdrColorBlend["srcFactor"] = "one".cstring.toJs
  glowHdrColorBlend["dstFactor"] = "one".cstring.toJs
  glowHdrColorBlend["operation"] = "add".cstring.toJs
  glowHdrBlend["color"] = glowHdrColorBlend
  let glowHdrAlphaBlend = newJsObject()
  glowHdrAlphaBlend["srcFactor"] = "one".cstring.toJs
  glowHdrAlphaBlend["dstFactor"] = "one".cstring.toJs
  glowHdrAlphaBlend["operation"] = "add".cstring.toJs
  glowHdrBlend["alpha"] = glowHdrAlphaBlend
  glowHdrTarget0["blend"] = glowHdrBlend
  discard glowHdrTargets.push(glowHdrTarget0)
  glowHdrFragment["targets"] = glowHdrTargets
  glowHdrPipelineDesc["fragment"] = glowHdrFragment
  let glowHdrPrimitive = newJsObject()
  glowHdrPrimitive["topology"] = "triangle-list".cstring.toJs
  glowHdrPrimitive["cullMode"] = "none".cstring.toJs
  glowHdrPipelineDesc["primitive"] = glowHdrPrimitive
  glowHdrPipeline = webgpu_init.device.createRenderPipeline(glowHdrPipelineDesc)

  # --- Blur bind group layout: source texture + sampler + BloomParams uniform.
  let blurLayoutDesc = newJsObject()
  blurLayoutDesc["label"] = "Blur Bind Group Layout".cstring.toJs
  let blurLayoutEntries = newJsArray()
  let blurEntry0 = newJsObject()
  blurEntry0["binding"] = 0.toJs
  blurEntry0["visibility"] = gpuShaderStageFragment.toJs
  let blurTexture0 = newJsObject()
  blurTexture0["sampleType"] = "float".cstring.toJs
  blurEntry0["texture"] = blurTexture0
  discard blurLayoutEntries.push(blurEntry0)
  let blurEntry1 = newJsObject()
  blurEntry1["binding"] = 1.toJs
  blurEntry1["visibility"] = gpuShaderStageFragment.toJs
  let blurSampler1 = newJsObject()
  blurSampler1["type"] = "filtering".cstring.toJs
  blurEntry1["sampler"] = blurSampler1
  discard blurLayoutEntries.push(blurEntry1)
  let blurEntry2 = newJsObject()
  blurEntry2["binding"] = 2.toJs
  blurEntry2["visibility"] = gpuShaderStageFragment.toJs
  let blurBuffer2 = newJsObject()
  blurBuffer2["type"] = "uniform".cstring.toJs
  blurEntry2["buffer"] = blurBuffer2
  discard blurLayoutEntries.push(blurEntry2)
  validateEntryCount(blurLayoutEntries, "Blur Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_BLUR)
  blurLayoutDesc["entries"] = blurLayoutEntries
  blurBindGroupLayout = webgpu_init.device.createBindGroupLayout(blurLayoutDesc)

  let blurPipelineLayoutDesc = newJsObject()
  let blurLayouts = newJsArray()
  discard blurLayouts.push(blurBindGroupLayout)
  blurPipelineLayoutDesc["bindGroupLayouts"] = blurLayouts
  let blurPipelineLayout = webgpu_init.device.createPipelineLayout(blurPipelineLayoutDesc)

  let blurShaderDesc = newJsObject()
  blurShaderDesc["label"] = "Blur Shader".cstring.toJs
  blurShaderDesc["code"] = BLUR_SHADER.cstring.toJs
  let blurShaderModule = webgpu_init.device.createShaderModule(blurShaderDesc)

  let blurPipelineDesc = newJsObject()
  blurPipelineDesc["label"] = "Blur Pipeline".cstring.toJs
  blurPipelineDesc["layout"] = blurPipelineLayout.toJs
  let blurVertex = newJsObject()
  blurVertex["module"] = blurShaderModule.toJs
  blurVertex["entryPoint"] = "vs_main".cstring.toJs
  blurPipelineDesc["vertex"] = blurVertex
  let blurFragment = newJsObject()
  blurFragment["module"] = blurShaderModule.toJs
  blurFragment["entryPoint"] = "fs_main".cstring.toJs
  let blurTargets = newJsArray()
  let blurTarget0 = newJsObject()
  blurTarget0["format"] = BLOOM_HDR_FORMAT.toJs
  discard blurTargets.push(blurTarget0)
  blurFragment["targets"] = blurTargets
  blurPipelineDesc["fragment"] = blurFragment
  let blurPrimitive = newJsObject()
  blurPrimitive["topology"] = "triangle-list".cstring.toJs
  blurPrimitive["cullMode"] = "none".cstring.toJs
  blurPipelineDesc["primitive"] = blurPrimitive
  blurPipeline = webgpu_init.device.createRenderPipeline(blurPipelineDesc)

  # --- Tonemap bind group layout: trail texture + bloom texture + sampler +
  # TonemapParams uniform. Presents to the swap chain, alpha-blended over the
  # backdrop (flat clear, or the RD field) already in it.
  let tonemapLayoutDesc = newJsObject()
  tonemapLayoutDesc["label"] = "Tonemap Bind Group Layout".cstring.toJs
  let tonemapLayoutEntries = newJsArray()
  let tonemapEntry0 = newJsObject()
  tonemapEntry0["binding"] = 0.toJs
  tonemapEntry0["visibility"] = gpuShaderStageFragment.toJs
  let tonemapTexture0 = newJsObject()
  tonemapTexture0["sampleType"] = "float".cstring.toJs
  tonemapEntry0["texture"] = tonemapTexture0
  discard tonemapLayoutEntries.push(tonemapEntry0)
  let tonemapEntry1 = newJsObject()
  tonemapEntry1["binding"] = 1.toJs
  tonemapEntry1["visibility"] = gpuShaderStageFragment.toJs
  let tonemapTexture1 = newJsObject()
  tonemapTexture1["sampleType"] = "float".cstring.toJs
  tonemapEntry1["texture"] = tonemapTexture1
  discard tonemapLayoutEntries.push(tonemapEntry1)
  let tonemapEntry2 = newJsObject()
  tonemapEntry2["binding"] = 2.toJs
  tonemapEntry2["visibility"] = gpuShaderStageFragment.toJs
  let tonemapSampler2 = newJsObject()
  tonemapSampler2["type"] = "filtering".cstring.toJs
  tonemapEntry2["sampler"] = tonemapSampler2
  discard tonemapLayoutEntries.push(tonemapEntry2)
  let tonemapEntry3 = newJsObject()
  tonemapEntry3["binding"] = 3.toJs
  tonemapEntry3["visibility"] = gpuShaderStageFragment.toJs
  let tonemapBuffer3 = newJsObject()
  tonemapBuffer3["type"] = "uniform".cstring.toJs
  tonemapEntry3["buffer"] = tonemapBuffer3
  discard tonemapLayoutEntries.push(tonemapEntry3)
  # Binding 4: RD field texture (S10). Sampled in the tonemap so the field joins
  # the graded HDR light; the bloom view stands in while the field view is nil.
  let tonemapEntry4 = newJsObject()
  tonemapEntry4["binding"] = 4.toJs
  tonemapEntry4["visibility"] = gpuShaderStageFragment.toJs
  let tonemapTexture4 = newJsObject()
  tonemapTexture4["sampleType"] = "float".cstring.toJs
  tonemapEntry4["texture"] = tonemapTexture4
  discard tonemapLayoutEntries.push(tonemapEntry4)
  # Binding 5: the camera, so the field sample maps through the view. The trail
  # and bloom are screen-space targets and need no transform; only the field
  # lives in the world.
  let tonemapEntry5 = newJsObject()
  tonemapEntry5["binding"] = 5.toJs
  tonemapEntry5["visibility"] = gpuShaderStageFragment.toJs
  let tonemapBuffer5 = newJsObject()
  tonemapBuffer5["type"] = "uniform".cstring.toJs
  tonemapEntry5["buffer"] = tonemapBuffer5
  discard tonemapLayoutEntries.push(tonemapEntry5)
  validateEntryCount(tonemapLayoutEntries, "Tonemap Bind Group Layout",
    EXPECTED_BIND_GROUP_ENTRIES_TONEMAP)
  tonemapLayoutDesc["entries"] = tonemapLayoutEntries
  tonemapBindGroupLayout = webgpu_init.device.createBindGroupLayout(tonemapLayoutDesc)

  let tonemapPipelineLayoutDesc = newJsObject()
  let tonemapLayouts = newJsArray()
  discard tonemapLayouts.push(tonemapBindGroupLayout)
  tonemapPipelineLayoutDesc["bindGroupLayouts"] = tonemapLayouts
  let tonemapPipelineLayout = webgpu_init.device.createPipelineLayout(tonemapPipelineLayoutDesc)

  let tonemapShaderDesc = newJsObject()
  tonemapShaderDesc["label"] = "Tonemap Shader".cstring.toJs
  tonemapShaderDesc["code"] = TONEMAP_SHADER.cstring.toJs
  let tonemapShaderModule = webgpu_init.device.createShaderModule(tonemapShaderDesc)

  let tonemapPipelineDesc = newJsObject()
  tonemapPipelineDesc["label"] = "Tonemap Pipeline".cstring.toJs
  tonemapPipelineDesc["layout"] = tonemapPipelineLayout.toJs
  let tonemapVertex = newJsObject()
  tonemapVertex["module"] = tonemapShaderModule.toJs
  tonemapVertex["entryPoint"] = "vs_main".cstring.toJs
  tonemapPipelineDesc["vertex"] = tonemapVertex
  let tonemapFragment = newJsObject()
  tonemapFragment["module"] = tonemapShaderModule.toJs
  tonemapFragment["entryPoint"] = "fs_main".cstring.toJs
  let tonemapTargets = newJsArray()
  let tonemapTarget0 = newJsObject()
  tonemapTarget0["format"] = canvasFormat.toJs
  # Alpha blend so empty pixels keep the backdrop (flat clear / RD field).
  let tonemapBlend = newJsObject()
  let tonemapColorBlend = newJsObject()
  tonemapColorBlend["srcFactor"] = "src-alpha".cstring.toJs
  tonemapColorBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  tonemapColorBlend["operation"] = "add".cstring.toJs
  tonemapBlend["color"] = tonemapColorBlend
  let tonemapAlphaBlend = newJsObject()
  tonemapAlphaBlend["srcFactor"] = "one".cstring.toJs
  tonemapAlphaBlend["dstFactor"] = "one-minus-src-alpha".cstring.toJs
  tonemapAlphaBlend["operation"] = "add".cstring.toJs
  tonemapBlend["alpha"] = tonemapAlphaBlend
  tonemapTarget0["blend"] = tonemapBlend
  discard tonemapTargets.push(tonemapTarget0)
  tonemapFragment["targets"] = tonemapTargets
  tonemapPipelineDesc["fragment"] = tonemapFragment
  let tonemapPrimitive = newJsObject()
  tonemapPrimitive["topology"] = "triangle-list".cstring.toJs
  tonemapPrimitive["cullMode"] = "none".cstring.toJs
  tonemapPipelineDesc["primitive"] = tonemapPrimitive
  # The present pass carries a depth attachment (the RD field pipeline needs
  # one); the tonemap draw ignores depth, matching the blit's config.
  let tonemapDepthStencil = newJsObject()
  tonemapDepthStencil["format"] = "depth24plus".cstring.toJs
  tonemapDepthStencil["depthWriteEnabled"] = false.toJs
  tonemapDepthStencil["depthCompare"] = "always".cstring.toJs
  tonemapPipelineDesc["depthStencil"] = tonemapDepthStencil
  tonemapPipeline = webgpu_init.device.createRenderPipeline(tonemapPipelineDesc)

  # BloomParams uniforms (one per blur axis) + the per-frame TonemapParams.
  let bloomParamsSize = wgslUniformSize(BloomParamsLayout)
  let bloomParamsHDesc = newJsObject()
  bloomParamsHDesc["size"] = bloomParamsSize.toJs
  bloomParamsHDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  bloomParamsHDesc["label"] = "Bloom Params H".cstring.toJs
  bloomParamsBufferH = webgpu_init.device.createBuffer(bloomParamsHDesc)
  let bloomParamsVDesc = newJsObject()
  bloomParamsVDesc["size"] = bloomParamsSize.toJs
  bloomParamsVDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  bloomParamsVDesc["label"] = "Bloom Params V".cstring.toJs
  bloomParamsBufferV = webgpu_init.device.createBuffer(bloomParamsVDesc)
  let tonemapParamsDesc = newJsObject()
  tonemapParamsDesc["size"] = wgslUniformSize(TonemapParamsLayout).toJs
  tonemapParamsDesc["usage"] = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst).toJs
  tonemapParamsDesc["label"] = "Tonemap Params".cstring.toJs
  tonemapParamsBuffer = webgpu_init.device.createBuffer(tonemapParamsDesc)

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
  validateEntryCount(blitEntriesA, "Blit Bind Group A",
    EXPECTED_BIND_GROUP_ENTRIES_BLIT)
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
  validateEntryCount(blitEntriesB, "Blit Bind Group B",
    EXPECTED_BIND_GROUP_ENTRIES_BLIT)
  blitBGB["entries"] = blitEntriesB
  blitBindGroupB = webgpu_init.device.createBindGroup(blitBGB)

  createFadeBindGroups()

  # Half-res HDR bloom targets + their bind groups (mirrors the trail textures;
  # rebuilt on resize by recreateTrailTextures). These come FIRST because the
  # render bind group binds the field texture, and before the field exists it
  # falls back to a bloom view — which has to have been created by then.
  createBloomTargets()
  createBloomBindGroups()

  # Create initial bind group
  updateBindGroup()

  # Seed the camera at the default view before the first frame reads it. Both
  # copies, so the first frame's trail reprojection is an identity rather than a
  # jump from an uninitialized zero-zoom camera.
  resetCamera()
  previousCamera = activeCamera

  isInitialized = true
  {.emit: "console.log('WebGPU render pipeline initialized with glow, trails, and bloom');".}
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
  let particlesEntry = newJsObject()
  particlesEntry["binding"] = 0.toJs
  let particlesResource = newJsObject()
  particlesResource["buffer"] = particles.toJs
  particlesEntry["resource"] = particlesResource
  discard entries.push(particlesEntry)

  # Entry 1: render params
  let renderParamsEntry = newJsObject()
  renderParamsEntry["binding"] = 1.toJs
  let renderParamsResource = newJsObject()
  renderParamsResource["buffer"] = renderParamsBuffer.toJs
  renderParamsEntry["resource"] = renderParamsResource
  discard entries.push(renderParamsEntry)

  # Entry 2: species colors
  let colorsEntry = newJsObject()
  colorsEntry["binding"] = 2.toJs
  let colorsResource = newJsObject()
  colorsResource["buffer"] = colorBuffer.toJs
  colorsEntry["resource"] = colorsResource
  discard entries.push(colorsEntry)

  # Entry 3: the reaction-diffusion field, so the vertex stage can light each
  # particle by the field it is standing in. While the field view is nil this is
  # the same bloom-view placeholder the tonemap binds, which keeps the entry
  # count right until createFieldResources has run.
  let fieldEntry = newJsObject()
  fieldEntry["binding"] = 3.toJs
  fieldEntry["resource"] = currentFieldViewOrFallback().toJs
  discard entries.push(fieldEntry)

  # Entry 4: the camera. Both pipelines transform through it.
  let cameraEntry = newJsObject()
  cameraEntry["binding"] = 4.toJs
  let cameraResource = newJsObject()
  cameraResource["buffer"] = cameraBuffer.toJs
  cameraEntry["resource"] = cameraResource
  discard entries.push(cameraEntry)

  # One array feeds both bind groups below, so one check covers the pair.
  validateEntryCount(entries, "Render/Glow Bind Group",
    EXPECTED_BIND_GROUP_ENTRIES_RENDER)
  bindGroupDesc["entries"] = entries
  renderBindGroup = webgpu_init.device.createBindGroup(bindGroupDesc)
  cachedRenderFieldGeneration = webgpu_init.fieldGeneration()

  # Create glow bind group (same layout, same entries)
  let glowBindGroupDesc = newJsObject()
  glowBindGroupDesc["label"] = "Glow Bind Group AoS".cstring.toJs
  glowBindGroupDesc["layout"] = glowPipeline.getBindGroupLayout(0).toJs
  glowBindGroupDesc["entries"] = entries
  glowBindGroup = webgpu_init.device.createBindGroup(glowBindGroupDesc)

proc camera*(): Camera =
  ## The live view. Input handlers read it, move it with camera_core's pure
  ## movers, and hand the result back through setCamera.
  activeCamera

proc setCamera*(next: Camera) =
  ## Replace the live view. The uniform follows on the next frame; nothing here
  ## writes the GPU, so a burst of input events costs one buffer write, not one
  ## per event.
  activeCamera = next

proc resetCamera*() =
  ## Back to the whole world, centred.
  activeCamera = initCamera(float32(config.WORLD_W), float32(config.WORLD_H))

proc uploadCamera(buffer: GPUBuffer, view: Camera) =
  ## Write one Camera record into one uniform buffer.
  ##
  ## The live view and the previous frame's view go through this same proc, so
  ## the two records are filled by one piece of code and cannot disagree about
  ## where a field sits. The world extent rides along because every camera
  ## transform needs the span it wraps around, and the pass reading a camera
  ## should not have to be handed that separately.
  ##
  ## Callers skip this whenever the view has not moved, which is safe only
  ## because config.WORLD_W/WORLD_H are immutable: a world that could resize
  ## under a still camera would leave the extent in the buffer stale, and would
  ## have to force an upload on the resize.
  cameraData[CAMERA_CENTER_X] = view.centerX
  cameraData[CAMERA_CENTER_Y] = view.centerY
  cameraData[CAMERA_ZOOM] = view.zoom
  cameraData[CAMERA_WORLD_WIDTH] = float32(config.WORLD_W)
  cameraData[CAMERA_WORLD_HEIGHT] = float32(config.WORLD_H)
  cameraData[CAMERA_PAD0] = 0.0
  cameraData[CAMERA_PAD1] = 0.0
  cameraData[CAMERA_PAD2] = 0.0
  webgpu_init.queue.writeBuffer(buffer, 0, cameraData)

proc createFadeBindGroups() =
  ## (Re)build both fade bind groups. They reference the ping-pong trail views,
  ## so they are rebuilt whenever those are recreated (resize), and they carry
  ## the field texture, so they are rebuilt when that appears too.
  ##
  ## One proc rather than an inline copy at each call site: the field binding is
  ## declared once instead of kept in step across all three.
  proc makeFadeBindGroup(label: cstring, trailView: GPUTextureView): GPUBindGroup =
    let desc = newJsObject()
    desc["label"] = label.toJs
    desc["layout"] = fadeBindGroupLayout.toJs
    let entries = newJsArray()

    let trailEntry = newJsObject()
    trailEntry["binding"] = 0.toJs
    trailEntry["resource"] = trailView.toJs
    discard entries.push(trailEntry)

    let samplerEntry = newJsObject()
    samplerEntry["binding"] = 1.toJs
    samplerEntry["resource"] = linearSampler.toJs
    discard entries.push(samplerEntry)

    let paramsEntry = newJsObject()
    paramsEntry["binding"] = 2.toJs
    let paramsResource = newJsObject()
    paramsResource["buffer"] = fadeParamsBuffer.toJs
    paramsEntry["resource"] = paramsResource
    discard entries.push(paramsEntry)

    # The field the trail drifts along. The bloom view stands in while the field
    # view is nil, because the layout declares an entry here either way.
    let fieldEntry = newJsObject()
    fieldEntry["binding"] = 3.toJs
    fieldEntry["resource"] = currentFieldViewOrFallback().toJs
    discard entries.push(fieldEntry)

    # The live camera and the one the trail was drawn under. The reprojection
    # asks where each world point sat on that earlier screen and reads the
    # trail there, so a moving view slides its history with the world instead
    # of smearing it across the screen.
    let cameraEntry = newJsObject()
    cameraEntry["binding"] = 4.toJs
    let cameraResource = newJsObject()
    cameraResource["buffer"] = cameraBuffer.toJs
    cameraEntry["resource"] = cameraResource
    discard entries.push(cameraEntry)

    let prevCameraEntry = newJsObject()
    prevCameraEntry["binding"] = 5.toJs
    let prevCameraResource = newJsObject()
    prevCameraResource["buffer"] = prevCameraBuffer.toJs
    prevCameraEntry["resource"] = prevCameraResource
    discard entries.push(prevCameraEntry)

    validateEntryCount(entries, $label, EXPECTED_BIND_GROUP_ENTRIES_FADE)
    desc["entries"] = entries
    webgpu_init.device.createBindGroup(desc)

  fadeBindGroupReadA = makeFadeBindGroup("Fade Bind Group Read A", trailViewA)
  fadeBindGroupReadB = makeFadeBindGroup("Fade Bind Group Read B", trailViewB)

proc ensureRenderFieldBinding() =
  ## Rebuild the render/glow bind groups when the field textures were
  ## (re)created, so the particle-lighting binding follows the live field
  ## instead of the placeholder it started on. Same generation-caching shape as
  ## ensureFieldCompositeBindGroup; a no-op on every frame that changes nothing.
  if webgpu_init.fieldGeneration() == cachedRenderFieldGeneration:
    return
  updateBindGroup()
  # The fade pass drifts the trail along the same field, so its groups hold the
  # same view and go stale at the same moment.
  createFadeBindGroups()

proc ensureFieldCompositeBindGroup() =
  ## (Re)build the field composite bind group when the field textures were
  ## (re)created (fieldGeneration changed). Layout is texture + sampler + the
  ## shared TonemapParams uniform (the colormap/opacity authority). No-op when
  ## the field view does not exist yet.
  let generation = webgpu_init.fieldGeneration()
  if generation == cachedFieldGeneration and not fieldCompositeBindGroup.isNil:
    return
  let fieldView = webgpu_init.activeFieldView()
  if cast[JsObject](fieldView).isNil or cast[JsObject](fieldView).isNullOrUndefined:
    return

  let bindGroupDesc = newJsObject()
  bindGroupDesc["label"] = "Field Composite Bind Group".cstring.toJs
  bindGroupDesc["layout"] = fieldCompositeBindGroupLayout.toJs
  let entries = newJsArray()
  let textureEntry = newJsObject()
  textureEntry["binding"] = 0.toJs
  textureEntry["resource"] = fieldView.toJs
  discard entries.push(textureEntry)
  let samplerEntry = newJsObject()
  samplerEntry["binding"] = 1.toJs
  samplerEntry["resource"] = webgpu_init.fieldSampler().toJs
  discard entries.push(samplerEntry)
  let uniformEntry = newJsObject()
  uniformEntry["binding"] = 2.toJs
  let uniformResource = newJsObject()
  uniformResource["buffer"] = tonemapParamsBuffer.toJs
  uniformEntry["resource"] = uniformResource
  discard entries.push(uniformEntry)
  # The camera, so this path places the field exactly where the tonemap path
  # does. Grading parity alone does not place it: the view moves.
  let compositeCameraEntry = newJsObject()
  compositeCameraEntry["binding"] = 3.toJs
  let compositeCameraResource = newJsObject()
  compositeCameraResource["buffer"] = cameraBuffer.toJs
  compositeCameraEntry["resource"] = compositeCameraResource
  discard entries.push(compositeCameraEntry)
  validateEntryCount(entries, "Field Composite Bind Group",
    EXPECTED_BIND_GROUP_ENTRIES_FIELD_COMPOSITE)
  bindGroupDesc["entries"] = entries
  fieldCompositeBindGroup = webgpu_init.device.createBindGroup(bindGroupDesc)
  cachedFieldGeneration = generation

proc createBloomTargets() =
  ## (Re)create the two half-resolution rgba16float bloom targets at the current
  ## canvas size and rewrite the per-axis BloomParams (their texelSize tracks
  ## the half-res dimensions). Destroys any prior targets first. Called at init
  ## and on resize, mirroring recreateTrailTextures.
  if not bloomTargetA.isNil:
    bloomTargetA.destroy()
  if not bloomTargetB.isNil:
    bloomTargetB.destroy()
  # Before the field exists, the render bind group's field slot holds a bloom
  # view — which these lines just destroyed. Force a rebuild rather than let the
  # next frame bind a dead texture. Harmless when the real field is bound.
  cachedRenderFieldGeneration = -1

  let halfWidth = halfDimension(canvas.width)
  let halfHeight = halfDimension(canvas.height)

  proc createBloomTexture(label: cstring): GPUTexture =
    let desc = newJsObject()
    let size = newJsArray()
    discard size.push(halfWidth.toJs)
    discard size.push(halfHeight.toJs)
    desc["size"] = size
    desc["format"] = BLOOM_HDR_FORMAT.toJs
    desc["usage"] = bitwiseOr(gpuTextureUsageRenderAttachment, gpuTextureUsageTextureBinding).toJs
    desc["label"] = label.toJs
    return webgpu_init.device.createTexture(desc)

  bloomTargetA = createBloomTexture("Bloom Target A")
  bloomTargetB = createBloomTexture("Bloom Target B")
  bloomViewA = bloomTargetA.createView()
  bloomViewB = bloomTargetB.createView()

  # Per-tap UV step = direction * texelSize. Direction picks the blur axis;
  # texelSize is one over the half-res dimensions.
  let texelX = 1.0 / float32(halfWidth)
  let texelY = 1.0 / float32(halfHeight)

  let bloomH = newFloat32Array(BLOOM_PARAMS_F32_COUNT)
  bloomH[BLOOM_DIRECTION_X] = 1.0
  bloomH[BLOOM_DIRECTION_Y] = 0.0
  bloomH[BLOOM_TEXEL_SIZE_X] = texelX
  bloomH[BLOOM_TEXEL_SIZE_Y] = texelY
  webgpu_init.queue.writeBuffer(bloomParamsBufferH, 0, bloomH)

  let bloomV = newFloat32Array(BLOOM_PARAMS_F32_COUNT)
  bloomV[BLOOM_DIRECTION_X] = 0.0
  bloomV[BLOOM_DIRECTION_Y] = 1.0
  bloomV[BLOOM_TEXEL_SIZE_X] = texelX
  bloomV[BLOOM_TEXEL_SIZE_Y] = texelY
  webgpu_init.queue.writeBuffer(bloomParamsBufferV, 0, bloomV)

proc currentFieldViewOrFallback(): GPUTextureView =
  ## The active RD field view for the tonemap's binding 4, or the bloom view
  ## while the field view is nil — the layout declares an entry there, so the
  ## bind group needs one whether or not createFieldResources has run.
  let fieldView = webgpu_init.activeFieldView()
  if cast[JsObject](fieldView).isNil or cast[JsObject](fieldView).isNullOrUndefined:
    return bloomViewA
  fieldView

proc createBloomBindGroups() =
  ## (Re)create the blur and tonemap bind groups. They reference the bloom and
  ## trail texture views, so they are rebuilt whenever either is recreated.
  proc makeBlurBindGroup(label: cstring, sourceView: GPUTextureView,
                         paramsBuffer: GPUBuffer): GPUBindGroup =
    let desc = newJsObject()
    desc["label"] = label.toJs
    desc["layout"] = blurBindGroupLayout.toJs
    let entries = newJsArray()
    let entry0 = newJsObject()
    entry0["binding"] = 0.toJs
    entry0["resource"] = sourceView.toJs
    discard entries.push(entry0)
    let entry1 = newJsObject()
    entry1["binding"] = 1.toJs
    entry1["resource"] = linearSampler.toJs
    discard entries.push(entry1)
    let entry2 = newJsObject()
    entry2["binding"] = 2.toJs
    let entry2Resource = newJsObject()
    entry2Resource["buffer"] = paramsBuffer.toJs
    entry2["resource"] = entry2Resource
    discard entries.push(entry2)
    validateEntryCount(entries, $label, EXPECTED_BIND_GROUP_ENTRIES_BLUR)
    desc["entries"] = entries
    return webgpu_init.device.createBindGroup(desc)

  # Horizontal pass samples A; vertical pass samples B (A->B->A ping-pong).
  blurBindGroupH = makeBlurBindGroup("Blur Bind Group H", bloomViewA, bloomParamsBufferH)
  blurBindGroupV = makeBlurBindGroup("Blur Bind Group V", bloomViewB, bloomParamsBufferV)

  let fieldView = currentFieldViewOrFallback()
  proc makeTonemapBindGroup(label: cstring, trailView: GPUTextureView): GPUBindGroup =
    let desc = newJsObject()
    desc["label"] = label.toJs
    desc["layout"] = tonemapBindGroupLayout.toJs
    let entries = newJsArray()
    let entry0 = newJsObject()
    entry0["binding"] = 0.toJs
    entry0["resource"] = trailView.toJs
    discard entries.push(entry0)
    let entry1 = newJsObject()
    entry1["binding"] = 1.toJs
    entry1["resource"] = bloomViewA.toJs   # final blurred bloom lives in A
    discard entries.push(entry1)
    let entry2 = newJsObject()
    entry2["binding"] = 2.toJs
    entry2["resource"] = linearSampler.toJs
    discard entries.push(entry2)
    let entry3 = newJsObject()
    entry3["binding"] = 3.toJs
    let entry3Resource = newJsObject()
    entry3Resource["buffer"] = tonemapParamsBuffer.toJs
    entry3["resource"] = entry3Resource
    discard entries.push(entry3)
    let entry4 = newJsObject()
    entry4["binding"] = 4.toJs
    entry4["resource"] = fieldView.toJs   # RD field, or bloom placeholder pre-field
    discard entries.push(entry4)
    # Binding 5: the camera, for mapping screen UV into field space.
    let entry5 = newJsObject()
    entry5["binding"] = 5.toJs
    let cameraResource = newJsObject()
    cameraResource["buffer"] = cameraBuffer.toJs
    entry5["resource"] = cameraResource
    discard entries.push(entry5)
    validateEntryCount(entries, $label, EXPECTED_BIND_GROUP_ENTRIES_TONEMAP)
    desc["entries"] = entries
    return webgpu_init.device.createBindGroup(desc)

  tonemapBindGroupTrailA = makeTonemapBindGroup("Tonemap Bind Group Trail A", trailViewA)
  tonemapBindGroupTrailB = makeTonemapBindGroup("Tonemap Bind Group Trail B", trailViewB)
  cachedTonemapFieldGeneration = webgpu_init.fieldGeneration()

proc ensureTonemapBindGroups() =
  ## Rebuild the tonemap bind groups when the RD field textures were (re)created
  ## (fieldGeneration changed) so binding 4 tracks the live field view. Mirrors
  ## ensureFieldCompositeBindGroup for the HDR path.
  if webgpu_init.fieldGeneration() == cachedTonemapFieldGeneration:
    return
  createBloomBindGroups()

# ==============================================================================
# SECTION 5: RENDER LOOP
# ==============================================================================

proc render*(particleCount: int) =
  ## Render particles using WebGPU with ping-pong trail rendering.
  ##
  ## Ping-pong architecture:
  ##   Frame N (trailParity=0): Read from A, Write to B, Blit B to screen
  ##   Frame N+1 (trailParity=1): Read from B, Write to A, Blit A to screen

  if not isInitialized:
    return

  # Point the particle-lighting binding at the live field if it appeared or was
  # recreated since the last frame. Cheap generation compare; usually a no-op.
  ensureRenderFieldBinding()

  # Update render params uniform
  # Layout matches RenderParams indices in gpu_types.nim
  renderParamsData[RENDER_RESOLUTION_X] = float32(canvas.width)
  renderParamsData[RENDER_RESOLUTION_Y] = float32(canvas.height)
  renderParamsData[RENDER_WORLD_SIZE_X] = float32(config.WORLD_W)
  renderParamsData[RENDER_WORLD_SIZE_Y] = float32(config.WORLD_H)
  renderParamsData[RENDER_BASE_SIZE] = float32(config.CONFIG.particleSize + 1)
  renderParamsData[RENDER_GLOW_INTENSITY] = float32(config.CONFIG.glowIntensity)
  renderParamsData[RENDER_VELOCITY_GLOW_SCALE] = float32(config.CONFIG.velocityGlowScale)
  renderParamsData[RENDER_MAX_VELOCITY] = float32(config.CONFIG.maxVelocity)
  # Trail length scale: convert 0-100 slider to shader-friendly multiplier
  # At trailLength=0: no elongation. At trailLength=100: significant elongation
  let trailLengthScale = config.CONFIG.trailLength * 0.02  # Scale factor for motion blur
  renderParamsData[RENDER_TRAIL_LENGTH_SCALE] = float32(trailLengthScale)
  renderParamsData[RENDER_GLOW_RADIUS_SCALE] = float32(config.CONFIG.glowRadiusScale)
  renderParamsData[RENDER_GLOW_FALLOFF] = float32(config.CONFIG.glowFalloff)
  renderParamsData[RENDER_GLOW_WARMTH] = float32(config.CONFIG.glowWarmth)
  # No floor: the neighbour sweep is world-intrinsic, so every particle in every
  # world carries a measured density and the glow reads it directly.
  renderParamsData[RENDER_GLOW_DENSITY_FLOOR] = 0.0'f32
  # The field lights the particles standing in it (render.wgsl), in every world,
  # because every world has a field. What decides whether anything shows is the
  # field's own intensity: a world depositing nothing sits at Gray-Scott's
  # trivial fixed point, where the coverage term is zero and each particle keeps
  # its species colour exactly.
  renderParamsData[RENDER_COLORMAP_INDEX] = float32(config.CONFIG.colormapIndex)
  renderParamsData[RENDER_FIELD_OPACITY] = float32(config.CONFIG.fieldOpacity)
  webgpu_init.queue.writeBuffer(renderParamsBuffer, 0, renderParamsData)

  # Camera uniform. One buffer feeds render, glow, fade, tonemap and the field
  # composite, so they all read the same view of the same instant. The upload
  # happens only when the view differs from what the buffer already holds — a
  # still camera leaves the contents correct, and comparing the whole Camera
  # (Nim lifts == over every field) keeps a future field from slipping past.
  if activeCamera != lastUploadedCamera:
    uploadCamera(cameraBuffer, activeCamera)
    lastUploadedCamera = activeCamera

  # The view the trail texture was drawn under, in its own buffer of the same
  # layout. The fade pass reprojects between the two, so it needs the previous
  # one as a whole camera rather than as scalars it reassembles. On the first
  # frame this equals the live view, which makes the reprojection an identity —
  # correct, since there is no history yet.
  if previousCamera != lastUploadedPrevCamera:
    uploadCamera(prevCameraBuffer, previousCamera)
    lastUploadedPrevCamera = previousCamera

  # Species colors, packed as vec4f for 16-byte alignment. colorData already
  # holds what the buffer holds, so writing through it doubles as the change
  # test: a palette edit lands the same frame it happens, and every other frame
  # skips the upload. The alpha slot is what guarantees the first frame uploads
  # — colorData starts zeroed, and 1.0 never matches that.
  var colorsChanged = false
  for speciesIndex in 0 ..< 6:
    for channel in 0 ..< 3:
      let channelValue = config.COLORS[speciesIndex * 3 + channel]
      if colorData[speciesIndex * 4 + channel] != channelValue:
        colorData[speciesIndex * 4 + channel] = channelValue
        colorsChanged = true
    if colorData[speciesIndex * 4 + 3] != 1.0:
      colorData[speciesIndex * 4 + 3] = 1.0  # padding/alpha
      colorsChanged = true
  if colorsChanged:
    webgpu_init.queue.writeBuffer(colorBuffer, 0, colorData)

  # Update fade params
  # Layout matches FadeParams indices in gpu_types.nim
  # The trail length the user set, in particle diameters, becomes the per-frame
  # multiplier fade.wgsl keeps of the previous frame: higher = more of the
  # previous frame retained = longer trails, and zero clears outright. The
  # mapping lives in trail_core, where the suite measures the frames it buys.
  fadeData[FADE_AMOUNT] = float32(fadeAmountFor(config.CONFIG.trailLength))
  # Trails bend along the field gradient, in every world. A flat field has zero
  # gradient, so the drift term vanishes by arithmetic rather than by a gate.
  fadeData[FADE_FIELD_DRIFT_SCALE] = float32(FIELD_DRIFT_SCALE)
  fadeData[FADE_PAD1] = 0.0
  fadeData[FADE_PAD2] = 0.0
  webgpu_init.queue.writeBuffer(fadeParamsBuffer, 0, fadeData)

  # Tonemap/grade uniforms — written every frame regardless of the present path.
  # The HDR tonemap reads all of them; the bloom-off field-composite floor reads
  # colormapIndex + fieldOpacity from this same buffer. fieldOpacity is the
  # user's slider, passed through unchanged.
  tonemapData[TONEMAP_EXPOSURE] = float32(config.CONFIG.exposure)
  tonemapData[TONEMAP_BLOOM_INTENSITY] = float32(config.CONFIG.bloomIntensity)
  tonemapData[TONEMAP_SATURATION] = float32(config.CONFIG.saturation)
  tonemapData[TONEMAP_CONTRAST] = float32(config.CONFIG.contrast)
  tonemapData[TONEMAP_TEMPERATURE] = float32(config.CONFIG.temperature)
  tonemapData[TONEMAP_COLORMAP_INDEX] = float32(config.CONFIG.colormapIndex)
  # The field contributes to the tonemap wherever it has intensity, which is a
  # question the coverage term answers per pixel rather than one the world
  # answers once.
  tonemapData[TONEMAP_FIELD_OPACITY] = float32(config.CONFIG.fieldOpacity)
  tonemapData[TONEMAP_PAD2] = 0.0
  webgpu_init.queue.writeBuffer(tonemapParamsBuffer, 0, tonemapData)

  # The spatial drag overlay: uniform written only while a spatial slider is
  # dragged; the closed set lives in overlay_core.
  let overlayKind = overlayKindFor(canvas_input.dragOverlayId)
  if overlayKind != okNone:
    overlayParamsData[OVERLAY_KIND] = float32(ord(overlayKind))
    if overlayKind == okRing:
      let cursor = screenUvToWorld(
        float32(canvas_input.getMouseX() / float(canvas.width)),
        float32(canvas_input.getMouseY() / float(canvas.height)),
        activeCamera, float32(config.WORLD_W), float32(config.WORLD_H))
      overlayParamsData[OVERLAY_CENTER_X] = cursor.x
      overlayParamsData[OVERLAY_CENTER_Y] = cursor.y
      overlayParamsData[OVERLAY_RADIUS] =
        float32(config.CONFIG.interactionRadius)
    else:
      overlayParamsData[OVERLAY_CENTER_X] = 0.0
      overlayParamsData[OVERLAY_CENTER_Y] = 0.0
      overlayParamsData[OVERLAY_RADIUS] = 0.0
    webgpu_init.queue.writeBuffer(overlayParamsBuffer, 0, overlayParamsData)

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
  # PASS 2: PRESENT (BLIT, or HDR BLOOM + TONEMAP when bloom is enabled)
  # ==========================================================================

  let currentTexture = gpuContext.getCurrentTexture()
  let swapChainView = currentTexture.createView()

  if config.CONFIG.bloomEnabled:
    # ------------------------------------------------------------------------
    # BLOOM PATH: glow -> half-res HDR -> separable blur (H,V) -> tonemap.
    # The trail texture stays the crisp 8-bit particle layer; the tonemap
    # composites it over the blurred glow.
    # ------------------------------------------------------------------------

    # The tonemap/grade uniforms (including the S10 field-visualization pair)
    # were written above, before this branch, so both present paths share them.
    # The field is sampled inside the tonemap (binding 4), so its bind groups
    # must track the live field texture.
    ensureTonemapBindGroups()

    # Helper: a single-color-attachment render pass clearing to black.
    # spanBegin/spanEnd mark the edges of the single passBloom profiling span
    # across the three bloom passes (first pass opens, last pass closes).
    proc beginBloomPass(view: GPUTextureView, label: cstring,
        spanBegin = false, spanEnd = false): GPURenderPassEncoder =
      let passDesc = newJsObject()
      passDesc["label"] = label.toJs
      if spanBegin:
        gpu_profiler.attachBeginTimestamp(passDesc, gpu_profiler.passBloom)
      if spanEnd:
        gpu_profiler.attachEndTimestamp(passDesc, gpu_profiler.passBloom)
      let attachments = newJsArray()
      let attachment = newJsObject()
      attachment["view"] = view.toJs
      attachment["loadOp"] = "clear".cstring.toJs
      let clear = newJsObject()
      clear["r"] = 0.0.toJs
      clear["g"] = 0.0.toJs
      clear["b"] = 0.0.toJs
      clear["a"] = 1.0.toJs
      attachment["clearValue"] = clear
      attachment["storeOp"] = "store".cstring.toJs
      discard attachments.push(attachment)
      passDesc["colorAttachments"] = attachments
      return commandEncoder.beginRenderPass(passDesc)

    # Bloom pass A: glow additively into the half-res HDR target A.
    let glowHdrPass = beginBloomPass(bloomViewA, "Glow HDR Pass",
      spanBegin = true)
    glowHdrPass.setPipeline(glowHdrPipeline)
    glowHdrPass.setBindGroup(0, glowBindGroup)
    glowHdrPass.draw(6 * particleCount, 1, 0, 0)
    glowHdrPass.endPass()

    # Blur H: sample A, write B.
    let blurHPass = beginBloomPass(bloomViewB, "Bloom Blur H")
    blurHPass.setPipeline(blurPipeline)
    blurHPass.setBindGroup(0, blurBindGroupH)
    blurHPass.draw(3, 1, 0, 0)
    blurHPass.endPass()

    # Blur V: sample B, write back into A (final blurred bloom).
    let blurVPass = beginBloomPass(bloomViewA, "Bloom Blur V",
      spanEnd = true)
    blurVPass.setPipeline(blurPipeline)
    blurVPass.setBindGroup(0, blurBindGroupV)
    blurVPass.draw(3, 1, 0, 0)
    blurVPass.endPass()

    # Present: clear bg, then tonemap the trail + bloom + field over it. The RD
    # field is composited INSIDE the tonemap (S10 — sampled at binding 4 and
    # folded into the graded HDR light), so there is no separate backdrop draw
    # here; the tonemap's coverage alpha keeps the flat clear wherever the field
    # has no intensity.
    let presentPassDesc = newJsObject()
    presentPassDesc["label"] = "Tonemap Present Pass".cstring.toJs
    gpu_profiler.attachTimestamps(presentPassDesc, gpu_profiler.passPresent)
    let presentAttachments = newJsArray()
    let presentAttachment = newJsObject()
    presentAttachment["view"] = swapChainView.toJs
    presentAttachment["loadOp"] = "clear".cstring.toJs
    let presentClearColor = newJsObject()
    presentClearColor["r"] = 0.04.toJs
    presentClearColor["g"] = 0.04.toJs
    presentClearColor["b"] = 0.06.toJs
    presentClearColor["a"] = 1.0.toJs
    presentAttachment["clearValue"] = presentClearColor
    presentAttachment["storeOp"] = "store".cstring.toJs
    discard presentAttachments.push(presentAttachment)
    presentPassDesc["colorAttachments"] = presentAttachments
    let presentDepthAttachment = newJsObject()
    presentDepthAttachment["view"] = depthTextureView.toJs
    presentDepthAttachment["depthLoadOp"] = "clear".cstring.toJs
    presentDepthAttachment["depthClearValue"] = 1.0.toJs
    presentDepthAttachment["depthStoreOp"] = "discard".cstring.toJs
    presentPassDesc["depthStencilAttachment"] = presentDepthAttachment
    let presentPass = commandEncoder.beginRenderPass(presentPassDesc)

    # The field is composited inside the tonemap (no separate backdrop draw in
    # the bloom path); the tonemap bind group carries the field at binding 4.
    let tonemapBG = if trailParity == 0: tonemapBindGroupTrailB else: tonemapBindGroupTrailA
    presentPass.setPipeline(tonemapPipeline)
    presentPass.setBindGroup(0, tonemapBG)
    presentPass.draw(3, 1, 0, 0)  # Fullscreen triangle

    if overlayKind != okNone:
      presentPass.setPipeline(overlayPipeline)
      presentPass.setBindGroup(0, overlayBindGroup)
      presentPass.draw(3, 1, 0, 0)

    presentPass.endPass()

  else:
    # ------------------------------------------------------------------------
    # QUALITY FLOOR (bloom off): the untouched present pass — RD backdrop,
    # additive glow, then the plain alpha blit of the trail.
    # ------------------------------------------------------------------------
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

    # Step 0: draw the field as a colormapped LDR backdrop under everything else
    # (the bloom-off floor). It reads the same colormapIndex / fieldOpacity from
    # the shared TonemapParams buffer the HDR tonemap uses, and its alpha follows
    # the field's own intensity — so a world whose field sits at the trivial
    # fixed point composites nothing visible. Nil-guarded before the textures.
    ensureFieldCompositeBindGroup()
    if not fieldCompositeBindGroup.isNil:
      presentPass.setPipeline(fieldCompositePipeline)
      presentPass.setBindGroup(0, fieldCompositeBindGroup)
      presentPass.draw(3, 1, 0, 0)  # Fullscreen triangle

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

    if overlayKind != okNone:
      presentPass.setPipeline(overlayPipeline)
      presentPass.setBindGroup(0, overlayBindGroup)
      presentPass.draw(3, 1, 0, 0)

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

  # The trail texture just written was drawn under THIS camera, so from the next
  # frame's point of view that is the previous one. Recorded after the submit,
  # so any camera move arriving between frames is reprojected across rather than
  # silently absorbed.
  previousCamera = activeCamera

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
  validateEntryCount(blitEntriesA, "Blit Bind Group A (resize)",
    EXPECTED_BIND_GROUP_ENTRIES_BLIT)
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
  validateEntryCount(blitEntriesB, "Blit Bind Group B (resize)",
    EXPECTED_BIND_GROUP_ENTRIES_BLIT)
  blitBGB["entries"] = blitEntriesB
  blitBindGroupB = webgpu_init.device.createBindGroup(blitBGB)

  # Recreate fade bind groups (reference trail texture views)
  createFadeBindGroups()

  # Recreate the half-res bloom targets at the new size and rebuild the bloom
  # bind groups (they reference both the bloom and the just-rebuilt trail views).
  createBloomTargets()
  createBloomBindGroups()

  # Reset trail parity to start fresh
  trailParity = 0

proc resize*() =
  ## Handle canvas resize. Recreates trail textures at new dimensions.
  canvas.width = windowInnerWidth()
  canvas.height = windowInnerHeight()

  # Recreate trail textures and bind groups at new size
  if isInitialized:
    recreateTrailTextures()
