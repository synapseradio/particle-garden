/**
 * SharedArrayBuffer allocation and typed array view management for Goober Garden.
 *
 * This module handles all shared memory allocation for the particle simulation:
 * - Double-buffered particle data (position, velocity, species, density)
 * - Velocity delta buffers for worker output
 * - Grid structure buffers for spatial partitioning
 * - Sync buffer for worker coordination via Atomics
 * - Matrix buffer for species interaction rules
 *
 * Double buffering enables lock-free sorting: while workers read from one buffer set,
 * the main thread can write sorted particle data to the other.
 */

import {
  MAX_PARTICLES,
  MAX_SPECIES,
  MAX_GRID,
  MAX_WORKERS,
} from './config.js';

// ═══════════════════════════════════════════════════════════════════════════════
// DOUBLE-BUFFERED PARTICLE DATA
// ═══════════════════════════════════════════════════════════════════════════════

// Buffer set A
export let pxBufferA;
export let pyBufferA;
export let vxBufferA;
export let vyBufferA;
export let speciesBufferA;
export let denBufferA;

// Buffer set B
export let pxBufferB;
export let pyBufferB;
export let vxBufferB;
export let vyBufferB;
export let speciesBufferB;
export let denBufferB;

// ═══════════════════════════════════════════════════════════════════════════════
// VELOCITY DELTA BUFFERS (workers write accumulated forces here)
// ═══════════════════════════════════════════════════════════════════════════════

export let vxDeltaBuffer;
export let vyDeltaBuffer;

// ═══════════════════════════════════════════════════════════════════════════════
// GRID BUFFERS (spatial partitioning for O(n) neighbor queries)
// ═══════════════════════════════════════════════════════════════════════════════

export let gridCountsBuffer;
export let gridOffsetsBuffer;

// ═══════════════════════════════════════════════════════════════════════════════
// SYNC AND MATRIX BUFFERS
// ═══════════════════════════════════════════════════════════════════════════════

export let syncBuffer;
export let matrixBuffer;

// ═══════════════════════════════════════════════════════════════════════════════
// TYPED ARRAY VIEWS - Buffer set A
// ═══════════════════════════════════════════════════════════════════════════════

export let pxA;
export let pyA;
export let vxA;
export let vyA;
export let speciesA;
export let denA;

// ═══════════════════════════════════════════════════════════════════════════════
// TYPED ARRAY VIEWS - Buffer set B
// ═══════════════════════════════════════════════════════════════════════════════

export let pxB;
export let pyB;
export let vxB;
export let vyB;
export let speciesB;
export let denB;

// ═══════════════════════════════════════════════════════════════════════════════
// TYPED ARRAY VIEWS - Velocity deltas
// ═══════════════════════════════════════════════════════════════════════════════

export let vxDelta;
export let vyDelta;

// ═══════════════════════════════════════════════════════════════════════════════
// TYPED ARRAY VIEWS - Grid structure
// ═══════════════════════════════════════════════════════════════════════════════

export let gridCounts;
export let gridOffsets;

// ═══════════════════════════════════════════════════════════════════════════════
// TYPED ARRAY VIEWS - Sync and matrix
// ═══════════════════════════════════════════════════════════════════════════════

export let syncArray;
export let matrix;

// ═══════════════════════════════════════════════════════════════════════════════
// LOCAL TEMPORARY ARRAYS (not shared with workers)
// ═══════════════════════════════════════════════════════════════════════════════

export let fillOffsets;
export let renderData;

// ═══════════════════════════════════════════════════════════════════════════════
// ACTIVE BUFFER TRACKING
// ═══════════════════════════════════════════════════════════════════════════════

// 0 = A is active/source, 1 = B is active/source
// Flipped after each grid build to swap read/write buffers
export let activeParity = 0;

// Memory bandwidth saved per frame (calculated in allocateBuffers)
export let bytesSavedPerFrame = 0;

// ═══════════════════════════════════════════════════════════════════════════════
// BUFFER ALLOCATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Allocate all SharedArrayBuffers and create typed array views.
 *
 * Buffer layout:
 * - Particle data: Float32 for positions/velocities/density, Uint8 for species
 * - Grid: Uint16 for counts (max 65535 particles per cell), Uint32 for offsets
 * - Sync: Int32 for Atomics operations
 * - Matrix: Float32 for interaction strengths
 */
