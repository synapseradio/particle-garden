# ==============================================================================
# PARTICLE GARDEN - UNIFIED MEMORY BUFFERS
# ==============================================================================
#
# This module creates typed array views for particle data and grid structures.
# Both CPU (for initialization) and GPU (via WebGPU) access this data.
#
# ARCHITECTURE: WebGPU-only physics with AoS (Array of Structures) layout.
#
# AoS PARTICLE STRUCT (32 bytes per particle):
# ┌─────────┬──────────┬───────┐
# │ Offset  │ Field    │ Type  │
# ├─────────┼──────────┼───────┤
# │ 0       │ pos.x    │ f32   │
# │ 4       │ pos.y    │ f32   │
# │ 8       │ vel.x    │ f32   │
# │ 12      │ vel.y    │ f32   │
# │ 16      │ species  │ u32   │
# │ 20      │ density  │ f32   │
# │ 24-31   │ padding  │ -     │
# └─────────┴──────────┴───────┘
#
# BUFFER ORGANIZATION:
# - particlesA: Primary particle buffer viewed as Float32Array (8 floats/particle)
# - particlesSorted: Sorted particles for cache-friendly force computation
# - velocityDeltaFixed: Int32Array for atomic Newton's 3rd law accumulation
# - gridCounts, gridOffsets: Grid buffers for spatial hashing
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays
import config
import memory_layout

# ==============================================================================
# SECTION 1: SHARED MEMORY
# ==============================================================================

var wasmMemory* {.exportc.}: WebAssemblyMemory
var sharedBuffer* {.exportc.}: JsObject

# ==============================================================================
# SECTION 2: AoS PARTICLE BUFFERS
# ==============================================================================
#
# Particles are stored as Float32Array with 8 elements per particle (32 bytes).
# The struct layout matches WGSL exactly for zero-copy GPU upload.

var particlesA* {.exportc.}: Float32Array      ## Primary particles (N * 8 f32s)
var particlesSorted* {.exportc.}: Float32Array ## Sorted particles for forces

# Number of f32 elements per particle (32 bytes / 4 bytes per f32 = 8)
const FLOATS_PER_PARTICLE* = 8

# ==============================================================================
# SECTION 3: INDEX MAPPINGS
# ==============================================================================

var sortedIndices* {.exportc.}: Uint32Array   ## sorted_idx -> original_idx
var reverseIndices* {.exportc.}: Uint32Array  ## original_idx -> sorted_idx

# ==============================================================================
# SECTION 4: VELOCITY DELTAS
# ==============================================================================

# Fixed-point interleaved velocity deltas for atomic accumulation (Newton's 3rd law)
# Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
var velocityDeltaFixed* {.exportc.}: Int32Array

# ==============================================================================
# SECTION 5: GRID STRUCTURE
# ==============================================================================

var gridCounts* {.exportc.}: Uint32Array
var gridOffsets* {.exportc.}: Uint32Array

# ==============================================================================
# SECTION 6: SHARED STATE
# ==============================================================================

var syncArray* {.exportc.}: Int32Array
var matrix* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 7: LOCAL TEMPORARY ARRAYS
# ==============================================================================

var fillOffsets* {.exportc.}: Uint32Array
var renderData* {.exportc.}: Float32Array

# ==============================================================================
# SECTION 8: BUFFER ALLOCATION
# ==============================================================================

proc allocateBuffers*() {.exportc.} =
  ## Create the shared memory buffer and all typed array views.

  # Create shared memory with SharedArrayBuffer backing
  wasmMemory = newWebAssemblyMemory(memory_layout.WASM_MEMORY_PAGES, memory_layout.WASM_MEMORY_PAGES_MAX, true)
  sharedBuffer = wasmMemory.buffer

  let L = MEMORY_LAYOUT
  let maxCells = memory_layout.MAX_GRID * memory_layout.MAX_GRID

  # ─────────────────────────────────────────────────────────────────────────────
  # AoS particle buffers (8 f32s per particle = 32 bytes)
  # ─────────────────────────────────────────────────────────────────────────────

  particlesA = newFloat32Array(sharedBuffer, L.particlesA, memory_layout.MAX_PARTICLES * FLOATS_PER_PARTICLE)
  particlesSorted = newFloat32Array(sharedBuffer, L.particlesSorted, memory_layout.MAX_PARTICLES * FLOATS_PER_PARTICLE)

  # ─────────────────────────────────────────────────────────────────────────────
  # Index mappings
  # ─────────────────────────────────────────────────────────────────────────────

  sortedIndices = newUint32Array(sharedBuffer, L.sortedIndices, memory_layout.MAX_PARTICLES)
  reverseIndices = newUint32Array(sharedBuffer, L.reverseIndices, memory_layout.MAX_PARTICLES)

  # ─────────────────────────────────────────────────────────────────────────────
  # Velocity deltas (2 i32s per particle)
  # ─────────────────────────────────────────────────────────────────────────────

  velocityDeltaFixed = newInt32Array(sharedBuffer, L.velocityDeltaFixed, memory_layout.MAX_PARTICLES * 2)

  # ─────────────────────────────────────────────────────────────────────────────
  # Grid structure
  # ─────────────────────────────────────────────────────────────────────────────

  gridCounts = newUint32Array(sharedBuffer, L.gridCounts, maxCells)
  gridOffsets = newUint32Array(sharedBuffer, L.gridOffsets, maxCells)

  # ─────────────────────────────────────────────────────────────────────────────
  # Shared state
  # ─────────────────────────────────────────────────────────────────────────────

  syncArray = newInt32Array(sharedBuffer, L.sync, 256)
  matrix = newFloat32Array(sharedBuffer, L.matrix, 36)

  # ─────────────────────────────────────────────────────────────────────────────
  # Local arrays (not shared)
  # ─────────────────────────────────────────────────────────────────────────────

  fillOffsets = newUint32Array(maxCells)
  renderData = newFloat32Array(memory_layout.MAX_PARTICLES * 6)

# ==============================================================================
# SECTION 9: AoS ACCESSOR HELPERS
# ==============================================================================
#
# These helpers provide convenient access to particle fields within the AoS buffer.
# For bulk operations, prefer direct Float32Array access with computed offsets.

proc getParticleOffset*(particleIdx: int): int {.inline.} =
  ## Get the Float32Array index for a particle's first field (pos.x)
  particleIdx * FLOATS_PER_PARTICLE

# Field indices within a particle (relative to particle start)
const
  FIELD_POS_X* = 0
  FIELD_POS_Y* = 1
  FIELD_VEL_X* = 2
  FIELD_VEL_Y* = 3
  FIELD_SPECIES* = 4  # Stored as f32, reinterpret as u32
  FIELD_DENSITY* = 5
  # Fields 6-7 are padding

