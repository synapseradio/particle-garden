# ==============================================================================
# EMERGENT GARDEN - WEB WORKER MANAGEMENT
# ==============================================================================
#
# Web Worker management for Goober Garden physics computation.
#
# ZERO-COPY ARCHITECTURE:
# - Workers receive the shared WebAssembly.Memory object
# - Each worker instantiates WASM with this memory
# - WASM reads/writes particle data directly - no copies
#
# This module handles:
# - Worker pool creation and initialization
# - Physics dispatch via sync buffer coordination
# - Worker completion synchronization using Atomics
#
# Compile with: nim js -o:web/workers.js src/workers.nim
#
# ==============================================================================

import std/jsffi
import std/asyncjs
import bindings/typed_arrays
import bindings/atomics
import bindings/workers as workersBindings
import bindings/window
import bindings/js_interop

# Direct imports - in consolidated build, all modules share the same variables
import config
import buffers

# ==============================================================================
# SECTION 1: FLOAT-TO-INT CONVERSION FOR ATOMICS
# ==============================================================================

# Convert a float to its bit representation as an int32.
# Required because Atomics only work with integer arrays.
# Uses typed array aliasing for reinterpret cast.

var floatConvArr: Float32Array
var intConvArr: Int32Array
var conversionInitialized = false

proc initFloatConversion() =
  ## Initialize the typed arrays used for float-to-int bit conversion.
  ## Must be called before floatToIntBits is used.
  if not conversionInitialized:
    floatConvArr = newFloat32Array(1)
    intConvArr = newInt32Array(floatConvArr.buffer)
    conversionInitialized = true

proc floatToIntBits*(f: float): int32 {.exportc.} =
  ## Convert a float to its IEEE 754 bit representation as an int32.
  ## This is needed because Atomics only work with integer typed arrays.
  if not conversionInitialized:
    initFloatConversion()
  floatConvArr[0] = f
  result = intConvArr[0]

# ==============================================================================
# SECTION 2: WORKER POOL STATE
# ==============================================================================

var workers* {.exportc.}: JsObject
var workerCount* {.exportc.}: int = 0
var frameCounter* {.exportc.}: int = 0

# Initialize workers array - must happen at module init
workers = newJsArray()

# ==============================================================================
# SECTION 3: ARRAY PUSH HELPER
# ==============================================================================

proc push*(arr: JsObject, item: JsObject) {.importjs: "#.push(#)".}
  ## Push an item onto a JavaScript array.

# ==============================================================================
# SECTION 4: WORKER CREATION
# ==============================================================================

proc createWorkers*() {.exportc.} =
  ## Create and initialize the worker pool.
  ##
  ## Each worker receives the shared WebAssembly.Memory object.
  ## Workers instantiate WASM with this memory for zero-copy access.

  # Calculate worker count: min(hardwareConcurrency - 1, MAX_WORKERS), at least 1
  let hwConcurrency = navigatorHardwareConcurrency()
  let availableCores = if hwConcurrency > 0: hwConcurrency else: 4
  workerCount = max(1, min(availableCores - 1, MAX_WORKERS))

  let workerUrl = cstring"worker.js"

  for i in 0 ..< workerCount:
    let worker = newWorker(workerUrl)

    # Build init message
    let msg = jsffi.newJsObject()
    msg["type"] = toJs(cstring"init")
    msg["workerIndex"] = toJs(i)
    msg["wasmMemory"] = cast[JsObject](wasmMemory)
    msg["syncOffset"] = toJs(MEMORY_LAYOUT.sync)

    # Send shared memory reference - workers use this for WASM instantiation
    worker.postMessage(msg)

    workers.push(cast[JsObject](worker))

  console.log("Created ", workerCount, " workers (zero-copy mode)")

# ==============================================================================
# SECTION 5: MATRIX SYNCHRONIZATION
# ==============================================================================

proc updateWorkersMatrix*() {.exportc.} =
  ## Notify workers of matrix changes.
  ## In zero-copy mode, the matrix is in shared memory - workers see updates immediately.
  discard # Matrix is in shared WASM memory - no action needed

# ==============================================================================
# SECTION 6: PHYSICS DISPATCH
# ==============================================================================

proc dispatchPhysicsShared*(
  dt: float,
  particleCount: int,
  canvasWidth: float,
  canvasHeight: float,
  gridW: int,
  gridH: int,
  cellSize: float,
  mouseX: float,
  mouseY: float,
  mouseDown: bool,
  mouseRightDown: bool
): Future[void] {.async, exportc.} =
  ## Dispatch physics computation to workers and wait for completion.
  ##
  ## ZERO-COPY: Workers read particle data directly from shared memory.
  ## This function only writes config scalars to the sync buffer.
  ##
  ## Parameters:
  ## - dt: Delta time in seconds
  ## - particleCount: Number of active particles
  ## - canvasWidth: Canvas width in pixels
  ## - canvasHeight: Canvas height in pixels
  ## - gridW: Grid width in cells
  ## - gridH: Grid height in cells
  ## - cellSize: Cell size in pixels
  ## - mouseX: Mouse X position
  ## - mouseY: Mouse Y position
  ## - mouseDown: Whether left mouse button is pressed
  ## - mouseRightDown: Whether right mouse button is pressed

  let n = particleCount
  let perWorker = jsCeil(n.float / workerCount.float)

  # Write worker assignments to sync buffer
  syncArray[1] = workerCount

  for i in 0 ..< workerCount:
    let startIdx = i * perWorker
    let endIdx = min(startIdx + perWorker, n)
    syncArray[2 + i * 2] = startIdx
    syncArray[2 + i * 2 + 1] = endIdx

  # Config offset in sync buffer
  let configOffset = 2 + workerCount * 2
  syncArray[configOffset + 0] = floatToIntBits(canvasWidth)
  syncArray[configOffset + 1] = floatToIntBits(canvasHeight)
  syncArray[configOffset + 2] = floatToIntBits(CONFIG.interactionRadius.float)
  syncArray[configOffset + 3] = gridW
  syncArray[configOffset + 4] = gridH
  syncArray[configOffset + 5] = floatToIntBits(cellSize)
  syncArray[configOffset + 6] = floatToIntBits(CONFIG.forceStrength * 0.5)
  syncArray[configOffset + 7] = floatToIntBits(dt)
  syncArray[configOffset + 8] = floatToIntBits(mouseX)
  syncArray[configOffset + 9] = floatToIntBits(mouseY)
  syncArray[configOffset + 10] = if mouseDown: 1 else: 0
  syncArray[configOffset + 11] = if mouseRightDown: 1 else: 0
  syncArray[configOffset + 12] = buffers.activeParity
  syncArray[configOffset + 13] = particleCount

  # Clear done flags
  let doneOffset = configOffset + 16
  for i in 0 ..< workerCount:
    discard atomicStore(syncArray, doneOffset + i, 0)

  # Increment frame counter to wake workers
  frameCounter += 1
  discard atomicStore(syncArray, 0, frameCounter)
  discard atomicNotify(syncArray, 0)

  # Wait for all workers to finish
  for i in 0 ..< workerCount:
    let waitResult = atomicWaitAsync(syncArray, doneOffset + i, 0)
    if waitResult.async:
      # waitResult.value is a Promise - await it
      discard await cast[Future[cstring]](waitResult.value)

# ==============================================================================
# SECTION 7: EXPORTS (for consolidated build, these are available via Nim import)
# ==============================================================================

# All public procs and vars with {.exportc.} are accessible via Nim import.
# No ES module export block needed in consolidated build.
