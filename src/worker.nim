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

import std/jsffi

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  Int32Array* = ref object of JsObject
  MessageEvent* = ref object of JsObject
    data*: JsObject

# ==============================================================================
# SECTION 2: JAVASCRIPT FFI
# ==============================================================================

proc newInt32Array*(buffer: JsObject, byteOffset: int, length: int): Int32Array {.importjs: "new Int32Array(#, #, #)".}
proc newFloat32Array*(size: int): JsObject {.importjs: "new Float32Array(#)".}
proc newInt32ArrayFromFloat*(f32: JsObject): JsObject {.importjs: "new Int32Array(#.buffer)".}

proc `[]`*(a: Int32Array, i: int): int32 {.importjs: "#[#]".}
proc `[]=`*(a: Int32Array, i: int, v: int32) {.importjs: "#[#] = #".}

proc atomicWait*(ta: Int32Array, index: int, value: int32) {.importjs: "Atomics.wait(#, #, #)".}
proc atomicLoad*(ta: Int32Array, index: int): int32 {.importjs: "Atomics.load(#, #)".}
proc atomicStore*(ta: Int32Array, index: int, value: int32) {.importjs: "Atomics.store(#, #, #)".}
proc atomicNotify*(ta: Int32Array, index: int) {.importjs: "Atomics.notify(#, #)".}

proc importScripts*(url: cstring) {.importjs: "importScripts(#)".}
proc then*(promise: JsObject, callback: proc(result: JsObject)) {.importjs: "#.then(#)".}

var self {.importjs: "self", nodecl.}: JsObject

# ==============================================================================
# SECTION 3: WORKER STATE
# ==============================================================================

var
  myIndex: int32
  wasmModule: JsObject
  physicsStepRangeFn: JsObject
  syncBuffer: Int32Array
  syncOffset: int  # Byte offset of sync buffer in shared memory

# Bit conversion buffers
var floatConvArr: JsObject
var intConvArr: JsObject

# ==============================================================================
# SECTION 4: HELPER FUNCTIONS
# ==============================================================================

proc asFloat(bits: int32): float32 =
  ## Reinterpret int32 bits as float32
  {.emit: """
  `floatConvArr`[0] = 0;
  `intConvArr`[0] = `bits`;
  return `floatConvArr`[0];
  """.}

# ==============================================================================
# SECTION 5: MAIN WORK LOOP (ZERO-COPY)
# ==============================================================================

proc workLoop() =
  ## Infinite loop: wait for frame signal, call WASM physics, signal done.
  ## NO DATA COPYING - WASM accesses shared memory directly.
  var lastFrame: int32 = 0

  while true:
    # --- WAIT FOR FRAME ---
    atomicWait(syncBuffer, 0, lastFrame)
    lastFrame = atomicLoad(syncBuffer, 0)

    # --- READ CONFIGURATION ---
    let workerCount = int32(syncBuffer[1])
    let baseIdx = 2 + myIndex * 2
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
    let bufferParity = int32(syncBuffer[configOffset + 11])
    let particleCount = int32(syncBuffer[configOffset + 12])

    # --- CALL WASM PHYSICS (ZERO-COPY) ---
    # No uploads or downloads! WASM reads/writes shared memory directly.
    {.emit: """
    `physicsStepRangeFn`(
      `startIdx`, `endIdx`, `particleCount`,
      `bufferParity`,
      `dt`, `W`, `H`, `rMax`, `fMul`,
      `gridW`, `gridH`,
      `mouseX`, `mouseY`, `mouseDown` ? 1.0 : 0.0
    );
    """.}

    # --- SIGNAL COMPLETION ---
    let doneOffset = configOffset + 16 + myIndex
    atomicStore(syncBuffer, doneOffset, 1)
    atomicNotify(syncBuffer, doneOffset)

# ==============================================================================
# SECTION 6: INITIALIZATION
# ==============================================================================

proc initWasmAndStart(module: JsObject) =
  ## Called when WASM module finishes loading.
  wasmModule = module

  # Create wrapped function for physicsStepRange (13 scalar parameters)
  {.emit: """
  var cwrapArgs = ['number','number','number','number',
                   'number','number','number','number','number',
                   'number','number','number','number','number'];
  `physicsStepRangeFn` = `wasmModule`.cwrap('physicsStepRange', null, cwrapArgs);
  console.log('WASM Worker ' + `myIndex` + ' initialized (zero-copy mode)');
  """.}

  workLoop()

proc onMessage(e: MessageEvent) =
  ## Handle init message from main thread.
  let msg = e.data
  let mType = msg["type"].to(cstring)

  if mType == "init":
    myIndex = msg.workerIndex.to(int32)
    syncOffset = msg.syncOffset.to(int)

    # Bit conversion buffers
    floatConvArr = newFloat32Array(1)
    intConvArr = newInt32ArrayFromFloat(floatConvArr)

    # Create view into shared memory for sync buffer
    let wasmMemory = msg.wasmMemory
    let buffer = wasmMemory["buffer"]
    syncBuffer = newInt32Array(buffer, syncOffset, 256)

    # Load WASM with the shared memory
    importScripts("/physics.js")
    {.emit: """
    createPhysicsModule({ wasmMemory: `wasmMemory` }).then(`initWasmAndStart`);
    """.}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

self["onmessage"] = onMessage
