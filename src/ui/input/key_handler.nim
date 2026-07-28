# ==============================================================================
# KEY HANDLER - Pure keyboard-to-camera processing
# ==============================================================================
#
# Pure functions turning a keypress into a new Camera. No DOM references, so the
# bindings are native-tested rather than only observable by typing at a running
# app.
#
# Arrows pan, +/- zoom, 0 resets. The reset matters more than it looks: every
# other binding here composes, so a user who has panned and zoomed far enough to
# be lost has no way back except one key that cannot itself get lost.
#
# ==============================================================================

import ../../camera_core

# ==============================================================================
# SECTION 1: KEY EVENT DATA (extracted from DOM events)
# ==============================================================================

type
  CameraKey* = enum
    ## The keys this handler acts on. Anything else leaves the camera alone,
    ## which is why the DOM layer maps unknown keys to ckNone rather than
    ## deciding for itself whether a key is interesting.
    ckNone
    ckPanLeft
    ckPanRight
    ckPanUp
    ckPanDown
    ckZoomIn
    ckZoomOut
    ckReset

func cameraKeyFor*(key: string): CameraKey =
  ## Map a DOM `KeyboardEvent.key` value to a camera action.
  ##
  ## Both "+" and "=" zoom in: on most layouts "+" is shift-"=", and a user
  ## pressing the unshifted key means the same thing. "_" pairs with "-" for the
  ## same reason.
  case key
  of "ArrowLeft": ckPanLeft
  of "ArrowRight": ckPanRight
  of "ArrowUp": ckPanUp
  of "ArrowDown": ckPanDown
  of "+", "=": ckZoomIn
  of "-", "_": ckZoomOut
  of "0": ckReset
  else: ckNone

# ==============================================================================
# SECTION 2: TUNING
# ==============================================================================

const
  KEY_ZOOM_STEP* = 1.2'f32
    ## Multiplier per zoom keypress. Coarser than a wheel notch because a key
    ## is a discrete act rather than a continuous gesture — roughly twelve
    ## presses cross the full zoom range.
  KEY_PAN_FRACTION* = 0.1'f32
    ## Fraction of the VISIBLE span one arrow keypress moves.
    ##
    ## A fraction of what is visible, not a fixed world distance: at 8x zoom a
    ## fixed step would throw the view most of the way across the screen, and
    ## at 0.25x it would barely move. Dividing by zoom makes one press always
    ## move a tenth of the frame.

# ==============================================================================
# SECTION 3: HANDLERS (pure state transitions)
# ==============================================================================

func panStep*(camera: Camera, span: float32): float32 =
  ## How far one arrow keypress moves, in world units, along an axis whose
  ## world extent is `span`. Scales inversely with zoom so the motion is a
  ## constant fraction of the view.
  span * KEY_PAN_FRACTION / camera.zoom

func handleCameraKey*(camera: Camera; key: CameraKey;
    worldWidth, worldHeight, minZoom, maxZoom: float32): Camera =
  ## The camera after one keypress.
  ##
  ## Zoom keys are anchored at the view CENTRE (clip 0,0), unlike the wheel,
  ## which anchors at the cursor. A keyboard has no cursor position to zoom
  ## toward, and centre-anchored zoom is the behaviour that leaves what you are
  ## looking at where it is.
  case key
  of ckNone: camera
  of ckReset: initCamera(worldWidth, worldHeight)
  of ckPanLeft:
    camera.panned(-panStep(camera, worldWidth), 0.0'f32, worldWidth, worldHeight)
  of ckPanRight:
    camera.panned(panStep(camera, worldWidth), 0.0'f32, worldWidth, worldHeight)
  of ckPanUp:
    camera.panned(0.0'f32, -panStep(camera, worldHeight), worldWidth, worldHeight)
  of ckPanDown:
    camera.panned(0.0'f32, panStep(camera, worldHeight), worldWidth, worldHeight)
  of ckZoomIn:
    camera.zoomedAt(clampZoom(camera.zoom * KEY_ZOOM_STEP, minZoom, maxZoom),
      0.0'f32, 0.0'f32, worldWidth, worldHeight)
  of ckZoomOut:
    camera.zoomedAt(clampZoom(camera.zoom / KEY_ZOOM_STEP, minZoom, maxZoom),
      0.0'f32, 0.0'f32, worldWidth, worldHeight)
