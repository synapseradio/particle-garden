# This module creates typed array views for particle data and grid structures.
# Both CPU (for initialization) and GPU (via WebGPU) access this data.
#
# Particle struct layout: the table in memory_layout.nim.
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays
import config
import memory_layout

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

const FLOATS_PER_PARTICLE* = 8

var sortedIndices* {.exportc.}: Uint32Array   ## sorted_idx -> original_idx
var reverseIndices* {.exportc.}: Uint32Array  ## original_idx -> sorted_idx

# Interleaved for atomic accumulation (Newton's 3rd law).
# Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
var velocityDeltaFixed* {.exportc.}: Int32Array

var gridCounts* {.exportc.}: Uint32Array
var gridOffsets* {.exportc.}: Uint32Array

var matrix* {.exportc.}: Float32Array

proc allocateBuffers*() {.exportc.} =
  # Create shared memory with SharedArrayBuffer backing
  wasmMemory = newWebAssemblyMemory(memory_layout.WASM_MEMORY_PAGES, memory_layout.WASM_MEMORY_PAGES_MAX, true)
  sharedBuffer = wasmMemory.buffer

  let layout = MEMORY_LAYOUT
  let maxCells = memory_layout.MAX_GRID * memory_layout.MAX_GRID

  particlesA = newFloat32Array(sharedBuffer, layout.particlesA, memory_layout.MAX_PARTICLES * FLOATS_PER_PARTICLE)
  particlesSorted = newFloat32Array(sharedBuffer, layout.particlesSorted, memory_layout.MAX_PARTICLES * FLOATS_PER_PARTICLE)

  sortedIndices = newUint32Array(sharedBuffer, layout.sortedIndices, memory_layout.MAX_PARTICLES)
  reverseIndices = newUint32Array(sharedBuffer, layout.reverseIndices, memory_layout.MAX_PARTICLES)

  velocityDeltaFixed = newInt32Array(sharedBuffer, layout.velocityDeltaFixed, memory_layout.MAX_PARTICLES * 2)

  gridCounts = newUint32Array(sharedBuffer, layout.gridCounts, maxCells)
  gridOffsets = newUint32Array(sharedBuffer, layout.gridOffsets, maxCells)

  matrix = newFloat32Array(sharedBuffer, layout.matrix,
    memory_layout.MAX_SPECIES * memory_layout.MAX_SPECIES)

# ==============================================================================
# SECTION 8: AoS FIELD INDICES
# ==============================================================================

# Field indices within a particle (relative to particle start)
const
  FIELD_POS_X* = 0
  FIELD_POS_Y* = 1
  FIELD_VEL_X* = 2
  FIELD_VEL_Y* = 3
  FIELD_SPECIES* = 4  # Stored as f32, reinterpret as u32
  FIELD_DENSITY* = 5
  # Fields 6-7 are padding

