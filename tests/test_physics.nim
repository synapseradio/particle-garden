import std/math
import std/random
import std/sequtils
import std/unittest
import ../src/physics_core
import ../src/sph_core
import ../src/field_core
import ../src/body_core
import ../src/shader_config
import ../src/config_ranges
import ../src/preset
from ../src/memory_layout import MAX_PARTICLES, MAX_BODIES
from ../src/balance_core import UnitConfig, unitImpulse, ufLongRange, u0

const
  EPSILON_TIGHT* = 1e-5f

proc approxEq(lhs, rhs: float32; epsilon: float32 = EPSILON_TIGHT): bool =
  abs(lhs - rhs) <= epsilon

suite "Force Magnitude (unscaled)":
  test "repulsion at r=0 is -1":
    let force = calculateForceMagnitude(0.0f, attr = 1.0f)
    check approxEq(force, -1.0f, EPSILON_TIGHT)

  test "repulsion decreases linearly to 0 at r=0.3":
    let f0 = calculateForceMagnitude(0.0f, attr = 1.0f)
    let f015 = calculateForceMagnitude(0.15f, attr = 1.0f)
    let f03 = calculateForceMagnitude(0.3f, attr = 1.0f)

    check f0 < f015
    check f015 < f03
    check approxEq(f03, 0.0f, EPSILON_TIGHT)

  test "attraction peak near r=0.65":
    # The force curve peaks where |2r - 1.3| = 0, i.e., r = 0.65
    let fPeak = calculateForceMagnitude(0.65f, attr = 1.0f)
    let fBefore = calculateForceMagnitude(0.5f, attr = 1.0f)
    let fAfter = calculateForceMagnitude(0.8f, attr = 1.0f)

    check approxEq(fPeak, 1.0f, EPSILON_TIGHT)
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


# The attenuation is 1 / (1 + strength * ln(1 + density)) and it multiplies the
# ATTRACTIVE contribution alone. These pin the three properties it gets by
# construction rather than by tuning, plus the commutation with force
# strength it requires: the term is a fraction of whatever attraction
# survives fMul, never an absolute force.

const
  CROWDING_DENSITIES = [0.0f, 0.5f, 1.0f, 5.0f, 20.0f, 100.0f, 400.0f]
  CROWDING_STRENGTHS = [0.0f, 0.25f, 1.0f, 2.0f]
  ATTRACTION_ZONE_DIST = 0.65f  ## Peak of the attraction envelope.
  REPULSION_ZONE_DIST = 0.15f   ## Inside the repulsion zone (r < 0.3).

suite "Crowding Attenuation":
  test "attenuation is identity at zero density":
    # log(1 + 0) = 0, so an isolated particle's force is unaffected by
    # crowding strength — the attenuation is invisible in a sparse world.
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
    # range instead of drifting into an absolute force.
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
    # Attenuating repulsion would partly cancel the cap it exists to serve.
    # The repulsion zone and every negative matrix entry keep the same force
    # at every density and every strength.
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


# The performance argument rests on a ceiling EXISTING and being computable from
# the parameters, not on blobs having looked smaller. This sweep reads every
# bound from the constant that owns it — FORCE_STRENGTH_MIN/MAX from the range
# authority, MATRIX_MIN_VALUE/MAX_VALUE and the crowding range from the range
# authority — so a later recalibration re-scopes the sweep with no second edit
# here.

func sweepPoints(lowBound, highBound: float; count: int): seq[float] =
  ## `count` evenly spaced values across a closed range, endpoints included.
  for step in 0 ..< count:
    result.add lowBound +
      (highBound - lowBound) * float(step) / float(count - 1)

const
  SWEPT_MATRIX_VALUES = sweepPoints(MATRIX_MIN_VALUE, MATRIX_MAX_VALUE, 7)
  SWEPT_FORCE_STRENGTHS = sweepPoints(FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX, 5)
  SWEPT_CROWDING_STRENGTHS = sweepPoints(
    CROWDING_STRENGTH_MIN, CROWDING_STRENGTH_MAX, 6)

suite "Distance Normalization":
  test "normalizes distance to [0,1] range":
    let (normDist, invD, valid) = normalizeDistance(30.0f, 40.0f, rMax = 100.0f)

    check valid
    check approxEq(normDist, 0.5f, EPSILON_TIGHT)
    check approxEq(invD, 1.0f / 50.0f, EPSILON_TIGHT)

  test "rejects zero distance":
    let (normDist, invD, valid) = normalizeDistance(0.0f, 0.0f, rMax = 100.0f)

    check not valid

  test "rejects distance beyond rMax":
    let (normDist, invD, valid) = normalizeDistance(80.0f, 60.0f, rMax = 50.0f)

    check not valid

  test "accepts distance at boundary (just under rMax)":
    let (normDist, invD, valid) = normalizeDistance(49.0f, 0.0f, rMax = 50.0f)

    check valid
    check approxEq(normDist, 0.98f, EPSILON_TIGHT)

  test "clamps minimum distance":
    let (normDist, invD, valid) = normalizeDistance(0.6f, 0.8f, rMax = 100.0f,
        minDistSq = 4.0f)

    check valid
    check approxEq(normDist, 2.0f / 100.0f, EPSILON_TIGHT)
    check approxEq(invD, 0.5f, EPSILON_TIGHT)

  test "does not clamp when above minimum":
    let (normDist, invD, valid) = normalizeDistance(3.0f, 4.0f, rMax = 100.0f,
        minDistSq = 4.0f)

    check valid
    check approxEq(normDist, 0.05f, EPSILON_TIGHT)
    check approxEq(invD, 0.2f, EPSILON_TIGHT)


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


suite "Toroidal Wrapping (Delta)":
  test "no wrap when delta is small":
    let delta = wrapDelta(10.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, 10.0f, EPSILON_TIGHT)

  test "wraps positive delta across boundary":
    let delta = wrapDelta(80.0f, size = 100.0f, halfSize = 50.0f)
    check approxEq(delta, -20.0f, EPSILON_TIGHT)

  test "wraps negative delta across boundary":
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


