## The parametric-body oracle: the analytic surface, the envelope, the two force
## laws, the reaction a body receives, the slot allocator and the rigid step.
##
## src/body_core.nim is the pure mirror web/shaders/src/body-force.wgsl and
## web/shaders/src/body-integrate.wgsl are written against, so every expectation
## here comes from somewhere other than the functions under test: the isotropic
## circle in closed form, Newton's third law, the lifetime argument itself, and
## symmetry.

import std/[unittest, math, os, strutils, strformat]
import ../src/body_core
import ../src/memory_layout
import ../src/physics_core
import ../src/sph_core
import ../src/config_ranges

const BODY_CORE_TESTS_LOADED* = true

const
  EPSILON_EXACT = 1e-9
    ## The closed-form circle and the scaled evaluation are algebraically the
    ## same expression in a different order, so they agree to float64 rounding
    ## rather than bit for bit.
  EPSILON_LOOSE = 1e-6

const
  TEST_WORLD_W = BODY_WORLD_W
  TEST_WORLD_H = BODY_WORLD_H
    ## The world the oracle states. A suite below reads src/config.nim and holds
    ## body_core's copy to what the app declares, so a world resize cannot leave
    ## either asserting against a world that no longer exists.

func circle(cx, cy, radius: float): Body =
  ## An isotropic body with no band and no forces: the SDF suite's subject.
  Body(centerX: cx, centerY: cy, radius: radius, anisotropy: 1.0,
    bandWidth: 1.0, invMass: 1.0, invInertia: 1.0)

func ellipse(cx, cy, radius, anisotropy, angle: float): Body =
  Body(centerX: cx, centerY: cy, radius: radius, anisotropy: anisotropy,
    angle: angle, bandWidth: 1.0, invMass: 1.0, invInertia: 1.0)

func surfacePoint(body: Body; bearing, scale: float): (float, float) =
  ## ORACLE: the ellipse by its parametric definition, independent of any
  ## distance function. `scale` 1 lands on the surface; below it lies inside and
  ## above it outside, since the ellipse is star-shaped about its centre.
  let localX = body.radius * scale * cos(bearing)
  let localY = body.radius * body.anisotropy * scale * sin(bearing)
  (body.centerX + localX * cos(body.angle) - localY * sin(body.angle),
   body.centerY + localX * sin(body.angle) + localY * cos(body.angle))

suite "A Body's Surface Is An Analytic Signed Distance":
  test "the isotropic distance equals the closed-form circle distance":
    # ORACLE: length(p - c) - r, written out here rather than taken from the
    # function under test. Anisotropy 1 must reduce to exactly that circle.
    let body = circle(1000.0, 700.0, 180.0)
    for px in [820.0, 1000.0, 1181.0, 1600.0]:
      for py in [500.0, 700.0, 902.0, 1300.0]:
        let expected = sqrt((px - body.centerX) * (px - body.centerX) +
          (py - body.centerY) * (py - body.centerY)) - body.radius
        check abs(sampleBody(body, px, py, TEST_WORLD_W,
          TEST_WORLD_H).distance - expected) < EPSILON_EXACT

  test "the sign is negative strictly inside and positive strictly outside":
    # The distance is a scaled bound once the radii differ, but the SIGN is
    # exact at every elongation — which is what enclosure reads.
    for anisotropy in [0.25, 0.5, 1.0, 2.0, 4.0]:
      let body = ellipse(1900.0, 1100.0, 100.0, anisotropy, 0.4)
      for interior in [0.05, 0.4, 0.9]:
        for bearing in 0 ..< 16:
          let theta = TAU * bearing.float / 16.0
          let (px, py) = surfacePoint(body, theta, interior)
          check sampleBody(body, px, py, TEST_WORLD_W,
            TEST_WORLD_H).distance < 0.0
      # Exterior points stay inside half the world in both axes: past that the
      # minimum image is the other way round, and "outside" stops naming a side.
      for exterior in [1.1, 1.5, 2.0]:
        for bearing in 0 ..< 16:
          let theta = TAU * bearing.float / 16.0
          let (px, py) = surfacePoint(body, theta, exterior)
          check sampleBody(body, px, py, TEST_WORLD_W,
            TEST_WORLD_H).distance > 0.0

  test "the distance is zero on the surface":
    for anisotropy in [0.25, 1.0, 4.0]:
      let body = ellipse(1400.0, 900.0, 150.0, anisotropy, -0.9)
      for bearing in 0 ..< 32:
        let theta = TAU * bearing.float / 32.0
        let (px, py) = surfacePoint(body, theta, 1.0)
        check abs(sampleBody(body, px, py, TEST_WORLD_W,
          TEST_WORLD_H).distance) < EPSILON_LOOSE

  test "rotating the body and the sample point together leaves the distance unchanged":
    # The evaluation carries the point into body space, so a rigid rotation of
    # the whole arrangement about the centre is not observable in it.
    let body = ellipse(1920.0, 1080.0, 220.0, 2.5, 0.0)
    let offsetX = 310.0
    let offsetY = -140.0
    let reference = sampleBody(body, body.centerX + offsetX,
      body.centerY + offsetY, TEST_WORLD_W, TEST_WORLD_H).distance
    for turn in [0.3, 1.1, 2.7, -0.8, PI]:
      var turned = body
      turned.angle = turn
      let rotatedX = offsetX * cos(turn) - offsetY * sin(turn)
      let rotatedY = offsetX * sin(turn) + offsetY * cos(turn)
      check abs(sampleBody(turned, body.centerX + rotatedX,
        body.centerY + rotatedY, TEST_WORLD_W,
        TEST_WORLD_H).distance - reference) < EPSILON_LOOSE

  test "the outward direction points away from the surface at every bearing":
    # The direction the forces steer along: outward means the distance grows
    # when a point steps along it.
    let body = ellipse(1000.0, 1000.0, 180.0, 3.0, 0.6)
    const STEP = 0.01
    for bearing in 0 ..< 24:
      let theta = TAU * bearing.float / 24.0
      for scale in [0.5, 1.0, 1.8]:
        let (px, py) = surfacePoint(body, theta, scale)
        let here = sampleBody(body, px, py, TEST_WORLD_W, TEST_WORLD_H)
        let ahead = sampleBody(body, px + here.normalX * STEP,
          py + here.normalY * STEP, TEST_WORLD_W, TEST_WORLD_H)
        check ahead.distance > here.distance
        check abs(here.normalX * here.normalX +
          here.normalY * here.normalY - 1.0) < EPSILON_LOOSE

  test "a body at the world edge reaches across it":
    # ORACLE: the same arrangement translated away from the seam. A body one
    # unit inside the right edge and a particle one unit past it are two units
    # apart, exactly as a particle two units inside would be.
    let atSeam = circle(TEST_WORLD_W - 1.0, 1080.0, 150.0)
    let across = sampleBody(atSeam, 1.0, 1080.0, TEST_WORLD_W, TEST_WORLD_H)
    let inside = sampleBody(atSeam, TEST_WORLD_W - 3.0, 1080.0,
      TEST_WORLD_W, TEST_WORLD_H)
    check abs(across.distance - inside.distance) < EPSILON_EXACT
    # Opposite sides of the centre, so the outward directions oppose.
    check abs(across.normalX + inside.normalX) < EPSILON_LOOSE
    # And the same holds on the other axis.
    let atTop = circle(1920.0, TEST_WORLD_H - 1.0, 150.0)
    check abs(sampleBody(atTop, 1920.0, 1.0, TEST_WORLD_W,
      TEST_WORLD_H).distance -
      sampleBody(atTop, 1920.0, TEST_WORLD_H - 3.0, TEST_WORLD_W,
        TEST_WORLD_H).distance) < EPSILON_EXACT

  test "the centre of a body evaluates without producing a NaN":
    # The outward direction is undefined at the centre; the evaluation still has
    # to return a usable one, because one particle landing there would otherwise
    # poison the whole accumulator.
    for anisotropy in [0.25, 1.0, 4.0]:
      let body = ellipse(500.0, 500.0, 120.0, anisotropy, 0.2)
      let sample = sampleBody(body, body.centerX, body.centerY,
        TEST_WORLD_W, TEST_WORLD_H)
      check sample.distance < 0.0
      check classify(sample.distance) notin {fcNan, fcInf, fcNegInf}
      check abs(sample.normalX * sample.normalX +
        sample.normalY * sample.normalY - 1.0) < EPSILON_LOOSE

