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
  ## Process mouse down event. Returns new state.
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
  ## Process mouse up event. Returns new state.
  case event.button
  of mbLeft:
    result = state.withMouseDown(false)
  of mbRight:
    result = state.withMouseRightDown(false)
  of mbMiddle:
    result = state

func handleMouseMove*(state: InputState; event: MouseEventData): InputState =
  ## Process mouse move event. Returns new state.
  state.withMousePosition(event.clientX, event.clientY)

func handleMouseLeave*(state: InputState): InputState =
  ## Process mouse leave event. Releases all buttons.
  state.withAllButtonsUp()

func handleDoubleClick*(state: InputState; event: MouseEventData): InputState =
  ## Process double-click event. Triggers blast at position.
  ## Also clears mouseDown to prevent stuck state from event timing.
  state.withBlast(event.clientX, event.clientY).withMouseDown(false)

# ==============================================================================
# SECTION 3: FRAME UPDATE
# ==============================================================================

const
  BLAST_DECAY_FACTOR* = 0.85  ## Per-frame decay (~300ms lifespan at 60fps)

func updateFrame*(state: InputState): InputState =
  ## Per-frame update. Decays blast effect.
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
    ## Extract pure data from DOM MouseEvent.
    MouseEventData(
      clientX: event.clientX.float,
      clientY: event.clientY.float,
      button: MouseButton(event.button)
    )
