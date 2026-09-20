## The parametric-body oracle: the analytic surface, the envelope, the two force
## laws, the reaction a body receives, the slot allocator and the rigid step.
##
## src/body_core.nim is the pure mirror web/shaders/src/body-force.wgsl and
## web/shaders/src/body-integrate.wgsl are written against, so every expectation
## here comes from somewhere other than the functions under test: the isotropic
## circle in closed form, Newton's third law, the lifetime argument itself, and
## symmetry.

import std/[unittest, math, options, os, strutils, strformat]
import ../src/body_core
import ../src/memory_layout
import ../src/physics_core
import ../src/config_ranges
import ../src/sim_registry

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

  test "enclosure fades to zero over a second band past the band edge":
    # ORACLE: the ease itself at its midpoint, smoothstep(0.5) = 0.5, so half a
    # band past the edge carries half the peak; two bands out it carries none.
    let body = shaped(0.0, 5.0)
    let (edgeX, edgeY) = atRadius(body, BAND)
    let (midX, midY) = atRadius(body, BAND * 1.5)
    let (endX, endY) = atRadius(body, BAND * 2.0)
    let atEdge = bodyForceAt(body, edgeX, edgeY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0)
    let midway = bodyForceAt(body, midX, midY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0)
    let atEnd = bodyForceAt(body, endX, endY, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0)
    check abs(atEdge.x + body.enclosure) < EPSILON_LOOSE
    check abs(midway.x - atEdge.x * 0.5) < EPSILON_LOOSE
    check atEnd.x == 0.0

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

  # ORACLE for the reach tests: the stated reach, twice the band in the
  # evaluation's own distance, and nothing bodyForceAt computes.
  test "a positive hold moves no particle beyond twice its band":
    let body = shaped(BODY_FORCE_CEILING, BODY_FORCE_CEILING)
    for offset in [BAND * 2.0, BAND * 2.0 + 1.0, BAND * 5.0,
        TEST_WORLD_W * 0.5 - RADIUS]:
      let (px, py) = atRadius(body, offset)
      let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
        1.0, 1.0)
      checkpoint(&"outside the surface by {offset:.0f}: force {force.x:.4f}")
      check force.x == 0.0
      check force.y == 0.0

  test "a negative hold moves nothing at twice its band inside the surface or deeper":
    # The body is wider than the deepest depth sampled, so every point below
    # lies inside it on the same side of the centre.
    var body = shaped(BODY_FORCE_CEILING, -BODY_FORCE_CEILING)
    body.radius = BODY_RADIUS_CEILING
    for depth in [BAND * 2.0, BAND * 2.0 + 1.0, BAND * 3.0,
        BODY_RADIUS_CEILING - 10.0]:
      let force = bodyForceAt(body, body.centerX + body.radius - depth,
        body.centerY, TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0)
      checkpoint(&"inside the surface by {depth:.0f}: force {force.x:.4f}")
      check force.x == 0.0
      check force.y == 0.0

  test "a hold reaches across a world edge no farther than twice its band":
    # A body one band from the right edge: its outward side lies across the
    # seam, so each particle below sits at the far left of the world and is
    # reached only through the minimum image.
    var body = shaped(BODY_FORCE_CEILING, BODY_FORCE_CEILING)
    body.centerX = TEST_WORLD_W - BAND
    for offset in [BAND * 2.0, BAND * 2.0 + 1.0, BAND * 3.0]:
      let px = wrapToTorus(body.centerX + RADIUS + offset, TEST_WORLD_W)
      check px < body.centerX - TEST_WORLD_W * 0.5
      let force = bodyForceAt(body, px, body.centerY, TEST_WORLD_W,
        TEST_WORLD_H, 1.0, 1.0)
      checkpoint(&"across the seam by {offset:.0f}: force {force.x:.4f}")
      check force.x == 0.0
      check force.y == 0.0

  test "an elongated hold reaches its band times its elongation along the long axis":
    # Radius 100 and band 50 keep the long semi-axis plus the reach (800)
    # inside half the world's height, so the minimum image never wraps the
    # shell onto the body's far side. Along the long axis the evaluated
    # distance is the true one divided by the elongation.
    const ELONGATED_RADIUS = 100.0
    const ELONGATED_BAND = 50.0
    let body = Body(centerX: 1920.0, centerY: 1080.0, radius: ELONGATED_RADIUS,
      anisotropy: BODY_ANISOTROPY_CEILING, bandWidth: ELONGATED_BAND,
      proximity: BODY_FORCE_CEILING, enclosure: BODY_FORCE_CEILING,
      invMass: 1.0, invInertia: 1.0)
    let longSemiAxis = ELONGATED_RADIUS * BODY_ANISOTROPY_CEILING
    let trueReach = 2.0 * ELONGATED_BAND * BODY_ANISOTROPY_CEILING
    check body.centerY + longSemiAxis + trueReach * 1.25 <
      body.centerY + TEST_WORLD_H * 0.5
    for beyond in [trueReach, trueReach + 1.0, trueReach * 1.25]:
      let force = bodyForceAt(body, body.centerX,
        body.centerY + longSemiAxis + beyond, TEST_WORLD_W, TEST_WORLD_H,
        1.0, 1.0)
      checkpoint(&"along the long axis by {beyond:.0f}: force {force.y:.4f}")
      check force.x == 0.0
      check force.y == 0.0
    # Just inside the reach in evaluated distance: still held.
    let justInside = (2.0 * ELONGATED_BAND - 1.0) * BODY_ANISOTROPY_CEILING
    let held = bodyForceAt(body, body.centerX,
      body.centerY + longSemiAxis + justInside, TEST_WORLD_W, TEST_WORLD_H,
      1.0, 1.0)
    check held.y < 0.0

  test "enclosure peaks at the band edge":
    let body = shaped(0.0, BODY_FORCE_CEILING)
    proc outward(offset: float): float =
      let (px, py) = atRadius(body, offset)
      bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0).x
    check abs(outward(BAND) + body.enclosure) < EPSILON_LOOSE
    checkpoint(&"at 0.9 bands {outward(BAND * 0.9):.4f}, at the edge " &
      &"{outward(BAND):.4f}, at 1.1 bands {outward(BAND * 1.1):.4f}")
    check abs(outward(BAND * 0.9)) < abs(outward(BAND))
    check abs(outward(BAND * 1.1)) < abs(outward(BAND))

  test "enclosure meets the surface, the band edge and the reach end without a corner":
    # The ratio the proximity edge test uses: a linear ramp moves one percent
    # of the strength over one percent of a band, an ease with zero slope three
    # parts in ten thousand.
    let body = shaped(0.0, BODY_FORCE_CEILING)
    proc outward(offset: float): float =
      let (px, py) = atRadius(body, offset)
      bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H, 1.0, 1.0).x
    let nearby = BAND * 0.01
    # Each point, with the side of it on which the hold acts.
    for (named, at, beside) in [("surface", 0.0, nearby),
        ("band edge, inner side", BAND, BAND - nearby),
        ("band edge, outer side", BAND, BAND + nearby),
        ("reach end", BAND * 2.0, BAND * 2.0 - nearby)]:
      let moved = abs(outward(beside) - outward(at))
      checkpoint(&"{named}: moves {moved:.6f} over a hundredth of a band")
      check moved < 0.001 * body.enclosure

  test "proximity and enclosure at the ceiling never sum past one ceiling":
    const SAMPLES = 400
    for proximity in [-BODY_FORCE_CEILING, BODY_FORCE_CEILING]:
      for enclosure in [-BODY_FORCE_CEILING, BODY_FORCE_CEILING]:
        let body = shaped(proximity, enclosure)
        var worst = 0.0
        var worstAt = 0.0
        for sample in 0 .. SAMPLES:
          let offset = -2.0 * BAND + 4.0 * BAND * sample.float / SAMPLES.float
          let (px, py) = atRadius(body, offset)
          let force = bodyForceAt(body, px, py, TEST_WORLD_W, TEST_WORLD_H,
            1.0, 1.0)
          let size = sqrt(force.x * force.x + force.y * force.y)
          if size > worst:
            worst = size
            worstAt = offset
        checkpoint(&"proximity {proximity:.0f}, enclosure {enclosure:.0f}: " &
          &"largest {worst:.4f} at {worstAt:.0f} from the surface")
        check worst <= BODY_FORCE_CEILING + EPSILON_LOOSE

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

