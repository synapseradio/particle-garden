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

from std/dom import Event, MouseEvent, TouchEvent, KeyboardEvent, Node, Element,
  preventDefault

from std/jsffi import JsObject

from bindings/dom_extensions import
  HTMLCanvasElement, WheelEvent, domWindow, addEventListener,
  addNonPassiveEventListener

import ui/core/observable
import ui/state/input_state
import ui/input/mouse_handler
import ui/input/touch_handler
import ui/input/wheel_handler
import ui/input/pan_handler
import ui/input/key_handler
import camera_core
import config
import config_ranges

var currentInput* = newObservable(initInputState())

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

var cameraTouched = false

proc setCameraFromUser*(next: Camera) =
  ## The camera write every user-facing path takes: a drag, a wheel, a key, the
  ## Zoom slider. It stamps the camera as touched so the drift yields; a writer
  ## that is not the user takes cameraSetter and leaves the stamp alone.
  cameraTouched = true
  cameraSetter(next)

proc takeCameraTouch*(): bool =
  ## Whether a user-facing camera write landed since the last read, clearing
  ## the stamp. One reader only, the frame loop.
  result = cameraTouched
  cameraTouched = false

var panSession = initPanSession()
  ## Whether a middle-button drag is moving the camera. Camera state rather
  ## than physics input, so it lives beside the camera hooks instead of in
  ## currentInput, and left-drag interaction is untouched by it.

var dragOverlayId* = ""
  ## Parameter id of the slider mid-drag, "" when none. web_api writes it from
  ## the panel's drag events; webgpu_render reads it to draw the spatial
  ## overlay. Lives here so both sit on the right side of the layer order.

proc getMouseX*(): float = currentInput.get().mouseX
proc getMouseY*(): float = currentInput.get().mouseY
proc getMouseDown*(): bool = currentInput.get().mouseDown
proc getMouseRightDown*(): bool = currentInput.get().mouseRightDown
proc getBlastX*(): float = currentInput.get().blastX
proc getBlastY*(): float = currentInput.get().blastY
proc getBlastStrength*(): float = currentInput.get().blastStrength

const BLAST_DECAY_FACTOR = 0.85
proc updateInputState*() =
  let current = currentInput.get()
  if current.hasActiveBlast():
    currentInput.set(current.withBlastDecay(BLAST_DECAY_FACTOR))

# Set via setInitParticlesCallback - called when particle/species count
# changes require a re-initialization (web_api routes its resetParticles
# and count commits through this).
var onInitParticles* {.exportc.}: proc() = nil

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
  onInitParticles = callback

proc setResizeParticlesCallback*(callback: proc()) {.exportc.} =
  onResizeParticles = callback

proc setReseedFieldCallback*(callback: proc()) {.exportc.} =
  onReseedField = callback

proc setResizeCallback*(callback: proc()) {.exportc.} =
  onResize = callback

