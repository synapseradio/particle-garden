/**
 * Application entry point for Goober Garden particle simulation.
 *
 * This module orchestrates all other modules:
 * - Initializes shared buffers, WebGL context, workers, and UI
 * - Manages the main animation loop
 * - Coordinates physics and rendering each frame
 *
 * The simulation flow each frame:
 * 1. buildGrid() - sort particles by spatial cell for cache-friendly access
 * 2. dispatchPhysicsShared() - wake workers to compute velocity deltas
 * 3. Apply velocity deltas and update positions
 * 4. render() - upload particle data to GPU and draw
 * 5. Update stats display
 */

import { CONFIG } from './config.js';
import {
  allocateBuffers,
  pxA,
  pyA,
  vxA,
  vyA,
  speciesA,
  pxB,
  pyB,
  vxB,
  vyB,
  speciesB,
  vxDelta,
  vyDelta,
  activeParity,
} from './buffers.js';
import { initGL, resize, render, canvas } from './renderer.js';
import {
  createWorkers,
  dispatchPhysicsShared,
  updateWorkersMatrix,
  workerCount,
} from './workers.js';
import { buildGrid, gridW, gridH, cellSize, gridTimeMs } from './grid.js';
import {
  init as initUI,
  setupUI,
  setupEvents,
  randomizeMatrix,
  updateStats,
  updateParticleStats,
  setMatrixUpdateCallback,
  mouseX,
  mouseY,
  mouseDown,
} from './ui.js';

// ═══════════════════════════════════════════════════════════════════════════════
// MODULE STATE
// ═══════════════════════════════════════════════════════════════════════════════

let particleCount = 0;
let isRunning = false;

// Timing and stats
let lastTime = 0;
let frameCount = 0;
let fps = 0;
let lastFpsTime = 0;
let workerTimeMs = 0;

// ═══════════════════════════════════════════════════════════════════════════════
// PARTICLE INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Initialize particles with random positions and velocities.
 * Particles are distributed evenly among species, then shuffled.
 */
export function initParticles() {
  particleCount = CONFIG.particleCount;
  const W = canvas.width;
  const H = canvas.height;
  const ns = CONFIG.speciesCount;

  // Initialize buffer A as starting point
  for (let i = 0; i < particleCount; i++) {
    pxA[i] = Math.random() * W;
    pyA[i] = Math.random() * H;
    vxA[i] = (Math.random() - 0.5) * 2;
    vyA[i] = (Math.random() - 0.5) * 2;
    speciesA[i] = i % ns;
  }

  // Shuffle species for even distribution
  for (let i = particleCount - 1; i > 0; i--) {
    const j = (Math.random() * (i + 1)) | 0;
    const t = speciesA[i];
    speciesA[i] = speciesA[j];
    speciesA[j] = t;
  }

  updateParticleStats(particleCount);
}

/**
 * Reset particles to initial random state.
 * Alias for initParticles() - exposed for UI callback.
 */
export function resetParticles() {
  initParticles();
}

// ═══════════════════════════════════════════════════════════════════════════════
// PHYSICS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Run one physics step.
 *
 * This function:
 * 1. Builds the spatial grid and sorts particles
 * 2. Dispatches physics work to workers
 * 3. Applies velocity deltas from workers
 * 4. Updates particle positions with velocity
 *
 * @param {number} dt - Delta time in seconds (already scaled by timeScale)
 */
