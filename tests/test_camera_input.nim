# Behavioral tests for src/ui/input/wheel_handler.nim, pan_handler.nim and
# key_handler.nim: the pure part of navigation. What is tested here is what a
# user would otherwise have to discover by scrolling, dragging and typing at a
# running app and noticing that something felt wrong.
#
# Input-layer decisions only: gesture classification, screen-to-world
# scaling, drag state, key bindings. Camera math itself is
# tests/test_camera_core.nim.

import std/unittest
import ../src/camera_core
import ../src/ui/input/mouse_handler
import ../src/ui/input/wheel_handler
import ../src/ui/input/pan_handler
import ../src/ui/input/key_handler

const CAMERA_INPUT_TESTS_LOADED* = true

const
  WORLD_W = 1920.0'f32
  WORLD_H = 1080.0'f32
  ZOOM_MIN = 0.25'f32
  ZOOM_MAX = 8.0'f32
  VIEW_W_PX = 1600.0'f32
  VIEW_H_PX = 900.0'f32
    ## A canvas in the units the DOM reports: canvas.width is set from
    ## window.innerWidth, so pointer coordinates and this span share a scale.

func testCamera(): Camera = initCamera(WORLD_W, WORLD_H)

func screenPixelsMoved(before, after: Camera): tuple[x, y: float32] =
  ## How far the view travelled on screen, in pixels, between two cameras at
  ## the same zoom. The inverse of the pixel-to-world scaling, so a test can
  ## state its expectation in the units the gesture was made in.
  (x: (after.centerX - before.centerX) * before.zoom * VIEW_W_PX / WORLD_W,
   y: (after.centerY - before.centerY) * before.zoom * VIEW_H_PX / WORLD_H)

func worldUnderPointer(camera: Camera, pixelX, pixelY: float32):
    tuple[x, y: float32] =
  screenUvToWorld(pixelX / VIEW_W_PX, pixelY / VIEW_H_PX, camera,
    WORLD_W, WORLD_H)

