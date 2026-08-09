# ==============================================================================
# This module handles:
# - Feature detection for WebGPU availability
# - GPU adapter and device acquisition with appropriate limits
# - GPU buffer creation for AoS (Array of Structures) particle layout
# - Graceful fallback when WebGPU is unavailable
#
# AoS BUFFER ARCHITECTURE:
# GPU buffers use consolidated particle structs (32 bytes each) instead of
# separate arrays for each field. This enables cache-friendly access patterns
# in compute shaders.
#
# Buffer inventory and per-buffer semantics: memory_layout.nim's MemoryOffsets.
#
# ==============================================================================

from std/jsffi import JsObject, toJs, `[]`, `[]=`
import std/asyncjs
import bindings/js_interop
import bindings/webgpu
import memory_layout
import field_core

proc makeJsObject(): JsObject {.importjs: "({})".}
proc makeJsArray(): JsObject {.importjs: "([])".}
proc push(arr: JsObject, item: JsObject): int {.importjs: "#.push(#)", discardable.}

type
  GPUBuffersObject* = ref object of JsObject
    particlesA* {.importjs: "particlesA".}: GPUBuffer       ## Primary particles
    particlesSorted* {.importjs: "particlesSorted".}: GPUBuffer  ## Sorted for forces

    sortedIndices* {.importjs: "sortedIndices".}: GPUBuffer  ## sorted -> original
    reverseIndices* {.importjs: "reverseIndices".}: GPUBuffer ## original -> sorted

    # Velocity deltas for Newton's 3rd law
    velocityDelta* {.importjs: "velocityDelta".}: GPUBuffer  ## Interleaved i32 pairs

    # Density deltas for symmetric accumulation
    densityDelta* {.importjs: "densityDelta".}: GPUBuffer  ## i32 per particle (fixed-point)
    sphDensityDelta* {.importjs: "sphDensityDelta".}: GPUBuffer
      ## The fluid's private kernel density, i32 per particle (fixed-point).
    crowdDensityDelta* {.importjs: "crowdDensityDelta".}: GPUBuffer
      ## Species-blind crowd density, i32 per particle (fixed-point). What the
      ## crowding cap reads; the renderer keeps reading the colony channel.
    fieldAlive* {.importjs: "fieldAlive".}: GPUBuffer
      ## One u32: how many field cells resolved above the aliveness threshold
      ## this frame. field-resolve writes it, the frame clears it, the stats
      ## cadence reads it back for the panel's dormancy lines.
    fieldAliveReadback* {.importjs: "fieldAliveReadback".}: GPUBuffer
      ## The 4-byte MAP_READ staging pair for fieldAlive.

    gridCounts* {.importjs: "gridCounts".}: GPUBuffer
    gridOffsets* {.importjs: "gridOffsets".}: GPUBuffer
    fillPointers* {.importjs: "fillPointers".}: GPUBuffer

    blockSums* {.importjs: "blockSums".}: GPUBuffer
    blockOffsets* {.importjs: "blockOffsets".}: GPUBuffer

    sync* {.importjs: "sync".}: GPUBuffer

  InitResult* = ref object of JsObject
    success* {.importjs: "success".}: bool
    error* {.importjs: "error".}: cstring
    info* {.importjs: "info".}: JsObject

  BufferSizes* = ref object of JsObject
    particlesA* {.importjs: "particlesA".}: int
    particlesSorted* {.importjs: "particlesSorted".}: int
    sortedIndices* {.importjs: "sortedIndices".}: int
    reverseIndices* {.importjs: "reverseIndices".}: int
    velocityDelta* {.importjs: "velocityDelta".}: int
      ## Two i32 per particle, interleaved [vx, vy].
    densityDelta* {.importjs: "densityDelta".}: int
      ## Density delta buffer for symmetric accumulation via atomics.
      ## Half-neighbor iteration processes each pair once, but density must be
      ## accumulated for BOTH particles. Since WGSL lacks atomic f32, we use
      ## fixed-point i32 (scale=65536) and apply in integrate pass.
    sphDensityDelta* {.importjs: "sphDensityDelta".}: int
    crowdDensityDelta* {.importjs: "crowdDensityDelta".}: int
    fieldAlive* {.importjs: "fieldAlive".}: int
    gridCounts* {.importjs: "gridCounts".}: int
    gridOffsets* {.importjs: "gridOffsets".}: int
    sync* {.importjs: "sync".}: int

