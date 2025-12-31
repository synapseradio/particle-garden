# ==============================================================================
# PARTICLE GARDEN - GRID CORE (Pure Mathematical Functions)
# ==============================================================================
#
# Pure functions for spatial grid calculations. These have no side effects
# and can be tested in isolation without buffer access.
#
# Used by:
#   - grid.nim (JS compilation)
#   - tests/test_grid.nim (native test compilation)
#
# ==============================================================================

import memory_layout

# Re-export MAX_GRID for backward compatibility with existing code
const MAX_GRID* = memory_layout.MAX_GRID

# ==============================================================================
# GRID DIMENSION COMPUTATION
# ==============================================================================

proc computeGridDims*(canvasW, canvasH, interactionRadius: int): tuple[
    gridW: int, gridH: int, cellSize: int] =
  ## Compute grid dimensions from canvas size and interaction radius.
  ##
  ## canvasW, canvasH - Canvas dimensions in pixels
  ## interactionRadius - Physics interaction radius (determines cell size)
  ##
  ## Returns:
  ##   gridW, gridH - Grid dimensions (clamped to [1, MAX_GRID])
  ##   cellSize - Actual cell size (equals interactionRadius)
  ##
  ## Cell size equals interaction radius - the classic spatial hash approach.
  ## 3×3 stencil covers all interactions. No LOD artifacts.
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


proc computeInverseCellDims*(gridW, gridH: int;
    canvasW, canvasH: float): tuple[invCellW: float, invCellH: float] =
  ## Compute inverse cell dimensions for efficient position-to-cell mapping.
  ##
  ## gridW, gridH - Grid dimensions
  ## canvasW, canvasH - Canvas dimensions
  ##
  ## Returns (gridW/canvasW, gridH/canvasH) for multiplication instead of division.
  ##
  result = (
    invCellW: float(gridW) / canvasW,
    invCellH: float(gridH) / canvasH
  )


# ==============================================================================
# CELL INDEX COMPUTATION
# ==============================================================================

proc positionToCellIndex*(px, py: float; gridW, gridH: int;
    invCellW, invCellH: float): int =
  ## Map a particle position to a cell index.
  ##
  ## px, py - Particle position
  ## gridW, gridH - Grid dimensions
  ## invCellW, invCellH - Inverse cell dimensions (from computeInverseCellDims)
  ##
  ## Returns linear cell index in [0, gridW*gridH - 1].
  ## Out-of-bounds positions are clamped to valid cells.
  ##
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


proc cellIndexToCoords*(cellIdx, gridW: int): tuple[cx: int, cy: int] =
  ## Convert a linear cell index back to cell coordinates.
  ##
  ## cellIdx - Linear cell index
  ## gridW - Grid width
  ##
  ## Returns (cx, cy) cell coordinates.
  ##
  result = (cx: cellIdx mod gridW, cy: cellIdx div gridW)


# ==============================================================================
# PREFIX SUM HELPERS
# ==============================================================================

proc computePrefixSum*(counts: openArray[int]): seq[int] =
  ## Compute exclusive prefix sum of cell counts.
  ##
  ## counts - Array of particle counts per cell
  ##
  ## Returns array of offsets where each offset[i] = sum of counts[0..i-1].
  ## This gives the starting index in the sorted buffer for each cell.
  ##
  result = newSeq[int](counts.len)
  var offset = 0
  for i in 0 ..< counts.len:
    result[i] = offset
    offset += counts[i]


proc validateGridOffsets*(offsets, counts: openArray[int];
    particleCount: int): bool =
  ## Validate that grid offsets are consistent with counts.
  ##
  ## offsets - Prefix sum offsets
  ## counts - Particle counts per cell
  ## particleCount - Total number of particles
  ##
  ## Returns true if:
  ##   - All offsets are non-negative
  ##   - offsets[i] + counts[i] <= particleCount for all i
  ##   - Sum of counts equals particleCount
  ##
  if offsets.len != counts.len:
    return false

  var totalCount = 0
  for i in 0 ..< offsets.len:
    if offsets[i] < 0:
      return false
    if offsets[i] + counts[i] > particleCount:
      return false
    totalCount += counts[i]

  result = (totalCount == particleCount)


# ==============================================================================
# INVARIANT CHECKING
# ==============================================================================

proc isValidCellIndex*(cellIdx, gridW, gridH: int): bool =
  ## Check if a cell index is valid.
  ##
  result = cellIdx >= 0 and cellIdx < gridW * gridH


proc isValidCellCoords*(cx, cy, gridW, gridH: int): bool =
  ## Check if cell coordinates are valid.
  ##
  result = cx >= 0 and cx < gridW and cy >= 0 and cy < gridH
