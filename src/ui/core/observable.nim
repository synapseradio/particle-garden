# ==============================================================================
# OBSERVABLE - Core reactive state container
# ==============================================================================
#
# Simple pub/sub observable pattern for UI state management.
# Provides type-safe subscriptions with automatic cleanup support.
#
# Design goals:
# - No global mutable state (state lives in Observable instances)
# - Batched notifications prevent render thrashing
# - Cleanup functions prevent memory leaks with DOM callbacks
# - Works in both JS (browser) and native (tests) contexts
#
# ==============================================================================

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  ## Unique identifier for subscriptions. Enables O(1) removal.
  SubscriptionId* = distinct int

  ## Callback that receives the new value.
  ## Returns a cleanup function (or nil if no cleanup needed).
  ## Cleanup is called before next notification or on unsubscribe.
  Observer*[T] = proc(value: T): proc()

  ## Subscription entry: ID + observer function + current cleanup
  Subscription[T] = object
    id: SubscriptionId
    fn: Observer[T]
    cleanup: proc()

  ## Core observable container. Holds value and notifies observers on change.
  Observable*[T] = ref object
    value: T
    subscriptions: seq[Subscription[T]]
    nextId: int
    pendingNotify: bool
    notifying: bool  # Guard against recursive notifications

proc `==`*(a, b: SubscriptionId): bool {.borrow.}

# ==============================================================================
# SECTION 2: BATCH STATE (module-level, manages notification coalescing)
# ==============================================================================

var batchDepth = 0
var pendingNotifications: seq[proc()]

when defined(js):
  proc queueMicrotask(fn: proc()) {.importjs: "queueMicrotask(#)".}

proc flushPending() =
  ## Execute all pending notifications
  if batchDepth > 0:
    return  # Still inside a batch

  let toFlush = pendingNotifications
  pendingNotifications = @[]

  for notify in toFlush:
    notify()

proc scheduleNotification(fn: proc()) =
  ## Schedule a notification for later execution
  pendingNotifications.add(fn)

  when defined(js):
    if pendingNotifications.len == 1:
      # First pending notification - schedule flush on microtask
      queueMicrotask(flushPending)
  else:
    # Native: flush synchronously (for tests)
    if batchDepth == 0:
      flushPending()

# ==============================================================================
# SECTION 3: BATCH API
# ==============================================================================

proc batch*(fn: proc()) =
  ## Group multiple updates into a single notification pass.
  ## Observers are notified once after the batch completes,
  ## not after each individual update.
  ##
  ## Nested batches are supported - notifications fire when
  ## the outermost batch completes.
  ##
  ## Example:
  ##   batch(proc() =
  ##     count.set(1)
  ##     name.set("updated")
  ##     # Observers notified once here, not twice
  ##   )
  batchDepth += 1
  try:
    fn()
  finally:
    batchDepth -= 1
    if batchDepth == 0:
      flushPending()

template withBatch*(body: untyped) =
  ## Template version of batch for cleaner syntax.
  ##
  ## Example:
  ##   withBatch:
  ##     count.set(1)
  ##     name.set("updated")
  batch(proc() = body)

# ==============================================================================
# SECTION 4: CONSTRUCTOR
# ==============================================================================

proc newObservable*[T](initial: T): Observable[T] =
  ## Create a new observable with an initial value.
  ##
  ## Example:
  ##   let count = newObservable(0)
  ##   let name = newObservable("default")
  Observable[T](
    value: initial,
    subscriptions: @[],
    nextId: 0,
    pendingNotify: false,
    notifying: false
  )

# ==============================================================================
# SECTION 5: VALUE ACCESS
# ==============================================================================

proc get*[T](obs: Observable[T]): T {.inline.} =
  ## Read the current value. No side effects.
  ##
  ## Example:
  ##   let current = count.get()
  obs.value

proc peek*[T](obs: Observable[T]): T {.inline.} =
  ## Alias for get. Reads value without triggering effects.
  obs.value

# ==============================================================================
# SECTION 6: NOTIFICATION
# ==============================================================================

