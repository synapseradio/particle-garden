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
  denA,
  matrix,
  gridCounts,
  gridOffsets,
  activeParity,
} from './buffers.js';
import { initGL, resize, render, canvas } from './renderer.js';
import { buildGrid, gridW, gridH, cellSize } from './grid.js';
import {
  createWorkers,
  dispatchPhysicsShared,
  updateWorkersMatrix,
} from './workers.js';
import {
  vxDelta,
  vyDelta,
} from './buffers.js';
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
// PHYSICS (WASM)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Run one physics step using parallel WASM workers.
 *
 * Flow:
 * 1. Build spatial grid (sorts particles by cell)
 * 2. Dispatch to workers (each runs WASM physics on its particle range)
 * 3. Apply velocity deltas from workers
 * 4. Integrate positions (friction, position update, toroidal wrap)
 *
 * @param {number} dt - Delta time in seconds (already scaled by timeScale)
 */
async function physics(dt) {
  const t0 = performance.now();

  // Build spatial grid - sorts particles by cell and flips parity
  const gridResult = buildGrid(particleCount, canvas.width, canvas.height);

  // Dispatch to WASM workers - they compute velocity deltas
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

  // Select active buffer (buildGrid flipped parity)
  const pxActive = activeParity === 1 ? pxB : pxA;
  const pyActive = activeParity === 1 ? pyB : pyA;
  const vxActive = activeParity === 1 ? vxB : vxA;
  const vyActive = activeParity === 1 ? vyB : vyA;

  const W = canvas.width;
  const H = canvas.height;
  const friction = 0.95;

  // Apply velocity deltas and integrate positions
  for (let i = 0; i < particleCount; i++) {
    // Apply delta and friction
    vxActive[i] = (vxActive[i] + vxDelta[i]) * friction;
    vyActive[i] = (vyActive[i] + vyDelta[i]) * friction;

    // Update position
    let x = pxActive[i] + vxActive[i];
    let y = pyActive[i] + vyActive[i];

    // Toroidal wrap
    if (x < 0) x += W;
    else if (x >= W) x -= W;
    if (y < 0) y += H;
    else if (y >= H) y -= H;

    pxActive[i] = x;
    pyActive[i] = y;
  }

  workerTimeMs = performance.now() - t0;
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
    updateStats(fps, 0, workerTimeMs);  // No grid time with brute force
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

  // Create worker pool (workers load WASM internally)
  createWorkers();

  // Set matrix update callback (matrix is in SharedArrayBuffer, workers see it)
  setMatrixUpdateCallback(() => updateWorkersMatrix());

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