suite "A Body's Presence Is An Envelope Over One Lifetime":
  # ORACLE: the lifetime argument itself. Nothing below asks the envelope where
  # its phases are in order to assert how long a body lives — the claim is that
  # the four phases divide the duration the caller named, whatever shape it is
  # given.
  const SKEWS = [-1.0, -0.5, 0.0, 0.37, 1.0]
  const LIFETIME = 8.0

  test "the four proportions sum to one":
    # CONTRACT: lifetime is the sum of the phases by construction, not by a
    # user's arithmetic. The same relation is a static assertion in body_core.
    check abs(ENVELOPE_PROPORTIONS.attack + ENVELOPE_PROPORTIONS.hold +
      ENVELOPE_PROPORTIONS.decay + ENVELOPE_PROPORTIONS.release - 1.0) <
      EPSILON_EXACT

  test "the phases divide the lifetime at every admissible skew":
    for skew in SKEWS:
      let phases = envelopePhases(LIFETIME, skew)
      check phases.attack > 0.0
      check phases.hold > 0.0
      check phases.decay > 0.0
      check phases.release > 0.0
      check abs(phases.attack + phases.hold + phases.decay + phases.release -
        LIFETIME) < EPSILON_LOOSE

  test "a skew redistributes weight between the rise and the fall":
    # What the parameter is for: the same lifetime spent differently. Without
    # this the skew could be ignored entirely and every other envelope test
    # would still pass.
    let early = envelopePhases(LIFETIME, 1.0)
    let late = envelopePhases(LIFETIME, -1.0)
    check early.attack + early.hold > late.attack + late.hold
    check early.decay + early.release < late.decay + late.release

  test "the envelope is zero before ignition and zero once the lifetime elapses":
    for skew in SKEWS:
      for before in [-100.0, -1.0, -1e-9]:
        check bodyEnvelope(before, LIFETIME, skew, 0.5) == 0.0
      for after in [LIFETIME, LIFETIME + 1e-9, LIFETIME * 4.0]:
        check bodyEnvelope(after, LIFETIME, skew, 0.5) == 0.0

  test "a body fades rather than appearing":
    # CONTRACT: no frame shows a step from no contribution to full. Asserted as
    # a Lipschitz bound over the whole lifetime rather than at the phase
    # boundaries alone, so a discontinuity anywhere fails here.
    const SAMPLES = 20000
    for skew in SKEWS:
      for sustain in [0.0, 0.4, 1.0]:
        var previous = 0.0
        var largestStep = 0.0
        for sampleIndex in 0 .. SAMPLES:
          let value = bodyEnvelope(
            LIFETIME * sampleIndex.float / SAMPLES.float, LIFETIME, skew,
            sustain)
          largestStep = max(largestStep, abs(value - previous))
          previous = value
        # The steepest reachable phase is the attack at skew -1, 3.75% of the
        # lifetime, which crosses the whole rise in 750 of these samples. A step
        # at a junction would instead jump by the envelope's own height there —
        # 0.4 at the smallest sustain sampled — so this sits well below the
        # smallest discontinuity the shape can hold.
        check largestStep < 0.01

  test "the envelope rises monotonically through attack and falls through decay":
    for skew in SKEWS:
      let phases = envelopePhases(LIFETIME, skew)
      var previous = -1.0
      for sampleIndex in 0 .. 200:
        let value = bodyEnvelope(
          phases.attack * sampleIndex.float / 200.0, LIFETIME, skew, 0.25)
        check value >= previous
        previous = value
      let decayStart = phases.attack + phases.hold
      previous = 2.0
      for sampleIndex in 0 .. 200:
        let value = bodyEnvelope(
          decayStart + phases.decay * sampleIndex.float / 200.0, LIFETIME,
          skew, 0.25)
        check value <= previous
        previous = value

  test "the envelope holds at one between attack and decay":
    for skew in SKEWS:
      let phases = envelopePhases(LIFETIME, skew)
      for fraction in [0.01, 0.5, 0.99]:
        check abs(bodyEnvelope(phases.attack + phases.hold * fraction,
          LIFETIME, skew, 0.3) - 1.0) < EPSILON_LOOSE

  test "decay ends at the sustain level it was given":
    for skew in SKEWS:
      for sustain in [0.0, 0.25, 0.6, 1.0]:
        let phases = envelopePhases(LIFETIME, skew)
        check abs(bodyEnvelope(phases.attack + phases.hold + phases.decay,
          LIFETIME, skew, sustain) - sustain) < EPSILON_LOOSE

  test "a body contributes for exactly the lifetime it was ignited with":
    # Two bodies of one lifetime and different shapes reach zero at the same
    # moment, having risen and fallen differently in between.
    for skew in SKEWS:
      check bodyEnvelope(LIFETIME * 0.999, LIFETIME, skew, 0.5) > 0.0
      check bodyEnvelope(LIFETIME, LIFETIME, skew, 0.5) == 0.0

