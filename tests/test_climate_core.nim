#
# One parameterised tour, walked by the frame loop, writing every toured
# parameter through the ordinary parameter path. The reaction-diffusion climate
# is one waypoint table on it.
#
# Two properties carry the whole feature, and both are structural rather than
# tuned — which is what these tests pin. If the path can leave the box its
# ranges bound, drift can put the simulation somewhere the sliders cannot
# express; if it can jump, the weather reads as a glitch instead of as weather.
#
# Every guarantee is written once, over any table. The templates below take the
# waypoints and the box, so a weather over different parameters registers its
# table with them and inherits the proofs. Two tables run through them here: the
# reaction-diffusion regimes, and a probe table of a different arity and a
# different scale whose only job is to keep the tour from being specialised
# to feed and kill.

import std/unittest
import ../src/climate_core
import ../src/config_ranges
import ../src/ui/api/param_descriptor

const CLIMATE_CORE_TESTS_LOADED* = true

const
  SWEEP_STEPS = 2000
    ## Phase samples per full-loop sweep. Fine enough that no segment boundary
    ## is stepped over, for any table this suite carries.
  FRAME_SECONDS = 1.0 / 60.0
  HANDOVER_NUDGE = 1e-7
    ## Phase offset either side of a waypoint, far finer than a frame takes.
  EASING_NUDGE = 1e-4
    ## Phase offset for a finite-difference speed reading.
  HANDOVER_TOLERANCE = 1e-5
    ## Positional slack across a handover. Smoothstep's zero end-derivative
    ## makes the real gap second-order in HANDOVER_NUDGE — around 1e-11 at the
    ## widest segment either table carries — so this leaves several orders of
    ## room while still failing a genuine break.

# ------------------------------------------------------------------------------
# The tables, and the boxes their points must stay inside
# ------------------------------------------------------------------------------

const RD_CLIMATE_BOX: array[ClimateAxis, tuple[lo, hi: float]] = [
  caFeed: (lo: RD_FEED_MIN, hi: RD_FEED_MAX),
  caKill: (lo: RD_KILL_MIN, hi: RD_KILL_MAX),
]
  ## The rectangle the climate tours inside, from the range authority. Pairing a
  ## table with its box is all a second weather has to do to be swept here.

type ProbeAxis = enum
  ## Three axes, so the tour's arity comes from the table rather than from the
  ## climate's two. Nothing ships on this enum; it exists to be different.
  pxNarrow
  pxUnit
  pxWide

const PROBE_TOUR: array[4, array[ProbeAxis, float]] = [
  [pxNarrow: -2.0, pxUnit: 0.00, pxWide: 10.0],
  [pxNarrow: -1.0, pxUnit: 0.50, pxWide: 40.0],
  [pxNarrow:  0.0, pxUnit: 0.25, pxWide: 25.0],
  [pxNarrow: -1.5, pxUnit: 0.75, pxWide: 55.0],
]
  ## A table sharing no constant, no arity and no scale with the climate: four
  ## waypoints, one axis entirely negative, one spanning a factor of fifty. A
  ## tour that assumes feed and kill — their count, their sign, or their
  ## magnitude — fails on this table and passes on the climate's.

const PROBE_BOX: array[ProbeAxis, tuple[lo, hi: float]] = [
  pxNarrow: (lo: -2.0, hi: 0.0),
  pxUnit: (lo: 0.0, hi: 1.0),
  pxWide: (lo: 10.0, hi: 60.0),
]

const PROBE_MAX_STEPS: array[ProbeAxis, float] = [
  pxNarrow: 0.01,
  pxUnit: 0.005,
  pxWide: 0.2,
]
  ## What each probe axis's widest segment can carry at CLIMATE_SPEED_MAX.
  ## Smoothstep peaks at 1.5x the average slope, so the fastest frame moves
  ## 1.5 * segment * waypoints * speed / 3600 — for pxWide's 45 units, about
  ## 0.15. Stated per axis because pxWide spans fifty times what pxUnit spans,
  ## and one number over both would assert nothing about the narrow one.

const FORCE_WEATHER_BOX: array[ForceAxis, tuple[lo, hi: float]] = [
  fxStrength: (lo: FORCE_STRENGTH_MIN, hi: FORCE_STRENGTH_MAX),
  fxRadius: (lo: INTERACTION_RADIUS_MIN.float, hi: INTERACTION_RADIUS_MAX.float),
  fxFriction: (lo: FRICTION_MIN, hi: FRICTION_MAX),
]
  ## The box the force weather tours inside, from the range authority. Pairing a
  ## table with its box is all a second weather has to do to be swept here, and
  ## this is the weather that proves that claim rather than asserting it.

