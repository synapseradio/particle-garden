## The parametric-body oracle: the analytic surface, the envelope, the two force
## laws, the reaction a body receives, the slot allocator and the rigid step.
##
## src/body_core.nim is the pure mirror web/shaders/src/body-force.wgsl and
## web/shaders/src/body-integrate.wgsl are written against, so every expectation
## here comes from somewhere other than the functions under test: the isotropic
## circle in closed form, Newton's third law, the lifetime argument itself, and
## symmetry.

import std/[unittest, math, os, strutils]
import ../src/body_core
import ../src/memory_layout

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
    var body = pushable(1.0, 0.0)
    body.centerX = TEST_WORLD_W - 2.0
    body.velX = 6.0
    let moved = bodyRigidStep(body, 0.0, 0.0, 0.0, 1.0, WORLD_W, WORLD_H)
    check moved.centerX >= 0.0
    check moved.centerX < TEST_WORLD_W
    check moved.centerX < 10.0

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