suite "One Evaluation Yields Both Proximity And Enclosure":
  const BAND = 200.0
  const RADIUS = 400.0

  func shaped(proximity, enclosure: float): Body =
    Body(centerX: 1920.0, centerY: 1080.0, radius: RADIUS, anisotropy: 1.0,
      bandWidth: BAND, proximity: proximity, enclosure: enclosure,
      invMass: 1.0, invInertia: 1.0)

  func atRadius(body: Body; offset: float): (float, float) =
    ## A point `offset` outside the surface along +x; negative is inside.
    (body.centerX + RADIUS + offset, body.centerY)

  test "proximity is exactly zero at and beyond the band edge":
    let body = shaped(8.0, 0.0)
    for offset in [BAND, BAND + 1.0, BAND * 4.0, -BAND, -BAND - 1.0]:
      let (px, py) = atRadius(body, offset)
      let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        1.0, 1.0)
      check force.x == 0.0
      check force.y == 0.0

  test "proximity approaches the band edge with a vanishing derivative":
    # A linear ramp at one percent inside the edge would still carry one
    # percent of the force; an ease with zero slope there carries three parts
    # in ten thousand. That ratio is the whole claim.
    let body = shaped(8.0, 0.0)
    let (px, py) = atRadius(body, BAND * 0.99)
    let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0)
    check abs(force.x) < 0.001 * body.proximity
    check abs(force.x) > 0.0

  test "proximity points toward the surface from both sides":
    let body = shaped(8.0, 0.0)
    for offset in [BAND * 0.9, BAND * 0.5, 1.0, -1.0, -BAND * 0.5, -BAND * 0.9]:
      let (px, py) = atRadius(body, offset)
      let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        1.0, 1.0)
      # The outward direction is +x at this bearing, so a pull toward the
      # surface is negative outside and positive inside.
      if offset > 0.0:
        check force.x < 0.0
      else:
        check force.x > 0.0
      check abs(force.y) < EPSILON_LOOSE

  test "a negative proximity pushes away from the surface":
    let body = shaped(-8.0, 0.0)
    for offset in [BAND * 0.5, -BAND * 0.5]:
      let (px, py) = atRadius(body, offset)
      let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        1.0, 1.0)
      if offset > 0.0:
        check force.x > 0.0
      else:
        check force.x < 0.0

  test "enclosure at zero strength is zero at every distance":
    let body = shaped(0.0, 0.0)
    for offset in [-RADIUS * 0.9, -BAND, -1.0, 1.0, BAND, BAND * 10.0]:
      let (px, py) = atRadius(body, offset)
      let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        1.0, 1.0)
      check force.x == 0.0
      check force.y == 0.0

  test "positive enclosure holds a particle in and negative keeps one out":
    let holdingIn = shaped(0.0, 5.0)
    let keepingOut = shaped(0.0, -5.0)
    let (outsideX, outsideY) = atRadius(holdingIn, BAND * 0.5)
    let (insideX, insideY) = atRadius(holdingIn, -BAND * 0.5)
    # Positive acts on what has got out, and pushes it back in.
    check bodyForceAt(holdingIn, outsideX, outsideY, TEST_WORLD_W,
      TEST_WORLD_H, 1.0, 1.0).x < 0.0
    check bodyForceAt(holdingIn, insideX, insideY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0).x == 0.0
    # Negative acts on what has got in, and pushes it back out.
    check bodyForceAt(keepingOut, insideX, insideY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0).x > 0.0
    check bodyForceAt(keepingOut, outsideX, outsideY, TEST_WORLD_W,
      TEST_WORLD_H, 1.0, 1.0).x == 0.0

  test "negating enclosure mirrors the same push across the surface":
    # The two signs are one quantity: what a particle at depth x inside
    # receives at -e is exactly the opposite of what a particle at height x
    # outside receives at +e. Enclosure acts on the side its sign names, so the
    # mirror is across the surface rather than at one point.
    # Depths stay inside the radius, or the mirrored point crosses the centre
    # and lands outside the body again.
    for depth in [1.0, BAND * 0.5, BAND, BAND * 1.9]:
      let (outsideX, outsideY) = atRadius(shaped(0.0, 0.0), depth)
      let (insideX, insideY) = atRadius(shaped(0.0, 0.0), -depth)
      let held = bodyForceAt(shaped(0.0, 5.0), outsideX, outsideY,
        TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0)
      let kept = bodyForceAt(shaped(0.0, -5.0), insideX, insideY,
        TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0)
      check abs(held.x + kept.x) < EPSILON_LOOSE
      check abs(held.y + kept.y) < EPSILON_LOOSE
      check abs(held.x) > 0.0

  test "enclosure reaches beyond the band at the strength it ramped to":
    # The band is the ramp, not the reach: past it the hold is at full
    # strength, which is why an escaped particle is always brought back.
    let body = shaped(0.0, 5.0)
    let (edgeX, edgeY) = atRadius(body, BAND)
    let (farX, farY) = atRadius(body, BAND * 5.0)
    let atEdge = bodyForceAt(body, edgeX, edgeY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0)
    let farOut = bodyForceAt(body, farX, farY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0)
    check abs(atEdge.x + body.enclosure) < EPSILON_LOOSE
    check abs(farOut.x - atEdge.x) < EPSILON_LOOSE

  test "both forces scale linearly in the envelope and in the strength":
    let body = shaped(8.0, 5.0)
    let (px, py) = atRadius(body, BAND * 0.4)
    let full = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0)
    for envelope in [0.0, 0.125, 0.5, 0.9]:
      let scaled = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        envelope, 1.0)
      check abs(scaled.x - full.x * envelope) < EPSILON_LOOSE
      check abs(scaled.y - full.y * envelope) < EPSILON_LOOSE
    for strength in [0.0, 0.3, 0.75]:
      let scaled = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        1.0, strength)
      check abs(scaled.x - full.x * strength) < EPSILON_LOOSE

