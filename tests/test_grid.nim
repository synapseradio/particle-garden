# ==============================================================================
# PARTICLE GARDEN - GRID CORE TESTS
# ==============================================================================
#
# Unit tests for pure grid functions in grid_core.nim
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/grid_core

# ==============================================================================
# TEST HELPERS
# ==============================================================================

const
  EPSILON* = 1e-6

proc approxEq(lhs, rhs: float; epsilon: float = EPSILON): bool =
  abs(lhs - rhs) <= epsilon

# ==============================================================================
# GRID DIMENSION TESTS
# ==============================================================================

suite "Grid Dimension Computation":
  test "computes grid from canvas and interaction radius":
    let (gridW, gridH, cellSize) = computeGridDims(
      canvasW = 1000, canvasH = 800, interactionRadius = 50)

    check gridW == 20  # 1000 / 50
    check gridH == 16  # 800 / 50
    check cellSize == 50

  test "clamps minimum grid to 1x1":
    let (gridW, gridH, _) = computeGridDims(
      canvasW = 10, canvasH = 10, interactionRadius = 100)

    # Canvas smaller than cell size
    check gridW == 1
    check gridH == 1

  test "clamps maximum grid to MAX_GRID":
    let (gridW, gridH, _) = computeGridDims(
      canvasW = 100000, canvasH = 100000, interactionRadius = 10)

    # Would be 10000x10000, clamped to 256x256
    check gridW == MAX_GRID
    check gridH == MAX_GRID

  test "handles non-divisible canvas sizes":
    let (gridW, gridH, _) = computeGridDims(
      canvasW = 1920, canvasH = 1080, interactionRadius = 50)

    # 1920/50 = 38.4 -> 38, 1080/50 = 21.6 -> 21
    check gridW == 38
    check gridH == 21

  test "cellSize equals interactionRadius":
    for radius in [25, 50, 100]:
      let (_, _, cellSize) = computeGridDims(1000, 1000, radius)
      check cellSize == radius


suite "Inverse Cell Dimensions":
  test "computes inverse dimensions correctly":
    let (invCellW, invCellH) = computeInverseCellDims(
      gridW = 10, gridH = 8, canvasW = 1000.0, canvasH = 800.0)

    check approxEq(invCellW, 0.01)  # 10/1000
    check approxEq(invCellH, 0.01)  # 8/800

  test "multiplication gives same result as division":
    let (invCellW, invCellH) = computeInverseCellDims(
      gridW = 20, gridH = 16, canvasW = 1000.0, canvasH = 800.0)

    # Test that px * invCellW gives same cell as px / cellW
    let px = 350.0
    let py = 450.0

    let cellX_mult = int(px * invCellW)
    let cellY_mult = int(py * invCellH)

    let cellX_div = int(px / 50.0)  # cellW = canvasW/gridW = 1000/20 = 50
    let cellY_div = int(py / 50.0)

    check cellX_mult == cellX_div
    check cellY_mult == cellY_div


# ==============================================================================
# CELL INDEX TESTS
# ==============================================================================

suite "Position to Cell Index":
  test "maps center position to correct cell":
    let idx = positionToCellIndex(
      px = 250.0, py = 350.0,
      gridW = 10, gridH = 10,
      invCellW = 0.01, invCellH = 0.01)  # 10/1000

    # Cell (2, 3) -> index 32
    check idx == 32

  test "clamps negative positions to first row/column":
    let idx = positionToCellIndex(
      px = -50.0, py = -50.0,
      gridW = 10, gridH = 10,
      invCellW = 0.01, invCellH = 0.01)

    check idx == 0  # Cell (0, 0)

  test "clamps positions beyond canvas to last row/column":
    let idx = positionToCellIndex(
      px = 1500.0, py = 1500.0,
      gridW = 10, gridH = 10,
      invCellW = 0.01, invCellH = 0.01)

    check idx == 99  # Cell (9, 9) = 9*10 + 9

  test "handles edge of canvas":
    # Position at 999 should map to cell 9 (0-indexed)
    let idx = positionToCellIndex(
      px = 999.0, py = 999.0,
      gridW = 10, gridH = 10,
      invCellW = 0.01, invCellH = 0.01)

    check idx == 99  # Cell (9, 9)

  test "all positions map to valid cells":
    let gridW = 20
    let gridH = 16
    let invCellW = 20.0 / 1000.0
    let invCellH = 16.0 / 800.0

    # Test various positions including edge cases
    for px in [-100.0, 0.0, 500.0, 999.0, 1500.0]:
      for py in [-100.0, 0.0, 400.0, 799.0, 1500.0]:
        let idx = positionToCellIndex(px, py, gridW, gridH, invCellW, invCellH)
        check idx >= 0
        check idx < gridW * gridH


