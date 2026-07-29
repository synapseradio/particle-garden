# ==============================================================================
# PARTICLE GARDEN - GRID CORE (Pure Mathematical Functions)
# ==============================================================================
#
# Pure functions for spatial grid calculations. These have no side effects
# and can be tested in isolation without buffer access.
#
# Used by:
#   - tests/test_grid.nim (native test compilation)
#
# This is a reference oracle, like physics_core: the grid the simulation
# actually builds lives in the WGSL bin-count/prefix-sum/bin-scatter passes,
# which no native test can execute. These functions mirror that arithmetic in
# a form the native suite can check, so the shader math has something to be
# wrong against. Nothing in src/ imports this module, and that is expected.
#
# ==============================================================================

import memory_layout

# Re-export MAX_GRID for backward compatibility with existing code
const MAX_GRID* = memory_layout.MAX_GRID

# ==============================================================================
# GRID DIMENSION COMPUTATION
# ==============================================================================

func computeGridDims*(canvasW, canvasH, interactionRadius: int): tuple[
    gridW: int, gridH: int, cellSize: int] =
  ## Compute grid dimensions from canvas size and interaction radius.
  ##
  ## canvasW, canvasH - Canvas dimensions in pixels
  ## interactionRadius - Physics interaction radius (determines cell size)
  ##
  ## Returns:
  ##   gridW, gridH - Grid dimensions (clamped to [1, MAX_GRID])
  ##   cellSize - max(interactionRadius, 16)
  ##
  ## Classic spatial hash: cellSize tracks the interaction radius so a 3×3
  ## stencil covers all interactions, no LOD artifacts. Floored at 16 below
  ## that.
  ##
  let cellSize = max(interactionRadius, 16)

  var gridW = canvasW div cellSize
  var gridH = canvasH div cellSize

  # Clamp to valid range [1, MAX_GRID]
  if gridW < 1:
    gridW = 1
  elif gridW > MAX_GRID:
    gridW = MAX_GRID

  if gridH < 1:
    gridH = 1
  elif gridH > MAX_GRID:
    gridH = MAX_GRID

  result = (gridW: gridW, gridH: gridH, cellSize: cellSize)


func computeInverseCellDims*(gridW, gridH: int;
    canvasW, canvasH: float): tuple[invCellW: float, invCellH: float] =
  ## Returns (gridW/canvasW, gridH/canvasH) for multiplication instead of division.
  result = (
    invCellW: float(gridW) / canvasW,
    invCellH: float(gridH) / canvasH
  )


# ==============================================================================
# CELL INDEX COMPUTATION
# ==============================================================================

func positionToCellIndex*(px, py: float; gridW, gridH: int;
    invCellW, invCellH: float): int =
  ## Out-of-bounds positions are clamped to valid cells.
  var cx = int(px * invCellW)
  var cy = int(py * invCellH)

  # Clamp to valid range
  if cx < 0:
    cx = 0
  elif cx >= gridW:
    cx = gridW - 1

  if cy < 0:
    cy = 0
  elif cy >= gridH:
    cy = gridH - 1

  result = cy * gridW + cx


func cellIndexToCoords*(cellIdx, gridW: int): tuple[cx: int, cy: int] =
  result = (cx: cellIdx mod gridW, cy: cellIdx div gridW)


# ==============================================================================
# PREFIX SUM HELPERS
# ==============================================================================

func computePrefixSum*(counts: openArray[int]): seq[int] =
  ## Gives the starting index in the sorted buffer for each cell.
  result = newSeq[int](counts.len)
  var offset = 0
  for idx in 0 ..< counts.len:
    result[idx] = offset
    offset += counts[idx]


func validateGridOffsets*(offsets, counts: openArray[int];
    particleCount: int): bool =
  ## The contiguity check is what separates a healthy prefix sum from a corrupted
  ## bin-scatter. A gap leaves sorted-buffer slots unclaimed, and an overlap makes
  ## two cells share slots. Both can satisfy the per-cell bound and the total-count
  ## check while still being garbage, so the consecutive-offset relationship is
  ## what actually catches them.
  ##
  if offsets.len != counts.len:
    return false

  var totalCount = 0
  for idx in 0 ..< offsets.len:
    if offsets[idx] < 0:
      return false
    if offsets[idx] + counts[idx] > particleCount:
      return false
    if idx > 0 and offsets[idx] != offsets[idx - 1] + counts[idx - 1]:
      return false
    totalCount += counts[idx]

  result = (totalCount == particleCount)


# ==============================================================================
# INVARIANT CHECKING
# ==============================================================================

func isValidCellIndex*(cellIdx, gridW, gridH: int): bool =
  result = cellIdx >= 0 and cellIdx < gridW * gridH


func isValidCellCoords*(cx, cy, gridW, gridH: int): bool =
  result = cx >= 0 and cx < gridW and cy >= 0 and cy < gridH
