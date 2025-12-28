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
import { buildGrid, computeGridDimensions, gridW, gridH, cellSize } from './grid.js';
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
import {
  initWebGPU,
  isWebGPUAvailable as webgpuAvailable,
} from './webgpu-init.js';
import {
  initPipelines,
  runPhysicsFrame,
  isPipelineReady,
  uploadInitialData,
} from './webgpu-compute.js';

// ═══════════════════════════════════════════════════════════════════════════════
// MODULE STATE
// ═══════════════════════════════════════════════════════════════════════════════

// DIAGNOSTIC: Enable WebGPU debugging (set to true to see checkpoint logs)
// To enable: type `__WEBGPU_DEBUG__ = true` in browser console
globalThis.__WEBGPU_DEBUG__ = true;
globalThis.__WEBGPU_DEBUG_FRAME__ = 0;

let particleCount = 0;
let isRunning = false;
let useWebGPU = false; // Set to true if WebGPU is available and initialized

// Timing and stats
let lastTime = 0;
let frameCount = 0;
let fps = 0;
let lastFpsTime = 0;
let workerTimeMs = 0;

// Performance profiling - per-frame measurements
let gridTimeMs = 0;
let physicsTimeMs = 0;
let integrationTimeMs = 0;
let renderPackTimeMs = 0;
let renderUploadTimeMs = 0;

// Performance profiling - rolling averages (over 60 frames)
const PROFILING_WINDOW = 60;
let profilingFrameCount = 0;
let gridTimeSum = 0;
let physicsTimeSum = 0;
let integrationTimeSum = 0;
let renderPackTimeSum = 0;
let renderUploadTimeSum = 0;
let totalTimeSum = 0;

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
// PHYSICS (DUAL PATH: WebGPU or WASM)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Run one physics step using WebGPU compute shaders (if available) or WASM workers.
 *
 * WebGPU Flow (all on GPU):
 * 1. Pass 1: bin-count (count particles per cell)
 * 2. Pass 2: prefix-sum (exclusive scan for cell offsets)
 * 3. Pass 3: bin-scatter (scatter particles to sorted order)
 * 4. Pass 4: forces (compute inter-particle forces)
 * 5. Pass 5: integrate (apply forces and update positions)
 *
 * WASM Flow (CPU parallel):
 * 1. Build spatial grid (sorts particles by cell)
 * 2. Dispatch to workers (each runs WASM physics on its particle range)
 * 3. Apply velocity deltas from workers
 * 4. Integrate positions (friction, position update, toroidal wrap)
 *
 * @param {number} dt - Delta time in seconds (already scaled by timeScale)
 */
