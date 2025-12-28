/**
 * Unified WASM Memory for Goober Garden.
 *
 * This module creates a single WebAssembly.Memory backed by SharedArrayBuffer.
 * All particle data, grid structures, and sync buffers live in this unified memory.
 *
 * ZERO-COPY ARCHITECTURE:
 * - JS creates typed array views into the WASM memory
 * - Workers instantiate WASM with the same memory
 * - WASM reads/writes directly - no uploads or downloads needed
 *
 * Memory layout (defined in config.js MEMORY_LAYOUT):
 * - Offset 0-1MB: Reserved for WASM stack/heap
 * - Offset 1MB+: Particle data, grid, matrix, sync buffer
 */

import {
  MAX_PARTICLES,
  MAX_GRID,
  MAX_WORKERS,
  WASM_MEMORY_PAGES,
  MEMORY_LAYOUT,
} from './config.js';

// ═══════════════════════════════════════════════════════════════════════════════
// UNIFIED WASM MEMORY
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * The single WebAssembly.Memory that backs everything.
 * Created with `shared: true` to enable SharedArrayBuffer backing.
 * Passed to workers and WASM modules for zero-copy access.
 */
export let wasmMemory;

/**
 * The underlying SharedArrayBuffer of wasmMemory.
 * Cached once since memory growth is disabled.
 */
export let sharedBuffer;

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
// LOCAL TEMPORARY ARRAYS (not in shared memory)
// ═══════════════════════════════════════════════════════════════════════════════

export let fillOffsets;
export let renderData;

// ═══════════════════════════════════════════════════════════════════════════════
// ACTIVE BUFFER TRACKING
// ═══════════════════════════════════════════════════════════════════════════════

export let activeParity = 0;

// ═══════════════════════════════════════════════════════════════════════════════
// BUFFER ALLOCATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Create the unified WebAssembly.Memory and all typed array views.
 *
 * This creates a single 128MB SharedArrayBuffer-backed memory.
 * All particle data lives at known offsets within this memory.
 * Both JS and WASM access the same underlying buffer - zero copies.
 */
export function allocateBuffers() {
  // Create unified WASM memory with SharedArrayBuffer backing
  wasmMemory = new WebAssembly.Memory({
    initial: WASM_MEMORY_PAGES,
    maximum: WASM_MEMORY_PAGES,
    shared: true,
  });

  // Cache the buffer reference (won't change since growth is disabled)
  sharedBuffer = wasmMemory.buffer;

  const L = MEMORY_LAYOUT;
  const maxCells = MAX_GRID * MAX_GRID;

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Buffer set A
  // ─────────────────────────────────────────────────────────────────────────────

  pxA = new Float32Array(sharedBuffer, L.pxA, MAX_PARTICLES);
  pyA = new Float32Array(sharedBuffer, L.pyA, MAX_PARTICLES);
  vxA = new Float32Array(sharedBuffer, L.vxA, MAX_PARTICLES);
  vyA = new Float32Array(sharedBuffer, L.vyA, MAX_PARTICLES);
  denA = new Float32Array(sharedBuffer, L.denA, MAX_PARTICLES);
  speciesA = new Uint8Array(sharedBuffer, L.speciesA, MAX_PARTICLES);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Buffer set B
  // ─────────────────────────────────────────────────────────────────────────────

  pxB = new Float32Array(sharedBuffer, L.pxB, MAX_PARTICLES);
  pyB = new Float32Array(sharedBuffer, L.pyB, MAX_PARTICLES);
  vxB = new Float32Array(sharedBuffer, L.vxB, MAX_PARTICLES);
  vyB = new Float32Array(sharedBuffer, L.vyB, MAX_PARTICLES);
  denB = new Float32Array(sharedBuffer, L.denB, MAX_PARTICLES);
  speciesB = new Uint8Array(sharedBuffer, L.speciesB, MAX_PARTICLES);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Velocity deltas
  // ─────────────────────────────────────────────────────────────────────────────

  vxDelta = new Float32Array(sharedBuffer, L.vxDelta, MAX_PARTICLES);
  vyDelta = new Float32Array(sharedBuffer, L.vyDelta, MAX_PARTICLES);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Grid structure
  // ─────────────────────────────────────────────────────────────────────────────

  gridCounts = new Uint16Array(sharedBuffer, L.gridCounts, maxCells);
  gridOffsets = new Uint32Array(sharedBuffer, L.gridOffsets, maxCells);

  // ─────────────────────────────────────────────────────────────────────────────
  // Create typed array views - Sync and matrix
  // ─────────────────────────────────────────────────────────────────────────────

  syncArray = new Int32Array(sharedBuffer, L.sync, 256);
  matrix = new Float32Array(sharedBuffer, L.matrix, 36);

  // ─────────────────────────────────────────────────────────────────────────────
  // Local arrays (not shared with workers)
  // ─────────────────────────────────────────────────────────────────────────────

  fillOffsets = new Uint32Array(maxCells);
  renderData = new Float32Array(MAX_PARTICLES * 6);
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
