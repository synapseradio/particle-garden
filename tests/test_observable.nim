# ==============================================================================
# PARTICLE GARDEN - OBSERVABLE TESTS
# ==============================================================================
#
# Unit tests for the observable pattern in ui/core/
#
# Run with: nimble test
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

  test "peek is alias for get":
    let obs = newObservable("hello")
    check obs.peek() == "hello"

  test "update transforms value":
    let obs = newObservable(5)
    obs.update(proc(value: int): int = value * 2)
    check obs.get() == 10


suite "Observable - Subscriptions":
  test "subscribe is called immediately with current value":
    let obs = newObservable(100)
    var received = -1

    discard obs.subscribe(proc(value: int): proc() =
      received = value
      nil
    )

    check received == 100

  test "subscribe is called when value changes":
    let obs = newObservable(0)
    var history: seq[int] = @[]

    discard obs.subscribe(proc(value: int): proc() =
      history.add(value)
      nil
    )

    obs.set(1)
    obs.set(2)
    obs.set(3)

    check history == @[0, 1, 2, 3]

  test "multiple subscribers all receive updates":
    let obs = newObservable(0)
    var receivedA = 0
    var receivedB = 0

    discard obs.subscribe(proc(value: int): proc() = receivedA = value; nil)
    discard obs.subscribe(proc(value: int): proc() = receivedB = value * 10; nil)

    obs.set(5)

    check receivedA == 5
    check receivedB == 50

  test "unsubscribe stops notifications":
    let obs = newObservable(0)
    var received = 0

    let id = obs.subscribe(proc(value: int): proc() =
      received = value
      nil
    )

    obs.set(1)
    check received == 1

    obs.unsubscribe(id)
    obs.set(2)
    check received == 1  # Not updated

  test "observerCount tracks subscriptions":
    let obs = newObservable(0)

    check obs.observerCount() == 0

    let id1 = obs.subscribe(proc(value: int): proc() = nil)
    check obs.observerCount() == 1

    let id2 = obs.subscribe(proc(value: int): proc() = nil)
    check obs.observerCount() == 2

    obs.unsubscribe(id1)
    check obs.observerCount() == 1

    obs.unsubscribe(id2)
    check obs.observerCount() == 0


suite "Observable - Cleanup":
  test "cleanup is called before next notification":
    let obs = newObservable(0)
    var cleanupCalls = 0

    discard obs.subscribe(proc(value: int): proc() =
      return proc() = cleanupCalls += 1
    )

    check cleanupCalls == 0
    obs.set(1)
    check cleanupCalls == 1
    obs.set(2)
    check cleanupCalls == 2

  test "cleanup is called on unsubscribe":
    let obs = newObservable(0)
    var cleanupCalled = false

    let id = obs.subscribe(proc(value: int): proc() =
      return proc() = cleanupCalled = true
    )

    check cleanupCalled == false
    obs.unsubscribe(id)
    check cleanupCalled == true

  test "unsubscribeAll cleans up all subscriptions":
    let obs = newObservable(0)
    var cleanups = 0

    discard obs.subscribe(proc(value: int): proc() = return proc() = cleanups += 1)
    discard obs.subscribe(proc(value: int): proc() = return proc() = cleanups += 1)

    obs.unsubscribeAll()
    check cleanups == 2
    check obs.observerCount() == 0


suite "Observable - Batching":
  test "batch groups notifications":
    let obs = newObservable(0)
    var notifications = 0

    discard obs.subscribe(proc(value: int): proc() =
      notifications += 1
      nil
    )

    # Initial subscribe: 1 notification
    check notifications == 1

    batch(proc() =
      obs.set(1)
      obs.set(2)
      obs.set(3)
    )

    # Only 1 additional notification after batch
    check notifications == 2
    check obs.get() == 3

  test "withBatch template works":
    let obs = newObservable(0)
    var count = 0

    discard obs.subscribe(proc(value: int): proc() = count += 1; nil)

    withBatch:
      obs.set(10)
      obs.set(20)

    check count == 2  # Initial + after batch
    check obs.get() == 20

  test "nested batches wait for outermost":
    let obs = newObservable(0)
    var notifications = 0

    discard obs.subscribe(proc(value: int): proc() = notifications += 1; nil)

    batch(proc() =
      obs.set(1)
      batch(proc() =
        obs.set(2)
      )
      obs.set(3)
    )

    check notifications == 2  # Initial + after outermost batch
    check obs.get() == 3


suite "Observable - Map":
  test "map creates derived observable":
    let source = newObservable(5)
    let doubled = source.map(proc(value: int): int = value * 2)

    check doubled.get() == 10

    source.set(10)
    check doubled.get() == 20