suite "Nim Owns Ignition And Slots, And Knows Them From The Clock Alone":
  # ORACLE: the lifetime argument. A slot's occupancy is a statement about time
  # and nothing else, so every expectation here is arithmetic on the clock.
  const LIFETIME = 5.0

  func disposition(lifetime = LIFETIME): BodyDisposition =
    BodyDisposition(radius: 150.0, bandWidth: 200.0, proximity: 6.0,
      enclosure: 0.0, lifetime: lifetime)

  const PLAIN = BodyShaping(anisotropy: 1.0, envelopeSkew: 0.0, sustain: 0.5)

  test "an ignition claims a free slot and reports that it did":
    var state = initBodyState()
    check state.freeSlots(0.0) == MAX_BODIES
    check state.igniteBody(100.0, 200.0, disposition(), PLAIN, 0.0)
    check state.freeSlots(0.0) == MAX_BODIES - 1
    check state.liveSlots(0.0) == 1

  test "a full table refuses a new ignition and says so":
    var state = initBodyState()
    for index in 0 ..< MAX_BODIES:
      check state.igniteBody(index.float, 0.0, disposition(), PLAIN, 0.0)
    check state.freeSlots(0.0) == 0
    check not state.igniteBody(7.0, 7.0, disposition(), PLAIN, 0.0)
    # And no live body was overwritten by the refusal.
    check state.liveSlots(0.0) == MAX_BODIES

  test "a slot is reused only after its body's full lifetime elapses":
    var state = initBodyState()
    for index in 0 ..< MAX_BODIES:
      check state.igniteBody(index.float, 0.0, disposition(), PLAIN, 0.0)
    for clock in [0.0, LIFETIME * 0.5, LIFETIME - 1e-9]:
      check not state.igniteBody(1.0, 1.0, disposition(), PLAIN, clock)
    check state.igniteBody(1.0, 1.0, disposition(), PLAIN, LIFETIME)

  test "the free count is the ceiling minus the live count at every clock value":
    var state = initBodyState()
    # Staggered ignitions, so the population rises and falls rather than
    # turning over all at once.
    for index in 0 ..< MAX_BODIES:
      check state.igniteBody(index.float, 0.0, disposition(LIFETIME),
        PLAIN, index.float * 0.25)
    for tick in 0 .. 200:
      let clock = tick.float * 0.1
      check state.liveSlots(clock) + state.freeSlots(clock) == MAX_BODIES
      check state.liveSlots(clock) >= 0
      check state.liveSlots(clock) <= MAX_BODIES
    # Past the last body's end every slot is free again, with no buffer read.
    check state.freeSlots(MAX_BODIES.float * 0.25 + LIFETIME) == MAX_BODIES

  test "the envelope array carries one value per slot and zero for a free one":
    var state = initBodyState()
    check state.igniteBody(500.0, 500.0, disposition(), PLAIN, 1.0)
    let atRise = state.envelopeValues(1.0 + LIFETIME * 0.2)
    check atRise.len == MAX_BODIES
    check atRise[0] > 0.0
    for slot in 1 ..< MAX_BODIES:
      check atRise[slot] == 0.0
    for expired in state.envelopeValues(1.0 + LIFETIME):
      check expired == 0.0

  test "an ignition writes the world's dispositions into the body it makes":
    var state = initBodyState()
    check state.igniteBody(640.0, 480.0, disposition(), PLAIN, 0.0)
    let body = state.slots[0].body
    check body.centerX == 640.0
    check body.centerY == 480.0
    check body.radius == disposition().radius
    check body.bandWidth == disposition().bandWidth
    check body.proximity == disposition().proximity
    check body.enclosure == disposition().enclosure
    check body.anisotropy == PLAIN.anisotropy
    # Mass and inertia come from the body's area, so a bigger body is harder to
    # push and harder to turn.
    let larger = block:
      var other = initBodyState()
      check other.igniteBody(0.0, 0.0,
        BodyDisposition(radius: 300.0, bandWidth: 200.0, proximity: 6.0,
          enclosure: 0.0, lifetime: LIFETIME), PLAIN, 0.0)
      other.slots[0].body
    check larger.invMass < body.invMass
    check larger.invInertia < body.invInertia

  # ORACLE: config_ranges' shaping bounds, the same numbers every other source
  # of an ignition would have to know. They are checked here against what a body
  # ends up holding, so the entry point is what enforces them.
  test "shaping past its bounds ignites as the nearest admissible value":
    var state = initBodyState()
    check state.igniteBody(10.0, 20.0, disposition(),
      BodyShaping(anisotropy: BODY_ANISOTROPY_MAX * 4.0,
        envelopeSkew: BODY_ENVELOPE_SKEW_MAX + 2.0,
        sustain: BODY_SUSTAIN_MAX + 3.0), 0.0)
    check state.slots[0].body.anisotropy == BODY_ANISOTROPY_MAX
    check state.slots[0].envelopeSkew == BODY_ENVELOPE_SKEW_MAX
    check state.slots[0].sustain == BODY_SUSTAIN_MAX
    check state.igniteBody(10.0, 20.0, disposition(),
      BodyShaping(anisotropy: BODY_ANISOTROPY_MIN * 0.01,
        envelopeSkew: BODY_ENVELOPE_SKEW_MIN - 2.0,
        sustain: BODY_SUSTAIN_MIN - 3.0), 0.0)
    check state.slots[1].body.anisotropy == BODY_ANISOTROPY_MIN
    check state.slots[1].envelopeSkew == BODY_ENVELOPE_SKEW_MIN
    check state.slots[1].sustain == BODY_SUSTAIN_MIN

  test "the mass a clamped ignition derives is the clamped shape's":
    # The bound holds ahead of everything ignition computes, so no caller can
    # reach the derivation with an unclamped shape.
    var state = initBodyState()
    check state.igniteBody(0.0, 0.0, disposition(),
      BodyShaping(anisotropy: BODY_ANISOTROPY_MAX * 4.0, envelopeSkew: 0.0,
        sustain: 0.5), 0.0)
    let expected = bodyInverseMasses(disposition().radius, BODY_ANISOTROPY_MAX)
    check state.slots[0].body.invMass == expected.invMass
    check state.slots[0].body.invInertia == expected.invInertia