async function physics(dt) {
  // Build spatial grid - this sorts particles and flips buffer parity
  const gridResult = buildGrid(particleCount, canvas.width, canvas.height);

  // Dispatch physics to workers
  const t0 = performance.now();
  await dispatchPhysicsShared(
    dt,
    particleCount,
    canvas.width,
    canvas.height,
    gridResult.gridW,
    gridResult.gridH,
    gridResult.cellSize,
    mouseX,
    mouseY,
    mouseDown
  );
  workerTimeMs = performance.now() - t0;

  // Apply velocity deltas
  // Note: activeParity now points to the sorted buffer that workers read from
  const vxActive = activeParity === 0 ? vxA : vxB;
  const vyActive = activeParity === 0 ? vyA : vyB;

  // Friction scaled by time step to prevent momentum loss during slow motion
  const dtFactor = dt * 60;
  const fric = Math.pow(1 - CONFIG.friction, dtFactor);

  for (let i = 0; i < particleCount; i++) {
    vxActive[i] = vxActive[i] * fric + vxDelta[i];
    vyActive[i] = vyActive[i] * fric + vyDelta[i];
  }

  // Update positions
  const W = canvas.width;
  const H = canvas.height;
  const dtScaled = dt * 60;

  const pxActive = activeParity === 0 ? pxA : pxB;
  const pyActive = activeParity === 0 ? pyA : pyB;

  const MAX_SPEED = 20.0;
  const MAX_SPEED_SQ = MAX_SPEED * MAX_SPEED;

  for (let i = 0; i < particleCount; i++) {
    let vx = vxActive[i];
    let vy = vyActive[i];

    // Clamp velocity to prevent teleporting
    const v2 = vx * vx + vy * vy;
    if (v2 > MAX_SPEED_SQ) {
      const v = Math.sqrt(v2);
      const scale = MAX_SPEED / v;
      vx *= scale;
      vy *= scale;
      vxActive[i] = vx;
      vyActive[i] = vy;
    }

    let x = pxActive[i] + vx * dtScaled;
    let y = pyActive[i] + vy * dtScaled;

    // Toroidal wrapping
    if (x < 0) x += W;
    else if (x >= W) x -= W;
    if (y < 0) y += H;
    else if (y >= H) y -= H;

    pxActive[i] = x;
    pyActive[i] = y;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN LOOP
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Main animation loop.
 * Computes delta time, runs physics, renders, and updates stats.
 *
 * @param {number} now - Current timestamp from requestAnimationFrame
 */
async function loop(now) {
  if (!isRunning) return;

  // Compute delta time, capped to prevent spiral of death
  const dt = Math.min((now - lastTime) / 1000, 0.05) * CONFIG.timeScale;
  lastTime = now;

  await physics(dt);
  render(particleCount);

  // Update FPS and stats every 500ms
  frameCount++;
  if (now - lastFpsTime > 500) {
    fps = ((frameCount * 1000) / (now - lastFpsTime)) | 0;
    frameCount = 0;
    lastFpsTime = now;
    updateStats(fps, gridTimeMs, workerTimeMs);
  }

  requestAnimationFrame(loop);
}

// ═══════════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Initialize the application.
 *
 * Sequence:
 * 1. Allocate SharedArrayBuffers
 * 2. Initialize WebGL context
 * 3. Set up UI bindings and event handlers
 * 4. Create worker pool
 * 5. Randomize attraction matrix
 * 6. Initialize particles
 * 7. Start animation loop
 */
async function init() {
  console.log(`
=========================================

   Hi there!

   •🧬•

   I hope this message finds you well.

=========================================
`);

  // Allocate shared memory buffers
  allocateBuffers();

  // Initialize WebGL
  if (!initGL()) return;

  // Initialize UI with callbacks
  initUI({
    initParticles,
    resize,
  });

  // Set up UI bindings
  setupUI();

  // Set up event handlers (pass canvas from renderer)
  setupEvents(canvas);

  // Set matrix update callback to sync with workers
  setMatrixUpdateCallback(updateWorkersMatrix);

  // Create worker pool
  createWorkers();

  // Initialize attraction matrix with random values
  randomizeMatrix();

  // Initialize particles
  initParticles();

  // Expose resetParticles globally for HTML onclick handler
  window.resetParticles = resetParticles;

  // Start animation loop
  lastTime = performance.now();
  lastFpsTime = lastTime;
  isRunning = true;
  requestAnimationFrame(loop);
}

// ═══════════════════════════════════════════════════════════════════════════════
// ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════════

document.addEventListener('DOMContentLoaded', init);
