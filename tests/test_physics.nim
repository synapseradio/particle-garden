# ==============================================================================
# EMERGENT GARDEN - PHYSICS CORE TESTS
# ==============================================================================
#
# Unit tests for pure physics functions in physics_core.nim
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/physics_core

# ==============================================================================
# TEST HELPERS
# ==============================================================================

const
  EPSILON_TIGHT* = 1e-5f   # For exact algorithm comparisons

proc approxEq(a, b: float32; epsilon: float32 = EPSILON_TIGHT): bool =
  ## Epsilon-based float comparison for testing.
  abs(a - b) <= epsilon

# ==============================================================================
# FORCE CALCULATION TESTS
# ==============================================================================

suite "Force Magnitude (unscaled)":
  test "repulsion at r=0 is -1":
    let f = calculateForceMagnitude(0.0f, attr = 1.0f)
    check approxEq(f, -1.0f, EPSILON_TIGHT)

  test "repulsion decreases linearly to 0 at r=0.3":
    let f0 = calculateForceMagnitude(0.0f, attr = 1.0f)
    let f015 = calculateForceMagnitude(0.15f, attr = 1.0f)
    let f03 = calculateForceMagnitude(0.3f, attr = 1.0f)

    check f0 < f015  # -1 < -0.5
    check f015 < f03  # -0.5 < 0
    check approxEq(f03, 0.0f, EPSILON_TIGHT)

  test "attraction peak near r=0.65":
    # The force curve peaks where |2r - 1.3| = 0, i.e., r = 0.65
    let fPeak = calculateForceMagnitude(0.65f, attr = 1.0f)
    let fBefore = calculateForceMagnitude(0.5f, attr = 1.0f)
    let fAfter = calculateForceMagnitude(0.8f, attr = 1.0f)

    check approxEq(fPeak, 1.0f, EPSILON_TIGHT)  # Max attraction
    check fBefore < fPeak
    check fAfter < fPeak

  test "zero force at r=1.0":
    # At r=1.0: |2*1.0 - 1.3| / 0.7 = 0.7/0.7 = 1, so force = attr * (1 - 1) = 0
    let f = calculateForceMagnitude(1.0f, attr = 1.0f)
    check approxEq(f, 0.0f, EPSILON_TIGHT)

  test "negative attraction inverts force":
    let fPos = calculateForceMagnitude(0.65f, attr = 1.0f)
    let fNeg = calculateForceMagnitude(0.65f, attr = -1.0f)

    check approxEq(fPos, -fNeg, EPSILON_TIGHT)

  test "zero attraction gives zero force in attraction zone":
    let f = calculateForceMagnitude(0.65f, attr = 0.0f)
    check approxEq(f, 0.0f, EPSILON_TIGHT)

  test "repulsion zone ignores attraction value":
    # In repulsion zone (r < 0.3), attr is not used
    let f1 = calculateForceMagnitude(0.15f, attr = 1.0f)
    let f2 = calculateForceMagnitude(0.15f, attr = -1.0f)
    let f3 = calculateForceMagnitude(0.15f, attr = 0.0f)

    check approxEq(f1, f2, EPSILON_TIGHT)
    check approxEq(f2, f3, EPSILON_TIGHT)


suite "Force Calculation (scaled)":
  test "scales by fMul":
    let f1 = calculateForce(0.5f, attr = 1.0f, fMul = 1.0f, invD = 1.0f)
    let f2 = calculateForce(0.5f, attr = 1.0f, fMul = 2.0f, invD = 1.0f)

    check approxEq(f2, f1 * 2.0f, EPSILON_TIGHT)

  test "scales by invD":
    let f1 = calculateForce(0.5f, attr = 1.0f, fMul = 1.0f, invD = 1.0f)
    let f2 = calculateForce(0.5f, attr = 1.0f, fMul = 1.0f, invD = 0.5f)

    check approxEq(f2, f1 * 0.5f, EPSILON_TIGHT)

  test "combined scaling":
    let fMul = 2.5f
    let invD = 0.1f
    let base = calculateForceMagnitude(0.5f, attr = 1.0f)
    let scaled = calculateForce(0.5f, attr = 1.0f, fMul = fMul, invD = invD)

    check approxEq(scaled, base * fMul * invD, EPSILON_TIGHT)