suite "Cell Coordinate Computation":
  test "maps position to correct cell":
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
  # integrate.wgsl: velocity times friction, then a logarithmic soft
  # cap that starts at half maxVelocity and hard-caps at maxVelocity.

  test "below the soft-cap threshold only friction acts":
    check abs(postStepSpeed(10.0'f32, 0.9'f32, 60.0'f32) - 9.0'f32) < 1e-6

  test "above the threshold the excess is compressed logarithmically":
    # damped = 40, threshold = 30, excess = 10 -> 30 + ln(11).
    check abs(postStepSpeed(40.0'f32, 1.0'f32, 60.0'f32) -
      (30.0'f32 + ln(11.0'f32))) < 1e-5

  test "no speed escapes the hard cap":
    check postStepSpeed(1.0e6'f32, 1.0'f32, 60.0'f32) <= 60.0'f32

  test "integrate adds the decoded word to the velocity before friction and the soft cap":
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    let word = (x: int32(2 * 65536), y: int32(1 * 65536))
    for maxVelocity in [6.0'f32, 100.0'f32]:
      let stepped = integrateVelocity((x: 3.0'f32, y: -4.0'f32), word,
        invScale, stepClock(1.0'f32, 0.9'f32), 1.0'f32, maxVelocity)
      # The decoded word is (2, 1), so friction and the cap act on (5, -3).
      let expectedSpeed = postStepSpeed(sqrt(34.0'f32), 0.9'f32, maxVelocity)
      check abs(hypot(stepped.x, stepped.y) - expectedSpeed) < 1e-5
      check abs(stepped.x * -3.0'f32 - stepped.y * 5.0'f32) < 1e-5

  test "the cap acts on speed alone, not on speed divided by ff_sub, at ff_sub one":
    # Bit-identical to postStepSpeed's own flat cap at ff_sub = 1: the D1
    # clock's forceGain equals ff there, so this stays a guard rather than a
    # red.
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    let maxVelocity = 60.0'f32
    let friction = 0.9'f32
    let word = (x: int32(40 * 65536), y: int32(0))
    let stepped = integrateVelocity((x: 0.0'f32, y: 0.0'f32), word,
      invScale, stepClock(1.0'f32, friction), 1.0'f32, maxVelocity)
    let expected = postStepSpeed(40.0'f32, friction, maxVelocity)
    check abs(hypot(stepped.x, stepped.y) - expected) < 1e-5'f32

suite "Friction Acts Per Reference Frame":

  test "ten steps at ff 1 and one step at ff 10 lose the same fraction of speed":
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    let friction = 0.9'f32
    # Far past the soft-cap threshold, so the cap curve never acts.
    let maxVelocity = 1.0e6'f32
    let zeroWord = (x: 0'i32, y: 0'i32)
    var tenSteps = (x: 10.0'f32, y: 0.0'f32)
    for _ in 0 ..< 10:
      tenSteps = integrateVelocity(tenSteps, zeroWord, invScale,
        stepClock(1.0'f32, friction), 1.0'f32, maxVelocity)
    let oneStep = integrateVelocity((x: 10.0'f32, y: 0.0'f32), zeroWord,
      invScale, stepClock(10.0'f32, friction), 1.0'f32, maxVelocity)
    checkpoint "ten steps at ff 1: " & $tenSteps.x & ", one step at ff 10: " &
      $oneStep.x
    check abs(tenSteps.x - oneStep.x) < 1e-4'f32

suite "Frame Reference":
  # frameFactor turns a substep's dt into a multiple of the frame the shipped
  # constants were measured at; integrate.wgsl multiplies the decoded
  # per-reference-frame delta by it.

  test "frameFactor returns 1 at the reference frame":
    check abs(frameFactor(FRAME_DT_REFERENCE) - 1.0) < 1e-12

  test "frameFactor scales linearly with dt":
    check abs(frameFactor(2.0 * FRAME_DT_REFERENCE) - 2.0) < 1e-12
    check abs(frameFactor(0.25 * FRAME_DT_REFERENCE) - 0.25) < 1e-12

  test "a frame split into substeps carries the same factor in total":
    # What makes integrate's multiply safe inside the substep loop: n
    # substeps of dt/n must deliver what one step of dt delivers.
    for substeps in [1, 2, 3, 5, 8]:
      let dt = 3.7 * FRAME_DT_REFERENCE
      check abs(frameFactor(dt / substeps.float) * substeps.float -
        frameFactor(dt)) < 1e-12

  test "frameFactor is zero at a stopped clock":
    check frameFactor(0.0) == 0.0

template checkNoVerdicts(verdicts: seq[string]) =
  for message in verdicts[0 ..< min(verdicts.len, 4)]:
    checkpoint message
  check verdicts.len == 0

# Today's convention, kept test-local so the guard below compares the
# per-reference-frame words against it after src/ moves on: each writer's
# own time factor applied in the encode, and integrate's decode without one.
func todayForcesWord(force, dt, fixedPointScale: float32): int32 =
  int32(force * dt * fixedPointScale)

func todaySphPairDelta(pressure, pressureDensity, gradientWeight,
    densityWeight, laggedDensity, viscosity, dt: float;
    direction, velocityDiff: tuple[x, y: float]): float =
  let pairPressure = 2.0 * pressure / (pressureDensity * pressureDensity)
  let pressureAccel = clamp(SPH_FORCE_SCALE * pairPressure * gradientWeight,
    -SPH_MAX_PRESSURE_ACCEL, SPH_MAX_PRESSURE_ACCEL)
  let smoothCoefficient = (viscosity + SPH_XSPH_EPSILON) * densityWeight /
    max(laggedDensity, 1.0)
  (-pressureAccel * direction.x) * dt +
    smoothCoefficient * velocityDiff.x * (dt / FRAME_DT_REFERENCE)

func todayDecode(word: int32; invFixedPointScale: float32): float32 =
  float32(word) * invFixedPointScale

suite "Today's Low Bits Move By Less Than The Frame Factor":
  # coupling-contract: moving each writer's time factor into integrate's
  # decode changes where truncation happens. Encoding x per reference frame
  # and multiplying by ff at the decode, against encoding ff * x, differs by
  # |e2 - ff * e1| for two truncation remainders in [0, 1): fewer than
  # max(1, ff) quanta, and nothing at ff 1.
  const FRAME_FACTORS = [1.0, 2.0, 30.0]
  let fixedScale = PRODUCTION_TUNING.fixedPointScale.float32
  let invScale = 1.0'f32 / fixedScale

  proc judgeLowBits(verdicts: var seq[string]; label: string;
      perReferenceWord: int32; todayWord: int32; factor: float) =
    let moved = abs(decodeVelocityDelta(perReferenceWord, invScale,
      factor.float32).float -
      todayDecode(todayWord, invScale).float) * fixedScale.float
    let bound = max(1.0, factor)
    if not (moved < bound) or (factor == 1.0 and moved != 0.0):
      verdicts.add label & " at frame factor " & $factor & ": the decode moved " &
        $moved & " quanta, the bound is fewer than " & $bound

  test "the pair, mouse and blast words move by less than the frame factor":
    let pointer = mouseForce(100.0'f32, 0.0'f32, 300.0'f32, 1.0'f32)
    let blast = blastForce(10.0'f32, 0.0'f32, 1.0'f32, 200.0'f32)
    var verdicts: seq[string]
    for (label, force) in [("pair", 37.7'f32), ("repelling pair", -61.3'f32),
        ("mouse", pointer.x), ("blast", blast.x)]:
      for factor in FRAME_FACTORS:
        verdicts.judgeLowBits(label, forcesVelocityDeltaFixed(force,
          fixedScale), todayForcesWord(force,
          (factor * FRAME_DT_REFERENCE).float32, fixedScale), factor)
    checkNoVerdicts(verdicts)

  test "the fluid pair word moves by less than the frame factor":
    let pressure = flooredTaitPressure(1.5, 1.0, 10.0, SPH_DEFAULT_GAMMA)
    var verdicts: seq[string]
    for (label, gradientWeight, velocityDiff) in [
        ("pressure alone", 0.8, (x: 0.0, y: 0.0)),
        ("blend alone", 0.0, (x: 3.0, y: -2.0)),
        ("pressure and blend", 0.8, (x: 3.0, y: -2.0))]:
      let perReference = sphPairVelocityDelta(pressure, 1.5, pressure, 1.5,
        gradientWeight, 0.6, 1.5, 1.5, 0.3, 1.0, (x: 0.6, y: 0.8),
        velocityDiff)
      for factor in FRAME_FACTORS:
        let today = todaySphPairDelta(pressure, 1.5, gradientWeight, 0.6, 1.5,
          0.3, factor * FRAME_DT_REFERENCE, (x: 0.6, y: 0.8), velocityDiff)
        verdicts.judgeLowBits(label,
          encodeVelocityDelta(perReference.x.float32, fixedScale),
          encodeVelocityDelta(today.float32, fixedScale), factor)
    checkNoVerdicts(verdicts)

  test "the scent, long-range and bodies words move by less than the frame factor":
    let body = Body(centerX: 1000.0, centerY: 800.0, radius: 200.0,
      anisotropy: 1.0, bandWidth: 120.0, proximity: 4.0, enclosure: 5.0)
    var verdicts: seq[string]
    for factor in FRAME_FACTORS:
      for gradient in [0.05, -0.0868]:
        let perReference = speciesTropismForce(gradient, 7.5, -1.0)
        let today = speciesTropismForce(gradient, 7.5 * factor, -1.0)
        verdicts.judgeLowBits("scent gradient " & $gradient,
          encodeVelocityDelta(perReference.float32, fixedScale),
          encodeVelocityDelta(today.float32, fixedScale), factor)
      for gradient in [0.02, -0.37]:
        verdicts.judgeLowBits("long range gradient " & $gradient,
          encodeVelocityDelta(gradient.float32 * 0.5'f32, fixedScale),
          encodeVelocityDelta(gradient.float32 * (0.5 * factor).float32,
            fixedScale), factor)
      for atX in [1250.0, 1320.0, 1150.0]:
        let perReference = bodyForceAt(body, atX, 800.0, BODY_WORLD_W,
          BODY_WORLD_H, 0.8, 0.7)
        let today = bodyForceAt(body, atX, 800.0, BODY_WORLD_W, BODY_WORLD_H,
          0.8, 0.7 * factor)
        verdicts.judgeLowBits("body at x " & $atX,
          encodeVelocityDelta(perReference.x.float32, fixedScale),
          encodeVelocityDelta(today.x.float32, fixedScale), factor)
    checkNoVerdicts(verdicts)

suite "A Full Crowd Decodes To Its Impulse":
  # WGSL i32 atomics wrap (https://www.w3.org/TR/WGSL/#atomic-rmw), so a
  # particle's words must hold what MAX_PARTICLES neighbours and every other
  # writer add at their maxima. Each crowd is encoded through its writer's
  # oracle, summed with wrapping adds, and decoded through integrate's oracle;
  # the decode must equal the crowd's impulse times the frame factor, to one
  # quantum per add. Both signs run, since the coarse split rounds toward
  # negative infinity.
  const FRAME_FACTORS = [1.0, 2.0, 30.0]
  const SIGNS = [1.0, -1.0]
  const ONSET_RATIO = CROWD_ONSET_RATIO
    ## The onset the colony radius is read at, the same ratio the world
    ## pressure starts at.
  let fixedScale = PRODUCTION_TUNING.fixedPointScale.float32
  let invScale = 1.0'f32 / fixedScale

  func speciesPair(sign: float): float32 =
    ## The pair at contact under the widest matrix entry, forces.wgsl's
    ## exponential model at the strength ceiling.
    (sign * FORCE_STRENGTH_MAX * (1.0 + 2.0 * MATRIX_MAX_VALUE)).float32

  func fluidPair(sign: float): float =
    ## One fluid pair at its maxima: the pressure clamp along the pair and the
    ## widest velocity gap under the viscosity ceiling, at the gain ceiling.
    sphPairVelocityDelta(1.0e6, 1.0, 1.0e6, 1.0, 1.0, 1.0, 1.0, 1.0,
      SPH_VISCOSITY_MAX, FLUID_STRENGTH_MAX, (x: -sign, y: 0.0),
      (x: sign * 2.0 * MAX_VELOCITY_MAX, y: 0.0)).x

  proc longRangeMax(): float =
    for radius in [INTERACTION_RADIUS_MIN.float, INTERACTION_RADIUS_MAX.float]:
      result = max(result, unitImpulse(ufLongRange, UnitConfig(
        particleCount: MAX_PARTICLES, interactionRadius: radius,
        worldWidth: BODY_WORLD_W, worldHeight: BODY_WORLD_H,
        onsetRatio: ONSET_RATIO, attraction: MATRIX_MAX_VALUE,
        longRangeStrength: LONG_RANGE_STRENGTH_MAX)) * u0)

  proc judge(verdicts: var seq[string]; label: string; words: VelocityWords;
      impulse: float; adds: int) =
    for factor in FRAME_FACTORS:
      let decoded = decodeVelocityWords(words, invScale, factor.float32,
        VELOCITY_COARSE_SHIFT).float
      let expected = impulse * factor
      let tolerance = adds.float * factor / fixedScale.float +
        1.0e-6 * abs(expected)
      if not (abs(decoded - expected) <= tolerance):
        verdicts.add label & " at frame factor " & $factor & ": decoded " &
          $decoded & ", the crowd's impulse is " & $expected

  test "a full fluid crowd's per-pair adds decode to its impulse":
    var verdicts: seq[string]
    for sign in SIGNS:
      let pair = fluidPair(sign)
      let pairWords = splitVelocityWord(encodeVelocityDelta(pair.float32,
        fixedScale), VELOCITY_COARSE_SHIFT)
      var words: VelocityWords
      for _ in 0 ..< MAX_PARTICLES:
        words = addVelocityWords(words, pairWords)
      verdicts.judge("fluid crowd, sign " & $sign, words,
        pair.float32.float * MAX_PARTICLES.float, MAX_PARTICLES)
    checkNoVerdicts(verdicts)

  test "a particle's own fluid register splits once into both words":
    var verdicts: seq[string]
    for sign in SIGNS:
      let register = fluidPair(sign).float32 * MAX_PARTICLES.float32
      let words = splitVelocitySum(register, fixedScale, VELOCITY_COARSE_SHIFT)
      verdicts.judge("fluid register, sign " & $sign, words, register.float, 1)
    checkNoVerdicts(verdicts)

  test "every writer at its maxima at once decodes to the summed impulse":
    let longRange = longRangeMax()
    var verdicts: seq[string]
    for sign in SIGNS:
      var words: VelocityWords
      var impulse = 0.0
      var adds = 0
      let speciesWord = forcesVelocityDeltaFixed(speciesPair(sign), fixedScale)
      let fluidWords = splitVelocityWord(encodeVelocityDelta(
        fluidPair(sign).float32, fixedScale), VELOCITY_COARSE_SHIFT)
      for _ in 0 ..< MAX_PARTICLES:
        words = addVelocityWords(words, (fine: speciesWord, coarse: 0'i32))
        words = addVelocityWords(words, fluidWords)
      impulse += MAX_PARTICLES.float * ((speciesPair(sign) *
        FRAME_DT_REFERENCE.float32).float + fluidPair(sign).float32.float)
      adds += 2 * MAX_PARTICLES
      let pointer = mouseForce(1.0e-3'f32, 0.0'f32, 300.0'f32, sign.float32)
      let blast = blastForce(sign.float32 * 10.0'f32, 0.0'f32, 1.0'f32,
        200.0'f32)
      for single in [pointer.x * FRAME_DT_REFERENCE.float32,
          blast.x * FRAME_DT_REFERENCE.float32,
          (sign * MAX_BODIES.float * BODY_MAX_FORCE_PER_PARTICLE).float32,
          (sign * speciesTropismForce(0.5, RD_FIELD_FORCE_MAX,
            TROPISM_MIN)).float32,
          (sign * longRange).float32]:
        words = addVelocityWords(words,
          (fine: encodeVelocityDelta(single, fixedScale), coarse: 0'i32))
        impulse += single.float
        inc adds
      verdicts.judge("every writer, sign " & $sign, words, impulse, adds)
    checkNoVerdicts(verdicts)

  test "a full crowd decodes to its impulse times the step limit when D > 0 (T8)":
    let ff = 2.0'f32
    let bound = PRESSURE_STEP_BOUND.float32
    let trueSlope = 100.0'f32
    let expectedS = bound / (2.0'f32 * ff * trueSlope)
    let stiffnessWords = splitVelocityWord(encodeStiffness(trueSlope,
      STIFFNESS_FIXED_POINT_SCALE.float32), STIFFNESS_COARSE_SHIFT)
    let decodedD = decodeStiffness(stiffnessWords,
      1.0'f32 / STIFFNESS_FIXED_POINT_SCALE.float32, STIFFNESS_COARSE_SHIFT)
    let s = stepLimit(ff, decodedD, bound)
    let pairWord = forcesVelocityDeltaFixed(speciesPair(1.0), fixedScale)
    var words: VelocityWords
    for _ in 0 ..< MAX_PARTICLES:
      words = addVelocityWords(words, (fine: pairWord, coarse: 0'i32))
    let decoded = decodeVelocityWords(words, invScale, ff,
      VELOCITY_COARSE_SHIFT).float * s.float
    let impulse = MAX_PARTICLES.float *
      (speciesPair(1.0) * FRAME_DT_REFERENCE.float32).float
    let expected = impulse * ff.float * expectedS.float
    let tolerance = MAX_PARTICLES.float * ff.float / fixedScale.float +
      1.0e-6 * abs(expected)
    check abs(decoded - expected) <= tolerance

# ==============================================================================
# THE WORLD PRESSURE
# ==============================================================================
# A pair's repulsive impulse per reference frame is the stiffness times the sum
# of both particles' pressures, times the proximity weight 1 - r/R, over 120,
# saturating at q_max, quantized once per component and exchanged. A particle's
# pressure is (max(rho - rho_on, 0) / rho_on)^2 over its smoothed crowd
# density. Nothing a player moves enters that expression.

const
  PRESSURE_ONSETS = [3.804, 40.0, 254.4]
    ## Three onsets the live world reaches: the contact floor at the preset
    ## rest spacing of 0.5, a middling world's, and a 128 000-particle world's
    ## at the shipped radius.
  PRESSURE_RADIUS = 50.0'f32
  PRESSURE_SEPARATIONS = [(3.0'f32, 4.0'f32), (-12.0'f32, 5.0'f32),
    (30.0'f32, 0.0'f32), (0.0'f32, -18.0'f32), (-9.0'f32, -9.0'f32)]
  BELOW_ONSET_RATIOS = [0.0, 0.25, 0.5, 0.9, 1.0]
  PAST_ONSET_RATIOS = [1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 9.5, 12.0, 20.0, 30.0]
    ## Past 9.86 times the onset the pressure sum saturates at q_max, so this
    ## sweep covers the rise and the saturated-sum tail at once.

let pressureScale = PRODUCTION_TUNING.fixedPointScale.float32
let invPressureScale = 1.0'f32 / pressureScale

func pressureParams(onset, forceMultiplier: float): PairImpulseParams =
  PairImpulseParams(forceMultiplier: forceMultiplier.float32,
    pressureOnset: onset.float32,
    pressureStiffness: WORLD_PRESSURE_STIFFNESS.float32,
    pressureImpulseMax: WORLD_PRESSURE_IMPULSE_MAX.float32,
    fixedPointScale: PRODUCTION_TUNING.fixedPointScale.float32)

func pairGeometry(separation: (float32, float32)):
    tuple[invDistance, normalizedDistance: float32] =
  let distance = sqrt(separation[0] * separation[0] +
    separation[1] * separation[1])
  (invDistance: 1.0'f32 / distance,
   normalizedDistance: distance / PRESSURE_RADIUS)

func pairAt(params: PairImpulseParams; separation: (float32, float32);
    densityThis, densityOther: float; speciesMagnitude: float32 = 0.0'f32):
    PairImpulse =
  let geometry = pairGeometry(separation)
  pairImpulse(params, separation[0], separation[1], geometry.invDistance,
    geometry.normalizedDistance, speciesMagnitude, speciesMagnitude,
    densityThis.float32, densityOther.float32)

func pressureWords(impulse: PairImpulse): tuple[x, y: VelocityWords] =
  ## The pair's pressure integer as the two words it is split across.
  (x: splitVelocityWord(impulse.pressureOnThis.x, VELOCITY_COARSE_SHIFT),
   y: splitVelocityWord(impulse.pressureOnThis.y, VELOCITY_COARSE_SHIFT))

func magnitudeAt(onset, densityThis, densityOther: float;
    normalizedDistance: float32): float32 =
  worldPressureMagnitude(crowdPressure(densityThis.float32, onset.float32),
    crowdPressure(densityOther.float32, onset.float32), normalizedDistance,
    WORLD_PRESSURE_STIFFNESS.float32, WORLD_PRESSURE_IMPULSE_MAX.float32)

suite "Pressure Past The Onset":
  test "the magnitude is zero at and below the onset":
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      for ratioThis in BELOW_ONSET_RATIOS:
        for ratioOther in BELOW_ONSET_RATIOS:
          for normalizedDistance in [0.0'f32, 0.2'f32, 0.5'f32, 0.99'f32]:
            let magnitude = magnitudeAt(onset, onset * ratioThis,
              onset * ratioOther, normalizedDistance)
            if magnitude != 0.0'f32:
              verdicts.add "onset " & $onset & " at " & $ratioThis & " and " &
                $ratioOther & " of it, r/R " & $normalizedDistance &
                ": the magnitude is " & $magnitude & ", not zero"
    checkNoVerdicts(verdicts)

  test "the magnitude rises strictly past the onset and holds at q_max":
    let ceilingMagnitude = WORLD_PRESSURE_IMPULSE_MAX.float32
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      var previous = -1.0'f32
      var saturatedAt = -1
      for index, ratio in PAST_ONSET_RATIOS:
        let magnitude = magnitudeAt(onset, onset * ratio, onset * ratio, 0.0'f32)
        let label = "onset " & $onset & " at " & $ratio & " of it"
        if magnitude > ceilingMagnitude:
          verdicts.add label & ": the magnitude is " & $magnitude &
            ", past the per-pair ceiling of " & $ceilingMagnitude
        if saturatedAt < 0 and magnitude == ceilingMagnitude:
          saturatedAt = index
        if saturatedAt < 0:
          if not (magnitude > previous):
            verdicts.add label & ": the magnitude is " & $magnitude &
              ", not past the previous " & $previous
        elif magnitude != ceilingMagnitude:
          verdicts.add label & ": the magnitude fell to " & $magnitude &
            " after saturating at " & $ceilingMagnitude
        previous = magnitude
      if saturatedAt < 2:
        verdicts.add "onset " & $onset & ": the sweep saturated at index " &
          $saturatedAt & ", so it shows no rise before the ceiling"
    checkNoVerdicts(verdicts)

  test "the magnitude grows as the square of the excess over the onset":
    # The square law's local stiffness is zero at the onset and rises with the
    # excess. A law with a step there - a Tait pressure for one - boils the
    # settle it is meant to hold (mean speed 4.02 against 1.47).
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      for excess in [0.01, 0.05, 0.2, 0.5, 1.0]:
        let single = magnitudeAt(onset, onset * (1.0 + excess),
          onset * (1.0 + excess), 0.0'f32)
        let doubled = magnitudeAt(onset, onset * (1.0 + 2.0 * excess),
          onset * (1.0 + 2.0 * excess), 0.0'f32)
        if not (single > 0.0'f32):
          verdicts.add "onset " & $onset & " at excess " & $excess &
            ": the magnitude is " & $single & ", so the ratio says nothing"
        elif not approxEq(doubled / single, 4.0'f32, 1e-3'f32):
          verdicts.add "onset " & $onset & " at excess " & $excess &
            ": doubling the excess multiplied the magnitude by " &
            $(doubled / single) & ", not by 4"
    checkNoVerdicts(verdicts)

  test "each component is zero at and below the onset and grows with density":
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      let params = pressureParams(onset, FORCE_STRENGTH_MAX)
      for separation in PRESSURE_SEPARATIONS:
        var previous = (x: 0'i32, y: 0'i32)
        for ratio in BELOW_ONSET_RATIOS:
          let words = pairAt(params, separation, onset * ratio,
            onset * ratio).pressureOnThis
          if words != (x: 0'i32, y: 0'i32):
            verdicts.add "onset " & $onset & " separation " & $separation &
              " at " & $ratio & " of the onset: the integers are " & $words &
              ", not zero"
        for ratio in PAST_ONSET_RATIOS:
          let words = pairAt(params, separation, onset * ratio,
            onset * ratio).pressureOnThis
          if abs(words.x) < abs(previous.x) or abs(words.y) < abs(previous.y):
            verdicts.add "onset " & $onset & " separation " & $separation &
              " at " & $ratio & " of the onset: the integers fell from " &
              $previous & " to " & $words
          previous = words
        if previous == (x: 0'i32, y: 0'i32):
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": the densest pair still writes nothing"
    checkNoVerdicts(verdicts)

  test "a saturated pair keeps the direction of its separation":
    # Saturating each component on its own would turn every saturated pair
    # toward a diagonal, so the sum saturates before the direction, and
    # before the proximity weight, is applied.
    let ceilingMagnitude = WORLD_PRESSURE_IMPULSE_MAX.float32
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      let params = pressureParams(onset, 1.0)
      for separation in PRESSURE_SEPARATIONS:
        let geometry = pairGeometry(separation)
        let words = pairAt(params, separation, onset * 30.0,
          onset * 30.0).pressureOnThis
        let expectedMagnitude =
          ceilingMagnitude * (1.0'f32 - geometry.normalizedDistance)
        let expected = (
          x: encodeVelocityDelta(-expectedMagnitude * separation[0] *
            geometry.invDistance, pressureScale),
          y: encodeVelocityDelta(-expectedMagnitude * separation[1] *
            geometry.invDistance, pressureScale))
        if words != expected:
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": the saturated integers are " & $words & ", not " & $expected
    checkNoVerdicts(verdicts)

  test "the two particles take exactly opposite integers and sum to zero":
    # The pair's integer is formed once and exchanged, and the magnitude is
    # symmetric in the two pressures, so reading the pair from the other side
    # returns the same integer negated.
    var verdicts: seq[string]
    var sum = (x: 0'i64, y: 0'i64)
    var written = (x: 0'i64, y: 0'i64)
    for onset in PRESSURE_ONSETS:
      let params = pressureParams(onset, 1.0)
      for separation in PRESSURE_SEPARATIONS:
        for ratioThis in PAST_ONSET_RATIOS:
          for ratioOther in [0.5, 1.0, 3.0, 12.0]:
            let fromThis = pairAt(params, separation, onset * ratioThis,
              onset * ratioOther)
            let fromOther = pairAt(params,
              (-separation[0], -separation[1]), onset * ratioOther,
              onset * ratioThis)
            if fromOther.pressureOnThis != fromThis.pressureOnOther():
              verdicts.add "onset " & $onset & " separation " & $separation &
                " at " & $ratioThis & " and " & $ratioOther &
                ": the other particle reads " & $fromOther.pressureOnThis &
                ", against the " & $fromThis.pressureOnOther() & " this one hands it"
            sum = (x: sum.x + fromThis.pressureOnThis.x +
                fromThis.pressureOnOther().x,
              y: sum.y + fromThis.pressureOnThis.y +
                fromThis.pressureOnOther().y)
            written = (x: written.x + abs(fromThis.pressureOnThis.x.int64),
              y: written.y + abs(fromThis.pressureOnThis.y.int64))
    if sum != (x: 0'i64, y: 0'i64):
      verdicts.add "the swept pairs' integers sum to " & $sum & ", not zero"
    if written.x == 0 or written.y == 0:
      verdicts.add "the sweep wrote " & $written &
        " in total, so a zero sum says nothing"
    checkNoVerdicts(verdicts)

  test "the term is unchanged by force strength, the matrix entry and crowding":
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      for separation in PRESSURE_SEPARATIONS:
        let geometry = pairGeometry(separation)
        var reference = (x: 0'i32, y: 0'i32)
        var speciesSeen: seq[float32]
        var first = true
        for forceMultiplier in [0.0, 0.7, 1.0, FORCE_STRENGTH_MAX]:
          for entry in [MATRIX_MIN_VALUE, 0.0, MATRIX_MAX_VALUE]:
            for crowdingStrength in [0.0, 1.0, CROWDING_STRENGTH_MAX]:
              let attenuation = crowdingAttenuation((onset * 12.0).float32,
                crowdingStrength.float32)
              let speciesMagnitude = polynomialForce(
                geometry.normalizedDistance, entry.float32, 0.5'f32, 0.75'f32,
                attenuation)
              let impulse = pairAt(pressureParams(onset, forceMultiplier),
                separation, onset * 12.0, onset * 12.0, speciesMagnitude)
              if first:
                reference = impulse.pressureOnThis
                first = false
              elif impulse.pressureOnThis != reference:
                verdicts.add "onset " & $onset & " separation " & $separation &
                  " at force " & $forceMultiplier & " entry " & $entry &
                  " crowding " & $crowdingStrength & ": the integers are " &
                  $impulse.pressureOnThis & ", against " & $reference
              # Both components, since a separation along one axis leaves the
              # other at zero however the species force moves.
              speciesSeen.add impulse.speciesOnThis.x + impulse.speciesOnThis.y
        if reference == (x: 0'i32, y: 0'i32):
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": the term writes nothing, so the sweep holds nothing"
        if speciesSeen.len > 0 and speciesSeen.allIt(it == speciesSeen[0]):
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": the sweep left the species term at " & $speciesSeen[0] &
            " throughout, so it moves nothing the term could have followed"
    checkNoVerdicts(verdicts)

  test "the term is unchanged by the friction and the pair's relative velocity":
    # Integrate receives the friction as the retention factor 1 - slider
    # (src/app.nim:193), so the swept retentions are the slider's two ends.
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      let params = pressureParams(onset, 1.0)
      for separation in PRESSURE_SEPARATIONS:
        var reference = (x: 0'i32, y: 0'i32)
        var speeds: seq[float32]
        var first = true
        for retention in [1.0 - FRICTION_MIN, 0.8, 1.0 - FRICTION_MAX]:
          for velocity in [(0.0'f32, 0.0'f32), (7.5'f32, -3.25'f32),
              (-40.0'f32, 40.0'f32)]:
            let impulse = pairAt(params, separation, onset * 12.0, onset * 12.0)
            let words = pressureWords(impulse)
            if first:
              reference = impulse.pressureOnThis
              first = false
            elif impulse.pressureOnThis != reference:
              verdicts.add "onset " & $onset & " separation " & $separation &
                " at retention " & $retention & " velocity " & $velocity &
                ": the integers are " & $impulse.pressureOnThis &
                ", against " & $reference
            let moved = (
              x: velocity[0] + decodeVelocityWords(words.x, invPressureScale,
                1.0'f32, VELOCITY_COARSE_SHIFT),
              y: velocity[1] + decodeVelocityWords(words.y, invPressureScale,
                1.0'f32, VELOCITY_COARSE_SHIFT))
            speeds.add postStepSpeed(sqrt(moved.x * moved.x +
              moved.y * moved.y), retention.float32,
              MAX_VELOCITY_MAX.float32)
        if reference == (x: 0'i32, y: 0'i32):
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": the term writes nothing, so the sweep holds nothing"
        if speeds.len > 0 and speeds.allIt(it == speeds[0]):
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": every swept friction and velocity left the same speed " &
            $speeds[0] & ", so the sweep moves nothing"
    checkNoVerdicts(verdicts)

  test "the sum saturates before the proximity weight, even where the old order would not (T10)":
    # c (the pre-weight sum) exceeds q_max at density ratio 30, but the old
    # order applies the weight before saturating, so at r/R 0.95 the old
    # magnitude (378.45) is far short of q_max and the new one (35.34,
    # q_max * 0.05) is not.
    let onset = 40.0
    let density = onset * 30.0
    let pressureEach = crowdPressure(density.float32, onset.float32)
    let sum = min(WORLD_PRESSURE_STIFFNESS.float32 *
      (pressureEach + pressureEach) * FRAME_DT_REFERENCE.float32,
      WORLD_PRESSURE_IMPULSE_MAX.float32)
    let normalizedDistance = 0.95'f32
    let expected = sum * (1.0'f32 - normalizedDistance)
    let actual = magnitudeAt(onset, density, density, normalizedDistance)
    check abs(actual - expected) < 1e-3'f32

# ==============================================================================
# THE STEP LIMIT
# ==============================================================================
# integrate scales a particle's whole decoded delta by s = min(1, theta / (2 *
# ff * D)), D being its summed pair stiffness, so the step is stable at every
# frame factor by construction. A particle with zero stiffness gets s = 1
# exactly.

func referenceIntegrateVelocity(velocity: tuple[x, y: float32];
    deltaFixed: tuple[x, y: int32];
    invFixedPointScale, frameFactor, friction, maxVelocity: float32):
    tuple[x, y: float32] =
  ## The D1 damped-clock map, worked independently of physics_core so T1
  ## compares against a second reading of the design rather than against
  ## physics_core's own claim of it: rho = friction^ff, h = friction *
  ## (1 - rho) / (1 - friction), u' = rho*v + h*delta, capped on speed alone.
  let rho = pow(friction, frameFactor)
  let h = if friction >= 1.0'f32: frameFactor
    else: friction * (1.0'f32 - rho) / (1.0'f32 - friction)
  var newVelX = rho * velocity.x + h * decodeVelocityDelta(deltaFixed.x,
    invFixedPointScale, 1.0'f32)
  var newVelY = rho * velocity.y + h * decodeVelocityDelta(deltaFixed.y,
    invFixedPointScale, 1.0'f32)
  let speed = sqrt(newVelX * newVelX + newVelY * newVelY)
  let capped = postStepSpeed(speed, 1.0'f32, maxVelocity)
  if speed > 0.0'f32:
    let scale = capped / speed
    newVelX *= scale
    newVelY *= scale
  (x: newVelX, y: newVelY)

const STEP_LIMIT_FRAME_FACTORS = [0.0'f32, 0.42'f32, 1.0'f32, 2.0'f32, 30.0'f32]

suite "The Step Limit":
  test "a calm particle's step is untouched at every frame factor (T1)":
    var rng = initRand(2200)
    var verdicts: seq[string]
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    for trial in 0 ..< 20:
      let velocity = (x: rng.rand(-40.0'f32 .. 40.0'f32),
        y: rng.rand(-40.0'f32 .. 40.0'f32))
      let word = (x: int32(rng.rand(-2_000_000 .. 2_000_000)),
        y: int32(rng.rand(-2_000_000 .. 2_000_000)))
      for ff in STEP_LIMIT_FRAME_FACTORS:
        let s = stepLimit(ff, 0.0'f32, PRESSURE_STEP_BOUND.float32)
        let limited = integrateVelocity(velocity, word, invScale,
          stepClock(ff, 0.9'f32), s, 60.0'f32)
        let reference = referenceIntegrateVelocity(velocity, word, invScale,
          ff, 0.9'f32, 60.0'f32)
        if limited != reference:
          verdicts.add "trial " & $trial & " ff " & $ff & ": limited " &
            $limited & " against the reference map's " & $reference
    checkNoVerdicts(verdicts)

  test "a limited step never carries 2 * ff * s * D past the bound (T2)":
    var rng = initRand(4100)
    var verdicts: seq[string]
    let bound = PRESSURE_STEP_BOUND.float32
    for trial in 0 ..< 200:
      let ff = rng.rand(0.0'f32 .. 30.0'f32)
      let stiffness = rng.rand(0.0'f32 .. 1000.0'f32)
      let s = stepLimit(ff, stiffness, bound)
      let reach = 2.0'f32 * ff * s * stiffness
      if reach > bound + 1e-3'f32:
        verdicts.add "trial " & $trial & " ff " & $ff & " D " & $stiffness &
          ": 2*ff*s*D is " & $reach & ", past the bound " & $bound
      if 2.0'f32 * ff * stiffness <= bound and s != 1.0'f32:
        verdicts.add "trial " & $trial & " ff " & $ff & " D " & $stiffness &
          ": s is " & $s & ", not 1, though 2*ff*D does not reach the bound"
    checkNoVerdicts(verdicts)

  test "a pair's stiffness is the radial slope of its impulse (T3)":
    var verdicts: seq[string]
    let onset = 40.0'f32
    for ratio in [0.0'f32, 0.5'f32, 1.0'f32, 2.0'f32, 4.0'f32]:
      # Kept well under q_max (706.9) so the derivative is not entangled
      # with the saturation T10 covers: at ratio 4 the sum is 540 * 2 *
      # 16 / 120 = 144.
      let density = onset * (1.0'f32 + ratio)
      let pressureEach = crowdPressure(density, onset)
      let sum = min(WORLD_PRESSURE_STIFFNESS.float32 *
        (pressureEach + pressureEach) * FRAME_DT_REFERENCE.float32,
        WORLD_PRESSURE_IMPULSE_MAX.float32)
      let slope = pairStiffnessSlope(pressureEach, pressureEach,
        WORLD_PRESSURE_STIFFNESS.float32, WORLD_PRESSURE_IMPULSE_MAX.float32,
        1.0'f32 / PRESSURE_RADIUS)
      let h = 0.001'f32
      let impulseAt = proc(normalizedDistance: float32): float32 =
        sum * (1.0'f32 - normalizedDistance)
      let numeric = -(impulseAt(0.5'f32 + h) - impulseAt(0.5'f32 - h)) /
        (2.0'f32 * h * PRESSURE_RADIUS)
      if ratio == 0.0'f32:
        if slope != 0.0'f32:
          verdicts.add "at the onset: slope is " & $slope & ", not 0"
      else:
        if not approxEq(slope, numeric, 1e-3'f32 * abs(numeric)):
          verdicts.add "ratio " & $ratio & ": slope " & $slope &
            " against the numeric derivative " & $numeric
      let ceiling = WORLD_PRESSURE_IMPULSE_MAX.float32 / PRESSURE_RADIUS
      if slope > ceiling + 1e-3'f32:
        verdicts.add "ratio " & $ratio & ": slope " & $slope &
          " exceeds q_max/R " & $ceiling
    checkNoVerdicts(verdicts)

  test "the stiffness words decode to the summed slope (T4)":
    let slopePerPair = (WORLD_PRESSURE_IMPULSE_MAX / INTERACTION_RADIUS_MIN.float).float32
    let word = splitVelocityWord(encodeStiffness(slopePerPair,
      STIFFNESS_FIXED_POINT_SCALE.float32), STIFFNESS_COARSE_SHIFT)
    var words: VelocityWords
    for _ in 0 ..< MAX_PARTICLES:
      words = addVelocityWords(words, word)
    let decoded = decodeStiffness(words,
      1.0'f32 / STIFFNESS_FIXED_POINT_SCALE.float32, STIFFNESS_COARSE_SHIFT)
    let expected = MAX_PARTICLES.float * slopePerPair.float
    let tolerance = MAX_PARTICLES.float * pow(2.0, -17.0)
    check abs(decoded.float - expected) <= tolerance

  test "the step limit scales every writer's contribution alike (T6)":
    let scale = PRODUCTION_TUNING.fixedPointScale.float32
    let invScale = 1.0'f32 / scale
    let ff = 4.0'f32
    let bound = PRESSURE_STEP_BOUND.float32
    let trueSlope = 50.0'f32
    let expectedS = bound / (2.0'f32 * ff * trueSlope)
    let words = splitVelocityWord(encodeStiffness(trueSlope,
      STIFFNESS_FIXED_POINT_SCALE.float32), STIFFNESS_COARSE_SHIFT)
    let decodedD = decodeStiffness(words,
      1.0'f32 / STIFFNESS_FIXED_POINT_SCALE.float32, STIFFNESS_COARSE_SHIFT)
    let s = stepLimit(ff, decodedD, bound)
    let speciesFixed = encodeVelocityDelta(3.0'f32, scale)
    let pressureFixed = encodeVelocityDelta(-1.5'f32, scale)
    let bodyFixed = encodeVelocityDelta(0.7'f32, scale)
    let combinedFixed = speciesFixed + pressureFixed + bodyFixed
    let stepped = integrateVelocity((x: 0.0'f32, y: 0.0'f32),
      (x: combinedFixed, y: 0'i32), invScale, stepClock(ff, 1.0'f32), s,
      1.0e6'f32)
    let expectedX = expectedS * decodeVelocityDelta(combinedFixed, invScale, ff)
    check abs(stepped.x - expectedX) < 1e-3'f32

suite "The Species Term Is Zero At Strength Zero":
  test "the species force is exactly zero on both particles":
    var verdicts: seq[string]
    for separation in PRESSURE_SEPARATIONS:
      let geometry = pairGeometry(separation)
      for entry in SWEPT_MATRIX_VALUES:
        for normalizedDistance in [0.0'f32, 0.2'f32, 0.6'f32, 0.99'f32]:
          let magnitude = polynomialForce(normalizedDistance, entry.float32,
            0.5'f32, 0.75'f32, 1.0'f32)
          let impulse = pairImpulse(pressureParams(254.4, FORCE_STRENGTH_MIN),
            separation[0], separation[1], geometry.invDistance,
            normalizedDistance, magnitude, magnitude, 0.0'f32, 0.0'f32)
          if impulse.speciesOnThis.x != 0.0'f32 or
              impulse.speciesOnThis.y != 0.0'f32 or
              impulse.speciesOnOther.x != 0.0'f32 or
              impulse.speciesOnOther.y != 0.0'f32:
            verdicts.add "separation " & $separation & " entry " & $entry &
              " at r/R " & $normalizedDistance & ": the species force is " &
              $impulse.speciesOnThis & " and " & $impulse.speciesOnOther
    checkNoVerdicts(verdicts)

  test "a crowd past the onset still resists compression at strength zero":
    # The pressure is part of the pair law, not a coupling: turning the species
    # force off leaves the world's resistance to compression where it was.
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      for separation in PRESSURE_SEPARATIONS:
        let atZero = pairAt(pressureParams(onset, FORCE_STRENGTH_MIN),
          separation, onset * 12.0, onset * 12.0).pressureOnThis
        let atFull = pairAt(pressureParams(onset, FORCE_STRENGTH_MAX),
          separation, onset * 12.0, onset * 12.0).pressureOnThis
        if atZero == (x: 0'i32, y: 0'i32):
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": a pair at 12 times the onset receives nothing at strength zero"
        elif atZero != atFull:
          verdicts.add "onset " & $onset & " separation " & $separation &
            ": strength zero writes " & $atZero & ", against " & $atFull &
            " at the strength ceiling"
    checkNoVerdicts(verdicts)

  test "a pair below the onset passes through at strength zero":
    var verdicts: seq[string]
    for onset in PRESSURE_ONSETS:
      for separation in PRESSURE_SEPARATIONS:
        for ratio in BELOW_ONSET_RATIOS:
          let impulse = pairAt(pressureParams(onset, FORCE_STRENGTH_MIN),
            separation, onset * ratio, onset * ratio)
          if impulse.pressureOnThis != (x: 0'i32, y: 0'i32) or
              impulse.speciesOnThis != (x: 0.0'f32, y: 0.0'f32):
            verdicts.add "onset " & $onset & " separation " & $separation &
              " at " & $ratio & " of the onset: the pair writes " &
              $impulse.speciesOnThis & " and " & $impulse.pressureOnThis
    checkNoVerdicts(verdicts)

# Today's species expression, kept test-local so the suite below compares the
# pair against forces.wgsl's convention rather than against the oracle under
# test: the magnitude scaled by `params.forceMultiplier * invDistance`
# (`:289`), projected on the separation, encoded once per reference frame
# (`:385`).
func todaySpeciesForce(separationComponent, speciesMagnitude, forceMultiplier,
    invDistance: float32): float32 =
  separationComponent * (speciesMagnitude * (forceMultiplier * invDistance))

func todaySpeciesWord(separationComponent, speciesMagnitude, forceMultiplier,
    invDistance, fixedPointScale: float32): int32 =
  int32(todaySpeciesForce(separationComponent, speciesMagnitude,
    forceMultiplier, invDistance) * FRAME_DT_REFERENCE.float32 *
    fixedPointScale)

suite "The Species Term Is Untouched Below The Onset":
  # Force Strength runs 0.14, 0.2, 0.5 and 1 on the new scale, behind a pair
  # gain of 5. 0.14 is swept beyond the three the law names because the
  # measured falsifier - a regrouped product moving 35 207 of 100 000 low bits
  # - was taken at the multiplier 0.7 it stands for.
  const SPECIES_MULTIPLIERS = [0.7, 1.0, 2.5, 5.0]

  test "the velocity delta is bit-identical with and without the term":
    var verdicts: seq[string]
    for forceMultiplier in SPECIES_MULTIPLIERS:
      for onset in PRESSURE_ONSETS:
        let params = pressureParams(onset, forceMultiplier)
        for separation in PRESSURE_SEPARATIONS:
          let geometry = pairGeometry(separation)
          for ratio in BELOW_ONSET_RATIOS:
            let density = onset * ratio
            for entry in SWEPT_MATRIX_VALUES:
              for crowdingStrength in SWEPT_CROWDING_STRENGTHS:
                let attenuation = crowdingAttenuation(density.float32,
                  crowdingStrength.float32)
                for magnitude in [
                    polynomialForce(geometry.normalizedDistance,
                      entry.float32, 0.5'f32, 0.75'f32, attenuation),
                    exponentialForce(geometry.normalizedDistance,
                      entry.float32, 4.0'f32, 2.0'f32, attenuation)]:
                  let impulse = pairAt(params, separation, density, density,
                    magnitude)
                  let pressure = pressureWords(impulse)
                  let withTerm = (
                    x: addVelocityWords((fine: forcesVelocityDeltaFixed(
                      impulse.speciesOnThis.x, pressureScale), coarse: 0'i32),
                      pressure.x),
                    y: addVelocityWords((fine: forcesVelocityDeltaFixed(
                      impulse.speciesOnThis.y, pressureScale), coarse: 0'i32),
                      pressure.y))
                  let without = (
                    x: todaySpeciesWord(separation[0], magnitude,
                      forceMultiplier.float32, geometry.invDistance,
                      pressureScale),
                    y: todaySpeciesWord(separation[1], magnitude,
                      forceMultiplier.float32, geometry.invDistance,
                      pressureScale))
                  let decoded = (
                    x: decodeVelocityWords(withTerm.x, invPressureScale,
                      1.0'f32, VELOCITY_COARSE_SHIFT),
                    y: decodeVelocityWords(withTerm.y, invPressureScale,
                      1.0'f32, VELOCITY_COARSE_SHIFT))
                  let todayDecoded = (
                    x: decodeVelocityDelta(without.x, invPressureScale, 1.0'f32),
                    y: decodeVelocityDelta(without.y, invPressureScale, 1.0'f32))
                  # The register the shader accumulates in, as well as the
                  # integer it encodes: a regrouped product moves the register
                  # on every pair, where truncation hides it on most.
                  let todayForce = (
                    x: todaySpeciesForce(separation[0], magnitude,
                      forceMultiplier.float32, geometry.invDistance),
                    y: todaySpeciesForce(separation[1], magnitude,
                      forceMultiplier.float32, geometry.invDistance))
                  let label = "force " & $forceMultiplier & " onset " &
                    $onset & " separation " & $separation & " at " & $ratio &
                    " of the onset, entry " & $entry & " crowding " &
                    $crowdingStrength
                  if impulse.speciesOnThis != todayForce:
                    verdicts.add label & ": the species register is " &
                      $impulse.speciesOnThis & ", against today's " &
                      $todayForce
                  if decoded != todayDecoded:
                    verdicts.add label & ": the delta is " & $decoded &
                      ", against today's " & $todayDecoded
    checkNoVerdicts(verdicts)

# ==============================================================================
# THE D1 CLOCK
# ==============================================================================

suite "A Damped Clock At Frame Factor 1 Is The Landed Step":
  test "rho and h equal r, and u' matches r*s*(v+delta) at ff 1":
    var verdicts: seq[string]
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    let fixedScale = PRODUCTION_TUNING.fixedPointScale.float32
    for r in [0.5'f32, 0.7'f32, 0.88'f32, 0.95'f32, 0.999'f32]:
      let clock = stepClock(1.0'f32, r)
      if not approxEq(clock.retention, r, 1e-6'f32):
        verdicts.add "r " & $r & ": rho is " & $clock.retention
      if not approxEq(clock.forceGain, r, 1e-6'f32):
        verdicts.add "r " & $r & ": h is " & $clock.forceGain
      let v = (x: 3.0'f32, y: -2.0'f32)
      let deltaVal = 1.5'f32
      let word = (x: encodeVelocityDelta(deltaVal, fixedScale), y: 0'i32)
      let s = 0.6'f32
      let stepped = integrateVelocity(v, word, invScale, clock, s, 1.0e6'f32)
      let expectedX = r * s * (v.x + deltaVal)
      if not approxEq(stepped.x, expectedX, 1e-4'f32 * abs(expectedX)):
        verdicts.add "r " & $r & ": u' is " & $stepped.x & ", expected " &
          $expectedX
    checkNoVerdicts(verdicts)

suite "A Constant Force Moves A Frictionless Particle The Same Distance At Every Frame Factor":
  test "total travel matches delta*T*(T+ff)/2 for the reference frames actually elapsed":
    # T is the reference-frame time elapsed by `steps` substeps of size ff,
    # not a fixed 60: 60/ff is not an integer at ff 0.42, so T is the
    # product actually reached.
    var verdicts: seq[string]
    let fixedScale = PRODUCTION_TUNING.fixedPointScale.float32
    let invScale = 1.0'f32 / fixedScale
    let deltaVal = 0.02'f32
    let word = (x: encodeVelocityDelta(deltaVal, fixedScale), y: 0'i32)
    for ff in [0.42'f32, 1.0'f32, 10.0'f32, 30.0'f32]:
      let clock = stepClock(ff, 1.0'f32)
      let steps = int(60.0'f32 / ff)
      var v = (x: 0.0'f32, y: 0.0'f32)
      var x = 0.0'f32
      for _ in 0 ..< steps:
        v = integrateVelocity(v, word, invScale, clock, 1.0'f32, 1.0e6'f32)
        x += travel(clock) * v.x
      let elapsed = steps.float32 * ff
      let expected = deltaVal * elapsed * (elapsed + ff) / 2.0'f32
      if not approxEq(x, expected, 1e-3'f32 * abs(expected)):
        verdicts.add "ff " & $ff & ": travel is " & $x & ", expected " &
          $expected
    checkNoVerdicts(verdicts)

suite "Terminal Speed Per Reference Frame Is r/(1-r) Times The Force At Every Frame Factor":
  test "forceGain over one minus retention equals r/(1-r) at every ff":
    var verdicts: seq[string]
    var rng = initRand(5100)
    for _ in 0 ..< 200:
      let ff = rng.rand(0.05'f32 .. 30.0'f32)
      let r = rng.rand(0.5'f32 .. 0.999'f32)
      let clock = stepClock(ff, r)
      let terminal = clock.forceGain / (1.0'f32 - clock.retention)
      let expected = r / (1.0'f32 - r)
      if not approxEq(terminal, expected, 1e-2'f32 * abs(expected)):
        verdicts.add "ff " & $ff & " r " & $r & ": terminal ratio is " &
          $terminal & ", expected " & $expected
    checkNoVerdicts(verdicts)

suite "A Held Frame Carries Speed Unchanged":
  test "a frictionless, forceless velocity survives a step at ff 0.42 then a step at ff 3":
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    let zeroWord = (x: 0'i32, y: 0'i32)
    let maxVelocity = 60.0'f32
    # Below the soft-cap threshold (30), so a correct, ff-independent cap
    # never touches it; the old per-ff-divided cap did, at ff 0.42.
    let v0 = (x: 20.0'f32, y: 0.0'f32)
    let afterFirst = integrateVelocity(v0, zeroWord, invScale,
      stepClock(0.42'f32, 1.0'f32), 1.0'f32, maxVelocity)
    let afterSecond = integrateVelocity(afterFirst, zeroWord, invScale,
      stepClock(3.0'f32, 1.0'f32), 1.0'f32, maxVelocity)
    check abs(afterSecond.x - v0.x) < 1e-4'f32

suite "The Cap Bounds Speed Per Reference Frame At Every Frame Factor":
  test "the capped speed never exceeds maxVelocity, and travel never exceeds ff*maxVelocity":
    var verdicts: seq[string]
    let fixedScale = PRODUCTION_TUNING.fixedPointScale.float32
    let invScale = 1.0'f32 / fixedScale
    let maxVelocity = 60.0'f32
    let hugeWord = (x: encodeVelocityDelta(10000.0'f32, fixedScale), y: 0'i32)
    for ff in [0.0'f32, 0.42'f32, 1.0'f32, 30.0'f32]:
      let clock = stepClock(ff, 0.9'f32)
      let stepped = integrateVelocity((x: 0.0'f32, y: 0.0'f32), hugeWord,
        invScale, clock, 1.0'f32, maxVelocity)
      let speed = hypot(stepped.x, stepped.y)
      if speed > maxVelocity + 1e-3'f32:
        verdicts.add "ff " & $ff & ": |u'| is " & $speed &
          ", past maxVelocity " & $maxVelocity
      let travelled = abs(travel(clock) * stepped.x)
      let bound = ff * maxVelocity
      if travelled > bound + 1e-3'f32:
        verdicts.add "ff " & $ff & ": travel is " & $travelled &
          ", past ff*maxVelocity " & $bound
    checkNoVerdicts(verdicts)

suite "Density Smoothing Is Per Reference Frame":
  test "two carries at ff 0.5 compose to one carry at ff 1":
    let factor = 0.7'f32
    let half = stepClock(0.5'f32, 1.0'f32)
    let whole = stepClock(1.0'f32, 1.0'f32)
    let twoHalves = densityCarry(half, factor) * densityCarry(half, factor)
    let oneWhole = densityCarry(whole, factor)
    check abs(twoHalves - oneWhole) < 1e-6'f32
    check abs(oneWhole - factor) < 1e-6'f32

suite "A Species Pair's Restoring Slope Is Its Radial Derivative":
  test "the analytic slope matches the central difference off the attraction-peak kink":
    var verdicts: seq[string]
    let eps = 1e-4'f32
    let forceMultiplier = 3.0'f32
    let invRadius = 1.0'f32 / 50.0'f32
    let repulsionEnd = 0.5'f32
    let attractionPeak = 0.75'f32
    let alpha = 4.0'f32
    let beta = 2.0'f32
    for attraction in [-0.6'f32, 0.6'f32]:
      for attenuation in [1.0'f32, 0.5'f32]:
        for i in 0 ..< 50:
          let n = (i.float32 + 0.5'f32) / 50.0'f32
          if abs(n - attractionPeak) < 4.0'f32 * eps:
            continue
          if n - 2.0'f32 * eps <= 0.0'f32 or n + 2.0'f32 * eps >= 1.0'f32:
            continue
          let polyPlus = polynomialForce(n + eps, attraction, repulsionEnd,
            attractionPeak, attenuation)
          let polyMinus = polynomialForce(n - eps, attraction, repulsionEnd,
            attractionPeak, attenuation)
          let polyNumeric = (polyPlus - polyMinus) / (2.0'f32 * eps)
          let polyExpected = max(0.0'f32,
            forceMultiplier * FRAME_DT_REFERENCE.float32 * invRadius * polyNumeric)
          let polyAnalytic = polynomialRestoringSlope(n, attraction,
            repulsionEnd, attractionPeak, attenuation, forceMultiplier, invRadius)
          if not approxEq(polyAnalytic, polyExpected,
              1e-2'f32 * max(abs(polyExpected), 1e-6'f32)):
            verdicts.add "polynomial n " & $n & " attraction " & $attraction &
              " attenuation " & $attenuation & ": analytic " & $polyAnalytic &
              ", numeric " & $polyExpected
          let expoPlus = exponentialForce(n + eps, attraction, alpha, beta,
            attenuation)
          let expoMinus = exponentialForce(n - eps, attraction, alpha, beta,
            attenuation)
          let expoNumeric = (expoPlus - expoMinus) / (2.0'f32 * eps)
          let expoExpected = max(0.0'f32,
            forceMultiplier * FRAME_DT_REFERENCE.float32 * invRadius * expoNumeric)
          let expoAnalytic = exponentialRestoringSlope(n, attraction, alpha,
            beta, attenuation, forceMultiplier, invRadius)
          if not approxEq(expoAnalytic, expoExpected,
              1e-2'f32 * max(abs(expoExpected), 1e-6'f32)):
            verdicts.add "exponential n " & $n & " attraction " & $attraction &
              " attenuation " & $attenuation & ": analytic " & $expoAnalytic &
              ", numeric " & $expoExpected
    checkNoVerdicts(verdicts)

suite "The Step Limit At Frame Factor 1 Is The Landed Bound":
  test "s_D at ff 1 equals min(1, theta / (2D)) at every retention (row 8)":
    let theta = PRESSURE_STEP_BOUND.float32
    let longStepBound = LONG_STEP_BOUND.float32
    var verdicts: seq[string]
    for retention in [0.5'f32, 0.7'f32, 0.88'f32, 0.95'f32, 1.0'f32]:
      let clock = stepClock(1.0'f32, retention)
      for d in [1e-4'f32, 0.5'f32, 1.0'f32, 3.0'f32, 100.0'f32]:
        let s = stepLimit(clock, d, theta, longStepBound)
        let expected = min(1.0'f32, theta / (2.0'f32 * d))
        if abs(s - expected) > 1e-4'f32 * max(expected, 1e-6'f32):
          verdicts.add "retention " & $retention & " D " & $d & ": s_D " &
            $s & ", expected " & $expected
    checkNoVerdicts(verdicts)

suite "The Resized Limit Keeps Every Contact Mode Decaying":
  test "s_D roots of the contact characteristic stay within the unit circle, strictly under friction (row 9)":
    # mu^2 - (1 + s*rho - s*ff*h*2D)*mu + s*rho = 0, D4's contact mode for a
    # pair's relative stiffness k = 2D.
    let theta = PRESSURE_STEP_BOUND.float32
    let longStepBound = LONG_STEP_BOUND.float32
    var verdicts: seq[string]
    let ffs = [0.05'f32, 0.2'f32, 1.0'f32, 4.2'f32, 10.0'f32, 30.0'f32]
    let ds = [1e-4'f32, 1e-2'f32, 1.0'f32, 10.0'f32, 100.0'f32]
    let rs = [0.5'f32, 0.7'f32, 0.88'f32, 0.95'f32, 1.0'f32]
    for ff in ffs:
      for r in rs:
        let clock = stepClock(ff, r)
        for d in ds:
          let s = stepLimit(clock, d, theta, longStepBound)
          let rho = clock.retention.float64
          let sumCoef = 1.0 + s.float64 * rho -
            s.float64 * ff.float64 * clock.forceGain.float64 * 2.0 * d.float64
          let product = s.float64 * rho
          let disc = sumCoef * sumCoef - 4.0 * product
          var maxModulus: float64
          if disc >= 0.0:
            let sq = sqrt(disc)
            maxModulus = max(abs((sumCoef + sq) / 2.0),
              abs((sumCoef - sq) / 2.0))
          else:
            maxModulus = sqrt(product)
          if maxModulus > 1.0 + 1e-6:
            verdicts.add "ff " & $ff & " r " & $r & " D " & $d &
              ": modulus " & $maxModulus & " leaves the unit circle"
          if r < 1.0'f32 and maxModulus >= 1.0 - 1e-9:
            verdicts.add "ff " & $ff & " r " & $r & " D " & $d &
              ": modulus " & $maxModulus & " does not decay strictly"
    checkNoVerdicts(verdicts)

suite "T5g A Limited Step Scales The Carried Velocity":
  test "u' equals 0.25 times rho times u when Delta is 0 and s is 0.25":
    let invScale = 1.0'f32 / PRODUCTION_TUNING.fixedPointScale.float32
    let zeroWord = (x: 0'i32, y: 0'i32)
    let v = (x: 12.0'f32, y: -5.0'f32)
    let r = 0.8'f32
    let ff = 4.0'f32
    let s = 0.25'f32
    let stepped = integrateVelocity(v, zeroWord, invScale, stepClock(ff, r),
      s, 1.0e6'f32)
    let rho = pow(r, ff)
    let expectedX = s * rho * v.x
    let expectedY = s * rho * v.y
    check abs(stepped.x - expectedX) < 1e-4'f32 * abs(expectedX)
    check abs(stepped.y - expectedY) < 1e-4'f32 * abs(expectedY)