# ------------------------------------------------------------------------------
# The guarantees, written once and run over every table
# ------------------------------------------------------------------------------

template checkSamePoint(lhs, rhs, tolerance: untyped) =
  for axis in lhs.low .. lhs.high:
    check abs(lhs[axis] - rhs[axis]) <= tolerance

template checkStaysInsideBox(waypoints, box: untyped) =
  ## IN RANGE by convexity: every point is a convex combination of two
  ## waypoints, and a set of ranges is an axis-aligned box.
  for step in 0 .. SWEEP_STEPS:
    let point = tourAt(waypoints, step.float / SWEEP_STEPS.float)
    for axis in point.low .. point.high:
      check point[axis] >= box[axis].lo
      check point[axis] <= box[axis].hi

template checkNoStepExceeds(waypoints, maxSteps, speed: untyped) =
  ## CONTINUOUS at the fastest weather offered, across the whole loop including
  ## every waypoint handover.
  ##
  ## The ceiling arrives per axis. A table whose axes span different scales
  ## cannot state a meaningful one otherwise: the widest axis sets a number the
  ## narrow ones clear no matter what they do, and the sweep stops asserting
  ## anything about them.
  for step in 0 ..< SWEEP_STEPS:
    let phase = step.float / SWEEP_STEPS.float
    let here = tourAt(waypoints, phase)
    let next = tourAt(waypoints, tourAdvance(phase, speed, FRAME_SECONDS))
    for axis in here.low .. here.high:
      check abs(next[axis] - here[axis]) <= maxSteps[axis]

template checkNoJumpAtHandover(waypoints: untyped) =
  ## Segment boundaries are where a piecewise path breaks if it breaks at all.
  for waypoint in 0 ..< waypoints.len:
    let boundary = waypoint.float / waypoints.len.float
    let before = tourAt(waypoints, boundary - HANDOVER_NUDGE)
    let after = tourAt(waypoints, boundary + HANDOVER_NUDGE)
    checkSamePoint(before, after, HANDOVER_TOLERANCE)

template checkEasesAtHandover(waypoints: untyped) =
  ## Smoothstep's derivative is zero at both ends of a segment, so the path
  ## arrives and leaves a waypoint slowly. Plain linear interpolation would be
  ## positionally continuous but visibly corner here, and this is the check that
  ## would notice the easing being dropped for simplicity.
  for waypoint in 0 ..< waypoints.len:
    let boundary = waypoint.float / waypoints.len.float
    let midpoint = (waypoint.float + 0.5) / waypoints.len.float
    let atWaypoint = tourAt(waypoints, boundary + EASING_NUDGE)
    let justAfter = tourAt(waypoints, boundary + 2.0 * EASING_NUDGE)
    let atMid = tourAt(waypoints, midpoint)
    let justAfterMid = tourAt(waypoints, midpoint + EASING_NUDGE)
    var waypointSpeed = 0.0
    var midSpeed = 0.0
    for axis in atMid.low .. atMid.high:
      waypointSpeed += abs(justAfter[axis] - atWaypoint[axis])
      midSpeed += abs(justAfterMid[axis] - atMid[axis])
    check waypointSpeed < midSpeed

template checkLandsOnEveryWaypoint(waypoints: untyped) =
  ## The tour passes through its own table exactly, which is what makes a
  ## waypoint a place the weather visits rather than a direction it leans.
  for waypoint in 0 ..< waypoints.len:
    let point = tourAt(waypoints, waypoint.float / waypoints.len.float)
    checkSamePoint(point, waypoints[waypoint], 1e-12)


suite "One Tour Serves Any Table":
  # The same advance and easing code runs over both tables, so a second
  # weather supplies a table and nothing else. These tests fail if the tour is
  # ever narrowed to the climate's two axes.
  test "the tour carries its guarantees onto a table of another arity":
    checkStaysInsideBox(PROBE_TOUR, PROBE_BOX)
    checkNoStepExceeds(PROBE_TOUR, PROBE_MAX_STEPS, CLIMATE_SPEED_MAX)
    checkNoJumpAtHandover(PROBE_TOUR)
    checkEasesAtHandover(PROBE_TOUR)

  test "the tour lands on every waypoint of any table it walks":
    checkLandsOnEveryWaypoint(PROBE_TOUR)
    checkLandsOnEveryWaypoint(RD_CLIMATE_TOUR)
    checkLandsOnEveryWaypoint(FORCE_WEATHER_TOUR)


