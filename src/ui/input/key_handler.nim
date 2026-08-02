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
import binding_table

export CameraKey

# ==============================================================================
# SECTION 1: KEY EVENT DATA (extracted from DOM events)
# ==============================================================================

type
  KeyContext* = object
    ## What a keypress carries beyond which key it was. The listener extracts
    ## both from the DOM event so the decision below stays pure.
    modified*: bool
      ## Ctrl, Cmd or Alt held.
    intoTextEntry*: bool
      ## Focus sits somewhere that takes typed characters.

func cameraKeyFor*(key: string; context: KeyContext): CameraKey =
  ## Map a DOM `KeyboardEvent.key` value to a camera action, from the binding
  ## table — the single declaration. Both "+" and "=" zoom in ("+" is
  ## shift-"=" on most layouts), and "_" pairs with "-" the same way.
  ##
  ## Two contexts claim no binding, and the caller swallows the event only for
  ## what this returns, so both leave the keypress to whoever else wants it.
  ##
  ## A modifier means the browser's chord, never a camera one: no binding in
  ## the table declares Ctrl, Cmd or Alt, so Ctrl/Cmd with `-`, `+` or `0` is
  ## page zoom and page reset. Checked as one rule rather than per binding,
  ## because a per-binding modifier field would have no varying consumer.
  ##
  ## Text entry means the field gets the character: the bindings include `0`,
  ## `-`, `_`, `+`, `=` and the four arrows, which are exactly what typing
  ## `-0.5` into a matrix cell or stepping a focused slider needs.
  if context.modified or context.intoTextEntry:
    return ckNone
  for binding in InputBindings:
    if binding.action != ckNone and key in binding.keys:
      return binding.action
  ckNone

# ==============================================================================
# SECTION 2: TUNING
# ==============================================================================

const
  KEY_ZOOM_STEP* = 1.2'f32
    ## Multiplier per zoom keypress. Coarser than a wheel notch because a key
    ## is a discrete act rather than a continuous gesture — roughly eleven
    ## presses cross config_ranges.CAMERA_ZOOM_MIN to CAMERA_ZOOM_MAX.
  KEY_PAN_FRACTION* = 0.1'f32
    ## Fraction of the VISIBLE span one arrow keypress moves.
    ##
    ## A fraction of what is visible, not a fixed world distance: at the zoom
    ## ceiling a fixed step would throw the view most of the way across the
    ## screen, and at the floor it would crawl. Dividing by zoom makes one press
    ## always move a tenth of the frame.

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
