# ==============================================================================
# PARTICLE GARDEN - CAMERA CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/camera_core.nim: the toroidal camera transform, the
# nearest-image choice that hides the seam, and the shared apparent-scale
# factor. All pure maths — the shaders mirror these functions, so what is
# checked here is the contract they are written against.
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/camera_core
import ../src/physics_core

const CAMERA_CORE_TESTS_LOADED* = true

const
  EPSILON = 1e-5'f32
  WORLD_W = 1920.0'f32
  WORLD_H = 1080.0'f32
  # Stand-ins for the config_ranges bounds, so these tests exercise clamping
  # without pinning the shipped range in two places.
  TEST_ZOOM_MIN = 0.25'f32
  TEST_ZOOM_MAX = 8.0'f32

func closeTo(a, b: float32): bool = abs(a - b) < EPSILON


suite "The Default Camera Reproduces Today's View":
  test "zoom 1.0 centred on the world middle reproduces today's clip mapping exactly":
    # THE COMPATIBILITY CONTRACT. Before a camera existed the renderer computed
    # `(worldPos / worldSize) * 2 - 1`. The camera must reduce to that at its
    # default, or adding one silently reframes the world for every existing
    # preset and screenshot.
    let camera = initCamera(WORLD_W, WORLD_H)
    for worldX in [0.0'f32, 1.0'f32, 480.0'f32, 960.0'f32, 1439.0'f32, 1919.0'f32]:
      for worldY in [0.0'f32, 1.0'f32, 270.0'f32, 540.0'f32, 809.0'f32, 1079.0'f32]:
        let expectedX = (worldX / WORLD_W) * 2.0'f32 - 1.0'f32
        let expectedY = (worldY / WORLD_H) * 2.0'f32 - 1.0'f32
        let actual = toClip(worldX, worldY, camera, WORLD_W, WORLD_H)
        check closeTo(actual.x, expectedX)
        check closeTo(actual.y, expectedY)

  test "the default camera sits at the world middle at zoom one":
    let camera = initCamera(WORLD_W, WORLD_H)
    check closeTo(camera.centerX, WORLD_W * 0.5'f32)
    check closeTo(camera.centerY, WORLD_H * 0.5'f32)
    check closeTo(camera.zoom, 1.0'f32)

  test "the world centre sits at the clip origin":
    let camera = initCamera(WORLD_W, WORLD_H)
    let clip = toClip(WORLD_W * 0.5'f32, WORLD_H * 0.5'f32, camera, WORLD_W, WORLD_H)
    check closeTo(clip.x, 0.0'f32)
    check closeTo(clip.y, 0.0'f32)


suite "The Nearest Toroidal Image Hides The Seam":
  test "the nearest toroidal image of a point across the seam is the short way round":
    # CONTRACT: a particle one unit past the right edge is one unit from a
    # camera sitting one unit inside the left edge — not a world-width away.
    # Drawing it at the long-way offset is exactly what puts a hard cut at the
    # world boundary.
    check closeTo(nearestImageDelta(1.0'f32, WORLD_W - 1.0'f32, WORLD_W), 2.0'f32)
    check closeTo(nearestImageDelta(WORLD_W - 1.0'f32, 1.0'f32, WORLD_W), -2.0'f32)

  test "a point already near the camera keeps its direct offset":
    check closeTo(nearestImageDelta(600.0'f32, 500.0'f32, WORLD_W), 100.0'f32)
    check closeTo(nearestImageDelta(500.0'f32, 600.0'f32, WORLD_W), -100.0'f32)

  test "the nearest image never exceeds half the world":
    # The property that matters: whatever the pair, the chosen image is within
    # half a world span, which is what "nearest" means on a torus.
    for positionStep in 0 .. 40:
      for centerStep in 0 .. 40:
        let position = WORLD_W * positionStep.float32 / 40.0'f32
        let center = WORLD_W * centerStep.float32 / 40.0'f32
        let delta = nearestImageDelta(position, center, WORLD_W)
        check abs(delta) <= WORLD_W * 0.5'f32 + EPSILON

  test "a particle crossing the boundary moves continuously in clip space":
    # CONTRACT: no jump. Stepping a particle across the seam under a fixed
    # camera must produce clip positions that move by the same small step each
    # time, including across the wrap itself.
    let camera = Camera(centerX: 0.0'f32, centerY: 540.0'f32, zoom: 1.0'f32)
    var previous = toClip(WORLD_W - 5.0'f32, 540.0'f32, camera, WORLD_W, WORLD_H).x
    for step in 1 .. 10:
      let position = wrapPosition(WORLD_W - 5.0'f32 + step.float32, WORLD_W)
      let current = toClip(position, 540.0'f32, camera, WORLD_W, WORLD_H).x
      let stepSize = abs(current - previous)
      check stepSize < 0.01'f32
      previous = current


suite "Panning Is Seamless And Exact":
  test "panning by exactly one world width returns an identical view":
    # THE test for the torus. Not "looks the same" — the camera value itself
    # must come back, so a long pan accumulates no drift and the nearest-image
    # precondition (centre inside one world span) always holds.
    let camera = initCamera(WORLD_W, WORLD_H)
    let panned = camera.panned(WORLD_W, 0.0'f32, WORLD_W, WORLD_H)
    check closeTo(panned.centerX, camera.centerX)
    check closeTo(panned.centerY, camera.centerY)
    check closeTo(panned.zoom, camera.zoom)

  test "panning by exactly one world height returns an identical view":
    let camera = initCamera(WORLD_W, WORLD_H)
    let panned = camera.panned(0.0'f32, WORLD_H, WORLD_W, WORLD_H)
    check closeTo(panned.centerX, camera.centerX)
    check closeTo(panned.centerY, camera.centerY)

  test "the camera centre stays inside the world however far it pans":
    # The precondition nearestImageDelta depends on. A centre that escaped
    # [0, size) would make the single-step wrap correction insufficient and
    # reintroduce the seam.
    var camera = initCamera(WORLD_W, WORLD_H)
    for _ in 0 .. 50:
      camera = camera.panned(137.0'f32, -71.0'f32, WORLD_W, WORLD_H)
      check camera.centerX >= 0.0'f32
      check camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32
      check camera.centerY < WORLD_H

  test "panning and panning back returns the starting view":
    let camera = initCamera(WORLD_W, WORLD_H)
    let roundTripped = camera
      .panned(313.0'f32, -207.0'f32, WORLD_W, WORLD_H)
      .panned(-313.0'f32, 207.0'f32, WORLD_W, WORLD_H)
    check closeTo(roundTripped.centerX, camera.centerX)
    check closeTo(roundTripped.centerY, camera.centerY)


suite "Zoom Clamps And Anchors":
  test "zoom clamps to its configured range":
    check closeTo(clampZoom(0.01'f32, TEST_ZOOM_MIN, TEST_ZOOM_MAX), TEST_ZOOM_MIN)
    check closeTo(clampZoom(99.0'f32, TEST_ZOOM_MIN, TEST_ZOOM_MAX), TEST_ZOOM_MAX)
    check closeTo(clampZoom(2.0'f32, TEST_ZOOM_MIN, TEST_ZOOM_MAX), 2.0'f32)
    check closeTo(clampZoom(TEST_ZOOM_MIN, TEST_ZOOM_MIN, TEST_ZOOM_MAX), TEST_ZOOM_MIN)
    check closeTo(clampZoom(TEST_ZOOM_MAX, TEST_ZOOM_MIN, TEST_ZOOM_MAX), TEST_ZOOM_MAX)

  test "the point under the cursor stays under the cursor while zooming":
    # CONTRACT: "the wheel zooms at the cursor" means the thing being pointed
    # at is the thing being approached. Zooming about the view centre instead
    # slides the target away exactly when the user reaches for it.
    #
    # SCOPE OF THE IDENTITY. It holds wherever the anchor names a unique world
    # point, which is where the anchor lies within half a world span of the new
    # centre — algebraically |anchor| <= newZoom. Below zoom 1 the world TILES,
    # so a clip coordinate names infinitely many world points and the renderer
    # draws the nearest image; asking which one "stayed under the cursor" has no
    # single answer there. The guard states that boundary rather than hiding it
    # by only testing zoom levels where it cannot bite.
    let camera = initCamera(WORLD_W, WORLD_H)
    var assertionsMade = 0
    for anchorX in [-0.8'f32, -0.25'f32, 0.0'f32, 0.4'f32, 0.9'f32]:
      for anchorY in [-0.6'f32, 0.0'f32, 0.7'f32]:
        # The world point currently under the anchor.
        let worldX = camera.centerX + anchorX * WORLD_W / (2.0'f32 * camera.zoom)
        let worldY = camera.centerY + anchorY * WORLD_H / (2.0'f32 * camera.zoom)
        for newZoom in [0.5'f32, 1.0'f32, 2.0'f32, 4.0'f32]:
          if abs(anchorX) > newZoom or abs(anchorY) > newZoom:
            continue
          let zoomed = camera.zoomedAt(
            newZoom, anchorX, anchorY, WORLD_W, WORLD_H)
          let clip = toClip(worldX, worldY, zoomed, WORLD_W, WORLD_H)
          check closeTo(clip.x, anchorX)
          check closeTo(clip.y, anchorY)
          inc assertionsMade
    # Guards against the filter above quietly emptying the test.
    check assertionsMade >= 30

  test "zooming out past one tiles the world rather than naming a unique point":
    # The other side of the boundary above, stated as its own fact: at zoom 0.5
    # a clip coordinate beyond |0.5| has wrapped, so the point it names is the
    # nearest image rather than the one the arithmetic started from. This is the
    # infinity effect working, not a defect.
    # Camera near the left edge; a point near the RIGHT edge is closer across
    # the seam than through the middle, so it renders to the camera's left.
    let camera = Camera(
      centerX: 100.0'f32, centerY: WORLD_H * 0.5'f32, zoom: 0.5'f32)
    let acrossTheSeam = toClip(WORLD_W - 100.0'f32, WORLD_H * 0.5'f32,
      camera, WORLD_W, WORLD_H)
    check acrossTheSeam.x < 0.0'f32
    check abs(acrossTheSeam.x) <= 0.5'f32 + EPSILON

    # A point genuinely to the camera's right, for contrast: same camera, and
    # nothing wrapped, so it lands where the direct offset puts it.
    let directlyRight = toClip(300.0'f32, WORLD_H * 0.5'f32,
      camera, WORLD_W, WORLD_H)
    check directlyRight.x > 0.0'f32

  test "zooming at the view centre leaves the centre alone":
    let camera = initCamera(WORLD_W, WORLD_H)
    let zoomed = camera.zoomedAt(3.0'f32, 0.0'f32, 0.0'f32, WORLD_W, WORLD_H)
    check closeTo(zoomed.centerX, camera.centerX)
    check closeTo(zoomed.centerY, camera.centerY)
    check closeTo(zoomed.zoom, 3.0'f32)

  test "zooming keeps the camera centre inside the world":
    var camera = initCamera(WORLD_W, WORLD_H)
    for step in 0 .. 20:
      camera = camera.zoomedAt(
        1.0'f32 + step.float32 * 0.3'f32, 0.9'f32, -0.9'f32, WORLD_W, WORLD_H)
      check camera.centerX >= 0.0'f32
      check camera.centerX < WORLD_W
      check camera.centerY >= 0.0'f32
      check camera.centerY < WORLD_H


suite "Apparent Scale Moves As One":
  test "particle size, trail length, and glow radius scale by the same factor at every zoom":
    # CONTRACT: one function serves all three. Three quantities that disagree at
    # any zoom other than 1.0 is the specific failure that makes zoom read as
    # broken rather than merely different, so the test asserts they are the
    # SAME NUMBER rather than three separately-correct numbers.
    const BASE_SIZE = 6.0'f32
    const TRAIL_LENGTH = 20.0'f32
    const GLOW_RADIUS = 14.0'f32
    for zoomStep in 0 .. 20:
      let zoom = TEST_ZOOM_MIN +
        (TEST_ZOOM_MAX - TEST_ZOOM_MIN) * zoomStep.float32 / 20.0'f32
      let camera = Camera(centerX: 0.0'f32, centerY: 0.0'f32, zoom: zoom)
      let factor = apparentScale(camera)
      check closeTo(BASE_SIZE * factor / BASE_SIZE, factor)
      check closeTo(TRAIL_LENGTH * factor / TRAIL_LENGTH, factor)
      check closeTo(GLOW_RADIUS * factor / GLOW_RADIUS, factor)
      # The ratios between the three are what must not move with zoom.
      check closeTo(
        (TRAIL_LENGTH * factor) / (BASE_SIZE * factor), TRAIL_LENGTH / BASE_SIZE)
      check closeTo(
        (GLOW_RADIUS * factor) / (BASE_SIZE * factor), GLOW_RADIUS / BASE_SIZE)

  test "apparent scale tracks zoom above the floor":
    for zoom in [1.0'f32, 2.0'f32, 4.0'f32, 8.0'f32]:
      check closeTo(
        apparentScale(Camera(centerX: 0, centerY: 0, zoom: zoom)), zoom)

  test "the size floor keeps particles visible at minimum zoom":
    # CONTRACT: unclamped, particles go sub-pixel exactly where the tiled-torus
    # effect lives and the field most needs legible inhabitants.
    let minimal = Camera(centerX: 0, centerY: 0, zoom: TEST_ZOOM_MIN)
    check apparentScale(minimal) == CAMERA_SIZE_FLOOR
    check apparentScale(minimal) > TEST_ZOOM_MIN

  test "apparent scale never falls below the floor at any zoom in range":
    for zoomStep in 0 .. 40:
      let zoom = TEST_ZOOM_MIN +
        (TEST_ZOOM_MAX - TEST_ZOOM_MIN) * zoomStep.float32 / 40.0'f32
      let factor = apparentScale(Camera(centerX: 0, centerY: 0, zoom: zoom))
      check factor >= CAMERA_SIZE_FLOOR

  test "apparent scale rises monotonically with zoom":
    var previous = 0.0'f32
    for zoomStep in 0 .. 40:
      let zoom = TEST_ZOOM_MIN +
        (TEST_ZOOM_MAX - TEST_ZOOM_MIN) * zoomStep.float32 / 40.0'f32
      let factor = apparentScale(Camera(centerX: 0, centerY: 0, zoom: zoom))
      check factor >= previous
      previous = factor


suite "Screen UV And World Are Exact Inverses":
  # WHY THIS SUITE EXISTS: fade.wgsl reprojects the trail by mapping a screen
  # pixel to a world point through the CURRENT camera and back to screen
  # through the PREVIOUS one. If those two transforms are not exact inverses,
  # every frame smears the trail by the error — and a smear is exactly what a
  # broken reprojection and a working one both look like at a glance, so the
  # property has to be checked here rather than by watching the app.

  test "screen UV to world and back is the identity at any camera":
    # The claim the reprojection rests on. When the camera has NOT moved, the
    # two transforms compose to nothing and the fade pass samples the pixel it
    # would have sampled with no camera at all.
    for zoom in [0.25'f32, 0.5'f32, 1.0'f32, 3.0'f32, 8.0'f32]:
      let camera = Camera(centerX: 700.0'f32, centerY: 400.0'f32, zoom: zoom)
      for uvStep in 0 .. 8:
        for vStep in 0 .. 8:
          let uvX = uvStep.float32 / 8.0'f32
          let uvY = vStep.float32 / 8.0'f32
          let world = screenUvToWorld(uvX, uvY, camera, WORLD_W, WORLD_H)
          let back = worldToScreenUv(world.x, world.y, camera, WORLD_W, WORLD_H)
          check abs(back.x - uvX) < 1e-4'f32
          check abs(back.y - uvY) < 1e-4'f32

  test "the default camera maps screen UV straight onto the world":
    # Reduces to uv * worldSize, so the composite passes sample the field at
    # the screen UV they used before a camera existed.
    let camera = initCamera(WORLD_W, WORLD_H)
    for uvStep in 0 .. 8:
      let uv = uvStep.float32 / 8.0'f32
      let world = screenUvToWorld(uv, uv, camera, WORLD_W, WORLD_H)
      check abs(world.x - uv * WORLD_W) < 1e-2'f32
      check abs(world.y - uv * WORLD_H) < 1e-2'f32

  test "a camera that has not moved reprojects every pixel onto itself":
    # The fade pass's actual composition: current camera forward, previous
    # camera back. Equal cameras must give a perfect identity, or a STILL view
    # would smear its own trail.
    let camera = Camera(centerX: 123.0'f32, centerY: 456.0'f32, zoom: 2.5'f32)
    for uvStep in 0 .. 8:
      for vStep in 0 .. 8:
        let uvX = uvStep.float32 / 8.0'f32
        let uvY = vStep.float32 / 8.0'f32
        let world = screenUvToWorld(uvX, uvY, camera, WORLD_W, WORLD_H)
        let reprojected =
          worldToScreenUv(world.x, world.y, camera, WORLD_W, WORLD_H)
        check abs(reprojected.x - uvX) < 1e-4'f32
        check abs(reprojected.y - uvY) < 1e-4'f32

  test "panning shifts the reprojection by a constant across the whole screen":
    # A pure pan is a pure translation in UV. This is what a camera-delta
    # offset would have got right — and the next test is what it would not.
    let before = Camera(centerX: 700.0'f32, centerY: 400.0'f32, zoom: 2.0'f32)
    let after = before.panned(60.0'f32, -25.0'f32, WORLD_W, WORLD_H)
    var firstShiftX, firstShiftY: float32
    var sampled = 0
    for uvStep in 0 .. 8:
      for vStep in 0 .. 8:
        let uvX = uvStep.float32 / 8.0'f32
        let uvY = vStep.float32 / 8.0'f32
        let world = screenUvToWorld(uvX, uvY, after, WORLD_W, WORLD_H)
        let was = worldToScreenUv(world.x, world.y, before, WORLD_W, WORLD_H)
        if sampled == 0:
          firstShiftX = was.x - uvX
          firstShiftY = was.y - uvY
        else:
          check abs((was.x - uvX) - firstShiftX) < 1e-4'f32
          check abs((was.y - uvY) - firstShiftY) < 1e-4'f32
        inc sampled
    check sampled == 81
    check abs(firstShiftX) > 1e-6'f32

  test "zooming does NOT shift the reprojection by a constant":
    # THE REASON THE FADE PASS CARRIES TWO CAMERAS INSTEAD OF ONE UV DELTA.
    # Under zoom the correct mapping is a scale about a point, so the shift
    # genuinely differs across the screen. A single offset would be wrong
    # everywhere except one pixel — and wrong most where the user is looking
    # least, at the edges. This test fails if anyone "simplifies" the
    # reprojection back to a delta.
    let before = Camera(centerX: 700.0'f32, centerY: 400.0'f32, zoom: 1.0'f32)
    let after = Camera(centerX: 700.0'f32, centerY: 400.0'f32, zoom: 2.0'f32)
    let cornerWorld = screenUvToWorld(0.0'f32, 0.0'f32, after, WORLD_W, WORLD_H)
    let cornerWas =
      worldToScreenUv(cornerWorld.x, cornerWorld.y, before, WORLD_W, WORLD_H)
    let farWorld = screenUvToWorld(1.0'f32, 1.0'f32, after, WORLD_W, WORLD_H)
    let farWas =
      worldToScreenUv(farWorld.x, farWorld.y, before, WORLD_W, WORLD_H)
    let cornerShift = cornerWas.x - 0.0'f32
    let farShift = farWas.x - 1.0'f32
    check abs(cornerShift - farShift) > 0.01'f32

  test "the view centre is the one point a zoom leaves alone":
    # And the corollary: the single pixel a UV-delta approximation would have
    # got right is the centre, which is why the error is invisible in the
    # middle of the screen and worst at the edges.
    let before = Camera(centerX: 700.0'f32, centerY: 400.0'f32, zoom: 1.0'f32)
    let after = Camera(centerX: 700.0'f32, centerY: 400.0'f32, zoom: 4.0'f32)
    let world = screenUvToWorld(0.5'f32, 0.5'f32, after, WORLD_W, WORLD_H)
    let was = worldToScreenUv(world.x, world.y, before, WORLD_W, WORLD_H)
    check abs(was.x - 0.5'f32) < 1e-4'f32
    check abs(was.y - 0.5'f32) < 1e-4'f32


suite "Zooming Out Tiles The World To The Window Edges":
  # THE PROPERTY THE USER SEES. Below zoom 1 the view is wider than the world,
  # and the world is a torus, so what belongs off the edge is the world again.
  # Drawing each particle once — at its nearest image — is correct for exactly
  # one world span and leaves black beyond it, which reads as the simulation
  # having stopped at an invisible wall.

  test "at zoom 1 and closer the world is drawn exactly once":
    # The cost of tiling must be zero at every zoom that does not need it,
    # because that is where the app spends nearly all its time.
    for zoom in [1.0'f32, 1.5'f32, 2.0'f32, 8.0'f32]:
      check tileRing(zoom) == 0
      check tileCount(zoom) == 1

  test "the ring always covers the half-span the view actually reaches":
    # The relation, not the table: a view at zoom z spans 1/z worlds, so it
    # reaches 1/(2z) worlds from the centre, and a ring of r copies covers
    # r + 0.5. Anything less leaves a gap at the window edge.
    for zoom in [0.25'f32, 0.3'f32, 0.34'f32, 0.5'f32, 0.7'f32, 0.9'f32,
        0.99'f32, 1.0'f32]:
      let covered = float32(tileRing(zoom)) + 0.5'f32
      let reached = 1.0'f32 / (2.0'f32 * zoom)
      check covered >= reached - 1e-6'f32

  test "the ring is never larger than it needs to be":
    # The other half of the relation. One ring less must NOT cover the view, or
    # the formula is buying instances nobody can see.
    for zoom in [0.25'f32, 0.3'f32, 0.5'f32, 0.9'f32]:
      let ring = tileRing(zoom)
      if ring > 0:
        let oneLess = float32(ring - 1) + 0.5'f32
        let reached = 1.0'f32 / (2.0'f32 * zoom)
        check oneLess < reached

  test "the tile count is the square of the ring's side":
    for zoom in [1.0'f32, 0.5'f32, 0.25'f32]:
      let side = 2 * tileRing(zoom) + 1
      check tileCount(zoom) == side * side

  test "the worst case at minimum zoom stays bounded":
    # The instance multiplier is a per-frame cost on every particle, so the
    # bound at CAMERA_ZOOM_MIN is the number that decides whether zooming out
    # is affordable at all. 25 copies at 0.25 is the price of the infinity read.
    check tileCount(0.25'f32) == 25

  test "every tile index maps to a distinct world offset":
    # A duplicate offset would draw two copies on top of each other and leave a
    # hole somewhere else — the failure mode that looks like tiling working
    # until you notice a missing quadrant.
    var seen: seq[tuple[x, y: int]]
    let ring = tileRing(0.25'f32)
    for tile in 0 ..< tileCount(0.25'f32):
      let offset = tileOffsetSteps(tile, ring)
      check offset notin seen
      seen.add(offset)
    check seen.len == 25

  test "tile 0 is a corner and the centre tile is the undisplaced world":
    # The centre of the ring must be the world at its own position, or zooming
    # out shifts the whole simulation sideways.
    let ring = tileRing(0.25'f32)
    let side = 2 * ring + 1
    let centre = tileOffsetSteps(ring * side + ring, ring)
    check centre == (x: 0, y: 0)
