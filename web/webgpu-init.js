/**
 * WebGPU Device Initialization for Goober Garden.
 *
 * This module handles:
 * - Feature detection for WebGPU availability
 * - GPU adapter and device acquisition with appropriate limits
 * - GPU buffer creation matching the SharedArrayBuffer memory layout
 * - Graceful fallback when WebGPU is unavailable
 *
 * HYBRID ARCHITECTURE:
 * WebGPU compute shaders will handle physics calculations while WebGL1
 * continues to handle rendering. Both systems operate on the same logical
 * memory structure for seamless data sharing.
 *
 * MEMORY LAYOUT:
 * GPU buffers mirror the MEMORY_LAYOUT structure defined in config.js:
 * - Particle buffers A/B (positions, velocities, species, density)
 * - Velocity delta buffers (worker accumulation targets)
 * - Spatial grid buffers (counts and offsets)
 * - Attraction matrix and sync buffers
 */

import {
  MAX_PARTICLES,
  MAX_GRID,
  MAX_SPECIES,
  MEMORY_LAYOUT,
} from './config.js';

// ═══════════════════════════════════════════════════════════════════════════════
// GPU STATE
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * The WebGPU adapter representing the physical GPU.
 * @type {GPUAdapter | null}
 */
export let adapter = null;

/**
 * The WebGPU logical device for GPU operations.
 * @type {GPUDevice | null}
 */
export let device = null;

/**
 * The device's command queue for submitting GPU work.
 * @type {GPUQueue | null}
 */
export let queue = null;

/**
 * WebGPU buffers mirroring the SharedArrayBuffer layout.
 * Each buffer corresponds to a section of MEMORY_LAYOUT.
 * @type {Object.<string, GPUBuffer>}
 */
export let buffers = {};

/**
 * Whether WebGPU initialization succeeded.
 * @type {boolean}
 */
export let isWebGPUAvailable = false;

// ═══════════════════════════════════════════════════════════════════════════════
// BUFFER SIZE CALCULATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Calculate GPU buffer sizes matching the SharedArrayBuffer memory layout.
 * All sizes must be aligned to 4 bytes for WebGPU requirements.
 *
 * @returns {Object} Buffer size specifications
 */