suite "Climate Drift Stays Inside The Rectangle":
  test "climate drift stays inside the feed/kill rectangle for every phase":
    # This is the property that lets the frame loop write drift straight
    # through setParam without a clamp doing quiet work — a clamp MASKS a path
    # that leaves the box rather than keeping it inside.
    checkStaysInsideBox(RD_CLIMATE_TOUR, RD_CLIMATE_BOX)

  test "phase outside [0,1) names the same point as its wrapped equivalent":
    # The frame loop never resets a counter, so phase must behave as an angle.
    # A session left running overnight relies on this.
    for step in 0 .. 200:
      let phase = step.float / 200.0
      for turns in [-3.0, -1.0, 2.0, 17.0]:
        let shifted = tourAt(RD_CLIMATE_TOUR, phase + turns)
        let direct = tourAt(RD_CLIMATE_TOUR, phase)
        checkSamePoint(shifted, direct, 1e-12)

  test "wrapPhase always lands in [0,1)":
    for raw in [-1000.0, -1.5, -1e-18, 0.0, 0.5, 1.0, 1.0 - 1e-18, 7.25, 1e6]:
      let wrapped = wrapPhase(raw)
      check wrapped >= 0.0
      check wrapped < 1.0


suite "Climate Drift Is Continuous":
  test "climate drift is continuous — no step exceeds the configured maximum delta":
    # Swept at CLIMATE_SPEED_MAX, the fastest weather the slider offers.
    # Observed: the largest single-frame move is well under CLIMATE_MAX_STEP;
    # if a future speed ceiling or regime coordinate pushes past it, this goes
    # red rather than the weather visibly jumping.
    checkNoStepExceeds(RD_CLIMATE_TOUR, CLIMATE_MAX_STEPS, CLIMATE_SPEED_MAX)

  test "the path has no positional jump at a waypoint handover":
    checkNoJumpAtHandover(RD_CLIMATE_TOUR)

  test "the path eases rather than corners at each waypoint":
    checkEasesAtHandover(RD_CLIMATE_TOUR)


suite "Climate Drift Tours The Named Regimes":
  test "the climate table carries one waypoint per named regime":
    # Why the path is a regime tour and not a wander: most of the feed/kill
    # rectangle produces nothing worth looking at — which is the entire reason
    # the named regimes exist — so a drift that wandered the box would spend
    # most of its time in dead parameter space. Landing exactly on each regime
    # is what makes the weather worth watching, and the table is a projection of
    # RD_REGIMES rather than a second copy of those coordinates.
    check CLIMATE_WAYPOINTS == RD_REGIMES.len
    for waypoint in 0 ..< CLIMATE_WAYPOINTS:
      check abs(RD_CLIMATE_TOUR[waypoint][caFeed] -
        RD_REGIMES[waypoint].feed) < 1e-12
      check abs(RD_CLIMATE_TOUR[waypoint][caKill] -
        RD_REGIMES[waypoint].kill) < 1e-12

  test "one tour at a given speed takes the time that speed names":
    # `speed` is tours per minute, a unit a user can feel. At speed 1 a lap
    # takes sixty seconds; at speed 2, thirty. Frame rate must not enter into
    # it, which is why the step takes elapsed seconds rather than a frame count.
    for speed in [CLIMATE_SPEED_MIN, CLIMATE_DEFAULT_SPEED, CLIMATE_SPEED_MAX]:
      let expectedSeconds = 60.0 / speed
      # Same elapsed time, two very different frame rates.
      for frameSeconds in [1.0 / 30.0, 1.0 / 144.0]:
        let frames = int(expectedSeconds / frameSeconds)
        var accumulated = 0.0
        for _ in 0 ..< frames:
          accumulated += tourPhaseStep(speed, frameSeconds)
        check abs(accumulated - 1.0) < 1e-3

  test "the drift default is slower than the ceiling and inside the range":
    check CLIMATE_DEFAULT_SPEED >= CLIMATE_SPEED_MIN
    check CLIMATE_DEFAULT_SPEED <= CLIMATE_SPEED_MAX
    check CLIMATE_DEFAULT_SPEED < CLIMATE_SPEED_MAX

  test "a stopped clock leaves the climate exactly where it was":
    # dt of zero happens on a paused or throttled tab. It must not nudge.
    for step in 0 .. 20:
      let phase = step.float / 20.0
      check tourAdvance(phase, CLIMATE_SPEED_MAX, 0.0) == wrapPhase(phase)

