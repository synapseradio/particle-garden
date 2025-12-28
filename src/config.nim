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

import std/jsffi

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  Float32Array* = ref object of JsObject

  ConfigObject* = ref object of JsObject
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
# SECTION 2: JAVASCRIPT FFI
# ==============================================================================

proc newFloat32Array*(arr: openArray[float]): Float32Array {.importjs: "new Float32Array(#)".}

# ==============================================================================
# SECTION 3: RUNTIME CONFIGURATION
# ==============================================================================

# Runtime configuration - these values can be modified during simulation
var CONFIG* {.exportc.}: ConfigObject
{.emit: """
var CONFIG = {
  particleCount: 16000,
  speciesCount: 4,
  interactionRadius: 50,
  forceStrength: 1.0,
  friction: 0.05,
  timeScale: 0.5,
  particleSize: 2,
  trails: false,
  trailAlpha: 0.92
};
""".}

# ==============================================================================
# SECTION 4: BUFFER ALLOCATION LIMITS
# ==============================================================================

# Buffer allocation limits - these determine SharedArrayBuffer sizes
const MAX_PARTICLES* {.exportc.} = 64000  ## Maximum supported particle count
const MAX_SPECIES* {.exportc.} = 6        ## Maximum species for attraction matrix
const MAX_GRID* {.exportc.} = 256         ## Maximum grid cells per dimension
const MAX_WORKERS* {.exportc.} = 16       ## Maximum Web Workers for physics

# ==============================================================================
# SECTION 5: WASM MEMORY CONFIGURATION
# ==============================================================================

# Unified WASM memory layout
# All particle data lives in WASM linear memory for zero-copy access
const WASM_MEMORY_PAGES* {.exportc.} = 2048      ## 128MB initial (each page = 64KB)
const WASM_MEMORY_PAGES_MAX* {.exportc.} = 8192  ## 512MB maximum
const WASM_DATA_OFFSET* {.exportc.} = 1024 * 1024  ## 1MB - skip WASM internals

# ==============================================================================
# SECTION 6: MEMORY LAYOUT
# ==============================================================================

# Memory layout offsets (computed from WASM_DATA_OFFSET)
# Each offset is relative to WASM memory start (byte 0)
var MEMORY_LAYOUT* {.exportc.}: MemoryLayoutObject

{.emit: """
var MEMORY_LAYOUT = (function() {
  var offset = 1048576; // WASM_DATA_OFFSET
  var floatSize = 64000 * 4; // MAX_PARTICLES * 4
  var uint8Size = 64000; // MAX_PARTICLES
  var gridCells = 256 * 256; // MAX_GRID * MAX_GRID

  var layout = {
    // Buffer A (source during even frames)
    pxA: offset,
    pyA: (offset += floatSize),
    vxA: (offset += floatSize),
    vyA: (offset += floatSize),
    denA: (offset += floatSize),
    speciesA: (offset += floatSize),

    // Buffer B (source during odd frames)
    pxB: (offset += uint8Size, offset = (offset + 3) & ~3), // Align to 4 bytes
    pyB: (offset += floatSize),
    vxB: (offset += floatSize),
    vyB: (offset += floatSize),
    denB: (offset += floatSize),
    speciesB: (offset += floatSize),

    // Velocity deltas (workers write here)
    vxDelta: (offset += uint8Size, offset = (offset + 3) & ~3),
    vyDelta: (offset += floatSize),

    // Spatial grid
    gridCounts: (offset += floatSize),
    gridOffsets: (offset += gridCells * 2, offset = (offset + 3) & ~3),

    // Attraction matrix (6x6 = 36 floats)
    matrix: (offset += gridCells * 4),

    // Sync buffer for Atomics (must be 4-byte aligned for Int32Array)
    sync: (offset += 36 * 4, offset = (offset + 3) & ~3),

    // End marker
    totalSize: (offset += 256 * 4) // 256 int32s for sync
  };

  return layout;
})();
""".}

# ==============================================================================
# SECTION 7: COLOR PALETTE
# ==============================================================================

# Species color palette - interleaved RGB values (6 species x 3 components)
var COLORS* {.exportc.}: Float32Array

{.emit: """
var COLORS = new Float32Array([
  1.0, 0.42, 0.42,  // Red
  1.0, 0.85, 0.24,  // Yellow
  0.42, 0.8, 0.47,  // Green
  0.3, 0.59, 1.0,   // Blue
  0.73, 0.42, 1.0,  // Purple
  1.0, 0.55, 0.3    // Orange
]);
""".}
