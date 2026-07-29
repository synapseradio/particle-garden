# ==============================================================================
# INPUT STATE - Mouse, touch, and blast effect state
# ==============================================================================
#
# Pure data types representing user input state. No DOM, no side effects.
# This module defines the shape of input state that flows through the system.
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

func initInputState*(): InputState =
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

func withMousePosition*(state: InputState; posX, posY: float): InputState =
  result = state
  result.mouseX = posX
  result.mouseY = posY

func withMouseDown*(state: InputState; down: bool): InputState =
  result = state
  result.mouseDown = down

func withMouseRightDown*(state: InputState; down: bool): InputState =
  result = state
  result.mouseRightDown = down

func withAllButtonsUp*(state: InputState): InputState =
  result = state
  result.mouseDown = false
  result.mouseRightDown = false

func withBlast*(state: InputState; posX, posY: float): InputState =
  result = state
  result.blastX = posX
  result.blastY = posY
  result.blastStrength = 1.0

func withBlastDecay*(state: InputState; decayFactor: float): InputState =
  result = state
  result.blastStrength = state.blastStrength * decayFactor

func withBlastCleared*(state: InputState): InputState =
  result = state
  result.blastStrength = 0.0

# ==============================================================================
# SECTION 4: QUERIES
# ==============================================================================

func hasActiveBlast*(state: InputState): bool =
  state.blastStrength > 0.001

func isAnyButtonDown*(state: InputState): bool =
  state.mouseDown or state.mouseRightDown