suite "A Body Is Pushed By The Particles It Pushes":
  const WORLD_W = TEST_WORLD_W
  const WORLD_H = TEST_WORLD_H

  func pushable(anisotropy, angle: float): Body =
    Body(centerX: 1920.0, centerY: 1080.0, radius: 300.0,
      anisotropy: anisotropy, angle: angle, bandWidth: 250.0, proximity: 9.0,
      enclosure: 3.0, invMass: 1.0 / 4000.0, invInertia: 1.0 / 4.0e8)

  test "the impulse a body receives is the negation of what it gives":
    # ORACLE: Newton's third law. Every impulse handed to a particle is handed
    # back to the body with the opposite sign, so the two sums cancel — to the
    # accumulator's own resolution and no worse.
    let body = pushable(2.2, 0.4)
    var accumulator = BodyAccumulator()
    var givenX = 0.0
    var givenY = 0.0
    var placed = 0
    for step in 0 ..< 400:
      # A deterministic scatter over a patch that straddles the surface.
      let angleAround = TAU * (step.float * 0.6180339887)
      let reach = 60.0 + 900.0 * ((step.float * 0.7548776662) mod 1.0)
      let px = body.centerX + reach * cos(angleAround)
      let py = body.centerY + reach * sin(angleAround)
      let force = bodyForceAt(body, px, py, WORLD_W, WORLD_H, 0.8, 0.7)
      givenX += force.x
      givenY += force.y
      accumulator.addBodyReaction(body, px, py, WORLD_W, WORLD_H,
        force.x, force.y)
      inc placed
    let received = accumulator.decoded()
    check placed == 400
    # One truncation per contribution, each below one accumulator unit.
    check abs(givenX + received.forceX) < placed.float / BODY_FIXED_POINT_SCALE
    check abs(givenY + received.forceY) < placed.float / BODY_FIXED_POINT_SCALE
    check abs(givenX) > 1.0

  test "a symmetric crowd leaves the body still":
    # ORACLE: symmetry. An ellipse reflected about its own major axis is
    # itself, and a ring of particles at uniform bearings is symmetric under
    # that reflection, so the net force and the net torque both vanish.
    let body = pushable(2.5, 0.0)
    var accumulator = BodyAccumulator()
    const RING = 24
    for step in 0 ..< RING:
      let bearing = TAU * step.float / RING.float
      let px = body.centerX + 420.0 * cos(bearing)
      let py = body.centerY + 420.0 * sin(bearing)
      let force = bodyForceAt(body, px, py, WORLD_W, WORLD_H, 1.0, 1.0)
      accumulator.addBodyReaction(body, px, py, WORLD_W, WORLD_H,
        force.x, force.y)
    let received = accumulator.decoded()
    check abs(received.forceX) < RING.float / BODY_FIXED_POINT_SCALE
    check abs(received.forceY) < RING.float / BODY_FIXED_POINT_SCALE
    check abs(received.torque) < RING.float / BODY_TORQUE_FIXED_SCALE
    # The arrangement is not a vacuous one: a one-sided crowd does move it.
    var lopsided = BodyAccumulator()
    for step in 0 ..< RING:
      let bearing = PI * step.float / RING.float
      let px = body.centerX + 420.0 * cos(bearing)
      let py = body.centerY + 420.0 * sin(bearing)
      let force = bodyForceAt(body, px, py, WORLD_W, WORLD_H, 1.0, 1.0)
      lopsided.addBodyReaction(body, px, py, WORLD_W, WORLD_H,
        force.x, force.y)
    check abs(lopsided.decoded().forceY) > 1.0

  test "a one-sided crowd moves the body toward it":
    let body = pushable(1.0, 0.0)
    var accumulator = BodyAccumulator()
    for step in 0 ..< 40:
      # A wedge of particles off the body's +x side, inside the band.
      let bearing = -0.5 + 1.0 * step.float / 39.0
      let px = body.centerX + 380.0 * cos(bearing)
      let py = body.centerY + 380.0 * sin(bearing)
      let force = bodyForceAt(body, px, py, WORLD_W, WORLD_H, 1.0, 1.0)
      accumulator.addBodyReaction(body, px, py, WORLD_W, WORLD_H,
        force.x, force.y)
    let received = accumulator.decoded()
    check received.forceX > 0.0
    let moved = bodyRigidStep(body, received.forceX, received.forceY,
      received.torque, 1.0, WORLD_W, WORLD_H)
    check moved.centerX > body.centerX

  test "the rigid step wraps a body across the world edge":
    # The step's timestep is seconds, as a particle's is: a body at 600 world
    # units a second crosses tens of units in the twentieth of a second this
    # takes, which is enough to carry it over a seam two units away.
    var body = pushable(1.0, 0.0)
    body.centerX = TEST_WORLD_W - 2.0
    body.velX = 600.0
    let moved = bodyRigidStep(body, 0.0, 0.0, 0.0, 0.05, WORLD_W, WORLD_H)
    check moved.centerX >= 0.0
    check moved.centerX < TEST_WORLD_W
    check moved.centerX < 100.0

  test "exponential damping settles a body in the same time at any substep count":
    # CONTRACT: damping is exponential in dt, so the substep count decides how
    # finely a frame is cut and never how fast a body comes to rest.
    var coarse = pushable(1.0, 0.0)
    coarse.velX = 40.0
    coarse.angVel = 0.9
    var fine = coarse
    const FRAMES = 12
    for frame in 0 ..< FRAMES:
      coarse = bodyRigidStep(coarse, 0.0, 0.0, 0.0, 1.0, WORLD_W, WORLD_H)
      for substep in 0 ..< 8:
        fine = bodyRigidStep(fine, 0.0, 0.0, 0.0, 1.0 / 8.0, WORLD_W, WORLD_H)
    check abs(coarse.velX - fine.velX) < EPSILON_LOOSE
    check abs(coarse.angVel - fine.angVel) < EPSILON_LOOSE
    # And it did settle rather than merely agreeing at a standstill.
    check abs(coarse.velX) < 40.0
    check abs(coarse.velX) > 0.0

