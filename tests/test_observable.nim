# ==============================================================================
# PARTICLE GARDEN - OBSERVABLE TESTS
# ==============================================================================
#
# Unit tests for the observable pattern in ui/core/
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/ui/core/observable

# Exported symbol for test_all.nim to reference
const OBSERVABLE_TESTS_LOADED* = true

# ==============================================================================
# OBSERVABLE TESTS
# ==============================================================================

suite "Observable - Basic Operations":
  test "newObservable creates with initial value":
    let obs = newObservable(42)
    check obs.get() == 42

  test "set updates value":
    let obs = newObservable(0)
    obs.set(10)
    check obs.get() == 10


suite "Observable - Subscriptions":
  test "a subscriber is called immediately with the current value":
    let obs = newObservable(100)
    var received = -1

    obs.subscribeSimple(proc(value: int) = received = value)

    check received == 100

  test "a subscriber is called when the value changes":
    let obs = newObservable(0)
    var history: seq[int] = @[]

    obs.subscribeSimple(proc(value: int) = history.add(value))

    obs.set(1)
    obs.set(2)
    obs.set(3)

    check history == @[0, 1, 2, 3]

  test "multiple subscribers all receive updates":
    let obs = newObservable(0)
    var receivedA = 0
    var receivedB = 0

    obs.subscribeSimple(proc(value: int) = receivedA = value)
    obs.subscribeSimple(proc(value: int) = receivedB = value * 10)

    obs.set(5)

    check receivedA == 5
    check receivedB == 50

  test "a value set with no subscribers is still readable":
    # canvas_input's currentInput is written every frame and read directly,
    # never subscribed to. Notification scheduling must not depend on
    # anyone listening.
    let obs = newObservable(0)
    obs.set(7)
    check obs.get() == 7
