# ==============================================================================
# MOUSE HANDLER - Pure mouse event processing
# ==============================================================================
#
# Pure functions that transform InputState based on mouse events.
# No DOM access, no side effects - just state transitions.
#
# Each handler takes current state + event data, returns new state.
# This makes mouse handling testable without a browser.
#
# ==============================================================================

import ../state/input_state

# ==============================================================================
# SECTION 1: MOUSE EVENT DATA (extracted from DOM events)
# ==============================================================================

type
  MouseButton* = enum
    mbLeft = 0
    mbMiddle = 1
    mbRight = 2

  MouseEventData* = object
    ## Extracted data from a DOM MouseEvent.
    ## Pure data, no DOM references.
    clientX*: float
    clientY*: float
    button*: MouseButton

# ==============================================================================
# SECTION 2: EVENT HANDLERS (pure state transitions)
# ==============================================================================

func handleMouseDown*(state: InputState; event: MouseEventData): InputState =
  result = state.withMousePosition(event.clientX, event.clientY)
  case event.button
  of mbLeft:
    result = result.withMouseDown(true)
  of mbRight:
    result = result.withMouseRightDown(true)
  of mbMiddle:
    # The middle button pans the camera (canvas_input, pan_handler) and reaches
    # physics input nowhere.
    discard

func handleMouseUp*(state: InputState; event: MouseEventData): InputState =
  case event.button
  of mbLeft:
    result = state.withMouseDown(false)
  of mbRight:
    result = state.withMouseRightDown(false)
  of mbMiddle:
    result = state

func handleMouseMove*(state: InputState; event: MouseEventData): InputState =
  state.withMousePosition(event.clientX, event.clientY)

func handleMouseLeave*(state: InputState): InputState =
  state.withAllButtonsUp()

func handleDoubleClick*(state: InputState; event: MouseEventData): InputState =
  ## Also clears mouseDown, to prevent a stuck state from event timing.
  state.withBlast(event.clientX, event.clientY).withMouseDown(false)

# ==============================================================================
# SECTION 3: FRAME UPDATE
# ==============================================================================

const
  BLAST_DECAY_FACTOR* = 0.85  ## Per-frame decay (~300ms lifespan at 60fps)

func updateFrame*(state: InputState): InputState =
  if state.hasActiveBlast():
    state.withBlastDecay(BLAST_DECAY_FACTOR)
  else:
    state

# ==============================================================================
# SECTION 4: DOM EVENT EXTRACTION (JS-only)
# ==============================================================================

when defined(js):
  from std/dom import MouseEvent

  proc extractMouseData*(event: MouseEvent): MouseEventData =
    MouseEventData(
      clientX: event.clientX.float,
      clientY: event.clientY.float,
      button: MouseButton(event.button)
    )
