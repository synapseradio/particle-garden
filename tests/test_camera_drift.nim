# Behavioral tests for src/camera_drift.nim: the self-moving view. The pan
# flow, the zoom breath and the touch clock are pure, so everything the drift
# promises is measurable here without a browser — the same standing the other
# *_core suites have.
#
# Every measurement below reads the camera the advance RETURNS rather than the
# formula that produced it: travel is measured back out of the centre through
# camera_core's own nearest-image maths, so a step that crosses the seam is
# measured as the short way round rather than as a world-sized jump.

import std/[unittest, math]
import ../src/camera_drift
import ../src/camera_core
import ../src/config_ranges

const CAMERA_DRIFT_TESTS_LOADED* = true

const
  WORLD_W = 1920.0'f32
  WORLD_H = 1080.0'f32
  FRAME_60 = 1.0 / 60.0
  ZOOM_EPSILON = 1e-5
    ## float32 zoom tolerance, the same order test_camera_core measures at.

func cameraAt(zoom: float): Camera =
  ## A camera centred on the world at a given zoom — the framing a user has
  ## left the view in when the drift takes over.
  result = initCamera(WORLD_W, WORLD_H)
  result.zoom = zoom.float32

func viewWidthsBetween(before, after: Camera): float =
  ## How far the centre moved, in view widths and view heights of the camera
  ## it started from. Through nearestImageDelta, so a step across the seam
  ## measures as the short way round.
  let dx = nearestImageDelta(after.centerX, before.centerX, WORLD_W).float
  let dy = nearestImageDelta(after.centerY, before.centerY, WORLD_H).float
  let viewW = WORLD_W.float / before.zoom.float
  let viewH = WORLD_H.float / before.zoom.float
  sqrt((dx / viewW) * (dx / viewW) + (dy / viewH) * (dy / viewH))

func runningDrift(): DriftState =
  ## A drift that has already been quiet long enough to own the camera. A
  ## fresh state is one, which is what makes the toggle move the view on the
  ## frame after it is switched on.
  initDriftState()

func smallestClosureError(slope: float; maxDenominator: int): float =
  ## How near the heading comes to closing inside a denominator bound. After
  ## the centre has wrapped `q` times across the world in x it has moved
  ## `q * slope` view heights in y, and the path closes exactly when that
  ## lands on an integer. The smallest distance to an integer over every `q`
  ## in the bound is therefore how far the orbit stays from repeating.
  ##
  ## Independent of the world's dimensions and of the zoom, because the
  ## velocity is expressed in view widths and heights before it is converted
  ## into world units — which is what makes the slope alone decide closure.
  result = 1.0
  for denominator in 1 .. maxDenominator:
    let offset = slope * denominator.float
    let distance = abs(offset - round(offset))
    if distance < result:
      result = distance


suite "The Named Speed Is The Speed Delivered":
  test "sixty seconds at a named speed travels that speed in view widths":
    # The unit is view widths per minute, so sixty seconds at speed s must
    # deliver s view widths — at any frame rate, which is why the step takes
    # elapsed seconds rather than a frame count.
    for speed in [CAMERA_DRIFT_SPEED_MIN, CAMERA_DRIFT_DEFAULT_SPEED,
        CAMERA_DRIFT_SPEED_MAX]:
      for frameSeconds in [1.0 / 30.0, 1.0 / 144.0]:
        let frames = int(60.0 / frameSeconds)
        var travelled = 0.0
        for _ in 0 ..< frames:
          travelled += driftPanStep(speed, frameSeconds)
        check abs(travelled - speed) < 1e-9

  test "the camera itself moves the distance the speed names":
    # The same claim, measured out of the camera the advance returns instead
    # of out of the step function: a pan whose direction or scaling was wrong
    # would satisfy the sum above and fail here.
    let speed = CAMERA_DRIFT_SPEED_MAX
    var state = runningDrift()
    var camera = cameraAt(1.0)
    var travelled = 0.0
    for _ in 0 ..< 600:
      let previous = camera
      let next = driftAdvance(state, camera, speed, FRAME_60, false,
        WORLD_W, WORLD_H)
      state = next.state
      camera = next.camera
      travelled += viewWidthsBetween(previous, camera)
    check abs(travelled - speed * 600.0 * FRAME_60 / 60.0) < 1e-3

  test "two frame rates agree on the zoom after the same elapsed seconds":
    # The breath advances on distance travelled and the distance is exactly
    # linear in elapsed time, so the zoom sixty seconds in cannot depend on
    # how many frames delivered those seconds.
    let speed = CAMERA_DRIFT_SPEED_MAX
    var zooms: seq[float] = @[]
    for frameSeconds in [1.0 / 30.0, 1.0 / 144.0]:
      var state = runningDrift()
      var camera = cameraAt(2.0)
      for _ in 0 ..< int(60.0 / frameSeconds):
        let next = driftAdvance(state, camera, speed, frameSeconds, false,
          WORLD_W, WORLD_H)
        state = next.state
        camera = next.camera
      zooms.add camera.zoom.float
    check abs(zooms[0] - zooms[1]) < ZOOM_EPSILON