proc doNotify[T](obs: Observable[T]) =
  ## Execute all observer callbacks with current value.
  ## Runs cleanup from previous notification first.
  if obs.notifying:
    return  # Prevent recursive notifications

  obs.notifying = true
  obs.pendingNotify = false

  try:
    for i in 0 ..< obs.subscriptions.len:
      # Run previous cleanup if any
      if not obs.subscriptions[i].cleanup.isNil:
        obs.subscriptions[i].cleanup()
        obs.subscriptions[i].cleanup = nil

      # Call observer, store new cleanup
      let newCleanup = obs.subscriptions[i].fn(obs.value)
      obs.subscriptions[i].cleanup = newCleanup
  finally:
    obs.notifying = false

# ==============================================================================
# SECTION 7: MUTATION
# ==============================================================================

proc set*[T](obs: Observable[T], newValue: T) =
  ## Update the value and schedule observer notifications.
  ##
  ## Notifications are batched - if called multiple times in
  ## quick succession, observers see only the final value.
  ##
  ## Example:
  ##   count.set(count.get() + 1)
  obs.value = newValue

  if not obs.pendingNotify:
    obs.pendingNotify = true
    let obsRef = obs  # Capture for closure
    scheduleNotification(proc() = doNotify(obsRef))

proc update*[T](obs: Observable[T], fn: proc(current: T): T) =
  ## Update value via transformation function.
  ##
  ## Example:
  ##   count.update(proc(c: int): int = c + 1)
  obs.set(fn(obs.value))

# ==============================================================================
# SECTION 8: SUBSCRIPTION
# ==============================================================================

proc subscribe*[T](obs: Observable[T], fn: Observer[T]): SubscriptionId =
  ## Subscribe to value changes. Returns ID for unsubscription.
  ##
  ## The observer is called immediately with the current value,
  ## then again whenever the value changes.
  ##
  ## The observer returns a cleanup function (or nil). Cleanup
  ## is called before the next notification or on unsubscribe.
  ##
  ## Example:
  ##   let subId = count.subscribe(proc(value: int): proc() =
  ##     echo "Count is now: ", value
  ##     # Return cleanup function
  ##     return proc() = echo "Cleaning up"
  ##   )
  let id = SubscriptionId(obs.nextId)
  obs.nextId += 1

  # Create subscription entry
  var sub = Subscription[T](id: id, fn: fn, cleanup: nil)

  # Invoke immediately with current value
  sub.cleanup = fn(obs.value)

  obs.subscriptions.add(sub)
  result = id

proc subscribeSimple*[T](obs: Observable[T], fn: proc(value: T)) =
  ## Subscribe without cleanup. Convenience for simple observers.
  ##
  ## Example:
  ##   count.subscribeSimple(proc(value: int) =
  ##     echo "Count changed to: ", value
  ##   )
  discard obs.subscribe(proc(value: T): proc() =
    fn(value)
    nil
  )

proc unsubscribe*[T](obs: Observable[T], id: SubscriptionId) =
  ## Remove a subscription by ID.
  ##
  ## Runs the cleanup function if one was returned by the observer.
  ##
  ## Example:
  ##   count.unsubscribe(subId)
  var idx = -1
  for i, sub in obs.subscriptions:
    if sub.id == id:
      idx = i
      break

  if idx >= 0:
    # Run cleanup before removing
    if not obs.subscriptions[idx].cleanup.isNil:
      obs.subscriptions[idx].cleanup()
    obs.subscriptions.delete(idx)

proc unsubscribeAll*[T](obs: Observable[T]) =
  ## Remove all subscriptions. Runs all cleanup functions.
  for sub in obs.subscriptions:
    if not sub.cleanup.isNil:
      sub.cleanup()
  obs.subscriptions = @[]

# ==============================================================================
# SECTION 9: UTILITIES
# ==============================================================================

proc observerCount*[T](obs: Observable[T]): int =
  ## Return the number of active subscriptions.
  obs.subscriptions.len

proc map*[T, U](obs: Observable[T], fn: proc(v: T): U): Observable[U] =
  ## Create a derived observable that transforms values.
  ##
  ## Note: This creates a new independent observable. For computed
  ## values that auto-update, use the computed module.
  ##
  ## Example:
  ##   let doubled = count.map(proc(c: int): int = c * 2)
  result = newObservable(fn(obs.get()))

  let derived = result
  discard obs.subscribe(proc(value: T): proc() =
    derived.set(fn(value))
    nil
  )
