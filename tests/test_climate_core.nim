# ==============================================================================
# PARTICLE GARDEN - CLIMATE CORE TESTS
# ==============================================================================
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
# EVERY GUARANTEE IS WRITTEN ONCE, over any table. The templates below take the
# waypoints and the box, so a weather over different parameters registers its
# table with them and inherits the proofs. Two tables run through them here: the
# reaction-diffusion regimes, and a probe table of a different arity and a
# different scale whose only job is to keep the tour from being specialised
# to feed and kill.
#
# ==============================================================================

import std/unittest
import ../src/climate_core
import ../src/config_ranges

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

const PROBE_MAX_STEP = 0.2
  ## What the probe table's widest segment (45 units, pxWide) can carry at
  ## CLIMATE_SPEED_MAX: smoothstep peaks at 1.5x the average slope, so the
  ## fastest frame moves 1.5 * 45 * 4 * 2 / 3600 ≈ 0.15 units.

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

template checkNoStepExceeds(waypoints, maxStep, speed: untyped) =
  ## CONTINUOUS at the fastest weather offered, across the whole loop including
  ## every waypoint handover.
  for step in 0 ..< SWEEP_STEPS:
    let phase = step.float / SWEEP_STEPS.float
    let here = tourAt(waypoints, phase)
    let next = tourAt(waypoints, tourAdvance(phase, speed, FRAME_SECONDS))
    for axis in here.low .. here.high:
      check abs(next[axis] - here[axis]) <= maxStep

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
  # CONTRACT: the weather spec's "A second loop cannot appear". The same
  # advance and easing code runs over both tables, so a second weather supplies
  # a table and nothing else. These tests fail if the tour is ever narrowed to
  # the climate's two axes.
  test "the tour carries its guarantees onto a table of another arity":
    checkStaysInsideBox(PROBE_TOUR, PROBE_BOX)
    checkNoStepExceeds(PROBE_TOUR, PROBE_MAX_STEP, CLIMATE_SPEED_MAX)
    checkNoJumpAtHandover(PROBE_TOUR)
    checkEasesAtHandover(PROBE_TOUR)

  test "the tour lands on every waypoint of any table it walks":
    checkLandsOnEveryWaypoint(PROBE_TOUR)
    checkLandsOnEveryWaypoint(RD_CLIMATE_TOUR)


suite "Climate Drift Stays Inside The Rectangle":
  test "climate drift stays inside the feed/kill rectangle for every phase":
    # CONTRACT: the weather spec's "Drift respects the range". This is the
    # property that lets the frame loop write drift straight through setParam
    # without a clamp doing quiet work — a clamp MASKS a path that leaves the
    # box rather than keeping it inside.
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
    # CONTRACT: the weather spec's "Drift is continuous". Swept at
    # CLIMATE_SPEED_MAX, the fastest weather the slider offers.
    # OBSERVED: the largest single-frame move is well under CLIMATE_MAX_STEP;
    # if a future speed ceiling or regime coordinate pushes past it, this goes
    # red rather than the weather visibly jumping.
    checkNoStepExceeds(RD_CLIMATE_TOUR, CLIMATE_MAX_STEP, CLIMATE_SPEED_MAX)

  test "the path has no positional jump at a waypoint handover":
    checkNoJumpAtHandover(RD_CLIMATE_TOUR)

  test "the path eases rather than corners at each waypoint":
    checkEasesAtHandover(RD_CLIMATE_TOUR)


suite "Climate Drift Tours The Named Regimes":
  test "the climate table carries one waypoint per named regime":
    # WHY THE PATH IS A REGIME TOUR AND NOT A WANDER. Most of the feed/kill
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
