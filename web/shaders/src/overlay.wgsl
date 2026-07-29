// =============================================================================
// OVERLAY SHADER - spatial parameter drags drawn at world scale
// =============================================================================
// Drawn last in both present paths, alpha-blended over the finished frame,
// only while a spatial parameter's slider is dragged: interactionRadius as a
// ring at the cursor, cameraZoom as a frame on the world seams. Coverage math
// mirrors src/overlay_core.nim, which is where it is tested; constants are
// substituted from there through shader_config.
// =============================================================================

//! import overlay_params
//! import camera
//! import render_params
//! import camera_transform

@group(0) @binding(0) var<uniform> overlay: OverlayParams;
@group(0) @binding(1) var<uniform> cam: Camera;
@group(0) @binding(2) var<uniform> params: RenderParams;

const OVERLAY_HALF_THICKNESS_PX: f32 = {{OVERLAY_HALF_THICKNESS_PX}};
const OVERLAY_AA_PX: f32 = {{OVERLAY_AA_PX}};
const OVERLAY_ALPHA: f32 = {{OVERLAY_ALPHA}};

const KIND_RING: f32 = 1.0;
const KIND_FRAME: f32 = 2.0;

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
  output.uv = (POSITIONS[id] + 1.0) * 0.5;
  output.uv.y = 1.0 - output.uv.y;
  return output;
}

// Mirrors overlay_core.edgeCoverage.
fn edgeCoverage(distanceFromLine: f32, halfThickness: f32, aa: f32) -> f32 {
  return 1.0 - smoothstep(halfThickness, halfThickness + aa, distanceFromLine);
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let worldSize = vec2f(cam.worldWidth, cam.worldHeight);
  let world = cameraScreenUvToWorld(input.uv, cam, worldSize);

  // World units per screen pixel, so the line holds its screen thickness at
  // any zoom. The y axis stands in for both; the world tracks the canvas.
  let worldPerPx = worldSize.y / (params.resolution.y * cam.zoom);
  let halfT = OVERLAY_HALF_THICKNESS_PX * worldPerPx;
  let aa = OVERLAY_AA_PX * worldPerPx;

  var coverage = 0.0;
  if (overlay.kind == KIND_RING) {
    // Toroidal distance to the centre, so a ring near the seam stays a ring.
    let delta = vec2f(
      cameraNearestDelta(world.x, overlay.centerX, worldSize.x),
      cameraNearestDelta(world.y, overlay.centerY, worldSize.y));
    coverage = edgeCoverage(abs(length(delta) - overlay.radius), halfT, aa);
  } else if (overlay.kind == KIND_FRAME) {
    // Mirrors overlay_core.seamDistance/frameCoverage: the world's boundary,
    // repeating with the torus.
    let mx = world.x - worldSize.x * floor(world.x / worldSize.x);
    let my = world.y - worldSize.y * floor(world.y / worldSize.y);
    let seamX = min(mx, worldSize.x - mx);
    let seamY = min(my, worldSize.y - my);
    coverage = edgeCoverage(min(seamX, seamY), halfT, aa);
  }

  let alpha = coverage * OVERLAY_ALPHA;
  return vec4f(vec3f(0.75, 0.85, 1.0) * alpha, alpha);
}