suite "The World Lights Bodies On A Cadence Of Its Own":
  # ORACLE: the rate, in bodies per second, and arithmetic on the clock. The
  # cadence takes that rate and a wall-clock delta and nothing else — no
  # coupling strength appears anywhere in this suite because none reaches the
  # generator: a body lit into a world at zero strength costs a slot and moves
  # nothing, and acts() is the only place a strength is read against zero.

  proc drawSequence(seed: uint64; count: int): seq[BodyDraw] =
    var generator = initBodyGenerator(seed)
    for index in 0 ..< count:
      result.add generator.drawIgnition()

  test "a rate of zero lights nothing however long the clock runs":
    var generator = initBodyGenerator(BODY_GENERATOR_SEED)
    for tick in 0 ..< 10_000:
      check generator.worldIgnition(0.0, 0.05).isNone

  test "the world lights a body every interval and never twice in one":
    for rate in [0.25, 1.0, BODY_IGNITION_RATE_MAX]:
      var generator = initBodyGenerator(BODY_GENERATOR_SEED)
      const DT = 1.0 / 64.0  # exact in binary, so the clock below is too
      let interval = 1.0 / rate
      var clock = 0.0
      var lastFire = 0.0
      var fires = 0
      for tick in 0 ..< 3840:  # a minute at that step
        clock += DT
        if generator.worldIgnition(rate, DT).isSome:
          checkpoint("rate " & $rate)
          check clock - lastFire >= interval
          check clock - lastFire < interval + DT
          lastFire = clock
          inc fires
      check fires > 0

  test "a body lit by hand restarts the cadence":
    # The world does not fire on top of a gesture: the next interval counts from
    # the body just lit, whoever lit it.
    var generator = initBodyGenerator(BODY_GENERATOR_SEED)
    const RATE = 1.0
    const DT = 0.25
    for tick in 0 ..< 3:
      check generator.worldIgnition(RATE, DT).isNone
    discard generator.drawIgnition()
    for tick in 0 ..< 3:
      check generator.worldIgnition(RATE, DT).isNone
    check generator.worldIgnition(RATE, DT).isSome

  test "one seed replays the same bodies and two seeds part ways":
    check drawSequence(BODY_GENERATOR_SEED, 16) ==
      drawSequence(BODY_GENERATOR_SEED, 16)
    check drawSequence(BODY_GENERATOR_SEED, 16) !=
      drawSequence(BODY_GENERATOR_SEED + 1, 16)

  test "every body the world draws lands in the world and inside the bounds":
    for draw in drawSequence(BODY_GENERATOR_SEED, 512):
      check draw.atX >= 0.0
      check draw.atX < BODY_WORLD_W
      check draw.atY >= 0.0
      check draw.atY < BODY_WORLD_H
      check draw.shaping.anisotropy >= BODY_ANISOTROPY_MIN
      check draw.shaping.anisotropy <= BODY_ANISOTROPY_MAX
      check draw.shaping.envelopeSkew >= BODY_ENVELOPE_SKEW_MIN
      check draw.shaping.envelopeSkew <= BODY_ENVELOPE_SKEW_MAX
      check draw.shaping.sustain >= BODY_SUSTAIN_MIN
      check draw.shaping.sustain <= BODY_SUSTAIN_MAX


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

