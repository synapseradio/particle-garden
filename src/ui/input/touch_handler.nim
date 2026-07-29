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

func handleTouchStart*(state: InputState; event: TouchEventData): InputState =
  ## First touch is treated as left mouse button down.
  if event.touches.len > 0:
    let touch = event.touches[0]
    result = state
      .withMousePosition(touch.clientX, touch.clientY)
      .withMouseDown(true)
  else:
    result = state

func handleTouchEnd*(state: InputState; event: TouchEventData): InputState =
  if event.touches.len == 0:
    result = state.withMouseDown(false)
  else:
    result = state

func handleTouchMove*(state: InputState; event: TouchEventData): InputState =
  if event.touches.len > 0:
    let touch = event.touches[0]
    result = state.withMousePosition(touch.clientX, touch.clientY)
  else:
    result = state

func handleTouchCancel*(state: InputState): InputState =
  state.withAllButtonsUp()

func handleTwoFingerTap*(state: InputState; event: TouchEventData): InputState =
  ## Two fingers down fires a blast at their midpoint — the touch equivalent of
  ## the mouse's double-click blast.
  ##
  ## The midpoint rather than either finger: a blast at one of two touch points
  ## would place the effect off to the side of the gesture, and which side would
  ## depend on the undefined order the browser reports touches in.
  ##
  ## Also clears mouseDown, for the same reason handleDoubleClick does — the
  ## first finger already registered as a press, and leaving it set strands the
  ## state as held after the fingers lift.
  if event.touches.len < 2:
    return state
  let midpointX = (event.touches[0].clientX + event.touches[1].clientX) * 0.5
  let midpointY = (event.touches[0].clientY + event.touches[1].clientY) * 0.5
  state.withBlast(midpointX, midpointY).withMouseDown(false)

# ==============================================================================
# SECTION 3: DOM EVENT EXTRACTION (JS-only)
# ==============================================================================

when defined(js):
  from std/dom import TouchEvent, TouchList

  proc extractTouchData*(event: TouchEvent): TouchEventData =
    result = TouchEventData(touches: @[])

    let touches = event.touches
    for idx in 0 ..< touches.len:
      let touch = touches[idx]
      result.touches.add(TouchPoint(
        clientX: touch.clientX.float,
        clientY: touch.clientY.float
      ))
