# ==============================================================================
# PARTICLE GARDEN - WEBGPU DEVICE INITIALIZATION
# ==============================================================================
#
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
# BUFFER ORGANIZATION:
# - particlesA: Primary particle buffer (N * 32 bytes)
# - particlesSorted: Spatially-sorted particles for cache-friendly forces
# - velocityDeltaFixed: Interleaved i32 pairs for Newton's 3rd law atomics
# - Grid buffers: counts, offsets, fillPointers
# - Index mappings: sortedIndices, reverseIndices
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

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  GPUBuffersObject* = ref object of JsObject
    # AoS particle buffers (32 bytes per particle)
    particlesA* {.importjs: "particlesA".}: GPUBuffer       ## Primary particles
    particlesSorted* {.importjs: "particlesSorted".}: GPUBuffer  ## Sorted for forces

    # Index mappings
    sortedIndices* {.importjs: "sortedIndices".}: GPUBuffer  ## sorted -> original
    reverseIndices* {.importjs: "reverseIndices".}: GPUBuffer ## original -> sorted

    # Velocity deltas for Newton's 3rd law
    velocityDelta* {.importjs: "velocityDelta".}: GPUBuffer  ## Interleaved i32 pairs

    # Density deltas for symmetric accumulation
    densityDelta* {.importjs: "densityDelta".}: GPUBuffer  ## i32 per particle (fixed-point)

    # Grid structure
    gridCounts* {.importjs: "gridCounts".}: GPUBuffer
    gridOffsets* {.importjs: "gridOffsets".}: GPUBuffer
    fillPointers* {.importjs: "fillPointers".}: GPUBuffer

    # Prefix sum intermediates
    blockSums* {.importjs: "blockSums".}: GPUBuffer
    blockOffsets* {.importjs: "blockOffsets".}: GPUBuffer

    # Shared state
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
    ## Density delta buffer for symmetric accumulation via atomics.
    ## Half-neighbor iteration processes each pair once, but density must be
    ## accumulated for BOTH particles. Since WGSL lacks atomic f32, we use
    ## fixed-point i32 (scale=65536) and apply in integrate pass.
    densityDelta* {.importjs: "densityDelta".}: int
    gridCounts* {.importjs: "gridCounts".}: int
    gridOffsets* {.importjs: "gridOffsets".}: int
    sync* {.importjs: "sync".}: int

# ==============================================================================
# SECTION 2: HELPER BINDINGS
# ==============================================================================

proc jsObjectLength*(obj: JsObject): int {.importjs: "Object.keys(#).length".}
proc jsCeilDiv*(numerator, denominator: int): int {.importjs: "Math.ceil(# / #)".}
proc makeFeatureList(name: cstring): JsObject {.importjs: "[#]".}
proc destroyAllBuffers*(obj: JsObject) {.importjs: "Object.values(#).forEach((buffer) => { if (buffer && typeof buffer.destroy === 'function') { buffer.destroy(); } })".}

# ==============================================================================
# SECTION 3: GPU STATE
# ==============================================================================

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
# app's first use of STORAGE_BINDING: the rd-step / resolve passes sample one
# texture and write the other. fieldTextureA is the FIXED front the render and
# force passes always read; fieldTextureB trails it by one substep (see
# field-resolve.wgsl for why the half-float format forces this ping-pong
# rather than an in-place update). fieldGenerationCounter bumps whenever the textures are
# (re)created so the render side can cache its bind group and rebuild on change.
var fieldTextureA {.exportc: "pgFieldTextureA".}: GPUTexture = nil
var fieldTextureB {.exportc: "pgFieldTextureB".}: GPUTexture = nil
var fieldViewA {.exportc: "pgFieldViewA".}: GPUTextureView = nil
var fieldViewB {.exportc: "pgFieldViewB".}: GPUTextureView = nil
var fieldLinearSampler {.exportc: "pgFieldSampler".}: GPUSampler = nil
var fieldDepositBuffer {.exportc: "pgFieldDeposit".}: GPUBuffer = nil
var fieldGenerationCounter {.exportc: "pgFieldGeneration".}: int = 0

# ==============================================================================
# SECTION 4: BUFFER SIZE CALCULATIONS
# ==============================================================================

proc calculateBufferSizes*(): BufferSizes {.exportc.} =
  ## Calculate GPU buffer sizes for AoS layout.
  let gridCells = memory_layout.MAX_GRID * memory_layout.MAX_GRID

  result = BufferSizes()

  # AoS particle buffers: 32 bytes per particle
  result.particlesA = memory_layout.MAX_PARTICLES * memory_layout.PARTICLE_STRIDE
  result.particlesSorted = memory_layout.MAX_PARTICLES * memory_layout.PARTICLE_STRIDE

  # Index mappings: u32 per particle
  result.sortedIndices = memory_layout.MAX_PARTICLES * 4
  result.reverseIndices = memory_layout.MAX_PARTICLES * 4

  # Velocity deltas: 2 i32s per particle (interleaved vx, vy)
  result.velocityDelta = memory_layout.MAX_PARTICLES * 2 * 4

  # Density deltas: 1 i32 per particle (fixed-point for atomic accumulation)
  # Required for symmetric density in half-neighbor iteration
  result.densityDelta = memory_layout.MAX_PARTICLES * 4

  # Grid: u32 per cell
  result.gridCounts = gridCells * 4
  result.gridOffsets = gridCells * 4

  # Sync: 256 i32s
  result.sync = 256 * 4

