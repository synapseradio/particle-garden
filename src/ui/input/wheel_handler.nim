# ==============================================================================
# WHEEL HANDLER - Pure wheel-to-camera processing
# ==============================================================================
#
# Pure functions turning a wheel event into a new Camera. No DOM references, so
# the zoom-at-cursor behaviour is native-tested rather than only observable by
# scrolling on a running app.
#
# ONE EVENT CARRIES TWO GESTURES, and which one it names is the modifier. A
# plain scroll pans, because that is what a trackpad's two-finger swipe means on
# every desktop and what a wheel means in every document. A scroll with ctrl or
# cmd held zooms: a trackpad pinch arrives as a wheel event with ctrlKey set and
# no key touched, so honouring the modifier is what makes pinch-to-zoom work at
# all, and it gives mouse users the same zoom without a second binding. See
# dom_extensions.nim's WheelEvent.ctrlKey doc.
#
# THE ANCHOR IS THE POINT OF THE ZOOM PATH. Zooming that ignores the cursor
# moves whatever you were looking at off-screen, so a user zooming toward a
# colony has to chase it with pans. Zooming at the cursor keeps the thing under
# the pointer under the pointer, which is what makes a wheel feel like
# magnification rather than like a slider. camera_core.zoomedAt does that
# arithmetic; this file's job is turning a wheel delta into the zoom to hand it,
# and clamping the result. The pan path scales its delta in pan_handler.
#
# ==============================================================================

import std/math
import ../../camera_core
import ./pan_handler

# ==============================================================================
# SECTION 1: WHEEL EVENT DATA (extracted from DOM events)
# ==============================================================================

type
  WheelEventData* = object
    ## Extracted data from a DOM WheelEvent. Pure data, no DOM references.
    deltaX*: float
      ## Horizontal scroll amount. Positive scrolls right, which looks further
      ## right into the world.
    deltaY*: float
      ## Vertical scroll amount. Positive scrolls down/away, which looks further
      ## down the world when panning and zooms OUT when the modifier is held —
      ## the convention every map and image viewer uses.
    zoomModifier*: bool
      ## Whether the gesture asks for zoom rather than pan. Set from ctrlKey OR
      ## metaKey, so a trackpad pinch, a ctrl-scroll and a cmd-scroll all reach
      ## the same path.
    clipX*: float
      ## Cursor position in clip space, x in [-1, 1].
    clipY*: float
      ## Cursor position in clip space, y in [-1, 1], y-up. The renderer's y
      ## flip is undone before this handler sees it, so the anchor here is in
      ## the same space camera_core.toClip returns.

  WheelGesture* = enum
    ## What one wheel event asks for. Named rather than left as a bare boolean
    ## so the DOM layer dispatches on a value it cannot get backwards.
    wgPan
    wgZoom

func wheelGesture*(event: WheelEventData): WheelGesture =
  ## Which gesture a wheel event names.
  if event.zoomModifier: wgZoom else: wgPan

# ==============================================================================
# SECTION 2: TUNING
# ==============================================================================

const
  WHEEL_ZOOM_RATE* = 0.0015
    ## Zoom factor per unit of wheel delta, applied exponentially so a scroll is
    ## multiplicative rather than additive — the only way for a notch to feel
    ## the same at the zoom floor as at the ceiling. A typical 100-unit notch
    ## changes zoom by about 16%, so config_ranges.CAMERA_ZOOM_MIN to
    ## CAMERA_ZOOM_MAX takes roughly fourteen notches end to end.
  WHEEL_PAN_RATE* = 1.0
    ## Screen pixels panned per unit of wheel delta. One to one: a browser
    ## reports both a trackpad swipe and a wheel notch in pixels, so the world
    ## already travels the distance the gesture asked for and anything else
    ## would make the picture lead or lag the fingers pushing it.

func wheelZoomFactor*(deltaY: float): float =
  ## The multiplicative zoom change one wheel event produces.
  ##
  ## Exponential in the delta so the factor COMPOSES: two half-sized scrolls
  ## multiply to exactly the factor one full scroll gives. An additive rate
  ## would not, and would make fast scrolling arrive somewhere different from
  ## slow scrolling over the same distance.
  exp(-deltaY * WHEEL_ZOOM_RATE)

func handleWheel*(camera: Camera; event: WheelEventData;
    worldWidth, worldHeight, minZoom, maxZoom: float32): Camera =
  ## The camera after one wheel event: zoomed about the cursor, clamped.
  ##
  ## Clamped BEFORE anchoring, not after. zoomedAt moves the centre by exactly
  ## the amount that holds the anchor point still at the zoom it is given, so
  ## handing it an out-of-range zoom and clamping afterwards would move the
  ## centre for a zoom that never happened — and the anchor would drift at both
  ## ends of the range, precisely where a user pushes hardest.
  let target = camera.zoom * wheelZoomFactor(event.deltaY).float32
  let clamped = clampZoom(target, minZoom, maxZoom)
  camera.zoomedAt(clamped, event.clipX.float32, event.clipY.float32,
    worldWidth, worldHeight)

func handleWheelPan*(camera: Camera; event: WheelEventData;
    worldWidth, worldHeight, viewWidthPx, viewHeightPx: float32): Camera =
  ## The camera after one wheel event pans it: the view moves the way the
  ## scroll points, by the screen distance the scroll asked for.
  ##
  ## Takes no zoom bounds because a pan cannot leave them — the zoom it was
  ## handed is the zoom it returns.
  viewPanned(camera,
    event.deltaX * WHEEL_PAN_RATE, event.deltaY * WHEEL_PAN_RATE,
    worldWidth, worldHeight, viewWidthPx, viewHeightPx)
