/**
 * Web Worker management for Goober Garden physics computation.
 *
 * ZERO-COPY ARCHITECTURE:
 * - Workers receive the shared WebAssembly.Memory object
 * - Each worker instantiates WASM with this memory
 * - WASM reads/writes particle data directly - no copies
 *
 * This module handles:
 * - Worker pool creation and initialization
 * - Physics dispatch via sync buffer coordination
 * - Worker completion synchronization using Atomics
 */

import { CONFIG, MAX_WORKERS, MEMORY_LAYOUT } from './config.js';
import { wasmMemory, syncArray, activeParity } from './buffers.js';

// ═══════════════════════════════════════════════════════════════════════════════
// FLOAT-TO-INT CONVERSION FOR ATOMICS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Convert a float to its bit representation as an int32.
 * Required because Atomics only work with integer arrays.
 */
export const floatToIntBits = (() => {
  const f32 = new Float32Array(1);
  const i32 = new Int32Array(f32.buffer);
  return (f) => {
    f32[0] = f;
    return i32[0];
  };
})();

// ═══════════════════════════════════════════════════════════════════════════════
// WORKER POOL STATE
// ═══════════════════════════════════════════════════════════════════════════════

export let workers = [];
export let workerCount = 0;
export let frameCounter = 0;

// ═══════════════════════════════════════════════════════════════════════════════
// WORKER CREATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Create and initialize the worker pool.
 *
 * Each worker receives the shared WebAssembly.Memory object.
 * Workers instantiate WASM with this memory for zero-copy access.
 */
export function createWorkers() {
  workerCount = Math.max(
    1,
    Math.min((navigator.hardwareConcurrency || 4) - 1, MAX_WORKERS),
  );

  const workerUrl = 'worker.js';

  for (let i = 0; i < workerCount; i++) {
    const worker = new Worker(workerUrl);

    // Send shared memory reference - workers use this for WASM instantiation
    worker.postMessage({
      type: 'init',
      workerIndex: i,
      wasmMemory: wasmMemory,
      syncOffset: MEMORY_LAYOUT.sync,
    });

    workers.push(worker);
  }

  console.log(`Created ${workerCount} workers (zero-copy mode)`);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MATRIX SYNCHRONIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Notify workers of matrix changes.
 * In zero-copy mode, the matrix is in shared memory - workers see updates immediately.
 */
export function updateWorkersMatrix() {
  // Matrix is in shared WASM memory - no action needed
}

// ═══════════════════════════════════════════════════════════════════════════════
// PHYSICS DISPATCH
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Dispatch physics computation to workers and wait for completion.
 *
 * ZERO-COPY: Workers read particle data directly from shared memory.
 * This function only writes config scalars to the sync buffer.
 *
 * @param {number} dt - Delta time in seconds
 * @param {number} particleCount - Number of active particles
 * @param {number} canvasWidth - Canvas width in pixels
 * @param {number} canvasHeight - Canvas height in pixels
 * @param {number} gridW - Grid width in cells
 * @param {number} gridH - Grid height in cells
 * @param {number} cellSize - Cell size in pixels
 * @param {number} mouseX - Mouse X position
 * @param {number} mouseY - Mouse Y position
 * @param {boolean} mouseDown - Whether mouse button is pressed
 * @returns {Promise<void>} Resolves when all workers have completed
 */
export async function dispatchPhysicsShared(
  dt,
  particleCount,
  canvasWidth,
  canvasHeight,
  gridW,
  gridH,
  cellSize,
  mouseX,
  mouseY,
  mouseDown
) {
  const n = particleCount;
  const perWorker = Math.ceil(n / workerCount);

  // Write worker assignments to sync buffer
  syncArray[1] = workerCount;

  for (let i = 0; i < workerCount; i++) {
    const startIdx = i * perWorker;
    const endIdx = Math.min(startIdx + perWorker, n);
    syncArray[2 + i * 2] = startIdx;
    syncArray[2 + i * 2 + 1] = endIdx;
  }

  // Config offset in sync buffer
  const configOffset = 2 + workerCount * 2;
  syncArray[configOffset + 0] = floatToIntBits(canvasWidth);
  syncArray[configOffset + 1] = floatToIntBits(canvasHeight);
  syncArray[configOffset + 2] = floatToIntBits(CONFIG.interactionRadius);
  syncArray[configOffset + 3] = gridW;
  syncArray[configOffset + 4] = gridH;
  syncArray[configOffset + 5] = floatToIntBits(cellSize);
  syncArray[configOffset + 6] = floatToIntBits(CONFIG.forceStrength * 0.5);
  syncArray[configOffset + 7] = floatToIntBits(dt);
  syncArray[configOffset + 8] = floatToIntBits(mouseX);
  syncArray[configOffset + 9] = floatToIntBits(mouseY);
  syncArray[configOffset + 10] = mouseDown ? 1 : 0;
  syncArray[configOffset + 11] = activeParity;
  syncArray[configOffset + 12] = particleCount;

  // Clear done flags
  const doneOffset = configOffset + 16;
  for (let i = 0; i < workerCount; i++) {
    Atomics.store(syncArray, doneOffset + i, 0);
  }

  // Increment frame counter to wake workers
  frameCounter++;
  Atomics.store(syncArray, 0, frameCounter);
  Atomics.notify(syncArray, 0);

  // Wait for all workers to finish
  for (let i = 0; i < workerCount; i++) {
    if (typeof Atomics.waitAsync === 'function') {
      const ret = Atomics.waitAsync(syncArray, doneOffset + i, 0);
      if (ret.async) {
        await ret.value;
      }
    } else {
      // Fallback for browsers without Atomics.waitAsync
      while (Atomics.load(syncArray, doneOffset + i) === 0) {
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
    }
  }
}
