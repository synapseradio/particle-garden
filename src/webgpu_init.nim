# ==============================================================================
# EMERGENT GARDEN - WEBGPU DEVICE INITIALIZATION
# ==============================================================================
#
# This module handles:
# - Feature detection for WebGPU availability
# - GPU adapter and device acquisition with appropriate limits
# - GPU buffer creation matching the SharedArrayBuffer memory layout
# - Graceful fallback when WebGPU is unavailable
#
# HYBRID ARCHITECTURE:
# WebGPU compute shaders will handle physics calculations while WebGL1
# continues to handle rendering. Both systems operate on the same logical
# memory structure for seamless data sharing.
#
# MEMORY LAYOUT:
# GPU buffers mirror the MEMORY_LAYOUT structure defined in config.js:
# - Particle buffers A/B (positions, velocities, species, density)
# - Velocity delta buffers (worker accumulation targets)
# - Spatial grid buffers (counts and offsets)
# - Attraction matrix and sync buffers
#
# Compile with: nim js -o:web/webgpu-init.js src/webgpu_init.nim
#
# ==============================================================================

from std/jsffi import JsObject, toJs, `[]`, `[]=`
import std/asyncjs
import bindings/js_interop
import bindings/webgpu
import config

# Disambiguate newJsObject - use the one from std/jsffi
proc makeJsObject(): JsObject {.importjs: "({})".}

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  GPUBuffersObject* = ref object of JsObject
    pxA* {.importjs: "pxA".}: GPUBuffer
    pyA* {.importjs: "pyA".}: GPUBuffer
    pxB* {.importjs: "pxB".}: GPUBuffer
    pyB* {.importjs: "pyB".}: GPUBuffer
    vxA* {.importjs: "vxA".}: GPUBuffer
    vyA* {.importjs: "vyA".}: GPUBuffer
    vxB* {.importjs: "vxB".}: GPUBuffer
    vyB* {.importjs: "vyB".}: GPUBuffer
    denA* {.importjs: "denA".}: GPUBuffer
    denB* {.importjs: "denB".}: GPUBuffer
    speciesA* {.importjs: "speciesA".}: GPUBuffer
    speciesB* {.importjs: "speciesB".}: GPUBuffer
    velocityDelta* {.importjs: "velocityDelta".}: GPUBuffer
    gridCounts* {.importjs: "gridCounts".}: GPUBuffer
    gridOffsets* {.importjs: "gridOffsets".}: GPUBuffer
    matrix* {.importjs: "matrix".}: GPUBuffer
    sync* {.importjs: "sync".}: GPUBuffer
    sortedIndices* {.importjs: "sortedIndices".}: GPUBuffer
    fillPointers* {.importjs: "fillPointers".}: GPUBuffer
    blockSums* {.importjs: "blockSums".}: GPUBuffer
    blockOffsets* {.importjs: "blockOffsets".}: GPUBuffer
    cellStats* {.importjs: "cellStats".}: GPUBuffer
    # Physical scatter buffers (cache-optimized sorted particle data)
    pxSorted* {.importjs: "pxSorted".}: GPUBuffer
    pySorted* {.importjs: "pySorted".}: GPUBuffer
    vxSorted* {.importjs: "vxSorted".}: GPUBuffer
    vySorted* {.importjs: "vySorted".}: GPUBuffer
    speciesSorted* {.importjs: "speciesSorted".}: GPUBuffer
    reverseIndices* {.importjs: "reverseIndices".}: GPUBuffer

  InitResult* = ref object of JsObject
    success* {.importjs: "success".}: bool
    error* {.importjs: "error".}: cstring
    info* {.importjs: "info".}: JsObject

  BufferSizes* = ref object of JsObject
    position* {.importjs: "position".}: int
    velocity* {.importjs: "velocity".}: int
    density* {.importjs: "density".}: int
    species* {.importjs: "species".}: int
    velocityDelta* {.importjs: "velocityDelta".}: int
    gridCounts* {.importjs: "gridCounts".}: int
    gridOffsets* {.importjs: "gridOffsets".}: int
    matrix* {.importjs: "matrix".}: int
    sync* {.importjs: "sync".}: int
    sortedIndices* {.importjs: "sortedIndices".}: int
    cellStats* {.importjs: "cellStats".}: int
    # Physical scatter buffer sizes (cache optimization)
    pxSorted* {.importjs: "pxSorted".}: int
    pySorted* {.importjs: "pySorted".}: int
    vxSorted* {.importjs: "vxSorted".}: int
    vySorted* {.importjs: "vySorted".}: int
    speciesSorted* {.importjs: "speciesSorted".}: int
    reverseIndices* {.importjs: "reverseIndices".}: int