export function allocateBuffers() {
  const BufferType = SharedArrayBuffer;

  // ─────────────────────────────────────────────────────────────────────────────
  // Particle data - DOUBLE BUFFERED
  // ─────────────────────────────────────────────────────────────────────────────

  pxBufferA = new BufferType(MAX_PARTICLES * 4);
  pyBufferA = new BufferType(MAX_PARTICLES * 4);
  vxBufferA = new BufferType(MAX_PARTICLES * 4);
  vyBufferA = new BufferType(MAX_PARTICLES * 4);
  speciesBufferA = new BufferType(MAX_PARTICLES);
  denBufferA = new BufferType(MAX_PARTICLES * 4);

  pxBufferB = new BufferType(MAX_PARTICLES * 4);
  pyBufferB = new BufferType(MAX_PARTICLES * 4);
  vxBufferB = new BufferType(MAX_PARTICLES * 4);
  vyBufferB = new BufferType(MAX_PARTICLES * 4);
  speciesBufferB = new BufferType(MAX_PARTICLES);
  denBufferB = new BufferType(MAX_PARTICLES * 4);

  // ─────────────────────────────────────────────────────────────────────────────
  // Velocity deltas (workers write here)
  // ─────────────────────────────────────────────────────────────────────────────

  vxDeltaBuffer = new BufferType(MAX_PARTICLES * 4);
  vyDeltaBuffer = new BufferType(MAX_PARTICLES * 4);

  // ─────────────────────────────────────────────────────────────────────────────
  // Grid structure
  // ─────────────────────────────────────────────────────────────────────────────

  const maxCells = MAX_GRID * MAX_GRID;
  gridCountsBuffer = new BufferType(maxCells * 2); // Uint16
  gridOffsetsBuffer = new BufferType(maxCells * 4); // Uint32
  fillOffsets = new Uint32Array(maxCells); // Temp (local only)

  // ─────────────────────────────────────────────────────────────────────────────
  // Sync buffer for Atomics
  // Layout: [frameCounter, workerCount, ...workerAssignments, ...config, ...doneFlags]
  // ─────────────────────────────────────────────────────────────────────────────

  const syncSize = 2 + MAX_WORKERS * 2 + 16 + MAX_WORKERS;
  syncBuffer = new BufferType(syncSize * 4);

  // ─────────────────────────────────────────────────────────────────────────────
  // Matrix buffer for species interactions
  // ─────────────────────────────────────────────────────────────────────────────

  matrixBuffer = new BufferType(MAX_SPECIES * MAX_SPECIES * 4);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Buffer set A
  // ─────────────────────────────────────────────────────────────────────────────

  pxA = new Float32Array(pxBufferA);
  pyA = new Float32Array(pyBufferA);
  vxA = new Float32Array(vxBufferA);
  vyA = new Float32Array(vyBufferA);
  speciesA = new Uint8Array(speciesBufferA);
  denA = new Float32Array(denBufferA);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Buffer set B
  // ─────────────────────────────────────────────────────────────────────────────

  pxB = new Float32Array(pxBufferB);
  pyB = new Float32Array(pyBufferB);
  vxB = new Float32Array(vxBufferB);
  vyB = new Float32Array(vyBufferB);
  speciesB = new Uint8Array(speciesBufferB);
  denB = new Float32Array(denBufferB);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Velocity deltas
  // ─────────────────────────────────────────────────────────────────────────────

  vxDelta = new Float32Array(vxDeltaBuffer);
  vyDelta = new Float32Array(vyDeltaBuffer);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Grid structure
  // ─────────────────────────────────────────────────────────────────────────────

  gridCounts = new Uint16Array(gridCountsBuffer);
  gridOffsets = new Uint32Array(gridOffsetsBuffer);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Sync and matrix
  // ─────────────────────────────────────────────────────────────────────────────

  syncArray = new Int32Array(syncBuffer);
  matrix = new Float32Array(matrixBuffer);

  // ─────────────────────────────────────────────────────────────────────────────
  // Render buffer (not shared, only used by main thread)
  // ─────────────────────────────────────────────────────────────────────────────

  renderData = new Float32Array(MAX_PARTICLES * 6);

  // ─────────────────────────────────────────────────────────────────────────────
  // Calculate memory saved per frame (virtual bandwidth)
  // ─────────────────────────────────────────────────────────────────────────────

  const bytesPerWorker =
    MAX_PARTICLES * 4 * 3 + // px, py, species
    MAX_GRID * MAX_GRID * 2 +
    MAX_GRID * MAX_GRID * 4;
  bytesSavedPerFrame = bytesPerWorker * (navigator.hardwareConcurrency - 1);
}

// ═══════════════════════════════════════════════════════════════════════════════
// PARITY MANAGEMENT
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Set the active parity. Used by grid building to flip buffers after sorting.
 * @param {number} parity - 0 for buffer set A, 1 for buffer set B
 */
export function setActiveParity(parity) {
  activeParity = parity;
}
