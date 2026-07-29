# ==============================================================================
# PARTICLE GARDEN - SPATIAL GRID DIMENSIONS
# ==============================================================================
#
# Spatial partitioning grid dimensions for particle simulation.
#
# This module only computes grid dimensions. The actual grid building
# (counting, prefix sum, scatter) happens entirely on the GPU via
# WebGPU compute shaders in webgpu_compute.nim.
#
# Compiled into app.nim's single frontend compilation unit (see app.nim);
# built with `just happen`.
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/js_interop
import config

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  GridDimensions* = ref object of JsObject
    gridW* {.exportc.}: int
    gridH* {.exportc.}: int
    cellSize* {.exportc.}: int

# ==============================================================================
# SECTION 2: MODULE STATE
# ==============================================================================

# Grid dimensions - updated each frame from WORLD size and interaction radius
var gridW* {.exportc.}: int = 0
var gridH* {.exportc.}: int = 0
var cellSize* {.exportc.}: int = 0

# Performance timing
var gridTimeMs* {.exportc.}: float = 0.0

# ==============================================================================
# SECTION 3: GRID DIMENSION COMPUTATION
# ==============================================================================

proc computeGridDimensions*(canvasWidth: int, canvasHeight: int): GridDimensions {.exportc.} =
  ## Compute grid dimensions without doing any sorting.
  ##
  ## NOTE: Grid dimensions are computed from WORLD size, not canvas size.
  ## This decouples physics resolution from display resolution.
  ## The canvas parameters are ignored but kept for API compatibility.

  # Classic spatial hash: cellSize tracks the interaction radius so a 3x3
  # stencil covers every interaction, no LOD artifacts. Floored at 16 below
  # that (INTERACTION_RADIUS_MIN is 10).
  cellSize = max(CONFIG.interactionRadius, 16)

  gridW = jsFloor(config.WORLD_W / cellSize.float)
  gridH = jsFloor(config.WORLD_H / cellSize.float)
  gridW = int(jsMax(1.0, jsMin(gridW.float, MAX_GRID.float)))
  gridH = int(jsMax(1.0, jsMin(gridH.float, MAX_GRID.float)))

  result = GridDimensions()
  result.gridW = gridW
  result.gridH = gridH
  result.cellSize = cellSize


