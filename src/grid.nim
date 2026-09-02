# ==============================================================================
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
import config
import grid_core

type
  GridDimensions* = ref object of JsObject
    gridW* {.exportc.}: int
    gridH* {.exportc.}: int
    cellSize* {.exportc.}: int

# Grid dimensions - updated each frame from WORLD size and interaction radius
var gridW* {.exportc.}: int = 0
var gridH* {.exportc.}: int = 0
var cellSize* {.exportc.}: int = 0

# Performance timing
var gridTimeMs* {.exportc.}: float = 0.0

proc computeGridDimensions*(canvasWidth: int, canvasHeight: int): GridDimensions {.exportc.} =
  ## Compute grid dimensions without doing any sorting.
  ##
  ## NOTE: Grid dimensions are computed from WORLD size, not canvas size.
  ## This decouples physics resolution from display resolution.
  ## The canvas parameters are ignored but kept for API compatibility.

  (gridW, gridH, cellSize) = grid_core.computeGridDims(
    int(config.WORLD_W), int(config.WORLD_H), CONFIG.interactionRadius)

  result = GridDimensions()
  result.gridW = gridW
  result.gridH = gridH
  result.cellSize = cellSize