suite "A Crowd Cannot Drive A Body Unstable":
  # The measurement gate for BODY_DENSITY, the two damping constants and the two
  # per-substep change caps. Feedback is the part of this capability whose
  # feasibility a reading of the code cannot settle: up to MAX_PARTICLES
  # particles may touch one body in one dispatch, each handing back an impulse
  # and a torque, and the body it moves is the body they are steering toward.
  #
  # FOUR PREMISES. Any of these moving re-runs this suite:
  #   1. the particle budget, memory_layout.MAX_PARTICLES
  #   2. the strength ceiling, BODY_STRENGTH_CEILING, and the force ceiling
  #      BODY_FORCE_CEILING the two signed parameters share
  #   3. the force law in bodyForceAt and the step in bodyRigidStep
  #   4. the substep count, sph_core's SPH_MAX_SUBSTEPS, and the largest frame
  #      BODY_LARGEST_FRAME_FACTOR states
  #
  # Every run is at the WORST reachable frame: BODY_LARGEST_FRAME_FACTOR
  # reference frames of impulse per rendered frame, cut into `substeps` pieces.
  # A shorter frame is strictly gentler on an explicit step, so a bound earned
  # here covers every frame the app can run.

  const CROWD_SAMPLES = 24
    ## The crowd is carried by this many weighted samples rather than by
    ## MAX_PARTICLES individuals: the body reads only the SUM of the reactions,
    ## and a sample standing for `crowd / CROWD_SAMPLES` particles at one point
    ## contributes exactly what those particles would if they were together.
    ## Together is the worst case — spread out they cancel — so the sweep
    ## measures the coherent crowd and covers the scattered one.
  const SWEEP_FRAMES = 480
    ## Rendered frames per run. At the largest frame that is 40 seconds of
    ## wall clock, long enough that a body under a steady crowd reaches its
    ## terminal speed several times over and a divergent one has left the world.
  const SETTLING_TOLERANCE = 2.0
    ## How much larger the second half's peak may be than the first half's
    ## before the run counts as still growing. A body under a steady crowd
    ## reaches a terminal speed and wanders about it, and a chaotic wander
    ## measured over two half-windows moves by tens of a percent; a loop that is
    ## actually gaining moves by hundreds of times, which the first run of this
    ## sweep showed before the impulse cap and the damping were set.

  func reachableCeiling(perFrameCap, frames: float): float =
    ## ORACLE for the bound tests below: the geometric sum, written out rather
    ## than taken from the step under test. Every substep takes
    ## `v <- (v + a) * d` with `a` at most `perFrameCap * frames` and
    ## `d = damping^frames`, so from rest the speed can never pass
    ## `a * (d + d^2 + ...)` however long the run and however large the crowd.
    ## The step's stability is this sum being finite, which it is for every
    ## damping below one.
    let retained = pow(BODY_LINEAR_DAMPING, frames)
    perFrameCap * frames * retained / (1.0 - retained)

  type CrowdRun = object
    ## One run's coordinate and what it measured, so a red reads as a place in
    ## the space rather than as "the sweep failed".
    crowd, strength, proximity, enclosure, band, radius, anisotropy: float
    substeps: int
    finite: bool
    peakSpeed, peakSpin: float
    earlyPeakSpeed, latePeakSpeed: float
    earlyPeakSpin, latePeakSpin: float

  func describe(run: CrowdRun): string =
    &"crowd {run.crowd:.0f}, strength {run.strength:.2f}, " &
    &"proximity {run.proximity:.1f}, enclosure {run.enclosure:.1f}, " &
    &"band {run.band:.0f}, radius {run.radius:.0f}, " &
    &"anisotropy {run.anisotropy:.2f}, substeps {run.substeps} -> " &
    &"peak speed {run.peakSpeed:.4f} (halves {run.earlyPeakSpeed:.4f} then " &
    &"{run.latePeakSpeed:.4f}), peak spin {run.peakSpin:.6f} (halves " &
    &"{run.earlyPeakSpin:.6f} then {run.latePeakSpin:.6f})"

  func settled(run: CrowdRun): bool =
    ## The comparison carries the accumulator's own resolution as its floor: a
    ## body whose whole motion is one fixed-point unit of impulse is reporting
    ## quantization rather than dynamics, and a ratio taken there measures the
    ## truncation.
    let masses = bodyInverseMasses(run.radius, run.anisotropy)
    let speedFloor = masses.invMass / BODY_FIXED_POINT_SCALE
    let spinFloor = masses.invInertia / BODY_TORQUE_FIXED_SCALE
    run.finite and
      run.latePeakSpeed <=
        run.earlyPeakSpeed * SETTLING_TOLERANCE + speedFloor and
      run.latePeakSpin <= run.earlyPeakSpin * SETTLING_TOLERANCE + spinFloor

  proc runCrowdPush(crowd, strength, proximity, enclosure, band, radius,
      anisotropy: float; substeps: int;
      frames = SWEEP_FRAMES): CrowdRun =
    ## One body, one coherent crowd pressed against it, the loop closed at the
    ## frame rate: particles take the impulse, the body takes its negation, both
    ## move, and the next substep evaluates at the new arrangement.
    result = CrowdRun(crowd: crowd, strength: strength, proximity: proximity,
      enclosure: enclosure, band: band, radius: radius, anisotropy: anisotropy,
      substeps: substeps, finite: true)
    let masses = bodyInverseMasses(radius, anisotropy)
    var body = Body(centerX: BODY_WORLD_W * 0.5, centerY: BODY_WORLD_H * 0.5,
      radius: radius, anisotropy: anisotropy, bandWidth: band,
      proximity: proximity, enclosure: enclosure,
      invMass: masses.invMass, invInertia: masses.invInertia)
    let weight = crowd / CROWD_SAMPLES.float
    # A wedge off the body's +x side straddling the surface: one-sided, so the
    # reactions add instead of cancelling, and spanning the band so both force
    # laws act at once.
    var px, py, vx, vy: array[CROWD_SAMPLES, float]
    for sample in 0 ..< CROWD_SAMPLES:
      let bearing = -0.5 + sample.float / (CROWD_SAMPLES - 1).float
      let reach = radius - band * 0.9 +
        1.8 * band * ((sample.float * 0.6180339887) mod 1.0)
      px[sample] = body.centerX + reach * cos(bearing)
      py[sample] = body.centerY + reach * sin(bearing)
    # Two clocks, as the step keeps them: seconds for travel, reference frames
    # for the impulse the strength carries and for the damping.
    let substepSeconds = BODY_LARGEST_SUBSTEP_DT / substeps.float
    let substepFrames = BODY_LARGEST_FRAME_FACTOR / substeps.float
    var speeds = newSeq[float](frames)
    var spins = newSeq[float](frames)
    for frame in 0 ..< frames:
      for _ in 0 ..< substeps:
        var accumulator = BodyAccumulator()
        for sample in 0 ..< CROWD_SAMPLES:
          let atX = px[sample]
          let atY = py[sample]
          let impulse = bodyForceAt(body, atX, atY,
            BODY_WORLD_W, BODY_WORLD_H, 1.0, strength * substepFrames)
          # Action and reaction are taken at the SAME point, which is what
          # body-force.wgsl does by construction: one invocation evaluates the
          # body once at the particle it holds. Taking the lever arm after the
          # particle moved would invent a torque on a circle, whose force is
          # radial and whose torque is therefore exactly zero.
          accumulator.addBodyReaction(body, atX, atY,
            BODY_WORLD_W, BODY_WORLD_H, impulse.x * weight, impulse.y * weight)
          vx[sample] = vx[sample] + impulse.x
          vy[sample] = vy[sample] + impulse.y
          # integrate.wgsl's own post-step: friction at its most permissive
          # setting (retention 1.0, the worst case for stability) and the speed
          # cap at its ceiling.
          let speed = sqrt(vx[sample] * vx[sample] + vy[sample] * vy[sample])
          if speed > 0.0:
            let capped = float(postStepSpeed(float32(speed), 1.0'f32,
              float32(BODY_PARTICLE_SPEED_CEILING)))
            vx[sample] = vx[sample] * capped / speed
            vy[sample] = vy[sample] * capped / speed
          px[sample] = wrapToTorus(px[sample] + vx[sample] * substepSeconds,
            BODY_WORLD_W)
          py[sample] = wrapToTorus(py[sample] + vy[sample] * substepSeconds,
            BODY_WORLD_H)
        let received = accumulator.decoded()
        body = bodyRigidStep(body, received.forceX, received.forceY,
          received.torque, substepSeconds, BODY_WORLD_W, BODY_WORLD_H)
      let speed = sqrt(body.velX * body.velX + body.velY * body.velY)
      let spin = abs(body.angVel)
      if classify(speed) in {fcNan, fcInf, fcNegInf} or
          classify(spin) in {fcNan, fcInf, fcNegInf}:
        result.finite = false
        return
      speeds[frame] = speed
      spins[frame] = spin
      result.peakSpeed = max(result.peakSpeed, speed)
      result.peakSpin = max(result.peakSpin, spin)
    proc peakOver(values: seq[float]; fromFrame, toFrame: int): float =
      for frame in fromFrame ..< toFrame:
        result = max(result, values[frame])
    result.earlyPeakSpeed = peakOver(speeds, 0, frames div 2)
    result.latePeakSpeed = peakOver(speeds, frames div 2, frames)
    result.earlyPeakSpin = peakOver(spins, 0, frames div 2)
    result.latePeakSpin = peakOver(spins, frames div 2, frames)

  # The lattice, evaluated once for the suite. Each axis runs to the bound the
  # shipped range will carry, so the sweep covers every world a player can
  # reach and not one the panel cannot express.
  let sweep = block:
    var runs: seq[CrowdRun] = @[]
    for crowd in [1000.0, MAX_PARTICLES.float * 0.25, MAX_PARTICLES.float]:
      for strength in [BODY_STRENGTH_CEILING * 0.5, BODY_STRENGTH_CEILING]:
        for proximity in [-BODY_FORCE_CEILING, 0.0, BODY_FORCE_CEILING]:
          for enclosure in [-BODY_FORCE_CEILING, 0.0, BODY_FORCE_CEILING]:
            for band in [BODY_BAND_FLOOR, BODY_BAND_CEILING]:
              for radius in [BODY_RADIUS_FLOOR, BODY_RADIUS_CEILING]:
                for anisotropy in [1.0, BODY_ANISOTROPY_CEILING]:
                  for substeps in [1, 3]:
                    runs.add runCrowdPush(crowd, strength, proximity,
                      enclosure, band, radius, anisotropy, substeps)
    runs

  test "the sweep reaches every corner of the space a player can express":
    # A sweep over an empty lattice passes vacuously; this is the positive
    # claim about the subject that keeps the ones below from being free.
    check sweep.len == 3 * 2 * 3 * 3 * 2 * 2 * 2 * 2
    # And every axis above runs to the bound the SHIPPED range carries, so the
    # sweep covers every world the panel can express. config_ranges derives its
    # bodies bounds from this module, so these are one number each rather than
    # two held equal; the checks are what keeps that derivation from being
    # quietly replaced by a literal.
    check BODIES_STRENGTH_MAX == BODY_STRENGTH_CEILING
    check BODY_PROXIMITY_MAX == BODY_FORCE_CEILING
    check BODY_ENCLOSURE_MAX == BODY_FORCE_CEILING
    check BODY_PROXIMITY_MIN == -BODY_FORCE_CEILING
    check BODY_ENCLOSURE_MIN == -BODY_FORCE_CEILING
    check BODY_BAND_MIN == BODY_BAND_FLOOR
    check BODY_BAND_MAX == BODY_BAND_CEILING
    check BODY_RADIUS_MIN == BODY_RADIUS_FLOOR
    check BODY_RADIUS_MAX == BODY_RADIUS_CEILING
    check BODY_ANISOTROPY_MAX == BODY_ANISOTROPY_CEILING
    var strongest = 0.0
    for run in sweep:
      strongest = max(strongest, run.peakSpeed)
    check strongest > 0.0

  test "no reachable crowd carries a body past the ceiling its cap and damping set":
    # The stability claim itself, against the closed-form sum rather than
    # against anything the step computes. Whatever the crowd, whatever the
    # coordinate, the speed stays under the geometric ceiling; that is what
    # makes the loop bounded rather than merely slow to diverge.
    var breached = 0
    var worst = ""
    for run in sweep:
      let speedCeiling = reachableCeiling(BODY_MAX_SPEED_CHANGE,
        BODY_LARGEST_FRAME_FACTOR / run.substeps.float)
      let spinCeiling = reachableCeiling(BODY_MAX_SPIN_CHANGE,
        BODY_LARGEST_FRAME_FACTOR / run.substeps.float)
      # The sum is attained in the limit, so the comparison carries a
      # relative epsilon rather than testing a float against its own limit.
      if not run.finite or run.peakSpeed > speedCeiling * 1.000001 or
          run.peakSpin > spinCeiling * 1.000001:
        inc breached
        if worst.len == 0:
          worst = &"{run.describe} against ceilings {speedCeiling:.4f} / " &
            &"{spinCeiling:.6f}"
    if breached > 0:
      checkpoint(&"{breached} of {sweep.len} runs passed the ceiling; " &
        &"first: {worst}")
    check breached == 0

  test "a run still gaining at its end is a transient the clock closes":
    # The control that separates a slow transient from a divergence: run the
    # same coordinate four times as long. A transient's half-to-half growth
    # shrinks as the window widens, because the thing that was still rising has
    # finished rising; a divergence's does not, because there is nothing for it
    # to finish. The tolerance below is met by the great majority of the space
    # outright, and this is what earns the rest.
    var gaining: seq[CrowdRun] = @[]
    for run in sweep:
      if not run.settled:
        gaining.add run
    checkpoint(&"{gaining.len} of {sweep.len} runs were still gaining at " &
      &"{SWEEP_FRAMES} frames")
    check gaining.len * 10 < sweep.len
    for run in gaining:
      let longer = runCrowdPush(run.crowd, run.strength, run.proximity,
        run.enclosure, run.band, run.radius, run.anisotropy, run.substeps,
        frames = SWEEP_FRAMES * 4)
      let ceilingAt = reachableCeiling(BODY_MAX_SPEED_CHANGE,
        BODY_LARGEST_FRAME_FACTOR / run.substeps.float)
      let spinCeilingAt = reachableCeiling(BODY_MAX_SPIN_CHANGE,
        BODY_LARGEST_FRAME_FACTOR / run.substeps.float)
      checkpoint("four times as long: " & longer.describe)
      check longer.finite
      check longer.peakSpeed <= ceilingAt * 1.000001
      check longer.peakSpin <= spinCeilingAt * 1.000001
      check longer.settled

  test "the substep count moves the reachable ceiling by less than a factor of two":
    # The ceiling is not perfectly substep-invariant and cannot be: damping is
    # applied after each substep, so an impulse delivered early in a finely cut
    # frame is damped more times than the same impulse delivered whole. The
    # claim is that the difference stays small enough that turning the fluid's
    # substeps up does not read as restrengthening the bodies coupling.
    let whole = reachableCeiling(BODY_MAX_SPEED_CHANGE,
      BODY_LARGEST_FRAME_FACTOR)
    let cut = reachableCeiling(BODY_MAX_SPEED_CHANGE,
      BODY_LARGEST_FRAME_FACTOR / float(SPH_MAX_SUBSTEPS))
    check whole > 0.0
    check max(whole, cut) / min(whole, cut) < 2.0

