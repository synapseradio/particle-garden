# ==============================================================================
# PARTICLE GARDEN - CAMERA DRIFT (Pure Self-Moving View Math)
# ==============================================================================
#
# The pan flow, the zoom breath and the touch clock behind a camera that moves
# itself. Pure: no FFI, no DOM.
#
# Every export is a func because ui/api/response_probe.nim calls driftPanStep
# under noSideEffect, and --warningAsError:Effect fails the build on a proc.
#
# ==============================================================================

import std/math
import camera_core
import config_ranges

# ==============================================================================
# TUNING CONSTANTS
# ==============================================================================

const
  CAMERA_DRIFT_DEFAULT_SPEED* = 0.25
    ## One view width every four minutes: slow enough to read as weather, the
    ## rate CLIMATE_DEFAULT_SPEED settles on for the same judgment.
  CAMERA_DRIFT_HEADING_SLOPE* = 0.6180339887
    ## View heights travelled per view width. A linear flow on the torus is
    ## periodic exactly when this ratio is rational, and the golden ratio
    ## conjugate is the worst-approximable irrational, so the orbit's shortest
    ## closure is the longest any slope offers.
  CAMERA_DRIFT_ZOOM_FACTOR* = 2.0
    ## What one breath multiplies the apparent scale by. At particle size 3 and
    ## DENSITY_SIZE_FLOOR it carries a density-floored particle between 1.4 and
    ## 2.8 px of on-screen radius.
  CAMERA_DRIFT_BREATHS_PER_WIDTH* = 0.5
    ## One full breath every two view widths travelled: eight minutes at the
    ## default speed, thirty seconds at the ceiling.
  CAMERA_DRIFT_RESUME_SECONDS* = 12.0
    ## Wall-clock quiet a camera-moving input buys before the drift advances
    ## again. Provisional: it clears a thinking pause inside a gesture and
    ## keeps a room left alone from reading as broken.
  CAMERA_DRIFT_MAX_PAN_STEP* = 0.002
    ## The largest fraction of a view width one advance may move, at
    ## CAMERA_DRIFT_SPEED_MAX and a 1/60 s frame; the path reaches 0.00111.
    ## A ceiling the path is held to: tests/test_camera_drift.nim sweeps
    ## against it, so a widened speed ceiling goes red there instead of making
    ## the view jump.
  CAMERA_DRIFT_MAX_ZOOM_STEP* = 0.01
    ## The largest zoom change one advance may make, at the speed ceiling and a
    ## 1/60 s frame, over every band the clamp produces. The widest band is
    ## [4, 8], where the same sweep measures the worst step at 0.00724.

static:
  doAssert CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR >= CAMERA_ZOOM_MIN,
    "the breath's band factor is wider than the camera zoom range carries, " &
    "so the clamp deriving a band would be empty"
  doAssert CAMERA_DRIFT_DEFAULT_SPEED >= CAMERA_DRIFT_SPEED_MIN and
    CAMERA_DRIFT_DEFAULT_SPEED <= CAMERA_DRIFT_SPEED_MAX
  doAssert CAMERA_DRIFT_BREATHS_PER_WIDTH > 0.0,
    "a breath that never completes leaves the zoom climbing to the band's top"

# ==============================================================================
# THE PAN FLOW
# ==============================================================================

func driftPanStep*(speed, deltaSeconds: float): float =
  ## View widths travelled in one advance. `speed` is view widths per minute,
  ## which is what dividing the world velocity by zoom below buys: the apparent
  ## speed holds while the breath changes the zoom.
  speed * deltaSeconds / 60.0

func driftHeading(): tuple[x, y: float] =
  ## The unit heading, in view widths and view heights.
  let norm = sqrt(1.0 +
    CAMERA_DRIFT_HEADING_SLOPE * CAMERA_DRIFT_HEADING_SLOPE)
  (x: 1.0 / norm, y: CAMERA_DRIFT_HEADING_SLOPE / norm)

# ==============================================================================
# THE ZOOM BREATH
# ==============================================================================

func driftBandLow*(zoom: float): float =
  ## The near end of the band a live zoom anchors, clamped so the band above it
  ## stays inside the camera zoom range.
  clamp(zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR)

func driftBandHigh*(bandLow: float): float =
  bandLow * CAMERA_DRIFT_ZOOM_FACTOR

func breathClimb(phase: float): float =
  (1.0 - cos(2.0 * PI * phase)) / 2.0

func driftZoomAt*(bandLow, phase: float): float =
  ## The breath's zoom at a phase, in log space, which is the space zoom lives
  ## in.
  bandLow * pow(CAMERA_DRIFT_ZOOM_FACTOR, breathClimb(phase))

func driftBreathPhase*(bandLow, zoom: float): float =
  ## The phase on the breath's RISING half that produces `zoom` in this band.
  ## Total over the band, so re-entering the breath at any zoom inside it
  ## returns that zoom with no correction step.
  let climb = clamp(ln(zoom / bandLow) / ln(CAMERA_DRIFT_ZOOM_FACTOR), 0.0, 1.0)
  arccos(1.0 - 2.0 * climb) / (2.0 * PI)

func wrappedPhase(phase: float): float =
  result = phase - floor(phase)
  # floor() of a tiny negative rounds to exactly 1.0 in floating point, and
  # the half-open bound is the whole promise.
  if result >= 1.0:
    result = 0.0

# ==============================================================================
# THE ADVANCE
# ==============================================================================

type
  DriftMotion* = enum
    dmWaiting    ## The drift carries no band and writes no camera.
    dmBreathing  ## The drift owns the camera, carrying the band and phase it
                 ## is moving through.

  DriftState* = object
    ## What one frame of drift hands the next. It holds no camera position: the
    ## advance integrates from whatever camera it is given, so a gesture that
    ## moved the view leaves nothing here to reconcile.
    quietSeconds*: float
    case motion*: DriftMotion
    of dmWaiting: discard
    of dmBreathing:
      bandLow*: float
      breathPhase*: float

func initDriftState*(): DriftState =
  ## Already past the quiet interval, so the frame after the toggle is switched
  ## on moves the camera.
  DriftState(quietSeconds: CAMERA_DRIFT_RESUME_SECONDS, motion: dmWaiting)

func driftAdvance*(state: DriftState; camera: Camera;
    speed, deltaSeconds: float; touched: bool;
    worldWidth, worldHeight: float32):
    tuple[state: DriftState; camera: Camera] =
  ## One frame of self-motion: the state to carry, and the camera to write.
  ##
  ## `touched` is whether any user-facing camera write landed since the last
  ## advance. `deltaSeconds` is wall-clock, never the time-scaled step, so a
  ## speed named in minutes means minutes at any simulation rate.
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
  var moved = panned(camera,
    float32(heading.x * travel * worldWidth.float / camera.zoom.float),
    float32(heading.y * travel * worldHeight.float / camera.zoom.float),
    worldWidth, worldHeight)
  moved.zoom = driftZoomAt(bandLow, phase).float32
  (state: DriftState(quietSeconds: quiet, motion: dmBreathing,
                     bandLow: bandLow, breathPhase: phase),
   camera: moved)
