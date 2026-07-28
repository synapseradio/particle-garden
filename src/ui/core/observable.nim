# ==============================================================================
# OBSERVABLE - Core reactive state container
# ==============================================================================
#
# Pub/sub container for the two pieces of state that cross module boundaries
# on the Nim side: canvas_input's currentInput and sim_config's worldCouplings.
# The Solid panel owns UI reactivity; this stays deliberately small.
#
# Design goals:
# - No global mutable state (state lives in Observable instances)
# - Notifications coalesce on a microtask in JS, flush synchronously natively
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

proc `==`*(lhs, rhs: SubscriptionId): bool {.borrow.}

# ==============================================================================
# SECTION 2: NOTIFICATION SCHEDULING
# ==============================================================================

var pendingNotifications: seq[proc()]

when defined(js):
  proc queueMicrotask(fn: proc()) {.importjs: "queueMicrotask(#)".}

proc flushPending() =
  ## Execute all pending notifications
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
    flushPending()

# ==============================================================================
# SECTION 3: CONSTRUCTOR
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
# SECTION 4: VALUE ACCESS
# ==============================================================================

proc get*[T](obs: Observable[T]): T {.inline.} =
  ## Read the current value. No side effects.
  ##
  ## Example:
  ##   let current = count.get()
  obs.value

# ==============================================================================
# SECTION 5: NOTIFICATION
# ==============================================================================

proc doNotify[T](obs: Observable[T]) =
  ## Execute all observer callbacks with current value.
  ## Runs cleanup from previous notification first.
  if obs.notifying:
    return  # Prevent recursive notifications

  obs.notifying = true
  obs.pendingNotify = false

  try:
    for idx in 0 ..< obs.subscriptions.len:
      # Run previous cleanup if any
      if not obs.subscriptions[idx].cleanup.isNil:
        obs.subscriptions[idx].cleanup()
        obs.subscriptions[idx].cleanup = nil

      # Call observer, store new cleanup
      let newCleanup = obs.subscriptions[idx].fn(obs.value)
      obs.subscriptions[idx].cleanup = newCleanup
  finally:
    obs.notifying = false

# ==============================================================================
# SECTION 6: MUTATION
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

# ==============================================================================
# SECTION 7: SUBSCRIPTION
# ==============================================================================

proc subscribe[T](obs: Observable[T], fn: Observer[T]): SubscriptionId =
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

