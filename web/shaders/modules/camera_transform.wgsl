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

// World position -> screen UV. The forward direction, used to ask where a world
// point SAT on a previous frame's screen.
fn cameraWorldToScreenUv(world: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  return (world - vec2f(cam.centerX, cam.centerY)) * cam.zoom / worldSize + 0.5;
}

// Screen UV -> field UV, for the passes that composite the field behind the
// particles. The field spans the world rect, so this is the world position
// normalized; sampling wraps because both samplers use repeat addressing, which
// is what lets the view sit past the world edge at zoom below 1.
fn cameraScreenUvToFieldUv(uv: vec2f, cam: Camera, worldSize: vec2f) -> vec2f {
  return cameraScreenUvToWorld(uv, cam, worldSize) / worldSize;
}

// TILING BELOW ZOOM 1. Mirrors camera_core.tileRing / tileOffsetSteps, which is
// where the covers-the-view and never-one-ring-more relations are tested.
//
// Below zoom 1 the window is wider than the world, and the world is a torus, so
// what belongs past its edge is the world again. Drawing each particle once
// leaves black out there instead — the simulation appearing to stop at an
// invisible wall. Each particle is drawn once per tile, as an instance.
//
// The CPU asks for tileCount(zoom) instances and this decides where each one
// goes. Both sides compute ceil((1/zoom - 1) / 2) from the same f32 zoom, so
// they agree; a disagreement would show as a missing or doubled world copy.
fn cameraTileRing(cam: Camera) -> u32 {
  return u32(max(0.0, ceil((1.0 / cam.zoom - 1.0) * 0.5)));
}

// A tile index as a world-space displacement. Row-major over the ring, so the
// middle index is the world at its own position.
//
// This is added to the quad's OFFSET, after the nearest-image choice rather
// than before it: wrapping a position already pushed a world sideways would
// simply undo the push.
fn cameraTileOffset(cam: Camera, tile: u32, worldSize: vec2f) -> vec2f {
  let ring = cameraTileRing(cam);
  let side = 2u * ring + 1u;
  let steps = vec2f(
    f32(i32(tile % side) - i32(ring)),
    f32(i32(tile / side) - i32(ring)));
  return steps * worldSize;
}

// The factor particle size, trail length and glow radius ALL multiply by.
// Mirrors camera_core.apparentScale, floor included.
//
// One function rather than three: three quantities that disagree at any zoom
// other than 1.0 is the specific failure that makes zoom read as broken rather
// than merely different. The floor keeps particles above a pixel when zooming
// out past 1:1, where the world tiles.
fn cameraApparentScale(cam: Camera) -> f32 {
  return max(cam.zoom, {{CAMERA_SIZE_FLOOR}});
}

// The correction a quad's world-space offset needs so its ON-SCREEN size ends
// up scaled by cameraApparentScale rather than by raw zoom.
//
// WHY THIS IS NOT JUST cameraApparentScale. A quad corner is built in pixels,
// divided into world units, and then multiplied by zoom again inside
// cameraToClip — so its screen size already tracks zoom with no help. Applying
// the apparent scale on top would square it. What the floor actually needs to
// change is only the ratio between the two, which is 1.0 everywhere above the
// floor and rises below it, holding particles above a pixel exactly where zoom
// alone would sink them.
fn cameraSizeCorrection(cam: Camera) -> f32 {
  return cameraApparentScale(cam) / cam.zoom;
}