suite "The Wheel Zooms At The Cursor":
  test "scrolling up zooms in and scrolling down zooms out":
    # The convention every map and image viewer uses. Getting this backwards is
    # the kind of thing that reads as broken instantly.
    check wheelZoomFactor(-100.0) > 1.0
    check wheelZoomFactor(100.0) < 1.0

  test "a wheel event with no movement changes nothing":
    check wheelZoomFactor(0.0) == 1.0

  test "the zoom factor composes: two half scrolls equal one whole":
    # The reason the rate is exponential: an additive rate would make fast
    # scrolling land somewhere different from slow scrolling over the same
    # total distance, so the view would depend on how quickly you moved.
    let whole = wheelZoomFactor(120.0)
    let halves = wheelZoomFactor(60.0) * wheelZoomFactor(60.0)
    check abs(whole - halves) < 1e-12

  test "the point under the cursor stays under the cursor while wheel-zooming":
    # The property the whole file exists for, asserted through the handler
    # rather than through camera_core, so that the handler's own clamping and
    # factor arithmetic are inside the claim.
    const ANCHOR_X = 0.4
    const ANCHOR_Y = -0.3
    let before = testCamera()
    let event = WheelEventData(deltaY: -100.0, clipX: ANCHOR_X, clipY: ANCHOR_Y)
    let after = handleWheel(before, event, WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX)

    let worldBeforeX = before.centerX + ANCHOR_X.float32 * WORLD_W /
      (2.0'f32 * before.zoom)
    let worldAfterX = after.centerX + ANCHOR_X.float32 * WORLD_W /
      (2.0'f32 * after.zoom)
    check abs(worldBeforeX - worldAfterX) < 0.01'f32

  test "wheel zoom clamps to the configured range at both ends":
    var zoomedOut = testCamera()
    for _ in 0 .. 200:
      zoomedOut = handleWheel(zoomedOut,
        WheelEventData(deltaY: 100.0, clipX: 0.0, clipY: 0.0),
        WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX)
    check zoomedOut.zoom == ZOOM_MIN

    var zoomedIn = testCamera()
    for _ in 0 .. 200:
      zoomedIn = handleWheel(zoomedIn,
        WheelEventData(deltaY: -100.0, clipX: 0.0, clipY: 0.0),
        WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX)
    check zoomedIn.zoom == ZOOM_MAX

  test "the camera centre stays inside the world however far the wheel is spun":
    # The precondition the nearest-image maths depends on. If a zoom ever left
    # the centre outside [0, worldSize), the seam would reappear.
    var camera = testCamera()
    for step in 0 .. 100:
      let delta = if step mod 2 == 0: -140.0 else: 90.0
      camera = handleWheel(camera,
        WheelEventData(deltaY: delta, clipX: 0.8, clipY: 0.6),
        WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX)
      check camera.centerX >= 0.0'f32
      check camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32
      check camera.centerY < WORLD_H


suite "A Wheel Event Names One Gesture":
  test "a wheel event with no modifier held pans":
    # Plain scroll is the pan on every device: a trackpad's two-finger swipe
    # and a mouse wheel arrive as the same event, and neither means zoom.
    check wheelGesture(WheelEventData(deltaY: 100.0)) == wgPan

  test "a wheel event with the control key held zooms":
    # How a trackpad pinch reaches a browser at all: the runtime reports it as
    # a wheel event with ctrlKey set, whether or not a control key was touched.
    check wheelGesture(WheelEventData(deltaY: 100.0, zoomModifier: true)) ==
      wgZoom

  test "the classified zoom still keeps the point under the cursor":
    # The anchor the wheel handler exists for, asserted THROUGH the new fork:
    # routing zoom behind a modifier must not have moved what it anchors on.
    const ANCHOR_X = 0.4
    const ANCHOR_Y = -0.3
    let event = WheelEventData(deltaY: -100.0, zoomModifier: true,
      clipX: ANCHOR_X, clipY: ANCHOR_Y)
    require wheelGesture(event) == wgZoom
    let before = testCamera()
    let after = handleWheel(before, event, WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX)
    let worldBeforeX = before.centerX + ANCHOR_X.float32 * WORLD_W /
      (2.0'f32 * before.zoom)
    let worldAfterX = after.centerX + ANCHOR_X.float32 * WORLD_W /
      (2.0'f32 * after.zoom)
    check abs(worldBeforeX - worldAfterX) < 0.01'f32


suite "Scrolling Pans The View":
  test "a scroll moves the view the way the scroll points":
    # Scrolling down looks further down the world, and scrolling right looks
    # further right — the viewport-moves convention every document has.
    let before = testCamera()
    let down = handleWheelPan(before, WheelEventData(deltaY: 100.0),
      WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
    check down.centerY > before.centerY
    check down.centerX == before.centerX

    let right = handleWheelPan(before, WheelEventData(deltaX: 100.0),
      WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
    check right.centerX > before.centerX
    check right.centerY == before.centerY

  test "one scroll travels the same screen distance at every zoom":
    # The property the pan scaling exists for: a world-fixed step would throw
    # the view across the screen at 8x and barely register at 1x; what a user
    # judges is how far the picture moved under their fingers, so the world
    # offset divides by zoom and the screen distance comes out constant.
    const SCROLLED = 120.0
    for zoom in [1.0'f32, 2.0'f32, 4.0'f32, 8.0'f32]:
      var before = testCamera()
      before.zoom = zoom
      let after = handleWheelPan(before,
        WheelEventData(deltaX: SCROLLED, deltaY: SCROLLED),
        WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
      let moved = screenPixelsMoved(before, after)
      check abs(moved.x - SCROLLED.float32 * WHEEL_PAN_RATE) < 0.01'f32
      check abs(moved.y - SCROLLED.float32 * WHEEL_PAN_RATE) < 0.01'f32

  test "opposite scrolls cancel exactly":
    # Reversible to the value, not merely to the pixel: a user nudging back
    # and forth must not accumulate drift.
    let before = testCamera()
    let away = handleWheelPan(before,
      WheelEventData(deltaX: 40.0, deltaY: 70.0),
      WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
    let back = handleWheelPan(away,
      WheelEventData(deltaX: -40.0, deltaY: -70.0),
      WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
    check abs(back.centerX - before.centerX) < 1e-3'f32
    check abs(back.centerY - before.centerY) < 1e-3'f32

  test "a scroll leaves the zoom alone":
    let before = testCamera()
    let after = handleWheelPan(before, WheelEventData(deltaY: 500.0),
      WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
    check after.zoom == before.zoom

  test "the camera centre stays inside the world however far a scroll runs":
    # The precondition the nearest-image maths depends on, over a scroll long
    # enough to cross the world several times.
    var camera = testCamera()
    for step in 0 .. 200:
      camera = handleWheelPan(camera, WheelEventData(deltaX: 900.0,
        deltaY: -700.0), WORLD_W, WORLD_H, VIEW_W_PX, VIEW_H_PX)
      check camera.centerX >= 0.0'f32
      check camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32
      check camera.centerY < WORLD_H

  test "a view with no pixels leaves the camera alone":
    # A canvas can report zero width between a resize and the next layout.
    # Scaling by it would divide by zero and put NaN in the camera centre,
    # which no later gesture recovers from.
    let before = testCamera()
    check handleWheelPan(before, WheelEventData(deltaX: 30.0, deltaY: 30.0),
      WORLD_W, WORLD_H, 0.0'f32, 0.0'f32) == before


suite "Middle-Button Drag Pans The World Under The Pointer":
  test "no drag is in progress until a button starts one":
    check not initPanSession().active

  test "a middle-button press starts a drag and the other buttons do not":
    # Left drag is the physics interaction and right drag is its repellent
    # twin; the middle button is the one with nothing else to mean.
    check panPressed(initPanSession(), mbMiddle, 10.0, 20.0).active
    check not panPressed(initPanSession(), mbLeft, 10.0, 20.0).active
    check not panPressed(initPanSession(), mbRight, 10.0, 20.0).active

  test "a move with no drag in progress reports no movement":
    # Mousemove fires constantly whether or not a button is down, so the
    # session — not the event — is what decides that the camera moves.
    let moved = panMoved(initPanSession(), 640.0, 480.0)
    check not moved.session.active
    check moved.dx == 0.0
    check moved.dy == 0.0

  test "a move reports the distance since the previous move, not since the press":
    var session = panPressed(initPanSession(), mbMiddle, 100.0, 100.0)
    let first = panMoved(session, 110.0, 130.0)
    check first.dx == 10.0
    check first.dy == 30.0
    let second = panMoved(first.session, 115.0, 135.0)
    check second.dx == 5.0
    check second.dy == 5.0

  test "releasing the middle button ends the drag":
    var session = panPressed(initPanSession(), mbMiddle, 100.0, 100.0)
    session = panReleased(session, mbMiddle)
    check not session.active
    check panMoved(session, 400.0, 400.0).dx == 0.0

  test "releasing another button leaves the drag running":
    let session = panPressed(initPanSession(), mbMiddle, 100.0, 100.0)
    check panReleased(session, mbLeft).active

  test "a drag moves the view against the pointer":
    # The grab convention: dragging right pulls the world right, which means
    # the view moves left. The opposite of the scroll convention above, and
    # the same split every map and image editor ships.
    let before = testCamera()
    let after = grabPanned(before, 50.0, 25.0, WORLD_W, WORLD_H,
      VIEW_W_PX, VIEW_H_PX)
    check after.centerX < before.centerX
    check after.centerY < before.centerY

  test "the world point under the pointer stays under the pointer while dragging":
    # What makes a drag read as grabbing the world rather than as nudging a
    # slider: the thing held onto is the thing that follows the hand.
    const START_X = 400.0'f32
    const START_Y = 300.0'f32
    const DRAG_X = 90.0'f32
    const DRAG_Y = -60.0'f32
    for zoom in [1.0'f32, 3.0'f32, 8.0'f32]:
      var before = testCamera()
      before.zoom = zoom
      let held = worldUnderPointer(before, START_X, START_Y)
      let after = grabPanned(before, DRAG_X, DRAG_Y, WORLD_W, WORLD_H,
        VIEW_W_PX, VIEW_H_PX)
      let stillHeld = worldUnderPointer(after, START_X + DRAG_X,
        START_Y + DRAG_Y)
      check abs(stillHeld.x - held.x) < 0.01'f32
      check abs(stillHeld.y - held.y) < 0.01'f32

  test "the camera centre stays inside the world however far a drag runs":
    var camera = testCamera()
    var session = panPressed(initPanSession(), mbMiddle, 0.0, 0.0)
    for step in 0 .. 200:
      let moved = panMoved(session, float(step) * 37.0, float(step) * -21.0)
      session = moved.session
      camera = grabPanned(camera, moved.dx, moved.dy, WORLD_W, WORLD_H,
        VIEW_W_PX, VIEW_H_PX)
      check camera.centerX >= 0.0'f32
      check camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32
      check camera.centerY < WORLD_H


suite "Keys Map To Camera Actions":
  test "the arrow keys, zoom keys and reset are recognised":
    check cameraKeyFor("ArrowLeft") == ckPanLeft
    check cameraKeyFor("ArrowRight") == ckPanRight
    check cameraKeyFor("ArrowUp") == ckPanUp
    check cameraKeyFor("ArrowDown") == ckPanDown
    check cameraKeyFor("+") == ckZoomIn
    check cameraKeyFor("-") == ckZoomOut
    check cameraKeyFor("0") == ckReset

  test "the unshifted zoom keys mean the same as the shifted ones":
    # On most layouts "+" is shift-"=", and a user pressing the unshifted key
    # means to zoom in.
    check cameraKeyFor("=") == ckZoomIn
    check cameraKeyFor("_") == ckZoomOut

  test "any other key is not a camera action":
    for key in ["a", "Enter", "Shift", "1", "ArrowLeftExtra", ""]:
      check cameraKeyFor(key) == ckNone

  test "a key that is not a camera action leaves the camera untouched":
    let before = testCamera()
    let after = handleCameraKey(before, ckNone, WORLD_W, WORLD_H,
      ZOOM_MIN, ZOOM_MAX)
    check after == before


suite "Keyboard Navigation Moves The View":
  test "opposite arrows cancel exactly":
    # Pan must be reversible to the value, not merely to the pixel: a user who
    # nudges left and right repeatedly should not accumulate drift.
    let before = testCamera()
    let left = handleCameraKey(before, ckPanLeft, WORLD_W, WORLD_H,
      ZOOM_MIN, ZOOM_MAX)
    let back = handleCameraKey(left, ckPanRight, WORLD_W, WORLD_H,
      ZOOM_MIN, ZOOM_MAX)
    check abs(back.centerX - before.centerX) < 1e-3'f32
    check abs(back.centerY - before.centerY) < 1e-3'f32

  test "one arrow press moves a constant fraction of the VIEW at every zoom":
    # Not a constant fraction of the world. At 8x a world-fixed step would
    # throw the view most of the way across the screen; at 0.25x it would
    # barely register. What must stay constant is the fraction of the frame.
    for zoom in [0.25'f32, 1.0'f32, 4.0'f32, 8.0'f32]:
      var camera = testCamera()
      camera.zoom = zoom
      let visibleSpan = WORLD_W / zoom
      check abs(panStep(camera, WORLD_W) - visibleSpan * KEY_PAN_FRACTION) <
        1e-3'f32

  test "zoom keys step multiplicatively and are inverses of each other":
    let before = testCamera()
    let inThenOut = handleCameraKey(
      handleCameraKey(before, ckZoomIn, WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX),
      ckZoomOut, WORLD_W, WORLD_H, ZOOM_MIN, ZOOM_MAX)
    check abs(inThenOut.zoom - before.zoom) < 1e-5'f32

  test "zoom keys clamp to the configured range":
    var camera = testCamera()
    for _ in 0 .. 50:
      camera = handleCameraKey(camera, ckZoomIn, WORLD_W, WORLD_H,
        ZOOM_MIN, ZOOM_MAX)
    check camera.zoom == ZOOM_MAX
    for _ in 0 .. 100:
      camera = handleCameraKey(camera, ckZoomOut, WORLD_W, WORLD_H,
        ZOOM_MIN, ZOOM_MAX)
    check camera.zoom == ZOOM_MIN

  test "zoom keys anchor at the view centre, leaving the centre alone":
    # Unlike the wheel, which anchors at the cursor. A keyboard has no cursor
    # to zoom toward.
    let before = testCamera()
    let after = handleCameraKey(before, ckZoomIn, WORLD_W, WORLD_H,
      ZOOM_MIN, ZOOM_MAX)
    check abs(after.centerX - before.centerX) < 1e-3'f32
    check abs(after.centerY - before.centerY) < 1e-3'f32

  test "reset returns exactly to the default view from anywhere":
    # The binding that cannot get lost: every other key composes, so a user who
    # has navigated somewhere confusing needs one that does not.
    var camera = testCamera()
    for _ in 0 .. 20:
      camera = handleCameraKey(camera, ckZoomIn, WORLD_W, WORLD_H,
        ZOOM_MIN, ZOOM_MAX)
      camera = handleCameraKey(camera, ckPanLeft, WORLD_W, WORLD_H,
        ZOOM_MIN, ZOOM_MAX)
      camera = handleCameraKey(camera, ckPanUp, WORLD_W, WORLD_H,
        ZOOM_MIN, ZOOM_MAX)
    let reset = handleCameraKey(camera, ckReset, WORLD_W, WORLD_H,
      ZOOM_MIN, ZOOM_MAX)
    check reset == initCamera(WORLD_W, WORLD_H)

  test "the camera centre stays inside the world under long key navigation":
    var camera = testCamera()
    for step in 0 .. 200:
      let key = case step mod 4
        of 0: ckPanLeft
        of 1: ckPanDown
        of 2: ckPanRight
        else: ckPanUp
      camera = handleCameraKey(camera, key, WORLD_W, WORLD_H,
        ZOOM_MIN, ZOOM_MAX)
      check camera.centerX >= 0.0'f32
      check camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32
      check camera.centerY < WORLD_H
