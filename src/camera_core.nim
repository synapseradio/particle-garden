# ==============================================================================
# PARTICLE GARDEN - CAMERA CORE (Pure Toroidal Camera Math)
# ==============================================================================
#
# Pure functions for the camera over the toroidal world: the world-to-clip
# transform, the nearest-toroidal-image choice that keeps the seam invisible,
# and the single scale factor that particle size, trail length, and glow radius
# all follow.
#
# None of this needs a GPU, which is why it lives here rather than in a shader.
# render.wgsl and glow.wgsl mirror toClip and apparentScale; the pair is
# hand-maintained with no compile-time link, the same contract grayScottStep and
# rd-step.wgsl already have.
#
# Used by:
#   - tests/test_camera_core.nim (native tests)
#   - src/webgpu_render.nim (writes the CameraLayout uniform)
#   - src/ui/input/ (wheel and key handlers move a Camera)
#
# ==============================================================================

import std/math
import physics_core

# ==============================================================================
# TUNING CONSTANTS
# ==============================================================================

const
  CAMERA_SIZE_FLOOR* = 0.5'f32
    ## Lower bound on the apparent-scale factor that particle size, trail
    ## length, and glow radius share.
    ##
    ## Without it, zooming out to CAMERA_ZOOM_MIN would shrink particles by the
    ## same factor and drop them under a pixel — precisely at the zoom where
    ## the world tiles and the field most needs legible inhabitants. At 0.5 a
    ## particle at minimum zoom is half its 1:1 size rather than a quarter,
    ## which keeps it visible while still reading as "further away".
    ##
    ## BLIND VISUAL PICK: the ratio that looks right is the user's call. What
    ## is not a taste question is that a floor must exist and that all three
    ## quantities share it.
  CAMERA_DEFAULT_ZOOM* = 1.0'f32
    ## The view that reproduces the pre-camera framing exactly: the whole world
    ## once, centred.

# ==============================================================================
# THE CAMERA
# ==============================================================================

type
  Camera* = object
    ## Where the view sits over the world and how close it is.
    ##
    ## centerX/centerY are ALWAYS wrapped into [0, worldSize). Every constructor
    ## and mover here maintains that, and the nearest-image maths below depends
    ## on it: with both the camera centre and a particle position inside one
    ## world span, their difference cannot exceed one full span, which is
    ## exactly the range physics_core.wrapDelta's single-step correction covers.
    centerX*: float32
    centerY*: float32
    zoom*: float32

func clampZoom*(zoom, minZoom, maxZoom: float32): float32 =
  ## Zoom held inside the configured range. The bounds arrive as parameters
  ## rather than as constants here because config_ranges.nim is the single
  ## source of truth for every user-facing range.
  clamp(zoom, minZoom, maxZoom)

func initCamera*(worldWidth, worldHeight: float32): Camera =
  ## The default view: the whole world, centred. At this camera toClip
  ## reproduces the mapping the renderer used before a camera existed.
  Camera(
    centerX: worldWidth * 0.5'f32,
    centerY: worldHeight * 0.5'f32,
    zoom: CAMERA_DEFAULT_ZOOM)

# ==============================================================================
# NEAREST TOROIDAL IMAGE
# ==============================================================================

