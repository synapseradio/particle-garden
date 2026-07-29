// =============================================================================
// MODULE: camera_transform — the toroidal camera, in the shader
// =============================================================================
// Mirrors src/camera_core.nim, which is where these functions are tested. The
// pair is hand-maintained with no compile-time link, the same contract
// grayScottStep and rd-step.wgsl already have — so a change here needs the
// matching change there, and tests/test_camera_core.nim is what catches it.
//
// Imported by render.wgsl and glow.wgsl, which must agree on where a particle
// lands and how big it looks. Two shaders drawing the same particle through
// different transforms is exactly the bug this module exists to make
// impossible.
//
// WORLD SIZE STAYS A PARAMETER. Camera carries worldWidth/worldHeight, and the
// fullscreen passes pass exactly those (`vec2f(cam.worldWidth,
// cam.worldHeight)`); render.wgsl and glow.wgsl pass the RenderParams.worldSize
// they already hold for their pixel-scale and field-cell maths. Keeping the
// span an argument holds every function here line-for-line against its
// camera_core.nim mirror, which takes it the same way and is where the
// arithmetic is tested.
// =============================================================================

//! import camera

// One axis of the offset from the camera centre to the nearest of a point's
// infinitely many toroidal images. Mirrors camera_core.nearestImageDelta, which
// is physics_core.wrapDelta with halfSize = size/2.
//
// This is what hides the seam: a particle at x=1 with the camera centred near
// x=worldWidth is two units away across the wrap, not worldWidth-2 units the
// long way round. Drawing it at the long-way offset is what produces a hard cut
// at the world edge.
fn cameraNearestDelta(position: f32, center: f32, size: f32) -> f32 {
  let delta = position - center;
  let halfSize = size * 0.5;
  if (delta > halfSize) {
    return delta - size;
  }
  if (delta < -halfSize) {
    return delta + size;
  }
  return delta;
}

// A world position in clip space, through the camera, at its nearest toroidal
// image. Mirrors camera_core.toClip and, like it, returns the UNFLIPPED
// normalized position — the y flip stays at the call site, where it always was.
//
// Reduces to the pre-camera mapping (worldPos / worldSize) * 2 - 1 exactly when
// the camera is centred at the world middle at zoom 1. That identity is pinned
// by a native test, and it is what lets a camera be added without restating
// what the default view looks like.
fn cameraToClip(worldPos: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  let delta = vec2f(
    cameraNearestDelta(worldPos.x, cam.centerX, worldSize.x),
    cameraNearestDelta(worldPos.y, cam.centerY, worldSize.y));
  return delta * 2.0 * cam.zoom / worldSize;
}

// A small world-space offset in clip space, with NO wrapping applied.
//
// Quad corners must go through this rather than through cameraToClip. The image
// choice belongs to the PARTICLE, once: a quad whose particle sits near the
// half-world line would otherwise have some corners wrap and others not, and
// would be torn in half across the screen. Choosing the image from the centre
// and adding the corner offset afterwards makes that impossible.
fn cameraOffsetToClip(offset: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  return offset * 2.0 * cam.zoom / worldSize;
}

// Screen UV -> world position, the inverse of the vertex path. Screen UV has
// (0,0) at the top-left, matching world (0,0), which is why both axes use the
// same `uv * 2 - 1` with no extra flip: the renderer's y flip and the UV y flip
// cancel exactly.
//
// At the default camera (centred, zoom 1) this returns `uv * worldSize`, so the
// composite passes reduce to sampling the field at the screen UV they used
// before a camera existed.
fn cameraScreenUvToWorld(uv: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  return vec2f(cam.centerX, cam.centerY) +
    (uv * 2.0 - 1.0) * worldSize / (2.0 * cam.zoom);
}

// World position -> screen UV. The forward direction; callers ask it where a
// world point SAT on a previous frame's screen.
fn cameraWorldToScreenUv(world: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  return (world - vec2f(cam.centerX, cam.centerY)) * cam.zoom / worldSize + 0.5;
}

// Screen UV -> field UV, for the passes that composite the field behind the
// particles. The field spans the world rect, so this is the world position
// normalized; sampling wraps because both samplers use repeat addressing, which
// is what lets a view straddling the world edge read the world on both sides.
fn cameraScreenUvToFieldUv(uv: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  return cameraScreenUvToWorld(uv, cam, worldSize) / worldSize;
}

// A quad corner is built in pixels, divided into world units, and multiplied by
// zoom again inside cameraToClip, so its on-screen size tracks zoom with no
// correcting factor of its own. Particle size, trail length and glow radius all
// reach clip space through that one path, which is what keeps them in step.
