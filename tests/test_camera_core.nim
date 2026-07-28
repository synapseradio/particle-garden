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

  test "a centre moved by any multiple of the world span rewraps into [0, worldSize)":
    # THE POSTCONDITION THE Camera DOC PROMISES, held against inputs that move
    # a centre further than one span. Everything downstream reads that promise
    # as its precondition: wrapDelta corrects by a single step, which is enough
    # only while the centre sits inside one span, so a mover that handed back a
    # centre two spans out would reintroduce the seam nearest-image exists to
    # hide.
    #
    # No gesture reaches these inputs today — a zoom jump across the whole
    # [1, 8] range displaces the centre by under half a span. The movers are
    # held to the promise regardless of who calls them, because a postcondition
    # that holds only for the callers who happen to exist is not one.
    for spans in [-4.0'f32, -2.5'f32, -1.0'f32, 0.0'f32, 1.0'f32, 3.0'f32,
        7.25'f32]:
      checkpoint("moved by " & $spans & " world spans")
      let pannedFar = initCamera(WORLD_W, WORLD_H).panned(
        spans * WORLD_W, spans * WORLD_H, WORLD_W, WORLD_H)
      check pannedFar.centerX >= 0.0'f32
      check pannedFar.centerX < WORLD_W
      check pannedFar.centerY >= 0.0'f32
      check pannedFar.centerY < WORLD_H

      # zoomedAt is driven from a centre already outside one span, the only way
      # to reach the multi-span case through it: its own displacement is
      # bounded by half a span across the whole zoom range.
      let far = Camera(
        centerX: WORLD_W * (0.5'f32 + spans),
        centerY: WORLD_H * (0.5'f32 + spans),
        zoom: 1.0'f32)
      let zoomedFar = far.zoomedAt(
        4.0'f32, 0.3'f32, -0.3'f32, WORLD_W, WORLD_H)
      check zoomedFar.centerX >= 0.0'f32
      check zoomedFar.centerX < WORLD_W
      check zoomedFar.centerY >= 0.0'f32
      check zoomedFar.centerY < WORLD_H

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

  test "a point past the seam renders at its nearest image, not the long way":
    # The other side of the boundary above, stated as its own fact: the clip
    # position names the nearest image rather than the one the arithmetic
    # started from, and no image sits further than a half span away.
    # Camera near the left edge; a point near the RIGHT edge is closer across
    # the seam than through the middle, so it renders to the camera's left.
    let camera = Camera(
      centerX: 100.0'f32, centerY: WORLD_H * 0.5'f32, zoom: 1.0'f32)
    let acrossTheSeam = toClip(WORLD_W - 100.0'f32, WORLD_H * 0.5'f32,
      camera, WORLD_W, WORLD_H)
    check acrossTheSeam.x < 0.0'f32
    check abs(acrossTheSeam.x) <= 1.0'f32 + EPSILON

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
