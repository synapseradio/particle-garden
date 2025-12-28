/**
 * Spatial grid construction for Goober Garden particle simulation.
 *
 * This module handles the spatial partitioning grid used for efficient neighbor queries.
 * The grid enables O(n) physics by limiting particle interactions to nearby cells.
 *
 * Key algorithm:
 * 1. Count particles per cell using source buffer positions
 * 2. Compute prefix sum to get cell offsets
 * 3. Scatter particles into destination buffer in sorted cell order
 * 4. Flip buffer parity so workers read from newly sorted buffer
 *
 * This "sort by cell" approach ensures particles in the same spatial region
 * are contiguous in memory, enabling cache-friendly iteration in workers.
 */

import { CONFIG, MAX_GRID } from './config.js';
import {
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
  gridCounts,
  gridOffsets,
  fillOffsets,
  activeParity,
  setActiveParity,
} from './buffers.js';

// Grid dimensions - updated each frame based on canvas size and interaction radius
export let gridW = 0;
export let gridH = 0;
export let cellSize = 0;

// Performance timing
export let gridTimeMs = 0;

/**
 * Build the spatial partitioning grid and sort particles by cell.
 *
 * This function:
 * 1. Determines grid dimensions from canvas size and interaction radius
 * 2. Counts particles per cell
 * 3. Computes prefix sums for cell offsets
 * 4. Scatters particles into destination buffer in sorted order
 * 5. Flips the active parity so workers read from sorted data
 *
 * @param {number} particleCount - Number of active particles
 * @param {number} canvasWidth - Canvas width in pixels
 * @param {number} canvasHeight - Canvas height in pixels
 * @returns {{ gridW: number, gridH: number, cellSize: number }}
 */
export function buildGrid(particleCount, canvasWidth, canvasHeight) {
  const t0 = performance.now();

  const n = particleCount;
  cellSize = CONFIG.interactionRadius;

  // Compute grid dimensions - perfect division of domain
  gridW = Math.floor(canvasWidth / cellSize);
  gridH = Math.floor(canvasHeight / cellSize);
  gridW = Math.max(1, Math.min(gridW, MAX_GRID));
  gridH = Math.max(1, Math.min(gridH, MAX_GRID));

  const numCells = gridW * gridH;
  const invCellW = gridW / canvasWidth;
  const invCellH = gridH / canvasHeight;

  // Determine source and destination buffers based on current parity
  const pxSrc = activeParity === 0 ? pxA : pxB;
  const pySrc = activeParity === 0 ? pyA : pyB;
  const vxSrc = activeParity === 0 ? vxA : vxB;
  const vySrc = activeParity === 0 ? vyA : vyB;
  const sSrc = activeParity === 0 ? speciesA : speciesB;

  const pxDst = activeParity === 0 ? pxB : pxA;
  const pyDst = activeParity === 0 ? pyB : pyA;
  const vxDst = activeParity === 0 ? vxB : vxA;
  const vyDst = activeParity === 0 ? vyB : vyA;
  const sDst = activeParity === 0 ? speciesB : speciesA;

  // Clear counts - clear entire buffer to prevent stale data access
  // WASM might access cells beyond numCells if particle positions are out of bounds
  const maxCells = gridCounts.length;
  for (let i = 0; i < maxCells; i++) gridCounts[i] = 0;

  // Count particles per cell using source positions
  for (let i = 0; i < n; i++) {
    let cx = (pxSrc[i] * invCellW) | 0;
    let cy = (pySrc[i] * invCellH) | 0;

    if (cx >= gridW) cx = gridW - 1;
    else if (cx < 0) cx = 0;

    if (cy >= gridH) cy = gridH - 1;
    else if (cy < 0) cy = 0;

    gridCounts[cy * gridW + cx]++;
  }

  // Prefix sum for offsets
  let off = 0;
  for (let i = 0; i < numCells; i++) {
    gridOffsets[i] = off;
    fillOffsets[i] = off; // Keep a copy for filling
    off += gridCounts[i];
  }

  // SCATTER: Reorder particles into destination buffers
  // This is the sort - particles are copied to contiguous positions by cell
  for (let i = 0; i < n; i++) {
    let cx = (pxSrc[i] * invCellW) | 0;
    let cy = (pySrc[i] * invCellH) | 0;

    if (cx >= gridW) cx = gridW - 1;
    else if (cx < 0) cx = 0;

    if (cy >= gridH) cy = gridH - 1;
    else if (cy < 0) cy = 0;

    const cell = cy * gridW + cx;
    const dstIdx = fillOffsets[cell]++;

    // Copy all particle data to sorted position
    pxDst[dstIdx] = pxSrc[i];
    pyDst[dstIdx] = pySrc[i];
    vxDst[dstIdx] = vxSrc[i];
    vyDst[dstIdx] = vySrc[i];
    sDst[dstIdx] = sSrc[i];
  }

  // Flip the buffer parity
  // Workers will now read from destination buffer (which is sorted)
  setActiveParity(1 - activeParity);

  gridTimeMs = performance.now() - t0;

  return { gridW, gridH, cellSize };
}
