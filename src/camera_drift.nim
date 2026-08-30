# ==============================================================================
# PARTICLE GARDEN - CAMERA DRIFT (Pure Self-Moving View Math)
# ==============================================================================
#
# The view moving itself: a pan along one fixed heading across the torus, a
# zoom breathing through a band anchored on whatever framing it finds, and the
# clock that keeps both out of a gesture's way.
#
# A FLOW, NOT A PATH. Each advance reads the camera it is handed and returns
# that camera displaced. Nothing here holds a position, so whatever the camera
# holds when the drift takes over is where the drift continues from — which is
# what keeps a middle-button drag's grabbed point under the pointer, where a
# writer reasserting an absolute centre next frame would undo the drag.
#
# Pure (no FFI, no DOM), and every export a func: ui/api/response_probe.nim
# calls driftPanStep under noSideEffect.
#
# Used by:
#   - tests/test_camera_drift.nim (native tests)
#   - src/app.nim (the per-frame advance, beside the two weathers)
#   - src/ui/api/response_probe.nim (the drift-speed probe)
#   - src/ui/state/render_state.nim (the default speed)
#
# ==============================================================================

import std/math
import camera_core
import config_ranges

# ==============================================================================
# TUNING CONSTANTS
# ==============================================================================
#
# The speed range lives in config_ranges, the range authority. These are the
# numbers the motion itself is made of, kept beside the maths that reads them
# the way KEY_ZOOM_STEP and KEY_PAN_FRACTION sit in key_handler.

const
  CAMERA_DRIFT_DEFAULT_SPEED* = 0.25
    ## One view width every four minutes. CLIMATE_DEFAULT_SPEED carries the
    ## same number for the same reason: slow enough to read as weather rather
    ## than as something malfunctioning.
  CAMERA_DRIFT_HEADING_SLOPE* = 0.6180339887
    ## View heights travelled per view width. The golden ratio conjugate, the
    ## worst-approximable irrational, so the orbit's shortest closure is the
    ## longest any slope offers. A linear flow on the torus is periodic exactly
    ## when this ratio is rational, and tests/test_camera_drift.nim sweeps the
    ## shipped value for a closure inside a denominator bound.
  CAMERA_DRIFT_ZOOM_FACTOR* = 2.0
    ## What the breath multiplies the apparent scale by: the smallest swing
    ## that reads as approach and retreat rather than as a wobble. At the
    ## shipped particle size 3 and DENSITY_SIZE_FLOOR it lifts a density-floored
    ## particle from 1.4 px of on-screen radius to 2.8, and stays well below the
    ## creature notch, where the view holds too few particles for a wander to
    ## be legible.
  CAMERA_DRIFT_BREATHS_PER_WIDTH* = 0.5
    ## One full breath every two view widths travelled: eight minutes at the
    ## default speed, thirty seconds at the ceiling. One speed slider therefore
    ## governs both motions and the two stay in a relation a user can learn.
  CAMERA_DRIFT_RESUME_SECONDS* = 12.0
    ## Wall-clock quiet a camera-moving input buys before the drift advances
    ## again. Provisional: long enough to clear a thinking pause inside a
    ## gesture, short enough that a room left alone does not read as broken.
  CAMERA_DRIFT_MAX_PAN_STEP* = 0.002
    ## The largest fraction of a view width one advance may move, at
    ## CAMERA_DRIFT_SPEED_MAX and a 1/60 s frame; the path reaches 0.00111
    ## there. A CEILING THE PATH IS HELD TO, not a limiter applied to it, on
    ## CLIMATE_MAX_STEP's terms: raising the speed ceiling past what the flow
    ## can carry goes red in the sweep instead of making the view jump.
  CAMERA_DRIFT_MAX_ZOOM_STEP* = 0.01
    ## The largest zoom change one advance may make, over every band the clamp
    ## produces, at the speed ceiling and a 1/60 s frame. The widest band is
    ## [4, 8], and the sweep in tests/test_camera_drift.nim measures the worst
    ## step there at 0.00724 — d(zoom)/d(phase) peaking near 13 against a
    ## per-frame phase step of 0.000556.

static:
  # The band the factor opens must fit inside the zoom range at every anchor
  # the range admits, or the clamp deriving it would be empty and a drift at
  # creature scale would have no band to breathe through.
  doAssert CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR >= CAMERA_ZOOM_MIN,
    "the breath's band factor is wider than the camera zoom range carries"
  doAssert CAMERA_DRIFT_DEFAULT_SPEED >= CAMERA_DRIFT_SPEED_MIN and
    CAMERA_DRIFT_DEFAULT_SPEED <= CAMERA_DRIFT_SPEED_MAX
  doAssert CAMERA_DRIFT_BREATHS_PER_WIDTH > 0.0,
    "a breath that never completes leaves the zoom climbing to the band's top"

# ==============================================================================
# THE PAN FLOW
# ==============================================================================

func driftPanStep*(speed, deltaSeconds: float): float =
  ## View widths the camera travels in one advance.
  ##
  ## Speed is view widths per minute, and dividing the world velocity by zoom
  ## is what makes that unit hold: pan_handler.pixelPanDelta divides by zoom
  ## because what a user judges is how far the picture moved under their
  ## fingers, never how far the centre moved through the world. A drift whose
  ## zoom breathes needs it, or the apparent speed would halve every time the
  ## view came in.
  speed * deltaSeconds / 60.0

