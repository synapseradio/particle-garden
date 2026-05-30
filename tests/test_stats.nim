# ==============================================================================
# PARTICLE GARDEN - STATS VIEW TESTS
# ==============================================================================
#
# Behavioral tests for the pure stats formatters and immutable updaters that
# drive the performance HUD. The format* functions control the visible precision
# of the readout, and the with* updaters must never mutate the source state.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/ui/stats/stats_view

const STATS_TESTS_LOADED* = true

suite "Stats Formatters Produce Fixed Precision":
  test "formatGridTime renders two decimal places":
    check formatGridTime(0.0) == "0.00"
    check formatGridTime(1.5) == "1.50"
    check formatGridTime(12.345) == "12.35"

  test "formatWorkerTime renders one decimal place":
    check formatWorkerTime(0.0) == "0.0"
    check formatWorkerTime(3.14) == "3.1"
    check formatWorkerTime(10.0) == "10.0"

  test "formatFps renders the integer count":
    check formatFps(0) == "0"
    check formatFps(60) == "60"


suite "Stats Updates Are Immutable":
  test "withFps sets fps and leaves the original state unchanged":
    let original = initStatsState()
    let updated = original.withFps(60)
    check updated.fps == 60
    check original.fps == 0

  test "withTiming preserves the fps field carried from the prior state":
    let state = initStatsState().withFps(30).withTiming(1.0, 2.0)
    check state.fps == 30
    check state.gridTimeMs == 1.0
    check state.workerTimeMs == 2.0

  test "withParticleCount sets the count without touching timing or fps":
    let state = initStatsState().withFps(45).withTiming(3.0, 4.0).withParticleCount(16000)
    check state.particleCount == 16000
    check state.fps == 45
    check state.gridTimeMs == 3.0
