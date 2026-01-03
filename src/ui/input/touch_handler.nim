# ==============================================================================
# TOUCH HANDLER - Pure touch event processing
# ==============================================================================
#
# Pure functions that transform InputState based on touch events.
# Touch is mapped to mouse-like behavior: first touch = left mouse button.
#
# ==============================================================================

import ../state/input_state

# ==============================================================================
# SECTION 1: TOUCH EVENT DATA (extracted from DOM events)
# ==============================================================================

type
  TouchPoint* = object
    ## Single touch point data.
    clientX*: float
    clientY*: float

  TouchEventData* = object
    ## Extracted data from a DOM TouchEvent.
    ## Pure data, no DOM references.
    touches*: seq[TouchPoint]

# ==============================================================================
# SECTION 2: EVENT HANDLERS (pure state transitions)
# ==============================================================================

proc handleTouchStart*(state: InputState; event: TouchEventData): InputState =
  ## Process touch start event.
  ## First touch is treated as left mouse button down.
  if event.touches.len > 0:
    let touch = event.touches[0]
    result = state
      .withMousePosition(touch.clientX, touch.clientY)
      .withMouseDown(true)
  else:
    result = state

proc handleTouchEnd*(state: InputState; event: TouchEventData): InputState =
  ## Process touch end event.
  ## When all touches end, release mouse button.
  if event.touches.len == 0:
    result = state.withMouseDown(false)
  else:
    result = state

proc handleTouchMove*(state: InputState; event: TouchEventData): InputState =
  ## Process touch move event.
  ## Track first touch position.
  if event.touches.len > 0:
    let touch = event.touches[0]
    result = state.withMousePosition(touch.clientX, touch.clientY)
  else:
    result = state

proc handleTouchCancel*(state: InputState): InputState =
  ## Process touch cancel event.
  ## Releases all touch state.
  state.withAllButtonsUp()

# ==============================================================================
# SECTION 3: DOM EVENT EXTRACTION (JS-only)
# ==============================================================================

when defined(js):
  from std/dom import TouchEvent, TouchList

  proc extractTouchData*(event: TouchEvent): TouchEventData =
    ## Extract pure data from DOM TouchEvent.
    result = TouchEventData(touches: @[])

    let touches = event.touches
    for i in 0 ..< touches.len:
      let touch = touches[i]
      result.touches.add(TouchPoint(
        clientX: touch.clientX.float,
        clientY: touch.clientY.float
      ))