func nearestImageDelta*(position, center, size: float32): float32 =
  ## The offset from the camera centre to the nearest of a point's infinitely
  ## many toroidal images.
  ##
  ## This is what makes the seam invisible. A particle at x=1 with the camera
  ## centred at x=worldWidth-1 is two units away across the wrap, not
  ## worldWidth-2 units away the long way; drawing it at the long-way offset is
  ## what produces a hard cut at the world edge.
  wrapDelta(position - center, size, size * 0.5'f32)

# ==============================================================================
# WORLD TO CLIP
# ==============================================================================

func toClip*(worldX, worldY: float32, camera: Camera,
    worldWidth, worldHeight: float32): tuple[x, y: float32] =
  ## A world position in clip space, through the camera, at its nearest
  ## toroidal image.
  ##
  ## Reduces to the pre-camera mapping `(worldPos / worldSize) * 2 - 1` exactly
  ## when the camera is centred at the world middle with zoom 1: there
  ## `(worldPos - worldSize/2) * 2 / worldSize` is the same expression
  ## rearranged. That identity is pinned by a test, because it is what lets a
  ## camera be added without restating what the default view looks like.
  ##
  ## The y flip render.wgsl applies (`-normalizedPos.y`) stays in the shader —
  ## this returns the unflipped normalized position, matching what the shader
  ## computes before flipping.
  let deltaX = nearestImageDelta(worldX, camera.centerX, worldWidth)
  let deltaY = nearestImageDelta(worldY, camera.centerY, worldHeight)
  (x: deltaX * 2.0'f32 * camera.zoom / worldWidth,
   y: deltaY * 2.0'f32 * camera.zoom / worldHeight)

# ==============================================================================
# SCREEN UV <-> WORLD
# ==============================================================================
#
# The inverse of the vertex path, and the pair the fade pass reprojects with.
# Screen UV has (0,0) at the top-left matching world (0,0), which is why both
# axes use the same `uv * 2 - 1` and neither needs an extra flip: the renderer's
# y flip and the UV y flip cancel.

func screenUvToWorld*(uvX, uvY: float32, camera: Camera,
    worldWidth, worldHeight: float32): tuple[x, y: float32] =
  ## Where in the world a screen pixel is looking.
  ##
  ## At the default camera this is `uv * worldSize`, so the composite passes
  ## reduce to sampling the field at the screen UV they used before a camera
  ## existed. Mirrors camera_transform.cameraScreenUvToWorld.
  (x: camera.centerX + (uvX * 2.0'f32 - 1.0'f32) * worldWidth /
     (2.0'f32 * camera.zoom),
   y: camera.centerY + (uvY * 2.0'f32 - 1.0'f32) * worldHeight /
     (2.0'f32 * camera.zoom))

func worldToScreenUv*(worldX, worldY: float32, camera: Camera,
    worldWidth, worldHeight: float32): tuple[x, y: float32] =
  ## Where a world point sits on screen. The forward direction, used to ask
  ## where a point SAT on a previous frame's screen.
  ##
  ## Deliberately does NOT take the nearest toroidal image: the fade pass wants
  ## the continuous answer, including values outside [0,1], because the trail
  ## sampler wraps and an image choice here would introduce a discontinuity
  ## exactly at the seam it is meant to cross smoothly.
  ## Mirrors camera_transform.cameraWorldToScreenUv.
  (x: (worldX - camera.centerX) * camera.zoom / worldWidth + 0.5'f32,
   y: (worldY - camera.centerY) * camera.zoom / worldHeight + 0.5'f32)

# ==============================================================================
# APPARENT SCALE
# ==============================================================================

func apparentScale*(camera: Camera): float32 =
  ## The factor particle size, trail length, and glow radius ALL multiply by.
  ##
  ## One function rather than three because three quantities that disagree at
  ## any zoom other than 1.0 is the specific failure that makes zoom read as
  ## broken rather than merely different — a world whose creatures stay the
  ## same size while spreading apart reads as zooming a diagram, not as
  ## approaching something alive.
  ##
  ## Floored so that zooming out past 1:1 — where the world tiles — does not
  ## drive particles under a pixel.
  if camera.zoom < CAMERA_SIZE_FLOOR: CAMERA_SIZE_FLOOR
  else: camera.zoom

# ==============================================================================
# TILING THE WORLD BELOW ZOOM 1
# ==============================================================================
#
# Below zoom 1 the window is wider than the world. The world is a torus, so what
# belongs beyond its edge is the world again — and drawing it there is the whole
# reason zooming out is worth having: the wrap stops being a rule the physics
# obeys and becomes something you can see.
#
# Nearest-image drawing is correct for exactly one world span and leaves black
# beyond it, which reads as the simulation stopping at an invisible wall rather
# than as a world without edges. These functions say how many copies close that
# gap. camera_transform.wgsl mirrors them; the mirror is what the render and
# glow shaders use to place each copy, and it must agree with the instance count
# the CPU asks for.

func tileRing*(zoom: float32): int =
  ## How many world copies out from the centre one the view can reach.
  ##
  ## A view at zoom z spans 1/z worlds, so it reaches 1/(2z) worlds from its
  ## centre, and a ring of r copies covers r + 0.5 — the half accounting for the
  ## centre copy's own far edge. Solving r >= (1/z - 1)/2 gives this, and both
  ## directions of that inequality are pinned by tests: enough to reach the
  ## window edge, and never one ring more than that.
  if zoom >= CAMERA_DEFAULT_ZOOM: 0
  else: int(ceil((1.0'f32 / zoom - 1.0'f32) * 0.5'f32))

func tileCount*(zoom: float32): int =
  ## The instance multiplier the draw calls need: every particle is drawn this
  ## many times. 1 at zoom 1 and closer, so the common case pays nothing.
  let side = 2 * tileRing(zoom) + 1
  side * side

func tileOffsetSteps*(tile, ring: int): tuple[x, y: int] =
  ## A tile index as a whole number of world widths and heights to displace by.
  ##
  ## Row-major over the ring, so the centre tile — the world at its own position
  ## — is the middle index rather than index 0. The displacement is added AFTER
  ## the nearest-image choice, never before: wrapping a position that has already
  ## been pushed a world sideways would just undo the push.
  let side = 2 * ring + 1
  (x: tile mod side - ring, y: tile div side - ring)

# ==============================================================================
# MOVEMENT
# ==============================================================================

func panned*(camera: Camera, deltaX, deltaY: float32,
    worldWidth, worldHeight: float32): Camera =
  ## The camera moved by a world-space offset, its centre rewrapped.
  ##
  ## Rewrapping is what makes panning by exactly one world width return an
  ## identical view rather than an equivalent-looking one: the camera value
  ## itself comes back to where it started, so nothing accumulates drift over
  ## a long pan and the nearest-image maths keeps its precondition.
  Camera(
    centerX: wrapPosition(camera.centerX + deltaX, worldWidth),
    centerY: wrapPosition(camera.centerY + deltaY, worldHeight),
    zoom: camera.zoom)

func zoomedAt*(camera: Camera, newZoom: float32,
    anchorClipX, anchorClipY: float32,
    worldWidth, worldHeight: float32): Camera =
  ## The camera at a new zoom, with the world point currently under a clip-space
  ## anchor left under that anchor.
  ##
  ## This is what "the wheel zooms at the cursor" means: the thing being pointed
  ## at is the thing being approached. Zooming about the view centre instead
  ## makes the target slide away exactly when the user is trying to reach it.
  ##
  ## Derivation: the anchor's clip position is `delta * 2 * zoom / size`, so the
  ## world offset it names is `anchorClip * size / (2 * zoom)`. Holding that
  ## world point fixed across a zoom change means moving the centre by the
  ## difference between the offset the old zoom named and the offset the new
  ## one names.
  let oldOffsetX = anchorClipX * worldWidth / (2.0'f32 * camera.zoom)
  let oldOffsetY = anchorClipY * worldHeight / (2.0'f32 * camera.zoom)
  let newOffsetX = anchorClipX * worldWidth / (2.0'f32 * newZoom)
  let newOffsetY = anchorClipY * worldHeight / (2.0'f32 * newZoom)
  Camera(
    centerX: wrapPosition(
      camera.centerX + (oldOffsetX - newOffsetX), worldWidth),
    centerY: wrapPosition(
      camera.centerY + (oldOffsetY - newOffsetY), worldHeight),
    zoom: newZoom)
