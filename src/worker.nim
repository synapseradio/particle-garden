# ==============================================================================
# EMERGENT GARDEN - WASM PHYSICS WORKER (Zero-Copy Architecture)
# ==============================================================================
#
# Each Web Worker loads its own WASM module using SHARED MEMORY.
# WASM reads particle data directly from memory - no uploads or downloads.
#
# ZERO-COPY FLOW:
#   1. Atomics.wait() until main thread signals new frame
#   2. Read config from sync buffer (scalars only)
#   3. Call WASM physicsStepRange() - WASM accesses shared memory directly
#   4. Signal completion via Atomics
#
# NO DATA COPYING: WASM and JS share the same WebAssembly.Memory
#
# ==============================================================================

# Avoid jsffi ambiguity by using std/jsffi directly for JsObject utilities
import std/jsffi
import bindings/typed_arrays
import bindings/atomics
import bindings/workers

# ==============================================================================
# SECTION 1: ADDITIONAL TYPE DEFINITIONS
# ==============================================================================

type
  WasmModule* = ref object of JsObject
    ## WASM module returned by createPhysicsModule

# ==============================================================================
# SECTION 2: WASM MODULE FFI
# ==============================================================================

# Global variable that will hold the WASM createPhysicsModule function
var createPhysicsModule {.importjs: "createPhysicsModule", nodecl.}: JsObject

proc cwrap*(module: WasmModule, name: cstring, returnType: cstring, argTypes: JsObject): JsObject {.importjs: "#.cwrap(#, #, #)".}
  ## Wrap a C function exported from WASM for convenient calling

proc importScriptsWorker*(url: cstring) {.importjs: "importScripts(#)".}
  ## Load a script into the worker's global scope

# Promise.then for untyped Promise (JsObject)
proc thenCallback*(promise: JsObject, callback: proc(result: JsObject)) {.importjs: "#.then(#)".}
  ## Attach a then callback to a Promise-like object

# Console logging
proc consoleLog*(args: varargs[JsObject, toJs]) {.importjs: "console.log(@)".}
  ## Log to console

# JavaScript null value
var jsNull* {.importjs: "null".}: JsObject

# Object utilities
proc newJsObject*(): JsObject {.importjs: "({})".}
  ## Create an empty JavaScript object

proc newJsArray*(): JsObject {.importjs: "([])".}
  ## Create an empty JavaScript array

# ==============================================================================
# SECTION 3: WORKER STATE
# ==============================================================================

var
  myIndex: int32
  wasmModule: WasmModule
  physicsStepRangeFn: JsObject
  syncBuffer: Int32Array
  syncOffset: int  # Byte offset of sync buffer in shared memory

# Bit conversion buffers - aliased views of the same ArrayBuffer
var floatConvArr: Float32Array
var intConvArr: Int32Array

# ==============================================================================
# SECTION 4: HELPER FUNCTIONS
# ==============================================================================

proc asFloat(bits: int): float =
  ## Reinterpret int32 bits as float32 using typed array aliasing.
  ## Both arrays share the same underlying buffer, so writing to intConvArr
  ## and reading from floatConvArr performs the bit reinterpretation.
  intConvArr[0] = bits
  return floatConvArr[0]

# ==============================================================================
# SECTION 5: PHYSICS FUNCTION CALL
# ==============================================================================

# Direct call to the wrapped WASM function with 15 parameters
# The function signature matches physicsStepRange in physics_wasm.nim:
# proc physicsStepRange(startIdx, endIdx, particleCount, bufferParity: int32,
#                       dt, W, H, rMax, fMul: float32,
#                       gridW, gridH: int32,
#                       mouseX, mouseY, mouseDown, mouseRightDown: float32)
proc callPhysicsStepRange(fn: JsObject,
                          startIdx, endIdx, particleCount, bufferParity: int32,
                          dt, W, H, rMax, fMul: float,
                          gridW, gridH: int32,
                          mouseX, mouseY, mouseDownVal, mouseRightDownVal: float) {.importjs: "#(#, #, #, #, #, #, #, #, #, #, #, #, #, #, #)".}

# ==============================================================================
# SECTION 6: MAIN WORK LOOP (ZERO-COPY)
# ==============================================================================