async function physics(dt) {
  const t0 = performance.now();

  if (useWebGPU && isPipelineReady) {
    // ═══════════════════════════════════════════════════════════════════════
    // WebGPU Compute Path (ALL computation on GPU)
    // ═══════════════════════════════════════════════════════════════════════

    // Only compute grid dimensions - no CPU sorting
    const gridResult = computeGridDimensions(canvas.width, canvas.height);
    gridTimeMs = 0; // Grid built on GPU

    const tPhysics0 = performance.now();

    await runPhysicsFrame({
      dt,
      particleCount,
      width: canvas.width,
      height: canvas.height,
      gridW: gridResult.gridW,
      gridH: gridResult.gridH,
      rMax: CONFIG.interactionRadius,
      fMul: CONFIG.forceStrength,
      friction: 0.95,
      mouseX,
      mouseY,
      mouseDown: mouseDown ? 1 : 0,
      parity: 0, // WebGPU always uses buffer set A as source
      matrix,
    });

    physicsTimeMs = performance.now() - tPhysics0;
    integrationTimeMs = 0; // Integration happens on GPU

    workerTimeMs = performance.now() - t0;
  } else {
    // ═══════════════════════════════════════════════════════════════════════
    // WASM Worker Path (CPU parallel)
    // ═══════════════════════════════════════════════════════════════════════

    // Phase 1: Build spatial grid - sorts particles by cell and flips parity
    const tGrid0 = performance.now();
    const gridResult = buildGrid(particleCount, canvas.width, canvas.height);
    gridTimeMs = performance.now() - tGrid0;

    // Phase 2: Dispatch to WASM workers - they compute velocity deltas
    const tPhysics0 = performance.now();
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
    physicsTimeMs = performance.now() - tPhysics0;

    // Phase 3: Integration - apply velocity deltas and integrate positions
    const tIntegration0 = performance.now();

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

    integrationTimeMs = performance.now() - tIntegration0;

    workerTimeMs = performance.now() - t0;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PERFORMANCE PROFILING
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Report aggregated profiling data over the profiling window.
 * Computes averages and percentages to identify bottlenecks.
 */
function reportProfilingData() {
  const n = profilingFrameCount;
  if (n === 0) return;

  const avgGrid = gridTimeSum / n;
  const avgPhysics = physicsTimeSum / n;
  const avgIntegration = integrationTimeSum / n;
  const avgRenderPack = renderPackTimeSum / n;
  const avgRenderUpload = renderUploadTimeSum / n;
  const avgTotal = totalTimeSum / n;

  // Compute percentages
  const pctGrid = (avgGrid / avgTotal) * 100;
  const pctPhysics = (avgPhysics / avgTotal) * 100;
  const pctIntegration = (avgIntegration / avgTotal) * 100;
  const pctRenderPack = (avgRenderPack / avgTotal) * 100;
  const pctRenderUpload = (avgRenderUpload / avgTotal) * 100;

  // Compute serial fraction (grid + integration + renderPack are currently serial)
  const serialTime = avgGrid + avgIntegration + avgRenderPack;
  const serialFraction = (serialTime / avgTotal) * 100;

  // Compute theoretical Amdahl's Law maximum speedup
  const s = serialTime / avgTotal;
  const maxSpeedup = 1 / (s + (1 - s) / navigator.hardwareConcurrency);

  console.log(`
╔═══════════════════════════════════════════════════════════════════════════════╗
║ PERFORMANCE PROFILE (avg over ${n} frames, ${particleCount} particles)
╠═══════════════════════════════════════════════════════════════════════════════╣
║ Phase Breakdown:
║   Grid Construction:    ${avgGrid.toFixed(2)}ms (${pctGrid.toFixed(1)}%)
║   Physics (WASM):       ${avgPhysics.toFixed(2)}ms (${pctPhysics.toFixed(1)}%)  [parallel]
║   Integration:          ${avgIntegration.toFixed(2)}ms (${pctIntegration.toFixed(1)}%)
║   Render Pack:          ${avgRenderPack.toFixed(2)}ms (${pctRenderPack.toFixed(1)}%)
║   Render Upload/Draw:   ${avgRenderUpload.toFixed(2)}ms (${pctRenderUpload.toFixed(1)}%)
║   ────────────────────────────────────────────────────────────────────────
║   TOTAL:                ${avgTotal.toFixed(2)}ms (${avgTotal > 0 ? ((1000/avgTotal)).toFixed(1) : '0'} FPS)
╠═══════════════════════════════════════════════════════════════════════════════╣
║ Parallelization Analysis:
║   Serial Time:          ${serialTime.toFixed(2)}ms (${serialFraction.toFixed(1)}%)
║   Parallel Time:        ${avgPhysics.toFixed(2)}ms (${pctPhysics.toFixed(1)}%)
║   Serial Fraction (s):  ${(s * 100).toFixed(1)}%
║
║   Amdahl's Law (${navigator.hardwareConcurrency} cores):
║   Max Theoretical Speedup: ${maxSpeedup.toFixed(2)}x
║
║   If serial fraction drops to 14%:
║   Predicted Max Speedup:    ${(1 / (0.14 + (1 - 0.14) / navigator.hardwareConcurrency)).toFixed(2)}x
╚═══════════════════════════════════════════════════════════════════════════════╝
  `);
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

  const frameStart = performance.now();
  globalThis.__WEBGPU_DEBUG_FRAME__++;

  // Compute delta time, capped to prevent spiral of death
  const dt = Math.min((now - lastTime) / 1000, 0.05) * CONFIG.timeScale;
  lastTime = now;

  await physics(dt);

  const renderTiming = render(particleCount);
  renderPackTimeMs = renderTiming.packTimeMs;
  renderUploadTimeMs = renderTiming.uploadTimeMs;

  const frameTotal = performance.now() - frameStart;

  // Accumulate profiling data
  gridTimeSum += gridTimeMs;
  physicsTimeSum += physicsTimeMs;
  integrationTimeSum += integrationTimeMs;
  renderPackTimeSum += renderPackTimeMs;
  renderUploadTimeSum += renderUploadTimeMs;
  totalTimeSum += frameTotal;
  profilingFrameCount++;

  // Update FPS and stats every 500ms
  frameCount++;
  if (now - lastFpsTime > 500) {
    fps = ((frameCount * 1000) / (now - lastFpsTime)) | 0;
    frameCount = 0;
    lastFpsTime = now;
    updateStats(fps, 0, workerTimeMs);  // No grid time with brute force
  }

  // Report profiling data every PROFILING_WINDOW frames
  if (profilingFrameCount >= PROFILING_WINDOW) {
    reportProfilingData();
    // Reset accumulators
    profilingFrameCount = 0;
    gridTimeSum = 0;
    physicsTimeSum = 0;
    integrationTimeSum = 0;
    renderPackTimeSum = 0;
    renderUploadTimeSum = 0;
    totalTimeSum = 0;
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

  // Try to initialize WebGPU (optional acceleration)
  console.log('Attempting WebGPU initialization...');
  const webgpuResult = await initWebGPU();
  if (webgpuResult.success) {
    console.log('✓ WebGPU device acquired:', webgpuResult.info);
    console.log('Initializing WebGPU compute pipelines...');
    const pipelineResult = await initPipelines();
    if (pipelineResult.success) {
      console.log('✓ WebGPU compute pipelines ready:', pipelineResult.info);
      useWebGPU = true;
      console.log('→ Physics acceleration: WebGPU compute shaders');
    } else {
      console.warn('✗ WebGPU pipeline initialization failed:', pipelineResult.error);
      console.log('→ Falling back to WASM workers');
    }
  } else {
    console.warn('✗ WebGPU not available:', webgpuResult.error);
    console.log('→ Using WASM workers for physics');
  }

  // Set matrix update callback (matrix is in SharedArrayBuffer, workers see it)
  setMatrixUpdateCallback(() => updateWorkersMatrix());

  // Initialize attraction matrix with random values
  randomizeMatrix();

  // Initialize particles
  initParticles();

  // Upload particle data to GPU if using WebGPU
  if (useWebGPU) {
    console.log('Uploading initial particle data to GPU...');
    const uploadResult = await uploadInitialData(particleCount);
    if (uploadResult.success) {
      console.log('✓ Initial data uploaded to GPU');
    } else {
      console.warn('✗ Failed to upload initial data:', uploadResult.error);
      console.log('→ Falling back to WASM workers');
      useWebGPU = false;
    }
  }

  // Only create worker pool if WebGPU is not available
  if (!useWebGPU) {
    createWorkers();
  }

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