proc jsObjectLength*(obj: JsObject): int {.importjs: "Object.keys(#).length".}
proc jsCeilDiv*(numerator, denominator: int): int {.importjs: "Math.ceil(# / #)".}
proc makeFeatureList(name: cstring): JsObject {.importjs: "[#]".}
proc destroyAllBuffers*(obj: JsObject) {.importjs: "Object.values(#).forEach((buffer) => { if (buffer && typeof buffer.destroy === 'function') { buffer.destroy(); } })".}

var adapter* {.exportc.}: GPUAdapter = nil
var device* {.exportc.}: GPUDevice = nil
var queue* {.exportc.}: GPUQueue = nil
var buffers* {.exportc.}: GPUBuffersObject = cast[GPUBuffersObject](makeJsObject())
var isWebGPUAvailable* {.exportc.}: bool = false
var hasTimestampQuery* {.exportc.}: bool = false

# ==============================================================================
# SECTION 3b: REACTION-DIFFUSION FIELD RESOURCES
# ==============================================================================
#
# The field lives in two rgba16float ping-pong storage textures (.r = activator,
# .g = inhibitor; .ba unused padding), FIELD_W x FIELD_H, spanning the full world
# rect. rgba16float rather than rg16float because WebGPU does not permit rg16float
# as a write-only storage texture — it is not in the storage-capable format list;
# rgba16float is the nearest storage+sampled+filterable half-float format. This is the
# app's only use of STORAGE_BINDING: the rd-step / resolve passes sample one
# texture and write the other. fieldTextureA is the FIXED front the render and
# force passes always read; fieldTextureB is the scratch the ping-pong bounces
# through (see field-resolve.wgsl for why the half-float format forces a
# ping-pong rather than an in-place update, and webgpu_compute's bind-group
# section for the full per-frame swap sequence). fieldGenerationCounter bumps
# whenever the textures are (re)created so the render side can cache its bind
# group and rebuild on change.
var fieldTextureA {.exportc: "pgFieldTextureA".}: GPUTexture = nil
var fieldTextureB {.exportc: "pgFieldTextureB".}: GPUTexture = nil
var fieldViewA {.exportc: "pgFieldViewA".}: GPUTextureView = nil
var fieldViewB {.exportc: "pgFieldViewB".}: GPUTextureView = nil
var fieldLinearSampler {.exportc: "pgFieldSampler".}: GPUSampler = nil
var fieldDepositBuffer {.exportc: "pgFieldDeposit".}: GPUBuffer = nil
var fieldGenerationCounter {.exportc: "pgFieldGeneration".}: int = 0

proc calculateBufferSizes*(): BufferSizes {.exportc.} =
  ## Calculate GPU buffer sizes for AoS layout.
  let gridCells = memory_layout.MAX_GRID * memory_layout.MAX_GRID

  result = BufferSizes()

  result.particlesA = memory_layout.MAX_PARTICLES * memory_layout.PARTICLE_STRIDE
  result.particlesSorted = memory_layout.MAX_PARTICLES * memory_layout.PARTICLE_STRIDE

  # Index mappings: u32 per particle
  result.sortedIndices = memory_layout.MAX_PARTICLES * 4
  result.reverseIndices = memory_layout.MAX_PARTICLES * 4

  # Velocity deltas: 2 i32s per particle (interleaved vx, vy)
  result.velocityDelta = memory_layout.MAX_PARTICLES * 2 * 4

  result.densityDelta = memory_layout.MAX_PARTICLES * 4
  result.sphDensityDelta = memory_layout.MAX_PARTICLES * 4
  result.crowdDensityDelta = memory_layout.MAX_PARTICLES * 4
  result.fieldAlive = 4  # one u32: the frame's alive-cell census

  # Grid: u32 per cell
  result.gridCounts = gridCells * 4
  result.gridOffsets = gridCells * 4

  # Sync: 256 i32s
  result.sync = 256 * 4

