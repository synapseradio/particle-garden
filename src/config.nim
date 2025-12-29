# ==============================================================================
# EMERGENT GARDEN - CONFIGURATION MODULE
# ==============================================================================
#
# Configuration and constants for Goober Garden simulation.
#
# This module exports:
# - CONFIG: Mutable runtime configuration (particle count, physics params, rendering options)
# - MAX_* constants: Upper bounds for buffer allocation and grid sizing
# - COLORS: Species color palette as interleaved RGB Float32Array
#
# Compile with: nim js -o:web/config.js src/config.nim
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays

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

  MemoryLayoutObject* = ref object of JsObject
    ## WASM memory layout offsets for particle buffers
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
    gridCounts* {.exportc.}: int
    gridOffsets* {.exportc.}: int
    matrix* {.exportc.}: int
    sync* {.exportc.}: int
    totalSize* {.exportc.}: int

# ==============================================================================
# SECTION 2: BUFFER ALLOCATION LIMITS
# ==============================================================================

# Buffer allocation limits - these determine SharedArrayBuffer sizes
# Using `let` instead of `const` so they're exported as JS variables
let MAX_PARTICLES* {.exportc.}: int = 64000  ## Maximum supported particle count
let MAX_SPECIES* {.exportc.}: int = 6        ## Maximum species for attraction matrix
let MAX_GRID* {.exportc.}: int = 256         ## Maximum grid cells per dimension
let MAX_WORKERS* {.exportc.}: int = 16       ## Maximum Web Workers for physics

# ==============================================================================
# SECTION 3: WASM MEMORY CONFIGURATION
# ==============================================================================

# Unified WASM memory layout
# All particle data lives in WASM linear memory for zero-copy access
let WASM_MEMORY_PAGES* {.exportc.}: int = 2048      ## 128MB initial (each page = 64KB)
let WASM_MEMORY_PAGES_MAX* {.exportc.}: int = 8192  ## 512MB maximum
let WASM_DATA_OFFSET* {.exportc.}: int = 1024 * 1024  ## 1MB - skip WASM internals

# ==============================================================================
# SECTION 4: MEMORY LAYOUT COMPUTATION
# ==============================================================================

# Helper to align to 4-byte boundary
proc align4(x: int): int {.inline.} = (x + 3) and (not 3)

# Compute memory layout offsets at initialization
# These match the JavaScript IIFE logic exactly
proc computeMemoryLayout(): MemoryLayoutObject =
  let floatSize = MAX_PARTICLES * 4  # Float32 = 4 bytes
  let uint8Size = MAX_PARTICLES      # Uint8 = 1 byte
  let gridCells = MAX_GRID * MAX_GRID

  var offset = WASM_DATA_OFFSET

  # Buffer A (source during even frames)
  let pxA = offset
  offset += floatSize
  let pyA = offset
  offset += floatSize
  let vxA = offset
  offset += floatSize
  let vyA = offset
  offset += floatSize
  let denA = offset
  offset += floatSize
  let speciesA = offset
  offset += uint8Size

  # Buffer B (source during odd frames) - align after uint8
  offset = align4(offset)
  let pxB = offset
  offset += floatSize
  let pyB = offset
  offset += floatSize
  let vxB = offset
  offset += floatSize
  let vyB = offset
  offset += floatSize
  let denB = offset
  offset += floatSize
  let speciesB = offset
  offset += uint8Size

  # Velocity deltas (workers write here) - align after uint8
  offset = align4(offset)
  let vxDelta = offset
  offset += floatSize
  let vyDelta = offset
  offset += floatSize

  # Spatial grid
  let gridCounts = offset
  offset += gridCells * 2  # Uint16Array
  offset = align4(offset)
  let gridOffsets = offset
  offset += gridCells * 4  # Uint32Array

  # Attraction matrix (6x6 = 36 floats)
  let matrix = offset
  offset += 36 * 4

  # Sync buffer for Atomics (must be 4-byte aligned for Int32Array)
  offset = align4(offset)
  let sync = offset
  offset += 256 * 4  # 256 int32s for sync

  let totalSize = offset

  # Construct the result object
  result = MemoryLayoutObject()
  result.pxA = pxA
  result.pyA = pyA
  result.vxA = vxA
  result.vyA = vyA
  result.denA = denA
  result.speciesA = speciesA
  result.pxB = pxB
  result.pyB = pyB
  result.vxB = vxB
  result.vyB = vyB
  result.denB = denB
  result.speciesB = speciesB
  result.vxDelta = vxDelta
  result.vyDelta = vyDelta
  result.gridCounts = gridCounts
  result.gridOffsets = gridOffsets
  result.matrix = matrix
  result.sync = sync
  result.totalSize = totalSize

# ==============================================================================
# SECTION 5: RUNTIME CONFIGURATION
# ==============================================================================

# Runtime configuration - these values can be modified during simulation
proc createConfig(): ConfigObject =
  result = ConfigObject()
  result.particleCount = 16000
  result.speciesCount = 4
  result.interactionRadius = 50
  result.forceStrength = 1.0
  result.friction = 0.05
  result.timeScale = 0.5
  result.particleSize = 2
  result.trails = false
  result.trailAlpha = 0.92

var CONFIG* {.exportc.}: ConfigObject = createConfig()

# ==============================================================================
# SECTION 6: MEMORY LAYOUT
# ==============================================================================

# Memory layout offsets (computed from WASM_DATA_OFFSET)
# Each offset is relative to WASM memory start (byte 0)
var MEMORY_LAYOUT* {.exportc.}: MemoryLayoutObject = computeMemoryLayout()

# ==============================================================================
# SECTION 7: COLOR PALETTE
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