# ==============================================================================
# SECTION 2: HELPER BINDINGS
# ==============================================================================

# Max values helper for finding largest buffer size
proc jsMaxValues*(obj: JsObject): int {.importjs: "Math.max(...Object.values(#))".}
  ## Get the maximum value from all values in an object

# Object.keys().length helper
proc jsObjectLength*(obj: JsObject): int {.importjs: "Object.keys(#).length".}
  ## Get the number of keys in an object

# Array reduce helper for summing buffer sizes
proc jsReduceSum*(obj: JsObject): int {.importjs: "Object.values(#).reduce((sum, size) => sum + size, 0)".}
  ## Sum all values in an object

# Math.ceil helper for workgroup calculation
proc jsCeilDiv*(a, b: int): int {.importjs: "Math.ceil(# / #)".}
  ## Ceiling division

# Destroy all buffers in an object (calls destroy() on each value that has it)
proc destroyAllBuffers*(obj: JsObject) {.importjs: "Object.values(#).forEach((buffer) => { if (buffer && typeof buffer.destroy === 'function') { buffer.destroy(); } })".}
  ## Iterate all values and call destroy() on any that have it

# ==============================================================================
# SECTION 3: GPU STATE
# ==============================================================================

# The WebGPU adapter representing the physical GPU.
var adapter* {.exportc.}: GPUAdapter = nil

# The WebGPU logical device for GPU operations.
var device* {.exportc.}: GPUDevice = nil

# The device's command queue for submitting GPU work.
var queue* {.exportc.}: GPUQueue = nil

# WebGPU buffers mirroring the SharedArrayBuffer layout.
# Each buffer corresponds to a section of MEMORY_LAYOUT.
var buffers* {.exportc.}: GPUBuffersObject = cast[GPUBuffersObject](makeJsObject())

# Whether WebGPU initialization succeeded.
var isWebGPUAvailable* {.exportc.}: bool = false

# ==============================================================================
# SECTION 4: BUFFER SIZE CALCULATIONS
# ==============================================================================

proc calculateBufferSizes*(): BufferSizes {.exportc.} =
  ## Calculate GPU buffer sizes matching the SharedArrayBuffer memory layout.
  ## All sizes must be aligned to 4 bytes for WebGPU requirements.
  let floatSize = MAX_PARTICLES * 4  # Float32 = 4 bytes per element
  let gridCells = MAX_GRID * MAX_GRID

  # Species uses u32 in WGSL shaders (for compatibility with storage buffers)
  let speciesBufferSize = MAX_PARTICLES * 4  # u32 per particle

  result = BufferSizes()
  # Particle data - positions (2x float32 per particle)
  result.position = floatSize * 2  # px and py interleaved would be optimal, but matching SAB layout

  # Particle data - velocities (2x float32 per particle)
  result.velocity = floatSize * 2

  # Particle data - density (1x float32 per particle)
  result.density = floatSize

  # Particle data - species (1x uint8 per particle, aligned)
  result.species = speciesBufferSize

  # Velocity deltas for accumulation (2x float32 per particle)
  result.velocityDelta = floatSize * 2

  # Spatial grid - cell occupancy counts (uint32 per cell for WGSL atomic<u32>)
  result.gridCounts = gridCells * 4

  # Spatial grid - particle offset indices (uint32 per cell)
  result.gridOffsets = gridCells * 4

  # Attraction matrix (species x species interactions)
  result.matrix = MAX_SPECIES * MAX_SPECIES * 4  # float32

  # Sync primitives (256 int32s for atomics)
  result.sync = 256 * 4

  # Sorted indices mapping (uint32 per particle)
  result.sortedIndices = MAX_PARTICLES * 4  # Maps sorted index -> original particle index

  # Cell statistics for hierarchical forces (8 floats per cell: 2 centroid + 6 species counts)
  result.cellStats = gridCells * 8 * 4  # 32 bytes per cell

  # Physical scatter buffers (cache-optimized sorted particle data)
  # These buffers hold particle data in spatially-sorted order, enabling sequential
  # memory access in the forces pass for L1 cache hits instead of random access L3 misses.
  result.pxSorted = floatSize        # Sorted X positions (f32 per particle)
  result.pySorted = floatSize        # Sorted Y positions (f32 per particle)
  result.vxSorted = floatSize        # Sorted X velocities (f32 per particle)
  result.vySorted = floatSize        # Sorted Y velocities (f32 per particle)
  result.speciesSorted = speciesBufferSize  # Sorted species (u32 per particle)
  result.reverseIndices = MAX_PARTICLES * 4  # Maps original_idx -> sorted_idx (for velocity scatter)

