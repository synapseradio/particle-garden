# ==============================================================================
# EMERGENT GARDEN - CONFIGURATION MODULE
# ==============================================================================
#
# Configuration and constants for Goober Garden simulation.
#
# This module exports:
# - CONFIG: Mutable runtime configuration (particle count, physics params, rendering options)
# - MAX_* constants: Upper bounds for buffer allocation and grid sizing
# - MEMORY_LAYOUT: AoS memory offsets (sourced from memory_layout.nim)
# - PARTICLE_*: Particle struct layout constants
# - COLORS: Species color palette as interleaved RGB Float32Array
#
# IMPORTANT: Memory layout constants are defined in memory_layout.nim.
# This module re-exports them for JS consumption.
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays
import memory_layout

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  ConfigObject* = ref object of JsObject
    ## Runtime configuration for particle simulation
    particleCount* {.exportc.}: int
    speciesCount* {.exportc.}: int
    interactionRadius* {.exportc.}: int
    forceStrength* {.exportc.}: float
    friction* {.exportc.}: float
    timeScale* {.exportc.}: float
    particleSize* {.exportc.}: int
    trails* {.exportc.}: bool
    trailAlpha* {.exportc.}: float
    glowIntensity* {.exportc.}: float
    maxVelocity* {.exportc.}: float

  MemoryLayoutObject* = ref object of JsObject
    ## AoS memory layout offsets for particle buffers.
    ## Values are sourced from memory_layout.OFFSETS.

    # AoS particle buffers
    particlesA* {.exportc.}: int       ## Primary particles (N * 32 bytes)
    particlesSorted* {.exportc.}: int  ## Sorted particles for cache-friendly forces

    # Index mappings
    sortedIndices* {.exportc.}: int    ## sorted_idx -> original_idx
    reverseIndices* {.exportc.}: int   ## original_idx -> sorted_idx

    # Velocity deltas
    velocityDeltaFixed* {.exportc.}: int  ## Interleaved fixed-point Int32 deltas

    # Grid
    gridCounts* {.exportc.}: int
    gridOffsets* {.exportc.}: int

    # Shared state
    matrix* {.exportc.}: int
    sync* {.exportc.}: int
    totalSize* {.exportc.}: int

# ==============================================================================
# SECTION 2: BUFFER ALLOCATION LIMITS (re-exported from memory_layout)
# ==============================================================================

let MAX_PARTICLES* {.exportc.}: int = memory_layout.MAX_PARTICLES
let MAX_SPECIES* {.exportc.}: int = memory_layout.MAX_SPECIES
let MAX_GRID* {.exportc.}: int = memory_layout.MAX_GRID

# ==============================================================================
# SECTION 2b: PARTICLE STRUCT LAYOUT (re-exported from memory_layout)
# ==============================================================================
#
# AoS Particle struct: 32 bytes, cache-aligned
# ┌─────────┬──────────┬───────┐
# │ Offset  │ Field    │ Size  │
# ├─────────┼──────────┼───────┤
# │ 0       │ pos.x    │ 4     │
# │ 4       │ pos.y    │ 4     │
# │ 8       │ vel.x    │ 4     │
# │ 12      │ vel.y    │ 4     │
# │ 16      │ species  │ 4     │
# │ 20      │ density  │ 4     │
# │ 24-31   │ padding  │ 8     │
# └─────────┴──────────┴───────┘

let PARTICLE_STRIDE* {.exportc.}: int = memory_layout.PARTICLE_STRIDE
let PARTICLE_POS_X_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_POS_X_OFFSET
let PARTICLE_POS_Y_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_POS_Y_OFFSET
let PARTICLE_VEL_X_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_VEL_X_OFFSET
let PARTICLE_VEL_Y_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_VEL_Y_OFFSET
let PARTICLE_SPECIES_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_SPECIES_OFFSET
let PARTICLE_DENSITY_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_DENSITY_OFFSET

# ==============================================================================
# SECTION 3: WORLD DIMENSIONS (decoupled from canvas/display)
# ==============================================================================

# Fixed world size for physics simulation. This is independent of canvas/display
# resolution. Using 4K as reference ensures consistent particle density and
# physics behavior across all display sizes.
let WORLD_W* {.exportc.}: float = 3840.0
let WORLD_H* {.exportc.}: float = 2160.0

# ==============================================================================
# SECTION 4: WASM MEMORY CONFIGURATION (re-exported from memory_layout)
# ==============================================================================

let WASM_MEMORY_PAGES* {.exportc.}: int = memory_layout.WASM_MEMORY_PAGES
let WASM_MEMORY_PAGES_MAX* {.exportc.}: int = memory_layout.WASM_MEMORY_PAGES_MAX
let WASM_DATA_OFFSET* {.exportc.}: int = memory_layout.WASM_DATA_OFFSET

# ==============================================================================
# SECTION 5: MEMORY LAYOUT (sourced from memory_layout.OFFSETS)
# ==============================================================================

proc createMemoryLayout(): MemoryLayoutObject =
  ## Convert memory_layout.OFFSETS to a JS-exportable object.
  result = MemoryLayoutObject()
  result.particlesA = memory_layout.OFFSETS.particlesA
  result.particlesSorted = memory_layout.OFFSETS.particlesSorted
  result.sortedIndices = memory_layout.OFFSETS.sortedIndices
  result.reverseIndices = memory_layout.OFFSETS.reverseIndices
  result.velocityDeltaFixed = memory_layout.OFFSETS.velocityDeltaFixed
  result.gridCounts = memory_layout.OFFSETS.gridCounts
  result.gridOffsets = memory_layout.OFFSETS.gridOffsets
  result.matrix = memory_layout.OFFSETS.matrix
  result.sync = memory_layout.OFFSETS.sync
  result.totalSize = memory_layout.OFFSETS.totalSize

var MEMORY_LAYOUT* {.exportc.}: MemoryLayoutObject = createMemoryLayout()

# ==============================================================================
# SECTION 6: RUNTIME CONFIGURATION
# ==============================================================================

proc createConfig(): ConfigObject =
  result = ConfigObject()
  result.particleCount = 16000
  result.speciesCount = 4
  result.interactionRadius = 50
  result.forceStrength = 1.0
  result.friction = 0.05
  result.timeScale = 0.5
  result.particleSize = 3
  result.trails = false
  result.trailAlpha = 0.92
  result.glowIntensity = 1.0
  result.maxVelocity = 10.0

var CONFIG* {.exportc.}: ConfigObject = createConfig()

# ==============================================================================
# SECTION 7: COLOR PALETTE
# ==============================================================================

var COLORS* {.exportc.}: Float32Array = newFloat32Array(@[
  1.0, 0.42, 0.42,  # Red
  1.0, 0.85, 0.24,  # Yellow
  0.42, 0.8, 0.47,  # Green
  0.3, 0.59, 1.0,   # Blue
  0.73, 0.42, 1.0,  # Purple
  1.0, 0.55, 0.3    # Orange
])