suite "An Enclosing Body Cannot Be Tunnelled":
  # The band floor's warrant. It is a relation, not a choice: the fastest
  # particle the world admits must land on the enclosure ramp on the substep
  # that carries it across the surface, or it meets the wall at full strength
  # as a step in the force.
  #
  # NOTE ON WHAT "TUNNELLED" MEANS HERE. Enclosure saturates rather than
  # vanishing past the band (design D4's `saturate`), so an escaped particle is
  # always brought back however far it got — escape is not the failure a
  # narrower band buys. Skipping the ramp is.

  const RADIUS = 400.0

  func wall(band: float): Body =
    ## A body that holds particles in, at the narrowest band under test.
    let masses = bodyInverseMasses(RADIUS, 1.0)
    Body(centerX: BODY_WORLD_W * 0.5, centerY: BODY_WORLD_H * 0.5,
      radius: RADIUS, anisotropy: 1.0, bandWidth: band, proximity: 0.0,
      enclosure: BODY_FORCE_CEILING,
      invMass: masses.invMass, invInertia: masses.invInertia)

  proc crossingDepth(band: float): float =
    ## How far outside the surface the fastest particle lands on the substep
    ## that carries it across, as a multiple of the band. Below one it is on
    ## the ramp; at or above one it has skipped the ramp.
    let body = wall(band)
    # A particle a hair inside the surface, travelling straight out at the
    # speed the range caps it at, over the longest substep the app can run.
    let startX = body.centerX + RADIUS - 1e-6
    let landedX = startX +
      BODY_PARTICLE_SPEED_CEILING * BODY_LARGEST_SUBSTEP_DT
    let landed = sampleBody(body, landedX, body.centerY,
      BODY_WORLD_W, BODY_WORLD_H)
    landed.distance / band

  test "the band floor is the travel of the fastest particle in the longest substep":
    # DERIVED, stated as an executable relation rather than as a comment: a
    # change to the speed ceiling or the frame cap that leaves this constant
    # behind fails here.
    check BODY_BAND_FLOOR ==
      BODY_PARTICLE_SPEED_CEILING * BODY_LARGEST_SUBSTEP_DT
    check BODY_BAND_FLOOR > 0.0
    check BODY_BAND_FLOOR < BODY_BAND_CEILING

  test "the fastest particle crossing an enclosing surface lands on the ramp":
    # Passes at the derived floor.
    check crossingDepth(BODY_BAND_FLOOR) < 1.0
    # And the force it meets there is a fraction of the wall, not the whole of
    # it: the ramp did its job.
    let body = wall(BODY_BAND_FLOOR)
    let landedX = body.centerX + RADIUS - 1e-6 +
      BODY_PARTICLE_SPEED_CEILING * BODY_LARGEST_SUBSTEP_DT
    let met = bodyForceAt(body, landedX, body.centerY,
      BODY_WORLD_W, BODY_WORLD_H, 1.0, 1.0)
    check abs(met.x) > 0.0
    check abs(met.x) < body.enclosure

  test "at half the derived floor the same particle skips the ramp":
    # Fails at half of it, which is what makes the floor a bound rather than a
    # preference. At half the band the crossing lands past the ramp's end and
    # the particle meets the wall at its full strength in one step.
    check crossingDepth(BODY_BAND_FLOOR * 0.5) >= 1.0
    let body = wall(BODY_BAND_FLOOR * 0.5)
    let landedX = body.centerX + RADIUS - 1e-6 +
      BODY_PARTICLE_SPEED_CEILING * BODY_LARGEST_SUBSTEP_DT
    let met = bodyForceAt(body, landedX, body.centerY,
      BODY_WORLD_W, BODY_WORLD_H, 1.0, 1.0)
    check abs(abs(met.x) - body.enclosure) < EPSILON_LOOSE

