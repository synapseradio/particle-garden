/**
 * Web Worker management for Goober Garden physics computation.
 *
 * This module handles:
 * - Worker pool creation and initialization with SharedArrayBuffer references
 * - Float-to-int bit conversion for Atomics-based config passing
 * - Physics dispatch via sync buffer coordination
 * - Worker completion synchronization using Atomics.waitAsync
 *
 * Workers read particle data from shared buffers, compute velocity deltas,
 * and signal completion through the sync buffer. The main thread then
 * applies the accumulated deltas.
 */

import { CONFIG, MAX_WORKERS } from './config.js';
import {
  pxBufferA,
  pyBufferA,
  speciesBufferA,
  denBufferA,
  pxBufferB,
  pyBufferB,
  speciesBufferB,
  denBufferB,
  vxDeltaBuffer,
  vyDeltaBuffer,
  gridCountsBuffer,
  gridOffsetsBuffer,
  syncBuffer,
  matrixBuffer,
  syncArray,
  activeParity,
} from './buffers.js';

// ═══════════════════════════════════════════════════════════════════════════════
// FLOAT-TO-INT CONVERSION FOR ATOMICS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Convert a float to its bit representation as an int32.
 * Required because Atomics only work with integer arrays, but we need to pass
 * float configuration values (canvas size, cell size, mouse position, etc.)
 * through the sync buffer.
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
 * Worker count is based on available hardware concurrency minus one (for the main thread).
 * Each worker receives references to all SharedArrayBuffers on initialization,
 * establishing the zero-copy communication channel.
 */
export function createWorkers() {
  workerCount = Math.max(
    1,
    Math.min((navigator.hardwareConcurrency || 4) - 1, MAX_WORKERS),
  );

  const workerUrl = 'worker.js';

  for (let i = 0; i < workerCount; i++) {
    const worker = new Worker(workerUrl);

    // Send shared buffer references once - workers retain these for all future frames
    worker.postMessage({
      type: 'init',
      workerIndex: i,
      pxBufferA,
      pyBufferA,
      speciesBufferA,
      densityBufferA: denBufferA,
      pxBufferB,
      pyBufferB,
      speciesBufferB,
      densityBufferB: denBufferB,
      vxDeltaBuffer,
      vyDeltaBuffer,
      gridCountsBuffer,
      gridOffsetsBuffer,
      syncBuffer,
      matrixBuffer,
    });

    workers.push(worker);
  }

  console.log(
    `Created ${workerCount} workers in SharedArrayBuffer mode`,
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// MATRIX SYNCHRONIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Notify workers of matrix changes.
 *
 * In SharedArrayBuffer mode, the matrix is already in shared memory.
 * Workers will see updates automatically on their next read.
 * This function exists for interface compatibility.
 */
export function updateWorkersMatrix() {
  // SAB mode: matrix is already in shared memory, workers will see the update
}

// ═══════════════════════════════════════════════════════════════════════════════
// PHYSICS DISPATCH
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Dispatch physics computation to workers and wait for completion.
 *
 * This function:
 * 1. Writes worker assignments (particle index ranges) to the sync buffer
 * 2. Writes configuration values (canvas size, physics params) to sync buffer
 * 3. Clears done flags and increments frame counter to wake workers
 * 4. Waits for all workers to signal completion via Atomics.waitAsync
 *
 * Workers compute velocity deltas for their assigned particle ranges.
 * The caller is responsible for applying those deltas after this returns.
 *
 * @param {number} dt - Delta time in seconds
 * @param {number} particleCount - Number of active particles
 * @param {number} canvasWidth - Canvas width in pixels
 * @param {number} canvasHeight - Canvas height in pixels
 * @param {number} gridW - Grid width in cells
 * @param {number} gridH - Grid height in cells
 * @param {number} cellSize - Cell size in pixels (equals interaction radius)
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

  // Write worker assignments and config to sync buffer
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
  syncArray[configOffset + 11] = activeParity; // Tell workers which buffer to read

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