const CROWD_SAMPLES = 24
  ## A crowd is carried by this many weighted samples rather than by
  ## MAX_PARTICLES individuals: a body reads only the SUM of the reactions,
  ## and a sample standing for `crowd / CROWD_SAMPLES` particles at one point
  ## contributes exactly what those particles would if they were together.
  ## Together is the worst case — spread out they cancel — so a run measures
  ## the coherent crowd and covers the scattered one.
const LARGEST_FRAME_SECONDS = 0.05 * TIME_SCALE_MAX
  ## The longest frame the executor can be handed: src/app.nim caps a raw frame
  ## delta at 0.05 s and multiplies by the time scale, whose ceiling is
  ## TIME_SCALE_MAX. Held against app.nim's own line by the premises test below.
const LARGEST_FRAME_FACTOR = LARGEST_FRAME_SECONDS / FRAME_DT_REFERENCE
  ## That frame as a multiple of the reference frame every force constant in
  ## body_core was measured against.

const SWEEP_FRAMES = 480
  ## Rendered frames per closed-loop run. At the largest frame that is 40
  ## seconds of wall clock, long enough that a body under a steady crowd
  ## reaches its terminal speed several times over and a divergent one has
  ## left the world.

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
  #   4. the substep ceiling, config_ranges' SUBSTEPS_MAX, and the largest frame
  #      LARGEST_FRAME_FACTOR states
  #
  # Every run is at the WORST reachable frame: LARGEST_FRAME_FACTOR
  # reference frames of impulse per rendered frame, cut into `substeps` pieces.
  # A shorter frame is strictly gentler on an explicit step, so a bound earned
  # here covers every frame the app can run.

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
    # reactions add instead of cancelling, and spanning from 0.9 of a band
    # inside to 1.9 outside, so both force laws act and the hold's falloff is
    # measured.
    var px, py, vx, vy: array[CROWD_SAMPLES, float]
    for sample in 0 ..< CROWD_SAMPLES:
      let bearing = -0.5 + sample.float / (CROWD_SAMPLES - 1).float
      let reach = radius - band * 0.9 +
        2.8 * band * ((sample.float * 0.6180339887) mod 1.0)
      px[sample] = body.centerX + reach * cos(bearing)
      py[sample] = body.centerY + reach * sin(bearing)
    # Two clocks, as the step keeps them: seconds for travel, reference frames
    # for the impulse integrate delivers and for the damping.
    let substepSeconds = LARGEST_FRAME_SECONDS / substeps.float
    let substepFrames = LARGEST_FRAME_FACTOR / substeps.float
    var speeds = newSeq[float](frames)
    var spins = newSeq[float](frames)
    for frame in 0 ..< frames:
      for _ in 0 ..< substeps:
        var accumulator = BodyAccumulator()
        for sample in 0 ..< CROWD_SAMPLES:
          let atX = px[sample]
          let atY = py[sample]
          let impulse = bodyForceAt(body, atX, atY,
            BODY_WORLD_W, BODY_WORLD_H, 1.0, strength)
          # Action and reaction are taken at the SAME point, which is what
          # body-force.wgsl does by construction: one invocation evaluates the
          # body once at the particle it holds. Taking the lever arm after the
          # particle moved would invent a torque on a circle, whose force is
          # radial and whose torque is therefore exactly zero.
          accumulator.addBodyReaction(body, atX, atY,
            BODY_WORLD_W, BODY_WORLD_H, impulse.x * weight, impulse.y * weight)
          vx[sample] = vx[sample] + impulse.x * substepFrames
          vy[sample] = vy[sample] + impulse.y * substepFrames
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
            for band in [BODY_BAND_MIN, BODY_BAND_CEILING]:
              for radius in [BODY_RADIUS_FLOOR, BODY_RADIUS_CEILING]:
                for anisotropy in [1.0, BODY_ANISOTROPY_CEILING]:
                  for substeps in [1, SUBSTEPS_MAX]:
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
        LARGEST_FRAME_FACTOR / run.substeps.float)
      let spinCeiling = reachableCeiling(BODY_MAX_SPIN_CHANGE,
        LARGEST_FRAME_FACTOR / run.substeps.float)
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
        LARGEST_FRAME_FACTOR / run.substeps.float)
      let spinCeilingAt = reachableCeiling(BODY_MAX_SPIN_CHANGE,
        LARGEST_FRAME_FACTOR / run.substeps.float)
      checkpoint("four times as long: " & longer.describe)
      check longer.finite
      check longer.peakSpeed <= ceilingAt * 1.000001
      check longer.peakSpin <= spinCeilingAt * 1.000001
      check longer.settled

  test "the substep count moves the reachable ceiling by less than a factor of two":
    # The ceiling is not perfectly substep-invariant and cannot be: damping is
    # applied after each substep, so an impulse delivered early in a finely cut
    # frame is damped more times than the same impulse delivered whole. The
    # claim is that the difference stays small enough that a frame the plan
    # cuts finely does not read as restrengthening the bodies coupling.
    let whole = reachableCeiling(BODY_MAX_SPEED_CHANGE,
      LARGEST_FRAME_FACTOR)
    let cut = reachableCeiling(BODY_MAX_SPEED_CHANGE,
      LARGEST_FRAME_FACTOR / float(SUBSTEPS_MAX))
    check whole > 0.0
    check max(whole, cut) / min(whole, cut) < 2.0