suite "Cell Index to Coordinates":
  test "converts index 0 to (0, 0)":
    let (cx, cy) = cellIndexToCoords(0, gridW = 10)
    check cx == 0
    check cy == 0

  test "converts last index to (gridW-1, gridH-1)":
    let (cx, cy) = cellIndexToCoords(99, gridW = 10)
    check cx == 9
    check cy == 9

  test "roundtrip through index and back":
    let gridW = 10
    for cy in 0 ..< 10:
      for cx in 0 ..< 10:
        let idx = cy * gridW + cx
        let (rx, ry) = cellIndexToCoords(idx, gridW)
        check rx == cx
        check ry == cy


# ==============================================================================
# PREFIX SUM TESTS
# ==============================================================================

suite "Prefix Sum Computation":
  test "computes exclusive prefix sum":
    let counts = @[3, 1, 4, 1, 5]
    let offsets = computePrefixSum(counts)

    check offsets == @[0, 3, 4, 8, 9]

  test "empty counts gives empty offsets":
    let counts: seq[int] = @[]
    let offsets = computePrefixSum(counts)

    check offsets.len == 0

  test "single cell":
    let counts = @[10]
    let offsets = computePrefixSum(counts)

    check offsets == @[0]

  test "all zeros":
    let counts = @[0, 0, 0, 0]
    let offsets = computePrefixSum(counts)

    check offsets == @[0, 0, 0, 0]


suite "Grid Offset Validation":
  test "valid offsets pass validation":
    let counts = @[3, 2, 5]
    let offsets = @[0, 3, 5]
    let particleCount = 10

    check validateGridOffsets(offsets, counts, particleCount)

  test "rejects mismatched lengths":
    let counts = @[3, 2, 5]
    let offsets = @[0, 3]
    let particleCount = 10

    check not validateGridOffsets(offsets, counts, particleCount)

  test "rejects negative offsets":
    let counts = @[3, 2, 5]
    let offsets = @[-1, 3, 5]
    let particleCount = 10

    check not validateGridOffsets(offsets, counts, particleCount)

  test "rejects out-of-bounds access":
    let counts = @[3, 2, 5]
    let offsets = @[0, 3, 6]  # Last cell would access indices 6-10
    let particleCount = 9    # Only 9 particles

    check not validateGridOffsets(offsets, counts, particleCount)

  test "rejects wrong total count":
    let counts = @[3, 2, 5]  # Total = 10
    let offsets = @[0, 3, 5]
    let particleCount = 11    # Mismatch

    check not validateGridOffsets(offsets, counts, particleCount)

  test "rejects offsets that gap then overlap when the total still matches":
    # CONTRACT: a valid prefix sum is contiguous, offset[i] == offset[i-1] + counts[i-1].
    # Here offset[1]=3 leaves a 1-slot gap after cell 0 (ends at 2), and offset[2]=4
    # overlaps into cell 1's range. Bins corrupt each other, yet every non-negativity,
    # particleCount-bound, and total-count check still passes. The validator must
    # reject this as a non-contiguous (corrupted bin-scatter) offset array.
    let counts = @[2, 2, 1]
    let offsets = @[0, 3, 4]
    let particleCount = 5

    check not validateGridOffsets(offsets, counts, particleCount)

  test "rejects offsets where a later offset moves backward into a prior bin":
    # CONTRACT: offsets must not decrease relative to the running prefix sum.
    # offset[1]=1 sits before offset[0]+counts[0]=2, so cell 1 overlaps cell 0.
    let counts = @[2, 2, 1]
    let offsets = @[0, 1, 3]
    let particleCount = 5

    check not validateGridOffsets(offsets, counts, particleCount)


# ==============================================================================
# INVARIANT CHECKING TESTS
# ==============================================================================

suite "Cell Index Validation":
  test "valid indices pass":
    check isValidCellIndex(0, gridW = 10, gridH = 10)
    check isValidCellIndex(50, gridW = 10, gridH = 10)
    check isValidCellIndex(99, gridW = 10, gridH = 10)

  test "negative indices fail":
    check not isValidCellIndex(-1, gridW = 10, gridH = 10)

  test "out-of-bounds indices fail":
    check not isValidCellIndex(100, gridW = 10, gridH = 10)
    check not isValidCellIndex(1000, gridW = 10, gridH = 10)


suite "Cell Coordinates Validation":
  test "valid coordinates pass":
    check isValidCellCoords(0, 0, gridW = 10, gridH = 10)
    check isValidCellCoords(5, 5, gridW = 10, gridH = 10)
    check isValidCellCoords(9, 9, gridW = 10, gridH = 10)

  test "negative coordinates fail":
    check not isValidCellCoords(-1, 0, gridW = 10, gridH = 10)
    check not isValidCellCoords(0, -1, gridW = 10, gridH = 10)

  test "out-of-bounds coordinates fail":
    check not isValidCellCoords(10, 0, gridW = 10, gridH = 10)
    check not isValidCellCoords(0, 10, gridW = 10, gridH = 10)
