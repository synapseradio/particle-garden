# ==============================================================================
# EMERGENT GARDEN - CONFIGURATION MODULE
# ==============================================================================
#
# Configuration and constants for Goober Garden simulation.
#
# This module exports:
# - CONFIG: Mutable runtime configuration (particle count, physics params, rendering options)
# - MAX_* constants: Upper bounds for buffer allocation and grid sizing
# - MEMORY_LAYOUT: WASM memory offsets (sourced from memory_layout.nim)
# - COLORS: Species color palette as interleaved RGB Float32Array
#
# IMPORTANT: Memory layout constants are defined in memory_layout.nim.
# This module re-exports them for JS consumption.
#
# Compile with: nim js -o:web/config.js src/config.nim
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
    ## WASM memory layout offsets for particle buffers.
    ## Values are sourced from memory_layout.OFFSETS.
    pxA* {.exportc.}: int
    pyA* {.exportc.}: int
    vxA* {.exportc.}: int
    vyA* {.exportc.}: int
    denA* {.exportc.}: int
    speciesA* {.exportc.}: int
    pxB* {.exportc.}: int
    pyB* {.exportc.}: int
    vxB* {.exportc.}: int
    vyB* {.exportc.}: int
    denB* {.exportc.}: int
    speciesB* {.exportc.}: int
    vxDelta* {.exportc.}: int
    vyDelta* {.exportc.}: int
    velocityDeltaFixed* {.exportc.}: int  ## Interleaved fixed-point Int32 deltas
    gridCounts* {.exportc.}: int
    gridOffsets* {.exportc.}: int
    matrix* {.exportc.}: int
    sync* {.exportc.}: int
    totalSize* {.exportc.}: int

# ==============================================================================
# SECTION 2: BUFFER ALLOCATION LIMITS (re-exported from memory_layout)
# ==============================================================================

# These re-export constants from memory_layout.nim for JS consumption.
# Using `let` so they appear as JS variables (not inlined away by optimizer).
let MAX_PARTICLES* {.exportc.}: int = memory_layout.MAX_PARTICLES
let MAX_SPECIES* {.exportc.}: int = memory_layout.MAX_SPECIES
let MAX_GRID* {.exportc.}: int = memory_layout.MAX_GRID
let MAX_WORKERS* {.exportc.}: int = memory_layout.MAX_WORKERS

# ==============================================================================
# SECTION 2b: WORLD DIMENSIONS (decoupled from canvas/display)
# ==============================================================================

# Fixed world size for physics simulation. This is independent of canvas/display
# resolution. Using 4K as reference ensures consistent particle density and
# physics behavior across all display sizes.
#
# The grid cell count depends on WORLD dimensions, not canvas dimensions.
# With WORLD_W=3840, WORLD_H=2160, and interactionRadius=120:
#   gridW = 3840/120 = 32 cells
#   gridH = 2160/120 = 18 cells
#   576 total cells → ~83 particles/cell at 48K particles
#
# Rendering scales world coords to canvas coords.
let WORLD_W* {.exportc.}: float = 3840.0
let WORLD_H* {.exportc.}: float = 2160.0

# ==============================================================================
# SECTION 3: WASM MEMORY CONFIGURATION (re-exported from memory_layout)
# ==============================================================================

let WASM_MEMORY_PAGES* {.exportc.}: int = memory_layout.WASM_MEMORY_PAGES
let WASM_MEMORY_PAGES_MAX* {.exportc.}: int = memory_layout.WASM_MEMORY_PAGES_MAX
let WASM_DATA_OFFSET* {.exportc.}: int = memory_layout.WASM_DATA_OFFSET

# ==============================================================================
# SECTION 4: MEMORY LAYOUT (sourced from memory_layout.OFFSETS)
# ==============================================================================

# Create JS-exportable object from compile-time OFFSETS
proc createMemoryLayout(): MemoryLayoutObject =
  ## Convert memory_layout.OFFSETS to a JS-exportable object.
  result = MemoryLayoutObject()
  result.pxA = memory_layout.OFFSETS.pxA
  result.pyA = memory_layout.OFFSETS.pyA
  result.vxA = memory_layout.OFFSETS.vxA
  result.vyA = memory_layout.OFFSETS.vyA
  result.denA = memory_layout.OFFSETS.denA
  result.speciesA = memory_layout.OFFSETS.speciesA
  result.pxB = memory_layout.OFFSETS.pxB
  result.pyB = memory_layout.OFFSETS.pyB
  result.vxB = memory_layout.OFFSETS.vxB
  result.vyB = memory_layout.OFFSETS.vyB
  result.denB = memory_layout.OFFSETS.denB
  result.speciesB = memory_layout.OFFSETS.speciesB
  result.vxDelta = memory_layout.OFFSETS.vxDelta
  result.vyDelta = memory_layout.OFFSETS.vyDelta
  result.velocityDeltaFixed = memory_layout.OFFSETS.velocityDeltaFixed
  result.gridCounts = memory_layout.OFFSETS.gridCounts
  result.gridOffsets = memory_layout.OFFSETS.gridOffsets
  result.matrix = memory_layout.OFFSETS.matrix
  result.sync = memory_layout.OFFSETS.sync
  result.totalSize = memory_layout.OFFSETS.totalSize

var MEMORY_LAYOUT* {.exportc.}: MemoryLayoutObject = createMemoryLayout()

# ==============================================================================
# SECTION 5: RUNTIME CONFIGURATION
# ==============================================================================

# Runtime configuration - these values can be modified during simulation
proc createConfig(): ConfigObject =
  result = ConfigObject()
  result.particleCount = 64000
  result.speciesCount = 4
  result.interactionRadius = 50
  result.forceStrength = 1.0
  result.friction = 0.05
  result.timeScale = 0.5
  result.particleSize = 3  # ~30% larger than original (was 2)
  result.trails = false
  result.trailAlpha = 0.92
  result.glowIntensity = 1.0
  result.maxVelocity = 10.0

var CONFIG* {.exportc.}: ConfigObject = createConfig()

# ==============================================================================
# SECTION 6: COLOR PALETTE
# ==============================================================================

# Species color palette - interleaved RGB values (6 species x 3 components)
var COLORS* {.exportc.}: Float32Array = newFloat32Array(@[
  1.0, 0.42, 0.42,  # Red
  1.0, 0.85, 0.24,  # Yellow
  0.42, 0.8, 0.47,  # Green
  0.3, 0.59, 1.0,   # Blue
  0.73, 0.42, 1.0,  # Purple
  1.0, 0.55, 0.3    # Orange
])