func driftHeading(): tuple[x, y: float] =
  ## The unit heading, in view widths and view heights. Normalised here rather
  ## than at the call site, so the travel above is the distance actually moved.
  let norm = sqrt(1.0 +
    CAMERA_DRIFT_HEADING_SLOPE * CAMERA_DRIFT_HEADING_SLOPE)
  (x: 1.0 / norm, y: CAMERA_DRIFT_HEADING_SLOPE / norm)

# ==============================================================================
# THE ZOOM BREATH
# ==============================================================================

func driftBandLow*(zoom: float): float =
  ## The near end of the band a live zoom anchors. Clamped so the band the
  ## factor opens above it stays inside the camera zoom range; the clamp is
  ## non-empty by the static assertion above, so the anchor always lies inside
  ## the band this returns.
  clamp(zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR)

func driftBandHigh*(bandLow: float): float =
  ## The far end of that band.
  bandLow * CAMERA_DRIFT_ZOOM_FACTOR

func breathClimb(phase: float): float =
  ## How far up the band the breath has climbed, in [0, 1]. A raised cosine,
  ## whose derivative is zero at both turning points — the same property
  ## smoothstep buys the tour, and for the same reason: linear interpolation
  ## would visibly corner where the approach hands over to the retreat.
  (1.0 - cos(2.0 * PI * phase)) / 2.0

func driftZoomAt*(bandLow, phase: float): float =
  ## The breath's zoom at a phase, in log space — the space zoom lives in.
  bandLow * pow(CAMERA_DRIFT_ZOOM_FACTOR, breathClimb(phase))

func driftBreathPhase*(bandLow, zoom: float): float =
  ## The phase on the breath's rising half that produces `zoom` in this band.
  ##
  ## Closed form and total over the band, which is what lets the drift re-enter
  ## the breath at the zoom the user left and return exactly that zoom, with no
  ## correction step and no snap.
  let climb = clamp(ln(zoom / bandLow) / ln(CAMERA_DRIFT_ZOOM_FACTOR), 0.0, 1.0)
  arccos(1.0 - 2.0 * climb) / (2.0 * PI)

func wrappedPhase(phase: float): float =
  ## Phase folded into [0, 1). The breath is closed, so any real names a point
  ## on it and a session left running for hours never accumulates into the
  ## range where float precision would coarsen the step.
  result = phase - floor(phase)
  if result >= 1.0:
    result = 0.0

# ==============================================================================
# THE ADVANCE
# ==============================================================================

type
  DriftMotion* = enum
    dmWaiting    ## A camera-moving input is still fresh, or nothing has
                 ## drifted yet. The drift carries no band and writes nothing.
    dmBreathing  ## The drift owns the camera and carries the band and phase
                 ## it is moving through.

  DriftState* = object
    ## What one frame of drift hands the next. No camera position: a flow
    ## integrates from whatever it finds, so there is nothing here to
    ## reconcile against the camera a gesture left behind.
    quietSeconds*: float  ## Wall-clock seconds since the last camera touch,
                          ## held at the resume interval once it is reached.
    case motion*: DriftMotion
    of dmWaiting: discard
    of dmBreathing:
      bandLow*: float      ## Near end of the band the user's framing anchored.
      breathPhase*: float  ## Position on that breath, an angle in [0, 1).

func initDriftState*(): DriftState =
  ## A drift already past its quiet interval, so switching the toggle on moves
  ## the camera on the next frame rather than after a silent wait.
  DriftState(quietSeconds: CAMERA_DRIFT_RESUME_SECONDS, motion: dmWaiting)

func driftAdvance*(state: DriftState; camera: Camera;
    speed, deltaSeconds: float; touched: bool;
    worldWidth, worldHeight: float32):
    tuple[state: DriftState; camera: Camera] =
  ## One frame of self-motion: the state to carry, and the camera to write.
  ##
  ## `touched` is whether any user-facing camera write landed since the last
  ## advance. It drops the drift back to waiting and discards the band, so a
  ## resume seeds afresh from the camera the user left.
  ##
  ## `deltaSeconds` is WALL-CLOCK, never the time-scaled step: a speed named in
  ## minutes means minutes however fast the simulation is running.
  let quiet =
    if touched: 0.0
    else: min(state.quietSeconds + deltaSeconds, CAMERA_DRIFT_RESUME_SECONDS)
  if quiet < CAMERA_DRIFT_RESUME_SECONDS:
    return (state: DriftState(quietSeconds: quiet, motion: dmWaiting),
            camera: camera)

  var bandLow: float
  var carriedPhase: float
  case state.motion
  of dmBreathing:
    bandLow = state.bandLow
    carriedPhase = state.breathPhase
  of dmWaiting:
    bandLow = driftBandLow(camera.zoom.float)
    carriedPhase = driftBreathPhase(bandLow, camera.zoom.float)

  let travel = driftPanStep(speed, deltaSeconds)
  let heading = driftHeading()
  let phase = wrappedPhase(
    carriedPhase + travel * CAMERA_DRIFT_BREATHS_PER_WIDTH)
  # Through camera_core.panned, which rewraps the centre — the precondition the
  # nearest-image maths depends on, and what makes the seam crossing invisible.
  var moved = panned(camera,
    float32(heading.x * travel * worldWidth.float / camera.zoom.float),
    float32(heading.y * travel * worldHeight.float / camera.zoom.float),
    worldWidth, worldHeight)
  moved.zoom = driftZoomAt(bandLow, phase).float32
  (state: DriftState(quietSeconds: quiet, motion: dmBreathing,
                     bandLow: bandLow, breathPhase: phase),
   camera: moved)
