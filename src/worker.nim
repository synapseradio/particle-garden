import std/[jsffi, math]

# ==============================================================================
# EMERGENT GARDEN - HIGH PERFORMANCE PHYSICS WORKER
# ==============================================================================
#
# ARCHITECTURE OVERVIEW:
# This worker implements a "Particle Life" simulation using a Data-Oriented Design
# approach optimized for JavaScript engines (V8/SpiderMonkey).
#
# KEY OPTIMIZATIONS:
# 1. Zero-Copy Synchronization:
#    - Uses SharedArrayBuffer to share memory between Main Thread and Workers.
#    - Uses Atomics (wait/notify) for barrier synchronization, avoiding the
#      overhead of postMessage() serialization.
#
# 2. Spatial Sorting (Double Buffering):
#    - Particles are sorted by grid cell every frame on the main thread.
#    - We use double buffering (Buffer A -> Buffer B) to rewrite particles
#      in contiguous memory order.
#    - This ensures that when a worker iterates over a cell's neighbors,
#      it reads from linear memory (cache-friendly) instead of random access.
#
# 3. Cell-Level Logic:
#    - Toroidal wrapping logic is pre-calculated at the cell level, removing
#      branching instructions from the hottest inner loop.
#
# ==============================================================================

# ------------------------------------------------------------------
# JS FFI Definitions
# ------------------------------------------------------------------

type
  SharedArrayBuffer* = ref object of JsObject

  # Typed arrays
  Float32Array* = ref object of JsObject
  Int32Array* = ref object of JsObject
  Uint8Array* = ref object of JsObject
  Uint16Array* = ref object of JsObject
  Uint32Array* = ref object of JsObject

  # Message event
  MessageEvent* = ref object of JsObject
    data*: JsObject

# Constructors
proc newFloat32Array*(buffer: JsObject): Float32Array {.importjs: "new Float32Array(#)".}
proc newFloat32Array*(size: int): Float32Array {.importjs: "new Float32Array(#)".}
proc newInt32Array*(buffer: JsObject): Int32Array {.importjs: "new Int32Array(#)".}
proc newUint8Array*(buffer: JsObject): Uint8Array {.importjs: "new Uint8Array(#)".}
proc newUint16Array*(buffer: JsObject): Uint16Array {.importjs: "new Uint16Array(#)".}
proc newUint32Array*(buffer: JsObject): Uint32Array {.importjs: "new Uint32Array(#)".}

# Atomics
proc atomicWait*(ta: Int32Array, index: int, value: int32) {.importjs: "Atomics.wait(#, #, #)".}
proc atomicLoad*(ta: Int32Array, index: int): int32 {.importjs: "Atomics.load(#, #)".}
proc atomicStore*(ta: Int32Array, index: int, value: int32) {.importjs: "Atomics.store(#, #, #)".}
proc atomicNotify*(ta: Int32Array, index: int) {.importjs: "Atomics.notify(#, #)".}

# Global 'self' for worker
var self {.importjs: "self", nodecl.}: JsObject

# ------------------------------------------------------------------
# Simulation Constants
# ------------------------------------------------------------------

const MAX_SPECIES = 6

# ------------------------------------------------------------------
# State
# ------------------------------------------------------------------

# Double buffered arrays
# We toggle between set A and set B every frame.
# One set acts as the "Source" (Read-Only, Sorted by Cell).
# The other set acts as the "Destination" (Write-Only) for the next frame's sort.
var
  pxA, pyA: Float32Array
  pxB, pyB: Float32Array
  sA, sB: Uint8Array # Actual species arrays

  # Derived/Grid data
  vxDelta, vyDelta: Float32Array
  gridCounts: Uint16Array
  gridOffsets: Uint32Array

  # Coordination
  syncBuffer: Int32Array
  matrix: Float32Array

  # Worker identity
  myIndex: int32
  startIdx, endIdx: int32

# ------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------

# Array accessors (JS arrays are accessed via brackets)
proc `[]`*(a: Float32Array, i: int): float32 {.importjs: "#[#]".}
proc `[]=`*(a: Float32Array, i: int, v: float32) {.importjs: "#[#] = #".}

proc `[]`*(a: Int32Array, i: int): int32 {.importjs: "#[#]".}
proc `[]=`*(a: Int32Array, i: int, v: int32) {.importjs: "#[#] = #".}

