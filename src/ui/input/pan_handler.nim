# ==============================================================================
# PAN HANDLER - Pure screen-pixel panning
# ==============================================================================
#
# Pure functions moving a Camera by a gesture measured in screen pixels, and the
# session that says whether a middle-button drag is under way. No DOM
# references, so both the scaling and the drag's start/move/end sequence are
# native-tested rather than only observable by dragging at a running app.
#
# TWO GESTURES PAN, AND THEY POINT OPPOSITE WAYS. A scroll moves the VIEW the
# way it points, the way a document scrolls under a wheel. A drag moves the
# WORLD with the pointer, so whatever was grabbed stays under the hand. Both
# conventions ship in every map and image editor, and a user who has either one
# backwards notices within one gesture, so each has its own named function and
# its own test rather than a sign chosen at a call site.
#
# ==============================================================================

import ../../camera_core
import ./mouse_handler

# ==============================================================================
# SECTION 1: SCREEN PIXELS TO WORLD UNITS
# ==============================================================================

func pixelPanDelta*(pixelDelta: float;
    worldSpan, viewSpanPx, zoom: float32): float32 =
  ## The world distance a gesture covers along one axis when it travels
  ## `pixelDelta` screen pixels.
  ##
  ## Divides by zoom, which is what makes a gesture cover the same SCREEN
  ## distance at every camera: at 8x one world unit spans eight times the
  ## pixels, so the world offset a hand's travel names shrinks to match. What a
  ## user judges is how far the picture moved under their fingers, never how far
  ## the centre moved through the world.
  ##
  ## The view span arrives in the units the canvas reports its own width in,
  ## which is what makes the ratio exact rather than approximate — canvas.width
  ## comes from window.innerWidth, the same scale pointer coordinates use.
  ##
  ## Zero when the view has no pixels or the camera has no zoom. Both divide by
  ## zero, and an infinite offset folds to NaN in the camera centre, which no
  ## later gesture recovers from: every subsequent comparison against a NaN
  ## centre is false, so the view would stay lost until reload.
  if viewSpanPx <= 0.0'f32 or zoom <= 0.0'f32: 0.0'f32
  else: pixelDelta.float32 * worldSpan / (viewSpanPx * zoom)

func viewPanned*(camera: Camera; pixelDx, pixelDy: float;
    worldWidth, worldHeight, viewWidthPx, viewHeightPx: float32): Camera =
  ## The camera after the VIEW travels a screen-pixel offset. Scrolling down
  ## looks further down the world.
  camera.panned(
    pixelPanDelta(pixelDx, worldWidth, viewWidthPx, camera.zoom),
    pixelPanDelta(pixelDy, worldHeight, viewHeightPx, camera.zoom),
    worldWidth, worldHeight)

func grabPanned*(camera: Camera; pixelDx, pixelDy: float;
    worldWidth, worldHeight, viewWidthPx, viewHeightPx: float32): Camera =
  ## The camera after the WORLD is dragged a screen-pixel offset. Dragging right
  ## pulls the world right, so the view moves left — the exact inverse of
  ## viewPanned, which is why it delegates rather than restating the arithmetic.
  ##
  ## Holds the grabbed point under the pointer for the whole drag: the centre
  ## moves by precisely the world offset the pointer's travel names, so the two
  ## cancel.
  viewPanned(camera, -pixelDx, -pixelDy,
    worldWidth, worldHeight, viewWidthPx, viewHeightPx)

# ==============================================================================
# SECTION 2: THE DRAG SESSION
# ==============================================================================

type
  PanSession* = object
    ## Whether a drag is under way, and where the pointer was when it was last
    ## seen. Mousemove fires whether or not any button is down, so the session
    ## rather than the event is what decides that a move pans.
    active*: bool
    lastX*: float
    lastY*: float

func initPanSession*(): PanSession =
  ## No drag under way. Also what a finished drag leaves behind: the position it
  ## ended at belongs to a gesture that is over, and the next press brings its
  ## own.
  PanSession(active: false, lastX: 0.0, lastY: 0.0)

func panPressed*(session: PanSession; button: MouseButton;
    x, y: float): PanSession =
  ## The session after a button goes down at a pointer position.
  ##
  ## Only the middle button pans. Left drag is the physics interaction and right
  ## drag its repellent twin, so the middle button is the one with nothing else
  ## to mean; a press of either other button leaves any drag exactly as it was.
  if button == mbMiddle: PanSession(active: true, lastX: x, lastY: y)
  else: session

func panReleased*(session: PanSession; button: MouseButton): PanSession =
  ## The session after a button comes up. Only the button that started the drag
  ## ends it, so a left click during a drag does not strand the pan.
  if button == mbMiddle: initPanSession()
  else: session

func panMoved*(session: PanSession; x, y: float):
    tuple[session: PanSession, dx, dy: float] =
  ## The session advanced to a new pointer position, and how far the pointer
  ## travelled to reach it.
  ##
  ## The delta is measured against the PREVIOUS move rather than against the
  ## press, because each move pans the camera by what it reports: measuring from
  ## the press would re-apply the whole drag on every event and accelerate away.
  ##
  ## A move arriving with no drag under way reports no travel, which is what
  ## keeps an ordinary mouse traverse across the canvas from moving the view.
  if not session.active:
    (session: session, dx: 0.0, dy: 0.0)
  else:
    (session: PanSession(active: true, lastX: x, lastY: y),
     dx: x - session.lastX,
     dy: y - session.lastY)
