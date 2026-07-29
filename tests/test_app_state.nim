# PARTICLE GARDEN - APP STATE / PROFILING TESTS
#
# Behavioral tests for the pure profiling accumulators in app_state.nim. The
# averages drive tuning decisions, and the averaging functions carry a
# frameCount > 0 guard that must hold to avoid dividing by zero before any
# frame has been recorded.

import std/unittest
import ../src/ui/state/app_state

const APP_STATE_TESTS_LOADED* = true

proc approxEq(lhs, rhs: float; epsilon: float = 1e-9): bool =
  abs(lhs - rhs) <= epsilon

proc timingWith(grid, frame: float): TimingState =
  result = initTimingState()
  result.gridTimeMs = grid
  result.frameTimeMs = frame

suite "Profiling Averages Divide By Frame Count":
  test "averageGridTime returns zero when no frames have accumulated":
    check initProfilingState().averageGridTime() == 0.0

  test "averageTotalTime returns zero when no frames have accumulated":
    check initProfilingState().averageTotalTime() == 0.0

  test "averageGridTime returns the mean of accumulated grid times across frames":
    var profile = initProfilingState()
    profile = profile.accumulate(timingWith(grid = 4.0, frame = 10.0))
    profile = profile.accumulate(timingWith(grid = 6.0, frame = 20.0))
    check profile.frameCount == 2
    check approxEq(profile.averageGridTime(), 5.0)

  test "averageTotalTime averages the per-frame wall-clock time":
    var profile = initProfilingState()
    profile = profile.accumulate(timingWith(grid = 1.0, frame = 10.0))
    profile = profile.accumulate(timingWith(grid = 1.0, frame = 20.0))
    check approxEq(profile.averageTotalTime(), 15.0)


suite "Profiling Accumulation Is Immutable And Resettable":
  test "accumulate returns a new state and leaves the original frame count at zero":
    let original = initProfilingState()
    let updated = original.accumulate(timingWith(grid = 2.0, frame = 5.0))
    check updated.frameCount == 1
    check original.frameCount == 0

  test "reset clears all accumulated sums and the frame count":
    var profile = initProfilingState()
    profile = profile.accumulate(timingWith(grid = 3.0, frame = 9.0))
    let cleared = profile.reset()
    check cleared.frameCount == 0
    check cleared.gridTimeSum == 0.0
    check cleared.totalTimeSum == 0.0
