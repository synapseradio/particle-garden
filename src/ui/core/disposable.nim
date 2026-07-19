# ==============================================================================
# DISPOSABLE - Cleanup management utilities
# ==============================================================================
#
# Provides tools for managing cleanup of multiple subscriptions, effects,
# and other resources that need disposal.
#
# The DisposableGroup collects cleanup functions and executes them all
# when disposed. This is essential for component cleanup to prevent
# memory leaks from orphaned subscriptions.
#
# ==============================================================================

import observable
import effect

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  ## A group of cleanup functions that can be disposed together.
  DisposableGroup* = ref object
    cleanups: seq[proc()]
    disposed: bool

# ==============================================================================
# SECTION 2: CONSTRUCTOR
# ==============================================================================

proc newDisposableGroup*(): DisposableGroup =
  ## Create a new disposable group.
  ##
  ## Example:
  ##   let disposables = newDisposableGroup()
  DisposableGroup(cleanups: @[], disposed: false)

# ==============================================================================
# SECTION 3: ADDING DISPOSABLES
# ==============================================================================

proc add*(group: DisposableGroup, cleanup: proc()) =
  ## Add a cleanup function to the group.
  ##
  ## Example:
  ##   disposables.add(proc() =
  ##     element.removeEventListener("click", handler)
  ##   )
  if group.disposed:
    # Already disposed - run cleanup immediately
    cleanup()
  else:
    group.cleanups.add(cleanup)

proc add*(group: DisposableGroup, eff: Effect) =
  ## Add an effect to the group.
  ##
  ## Example:
  ##   let eff = effect(count, proc(c: int): proc() = ...)
  ##   disposables.add(eff)
  group.add(proc() = eff.dispose())

proc addSubscription*[T](
  group: DisposableGroup,
  obs: Observable[T],
  id: SubscriptionId
) =
  ## Add a subscription to the group for later unsubscription.
  ##
  ## Example:
  ##   let subId = obs.subscribe(...)
  ##   disposables.addSubscription(obs, subId)
  import observable
  group.add(proc() = obs.unsubscribe(id))

# ==============================================================================
# SECTION 4: DISPOSAL
# ==============================================================================

proc dispose*(group: DisposableGroup) =
  ## Dispose all items in reverse order (LIFO).
  ##
  ## Reverse order ensures that items added later (which may depend
  ## on earlier items) are cleaned up first.
  ##
  ## Example:
  ##   disposables.dispose()
  if group.disposed:
    return

  group.disposed = true

  # Dispose in reverse order (LIFO)
  for idx in countdown(group.cleanups.high, 0):
    group.cleanups[idx]()

  group.cleanups = @[]

proc isDisposed*(group: DisposableGroup): bool =
  ## Check if the group has been disposed.
  group.disposed

proc count*(group: DisposableGroup): int =
  ## Return the number of pending cleanups.
  group.cleanups.len

# ==============================================================================
# SECTION 5: SCOPED DISPOSAL
# ==============================================================================

template withDisposables*(body: untyped) =
  ## Create a disposable group that is automatically disposed
  ## when the scope exits.
  ##
  ## Example:
  ##   withDisposables:
  ##     disposables.add(effect1)
  ##     disposables.add(effect2)
  ##     # disposables is automatically disposed at end of block
  let disposables {.inject.} = newDisposableGroup()
  try:
    body
  finally:
    disposables.dispose()

# ==============================================================================
# SECTION 6: DOM EVENT HELPERS
# ==============================================================================

when defined(js):
  from std/dom import Element, Event, addEventListener, removeEventListener

  proc onEvent*(
    group: DisposableGroup,
    element: Element,
    eventName: cstring,
    handler: proc(event: Event)
  ) =
    ## Attach an event listener and register cleanup with the group.
    ##
    ## Example:
    ##   disposables.onEvent(button, "click", proc(event: Event) =
    ##     handleClick()
    ##   )
    element.addEventListener(eventName, handler)
    group.add(proc() =
      element.removeEventListener(eventName, handler)
    )

  proc onEventCapture*(
    group: DisposableGroup,
    element: Element,
    eventName: cstring,
    handler: proc(event: Event)
  ) =
    ## Attach an event listener with capture and register cleanup.
    {.emit: """
    `element`.addEventListener(`eventName`, `handler`, true);
    """.}
    group.add(proc() =
      {.emit: """
      `element`.removeEventListener(`eventName`, `handler`, true);
      """.}
    )

# ==============================================================================
# SECTION 7: UTILITY FUNCTIONS
# ==============================================================================

proc disposeAll*(disposables: varargs[DisposableGroup]) =
  ## Dispose multiple groups at once.
  ##
  ## Example:
  ##   disposeAll(group1, group2, group3)
  for group in disposables:
    group.dispose()

proc link*(parent: DisposableGroup, child: DisposableGroup) =
  ## Link a child group to a parent.
  ##
  ## When the parent is disposed, the child is also disposed.
  ##
  ## Example:
  ##   parent.link(child)
  parent.add(proc() = child.dispose())