# ==============================================================================
# SECTION 5: FEATURE DETECTION
# ==============================================================================

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
  samplerDesc["label".cstring] = "RD Field Sampler".cstring.toJs
  fieldLinearSampler = device.createSampler(samplerDesc)

  # Deposit buffer: 2 i32 channels (activator, inhibitor) per field cell, for
  # fixed-point atomic accumulation of per-particle splats.
  let depositBytes = FIELD_W * FIELD_H * 2 * 4
  let depositUsage = bitwiseOr(gpuBufferUsageStorage, gpuBufferUsageCopyDst)
  fieldDepositBuffer = device.createBufferLabeled(
    depositBytes, depositUsage, "RD Field Deposit (fixed-point i32, 2ch)")

  # Seed: clear both field textures to (activator=1, inhibitor=0), the trivial
  # Gray-Scott steady state, via a render-pass clear (rgba16float is renderable).
  # Particle deposits then perturb the inhibitor to ignite the pattern. Also
  # zero the deposit buffer so frame 0 folds no garbage.
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

# ==============================================================================
# SECTION 6: INITIALIZATION
# ==============================================================================

proc initWebGPU*(): Future[JsObject] {.async, exportc.} =
  ## Initialize WebGPU device and create AoS GPU buffers.

  # ─────────────────────────────────────────────────────────────────────────
  # Phase 1: Feature Detection
  # ─────────────────────────────────────────────────────────────────────────

  if not detectWebGPU():
    let errorResult = makeJsObject()
    errorResult["success".cstring] = false.toJs
    errorResult["error".cstring] = "WebGPU is not available in this browser. Try Chrome 113+ or Edge 113+.".cstring.toJs
    return errorResult

  # ─────────────────────────────────────────────────────────────────────────
  # Phase 2: Request Adapter
  # ─────────────────────────────────────────────────────────────────────────

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

  # ─────────────────────────────────────────────────────────────────────────
  # Phase 3: Request Device with Limits
  # ─────────────────────────────────────────────────────────────────────────

  let sizes = calculateBufferSizes()

  # Find max buffer size (particlesA is largest at 64K * 32 = 2MB)
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

  # ─────────────────────────────────────────────────────────────────────────
  # Phase 4: Create GPU Buffers (AoS Layout)
  # ─────────────────────────────────────────────────────────────────────────

  let bufferUsage = bitwiseOr(bitwiseOr(gpuBufferUsageStorage, gpuBufferUsageCopySrc), gpuBufferUsageCopyDst)

  proc createBuf(size: int, usage: int, label: cstring): GPUBuffer =
    let desc = makeJsObject()
    desc["size".cstring] = size.toJs
    desc["usage".cstring] = usage.toJs
    desc["label".cstring] = label.toJs
    return device.createBuffer(desc)

  # AoS particle buffers (32 bytes per particle)
  buffers.particlesA = createBuf(sizes.particlesA, bufferUsage, "Particles A (AoS, 32 bytes/particle)")
  buffers.particlesSorted = createBuf(sizes.particlesSorted, bufferUsage, "Particles Sorted (AoS, 32 bytes/particle)")

  # Index mappings
  buffers.sortedIndices = createBuf(sizes.sortedIndices, bufferUsage, "Sorted Indices (sorted -> original)")
  buffers.reverseIndices = createBuf(sizes.reverseIndices, bufferUsage, "Reverse Indices (original -> sorted)")

  # Velocity deltas for Newton's 3rd law atomics
  buffers.velocityDelta = createBuf(sizes.velocityDelta, bufferUsage, "Velocity Delta (interleaved i32)")

  # Density deltas for symmetric accumulation (half-neighbor pattern)
  # Each pair processed once; both particles receive density contribution via atomics
  buffers.densityDelta = createBuf(sizes.densityDelta, bufferUsage, "Density Delta (fixed-point i32)")

  # Grid buffers
  buffers.gridCounts = createBuf(sizes.gridCounts, bufferUsage, "Grid Cell Counts")
  buffers.gridOffsets = createBuf(sizes.gridOffsets, bufferUsage, "Grid Cell Offsets")
  buffers.fillPointers = createBuf(sizes.gridOffsets, bufferUsage, "Fill Pointers")

  # Prefix sum intermediates
  let blockSumsSize = 256 * 4
  buffers.blockSums = createBuf(blockSumsSize, bufferUsage, "Prefix Sum Block Totals")
  buffers.blockOffsets = createBuf(blockSumsSize, bufferUsage, "Prefix Sum Block Offsets")

  # Shared state
  buffers.sync = createBuf(sizes.sync, bufferUsage, "Synchronization Buffer")

  let bufferCount = jsObjectLength(cast[JsObject](buffers))
  {.emit: "console.log('WebGPU AoS buffers created:', `bufferCount`, 'buffers');".}

  # Reaction-diffusion field textures + deposit buffer (created regardless of the
  # active mode, like the SPH buffers, so a switch to RD finds them ready).
  createFieldResources()
  {.emit: "console.log('WebGPU RD field resources created (512x512 rgba16float ping-pong)');".}

  # ─────────────────────────────────────────────────────────────────────────
  # Success
  # ─────────────────────────────────────────────────────────────────────────

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

# ==============================================================================
# SECTION 7: CLEANUP
# ==============================================================================

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
