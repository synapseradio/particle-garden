# ==============================================================================
# EMERGENT GARDEN - UNIFIED WASM MEMORY BUFFERS
# ==============================================================================
#
# This module creates a single WebAssembly.Memory backed by SharedArrayBuffer.
# All particle data, grid structures, and sync buffers live in this unified memory.
#
# ZERO-COPY ARCHITECTURE:
# - JS creates typed array views into the WASM memory
# - Workers instantiate WASM with the same memory
# - WASM reads/writes directly - no uploads or downloads needed
#
# Memory layout (defined in config.nim MEMORY_LAYOUT):
# - Offset 0-1MB: Reserved for WASM stack/heap
# - Offset 1MB+: Particle data, grid, matrix, sync buffer
#
# Compile with: nim js -o:web/buffers.js src/buffers.nim
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays
import config

# ==============================================================================
# SECTION 1: UNIFIED WASM MEMORY
# ==============================================================================

# The single WebAssembly.Memory that backs everything.
# Created with `shared: true` to enable SharedArrayBuffer backing.
# Passed to workers and WASM modules for zero-copy access.
var wasmMemory* {.exportc.}: WebAssemblyMemory

# The underlying SharedArrayBuffer of wasmMemory.
# Cached once since memory growth is disabled.
var sharedBuffer* {.exportc.}: JsObject

# ==============================================================================
# SECTION 2: TYPED ARRAY VIEWS - Buffer set A
# ==============================================================================

var pxA* {.exportc.}: Float32Array
var pyA* {.exportc.}: Float32Array
var vxA* {.exportc.}: Float32Array
var vyA* {.exportc.}: Float32Array
var speciesA* {.exportc.}: Uint8Array
var denA* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 3: TYPED ARRAY VIEWS - Buffer set B
# ==============================================================================

var pxB* {.exportc.}: Float32Array
var pyB* {.exportc.}: Float32Array
var vxB* {.exportc.}: Float32Array
var vyB* {.exportc.}: Float32Array
var speciesB* {.exportc.}: Uint8Array
var denB* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 4: TYPED ARRAY VIEWS - Velocity deltas
# ==============================================================================

var vxDelta* {.exportc.}: Float32Array
var vyDelta* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 5: TYPED ARRAY VIEWS - Grid structure
# ==============================================================================

var gridCounts* {.exportc.}: Uint16Array
var gridOffsets* {.exportc.}: Uint32Array

# ==============================================================================
# SECTION 6: TYPED ARRAY VIEWS - Sync and matrix
# ==============================================================================

var syncArray* {.exportc.}: Int32Array
var matrix* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 7: LOCAL TEMPORARY ARRAYS (not in shared memory)
# ==============================================================================

var fillOffsets* {.exportc.}: Uint32Array
var renderData* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 8: ACTIVE BUFFER TRACKING
# ==============================================================================

var activeParity* {.exportc.}: int = 0

# ==============================================================================
# SECTION 9: BUFFER ALLOCATION
# ==============================================================================

proc allocateBuffers*() {.exportc.} =
  ## Create the unified WebAssembly.Memory and all typed array views.
  ##
  ## This creates a single 128MB SharedArrayBuffer-backed memory.
  ## All particle data lives at known offsets within this memory.
  ## Both JS and WASM access the same underlying buffer - zero copies.

  # Create unified WASM memory with SharedArrayBuffer backing
  wasmMemory = newWebAssemblyMemory(WASM_MEMORY_PAGES, WASM_MEMORY_PAGES_MAX, true)

  # Cache the buffer reference (will not change since growth is disabled)
  sharedBuffer = wasmMemory.buffer

  # Get layout offsets from config
  let L = MEMORY_LAYOUT
  let maxCells = MAX_GRID * MAX_GRID

  # ─────────────────────────────────────────────────────────────────────────────
  # Create typed array views - Buffer set A
  # ─────────────────────────────────────────────────────────────────────────────

  pxA = newFloat32Array(sharedBuffer, L.pxA, MAX_PARTICLES)
  pyA = newFloat32Array(sharedBuffer, L.pyA, MAX_PARTICLES)
  vxA = newFloat32Array(sharedBuffer, L.vxA, MAX_PARTICLES)
  vyA = newFloat32Array(sharedBuffer, L.vyA, MAX_PARTICLES)
  denA = newFloat32Array(sharedBuffer, L.denA, MAX_PARTICLES)
  speciesA = newUint8Array(sharedBuffer, L.speciesA, MAX_PARTICLES)

  # ─────────────────────────────────────────────────────────────────────────────
  # Create typed array views - Buffer set B
  # ─────────────────────────────────────────────────────────────────────────────

  pxB = newFloat32Array(sharedBuffer, L.pxB, MAX_PARTICLES)
  pyB = newFloat32Array(sharedBuffer, L.pyB, MAX_PARTICLES)
  vxB = newFloat32Array(sharedBuffer, L.vxB, MAX_PARTICLES)
  vyB = newFloat32Array(sharedBuffer, L.vyB, MAX_PARTICLES)
  denB = newFloat32Array(sharedBuffer, L.denB, MAX_PARTICLES)
  speciesB = newUint8Array(sharedBuffer, L.speciesB, MAX_PARTICLES)

  # ─────────────────────────────────────────────────────────────────────────────
  # Create typed array views - Velocity deltas
  # ─────────────────────────────────────────────────────────────────────────────

  vxDelta = newFloat32Array(sharedBuffer, L.vxDelta, MAX_PARTICLES)
  vyDelta = newFloat32Array(sharedBuffer, L.vyDelta, MAX_PARTICLES)

  # ─────────────────────────────────────────────────────────────────────────────
  # Create typed array views - Grid structure
  # ─────────────────────────────────────────────────────────────────────────────

  gridCounts = newUint16Array(sharedBuffer, L.gridCounts, maxCells)
  gridOffsets = newUint32Array(sharedBuffer, L.gridOffsets, maxCells)

  # ─────────────────────────────────────────────────────────────────────────────
  # Create typed array views - Sync and matrix
  # ─────────────────────────────────────────────────────────────────────────────

  syncArray = newInt32Array(sharedBuffer, L.sync, 256)
  matrix = newFloat32Array(sharedBuffer, L.matrix, 36)

  # ─────────────────────────────────────────────────────────────────────────────
  # Local arrays (not shared with workers)
  # ─────────────────────────────────────────────────────────────────────────────

  fillOffsets = newUint32Array(maxCells)
  renderData = newFloat32Array(MAX_PARTICLES * 6)

# ==============================================================================
# SECTION 10: PARITY MANAGEMENT
# ==============================================================================

proc setActiveParity*(parity: int) {.exportc.} =
  ## Set the active parity. Used by grid building to flip buffers after sorting.
  ## parity - 0 for buffer set A, 1 for buffer set B
  activeParity = parity

