# ==============================================================================
# COMPUTED - Derived reactive values
# ==============================================================================
#
# Computed values derive from one or more source observables.
# They re-compute when dependencies change and notify their own observers.
#
# Unlike auto-tracking signals (Solid.js style), dependencies are declared
# explicitly via dependsOn(). This is simpler and more predictable.
#
# ==============================================================================

import observable

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  ## A computed value derived from other observables.
  ## Re-computes lazily when dependencies change.
  Computed*[T] = ref object
    obs: Observable[T]          # Internal observable holding derived value
    compute: proc(): T          # Function to recompute value
    subscriptionIds: seq[SubscriptionId]  # Track dependencies for cleanup
    stale: bool                 # True if needs recomputation

# ==============================================================================
# SECTION 2: CONSTRUCTOR
# ==============================================================================

proc newComputed*[T](compute: proc(): T): Computed[T] =
  ## Create a computed value.
  ##
  ## The compute function is called immediately to get the initial value,
  ## then again whenever a dependency (added via dependsOn) changes.
  ##
  ## Example:
  ##   let count = newObservable(5)
  ##   let doubled = newComputed(proc(): int = count.get() * 2)
  ##     .dependsOn(count)
  Computed[T](
    obs: newObservable(compute()),
    compute: compute,
    subscriptionIds: @[],
    stale: false
  )

# ==============================================================================
# SECTION 3: VALUE ACCESS
# ==============================================================================

proc get*[T](comp: Computed[T]): T =
  ## Read the computed value, recomputing if stale.
  if comp.stale:
    comp.obs.set(comp.compute())
    comp.stale = false
  comp.obs.get()

proc peek*[T](comp: Computed[T]): T {.inline.} =
  ## Read value without recomputing even if stale.
  ## Use when you know the value is current.
  comp.obs.peek()

# ==============================================================================
# SECTION 4: DEPENDENCY DECLARATION
# ==============================================================================

proc dependsOn*[T, S](comp: Computed[T], source: Observable[S]): Computed[T] =
  ## Declare that this computed depends on a source observable.
  ## Returns self for chaining.
  ##
  ## When the source changes, the computed is marked stale.
  ## It recomputes on next get() call.
  ##
  ## Example:
  ##   let total = newComputed(proc(): int = a.get() + b.get())
  ##     .dependsOn(a)
  ##     .dependsOn(b)
  let compRef = comp  # Capture for closure

  let subId = source.subscribe(proc(value: S): proc() =
    compRef.stale = true
    # Trigger recomputation and notify computed's observers
    discard compRef.get()
    nil
  )

  comp.subscriptionIds.add(subId)
  result = comp

# ==============================================================================
# SECTION 5: SUBSCRIPTION (delegates to internal observable)
# ==============================================================================

proc subscribe*[T](comp: Computed[T], fn: Observer[T]): SubscriptionId =
  ## Subscribe to computed value changes.
  ## Works the same as Observable.subscribe.
  comp.obs.subscribe(fn)

proc subscribeSimple*[T](comp: Computed[T], fn: proc(value: T)) =
  ## Subscribe without cleanup. Convenience for simple observers.
  comp.obs.subscribeSimple(fn)

proc unsubscribe*[T](comp: Computed[T], id: SubscriptionId) =
  ## Remove a subscription from this computed.
  comp.obs.unsubscribe(id)

# ==============================================================================
# SECTION 6: CLEANUP
# ==============================================================================

proc dispose*[T](comp: Computed[T]) =
  ## Clean up all dependency subscriptions.
  ##
  ## Call this when the computed is no longer needed to prevent
  ## memory leaks from lingering subscriptions.
  ##
  ## Note: This does NOT unsubscribe observers of this computed -
  ## only the computed's subscriptions to its dependencies.
  comp.subscriptionIds = @[]
  comp.obs.unsubscribeAll()

# ==============================================================================
# SECTION 7: COMBINATORS
# ==============================================================================

proc combine*[A, B, R](
  a: Observable[A],
  b: Observable[B],
  fn: proc(a: A, b: B): R
): Computed[R] =
  ## Combine two observables into a computed value.
  ##
  ## Example:
  ##   let fullName = combine(firstName, lastName,
  ##     proc(f, l: string): string = f & " " & l)
  result = newComputed(proc(): R = fn(a.get(), b.get()))
    .dependsOn(a)
    .dependsOn(b)

proc combine*[A, B, C, R](
  a: Observable[A],
  b: Observable[B],
  c: Observable[C],
  fn: proc(a: A, b: B, c: C): R
): Computed[R] =
  ## Combine three observables into a computed value.
  result = newComputed(proc(): R = fn(a.get(), b.get(), c.get()))
    .dependsOn(a)
    .dependsOn(b)
    .dependsOn(c)

proc combine*[A, B, C, D, R](
  a: Observable[A],
  b: Observable[B],
  c: Observable[C],
  d: Observable[D],
  fn: proc(a: A, b: B, c: C, d: D): R
): Computed[R] =
  ## Combine four observables into a computed value.
  result = newComputed(proc(): R = fn(a.get(), b.get(), c.get(), d.get()))
    .dependsOn(a)
    .dependsOn(b)
    .dependsOn(c)
    .dependsOn(d)