suite "A Body Is Blind Past Its Reach":
  # ORACLE: the stated reach. A particle more than twice the band from a
  # body's surface neither receives anything from it nor hands it anything
  # back, so a crowd out there cannot move it however large.
  const SEPARATION = 1200.0
    ## Far enough apart at the default radius and band that the two reach
    ## shells (240 + 2 * 120 each side) leave a 240-wide gap between them.
  const CLUMP_SPREAD = 40.0

  func holding(centerX: float): Body =
    let masses = bodyInverseMasses(BODY_DEFAULT_RADIUS, 1.0)
    Body(centerX: centerX, centerY: BODY_WORLD_H * 0.5,
      radius: BODY_DEFAULT_RADIUS, anisotropy: 1.0,
      bandWidth: BODY_DEFAULT_BAND, proximity: BODY_DEFAULT_PROXIMITY,
      enclosure: BODY_FORCE_CEILING,
      invMass: masses.invMass, invInertia: masses.invInertia)

  type PairRun = object
    startA, startB, endA, endB: Body
    fastestA, fastestB: float     ## Largest speed either body reached.
    firstFrameVelA: float         ## Body A's x velocity after frame one.
    clumpImpulse: float           ## Summed magnitude the clump received.

  proc runPairAgainstClump(clumpX: float): PairRun =
    ## Two holding bodies and one weighted clump, the loop closed at the
    ## largest frame in the shape of the stability sweep's runCrowdPush.
    var bodies = [holding(BODY_WORLD_W * 0.5 - SEPARATION * 0.5),
      holding(BODY_WORLD_W * 0.5 + SEPARATION * 0.5)]
    result.startA = bodies[0]
    result.startB = bodies[1]
    let weight = MAX_PARTICLES.float / CROWD_SAMPLES.float
    var px, py, vx, vy: array[CROWD_SAMPLES, float]
    for sample in 0 ..< CROWD_SAMPLES:
      let bearing = TAU * sample.float / CROWD_SAMPLES.float
      let spread = CLUMP_SPREAD * ((sample.float * 0.6180339887) mod 1.0)
      px[sample] = clumpX + spread * cos(bearing)
      py[sample] = BODY_WORLD_H * 0.5 + spread * sin(bearing)
    let strength = BODY_STRENGTH_CEILING
    for frame in 0 ..< SWEEP_FRAMES:
      var accumulators: array[2, BodyAccumulator]
      for sample in 0 ..< CROWD_SAMPLES:
        for slot in 0 .. 1:
          let impulse = bodyForceAt(bodies[slot], px[sample], py[sample],
            BODY_WORLD_W, BODY_WORLD_H, 1.0, strength)
          accumulators[slot].addBodyReaction(bodies[slot], px[sample],
            py[sample], BODY_WORLD_W, BODY_WORLD_H, impulse.x * weight,
            impulse.y * weight)
          vx[sample] += impulse.x * LARGEST_FRAME_FACTOR
          vy[sample] += impulse.y * LARGEST_FRAME_FACTOR
          result.clumpImpulse += (abs(impulse.x) + abs(impulse.y)) *
            LARGEST_FRAME_FACTOR
        px[sample] = wrapToTorus(px[sample] + vx[sample] *
          LARGEST_FRAME_SECONDS, BODY_WORLD_W)
        py[sample] = wrapToTorus(py[sample] + vy[sample] *
          LARGEST_FRAME_SECONDS, BODY_WORLD_H)
      for slot in 0 .. 1:
        let received = accumulators[slot].decoded()
        bodies[slot] = bodyRigidStep(bodies[slot], received.forceX,
          received.forceY, received.torque, LARGEST_FRAME_SECONDS,
          BODY_WORLD_W, BODY_WORLD_H)
      if frame == 0:
        result.firstFrameVelA = bodies[0].velX
      result.fastestA = max(result.fastestA, sqrt(bodies[0].velX *
        bodies[0].velX + bodies[0].velY * bodies[0].velY))
      result.fastestB = max(result.fastestB, sqrt(bodies[1].velX *
        bodies[1].velX + bodies[1].velY * bodies[1].velY))
    result.endA = bodies[0]
    result.endB = bodies[1]

  test "two holding bodies stay put when the crowd lies beyond both reaches":
    let reach = BODY_DEFAULT_RADIUS + 2.0 * BODY_DEFAULT_BAND
    let clumpX = BODY_WORLD_W * 0.5
    let run = runPairAgainstClump(clumpX)
    # The clump's nearest point is outside both shells.
    check clumpX - CLUMP_SPREAD - run.startA.centerX > reach
    check run.startB.centerX - (clumpX + CLUMP_SPREAD) > reach
    checkpoint(&"fastest {run.fastestA:.4f} / {run.fastestB:.4f}, clump " &
      &"impulse {run.clumpImpulse:.4f}, ends at {run.endA.centerX:.2f} / " &
      &"{run.endB.centerX:.2f}")
    check run.fastestA == 0.0
    check run.fastestB == 0.0
    check run.endB.centerX - run.endA.centerX ==
      run.startB.centerX - run.startA.centerX
    check run.clumpImpulse == 0.0

  test "a crowd inside one body's reach moves that body toward it":
    # The control: the same rig sees motion once the clump sits a band outside
    # body A's surface, inside its reach.
    let run = runPairAgainstClump(BODY_WORLD_W * 0.5 - SEPARATION * 0.5 +
      BODY_DEFAULT_RADIUS + BODY_DEFAULT_BAND)
    check run.firstFrameVelA > 0.0
    check run.endA.centerX > run.startA.centerX

  test "overlapping bodies add and a body out of reach adds nothing":
    let first = holding(1500.0)
    let second = holding(2340.0)
    # Out of reach: its surface lies over a thousand units from the particle.
    let third = holding(600.0)
    let atX = 1900.0
    let atY = BODY_WORLD_H * 0.5 + 70.0
    let fromFirst = bodyForceAt(first, atX, atY, BODY_WORLD_W, BODY_WORLD_H,
      1.0, 1.0)
    let fromSecond = bodyForceAt(second, atX, atY, BODY_WORLD_W,
      BODY_WORLD_H, 1.0, 1.0)
    let fromThird = bodyForceAt(third, atX, atY, BODY_WORLD_W, BODY_WORLD_H,
      1.0, 1.0)
    checkpoint(&"out of reach: ({fromThird.x:.4f}, {fromThird.y:.4f})")
    check fromThird.x == 0.0
    check fromThird.y == 0.0
    check abs(fromFirst.x) + abs(fromFirst.y) > 0.0
    check abs(fromSecond.x) + abs(fromSecond.y) > 0.0
    # Summed in slot order, as body-force.wgsl's loop sums.
    var totalX = 0.0
    var totalY = 0.0
    for force in [fromFirst, fromSecond, fromThird]:
      totalX = totalX + force.x
      totalY = totalY + force.y
    check totalX == fromFirst.x + fromSecond.x
    check totalY == fromFirst.y + fromSecond.y

