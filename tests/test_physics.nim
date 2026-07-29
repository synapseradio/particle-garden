# ==============================================================================
# PARTICLE GARDEN - PHYSICS CORE TESTS
# ==============================================================================
#
# Unit tests for pure physics functions in physics_core.nim
#
# Run with: just test
#
# ==============================================================================

import std/math
import std/unittest
import ../src/physics_core
import ../src/config_ranges
import ../src/preset

# ==============================================================================
# TEST HELPERS
# ==============================================================================

const
  EPSILON_TIGHT* = 1e-5f   # For exact algorithm comparisons

proc approxEq(lhs, rhs: float32; epsilon: float32 = EPSILON_TIGHT): bool =
  ## Epsilon-based float comparison for testing.
  abs(lhs - rhs) <= epsilon

# ==============================================================================
# FORCE CALCULATION TESTS
# ==============================================================================

suite "Force Magnitude (unscaled)":
  test "repulsion at r=0 is -1":
    let force = calculateForceMagnitude(0.0f, attr = 1.0f)
    check approxEq(force, -1.0f, EPSILON_TIGHT)

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
    let force = calculateForceMagnitude(1.0f, attr = 1.0f)
    check approxEq(force, 0.0f, EPSILON_TIGHT)

  test "negative attraction inverts force":
    let fPos = calculateForceMagnitude(0.65f, attr = 1.0f)
    let fNeg = calculateForceMagnitude(0.65f, attr = -1.0f)

    check approxEq(fPos, -fNeg, EPSILON_TIGHT)

  test "zero attraction gives zero force in attraction zone":
    let force = calculateForceMagnitude(0.65f, attr = 0.0f)
    check approxEq(force, 0.0f, EPSILON_TIGHT)

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
# CROWDING ATTENUATION TESTS
# ==============================================================================
#
# The attenuation is 1 / (1 + strength * ln(1 + density)) and it multiplies the
# ATTRACTIVE contribution alone. These pin the three properties design C2 gets
# by construction rather than by tuning, plus the commutation with force
# strength design C0 requires: the term is a fraction of whatever attraction
# survives fMul, never an absolute force.

const
  CROWDING_DENSITIES = [0.0f, 0.5f, 1.0f, 5.0f, 20.0f, 100.0f, 400.0f]
  CROWDING_STRENGTHS = [0.0f, 0.25f, 1.0f, 2.0f]
  ATTRACTION_ZONE_DIST = 0.65f  ## Peak of the attraction envelope.
  REPULSION_ZONE_DIST = 0.15f   ## Inside the repulsion zone (r < 0.3).

