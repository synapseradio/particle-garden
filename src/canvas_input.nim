# ==============================================================================
# PARTICLE GARDEN - CANVAS INPUT
# ==============================================================================
#
# Mouse and touch input on the simulation canvas, plus the window-resize and
# particle-reinit callbacks app.nim registers. This is the physics-input
# side of the old ui.nim; everything panel-shaped lives in the Solid UI
# behind window.gardenAPI (web_api.nim).
#
# The canonical input state is currentInput (Observable[InputState]);
# event handlers compute new state through the pure mouse_handler /
# touch_handler functions and set the observable.
#
# JS-only wiring over natively-tested pure modules; verified by `nimble app`.
#
# ==============================================================================

from std/dom import Event, MouseEvent, TouchEvent, preventDefault

from std/jsffi import JsObject

from bindings/dom_extensions import
  HTMLCanvasElement, domWindow, addEventListener

import ui/core/observable
import ui/state/input_state
import ui/input/mouse_handler
import ui/input/touch_handler

# ==============================================================================
# SECTION 1: INPUT STATE
# ==============================================================================

var currentInput* = newObservable(initInputState())

proc getMouseX*(): float = currentInput.get().mouseX
proc getMouseY*(): float = currentInput.get().mouseY
proc getMouseDown*(): bool = currentInput.get().mouseDown
proc getMouseRightDown*(): bool = currentInput.get().mouseRightDown
proc getBlastX*(): float = currentInput.get().blastX
proc getBlastY*(): float = currentInput.get().blastY
proc getBlastStrength*(): float = currentInput.get().blastStrength

# Frame update - decays blast in the observable
const BLAST_DECAY_FACTOR = 0.85
proc updateInputState*() =
  let current = currentInput.get()
  if current.hasActiveBlast():
    currentInput.set(current.withBlastDecay(BLAST_DECAY_FACTOR))

# ==============================================================================
# SECTION 2: CALLBACKS
# ==============================================================================

# Set via setInitParticlesCallback - called when particle/species count
# changes require a re-initialization (web_api routes its resetParticles
# and count commits through this).
var onInitParticles* {.exportc.}: proc() = nil

# Set via setResizeCallback - called on window resize
var onResize* {.exportc.}: proc() = nil

proc setInitParticlesCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for particle reinitialization.
  onInitParticles = callback

proc setResizeCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for window resize.
  onResize = callback

# ==============================================================================
# SECTION 3: EVENT SETUP
# ==============================================================================

proc setupEvents*(canvas: JsObject) {.exportc.} =
  ## Set up mouse, touch, and resize event handlers on the canvas.
  ## Handlers use pure functions from mouse_handler/touch_handler to compute
  ## new state, then update the currentInput observable.

  let canvasEl = cast[HTMLCanvasElement](canvas)

  # Window resize
  domWindow.addEventListener("resize", proc() =
    if not onResize.isNil:
      onResize()
  )

  # Mouse events - use pure handlers
  canvasEl.addEventListener("mousedown", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseDown(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseup", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseUp(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseleave", proc(event: MouseEvent) =
    currentInput.set(handleMouseLeave(currentInput.get()))
  )

  # Prevent context menu on right-click
  canvasEl.addEventListener("contextmenu", proc(event: Event) =
    preventDefault(event)
  )

  # Double-click triggers blast effect (powerful repellent)
  canvasEl.addEventListener("dblclick", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleDoubleClick(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mousemove", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseMove(currentInput.get(), eventData))
  )

  # Touch events - use pure handlers
  canvasEl.addEventListener("touchstart", proc(event: TouchEvent) =
    preventDefault(event)
    let eventData = extractTouchData(event)
    currentInput.set(handleTouchStart(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("touchend", proc(event: TouchEvent) =
    # TouchEvent.touches contains remaining touches after this one ends
    let eventData = extractTouchData(event)
    currentInput.set(handleTouchEnd(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("touchmove", proc(event: TouchEvent) =
    preventDefault(event)
    let eventData = extractTouchData(event)
    currentInput.set(handleTouchMove(currentInput.get(), eventData))
  )