proc createFieldResources() =
  ## (Re)create the reaction-diffusion field textures, deposit buffer, and
  ## sampler, then seed them. Called once from initWebGPU after the particle
  ## buffers exist. Idempotent: destroys any prior resources first and bumps
  ## the generation counter so cached bind groups downstream rebuild.
  if not fieldTextureA.isNil: fieldTextureA.destroy()
  if not fieldTextureB.isNil: fieldTextureB.destroy()
  if not fieldDepositBuffer.isNil: fieldDepositBuffer.destroy()

  let fieldUsage = bitwiseOr(bitwiseOr(
    gpuTextureUsageStorageBinding, gpuTextureUsageTextureBinding),
    gpuTextureUsageRenderAttachment)

  proc createFieldTexture(label: cstring): GPUTexture =
    let desc = makeJsObject()
    let size = makeJsObject()
    size["width".cstring] = FIELD_W.toJs
    size["height".cstring] = FIELD_H.toJs
    desc["size".cstring] = size
    desc["format".cstring] = "rgba16float".cstring.toJs
    desc["usage".cstring] = fieldUsage.toJs
    desc["label".cstring] = label.toJs
    return device.createTexture(desc)

  fieldTextureA = createFieldTexture("RD Field A (front)")
  fieldTextureB = createFieldTexture("RD Field B (trailing)")
  fieldViewA = fieldTextureA.createView()
  fieldViewB = fieldTextureB.createView()

  # Linear sampler for the LDR composite (compute passes use textureLoad and
  # need no sampler). rgba16float is filterable, so filtering is valid.
  let samplerDesc = makeJsObject()
  samplerDesc["magFilter".cstring] = "linear".cstring.toJs
  samplerDesc["minFilter".cstring] = "linear".cstring.toJs
  # Repeat addressing, because the field wraps and the composite passes sample
  # it through a camera whose view can straddle the world edge. Clamping here
  # would smear the boundary row across everything past that edge instead of
  # showing the world again, which is the seam the camera exists to hide.
  samplerDesc["addressModeU".cstring] = "repeat".cstring.toJs
  samplerDesc["addressModeV".cstring] = "repeat".cstring.toJs
  samplerDesc["label".cstring] = "RD Field Sampler".cstring.toJs
  fieldLinearSampler = device.createSampler(samplerDesc)

  # Deposit buffer: one i32 per field cell — the inhibitor channel — for
  # fixed-point atomic accumulation of per-particle splats. field-deposit.wgsl
  # documents why there is no second, activator channel.
  let depositBytes = FIELD_W * FIELD_H * 4
  let depositUsage = bitwiseOr(gpuBufferUsageStorage, gpuBufferUsageCopyDst)
  fieldDepositBuffer = device.createBufferLabeled(
    depositBytes, depositUsage, "RD Field Deposit (fixed-point i32, inhibitor)")

  # Clear both field textures to (activator=1, inhibitor=0) via a render-pass
  # clear (rgba16float is renderable). This is the PRE-SEED BASELINE, not the
  # seed: it is Gray-Scott's trivial fixed point, inert for any feed/kill, and
  # the field stays exactly here until particle deposits lift it off, or
  # field-seed.wgsl writes a pattern over it on a reset or a deliberate scatter.
  # What this clear guarantees is a defined starting state, so a frame encoded
  # before the first deposit reads sane values rather than uninitialized texture
  # memory. Also zero the deposit buffer so frame 0 folds no garbage.
  let seedEncoder = device.createCommandEncoderLabeled("RD Field Seed")

  proc clearFieldTexture(view: GPUTextureView, label: cstring) =
    let passDesc = makeJsObject()
    passDesc["label".cstring] = label.toJs
    let attachments = makeJsArray()
    let attachment = makeJsObject()
    attachment["view".cstring] = view.toJs
    attachment["loadOp".cstring] = "clear".cstring.toJs
    let seedColor = makeJsObject()
    seedColor["r".cstring] = 1.0.toJs   # activator = 1
    seedColor["g".cstring] = 0.0.toJs   # inhibitor = 0
    seedColor["b".cstring] = 0.0.toJs
    seedColor["a".cstring] = 1.0.toJs
    attachment["clearValue".cstring] = seedColor
    attachment["storeOp".cstring] = "store".cstring.toJs
    discard attachments.push(attachment.toJs)
    passDesc["colorAttachments".cstring] = attachments
    let clearPass = seedEncoder.beginRenderPass(passDesc)
    clearPass.endPass()

  clearFieldTexture(fieldViewA, "Seed RD Field A")
  clearFieldTexture(fieldViewB, "Seed RD Field B")
  seedEncoder.clearBuffer(fieldDepositBuffer, 0, depositBytes)

  let seedCommands = seedEncoder.finish()
  let seedArray = makeJsArray()
  discard seedArray.push(seedCommands.toJs)
  queue.submit(seedArray)

  inc fieldGenerationCounter

proc activeFieldView*(): GPUTextureView =
  ## The sampled view of the current front field texture (fieldA is the fixed
  ## front). R = activator, G = inhibitor. Nil until createFieldResources runs.
  fieldViewA

proc fieldSampledViewA*(): GPUTextureView = fieldViewA
proc fieldSampledViewB*(): GPUTextureView = fieldViewB
  ## The two ping-pong views, for the compute executor's RD bind groups.