# ==============================================================================
# DISTANCE NORMALIZATION TESTS
# ==============================================================================

suite "Distance Normalization":
  test "normalizes distance to [0,1] range":
    let (r, invD, valid) = normalizeDistance(30.0f, 40.0f, rMax = 100.0f)
    # Distance is 50, normalized to 50/100 = 0.5

    check valid
    check approxEq(r, 0.5f, EPSILON_TIGHT)
    check approxEq(invD, 1.0f / 50.0f, EPSILON_TIGHT)

  test "rejects zero distance":
    let (r, invD, valid) = normalizeDistance(0.0f, 0.0f, rMax = 100.0f)

    check not valid

  test "rejects distance beyond rMax":
    let (r, invD, valid) = normalizeDistance(80.0f, 60.0f, rMax = 50.0f)
    # Distance is 100, which exceeds rMax=50

    check not valid

  test "accepts distance at boundary (just under rMax)":
    let (r, invD, valid) = normalizeDistance(49.0f, 0.0f, rMax = 50.0f)

    check valid
    check approxEq(r, 0.98f, EPSILON_TIGHT)

  test "clamps minimum distance":
    # Very close particles: distance would be 1.0, but minDistSq=4 clamps to 2.0
    let (r, invD, valid) = normalizeDistance(0.6f, 0.8f, rMax = 100.0f,
        minDistSq = 4.0f)
    # Actual distance: sqrt(0.36 + 0.64) = 1.0
    # Clamped distance: sqrt(4) = 2.0

    check valid
    check approxEq(r, 2.0f / 100.0f, EPSILON_TIGHT)
    check approxEq(invD, 0.5f, EPSILON_TIGHT)  # 1/2

  test "does not clamp when above minimum":
    let (r, invD, valid) = normalizeDistance(3.0f, 4.0f, rMax = 100.0f,
        minDistSq = 4.0f)
    # Distance is 5.0, which is above sqrt(4)=2

    check valid
    check approxEq(r, 0.05f, EPSILON_TIGHT)
    check approxEq(invD, 0.2f, EPSILON_TIGHT)


# ==============================================================================
# DENSITY ACCUMULATION TESTS
# ==============================================================================

suite "Density Accumulation":
  test "same species contributes (1 - r)":
    check approxEq(accumulateDensity(0.0f, sameSpecies = true), 1.0f,
        EPSILON_TIGHT)
    check approxEq(accumulateDensity(0.5f, sameSpecies = true), 0.5f,
        EPSILON_TIGHT)
    check approxEq(accumulateDensity(1.0f, sameSpecies = true), 0.0f,
        EPSILON_TIGHT)

  test "different species contributes zero":
    check approxEq(accumulateDensity(0.0f, sameSpecies = false), 0.0f,
        EPSILON_TIGHT)
    check approxEq(accumulateDensity(0.5f, sameSpecies = false), 0.0f,
        EPSILON_TIGHT)

  test "density is non-negative for valid r":
    for i in 0..10:
      let r = float32(i) / 10.0f
      let d = accumulateDensity(r, sameSpecies = true)
      check d >= 0.0f


# ==============================================================================
# TOROIDAL WRAPPING TESTS
# ==============================================================================