proc setupEvents*(canvas: JsObject) {.exportc.} =
  let canvasEl = cast[HTMLCanvasElement](canvas)

  proc pointerWorld(pixelX, pixelY: float): tuple[x, y: float32] =
    ## The world point under a pointer pixel, through the live camera. Before
    ## app.nim wires the camera hooks the default camera stands in, which is
    ## exact while nothing can have moved the view yet.
    let camera =
      if cameraGetter.isNil:
        initCamera(float32(config.WORLD_W), float32(config.WORLD_H))
      else:
        cameraGetter()
    screenPixelToWorld(float32(pixelX), float32(pixelY),
      float32(canvasEl.width), float32(canvasEl.height),
      camera, float32(config.WORLD_W), float32(config.WORLD_H))

  domWindow.addEventListener("resize", proc() =
    if not onResize.isNil:
      onResize()
  )

  canvasEl.addEventListener("mousedown", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    if eventData.button == mbMiddle:
      # Autoscroll otherwise drops a scroll puck on the canvas and eats the
      # drag; the middle button pans the camera here instead.
      preventDefault(event)
    panSession = panPressed(panSession, eventData.button,
      eventData.clientX, eventData.clientY)
    currentInput.set(handleMouseDown(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseup", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    panSession = panReleased(panSession, eventData.button)
    currentInput.set(handleMouseUp(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseleave", proc(event: MouseEvent) =
    # A pointer that leaves mid-drag returns from anywhere, and resuming from
    # a stale position would jump the view by however far it travelled unseen.
    panSession = initPanSession()
    currentInput.set(handleMouseLeave(currentInput.get()))
  )

  canvasEl.addEventListener("contextmenu", proc(event: Event) =
    preventDefault(event)
  )

  # Double-click triggers blast effect (powerful repellent). The click
  # converts to world space HERE, at capture: a blast pins a moment to a world
  # point, so a camera move during its decay must not drag it with the screen.
  # The same zero-size guard the wheel handler uses, and for the same reason:
  # a canvas mid-resize has no pixels to divide by.
  canvasEl.addEventListener("dblclick", proc(event: MouseEvent) =
    if float(canvasEl.width) <= 0.0 or float(canvasEl.height) <= 0.0:
      return
    var eventData = extractMouseData(event)
    let world = pointerWorld(eventData.clientX, eventData.clientY)
    eventData.clientX = float(world.x)
    eventData.clientY = float(world.y)
    currentInput.set(handleDoubleClick(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mousemove", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseMove(currentInput.get(), eventData))
    # Mousemove fires whether or not a button is down, so the session decides
    # that a move pans; with none in progress panMoved reports no travel.
    let moved = panMoved(panSession, eventData.clientX, eventData.clientY)
    panSession = moved.session
    if panSession.active and cameraHooksReady():
      setCameraFromUser(grabPanned(cameraGetter(), moved.dx, moved.dy,
        float32(config.WORLD_W), float32(config.WORLD_H),
        float32(canvasEl.width), float32(canvasEl.height)))
  )

  canvasEl.addEventListener("touchstart", proc(event: TouchEvent) =
    preventDefault(event)
    let eventData = extractTouchData(event)
    # Two fingers down is the touch equivalent of the double-click blast; one
    # finger is an ordinary press. The tap's touches convert to world space at
    # capture, exactly as the dblclick above does: the pixel-to-world transform
    # is affine, so the midpoint the handler takes lands on the converted
    # midpoint. The one-finger press stays in canvas pixels — it feeds the live
    # cursor, which app.nim converts per frame through the current camera.
    if eventData.touches.len >= 2:
      if float(canvasEl.width) <= 0.0 or float(canvasEl.height) <= 0.0:
        return
      var worldTap = eventData
      for touch in worldTap.touches.mitems:
        let world = pointerWorld(touch.clientX, touch.clientY)
        touch.clientX = float(world.x)
        touch.clientY = float(world.y)
      currentInput.set(handleTwoFingerTap(currentInput.get(), worldTap))
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

  # Wheel carries both camera gestures: a plain scroll pans, and a scroll with
  # ctrl or cmd held zooms at the cursor, which is the shape a trackpad pinch
  # arrives in. Both preventDefault, and both must: the pan replaces page
  # scroll, which in a desktop window reads as the whole app jumping, and the
  # zoom replaces the browser's page zoom, which would resize the app itself
  # under the gesture. Registered non-passive so those calls are honoured.
  canvasEl.addNonPassiveEventListener("wheel", proc(event: WheelEvent) =
    preventDefault(cast[Event](event))
    if not cameraHooksReady():
      return
    let width = float(canvasEl.width)
    let height = float(canvasEl.height)
    if width <= 0.0 or height <= 0.0:
      return
    let wheelData = WheelEventData(
      deltaX: float(event.deltaX),
      deltaY: float(event.deltaY),
      zoomModifier: event.ctrlKey or event.metaKey,
      # Cursor position in clip space: x right-positive, y UP-positive. The y
      # inversion here is what undoes the renderer's own flip, so the anchor
      # handed to the handler is in the same space camera_core.toClip returns.
      clipX: (float(event.offsetX) / width) * 2.0 - 1.0,
      clipY: 1.0 - (float(event.offsetY) / height) * 2.0)
    case wheelGesture(wheelData)
    of wgZoom:
      setCameraFromUser(handleWheel(cameraGetter(), wheelData,
        float32(config.WORLD_W), float32(config.WORLD_H),
        float32(CAMERA_ZOOM_MIN), float32(CAMERA_ZOOM_MAX)))
    of wgPan:
      setCameraFromUser(handleWheelPan(cameraGetter(), wheelData,
        float32(config.WORLD_W), float32(config.WORLD_H),
        float32(width), float32(height)))
  )

  # Keyboard navigation. Listens on the WINDOW rather than the canvas: a canvas
  # only receives key events when focused, and this one is never clicked into
  # deliberately, so canvas-scoped bindings would appear dead until the user
  # happened to click the world first.
  #
  # Listening that wide is why keyContextOf exists: every keystroke in the panel
  # arrives here too, including the ones a text field is entitled to.
  proc keyContextOf(event: KeyboardEvent): KeyContext =
    let target = cast[Event](event).target
    var typing = false
    if not target.isNil:
      typing = $target.nodeName in ["INPUT", "TEXTAREA", "SELECT"] or
        cast[Element](target).isContentEditable
    KeyContext(
      modified: event.ctrlKey or event.metaKey or event.altKey,
      intoTextEntry: typing)

  domWindow.addEventListener("keydown", proc(event: KeyboardEvent) =
    if not cameraHooksReady():
      return
    let action = cameraKeyFor($event.key, keyContextOf(event))
    if action == ckNone:
      return
    # Only swallow the event once it is known to be a camera binding, so
    # ordinary typing elsewhere in the panel is untouched.
    preventDefault(cast[Event](event))
    setCameraFromUser(handleCameraKey(cameraGetter(), action,
      float32(config.WORLD_W), float32(config.WORLD_H),
      float32(CAMERA_ZOOM_MIN), float32(CAMERA_ZOOM_MAX)))
  )