suite "A Stopped Clock Leaves The Camera Exactly Where It Was":
  test "a zero-second advance changes no component of the camera":
    # A throttled or backgrounded tab delivers exactly this. Equality is
    # exact rather than approximate: a drift that nudged the view on a frame
    # that consumed no time would accumulate motion out of nothing.
    for zoom in [CAMERA_ZOOM_MIN, 2.0, 4.0, CAMERA_ZOOM_MAX]:
      let camera = cameraAt(zoom)
      let next = driftAdvance(initDriftState(), camera,
        CAMERA_DRIFT_SPEED_MAX, 0.0, false, WORLD_W, WORLD_H)
      check next.camera.centerX == camera.centerX
      check next.camera.centerY == camera.centerY
      check next.camera.zoom == camera.zoom


suite "The Drift Path Does Not Close":
  test "the shipped heading admits no closure inside the tested bound":
    # The golden ratio conjugate is the worst-approximable irrational, so its
    # closure error over denominators up to N stays near 1/(sqrt(5) * N) —
    # about 4.5e-4 at this bound. The threshold sits well below that and well
    # above zero, so a heading edited to a ratio of small integers goes red.
    const MaxDenominator = 1000
    const ClosureFloor = 1e-4
    let smallest = smallestClosureError(CAMERA_DRIFT_HEADING_SLOPE,
      MaxDenominator)
    checkpoint("smallest closure error over denominators up to " &
      $MaxDenominator & ": " & $smallest)
    check smallest > ClosureFloor

  test "a rational heading closes inside the same bound":
    # THE NON-VACUOUS CHECK. A sweep that reported "no closure" for every
    # slope would pass the test above for the wrong reason, so a slope that
    # must close has to be found closing.
    for rational in [3.0 / 5.0, 1.0 / 2.0, 7.0 / 11.0]:
      check smallestClosureError(rational, 1000) < 1e-12

  test "the centre stays inside one world span across a seam crossing":
    # The precondition nearestImageDelta depends on. The path is driven far
    # enough to cross the seam several times.
    var state = runningDrift()
    var camera = cameraAt(1.0)
    for _ in 0 ..< 20000:
      let next = driftAdvance(state, camera, CAMERA_DRIFT_SPEED_MAX,
        FRAME_60, false, WORLD_W, WORLD_H)
      state = next.state
      camera = next.camera
      check camera.centerX >= 0.0'f32 and camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32 and camera.centerY < WORLD_H


suite "The Zoom Breath Is Anchored On The Live Zoom":
  test "the band contains its anchor and lies inside the zoom range":
    # Swept across the whole range including both ends, because the clamp is
    # what makes the band non-empty at the top and the anchor is what makes
    # it non-empty at the bottom.
    for step in 0 .. 64:
      let anchor = CAMERA_ZOOM_MIN +
        (CAMERA_ZOOM_MAX - CAMERA_ZOOM_MIN) * step.float / 64.0
      let low = driftBandLow(anchor)
      let high = driftBandHigh(low)
      check low <= anchor
      check anchor <= high
      check low >= CAMERA_ZOOM_MIN
      check high <= CAMERA_ZOOM_MAX

  test "the breath at the phase recovered from an anchor returns that anchor":
    # What lets the drift re-enter the breath at the user's zoom with no
    # correction step: the inverse is closed form and total over the band.
    for step in 0 .. 64:
      let anchor = CAMERA_ZOOM_MIN +
        (CAMERA_ZOOM_MAX - CAMERA_ZOOM_MIN) * step.float / 64.0
      let low = driftBandLow(anchor)
      let recovered = driftZoomAt(low, driftBreathPhase(low, anchor))
      check abs(recovered - anchor) < 1e-9

  test "the breath has zero rate at both ends of its band":
    # A raised cosine turns without a velocity discontinuity, which is what
    # keeps the approach from cornering into the retreat.
    const Delta = 1e-6
    for low in [CAMERA_ZOOM_MIN, 2.0, CAMERA_ZOOM_MAX /
        CAMERA_DRIFT_ZOOM_FACTOR]:
      for turningPoint in [0.0, 0.5]:
        let rate = (driftZoomAt(low, turningPoint + Delta) -
          driftZoomAt(low, turningPoint - Delta)) / (2.0 * Delta)
        check abs(rate) < 1e-5


