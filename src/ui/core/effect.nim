# ==============================================================================
# EFFECT - Side effects with automatic cleanup
# ==============================================================================
#
# Effects run side effects when observables change. They manage cleanup
# functions to prevent memory leaks, especially with DOM event listeners.
#
# The Effect type wraps a subscription and manages its lifecycle.
# When disposed, it unsubscribes and runs final cleanup.
#
# ==============================================================================

import observable

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  ## An effect that runs when an observable changes.
  ## Manages cleanup automatically.
  Effect* = ref object
    disposed: bool
    cleanup: proc()  # Current cleanup function

# ==============================================================================
# SECTION 2: EFFECT CREATION
# ==============================================================================

proc effect*[T](obs: Observable[T], fn: proc(value: T): proc()): Effect =
  ## Create an effect that runs when the observable changes.
  ##
  ## The effect function receives the current value and returns
  ## a cleanup function (or nil). Cleanup runs before the next
  ## invocation and when the effect is disposed.
  ##
  ## Example:
  ##   let eff = effect(mousePos, proc(pos: tuple[x, y: float]): proc() =
  ##     # Set up something based on position
  ##     element.style.left = $pos.x & "px"
  ##
  ##     # Return cleanup
  ##     return proc() =
  ##       echo "Cleaning up for position ", pos
  ##   )
  ##
  ##   # Later, stop the effect:
  ##   eff.dispose()
  result = Effect(disposed: false, cleanup: nil)

  let eff = result

  discard obs.subscribe(proc(value: T): proc() =
    if eff.disposed:
      return nil

    # Run previous cleanup
    if not eff.cleanup.isNil:
      eff.cleanup()

    # Run effect and store cleanup
    eff.cleanup = fn(value)

    # The observable manages its own cleanup, we manage ours separately
    return nil
  )

proc effectSimple*[T](obs: Observable[T], fn: proc(value: T)): Effect =
  ## Create an effect without cleanup.
  ##
  ## Example:
  ##   let eff = effectSimple(count, proc(c: int) =
  ##     echo "Count is now: ", c
  ##   )
  effect(obs, proc(value: T): proc() =
    fn(value)
    nil
  )

# ==============================================================================
# SECTION 3: MULTI-OBSERVABLE EFFECTS
# ==============================================================================

proc effectAll*[T](
  observables: seq[Observable[T]],
  fn: proc(values: seq[T]): proc()
): Effect =
  ## Create an effect that runs when ANY of the observables change.
  ##
  ## The effect receives all current values as a sequence.
  ##
  ## Example:
  ##   let eff = effectAll(@[x, y, z], proc(vals: seq[float]): proc() =
  ##     echo "Position: ", vals[0], ", ", vals[1], ", ", vals[2]
  ##     nil
  ##   )
  result = Effect(disposed: false, cleanup: nil)

  let eff = result
  let obs = observables  # Capture

  # Subscribe to all observables
  for o in observables:
    discard o.subscribe(proc(value: T): proc() =
      if eff.disposed:
        return nil

      # Collect all current values
      var values: seq[T] = @[]
      for ob in obs:
        values.add(ob.get())

      # Run previous cleanup
      if not eff.cleanup.isNil:
        eff.cleanup()

      # Run effect
      eff.cleanup = fn(values)

      return nil
    )

proc effect2*[A, B](
  a: Observable[A],
  b: Observable[B],
  fn: proc(a: A, b: B): proc()
): Effect =
  ## Create an effect that runs when either of two observables change.
  ##
  ## Example:
  ##   let eff = effect2(width, height, proc(w, h: int): proc() =
  ##     canvas.resize(w, h)
  ##     nil
  ##   )
  result = Effect(disposed: false, cleanup: nil)

  let eff = result
  let obsA = a
  let obsB = b

  proc runEffect() =
    if eff.disposed:
      return

    if not eff.cleanup.isNil:
      eff.cleanup()

    eff.cleanup = fn(obsA.get(), obsB.get())

  discard a.subscribe(proc(value: A): proc() =
    runEffect()
    nil
  )

  discard b.subscribe(proc(value: B): proc() =
    runEffect()
    nil
  )

# ==============================================================================
# SECTION 4: LIFECYCLE
# ==============================================================================

proc dispose*(eff: Effect) =
  ## Stop the effect and run final cleanup.
  ##
  ## After disposal, the effect will not run again.
  ##
  ## Example:
  ##   eff.dispose()
  if eff.disposed:
    return

  eff.disposed = true

  if not eff.cleanup.isNil:
    eff.cleanup()
    eff.cleanup = nil

proc isDisposed*(eff: Effect): bool =
  ## Check if the effect has been disposed.
  eff.disposed

# ==============================================================================
# SECTION 5: UTILITY EFFECTS
# ==============================================================================

proc onChange*[T](obs: Observable[T], fn: proc(newVal, oldVal: T)): Effect =
  ## Create an effect that provides both new and old values.
  ##
  ## Useful for animations or transitions that need to interpolate.
  ##
  ## Example:
  ##   let eff = onChange(position, proc(new, old: float) =
  ##     animate(old, new)
  ##   )
  var previous = obs.get()

  effect(obs, proc(value: T): proc() =
    let old = previous
    previous = value
    fn(value, old)
    nil
  )

proc debounced*[T](
  obs: Observable[T],
  delayMs: int,
  fn: proc(value: T): proc()
): Effect =
  ## Create an effect that debounces rapid changes.
  ##
  ## The effect only runs after the observable has been stable
  ## for delayMs milliseconds.
  ##
  ## Note: Only works in JS context (uses setTimeout).
  when defined(js):
    proc setTimeout(fn: proc(), delay: int): int {.importjs: "setTimeout(#, #)".}
    proc clearTimeout(id: int) {.importjs: "clearTimeout(#)".}

    result = Effect(disposed: false, cleanup: nil)

    let eff = result
    var timeoutId = 0

    discard obs.subscribe(proc(value: T): proc() =
      if eff.disposed:
        return nil

      # Clear pending timeout
      if timeoutId != 0:
        clearTimeout(timeoutId)

      # Schedule new timeout
      let currentValue = value
      timeoutId = setTimeout(proc() =
        if not eff.disposed:
          if not eff.cleanup.isNil:
            eff.cleanup()
          eff.cleanup = fn(currentValue)
        timeoutId = 0
      , delayMs)

      return nil
    )
  else:
    # Native: no debouncing, run immediately
    result = effect(obs, fn)
