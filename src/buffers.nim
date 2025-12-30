# ==============================================================================
# EMERGENT GARDEN - UNIFIED MEMORY BUFFERS
# ==============================================================================
#
# This module creates typed array views for particle data and grid structures.
# Both CPU (for initialization) and GPU (via WebGPU) access this data.
#
# ARCHITECTURE: WebGPU-only physics.
# All physics computation runs on the GPU. The CPU-side buffers are used for:
# - Initial particle generation (randomization)
# - Uploading initial state to GPU buffers
# - WebGL fallback rendering (if WebGPU render unavailable)
#
# Memory layout (defined in memory_layout.nim):
# - Offset 0-1MB: Reserved for future use
# - Offset 1MB+: Particle data, grid, matrix
#
# ==============================================================================
# BUFFER SETS (A and B)
# ==============================================================================
#
# Two buffer sets exist for historical reasons (legacy double-buffering).
# In WebGPU mode, only buffer set A is actively used:
#   - activeParity is always 0
#   - Physics does IN-PLACE updates on GPU buffers
#   - No buffer swapping occurs
#
# Buffer set B is retained for:
#   - GPU-side parity selection (webgpu_compute still references both)
#   - Potential future use cases
#
# INVARIANT:
#   After physics completes, buffer[activeParity] (always A) contains valid state.
#   Renderer reads from buffer[activeParity].
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

# Fixed-point interleaved velocity deltas for atomic accumulation (Newton's 3rd law)
# Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
# Scale: 65536 (16-bit fractional precision)
var velocityDeltaFixed* {.exportc.}: Int32Array

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

  # Fixed-point interleaved: 2 int32s per particle (vdx, vdy)
  velocityDeltaFixed = newInt32Array(sharedBuffer, L.velocityDeltaFixed, MAX_PARTICLES * 2)

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
#
# See PARITY CONTRACT in file header for full documentation.
#
# Quick reference:
#   parity = 0 → Buffer set A is active (pxA, pyA, vxA, vyA, speciesA, denA)
#   parity = 1 → Buffer set B is active (pxB, pyB, vxB, vyB, speciesB, denB)
#

proc setActiveParity*(parity: int) {.exportc.} =
  ## Set the active parity. Used by grid.buildGrid() after scatter completes.
  ##
  ## parity: 0 for buffer set A, 1 for buffer set B
  ##
  ## WASM path: Called after grid scatter to flip to the newly-written buffer.
  ## WebGPU path: Typically not called (parity stays at 0).
  ##
  assert parity in {0, 1}, "Parity must be 0 or 1, got: " & $parity
  activeParity = parity