proc fieldSampler*(): GPUSampler =
  ## The linear sampler the LDR field composite reads the field with.
  fieldLinearSampler

proc fieldDepositGpuBuffer*(): GPUBuffer =
  ## The fixed-point deposit buffer (2 i32 channels per field cell).
  fieldDepositBuffer

proc fieldGeneration*(): int =
  ## Bumps on each (re)creation of the field textures, so the render side caches
  ## its field-composite bind group and rebuilds only when this changes.
  fieldGenerationCounter

proc detectWebGPU*(): bool {.exportc.} =
  if not hasWebGPU():
    {.emit: "console.warn('WebGPU not supported: navigator.gpu is undefined');".}
    return false

  if not isJsFunction(navigator.gpu.toJs["requestAdapter".cstring]):
    {.emit: "console.warn('WebGPU not supported: requestAdapter method missing');".}
    return false

  return true

proc initWebGPU*(): Future[JsObject] {.async, exportc.} =
  ## Initialize WebGPU device and create AoS GPU buffers.

  if not detectWebGPU():
    let errorResult = makeJsObject()
    errorResult["success".cstring] = false.toJs
    errorResult["error".cstring] = "WebGPU is not available in this browser. Try Chrome 113+ or Edge 113+.".cstring.toJs
    return errorResult

  let adapterOptions = makeJsObject()
  adapterOptions["powerPreference".cstring] = "high-performance".cstring.toJs

  adapter = await navigator.gpu.requestAdapter(adapterOptions)

  if adapter.isNil or adapter.isNullOrUndefined:
    let errorResult = makeJsObject()
    errorResult["success".cstring] = false.toJs
    errorResult["error".cstring] = "Failed to obtain WebGPU adapter. Your GPU may not support WebGPU.".cstring.toJs
    return errorResult

  let adapterInfo = adapter.info
  if adapterInfo.isNullOrUndefined:
    {.emit: "console.log('WebGPU adapter acquired:', 'Info unavailable');".}
  else:
    {.emit: "console.log('WebGPU adapter acquired:', `adapterInfo`);".}

  let sizes = calculateBufferSizes()

  # Find max buffer size (particlesA is the largest single buffer)
  var maxBufferSize = sizes.particlesA
  if sizes.particlesSorted > maxBufferSize: maxBufferSize = sizes.particlesSorted

  let requiredLimits = makeJsObject()
  requiredLimits["maxBufferSize".cstring] = toJs(maxBufferSize * 2)  # 2x headroom
  requiredLimits["maxStorageBufferBindingSize".cstring] = toJs(maxBufferSize * 2)
  requiredLimits["maxComputeWorkgroupSizeX".cstring] = toJs(256)
  requiredLimits["maxComputeWorkgroupsPerDimension".cstring] = toJs(jsCeilDiv(memory_layout.MAX_PARTICLES, 256))

  let deviceDescriptor = makeJsObject()
  deviceDescriptor["requiredLimits".cstring] = requiredLimits

  # timestamp-query is optional: request it when the adapter offers it,
  # degrade to CPU-side performance.now timing otherwise.
  hasTimestampQuery = adapter.hasFeature("timestamp-query")
  if hasTimestampQuery:
    deviceDescriptor["requiredFeatures".cstring] = makeFeatureList("timestamp-query")
    {.emit: "console.log('GPU timestamp-query: enabled');".}
  else:
    {.emit: "console.log('GPU timestamp-query: unavailable, per-pass GPU timing disabled');".}

  device = await adapter.requestDevice(deviceDescriptor)

  if device.isNil or device.isNullOrUndefined:
    let errorResult = makeJsObject()
    errorResult["success".cstring] = false.toJs
    errorResult["error".cstring] = "Failed to create WebGPU device.".cstring.toJs
    return errorResult

  queue = device.queue

  device.addEventListener("uncapturederror", proc(event: JsObject) =
    let errorObj = event["error".cstring]
    {.emit: "console.error('WebGPU uncaptured error:', `errorObj`);".}
  )

  let lostPromise = cast[JsPromise[JsObject]](device.lost)
  discard lostPromise.jsThen(proc(info: JsObject): JsObject =
    let msg = info["message".cstring]
    {.emit: "console.error('WebGPU device lost:', `msg`);".}
    isWebGPUAvailable = false
    return cast[JsObject](js_interop.jsNull)
  )

  {.emit: "console.log('WebGPU device created with limits:', `device`.limits);".}

  let bufferUsage = bitwiseOr(bitwiseOr(gpuBufferUsageStorage, gpuBufferUsageCopySrc), gpuBufferUsageCopyDst)

  proc createBuf(size: int, usage: int, label: cstring): GPUBuffer =
    let desc = makeJsObject()
    desc["size".cstring] = size.toJs
    desc["usage".cstring] = usage.toJs
    desc["label".cstring] = label.toJs
    return device.createBuffer(desc)

  buffers.particlesA = createBuf(sizes.particlesA, bufferUsage, "Particles A (AoS, 32 bytes/particle)")
  buffers.particlesSorted = createBuf(sizes.particlesSorted, bufferUsage, "Particles Sorted (AoS, 32 bytes/particle)")

  buffers.sortedIndices = createBuf(sizes.sortedIndices, bufferUsage, "Sorted Indices (sorted -> original)")
  buffers.reverseIndices = createBuf(sizes.reverseIndices, bufferUsage, "Reverse Indices (original -> sorted)")

  buffers.velocityDelta = createBuf(sizes.velocityDelta, bufferUsage, "Velocity Delta (interleaved i32)")

  buffers.densityDelta = createBuf(sizes.densityDelta, bufferUsage, "Density Delta (fixed-point i32)")
  buffers.sphDensityDelta = createBuf(
    sizes.sphDensityDelta, bufferUsage, "SPH Kernel Density Delta (fixed-point i32)")
  buffers.crowdDensityDelta = createBuf(
    sizes.crowdDensityDelta, bufferUsage, "Crowd Density Delta (fixed-point i32)")
  buffers.fieldAlive = createBuf(
    sizes.fieldAlive, bufferUsage, "Field Alive-Cell Census (u32)")
  buffers.fieldAliveReadback = createBuf(sizes.fieldAlive,
    bitwiseOr(gpuBufferUsageCopyDst, gpuBufferUsageMapRead),
    "Field Alive-Cell Readback")

  buffers.gridCounts = createBuf(sizes.gridCounts, bufferUsage, "Grid Cell Counts")
  buffers.gridOffsets = createBuf(sizes.gridOffsets, bufferUsage, "Grid Cell Offsets")
  buffers.fillPointers = createBuf(sizes.gridOffsets, bufferUsage, "Fill Pointers")

  # Prefix sum intermediates
  let blockSumsSize = 256 * 4
  buffers.blockSums = createBuf(blockSumsSize, bufferUsage, "Prefix Sum Block Totals")
  buffers.blockOffsets = createBuf(blockSumsSize, bufferUsage, "Prefix Sum Block Offsets")

  buffers.sync = createBuf(sizes.sync, bufferUsage, "Synchronization Buffer")

  let bufferCount = jsObjectLength(cast[JsObject](buffers))
  {.emit: "console.log('WebGPU AoS buffers created:', `bufferCount`, 'buffers');".}

  # Reaction-diffusion field textures + deposit buffer (created for every world,
  # like the SPH buffers, so a strength leaving zero finds them ready).
  createFieldResources()
  {.emit: "console.log('WebGPU RD field resources created (512x512 rgba16float ping-pong)');".}

  isWebGPUAvailable = true

  let infoObj = makeJsObject()
  if adapter.info.isNullOrUndefined:
    infoObj["adapter".cstring] = "Unknown adapter".cstring.toJs
  else:
    infoObj["adapter".cstring] = adapter.info.toJs
  infoObj["limits".cstring] = device.limits.toJs
  infoObj["bufferCount".cstring] = bufferCount.toJs
  infoObj["particleBufferSize".cstring] = sizes.particlesA.toJs

  let successResult = makeJsObject()
  successResult["success".cstring] = true.toJs
  successResult["info".cstring] = infoObj

  return successResult

proc cleanup*() {.exportc.} =
  destroyAllBuffers(cast[JsObject](buffers))
  buffers = cast[GPUBuffersObject](makeJsObject())

  # Reaction-diffusion field resources are separate from the buffers object.
  if not fieldTextureA.isNil: fieldTextureA.destroy()
  if not fieldTextureB.isNil: fieldTextureB.destroy()
  if not fieldDepositBuffer.isNil: fieldDepositBuffer.destroy()
  fieldTextureA = nil
  fieldTextureB = nil
  fieldViewA = nil
  fieldViewB = nil
  fieldDepositBuffer = nil

  if not device.isNil and not device.isNullOrUndefined:
    device.destroy()

  adapter = nil
  device = nil
  queue = nil
  isWebGPUAvailable = false

  {.emit: "console.log('WebGPU resources cleaned up');".}
