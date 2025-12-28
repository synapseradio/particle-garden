/**
 * Configuration and constants for Goober Garden simulation.
 *
 * This module exports:
 * - CONFIG: Mutable runtime configuration (particle count, physics params, rendering options)
 * - MAX_* constants: Upper bounds for buffer allocation and grid sizing
 * - COLORS: Species color palette as interleaved RGB Float32Array
 */

// Runtime configuration - these values can be modified during simulation
export const CONFIG = {
  particleCount: 16000, // Number of active particles
  speciesCount: 4, // Number of particle species (affects matrix size)
  interactionRadius: 50, // Radius for particle-particle force calculations
  forceStrength: 1.0, // Multiplier for attraction/repulsion forces
  friction: 0.05, // Velocity damping per frame
  timeScale: 0.5, // Simulation speed multiplier
  particleSize: 2, // Base render size for particles
  trails: false, // Enable trail rendering mode
  trailAlpha: 0.92, // Trail fade factor (higher = longer trails)
};

// Buffer allocation limits - these determine SharedArrayBuffer sizes
export const MAX_PARTICLES = 64000; // Maximum supported particle count
export const MAX_SPECIES = 6; // Maximum species for attraction matrix
export const MAX_GRID = 256; // Maximum grid cells per dimension
export const MAX_WORKERS = 16; // Maximum Web Workers for physics

// Unified WASM memory layout (128MB total)
// All particle data lives in WASM linear memory for zero-copy access
export const WASM_MEMORY_PAGES = 2048; // 128MB (each page = 64KB)
export const WASM_DATA_OFFSET = 1024 * 1024; // 1MB - skip WASM internals

// Memory layout offsets (computed from WASM_DATA_OFFSET)
// Each offset is relative to WASM memory start (byte 0)
export const MEMORY_LAYOUT = (() => {
  let offset = WASM_DATA_OFFSET;
  const floatSize = MAX_PARTICLES * 4;
  const uint8Size = MAX_PARTICLES;
  const gridCells = MAX_GRID * MAX_GRID;

  const layout = {
    // Buffer A (source during even frames)
    pxA: offset,
    pyA: (offset += floatSize),
    vxA: (offset += floatSize),
    vyA: (offset += floatSize),
    denA: (offset += floatSize),
    speciesA: (offset += floatSize),

    // Buffer B (source during odd frames)
    pxB: (offset += uint8Size, offset = (offset + 3) & ~3), // Align to 4 bytes
    pyB: (offset += floatSize),
    vxB: (offset += floatSize),
    vyB: (offset += floatSize),
    denB: (offset += floatSize),
    speciesB: (offset += floatSize),

    // Velocity deltas (workers write here)
    vxDelta: (offset += uint8Size, offset = (offset + 3) & ~3),
    vyDelta: (offset += floatSize),

    // Spatial grid
    gridCounts: (offset += floatSize),
    gridOffsets: (offset += gridCells * 2, offset = (offset + 3) & ~3),

    // Attraction matrix (6x6 = 36 floats)
    matrix: (offset += gridCells * 4),

    // Sync buffer for Atomics (must be 4-byte aligned for Int32Array)
    sync: (offset += 36 * 4, offset = (offset + 3) & ~3),

    // End marker
    totalSize: (offset += 256 * 4), // 256 int32s for sync
  };

  return layout;
})();

// Species color palette - interleaved RGB values (6 species x 3 components)
export const COLORS = new Float32Array([
  1.0,
  0.42,
  0.42, // Red
  1.0,
  0.85,
  0.24, // Yellow
  0.42,
  0.8,
  0.47, // Green
  0.3,
  0.59,
  1.0, // Blue
  0.73,
  0.42,
  1.0, // Purple
  1.0,
  0.55,
  0.3, // Orange
]);