proc `[]`*(a: Uint8Array, i: int): uint8 {.importjs: "#[#]".}
proc `[]=`*(a: Uint8Array, i: int, v: uint8) {.importjs: "#[#] = #".}

proc `[]`*(a: Uint16Array, i: int): uint16 {.importjs: "#[#]".}
proc `[]=`*(a: Uint16Array, i: int, v: uint16) {.importjs: "#[#] = #".}

proc `[]`*(a: Uint32Array, i: int): uint32 {.importjs: "#[#]".}
proc `[]=`*(a: Uint32Array, i: int, v: uint32) {.importjs: "#[#] = #".}

# Helper to reinterpret float bits as int
proc asFloat(bits: int32): float32 =
  var arr = newFloat32Array(1)
  var iarr = newInt32Array(arr["buffer"])
  iarr[0] = bits
  return arr[0]

# Safe float -> int conversion (truncates Infinity/NaN to 0)
# This forces the JS engine to use a bitwise OR operation, which is the standard
# way to hint to V8/JIT that we want a 32-bit integer. It avoids costly
# BigInt conversions or deoptimizations when values are Infinity/NaN.
proc toInt32(x: float32): int32 {.importjs: "(# | 0)".}

# ------------------------------------------------------------------
# Physics Logic
# ------------------------------------------------------------------

proc computeForces(
  startIdx, endIdx: int32,
  px, py: Float32Array,
  species: Uint8Array,
  W, H, rMax: float32,
  gridW, gridH: int32,
  cellSize, fMul, dt, mouseX, mouseY: float32,
  mouseDown: bool
) =
  # Pre-calculate constants to avoid math in the loop
  let rMaxSq = rMax * rMax
  let invR = 1.0 / rMax
  let halfW = W * 0.5
  let halfH = H * 0.5
  let invCellSize = 1.0 / cellSize
  let md2Limit = 90000.0 # 300^2

  for i in startIdx ..< endIdx:
    let xi = px[i]
    let yi = py[i]
    let si = species[i]
    let rowOffset = int32(si) * MAX_SPECIES

    var fx = 0.0'f32
    var fy = 0.0'f32

    # Use int32 explicit cast to ensure JS bitwise OR 0 behavior
    let cx = toInt32(xi * invCellSize)
    let cy = toInt32(yi * invCellSize)

    # 3x3 Neighborhood search
    # We iterate over the 9 surrounding cells to find neighbors.
    # Because particles are SORTED by cell, we can iterate 'j' linearly
    # through the particle array segments corresponding to these cells.
    for dy in -1 .. 1:
      var ny = cy + int32(dy)
      var wrapY = 0.0'f32

      # Pre-calculate Y-wrapping at the cell level.
      # This removes branching from the inner particle loop.
      if ny < 0:
        ny += gridH
        wrapY = -H
      elif ny >= gridH:
        ny -= gridH
        wrapY = H

      let nyIdx = ny * gridW

      for dx in -1 .. 1:
        var nx = cx + int32(dx)
        var wrapX = 0.0'f32

        # Pre-calculate X-wrapping at the cell level.
        if nx < 0:
          nx += gridW
          wrapX = -W
        elif nx >= gridW:
          nx -= gridW
          wrapX = W

        let cell = nyIdx + nx
        # Because particles are sorted, we just need the start index and count for this cell.
        let start = int32(gridOffsets[cell])
        let count = int32(gridCounts[cell])
        let fin = start + count

        # LINEAR SCAN over sorted neighbors
        # This is the "hot" loop (millions of iterations).
        # We read px[j], py[j] sequentially, maximizing cache hits.
        for j in start ..< fin:
          # In optimized sorted version, we allow self-check or check distance > 0
          # Since d2 > 0 check handles i == j naturally

          let ddx = (px[j] + wrapX) - xi
          let ddy = (py[j] + wrapY) - yi

          let d2 = ddx * ddx + ddy * ddy

          if d2 > 0.0 and d2 < rMaxSq:
            let d = sqrt(d2)
            let r = d * invR

            # Matrix lookup
            let s_j = species[j]
            let attr = matrix[rowOffset + int32(s_j)]

            var f: float32
            if r < 0.3:
              f = r / 0.3 - 1.0
            else:
              let t = 2.0 * r - 1.3
              let abs_t = if t < 0: -t else: t
              f = attr * (1.0 - abs_t / 0.7)

            f = f * fMul / d
            fx += ddx * f
            fy += ddy * f

    # Mouse attraction
    if mouseDown:
      var mdx = mouseX - xi
      var mdy = mouseY - yi

      if mdx > halfW: mdx -= W
      elif mdx < -halfW: mdx += W

      if mdy > halfH: mdy -= H
      elif mdy < -halfH: mdy += H

      let md2 = mdx * mdx + mdy * mdy
      if md2 > 0.0 and md2 < md2Limit:
        let md = sqrt(md2)
        let mf = 0.5 * (1.0 - md / 300.0) / md
        fx += mdx * mf
        fy += mdy * mf

    # Write to delta buffer
    vxDelta[i] = fx * dt
    vyDelta[i] = fy * dt