suite "The Body Oracle Names The World It Is Measured In":
  const CONFIG_FILE = "src" / "config.nim"

  proc worldExtent(name: string): float =
    ## The world dimension config.nim declares, read from source. body_core is
    ## pure and cannot import config.nim, which carries FFI pragmas, so the
    ## world this suite measures in is checked against the shipped one rather
    ## than assumed. Precedent: tests/test_field_core.nim reads it the same way.
    result = -1.0
    if not fileExists(CONFIG_FILE): return
    for line in readFile(CONFIG_FILE).splitLines():
      if line.startsWith("let " & name & "*"):
        return parseFloat(line.rsplit('=', 1)[1].strip())

  proc frameDeltaCap(): float =
    ## The largest raw frame delta src/app.nim will act on, read from source.
    ## The oracle cannot import app.nim — it is the JS entry point — so the
    ## premise is checked against the line that states it rather than assumed.
    result = -1.0
    const LOOP_FILE = "src" / "app.nim"
    if not fileExists(LOOP_FILE): return
    for line in readFile(LOOP_FILE).splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("let cappedDt = if rawDt >"):
        return parseFloat(trimmed.split(':', 1)[0].rsplit('>', 1)[1].strip())

  test "the premises the accumulator and the band floor rest on are the app's":
    # FOUR PREMISES, each held here rather than restated in a comment: the
    # particle speed ceiling, the longest frame, the substep ceiling, and the
    # reference frame. Any of them moving re-runs the stability sweep and
    # re-derives the band floor.
    check BODY_PARTICLE_SPEED_CEILING == MAX_VELOCITY_MAX
    check frameDeltaCap() > 0.0
    check BODY_LARGEST_SUBSTEP_DT == frameDeltaCap() * TIME_SCALE_MAX
    check BODY_LARGEST_FRAME_FACTOR ==
      BODY_LARGEST_SUBSTEP_DT / FRAME_DT_REFERENCE
    # One substep takes the whole frame, which is what makes the substep above
    # the largest one the executor can produce.
    check SPH_SUBSTEPS_MIN == 1
    check SPH_SUBSTEPS_MAX == SPH_MAX_SUBSTEPS

  test "the world this suite measures in is the world the app runs":
    check worldExtent("WORLD_W") > 0.0
    check worldExtent("WORLD_H") > 0.0
    check worldExtent("WORLD_W") == BODY_WORLD_W
    check worldExtent("WORLD_H") == BODY_WORLD_H
    # The lever-arm bound the torque accumulator is sized against is that
    # world's half-diagonal and nothing else.
    check abs(BODY_WORLD_HALF_DIAGONAL -
      0.5 * sqrt(worldExtent("WORLD_W") * worldExtent("WORLD_W") +
        worldExtent("WORLD_H") * worldExtent("WORLD_H"))) < EPSILON_EXACT
