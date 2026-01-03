# ==============================================================================
# INPUT STATE - Mouse, touch, and blast effect state
# ==============================================================================
#
# Pure data types representing user input state. No DOM, no side effects.
# This module defines the shape of input state that flows through the system.
#
# Previously this state lived as mutable globals in ui.nim:
#   mouseX, mouseY, mouseDown, mouseRightDown
#   blastX, blastY, blastStrength
#
# Now it's a single immutable record updated via pure functions.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: INPUT STATE TYPE
# ==============================================================================

type
  InputState* = object
    ## Complete input state for the simulation.
    ## Immutable - updates return new state.

    # Mouse position (canvas coordinates)
    mouseX*: float
    mouseY*: float

    # Mouse button state
    mouseDown*: bool       # Left button
    mouseRightDown*: bool  # Right button

    # Blast effect (triggered by double-click)
    # blastStrength decays from 1.0 to 0.0 over ~300ms
    blastX*: float
    blastY*: float
    blastStrength*: float

# ==============================================================================
# SECTION 2: CONSTRUCTORS
# ==============================================================================

proc initInputState*(): InputState =
  ## Create initial input state with all values zeroed.
  InputState(
    mouseX: 0.0,
    mouseY: 0.0,
    mouseDown: false,
    mouseRightDown: false,
    blastX: 0.0,
    blastY: 0.0,
    blastStrength: 0.0
  )

# ==============================================================================
# SECTION 3: PURE UPDATE FUNCTIONS
# ==============================================================================

proc withMousePosition*(state: InputState; x, y: float): InputState =
  ## Return new state with updated mouse position.
  result = state
  result.mouseX = x
  result.mouseY = y

proc withMouseDown*(state: InputState; down: bool): InputState =
  ## Return new state with updated left mouse button.
  result = state
  result.mouseDown = down

proc withMouseRightDown*(state: InputState; down: bool): InputState =
  ## Return new state with updated right mouse button.
  result = state
  result.mouseRightDown = down

proc withAllButtonsUp*(state: InputState): InputState =
  ## Return new state with all mouse buttons released.
  result = state
  result.mouseDown = false
  result.mouseRightDown = false

proc withBlast*(state: InputState; x, y: float): InputState =
  ## Return new state with blast triggered at position.
  result = state
  result.blastX = x
  result.blastY = y
  result.blastStrength = 1.0

proc withBlastDecay*(state: InputState; decayFactor: float): InputState =
  ## Return new state with blast strength decayed.
  ## Typical decay: blastStrength *= 0.85 per frame (~300ms lifespan)
  result = state
  result.blastStrength = state.blastStrength * decayFactor

proc withBlastCleared*(state: InputState): InputState =
  ## Return new state with blast effect cleared.
  result = state
  result.blastStrength = 0.0

# ==============================================================================
# SECTION 4: QUERIES
# ==============================================================================

proc hasActiveBlast*(state: InputState): bool =
  ## Check if blast effect is still active.
  state.blastStrength > 0.001

proc isAnyButtonDown*(state: InputState): bool =
  ## Check if any mouse button is pressed.
  state.mouseDown or state.mouseRightDown
