# ==============================================================================
# PARTICLE GARDEN - SPATIAL GRID DIMENSIONS
# ==============================================================================
#
# Spatial partitioning grid dimensions for particle simulation.
#
# ARCHITECTURE: WebGPU-only physics.
# This module only computes grid dimensions. The actual grid building
# (counting, prefix sum, scatter) happens entirely on the GPU via
# WebGPU compute shaders in webgpu_compute.nim.
#
# The computeGridDimensions() proc calculates how many cells to use
# based on world size and interaction radius. This info is passed
# to the GPU for the bin-count, prefix-sum, and bin-scatter passes.
#
# Compile with: nim js -o:web/grid.js src/grid.nim
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

# Grid dimensions - updated each frame based on canvas size and interaction radius
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
  ## Used by WebGPU path which builds the grid on the GPU.
  ##
  ## NOTE: Grid dimensions are computed from WORLD size, not canvas size.
  ## This decouples physics resolution from display resolution.
  ## The canvas parameters are ignored but kept for API compatibility.
  ##
  ## Returns object with gridW, gridH, cellSize

  # Cell size equals interaction radius - classic spatial hash, no LOD artifacts
  cellSize = max(CONFIG.interactionRadius, 16)

  # Use WORLD dimensions for grid computation (decoupled from display)
  gridW = jsFloor(config.WORLD_W / cellSize.float)
  gridH = jsFloor(config.WORLD_H / cellSize.float)
  gridW = int(jsMax(1.0, jsMin(gridW.float, MAX_GRID.float)))
  gridH = int(jsMax(1.0, jsMin(gridH.float, MAX_GRID.float)))

  result = GridDimensions()
  result.gridW = gridW
  result.gridH = gridH
  result.cellSize = cellSize

# ==============================================================================
# SECTION 4: LEGACY BUILDGRID REMOVED
# ==============================================================================
#
# The buildGrid() proc that performed CPU-side grid construction and particle
# sorting has been removed. In WebGPU mode, grid building happens entirely
# on the GPU via compute shaders:
#   - bin-count.wgsl: Count particles per cell
#   - prefix-sum*.wgsl: Compute cell offsets
#   - bin-scatter.wgsl: Build sorted index mapping
#
# Only computeGridDimensions() remains to calculate grid parameters.
# ==============================================================================

