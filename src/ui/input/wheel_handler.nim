# ==============================================================================
# WHEEL HANDLER - Pure wheel-to-zoom processing
# ==============================================================================
#
# Pure functions turning a wheel event into a new Camera. No DOM references, so
# the zoom-at-cursor behaviour is native-tested rather than only observable by
# scrolling on a running app.
#
# THE ANCHOR IS THE POINT OF THIS FILE. Zooming that ignores the cursor moves
# whatever you were looking at off-screen, so a user zooming toward a colony has
# to chase it with pans. Zooming at the cursor keeps the thing under the pointer
# under the pointer, which is what makes a wheel feel like magnification rather
# than like a slider. camera_core.zoomedAt does that arithmetic; this file's job
# is turning a wheel delta into the zoom to hand it, and clamping the result.
#
# ==============================================================================

import std/math
import ../../camera_core

# ==============================================================================
# SECTION 1: WHEEL EVENT DATA (extracted from DOM events)
# ==============================================================================

type
  WheelEventData* = object
    ## Extracted data from a DOM WheelEvent. Pure data, no DOM references.
    deltaY*: float
      ## Positive scrolls down/away, which zooms OUT — the convention every map
      ## and image viewer uses.
    clipX*: float
      ## Cursor position in clip space, x in [-1, 1].
    clipY*: float
      ## Cursor position in clip space, y in [-1, 1], y-up. The renderer's y
      ## flip is undone before this handler sees it, so the anchor here is in
      ## the same space camera_core.toClip returns.

# ==============================================================================
# SECTION 2: TUNING
# ==============================================================================

const
  WHEEL_ZOOM_RATE* = 0.0015
    ## Zoom factor per unit of wheel delta, applied exponentially so a scroll is
    ## multiplicative rather than additive — the only way for a notch to feel
    ## the same at 0.25x as at 8x. A typical 100-unit notch changes zoom by
    ## about 16%, putting the full 0.25..8 range around twenty notches.

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