suite "An Enclosing Body Cannot Be Tunnelled":
  # The band floor's warrant. It is a relation, not a choice: the fastest
  # particle the world admits must land on the enclosure ramp on the substep
  # substepPlan runs, or it meets the wall at full strength as a step in the
  # force.
  #
  # NOTE ON WHAT "TUNNELLED" MEANS HERE. The hold peaks at the band edge and is
  # gone at twice the band, so a particle carried past the reach in one substep
  # is let go: skipping the ramp is skipping the hold entirely.

  const RADIUS = 400.0

  func wall(band: float): Body =
    ## A body that holds particles in, at the narrowest band under test.
    let masses = bodyInverseMasses(RADIUS, 1.0)
    Body(centerX: BODY_WORLD_W * 0.5, centerY: BODY_WORLD_H * 0.5,
      radius: RADIUS, anisotropy: 1.0, bandWidth: band, proximity: 0.0,
      enclosure: BODY_FORCE_CEILING,
      invMass: masses.invMass, invInertia: masses.invInertia)

  proc wallLandedX(body: Body; maxVelocity, ff: float): float =
    ## Where the fastest particle lands after one substep at substepPlan's
    ## count, starting a hair inside the surface. Travel is the plan's
    ## effective Max Velocity wherever the plan clamps (effMaxVelocity > 0),
    ## the caller's Max Velocity otherwise — the value integrate actually
    ## receives either way.
    let live = LiveValues(bodies: BODIES_DEFAULT_STRENGTH,
      bodyBand: body.bandWidth, bodyLive: true, maxVelocity: maxVelocity)
    let plan = substepPlan(ff, live)
    let ffSub = ff / plan.count.float
    let travelSpeed =
      if plan.effMaxVelocity > 0.0: plan.effMaxVelocity else: maxVelocity
    body.centerX + RADIUS - 1e-6 + travelSpeed * ffSub

  proc crossingDepth(band, maxVelocity, ff: float): float =
    ## How far outside the surface the fastest particle lands on the substep
    ## substepPlan runs, as a multiple of the band. Below one it is on the
    ## ramp; at or above one it has skipped the ramp.
    let body = wall(band)
    let landedX = wallLandedX(body, maxVelocity, ff)
    let landed = sampleBody(body, landedX, body.centerY,
      BODY_WORLD_W, BODY_WORLD_H)
    landed.distance / band

  test "the fastest particle crossing an enclosing surface at the band floor lands on the ramp":
    # At band BODY_BAND_MIN (25), Max
    # Velocity 50 (simulation_state.nim:139) and ff 1, substepPlan's travel
    # count is n_T = ceil(50 * 1 / 25) = 2, so the substep runs at ff_sub =
    # 1/2 and travels 50 * 0.5 = 25, the band exactly.
    #
    # Against the stub, count is always 1: ff_sub stays 1 and one step
    # carries the particle 50, twice the band, so this fails for that
    # reason.
    check crossingDepth(BODY_BAND_MIN, 50.0, 1.0) < 1.0
    # And the hold has it there: nothing past the ceiling acts.
    let body = wall(BODY_BAND_MIN)
    let landedX = wallLandedX(body, 50.0, 1.0)
    let met = bodyForceAt(body, landedX, body.centerY,
      BODY_WORLD_W, BODY_WORLD_H, 1.0, 1.0)
    check met.x < 0.0
    check abs(met.x) <= body.enclosure

  test "containment holds below the band floor when the substep count clamps and Max Velocity drops to compensate":
    # At band BODY_BAND_MIN * 0.5 (12.5), Max Velocity 50
    # (simulation_state.nim:139) and ff 1: the travel count is n_T =
    # ceil(50 * 1 / 12.5) = 4, past SUBSTEPS_MAX (3), so the count clamps
    # to 3 and the effective Max Velocity drops to T * 3 / ff =
    # 12.5 * 3 / 1 = 37.5. At ff_sub = 1/3, travel is 37.5 * (1/3) = 12.5,
    # the band exactly: containment holds even though the band sits below
    # the floor.
    #
    # Against the stub, count is always 1 and effMaxVelocity stays 0 (no
    # clamp applied): ff_sub stays 1 and travel is the full Max Velocity,
    # 50, four times the band, so this fails for that reason.
    check crossingDepth(BODY_BAND_MIN * 0.5, 50.0, 1.0) < 1.0

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

  test "the premises the accumulator and the stability sweep rest on are the app's":
    # TWO PREMISES, each held here rather than restated in a comment: the
    # particle speed ceiling and the longest frame the sweep runs at. Either
    # moving re-runs the stability sweep.
    check BODY_PARTICLE_SPEED_CEILING == MAX_VELOCITY_MAX
    check frameDeltaCap() > 0.0
    check LARGEST_FRAME_SECONDS == frameDeltaCap() * TIME_SCALE_MAX

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
