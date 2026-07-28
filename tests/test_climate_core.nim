# ==============================================================================
# PARTICLE GARDEN - CLIMATE CORE TESTS
# ==============================================================================
#
# The drifting climate: a closed loop through the named regimes that the frame
# loop walks, writing feed and kill through the ordinary parameter path.
#
# Two properties carry the whole feature, and both are structural rather than
# tuned — which is what these tests pin. If the path can leave the feed/kill
# rectangle, drift can put the simulation somewhere the sliders cannot express;
# if it can jump, the weather reads as a glitch instead of as weather.
#
# ==============================================================================

import std/unittest
import ../src/climate_core
import ../src/config_ranges

const CLIMATE_CORE_TESTS_LOADED* = true

const
  SWEEP_STEPS = 2000
    ## Phase samples per full-loop sweep. Fine enough that no segment boundary
    ## (there are CLIMATE_WAYPOINTS of them) is stepped over.
  FRAME_SECONDS = 1.0 / 60.0

suite "Climate Drift Stays Inside The Rectangle":
  test "climate drift stays inside the feed/kill rectangle for every phase":
    # CONTRACT: the climate-drift spec's "Drift respects the range". This is
    # the property that lets the frame loop write drift straight through
    # setParam without a clamp doing quiet work — a clamp would MASK a path
    # that had left the box rather than keep it inside.
    for step in 0 .. SWEEP_STEPS:
      let phase = step.float / SWEEP_STEPS.float
      let climate = climateAt(phase)
      check climate.feed >= RD_FEED_MIN
      check climate.feed <= RD_FEED_MAX
      check climate.kill >= RD_KILL_MIN
      check climate.kill <= RD_KILL_MAX

  test "phase outside [0,1) names the same point as its wrapped equivalent":
    # The frame loop never resets a counter, so phase must behave as an angle.
    # A session left running overnight relies on this.
    for step in 0 .. 200:
      let phase = step.float / 200.0
      for turns in [-3.0, -1.0, 2.0, 17.0]:
        let shifted = climateAt(phase + turns)
        let direct = climateAt(phase)
        check abs(shifted.feed - direct.feed) < 1e-12
        check abs(shifted.kill - direct.kill) < 1e-12

  test "wrapPhase always lands in [0,1)":
    for raw in [-1000.0, -1.5, -1e-18, 0.0, 0.5, 1.0, 1.0 - 1e-18, 7.25, 1e6]:
      let wrapped = wrapPhase(raw)
      check wrapped >= 0.0
      check wrapped < 1.0


suite "Climate Drift Is Continuous":
  test "climate drift is continuous — no step exceeds the configured maximum delta":
    # CONTRACT: the climate-drift spec's "Drift is continuous". Swept at
    # CLIMATE_SPEED_MAX, the fastest weather the slider offers, across the
    # whole loop including every waypoint handover.
    # OBSERVED: the largest single-frame move is well under CLIMATE_MAX_STEP;
    # if a future speed ceiling or regime coordinate pushes past it, this goes
    # red rather than the weather visibly jumping.
    for step in 0 ..< SWEEP_STEPS:
      let phase = step.float / SWEEP_STEPS.float
      let nextPhase = climateAdvance(phase, CLIMATE_SPEED_MAX, FRAME_SECONDS)
      let here = climateAt(phase)
      let next = climateAt(nextPhase)
      check abs(next.feed - here.feed) <= CLIMATE_MAX_STEP
      check abs(next.kill - here.kill) <= CLIMATE_MAX_STEP

  test "the path has no positional jump at a waypoint handover":
    # Segment boundaries are where a piecewise path breaks if it breaks at all.
    # Sampled either side of each one at a far finer step than a frame takes.
    const NUDGE = 1e-7
    for waypoint in 0 ..< CLIMATE_WAYPOINTS:
      let boundary = waypoint.float / CLIMATE_WAYPOINTS.float
      let before = climateAt(boundary - NUDGE)
      let after = climateAt(boundary + NUDGE)
      check abs(after.feed - before.feed) < 1e-5
      check abs(after.kill - before.kill) < 1e-5

  test "the path eases rather than corners at each waypoint":
    # Smoothstep's derivative is zero at both ends of a segment, so the path
    # arrives and leaves a regime slowly. Plain linear interpolation would be
    # positionally continuous but visibly corner here, and this is the test
    # that would notice the easing being dropped for simplicity.
    const NUDGE = 1e-4
    for waypoint in 0 ..< CLIMATE_WAYPOINTS:
      let boundary = waypoint.float / CLIMATE_WAYPOINTS.float
      # Speed just after a waypoint must be far below speed at mid-segment.
      let atWaypoint = climateAt(boundary + NUDGE)
      let justAfter = climateAt(boundary + 2.0 * NUDGE)
      let midpoint = (waypoint.float + 0.5) / CLIMATE_WAYPOINTS.float
      let atMid = climateAt(midpoint)
      let justAfterMid = climateAt(midpoint + NUDGE)
      let waypointSpeed = abs(justAfter.feed - atWaypoint.feed) +
        abs(justAfter.kill - atWaypoint.kill)
      let midSpeed = abs(justAfterMid.feed - atMid.feed) +
        abs(justAfterMid.kill - atMid.kill)
      check waypointSpeed < midSpeed


suite "Climate Drift Tours The Named Regimes":
  test "every named regime is a point the drift passes through":
    # WHY THE PATH IS A REGIME TOUR AND NOT A WANDER. Most of the feed/kill
    # rectangle produces nothing worth looking at — which is the entire reason
    # the named regimes exist — so a drift that wandered the box would spend
    # most of its time in dead parameter space. Landing exactly on each regime
    # is what makes the weather worth watching.
    for waypoint in 0 ..< CLIMATE_WAYPOINTS:
      let climate = climateAt(waypoint.float / CLIMATE_WAYPOINTS.float)
      check abs(climate.feed - RD_REGIMES[waypoint].feed) < 1e-12
      check abs(climate.kill - RD_REGIMES[waypoint].kill) < 1e-12

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
          accumulated += climatePhaseStep(speed, frameSeconds)
        check abs(accumulated - 1.0) < 1e-3

  test "the drift default is slower than the ceiling and inside the range":
    check CLIMATE_DEFAULT_SPEED >= CLIMATE_SPEED_MIN
    check CLIMATE_DEFAULT_SPEED <= CLIMATE_SPEED_MAX
    check CLIMATE_DEFAULT_SPEED < CLIMATE_SPEED_MAX

  test "a stopped clock leaves the climate exactly where it was":
    # dt of zero happens on a paused or throttled tab. It must not nudge.
    for step in 0 .. 20:
      let phase = step.float / 20.0
      check climateAdvance(phase, CLIMATE_SPEED_MAX, 0.0) == wrapPhase(phase)