suite "Toroidal Wrapping (Delta)":
  test "no wrap when delta is small":
    let d = wrapDelta(10.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(d, 10.0f, EPSILON_TIGHT)

  test "wraps positive delta across boundary":
    # Delta of 80 on a 100-wide domain should wrap to -20
    let d = wrapDelta(80.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(d, -20.0f, EPSILON_TIGHT)

  test "wraps negative delta across boundary":
    # Delta of -80 on a 100-wide domain should wrap to +20
    let d = wrapDelta(-80.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(d, 20.0f, EPSILON_TIGHT)

  test "boundary case at exactly halfSize":
    # At exactly halfSize, no wrap (delta <= halfSize)
    let d = wrapDelta(50.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(d, 50.0f, EPSILON_TIGHT)

  test "wraps just over halfSize":
    let d = wrapDelta(50.1f, size = 100.0f, halfSize = 50.0f)
    check approxEq(d, -49.9f, EPSILON_TIGHT)


suite "Toroidal Wrapping (Position)":
  test "no wrap when in bounds":
    check approxEq(wrapPosition(50.0f, 100.0f), 50.0f, EPSILON_TIGHT)

  test "wraps negative position":
    check approxEq(wrapPosition(-10.0f, 100.0f), 90.0f, EPSILON_TIGHT)

  test "wraps position at upper bound":
    check approxEq(wrapPosition(100.0f, 100.0f), 0.0f, EPSILON_TIGHT)

  test "wraps position beyond upper bound":
    check approxEq(wrapPosition(110.0f, 100.0f), 10.0f, EPSILON_TIGHT)


# ==============================================================================
# CELL COORDINATE TESTS
# ==============================================================================

suite "Cell Coordinate Computation":
  test "maps position to correct cell":
    # 10x10 grid on 100x100 canvas, each cell is 10x10
    let (cx, cy) = computeCellCoords(25.0f, 35.0f, gridW = 10, gridH = 10,
        invCellW = 0.1f, invCellH = 0.1f)
    check cx == 2
    check cy == 3

  test "clamps negative positions to 0":
    let (cx, cy) = computeCellCoords(-10.0f, -5.0f, gridW = 10, gridH = 10,
        invCellW = 0.1f, invCellH = 0.1f)
    check cx == 0
    check cy == 0

  test "clamps positions beyond grid to max cell":
    let (cx, cy) = computeCellCoords(150.0f, 200.0f, gridW = 10, gridH = 10,
        invCellW = 0.1f, invCellH = 0.1f)
    check cx == 9
    check cy == 9

  test "boundary position at grid edge":
    # Position at exactly 99.9 should map to cell 9 (last cell)
    let (cx, cy) = computeCellCoords(99.9f, 99.9f, gridW = 10, gridH = 10,
        invCellW = 0.1f, invCellH = 0.1f)
    check cx == 9
    check cy == 9


suite "Cell Index Conversion":
  test "converts coordinates to linear index":
    check cellCoordsToIndex(0, 0, gridW = 10) == 0
    check cellCoordsToIndex(5, 0, gridW = 10) == 5
    check cellCoordsToIndex(0, 3, gridW = 10) == 30
    check cellCoordsToIndex(7, 4, gridW = 10) == 47


# ==============================================================================
# NEIGHBOR CELL TESTS
# ==============================================================================

suite "Neighbor Cell Computation":
  test "center neighbor (no offset)":
    let n = getNeighborCell(5, 5, dx = 0, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.nx == 5
    check n.ny == 5
    check n.cell == 55
    check approxEq(n.wrapX, 0.0f, EPSILON_TIGHT)
    check approxEq(n.wrapY, 0.0f, EPSILON_TIGHT)

  test "right neighbor":
    let n = getNeighborCell(5, 5, dx = 1, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.nx == 6
    check n.cell == 56

  test "wraps left edge to right":
    let n = getNeighborCell(0, 5, dx = -1, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.nx == 9
    check n.ny == 5
    check approxEq(n.wrapX, -100.0f, EPSILON_TIGHT)

  test "wraps right edge to left":
    let n = getNeighborCell(9, 5, dx = 1, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.nx == 0
    check approxEq(n.wrapX, 100.0f, EPSILON_TIGHT)

  test "wraps top edge to bottom":
    let n = getNeighborCell(5, 0, dx = 0, dy = -1, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.ny == 9
    check approxEq(n.wrapY, -100.0f, EPSILON_TIGHT)

  test "wraps bottom edge to top":
    let n = getNeighborCell(5, 9, dx = 0, dy = 1, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.ny == 0
    check approxEq(n.wrapY, 100.0f, EPSILON_TIGHT)

  test "corner wrap (top-left to bottom-right)":
    let n = getNeighborCell(0, 0, dx = -1, dy = -1, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check n.nx == 9
    check n.ny == 9
    check approxEq(n.wrapX, -100.0f, EPSILON_TIGHT)
    check approxEq(n.wrapY, -100.0f, EPSILON_TIGHT)
