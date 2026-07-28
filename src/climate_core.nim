# ==============================================================================
# PARTICLE GARDEN - CLIMATE CORE (Pure Drifting Weather)
# ==============================================================================
#
# A weather is a closed tour of waypoints that the frame loop walks, writing
# every toured parameter through the ordinary setParam path so the sliders
# visibly move. Pure (no FFI, no DOM): compiles on both backends and is
# exercised natively, like the other *_core modules.
#
# ONE TOUR, MANY TABLES. `tourAt` interpolates any table whose waypoints are
# float coordinates indexed by that weather's own axis enum, so a weather over
# different parameters supplies a table and reuses this advance, easing and
# wrapping. The reaction-diffusion climate below is one such table. Arity comes
# from the axis enum, which is why nothing here fixes it at two: a weather over
# four force parameters names four axes and calls the same code. The axis type
# also keeps one weather's point from being read as another's.
#
# THE CLIMATE TABLE TOURS THE NAMED REGIMES. Most of the feed/kill rectangle
# produces nothing worth looking at — that is the whole reason the named regimes
# exist — so a drift that wandered the box at random would spend most of its
# time in dead or flooded parameter space and read as a broken feature rather
# than as weather. The path is instead a closed loop through the six regime
# coordinates in RD_REGIMES order, so the weather visits every regime the panel
# names and nothing else.
#
# TWO PROPERTIES EVERY TABLE GETS BY CONSTRUCTION, not by tuning:
#
#   IN RANGE. Every point is a convex combination of two waypoints. One
#   parameter's range is an interval and a set of them is an axis-aligned box,
#   hence convex, so a table whose waypoints all lie inside its box interpolates
#   only to points inside it. config_ranges statically asserts that for
#   RD_REGIMES, and a table added there carries the same assertion beside its
#   own ranges. No clamping is needed and none is applied; clamping would hide a
#   path that has left the box rather than prevent it.
#
#   CONTINUOUS. Segments are joined with smoothstep easing, whose derivative is
#   zero at both ends, so the path has no velocity discontinuity where one
#   waypoint hands over to the next. Plain linear interpolation would be
#   positionally continuous but would visibly corner at every waypoint.
#
# tests/test_climate_core.nim sweeps both properties over the climate table and
# over a probe table of another arity, so the guarantees are proven of the tour
# rather than of the climate.
#
# The frame loop advances `phase` and writes the result through the ordinary
# setParam path, so the sliders move where a user can see them — that is what
# makes the weather legible rather than mysterious, and it is a requirement of
# the weather spec rather than an implementation convenience.

import std/math
import config_ranges

func smoothstep(t: float): float =
  ## The classic 3t^2 - 2t^3 ease, zero-derivative at both ends. Keeps the
  ## handover between two waypoints free of a velocity corner.
  let clamped = clamp(t, 0.0, 1.0)
  clamped * clamped * (3.0 - 2.0 * clamped)

func wrapPhase*(phase: float): float =
  ## Phase folded into [0, 1). Every tour is closed, so phase is an angle: any
  ## real value names a point on it, and the frame loop never has to reset.
  result = phase - floor(phase)
  # floor() of a tiny negative can round to exactly 1.0 in floating point.
  if result >= 1.0:
    result = 0.0

func tourAt*[A](waypoints: openArray[array[A, float]],
                phase: float): array[A, float] =
  ## The point at `phase` on the closed tour of `waypoints`. Phase 0 sits
  ## exactly on the first waypoint; each 1/len advances one waypoint further.
  ## The table travels as an argument rather than living in this module, so a
  ## table can sit beside the ranges its coordinates must satisfy.
  let count = waypoints.len
  let scaled = wrapPhase(phase) * count.float
  let segment = min(int(scaled), count - 1)
  let eased = smoothstep(scaled - segment.float)
  let here = waypoints[segment]
  let next = waypoints[(segment + 1) mod count]
  for axis in result.low .. result.high:
    result[axis] = here[axis] + (next[axis] - here[axis]) * eased

func tourPhaseStep*(speed, deltaSeconds: float): float =
  ## Phase advanced in one frame. `speed` is tours per minute — a unit a user
  ## can feel ("one lap of the regimes a minute") rather than a bare rate — so
  ## a full loop at speed 1.0 takes sixty seconds however the frame rate moves.
  speed * deltaSeconds / 60.0

func tourAdvance*(phase, speed, deltaSeconds: float): float =
  ## Next phase. Wrapped, so a session left running for hours never drifts into
  ## the range where float precision would coarsen the step.
  wrapPhase(phase + tourPhaseStep(speed, deltaSeconds))

# ------------------------------------------------------------------------------
# The reaction-diffusion climate: one table on that tour
# ------------------------------------------------------------------------------

type ClimateAxis* = enum
  ## The climate's axes, and the names its waypoints are read back by.
  caFeed
  caKill

func rdClimateTour(): array[RD_REGIMES.len, array[ClimateAxis, float]] =
  ## The named regimes' coordinates as tour waypoints. RD_REGIMES stays the one
  ## source of those numbers; this projects them, and inherits the static
  ## in-range assertion config_ranges makes over them.
  for index, regime in RD_REGIMES:
    result[index] = [caFeed: regime.feed, caKill: regime.kill]

const
  RD_CLIMATE_TOUR* = rdClimateTour()
    ## The waypoint table the drifting climate walks.
  CLIMATE_WAYPOINTS* = RD_CLIMATE_TOUR.len
    ## Waypoints on the climate loop: one per named regime. The loop closes back
    ## to the first, so there are also CLIMATE_WAYPOINTS segments.
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
