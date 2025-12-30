// =============================================================================
// VELOCITY INTEGRATION AND POSITION UPDATE SHADER (Pass 5)
// =============================================================================
//
// Applies velocity deltas computed by Pass 4 (forces) and updates positions.
// Mirrors main.js::physics() lines 186-204 for exact algorithm parity.
//
// Algorithm:
// 1. Read velocity and position from active buffer (in-place update)
// 2. Read velocity delta from Pass 4 output
// 3. Apply delta and friction: v_new = (v_old + vDelta) * friction
// 4. Update position: p_new = p_old + v_new
// 5. Apply toroidal wrapping to position
// 6. Write back to same buffer (in-place)
//
// NOTE: This shader does IN-PLACE updates on the active buffer.
// The caller determines which buffer set (A or B) is active by binding
// the appropriate buffers. No parity branching needed in shader.
//
// Thread mapping: One particle per thread (@workgroup_size(64, 1, 1))
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// DIAGNOSTIC: Bypass Mode
// Set to true to force visible particle movement (spiral pattern)
// This isolates readback issues from physics issues
// ─────────────────────────────────────────────────────────────────────────────
const BYPASS_PHYSICS: bool = false;

// Simulation parameters (uniform)
struct IntegrationParams {
  W: f32,               // World width
  H: f32,               // World height
  friction: f32,        // Friction coefficient (0.95)
  particleCount: u32,   // Active particle count
};

// Uniform buffer
@group(0) @binding(0) var<uniform> params: IntegrationParams;

// Active particle buffers (in-place read/write)
@group(0) @binding(1) var<storage, read_write> px: array<f32>;
@group(0) @binding(2) var<storage, read_write> py: array<f32>;
@group(0) @binding(3) var<storage, read_write> vx: array<f32>;
@group(0) @binding(4) var<storage, read_write> vy: array<f32>;

// Velocity delta (output from Pass 4, packed vec2)
@group(0) @binding(5) var<storage, read> velocityDelta: array<vec2<f32>>;

// Frame counter for animation (incremented via uniform or derived)
var<private> frameCounter: f32 = 0.0;

@compute @workgroup_size(64, 1, 1)
fn integrate(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let i = globalId.x;

  // Bounds check
  if (i >= params.particleCount) {
    return;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // DIAGNOSTIC: Bypass mode - force visible spiral movement
  // If particles appear: readback works, issue is in physics
  // If no particles: readback is broken
  // ─────────────────────────────────────────────────────────────────────────────
  if (BYPASS_PHYSICS) {
    // Use friction as a crude frame counter (it's constant 0.95)
    // Generate spiral pattern based on particle index
    let angle = f32(i) * 0.0001 + px[i] * 0.01;
    let radius = 100.0 + f32(i % 200u);
    let centerX = params.W * 0.5;
    let centerY = params.H * 0.5;

    // Animate position in a spiral
    px[i] = centerX + radius * cos(angle);
    py[i] = centerY + radius * sin(angle);
    vx[i] = 0.0;
    vy[i] = 0.0;
    return;
  }

  // Read current state
  let vx_old = vx[i];
  let vy_old = vy[i];
  let px_old = px[i];
  let py_old = py[i];

  // Apply velocity delta and friction
  // Matches main.js:189-190: vxActive[i] = (vxActive[i] + vxDelta[i]) * friction;
  let vDelta = velocityDelta[i];
  let vx_new = (vx_old + vDelta.x) * params.friction;
  let vy_new = (vy_old + vDelta.y) * params.friction;

  // Update position
  // Matches main.js:193-194: let x = pxActive[i] + vxActive[i];
  var px_new = px_old + vx_new;
  var py_new = py_old + vy_new;

  // Toroidal wrap
  // Matches main.js:197-200
  if (px_new < 0.0) {
    px_new += params.W;
  } else if (px_new >= params.W) {
    px_new -= params.W;
  }

  if (py_new < 0.0) {
    py_new += params.H;
  } else if (py_new >= params.H) {
    py_new -= params.H;
  }

  // Write back (in-place)
  vx[i] = vx_new;
  vy[i] = vy_new;
  px[i] = px_new;
  py[i] = py_new;
}