suite "Crowding Attenuation":
  test "attenuation is identity at zero density":
    # log(1 + 0) = 0, so an isolated particle feels exactly today's force at
    # every strength. This is what makes the change provably invisible in a
    # sparse world.
    for strength in CROWDING_STRENGTHS:
      check approxEq(crowdingAttenuation(0.0f, strength), 1.0f, EPSILON_TIGHT)

  test "attenuation is monotone decreasing in density":
    # Crowding is never rewarded. At strength zero the curve is flat, which is
    # the same statement with the strength turned off.
    for strength in CROWDING_STRENGTHS:
      for densityIndex in 1 ..< CROWDING_DENSITIES.len:
        let looser = crowdingAttenuation(
          CROWDING_DENSITIES[densityIndex - 1], strength)
        let denser = crowdingAttenuation(
          CROWDING_DENSITIES[densityIndex], strength)
        check denser <= looser
        if strength > 0.0f:
          check denser < looser

  test "strength zero reproduces the unattenuated force exactly":
    # One number, and every regression under it is bisectable to that number.
    for density in CROWDING_DENSITIES:
      for attr in [-1.0f, -0.4f, 0.0f, 0.4f, 1.0f]:
        for normDist in [0.0f, REPULSION_ZONE_DIST, 0.3f,
            ATTRACTION_ZONE_DIST, 1.0f]:
          let plain = calculateForce(normDist, attr, fMul = 1.7f, invD = 0.2f)
          let attenuated = calculateAttenuatedForce(normDist, attr,
            fMul = 1.7f, invD = 0.2f, density = density, crowdingStrength = 0.0f)
          check approxEq(attenuated, plain, EPSILON_TIGHT)

  test "the attenuation commutes with force strength":
    # The attenuated force at fMul = k is k times the attenuated force at
    # fMul = 1, so the term means the same thing across the whole force-strength
    # range instead of drifting into an absolute force (design C0).
    for strength in CROWDING_STRENGTHS:
      for density in CROWDING_DENSITIES:
        for forceMultiplier in [0.0f, 0.5f, 1.0f, 5.0f]:
          let atOne = calculateAttenuatedForce(ATTRACTION_ZONE_DIST,
            attr = 0.8f, fMul = 1.0f, invD = 0.25f, density = density,
            crowdingStrength = strength)
          let atK = calculateAttenuatedForce(ATTRACTION_ZONE_DIST,
            attr = 0.8f, fMul = forceMultiplier, invD = 0.25f,
            density = density, crowdingStrength = strength)
          check approxEq(atK, forceMultiplier * atOne, EPSILON_TIGHT)

  test "repulsion survives the crowd":
    # Attenuating repulsion would partly cancel the cap it exists to serve
    # (design C1). The repulsion zone and every negative matrix entry keep
    # today's force at every density and every strength.
    for strength in CROWDING_STRENGTHS:
      for density in CROWDING_DENSITIES:
        let inRepulsionZone = calculateAttenuatedForce(REPULSION_ZONE_DIST,
          attr = 1.0f, fMul = 1.0f, invD = 1.0f, density = density,
          crowdingStrength = strength)
        check approxEq(inRepulsionZone,
          calculateForce(REPULSION_ZONE_DIST, attr = 1.0f, fMul = 1.0f,
            invD = 1.0f), EPSILON_TIGHT)
        let negativeEntry = calculateAttenuatedForce(ATTRACTION_ZONE_DIST,
          attr = -0.6f, fMul = 1.0f, invD = 1.0f, density = density,
          crowdingStrength = strength)
        check approxEq(negativeEntry,
          calculateForce(ATTRACTION_ZONE_DIST, attr = -0.6f, fMul = 1.0f,
            invD = 1.0f), EPSILON_TIGHT)

  test "attenuated attraction matches the closed form":
    # The oracle the WGSL mirrors, written out once so the shader has something
    # to be wrong against.
    for strength in CROWDING_STRENGTHS:
      for density in CROWDING_DENSITIES:
        let expected = calculateForce(ATTRACTION_ZONE_DIST, attr = 0.8f,
          fMul = 1.3f, invD = 0.5f) /
          (1.0f + strength * ln(1.0f + density))
        check approxEq(calculateAttenuatedForce(ATTRACTION_ZONE_DIST,
          attr = 0.8f, fMul = 1.3f, invD = 0.5f, density = density,
          crowdingStrength = strength), expected, EPSILON_TIGHT)


# ==============================================================================
# DENSITY CEILING TESTS
# ==============================================================================
#
# The performance argument rests on a ceiling EXISTING and being computable from
# the parameters, not on blobs having looked smaller. This sweep reads every
# bound from the constant that owns it — FORCE_STRENGTH_MIN/MAX from the range
# authority, MATRIX_VALUE_MIN/MAX from the preset schema, and the crowding range
# from the range authority — so a later recalibration re-scopes the sweep with no
# second edit here.

func sweepPoints(lowBound, highBound: float; count: int): seq[float] =
  ## `count` evenly spaced values across a closed range, endpoints included.
  for step in 0 ..< count:
    result.add lowBound +
      (highBound - lowBound) * float(step) / float(count - 1)

const
  SWEPT_MATRIX_VALUES = sweepPoints(MATRIX_VALUE_MIN, MATRIX_VALUE_MAX, 7)
  SWEPT_FORCE_STRENGTHS = sweepPoints(FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX, 5)
  SWEPT_CROWDING_STRENGTHS = sweepPoints(
    CROWDING_STRENGTH_MIN, CROWDING_STRENGTH_MAX, 6)