proc workLoop() =
  ## Infinite loop: wait for frame signal, call WASM physics, signal done.
  ## NO DATA COPYING - WASM accesses shared memory directly.
  var lastFrame: int = 0

  while true:
    # --- WAIT FOR FRAME ---
    discard atomicWait(syncBuffer, 0, lastFrame)
    lastFrame = atomicLoad(syncBuffer, 0)

    # --- READ CONFIGURATION ---
    let workerCount = syncBuffer[1]
    let baseIdx = 2 + int(myIndex) * 2
    let startIdx = int32(syncBuffer[baseIdx])
    let endIdx = int32(syncBuffer[baseIdx + 1])

    let configOffset = 2 + workerCount * 2
    let W = asFloat(syncBuffer[configOffset + 0])
    let H = asFloat(syncBuffer[configOffset + 1])
    let rMax = asFloat(syncBuffer[configOffset + 2])
    let gridW = int32(syncBuffer[configOffset + 3])
    let gridH = int32(syncBuffer[configOffset + 4])
    let fMul = asFloat(syncBuffer[configOffset + 6])
    let dt = asFloat(syncBuffer[configOffset + 7])
    let mouseX = asFloat(syncBuffer[configOffset + 8])
    let mouseY = asFloat(syncBuffer[configOffset + 9])
    let mouseDown = syncBuffer[configOffset + 10] != 0
    let mouseRightDown = syncBuffer[configOffset + 11] != 0
    let bufferParity = int32(syncBuffer[configOffset + 12])
    let particleCount = int32(syncBuffer[configOffset + 13])

    # --- CALL WASM PHYSICS (ZERO-COPY) ---
    # No uploads or downloads! WASM reads/writes shared memory directly.
    let mouseDownVal = if mouseDown: 1.0 else: 0.0
    let mouseRightDownVal = if mouseRightDown: 1.0 else: 0.0
    callPhysicsStepRange(physicsStepRangeFn,
                         startIdx, endIdx, particleCount, bufferParity,
                         dt, W, H, rMax, fMul,
                         gridW, gridH,
                         mouseX, mouseY, mouseDownVal, mouseRightDownVal)

    # --- SIGNAL COMPLETION ---
    let doneOffset = configOffset + 16 + int(myIndex)
    discard atomicStore(syncBuffer, doneOffset, 1)
    discard atomicNotify(syncBuffer, doneOffset)

# ==============================================================================
# SECTION 7: INITIALIZATION
# ==============================================================================

proc initWasmAndStart(module: JsObject) =
  ## Called when WASM module finishes loading.
  wasmModule = cast[WasmModule](module)

  # Create array of argument types for cwrap
  let argTypes = newJsArray()
  # 15 'number' arguments for physicsStepRange:
  # startIdx, endIdx, particleCount, bufferParity,
  # dt, W, H, rMax, fMul, gridW, gridH, mouseX, mouseY, mouseDown, mouseRightDown
  for i in 0 ..< 15:
    argTypes[i] = toJs("number")

  # Wrap the C function for convenient calling
  physicsStepRangeFn = wasmModule.cwrap(cstring"physicsStepRange", jsNull, argTypes)

  consoleLog(toJs("WASM Worker "), toJs(myIndex), toJs(" initialized (zero-copy mode)"))

  workLoop()

proc onMessage(e: MessageEvent) =
  ## Handle init message from main thread.
  let msg = e.data
  let mType = msg["type"].to(cstring)

  if mType == "init":
    myIndex = msg["workerIndex"].to(int32)
    syncOffset = msg["syncOffset"].to(int)

    # Create bit conversion buffers - aliased views of the same ArrayBuffer
    # Writing to intConvArr and reading from floatConvArr performs bit reinterpretation
    floatConvArr = newFloat32Array(1)
    intConvArr = newInt32Array(floatConvArr.buffer)

    # Create view into shared memory for sync buffer
    let wasmMemory = msg["wasmMemory"]
    let buffer = wasmMemory["buffer"]
    syncBuffer = newInt32Array(buffer, syncOffset, 256)

    # Load WASM with the shared memory
    importScriptsWorker(cstring"/physics.js")

    # Create options object with wasmMemory
    let options = newJsObject()
    options["wasmMemory"] = wasmMemory

    # Call createPhysicsModule(options).then(initWasmAndStart)
    let promise = createPhysicsModule.call(options)
    promise.thenCallback(initWasmAndStart)

# ==============================================================================
# SECTION 8: ADDITIONAL FFI FOR PROMISE AND ARRAY
# ==============================================================================

proc call*(fn: JsObject, arg: JsObject): JsObject {.importjs: "#(#)".}
  ## Call a function with one argument

proc `[]=`*(arr: JsObject, idx: int, val: JsObject) {.importjs: "#[#] = #".}
  ## Set array element

# ==============================================================================
# ENTRY POINT
# ==============================================================================

self.onmessage = onMessage