function calculateBufferSizes() {
  const floatSize = MAX_PARTICLES * 4; // Float32 = 4 bytes per element
  const gridCells = MAX_GRID * MAX_GRID;

  // Species uses u32 in WGSL shaders (for compatibility with storage buffers)
  const speciesBufferSize = MAX_PARTICLES * 4; // u32 per particle

  return {
    // Particle data - positions (2x float32 per particle)
    position: floatSize * 2, // px and py interleaved would be optimal, but matching SAB layout

    // Particle data - velocities (2x float32 per particle)
    velocity: floatSize * 2,

    // Particle data - density (1x float32 per particle)
    density: floatSize,

    // Particle data - species (1x uint8 per particle, aligned)
    species: speciesBufferSize,

    // Velocity deltas for accumulation (2x float32 per particle)
    velocityDelta: floatSize * 2,

    // Spatial grid - cell occupancy counts (uint32 per cell for WGSL atomic<u32>)
    gridCounts: gridCells * 4,

    // Spatial grid - particle offset indices (uint32 per cell)
    gridOffsets: gridCells * 4,

    // Attraction matrix (species x species interactions)
    matrix: MAX_SPECIES * MAX_SPECIES * 4, // float32

    // Sync primitives (256 int32s for atomics)
    sync: 256 * 4,

    // Sorted indices mapping (uint32 per particle)
    sortedIndices: MAX_PARTICLES * 4, // Maps sorted index → original particle index
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
// FEATURE DETECTION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Check if WebGPU is available in the current environment.
 *
 * @returns {boolean} True if navigator.gpu exists and appears functional
 */
function detectWebGPU() {
  if (!navigator.gpu) {
    console.warn('WebGPU not supported: navigator.gpu is undefined');
    return false;
  }

  // Additional sanity checks
  if (typeof navigator.gpu.requestAdapter !== 'function') {
    console.warn('WebGPU not supported: requestAdapter method missing');
    return false;
  }

  return true;
}

// ═══════════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Initialize WebGPU device and create GPU buffers.
 *
 * This function:
 * 1. Detects WebGPU availability
 * 2. Requests a GPU adapter with required features
 * 3. Creates a logical device with appropriate limits
 * 4. Allocates GPU buffers matching the SharedArrayBuffer layout
 *
 * @returns {Promise<{success: boolean, error?: string}>}
 */
export async function initWebGPU() {
  try {
    // ─────────────────────────────────────────────────────────────────────────
    // Phase 1: Feature Detection
    // ─────────────────────────────────────────────────────────────────────────

    if (!detectWebGPU()) {
      return {
        success: false,
        error: 'WebGPU is not available in this browser. Try Chrome 113+ or Edge 113+.',
      };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 2: Request Adapter
    // ─────────────────────────────────────────────────────────────────────────

    adapter = await navigator.gpu.requestAdapter({
      powerPreference: 'high-performance', // Prefer discrete GPU if available
    });

    if (!adapter) {
      return {
        success: false,
        error: 'Failed to obtain WebGPU adapter. Your GPU may not support WebGPU.',
      };
    }

    console.log('WebGPU adapter acquired:', adapter.info || 'Info unavailable');

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 3: Request Device with Limits
    // ─────────────────────────────────────────────────────────────────────────

    // Calculate required buffer sizes
    const sizes = calculateBufferSizes();
    const maxBufferSize = Math.max(...Object.values(sizes));

    // Request device with limits sufficient for our workload
    device = await adapter.requestDevice({
      requiredLimits: {
        maxBufferSize: maxBufferSize * 4, // Request 4x headroom
        maxStorageBufferBindingSize: maxBufferSize * 4,
        maxComputeWorkgroupSizeX: 256, // For particle processing
        maxComputeWorkgroupsPerDimension: Math.ceil(MAX_PARTICLES / 256),
      },
    });

    if (!device) {
      return {
        success: false,
        error: 'Failed to create WebGPU device.',
      };
    }

    queue = device.queue;

    // Set up error handling
    device.addEventListener('uncapturederror', (event) => {
      console.error('WebGPU uncaptured error:', event.error);
    });

    // Handle device loss
    device.lost.then((info) => {
      console.error('WebGPU device lost:', info.message);
      isWebGPUAvailable = false;
    });

    console.log('WebGPU device created with limits:', device.limits);

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 4: Create GPU Buffers
    // ─────────────────────────────────────────────────────────────────────────

    // Create buffers for double-buffered particle data (A and B sets)
    const bufferUsage = GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST;

    // Positions - separate buffers for A and B sets
    buffers.pxA = device.createBuffer({
      size: sizes.position / 2,
      usage: bufferUsage,
      label: 'Particle Positions X (Set A)',
    });

    buffers.pyA = device.createBuffer({
      size: sizes.position / 2,
      usage: bufferUsage,
      label: 'Particle Positions Y (Set A)',
    });

    buffers.pxB = device.createBuffer({
      size: sizes.position / 2,
      usage: bufferUsage,
      label: 'Particle Positions X (Set B)',
    });

    buffers.pyB = device.createBuffer({
      size: sizes.position / 2,
      usage: bufferUsage,
      label: 'Particle Positions Y (Set B)',
    });

    // Velocities - separate buffers for A and B sets
    buffers.vxA = device.createBuffer({
      size: sizes.velocity / 2,
      usage: bufferUsage,
      label: 'Particle Velocities X (Set A)',
    });

    buffers.vyA = device.createBuffer({
      size: sizes.velocity / 2,
      usage: bufferUsage,
      label: 'Particle Velocities Y (Set A)',
    });

    buffers.vxB = device.createBuffer({
      size: sizes.velocity / 2,
      usage: bufferUsage,
      label: 'Particle Velocities X (Set B)',
    });

    buffers.vyB = device.createBuffer({
      size: sizes.velocity / 2,
      usage: bufferUsage,
      label: 'Particle Velocities Y (Set B)',
    });

    // Density - separate buffers for A and B sets
    buffers.denA = device.createBuffer({
      size: sizes.density,
      usage: bufferUsage,
      label: 'Particle Density (Set A)',
    });

    buffers.denB = device.createBuffer({
      size: sizes.density,
      usage: bufferUsage,
      label: 'Particle Density (Set B)',
    });

    // Species - separate buffers for A and B sets
    buffers.speciesA = device.createBuffer({
      size: sizes.species,
      usage: bufferUsage,
      label: 'Particle Species (Set A)',
    });

    buffers.speciesB = device.createBuffer({
      size: sizes.species,
      usage: bufferUsage,
      label: 'Particle Species (Set B)',
    });

    // Velocity deltas (workers write here, physics integrates)
    buffers.vxDelta = device.createBuffer({
      size: sizes.velocityDelta / 2,
      usage: bufferUsage,
      label: 'Velocity Delta X',
    });

    buffers.vyDelta = device.createBuffer({
      size: sizes.velocityDelta / 2,
      usage: bufferUsage,
      label: 'Velocity Delta Y',
    });

    // Spatial grid buffers
    buffers.gridCounts = device.createBuffer({
      size: sizes.gridCounts,
      usage: bufferUsage,
      label: 'Grid Cell Counts',
    });

    buffers.gridOffsets = device.createBuffer({
      size: sizes.gridOffsets,
      usage: bufferUsage,
      label: 'Grid Cell Offsets',
    });

    // Attraction matrix
    buffers.matrix = device.createBuffer({
      size: sizes.matrix,
      usage: bufferUsage | GPUBufferUsage.UNIFORM, // Also usable as uniform
      label: 'Attraction Matrix',
    });

    // Sync buffer (for atomics - needs special handling in WGSL)
    buffers.sync = device.createBuffer({
      size: sizes.sync,
      usage: bufferUsage,
      label: 'Synchronization Buffer',
    });

    // Sorted indices buffer (bin-scatter output, forces input)
    buffers.sortedIndices = device.createBuffer({
      size: sizes.sortedIndices,
      usage: bufferUsage,
      label: 'Sorted Indices Buffer',
    });

    // Fill pointers buffer (bin-scatter uses as atomic counters)
    // Initialized from gridOffsets before bin-scatter, then incremented per particle.
    // This is separate from gridCounts because forces needs the original counts.
    buffers.fillPointers = device.createBuffer({
      size: sizes.gridOffsets,
      usage: bufferUsage,
      label: 'Fill Pointers Buffer',
    });

    console.log('WebGPU buffers created:', Object.keys(buffers).length, 'buffers');

    // ─────────────────────────────────────────────────────────────────────────
    // Success
    // ─────────────────────────────────────────────────────────────────────────

    isWebGPUAvailable = true;

    return {
      success: true,
      info: {
        adapter: adapter.info || 'Unknown adapter',
        limits: device.limits,
        bufferCount: Object.keys(buffers).length,
        totalMemory: Object.values(sizes).reduce((sum, size) => sum + size, 0),
      },
    };
  } catch (error) {
    console.error('WebGPU initialization failed:', error);

    return {
      success: false,
      error: `WebGPU initialization error: ${error.message}`,
    };
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLEANUP
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Clean up WebGPU resources.
 * Call this before page unload or when switching back to WASM-only mode.
 */
export function cleanup() {
  // Destroy all buffers
  Object.values(buffers).forEach((buffer) => {
    if (buffer && typeof buffer.destroy === 'function') {
      buffer.destroy();
    }
  });

  buffers = {};

  // Destroy device
  if (device && typeof device.destroy === 'function') {
    device.destroy();
  }

  adapter = null;
  device = null;
  queue = null;
  isWebGPUAvailable = false;

  console.log('WebGPU resources cleaned up');
}