suite "The Density Ceiling":
  test "a density ceiling exists":
    for attr in SWEPT_MATRIX_VALUES:
      for forceStrength in SWEPT_FORCE_STRENGTHS:
        for crowding in SWEPT_CROWDING_STRENGTHS:
          if crowding == 0.0:
            continue  # today's force law caps nothing; the endpoint below
          let ceiling = densityCeiling(attr, forceStrength, crowding)
          checkpoint("attr " & $attr & " force " & $forceStrength &
            " crowding " & $crowding)
          check ceiling >= 0.0
          check classify(ceiling) notin {fcInf, fcNegInf, fcNan}

  test "the ceiling degenerates at force strength zero":
    # D13 puts zero inside the force-strength range and design C0 says what it
    # means: no force acts, so species attraction concentrates nothing at any
    # density. The bound on what attraction concentrates is therefore zero —
    # vacuous rather than wrong, and swept rather than excluded.
    for attr in SWEPT_MATRIX_VALUES:
      for crowding in SWEPT_CROWDING_STRENGTHS:
        check densityCeiling(attr, FORCE_STRENGTH_MIN, crowding) == 0.0

  test "the ceiling decreases monotonically in crowding strength":
    for attr in SWEPT_MATRIX_VALUES:
      for forceStrength in SWEPT_FORCE_STRENGTHS:
        for strengthIndex in 1 ..< SWEPT_CROWDING_STRENGTHS.len:
          let looser = densityCeiling(attr, forceStrength,
            SWEPT_CROWDING_STRENGTHS[strengthIndex - 1])
          let firmer = densityCeiling(attr, forceStrength,
            SWEPT_CROWDING_STRENGTHS[strengthIndex])
          checkpoint("attr " & $attr & " force " & $forceStrength)
          check firmer <= looser
          if forceStrength > 0.0 and attr > 0.0:
            check firmer < looser

  test "the ceiling is the same at every non-zero force strength":
    # Design C0: the attenuation is a fraction of the attraction that survives
    # fMul, never an absolute force. So force strength scales both sides of the
    # balance and cancels out of the ceiling entirely, and the cap means the
    # same thing across the whole force-strength range.
    for attr in SWEPT_MATRIX_VALUES:
      for crowding in SWEPT_CROWDING_STRENGTHS:
        let atMax = densityCeiling(attr, FORCE_STRENGTH_MAX, crowding)
        for forceStrength in SWEPT_FORCE_STRENGTHS:
          if forceStrength == 0.0:
            continue
          check densityCeiling(attr, forceStrength, crowding) == atMax


# ==============================================================================
# DISTANCE NORMALIZATION TESTS
# ==============================================================================

suite "Distance Normalization":
  test "normalizes distance to [0,1] range":
    let (normDist, invD, valid) = normalizeDistance(30.0f, 40.0f, rMax = 100.0f)
    # Distance is 50, normalized to 50/100 = 0.5

    check valid
    check approxEq(normDist, 0.5f, EPSILON_TIGHT)
    check approxEq(invD, 1.0f / 50.0f, EPSILON_TIGHT)

  test "rejects zero distance":
    let (normDist, invD, valid) = normalizeDistance(0.0f, 0.0f, rMax = 100.0f)

    check not valid

  test "rejects distance beyond rMax":
    let (normDist, invD, valid) = normalizeDistance(80.0f, 60.0f, rMax = 50.0f)
    # Distance is 100, which exceeds rMax=50

    check not valid

  test "accepts distance at boundary (just under rMax)":
    let (normDist, invD, valid) = normalizeDistance(49.0f, 0.0f, rMax = 50.0f)

    check valid
    check approxEq(normDist, 0.98f, EPSILON_TIGHT)

  test "clamps minimum distance":
    # Very close particles: distance would be 1.0, but minDistSq=4 clamps to 2.0
    let (normDist, invD, valid) = normalizeDistance(0.6f, 0.8f, rMax = 100.0f,
        minDistSq = 4.0f)
    # Actual distance: sqrt(0.36 + 0.64) = 1.0
    # Clamped distance: sqrt(4) = 2.0

    check valid
    check approxEq(normDist, 2.0f / 100.0f, EPSILON_TIGHT)
    check approxEq(invD, 0.5f, EPSILON_TIGHT)  # 1/2

  test "does not clamp when above minimum":
    let (normDist, invD, valid) = normalizeDistance(3.0f, 4.0f, rMax = 100.0f,
        minDistSq = 4.0f)
    # Distance is 5.0, which is above sqrt(4)=2

    check valid
    check approxEq(normDist, 0.05f, EPSILON_TIGHT)
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
    for idx in 0..10:
      let normDist = float32(idx) / 10.0f
      let density = accumulateDensity(normDist, sameSpecies = true)
      check density >= 0.0f