suite "A Single Advance Moves The View By A Bounded Amount":
  test "no advance at the speed ceiling exceeds either declared ceiling":
    # Swept at CAMERA_DRIFT_SPEED_MAX over a full breath, for every band the
    # clamp produces. Both ceilings are constraints the path is HELD TO, not
    # limiters applied to it: raising the speed ceiling past what the flow can
    # carry goes red here rather than making the view jump.
    var worstPan = 0.0
    var worstZoom = 0.0
    for step in 0 .. 32:
      let anchor = CAMERA_ZOOM_MIN +
        (CAMERA_ZOOM_MAX - CAMERA_ZOOM_MIN) * step.float / 32.0
      var state = runningDrift()
      var camera = cameraAt(anchor)
      # One full breath at the ceiling: BREATHS_PER_WIDTH breaths per view
      # width travelled, and the ceiling covers a view width every fifteen
      # seconds, so this many frames carries the breath past a whole cycle.
      let frames = int(60.0 / (CAMERA_DRIFT_SPEED_MAX *
        CAMERA_DRIFT_BREATHS_PER_WIDTH) * 60.0) + 60
      for _ in 0 ..< frames:
        let previous = camera
        let next = driftAdvance(state, camera, CAMERA_DRIFT_SPEED_MAX,
          FRAME_60, false, WORLD_W, WORLD_H)
        state = next.state
        camera = next.camera
        worstPan = max(worstPan, viewWidthsBetween(previous, camera))
        worstZoom = max(worstZoom,
          abs(camera.zoom.float - previous.zoom.float))
    checkpoint("worst pan step " & $worstPan & " view widths against " &
      $CAMERA_DRIFT_MAX_PAN_STEP)
    checkpoint("worst zoom step " & $worstZoom & " against " &
      $CAMERA_DRIFT_MAX_ZOOM_STEP)
    check worstPan <= CAMERA_DRIFT_MAX_PAN_STEP
    check worstZoom <= CAMERA_DRIFT_MAX_ZOOM_STEP


suite "A Camera-Moving Input Yields The Drift":
  test "no advance lands until the quiet interval has elapsed":
    # The stamp arrives, and every frame inside the interval must leave the
    # camera alone — a drift that moved during a gesture would fight it.
    var state = driftAdvance(initDriftState(), cameraAt(2.0),
      CAMERA_DRIFT_SPEED_MAX, FRAME_60, true, WORLD_W, WORLD_H).state
    var camera = cameraAt(2.0)
    var elapsed = 0.0
    while elapsed < CAMERA_DRIFT_RESUME_SECONDS - FRAME_60:
      let next = driftAdvance(state, camera, CAMERA_DRIFT_SPEED_MAX,
        FRAME_60, false, WORLD_W, WORLD_H)
      state = next.state
      elapsed += FRAME_60
      check next.camera == camera
      camera = next.camera

  test "a pause inside a gesture is not interrupted":
    # A hand that stops mid-drag to think has not finished the gesture. The
    # measured pause the resume interval must clear lives beside the constant.
    var state = initDriftState()
    var camera = cameraAt(2.0)
    var elapsed = 0.0
    # The stamp that opens the gesture.
    state = driftAdvance(state, camera, CAMERA_DRIFT_SPEED_MAX, FRAME_60,
      true, WORLD_W, WORLD_H).state
    while elapsed < 4.0:
      let next = driftAdvance(state, camera, CAMERA_DRIFT_SPEED_MAX,
        FRAME_60, false, WORLD_W, WORLD_H)
      state = next.state
      check next.camera == camera
      elapsed += FRAME_60

  test "resuming continues from the camera the user left":
    # No jump, in position or in zoom: the first drifted frame differs from
    # the released framing by no more than one advance's bounded step.
    var state = driftAdvance(initDriftState(), cameraAt(3.0),
      CAMERA_DRIFT_SPEED_MAX, FRAME_60, true, WORLD_W, WORLD_H).state
    let released = cameraAt(3.0)
    var camera = released
    var moved = false
    var elapsed = 0.0
    while not moved and elapsed < CAMERA_DRIFT_RESUME_SECONDS * 2.0:
      let next = driftAdvance(state, camera, CAMERA_DRIFT_SPEED_MAX,
        FRAME_60, false, WORLD_W, WORLD_H)
      state = next.state
      elapsed += FRAME_60
      if next.camera != camera:
        moved = true
        check viewWidthsBetween(camera, next.camera) <=
          CAMERA_DRIFT_MAX_PAN_STEP
        check abs(next.camera.zoom.float - camera.zoom.float) <=
          CAMERA_DRIFT_MAX_ZOOM_STEP
      camera = next.camera
    check moved
    checkpoint("motion resumed after " & $elapsed & " s")
    check elapsed >= CAMERA_DRIFT_RESUME_SECONDS


suite "The Drift Speed Range Carries Its Default And Its Notch":
  test "the default is inside the range and below the ceiling":
    check CAMERA_DRIFT_DEFAULT_SPEED >= CAMERA_DRIFT_SPEED_MIN
    check CAMERA_DRIFT_DEFAULT_SPEED < CAMERA_DRIFT_SPEED_MAX

  test "the floor is above zero, because the toggle is what stops the drift":
    check CAMERA_DRIFT_SPEED_MIN > 0.0

  test "the notch is a position the slider can reach":
    check CAMERA_DRIFT_SPEED_NOTCH_SCREEN >= CAMERA_DRIFT_SPEED_MIN
    check CAMERA_DRIFT_SPEED_NOTCH_SCREEN <= CAMERA_DRIFT_SPEED_MAX
