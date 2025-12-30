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

// Simulation parameters (uniform) - 32 bytes total
struct IntegrationParams {
  W: f32,               // World width (offset 0)
  H: f32,               // World height (offset 4)
  friction: f32,        // Friction coefficient (offset 8)
  maxVelocity: f32,     // Maximum velocity (offset 12)
  particleCount: u32,   // Active particle count (offset 16)
  pad0: u32,            // Padding (offset 20)
  pad1: u32,            // Padding (offset 24)
  pad2: u32,            // Padding (offset 28)
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

@compute @workgroup_size(64, 1, 1)
fn integrate(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let i = globalId.x;

  // Bounds check
  if (i >= params.particleCount) {
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
  var vx_new = (vx_old + vDelta.x) * params.friction;
  var vy_new = (vy_old + vDelta.y) * params.friction;

  // Logarithmic velocity capping to reduce jank in high-activity areas
  // Soft cap: velocities above threshold are compressed logarithmically
  let speed = sqrt(vx_new * vx_new + vy_new * vy_new);
  let threshold = params.maxVelocity * 0.5;  // Start compressing at half max
  if (speed > threshold && speed > 0.0) {
    let excess = speed - threshold;
    // log(1 + x) gives smooth compression; scale so speed at 2*threshold = threshold + log(1 + threshold)
    let compressed = threshold + log(1.0 + excess);
    // Cap at maxVelocity as hard limit
    let finalSpeed = min(compressed, params.maxVelocity);
    let scale = finalSpeed / speed;
    vx_new *= scale;
    vy_new *= scale;
  }

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
