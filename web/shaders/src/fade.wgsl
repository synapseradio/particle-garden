// =============================================================================
// FADE SHADER - samples the previous trail frame and fades it toward background
// =============================================================================
// Drawn first in the offscreen pass, before the current frame's particles, so
// the persistent trail texture decays by fadeAmount each frame instead of
// being cleared outright.
//
// FadeParams comes from the generated fade_params module (FadeParamsLayout in
// src/gpu_types.nim); fadeAmount is 0.0 = instant clear, 1.0 = keep previous.
//
// THE TRAIL DRIFTS ALONG THE FIELD. Binding 3 is the reaction-diffusion field;
// the trail is re-sampled a hair along its gradient, so a trail decaying near
// the pattern bends around it rather than fading straight back. fieldDriftScale
// carries colormap_core's FIELD_DRIFT_SCALE, and the field is world-intrinsic,
// so the drift is live on every frame the trail is on.
// =============================================================================

//! import fade_params
//! import camera_transform
//! import field_grid

@group(0) @binding(0) var prevFrame: texture_2d<f32>;
@group(0) @binding(1) var prevSampler: sampler;
@group(0) @binding(2) var<uniform> params: FadeParams;
@group(0) @binding(3) var fieldTexture: texture_2d<f32>;
@group(0) @binding(4) var<uniform> cam: Camera;

// Fullscreen triangle (3 vertices cover entire screen)
const POSITIONS = array<vec2f, 3>(
  vec2f(-1.0, -1.0),
  vec2f( 3.0, -1.0),
  vec2f(-1.0,  3.0),
);

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
};

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;
  output.position = vec4f(POSITIONS[id], 0.0, 1.0);
  // Convert clip space (-1 to 1) to UV space (0 to 1)
  output.uv = (POSITIONS[id] + 1.0) * 0.5;
  output.uv.y = 1.0 - output.uv.y;  // Flip Y for texture coordinates
  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let worldSize = vec2f(params.worldWidth, params.worldHeight);

  // REPROJECT THE TRAIL. The trail texture is in SCREEN space, so without this
  // the trails stay welded to the screen while the world moves under them —
  // pan and the whole history smears sideways. Ask where the world point now
  // under this pixel sat on the previous frame's screen, and read the trail
  // there.
  //
  // Both cameras are needed, not a single UV offset: an offset is exact only
  // while the zoom is unchanged, and during a zoom the correct mapping is a
  // scale about a point. At a still camera the two transforms are inverses and
  // this returns input.uv exactly, so a stationary view fades as it always did.
  let worldHere = cameraScreenUvToWorld(input.uv, cam, worldSize);
  // Positional, because WGSL has no named-field constructors — the field order
  // here must match the Camera struct that camera.wgsl generates from
  // CameraLayout: centerX, centerY, zoom, pad0.
  let prevCam = Camera(params.prevCenterX, params.prevCenterY,
    params.prevZoom, 0.0);
  let reprojectedUv = cameraWorldToScreenUv(worldHere, prevCam, worldSize);

  // Displace the sample along the field gradient. The whole term is multiplied
  // by fieldDriftScale, so at zero this reduces to the reprojected UV exactly
  // and the guard skips the four texture loads that would build a gradient
  // about to be multiplied by zero. It comes from a uniform, so the branch is
  // coherent across the draw. The shipped scale is nonzero, which makes the
  // guard a contract with the value rather than a path the app takes.
  //
  // The field cell comes from the WORLD position, not from the screen UV: the
  // field lives in the world, so a camera that has panned or zoomed must read
  // the same field cell for the same world point.
  // Floor rather than fieldCellFor's clamp: worldHere is a reprojection, so
  // near a seam it legitimately sits outside the world rect, and the gradient
  // taps wrap it back onto the torus.
  var fieldGradient = vec2f(0.0);
  if (params.fieldDriftScale != 0.0) {
    let fieldUv = worldHere / worldSize;
    let fieldCell = vec2<i32>(floor(fieldUv * vec2<f32>(FIELD_DIMS)));
    fieldGradient = fieldInhibitorGradient(fieldTexture, fieldCell);
  }
  let driftUv = reprojectedUv + fieldGradient * params.fieldDriftScale;

  let prev = textureSample(prevFrame, prevSampler, driftUv);

  // Fade toward transparent (glow shows through from present pass)
  // Higher fadeAmount = MORE of previous frame = LONGER trails
  // RGB fades toward background tint, alpha fades toward 0
  let bgRgb = vec3f(0.04, 0.04, 0.06);
  let fadedRgb = mix(bgRgb, prev.rgb, params.fadeAmount);
  let fadedAlpha = prev.a * params.fadeAmount;
  return vec4f(fadedRgb, fadedAlpha);
}