# ------------------------------------------------------------------
# Main Loop
# ------------------------------------------------------------------

proc workLoop() =
  var lastFrame: int32 = 0

  # The worker stays alive forever, waiting for signals from the main thread.
  while true:
    # 1. WAIT
    # We block here until the main thread updates the frame counter.
    # Atomics.wait puts the thread to sleep (no CPU usage) until notified.
    atomicWait(syncBuffer, 0, lastFrame)
    lastFrame = atomicLoad(syncBuffer, 0)

    # 2. READ CONFIG & ASSIGNMENT
    # All configuration is read from the SharedArrayBuffer (zero-copy).
    # We interpret float parameters from their integer bit representation.
    let workerCount = int32(syncBuffer[1])
    let baseIdx = 2 + myIndex * 2
    startIdx = int32(syncBuffer[baseIdx])
    endIdx = int32(syncBuffer[baseIdx + 1])

    # Read config
    let configOffset = 2 + workerCount * 2
    let W = asFloat(syncBuffer[configOffset + 0])
    let H = asFloat(syncBuffer[configOffset + 1])
    let rMax = asFloat(syncBuffer[configOffset + 2])
    let gridW = int32(syncBuffer[configOffset + 3])
    let gridH = int32(syncBuffer[configOffset + 4])
    let cellSize = asFloat(syncBuffer[configOffset + 5])

    let fMul = asFloat(syncBuffer[configOffset + 6])
    let dt = asFloat(syncBuffer[configOffset + 7])
    let mouseX = asFloat(syncBuffer[configOffset + 8])
    let mouseY = asFloat(syncBuffer[configOffset + 9])
    let mouseDown = syncBuffer[configOffset + 10] != 0
    let bufferParity = int32(syncBuffer[configOffset + 11])

    # Select Active Buffer
    let px = if bufferParity == 0: pxA else: pxB
    let py = if bufferParity == 0: pyA else: pyB
    let species = if bufferParity == 0: sA else: sB

    # Run Physics
    computeForces(
      startIdx, endIdx,
      px, py, species,
      W, H, rMax,
      gridW, gridH,
      cellSize, fMul, dt,
      mouseX, mouseY, mouseDown
    )

    # Signal Done
    # We update our specific "done" flag in the shared buffer and notify the main thread.
    let doneOffset = configOffset + 16 + myIndex
    atomicStore(syncBuffer, doneOffset, 1)
    atomicNotify(syncBuffer, doneOffset)

# ------------------------------------------------------------------
# Message Handler
# ------------------------------------------------------------------

proc onMessage(e: MessageEvent) =
  let msg = e.data
  let mType = msg["type"].to(cstring)

  if mType == "init":
    myIndex = msg.workerIndex.to(int32)

    # Init views
    pxA = newFloat32Array(msg.pxBufferA)
    pyA = newFloat32Array(msg.pyBufferA)
    sA = newUint8Array(msg.speciesBufferA)

    pxB = newFloat32Array(msg.pxBufferB)
    pyB = newFloat32Array(msg.pyBufferB)
    sB = newUint8Array(msg.speciesBufferB)

    vxDelta = newFloat32Array(msg.vxDeltaBuffer)
    vyDelta = newFloat32Array(msg.vyDeltaBuffer)

    gridCounts = newUint16Array(msg.gridCountsBuffer)
    gridOffsets = newUint32Array(msg.gridOffsetsBuffer)

    syncBuffer = newInt32Array(msg.syncBuffer)
    matrix = newFloat32Array(msg.matrixBuffer)

    # Start loop
    workLoop()

# Set up listener
self["onmessage"] = onMessage
