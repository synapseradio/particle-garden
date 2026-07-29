# ==============================================================================
# PARTICLE GARDEN - CAMERA CORE (Pure Toroidal Camera Math)
# ==============================================================================
#
# Pure functions for the camera over the toroidal world: the world-to-clip
# transform and the nearest-toroidal-image choice that keeps the seam
# invisible.
#
# None of this needs a GPU, which is why it lives here rather than in a shader.
# render.wgsl and glow.wgsl mirror toClip; the pair is hand-maintained with no
# compile-time link, the same contract grayScottStep and rd-step.wgsl already
# have.
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
  ## reduces to the pre-camera mapping `(worldPos / worldSize) * 2 - 1`.
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
# MOVEMENT
# ==============================================================================

func wrappedCenter(pos, size: float32): float32 =
  ## A camera centre folded into [0, size) from however many spans out.
  ##
  ## physics_core.wrapPosition corrects one span, which is everything a particle
  ## advanced by a single bounded step can need, and the hot path keeps that
  ## cheap form for exactly that reason. A camera centre carries no such bound:
  ## deltaX and the zoom anchor arrive from callers, so the fold here must hold
  ## for any displacement rather than for the ones today's gestures produce.
  result = pos - floor(pos / size) * size
  # For inputs many spans out the quotient loses enough precision that the fold
  # can land on `size` itself, or a hair below zero. Both mean zero, and the
  # half-open bound is the whole promise, so it is enforced rather than assumed.
  if result < 0.0'f32 or result >= size:
    result = 0.0'f32

func panned*(camera: Camera, deltaX, deltaY: float32,
    worldWidth, worldHeight: float32): Camera =
  ## The camera moved by a world-space offset, its centre rewrapped.
  ##
  ## Rewrapping is what makes panning by exactly one world width return an
  ## identical view rather than an equivalent-looking one: the camera value
  ## itself comes back to where it started, so nothing accumulates drift over
  ## a long pan and the nearest-image maths keeps its precondition.
  Camera(
    centerX: wrappedCenter(camera.centerX + deltaX, worldWidth),
    centerY: wrappedCenter(camera.centerY + deltaY, worldHeight),
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
    centerX: wrappedCenter(
      camera.centerX + (oldOffsetX - newOffsetX), worldWidth),
    centerY: wrappedCenter(
      camera.centerY + (oldOffsetY - newOffsetY), worldHeight),
    zoom: newZoom)