suite "The Climate Owns Its Output Surface":
  # The defect this family pins: the weather moves parameters from the frame
  # loop, so every consumer — the clamp that writes them, the panel that reads
  # them back — has to know which ones. Held as a separate list per consumer,
  # a third axis moves the simulation while a panel silently stops reporting
  # part of it, and nothing goes red. CLIMATE_PARAM_IDS is the one list; these
  # tests check the agreements a compiler cannot.

  test "every parameter the climate writes has a descriptor":
    # An id here that names no descriptor cannot be clamped, cannot be read
    # back through getParam, and cannot appear on a slider — the weather would
    # move a parameter the panel has no way to show.
    var known: seq[string]
    for descriptor in buildParamDescriptors():
      known.add(descriptor.id)
    for axis in ClimateAxis:
      check CLIMATE_PARAM_IDS[axis] in known

  test "the descriptor sweep can fail":
    # THE NON-VACUOUS CHECK. The sweep above is a membership test over a list
    # built at runtime; if that list ever came back holding everything, the
    # sweep would pass for the wrong reason.
    var known: seq[string]
    for descriptor in buildParamDescriptors():
      known.add(descriptor.id)
    check known.len > 0
    check "noSuchParameter" notin known

suite "The Force Weather Rides The Same Tour":
  # The spec's claim is structural: the force weather supplies a waypoint table
  # and nothing else, and inherits every guarantee from the one advance
  # implementation. These call the SAME templates the climate calls, which is
  # what that claim reduces to — a second loop would have to be tested here
  # separately, and there is nothing separate to test.

  test "the force weather stays inside the box its ranges bound":
    # Convexity again, and it matters more here than for the climate: the frame
    # loop writes these straight through with no clamp, and three of the four
    # force parameters reach the physics on the very next frame.
    checkStaysInsideBox(FORCE_WEATHER_TOUR, FORCE_WEATHER_BOX)

  test "no force axis steps further than its own ceiling at the top speed":
    checkNoStepExceeds(FORCE_WEATHER_TOUR, FORCE_WEATHER_MAX_STEPS,
      FORCE_WEATHER_SPEED_MAX)

  test "the force path has no positional jump at a waypoint handover":
    checkNoJumpAtHandover(FORCE_WEATHER_TOUR)

  test "the force path eases rather than corners at each waypoint":
    checkEasesAtHandover(FORCE_WEATHER_TOUR)

  test "every parameter the force weather writes has a descriptor":
    # Same agreement CLIMATE_PARAM_IDS carries: an id naming no descriptor
    # cannot be clamped, read back, or shown on a slider.
    var known: seq[string]
    for descriptor in buildParamDescriptors():
      known.add(descriptor.id)
    for axis in ForceAxis:
      check FORCE_WEATHER_PARAM_IDS[axis] in known

  test "the force weather writes the coordinates its tour travels in":
    check FORCE_WEATHER_PARAM_IDS.len == FORCE_WEATHER_TOUR[0].len
    for axis in ForceAxis:
      check FORCE_WEATHER_PARAM_IDS[axis].len > 0

  test "the two weathers tour different arities on one implementation":
    # The load-bearing difference. If the tour were ever specialised back to
    # the climate's two axes, this is the statement that stops making sense.
    check FORCE_WEATHER_TOUR[0].len != RD_CLIMATE_TOUR[0].len

  test "the force default speed is inside the range and under the ceiling":
    check FORCE_WEATHER_DEFAULT_SPEED >= FORCE_WEATHER_SPEED_MIN
    check FORCE_WEATHER_DEFAULT_SPEED <= FORCE_WEATHER_SPEED_MAX
    check FORCE_WEATHER_DEFAULT_SPEED < FORCE_WEATHER_SPEED_MAX


suite "The Climate Owns Its Output Surface Continued":
  test "the climate writes the coordinates its tour travels in":
    # CLIMATE_PARAM_IDS and the tour table are two statements about the same
    # axes. The array types tie their arity together at compile time; this
    # states the pairing an editor would otherwise have to remember.
    check CLIMATE_PARAM_IDS.len == RD_CLIMATE_TOUR[0].len
    for axis in ClimateAxis:
      check CLIMATE_PARAM_IDS[axis].len > 0