# ==============================================================================
# SECTION 5: FEATURE DETECTION
# ==============================================================================

proc detectWebGPU*(): bool {.exportc.} =
  ## Check if WebGPU is available in the current environment.
  ## Returns true if navigator.gpu exists and appears functional.
  if not hasWebGPU():
    {.emit: "console.warn('WebGPU not supported: navigator.gpu is undefined');".}
    return false

  # Additional sanity check - verify requestAdapter is a function
  if not isJsFunction(navigator.gpu.toJs["requestAdapter".cstring]):
    {.emit: "console.warn('WebGPU not supported: requestAdapter method missing');".}
    return false

  return true

# ==============================================================================
# SECTION 6: INITIALIZATION
# ==============================================================================

proc initWebGPU*(): Future[JsObject] {.async, exportc.} =
  ## Initialize WebGPU device and create GPU buffers.
  ##
  ## This function:
  ## 1. Detects WebGPU availability
  ## 2. Requests a GPU adapter with required features
  ## 3. Creates a logical device with appropriate limits
  ## 4. Allocates GPU buffers matching the SharedArrayBuffer layout
  ##
  ## Returns: Promise<{success: boolean, error?: string}>

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

  # Calculate required buffer sizes
  let sizes = calculateBufferSizes()
  # Compute max directly to avoid Object.values including Nim metadata
  var maxBufferSize = sizes.position
  if sizes.velocity > maxBufferSize: maxBufferSize = sizes.velocity
  if sizes.density > maxBufferSize: maxBufferSize = sizes.density
  if sizes.species > maxBufferSize: maxBufferSize = sizes.species
  if sizes.velocityDelta > maxBufferSize: maxBufferSize = sizes.velocityDelta
  if sizes.gridCounts > maxBufferSize: maxBufferSize = sizes.gridCounts
  if sizes.gridOffsets > maxBufferSize: maxBufferSize = sizes.gridOffsets
  if sizes.matrix > maxBufferSize: maxBufferSize = sizes.matrix
  if sizes.sortedIndices > maxBufferSize: maxBufferSize = sizes.sortedIndices
  if sizes.pxSorted > maxBufferSize: maxBufferSize = sizes.pxSorted
  if sizes.pySorted > maxBufferSize: maxBufferSize = sizes.pySorted
  if sizes.vxSorted > maxBufferSize: maxBufferSize = sizes.vxSorted
  if sizes.vySorted > maxBufferSize: maxBufferSize = sizes.vySorted
  if sizes.speciesSorted > maxBufferSize: maxBufferSize = sizes.speciesSorted
  if sizes.reverseIndices > maxBufferSize: maxBufferSize = sizes.reverseIndices

  # Build required limits object
  let requiredLimits = makeJsObject()
  requiredLimits["maxBufferSize".cstring] = toJs(maxBufferSize * 4)  # Request 4x headroom
  requiredLimits["maxStorageBufferBindingSize".cstring] = toJs(maxBufferSize * 4)
  requiredLimits["maxComputeWorkgroupSizeX".cstring] = toJs(256)  # For particle processing
  requiredLimits["maxComputeWorkgroupsPerDimension".cstring] = toJs(jsCeilDiv(MAX_PARTICLES, 256))

  let deviceDescriptor = makeJsObject()
  deviceDescriptor["requiredLimits".cstring] = requiredLimits

  device = await adapter.requestDevice(deviceDescriptor)

  if device.isNil or device.isNullOrUndefined:
    let errorResult = makeJsObject()
    errorResult["success".cstring] = false.toJs
    errorResult["error".cstring] = "Failed to create WebGPU device.".cstring.toJs
    return errorResult

  queue = device.queue

  # Set up error handling
  device.addEventListener("uncapturederror", proc(event: JsObject) =
    let errorObj = event["error".cstring]
    {.emit: "console.error('WebGPU uncaptured error:', `errorObj`);".}
  )

  # Handle device loss - convert Future to JsPromise via cast
  let lostPromise = cast[JsPromise[JsObject]](device.lost)
  discard lostPromise.jsThen(proc(info: JsObject): JsObject =
    let msg = info["message".cstring]
    {.emit: "console.error('WebGPU device lost:', `msg`);".}
    isWebGPUAvailable = false
    return cast[JsObject](js_interop.jsNull)
  )

  {.emit: "console.log('WebGPU device created with limits:', `device`.limits);".}

  # ─────────────────────────────────────────────────────────────────────────
  # Phase 4: Create GPU Buffers
  # ─────────────────────────────────────────────────────────────────────────

  # Create buffers for double-buffered particle data (A and B sets)
  let bufferUsage = bitwiseOr(bitwiseOr(gpuBufferUsageStorage, gpuBufferUsageCopySrc), gpuBufferUsageCopyDst)
  let bufferUsageWithUniform = bitwiseOr(bufferUsage, gpuBufferUsageUniform)

  # Helper to create a buffer with descriptor
  proc createBuf(size: int, usage: int, label: cstring): GPUBuffer =
    let desc = makeJsObject()
    desc["size".cstring] = size.toJs
    desc["usage".cstring] = usage.toJs
    desc["label".cstring] = label.toJs
    return device.createBuffer(desc)

  # Positions - separate buffers for A and B sets
  buffers.pxA = createBuf(sizes.position div 2, bufferUsage, "Particle Positions X (Set A)")
  buffers.pyA = createBuf(sizes.position div 2, bufferUsage, "Particle Positions Y (Set A)")
  buffers.pxB = createBuf(sizes.position div 2, bufferUsage, "Particle Positions X (Set B)")
  buffers.pyB = createBuf(sizes.position div 2, bufferUsage, "Particle Positions Y (Set B)")

  # Velocities - separate buffers for A and B sets
  buffers.vxA = createBuf(sizes.velocity div 2, bufferUsage, "Particle Velocities X (Set A)")
  buffers.vyA = createBuf(sizes.velocity div 2, bufferUsage, "Particle Velocities Y (Set A)")
  buffers.vxB = createBuf(sizes.velocity div 2, bufferUsage, "Particle Velocities X (Set B)")
  buffers.vyB = createBuf(sizes.velocity div 2, bufferUsage, "Particle Velocities Y (Set B)")

  # Density - separate buffers for A and B sets
  buffers.denA = createBuf(sizes.density, bufferUsage, "Particle Density (Set A)")
  buffers.denB = createBuf(sizes.density, bufferUsage, "Particle Density (Set B)")

  # Species - separate buffers for A and B sets
  buffers.speciesA = createBuf(sizes.species, bufferUsage, "Particle Species (Set A)")
  buffers.speciesB = createBuf(sizes.species, bufferUsage, "Particle Species (Set B)")

  # Velocity deltas (packed vec2 per particle)
  buffers.velocityDelta = createBuf(sizes.velocityDelta, bufferUsage, "Velocity Delta (vec2)")

  # Spatial grid buffers
  buffers.gridCounts = createBuf(sizes.gridCounts, bufferUsage, "Grid Cell Counts")
  buffers.gridOffsets = createBuf(sizes.gridOffsets, bufferUsage, "Grid Cell Offsets")

  # Attraction matrix (also usable as uniform)
  buffers.matrix = createBuf(sizes.matrix, bufferUsageWithUniform, "Attraction Matrix")

  # Sync buffer (for atomics - needs special handling in WGSL)
  buffers.sync = createBuf(sizes.sync, bufferUsage, "Synchronization Buffer")

  # Sorted indices buffer (bin-scatter output, forces input)
  buffers.sortedIndices = createBuf(sizes.sortedIndices, bufferUsage, "Sorted Indices Buffer")

  # Fill pointers buffer (bin-scatter uses as atomic counters)
  # Initialized from gridOffsets before bin-scatter, then incremented per particle.
  # This is separate from gridCounts because forces needs the original counts.
  buffers.fillPointers = createBuf(sizes.gridOffsets, bufferUsage, "Fill Pointers Buffer")

  # Parallel prefix-sum intermediate buffers
  # 256 workgroups max (65536 cells / 256 per workgroup), each stores a u32
  let blockSumsSize = 256 * 4  # 256 blocks * 4 bytes per u32
  buffers.blockSums = createBuf(blockSumsSize, bufferUsage, "Prefix Sum Block Totals")
  buffers.blockOffsets = createBuf(blockSumsSize, bufferUsage, "Prefix Sum Block Offsets")

  # Cell statistics for hierarchical forces LOD
  buffers.cellStats = createBuf(sizes.cellStats, bufferUsage, "Cell Statistics (LOD)")

  # Physical scatter buffers (cache-optimized sorted particle data)
  # These buffers hold particle data in spatially-sorted order for sequential L1 cache access.
  # The bin-scatter pass physically copies particle data into these buffers, eliminating
  # the indirect indexing (pxA[sortedIndices[j]]) that caused L3 cache misses.
  buffers.pxSorted = createBuf(sizes.pxSorted, bufferUsage, "Sorted Positions X")
  buffers.pySorted = createBuf(sizes.pySorted, bufferUsage, "Sorted Positions Y")
  buffers.vxSorted = createBuf(sizes.vxSorted, bufferUsage, "Sorted Velocities X")
  buffers.vySorted = createBuf(sizes.vySorted, bufferUsage, "Sorted Velocities Y")
  buffers.speciesSorted = createBuf(sizes.speciesSorted, bufferUsage, "Sorted Species")
  buffers.reverseIndices = createBuf(sizes.reverseIndices, bufferUsage, "Reverse Indices (original -> sorted)")

  # NOTE: Staging buffers removed - WebGPU render reads directly from GPU buffers (zero readback)

  let bufferCount = jsObjectLength(cast[JsObject](buffers))
  {.emit: "console.log('WebGPU buffers created:', `bufferCount`, 'buffers');".}

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
  infoObj["bufferCount".cstring] = jsObjectLength(cast[JsObject](buffers)).toJs
  infoObj["totalMemory".cstring] = jsReduceSum(cast[JsObject](sizes)).toJs

  let successResult = makeJsObject()
  successResult["success".cstring] = true.toJs
  successResult["info".cstring] = infoObj

  return successResult

# ==============================================================================
# SECTION 7: CLEANUP
# ==============================================================================

proc cleanup*() {.exportc.} =
  ## Clean up WebGPU resources.
  ## Call this before page unload or when switching back to WASM-only mode.

  # Destroy all buffers
  destroyAllBuffers(cast[JsObject](buffers))

  # Reset buffers to empty object
  buffers = cast[GPUBuffersObject](makeJsObject())

  # Destroy device
  if not device.isNil and not device.isNullOrUndefined:
    device.destroy()

  adapter = nil
  device = nil
  queue = nil
  isWebGPUAvailable = false

  {.emit: "console.log('WebGPU resources cleaned up');".}