# ==============================================================================
# TOROIDAL WRAPPING TESTS
# ==============================================================================

suite "Toroidal Wrapping (Delta)":
  test "no wrap when delta is small":
    let delta = wrapDelta(10.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, 10.0f, EPSILON_TIGHT)

  test "wraps positive delta across boundary":
    # Delta of 80 on a 100-wide domain should wrap to -20
    let delta = wrapDelta(80.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, -20.0f, EPSILON_TIGHT)

  test "wraps negative delta across boundary":
    # Delta of -80 on a 100-wide domain should wrap to +20
    let delta = wrapDelta(-80.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, 20.0f, EPSILON_TIGHT)

  test "boundary case at exactly halfSize":
    # At exactly halfSize, no wrap (delta <= halfSize)
    let delta = wrapDelta(50.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, 50.0f, EPSILON_TIGHT)

  test "wraps just over halfSize":
    let delta = wrapDelta(50.1f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, -49.9f, EPSILON_TIGHT)


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
    let neighbor = getNeighborCell(5, 5, dx = 0, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.nx == 5
    check neighbor.ny == 5
    check neighbor.cell == 55
    check approxEq(neighbor.wrapX, 0.0f, EPSILON_TIGHT)
    check approxEq(neighbor.wrapY, 0.0f, EPSILON_TIGHT)

  test "right neighbor":
    let neighbor = getNeighborCell(5, 5, dx = 1, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.nx == 6
    check neighbor.cell == 56

  test "wraps left edge to right":
    let neighbor = getNeighborCell(0, 5, dx = -1, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.nx == 9
    check neighbor.ny == 5
    check approxEq(neighbor.wrapX, -100.0f, EPSILON_TIGHT)

  test "wraps right edge to left":
    let neighbor = getNeighborCell(9, 5, dx = 1, dy = 0, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.nx == 0
    check approxEq(neighbor.wrapX, 100.0f, EPSILON_TIGHT)

  test "wraps top edge to bottom":
    let neighbor = getNeighborCell(5, 0, dx = 0, dy = -1, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.ny == 9
    check approxEq(neighbor.wrapY, -100.0f, EPSILON_TIGHT)

  test "wraps bottom edge to top":
    let neighbor = getNeighborCell(5, 9, dx = 0, dy = 1, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.ny == 0
    check approxEq(neighbor.wrapY, 100.0f, EPSILON_TIGHT)

  test "corner wrap (top-left to bottom-right)":
    let neighbor = getNeighborCell(0, 0, dx = -1, dy = -1, gridW = 10, gridH = 10,
        canvasW = 100.0f, canvasH = 100.0f)
    check neighbor.nx == 9
    check neighbor.ny == 9
    check approxEq(neighbor.wrapX, -100.0f, EPSILON_TIGHT)
    check approxEq(neighbor.wrapY, -100.0f, EPSILON_TIGHT)


suite "Neighbor Cell Index Validity":
  # getNeighborCell feeds a buffer index (cell = ny*gridW + nx). If wrapping ever
  # produced an out-of-range cell, the forces pass would read or write outside the
  # grid buffer. This sweeps every cell and every neighbor offset to prove the
  # returned index always lands inside [0, gridW*gridH).
  test "getNeighborCell returns an in-range cell for every offset at every cell":
    const gridW = 10
    const gridH = 10
    for cy in 0 ..< gridH:
      for cx in 0 ..< gridW:
        for dy in [-1, 0, 1]:
          for dx in [-1, 0, 1]:
            let neighbor = getNeighborCell(cx, cy, dx, dy, gridW, gridH,
                canvasW = 100.0f, canvasH = 100.0f)
            check neighbor.nx >= 0
            check neighbor.nx < gridW
            check neighbor.ny >= 0
            check neighbor.ny < gridH
            check neighbor.cell >= 0
            check neighbor.cell < gridW * gridH
            check neighbor.cell == neighbor.ny * gridW + neighbor.nx

suite "Configurable Force Curve Mirror":
  # forces.wgsl's shipped force law: MODEL 0 (polynomial) is a Hermite
  # repulsion over [0, repulsionEnd] and a squared-bump attraction over
  # [repulsionEnd, 1] peaking at attractionPeak; MODEL 1 (exponential) is
  # -exp(-alpha r) + attr * exp(-beta r) * 2. Crowding attenuation multiplies
  # only a POSITIVE attraction's contribution, in both models. These pin the
  # mirror to the shader block, coordinates written against the shipped
  # defaults (repulsionEnd 0.5, attractionPeak 0.65 — src/preset.nim).

  const RepEnd = 0.5'f32
  const AttPeak = 0.65'f32

  test "repulsion is a Hermite ramp from -1 at contact to 0 at the zone end":
    check polynomialForce(0.0'f32, 1.0'f32, RepEnd, AttPeak, 1.0'f32) == -1.0'f32
    # t = 0.5 gives -1 + 3/4 - 1/4 = -0.5 exactly.
    check abs(polynomialForce(RepEnd * 0.5'f32, 1.0'f32, RepEnd, AttPeak,
      1.0'f32) - (-0.5'f32)) < 1e-6
    check abs(polynomialForce(RepEnd, 1.0'f32, RepEnd, AttPeak,
      1.0'f32)) < 1e-6

  test "attraction bumps to attr * 4 exactly at the peak and dies at both ends":
    check abs(polynomialForce(AttPeak, 1.0'f32, RepEnd, AttPeak, 1.0'f32) -
      4.0'f32) < 1e-6
    check abs(polynomialForce(0.999'f32, 1.0'f32, RepEnd, AttPeak,
      1.0'f32)) < 0.01'f32

  test "crowding attenuates a positive attraction and nothing else":
    let full = polynomialForce(AttPeak, 1.0'f32, RepEnd, AttPeak, 1.0'f32)
    let dimmed = polynomialForce(AttPeak, 1.0'f32, RepEnd, AttPeak, 0.5'f32)
    check abs(dimmed - full * 0.5'f32) < 1e-6
    # A negative matrix entry in the attraction zone pushes apart; the shader
    # never dampens it (select on attraction > 0).
    check polynomialForce(AttPeak, -1.0'f32, RepEnd, AttPeak, 0.5'f32) ==
      polynomialForce(AttPeak, -1.0'f32, RepEnd, AttPeak, 1.0'f32)
    # Repulsion-zone force ignores attenuation entirely.
    check polynomialForce(0.2'f32, 1.0'f32, RepEnd, AttPeak, 0.5'f32) ==
      polynomialForce(0.2'f32, 1.0'f32, RepEnd, AttPeak, 1.0'f32)

  test "the exponential model separates its two decays":
    # attraction 0 isolates the repulsion decay.
    check abs(exponentialForce(0.3'f32, 0.0'f32, 5.0'f32, 2.0'f32, 1.0'f32) -
      (-exp(-5.0'f32 * 0.3'f32))) < 1e-6
    # The attraction term adds attr * exp(-beta r) * 2, attenuated.
    let base = exponentialForce(0.3'f32, 0.0'f32, 5.0'f32, 2.0'f32, 1.0'f32)
    let withAttr = exponentialForce(0.3'f32, 1.0'f32, 5.0'f32, 2.0'f32,
      0.5'f32)
    check abs(withAttr - base -
      exp(-2.0'f32 * 0.3'f32) * 2.0'f32 * 0.5'f32) < 1e-6

suite "Post-Step Speed Mirror":
  # integrate.wgsl:120-137: velocity times friction, then a logarithmic soft
  # cap that starts at half maxVelocity and hard-caps at maxVelocity.

  test "below the soft-cap threshold only friction acts":
    check abs(postStepSpeed(10.0'f32, 0.9'f32, 60.0'f32) - 9.0'f32) < 1e-6

  test "above the threshold the excess is compressed logarithmically":
    # damped = 40, threshold = 30, excess = 10 -> 30 + ln(11).
    check abs(postStepSpeed(40.0'f32, 1.0'f32, 60.0'f32) -
      (30.0'f32 + ln(11.0'f32))) < 1e-5

  test "no speed escapes the hard cap":
    check postStepSpeed(1.0e6'f32, 1.0'f32, 60.0'f32) <= 60.0'f32
