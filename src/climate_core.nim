# ==============================================================================
# PARTICLE GARDEN - CLIMATE CORE (Pure Drifting Weather)
# ==============================================================================
#
# Where the reaction-diffusion climate sits at a given moment, when the weather
# is allowed to wander. Pure (no FFI, no DOM): compiles on both backends and is
# exercised natively, like the other *_core modules.
#
# THE PATH TOURS THE NAMED REGIMES. Most of the feed/kill rectangle produces
# nothing worth looking at — that is the whole reason the named regimes exist —
# so a drift that wandered the box at random would spend most of its time in
# dead or flooded parameter space and read as a broken feature rather than as
# weather. The path is instead a closed loop through the six regime coordinates
# in RD_REGIMES order, so the weather visits every regime the panel names and
# nothing else.
#
# TWO PROPERTIES THE LOOP GUARANTEES BY CONSTRUCTION, not by tuning:
#
#   IN RANGE. Every point is a convex combination of two regime coordinates.
#   The feed/kill rectangle is an axis-aligned box, hence convex, and
#   config_ranges statically asserts every regime lies inside it — so every
#   interpolated point does too. No clamping is needed and none is applied;
#   clamping would hide a path that had left the box rather than prevent it.
#
#   CONTINUOUS. Segments are joined with smoothstep easing, whose derivative is
#   zero at both ends, so the path has no velocity discontinuity where one
#   regime hands over to the next. Plain linear interpolation would be
#   positionally continuous but would visibly corner at every waypoint.
#
# The frame loop advances `phase` and writes the result through the ordinary
# setParam path, so the sliders move where a user can see them — that is what
# makes the weather legible rather than mysterious, and it is a requirement of
# the climate-drift spec rather than an implementation convenience.

import std/math
import config_ranges

const
  CLIMATE_WAYPOINTS* = RD_REGIMES.len
    ## Waypoints on the loop: one per named regime. The loop closes back to the
    ## first, so there are also CLIMATE_WAYPOINTS segments.
  CLIMATE_DEFAULT_SPEED* = 0.25
    ## One tour of the regimes every four minutes. Slow enough that the pattern
    ## has time to settle into each regime before the climate leaves it —
    ## ignition alone takes a dozen frames, and a morphology takes longer to
    ## develop than to nucleate — and slow enough that a moving slider reads as
    ## weather rather than as something malfunctioning.
  CLIMATE_MAX_STEP* = 0.002
    ## The largest a single advance may move feed or kill, in slider units, at
    ## CLIMATE_SPEED_MAX and a 1/60 s frame. Two slider steps: enough that the
    ## readout moves, small enough that no frame jumps a regime.
    ##
    ## This is a CEILING THE PATH MUST RESPECT, not a limiter applied to it.
    ## tests/test_climate_core.nim sweeps the whole loop and fails if any step
    ## exceeds it, so raising CLIMATE_SPEED_MAX past what the loop can carry
    ## goes red here rather than making the weather jump.

func smoothstep(t: float): float =
  ## The classic 3t^2 - 2t^3 ease, zero-derivative at both ends. Keeps the
  ## handover between two regimes free of a velocity corner.
  let clamped = clamp(t, 0.0, 1.0)
  clamped * clamped * (3.0 - 2.0 * clamped)

func wrapPhase*(phase: float): float =
  ## Phase folded into [0, 1). The loop is closed, so phase is an angle: any
  ## real value names a point on it, and the frame loop never has to reset.
  result = phase - floor(phase)
  # floor() of a tiny negative can round to exactly 1.0 in floating point.
  if result >= 1.0:
    result = 0.0

func climateAt*(phase: float): tuple[feed, kill: float] =
  ## The climate at `phase` on the closed regime tour. Phase 0 sits exactly on
  ## the first regime; each 1/CLIMATE_WAYPOINTS advances one regime further.
  let wrapped = wrapPhase(phase)
  let scaled = wrapped * CLIMATE_WAYPOINTS.float
  let segment = min(int(scaled), CLIMATE_WAYPOINTS - 1)
  let eased = smoothstep(scaled - segment.float)
  let here = RD_REGIMES[segment]
  let next = RD_REGIMES[(segment + 1) mod CLIMATE_WAYPOINTS]
  (feed: here.feed + (next.feed - here.feed) * eased,
   kill: here.kill + (next.kill - here.kill) * eased)

func climatePhaseStep*(speed, deltaSeconds: float): float =
  ## Phase advanced in one frame. `speed` is tours per minute — a unit a user
  ## can feel ("one lap of the regimes a minute") rather than a bare rate — so
  ## a full loop at speed 1.0 takes sixty seconds however the frame rate moves.
  speed * deltaSeconds / 60.0

func climateAdvance*(phase, speed, deltaSeconds: float): float =
  ## Next phase. Wrapped, so a session left running for hours never drifts into
  ## the range where float precision would coarsen the step.
  wrapPhase(phase + climatePhaseStep(speed, deltaSeconds))
