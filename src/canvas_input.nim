# ==============================================================================
# PARTICLE GARDEN - CANVAS INPUT
# ==============================================================================
#
# Mouse and touch input on the simulation canvas, plus the window-resize and
# particle-reinit callbacks app.nim registers. This is the physics-input
# side; everything panel-shaped lives in the Solid UI behind
# window.gardenAPI (web_api.nim).
#
# The canonical input state is currentInput (Observable[InputState]);
# event handlers compute new state through the pure mouse_handler /
# touch_handler functions and set the observable.
#
# JS-only wiring over natively-tested pure modules; verified by `just happen`.
#
# ==============================================================================

from std/dom import Event, MouseEvent, TouchEvent, KeyboardEvent, preventDefault

from std/jsffi import JsObject

from bindings/dom_extensions import
  HTMLCanvasElement, WheelEvent, domWindow, addEventListener

import ui/core/observable
import ui/state/input_state
import ui/input/mouse_handler
import ui/input/touch_handler
import ui/input/wheel_handler
import ui/input/key_handler
import camera_core
import config
import config_ranges

# ==============================================================================
# SECTION 1: INPUT STATE
# ==============================================================================

var currentInput* = newObservable(initInputState())

# ==============================================================================
# CAMERA HOOKS
# ==============================================================================
#
# The camera lives in webgpu_render.nim, which is a layer ABOVE this file in
# app.nim's import order — so it cannot be read from here directly. app.nim
# wires these two, exactly as it wires onResize below. Nil until it does, and
# every camera handler no-ops while they are, so input arriving before the
# render pipeline finishes initializing is ignored rather than crashing.

var cameraGetter*: proc(): Camera = nil
  ## Reads the live camera. Set by app.nim to webgpu_render.camera.
var cameraSetter*: proc(next: Camera) = nil
  ## Replaces the live camera. Set by app.nim to webgpu_render.setCamera.

proc cameraHooksReady(): bool =
  not cameraGetter.isNil and not cameraSetter.isNil

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

# Set via setReseedFieldCallback - called when the reaction-diffusion field
# should be re-seeded with a fresh pattern. Same indirection as
# onInitParticles, and for the same reason: web_api is Layer 3 and cannot
# import Layer 4's webgpu_compute, where the seed request actually lives.
var onReseedField* {.exportc.}: proc() = nil

# Set via setResizeParticlesCallback - called when the particle COUNT changes
# and the living population must survive it. Distinct from onInitParticles
# because the two answer different questions: this one grows or thins a world,
# that one replaces it.
var onResizeParticles* {.exportc.}: proc() = nil

proc setInitParticlesCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for particle reinitialization.
  onInitParticles = callback

proc setResizeParticlesCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for a non-destructive particle-count change.
  onResizeParticles = callback

proc setReseedFieldCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for reaction-diffusion field re-seeding.
  onReseedField = callback

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
    # Two fingers down is the touch equivalent of the double-click blast; one
    # finger is an ordinary press.
    if eventData.touches.len >= 2:
      currentInput.set(handleTwoFingerTap(currentInput.get(), eventData))
    else:
      currentInput.set(handleTouchStart(currentInput.get(), eventData))
  )

  # An interrupted touch (an incoming call, a system gesture) fires touchcancel
  # rather than touchend; without this listener the press stays down forever.
  canvasEl.addEventListener("touchcancel", proc(event: TouchEvent) =
    currentInput.set(handleTouchCancel(currentInput.get()))
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

  # Wheel zooms at the cursor. preventDefault stops the page from scrolling
  # underneath the canvas, which in a desktop window reads as the whole app
  # jumping.
  canvasEl.addEventListener("wheel", proc(event: WheelEvent) =
    preventDefault(cast[Event](event))
    if not cameraHooksReady():
      return
    # Cursor position in clip space: x right-positive, y UP-positive. The y
    # inversion here is what undoes the renderer's own flip, so the anchor
    # handed to the handler is in the same space camera_core.toClip returns.
    let width = float(canvasEl.width)
    let height = float(canvasEl.height)
    if width <= 0.0 or height <= 0.0:
      return
    let wheelData = WheelEventData(
      deltaY: float(event.deltaY),
      clipX: (float(event.offsetX) / width) * 2.0 - 1.0,
      clipY: 1.0 - (float(event.offsetY) / height) * 2.0)
    cameraSetter(handleWheel(cameraGetter(), wheelData,
      float32(config.WORLD_W), float32(config.WORLD_H),
      float32(CAMERA_ZOOM_MIN), float32(CAMERA_ZOOM_MAX)))
  )

  # Keyboard navigation. Listens on the WINDOW rather than the canvas: a canvas
  # only receives key events when focused, and this one is never clicked into
  # deliberately, so canvas-scoped bindings would appear dead until the user
  # happened to click the world first.
  domWindow.addEventListener("keydown", proc(event: KeyboardEvent) =
    if not cameraHooksReady():
      return
    let action = cameraKeyFor($event.key)
    if action == ckNone:
      return
    # Only swallow the event once it is known to be a camera binding, so
    # ordinary typing elsewhere in the panel is untouched.
    preventDefault(cast[Event](event))
    cameraSetter(handleCameraKey(cameraGetter(), action,
      float32(config.WORLD_W), float32(config.WORLD_H),
      float32(CAMERA_ZOOM_MIN), float32(CAMERA_ZOOM_MAX)))
  )
