# ==============================================================================
# PARTICLE GARDEN - CAMERA INPUT TESTS
# ==============================================================================
#
# Behavioral tests for src/ui/input/wheel_handler.nim and key_handler.nim: the
# pure part of navigation. What is tested here is what a user would otherwise
# have to discover by scrolling and typing at a running app and noticing that
# something felt wrong.
#
# The camera maths itself lives in tests/test_camera_core.nim. These tests cover
# only the input layer's own decisions: how a wheel delta becomes a zoom, which
# key means what, and what each binding anchors on.
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/camera_core
import ../src/ui/input/wheel_handler
import ../src/ui/input/key_handler

const CAMERA_INPUT_TESTS_LOADED* = true

const
  WORLD_W = 1920.0'f32
  WORLD_H = 1080.0'f32
  ZOOM_MIN = 0.25'f32
  ZOOM_MAX = 8.0'f32

func testCamera(): Camera = initCamera(WORLD_W, WORLD_H)

suite "The Wheel Zooms At The Cursor":
  test "scrolling up zooms in and scrolling down zooms out":
    # The convention every map and image viewer uses. Getting this backwards is
    # the kind of thing that reads as broken instantly.
    check wheelZoomFactor(-100.0) > 1.0
    check wheelZoomFactor(100.0) < 1.0

  test "a wheel event with no movement changes nothing":
    check wheelZoomFactor(0.0) == 1.0

  test "the zoom factor composes: two half scrolls equal one whole":
    # THE REASON THE RATE IS EXPONENTIAL. An additive rate would make fast
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

    # The world point the anchor named before the zoom, and after it.
    let worldBeforeX = before.centerX + ANCHOR_X.float32 * WORLD_W /
      (2.0'f32 * before.zoom)
    let worldAfterX = after.centerX + ANCHOR_X.float32 * WORLD_W /
      (2.0'f32 * after.zoom)
    check abs(worldBeforeX - worldAfterX) < 0.01'f32

  test "wheel zoom clamps to the configured range at both ends":
    # A very large scroll in each direction must land exactly on the bound,
    # not past it and not short of it.
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
    # THE BINDING THAT CANNOT GET LOST. Every other key composes, so a user who
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
