/**
 * WebGPU Compute Pipeline Orchestration for Goober Garden.
 *
 * This module implements the 5-pass physics pipeline:
 * - Pass 1: bin-count (count particles per cell)
 * - Pass 2: prefix-sum (exclusive scan for cell offsets)
 * - Pass 3: bin-scatter (scatter particles to sorted order)
 * - Pass 4: forces (compute inter-particle forces)
 * - Pass 5: integrate (apply forces and update positions)
 *
 * BUFFER PARITY:
 * The simulation uses double-buffering (A/B sets) to avoid read-write hazards.
 * - Read from buffer set with parity N
 * - Write to buffer set with parity (1-N)
 * - After integration, flip parity
 *
 * SYNCHRONIZATION:
 * All 5 passes are encoded into a single command buffer and submitted together.
 * The GPU automatically handles inter-pass synchronization via buffer barriers.
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 * BINDING MANIFESTS (Shader Contract Documentation)
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * These manifests document the binding contracts between WGSL shaders and JS bind groups.
 * The shader declarations are the canonical source of truth.
 *
 * PASS 1: BIN-COUNT (bin-count.wgsl)
 * ┌─────────┬───────────────┬────────────────┬──────────────────┬────────────┐
 * │ Binding │ Shader Type   │ Access         │ JS Buffer        │ Size       │
 * ├─────────┼───────────────┼────────────────┼──────────────────┼────────────┤
 * │    0    │ uniform       │ read           │ gridParams       │ 32 bytes   │
 * │    1    │ storage       │ read           │ px (parity src)  │ N * 4      │
 * │    2    │ storage       │ read           │ py (parity src)  │ N * 4      │
 * │    3    │ storage       │ read_write     │ gridCounts       │ cells * 4  │
 * └─────────┴───────────────┴────────────────┴──────────────────┴────────────┘
 * EXPECTED ENTRY COUNT: 4
 *
 * PASS 2: PREFIX-SUM (prefix-sum.wgsl)
 * ┌─────────┬───────────────┬────────────────┬──────────────────┬────────────┐
 * │ Binding │ Shader Type   │ Access         │ JS Buffer        │ Size       │
 * ├─────────┼───────────────┼────────────────┼──────────────────┼────────────┤
 * │    0    │ uniform       │ read           │ scanParams       │ 16 bytes   │
 * │    1    │ storage       │ read           │ gridCounts       │ cells * 4  │
 * │    2    │ storage       │ read_write     │ gridOffsets      │ cells * 4  │
 * └─────────┴───────────────┴────────────────┴──────────────────┴────────────┘
 * EXPECTED ENTRY COUNT: 3
 *
 * PASS 3: BIN-SCATTER (bin-scatter.wgsl)
 *
 * ARCHITECTURAL NOTE: This shader only builds sortedIndices mapping, it does NOT
 * physically scatter particle data. The forces pass uses indirect indexing
 * (pxA[sortedIndices[j]]) to read particles in spatially-sorted order from the
 * original unsorted buffers. This design keeps us under WebGPU's 8-storage-buffer
 * limit. If cache performance becomes a bottleneck, we could split into multiple
 * passes to physically scatter data.
 *
 * ┌─────────┬───────────────┬────────────────┬──────────────────┬────────────┐
 * │ Binding │ Shader Type   │ Access         │ JS Buffer        │ Size       │
 * ├─────────┼───────────────┼────────────────┼──────────────────┼────────────┤
 * │    0    │ uniform       │ read           │ gridParams       │ 32 bytes   │
 * │    1    │ storage       │ read           │ srcPx            │ N * 4      │
 * │    2    │ storage       │ read           │ srcPy            │ N * 4      │
 * │    3    │ storage       │ read_write     │ sortedIndices    │ N * 4      │
 * │    4    │ storage       │ read_write     │ fillPointers     │ cells * 4  │
 * └─────────┴───────────────┴────────────────┴──────────────────┴────────────┘
 * EXPECTED ENTRY COUNT: 5
 * STORAGE BUFFER COUNT: 4 (under 8-buffer WebGPU limit)
 *
 * NOTE: fillPointers is copied from gridOffsets by JS before dispatch
 *
 * PASS 4: FORCES (forces.wgsl)
 *
 * ARCHITECTURAL NOTE: JS binds only the ACTIVE buffer set (A or B) based on
 * parity - shader doesn't select at runtime. Matrix is embedded in SimParams
 * uniform to stay at exactly 8 storage buffers (the WebGPU per-stage limit).
 * Density computation removed; add separate pass if needed.
 *
 * ┌─────────┬───────────────┬────────────────┬──────────────────┬────────────┐
 * │ Binding │ Shader Type   │ Access         │ JS Buffer        │ Size       │
 * ├─────────┼───────────────┼────────────────┼──────────────────┼────────────┤
 * │    0    │ uniform       │ read           │ simParams        │ 192 bytes  │
 * │         │ (w/ matrix)   │                │ (12 params + 36) │            │
 * │    1    │ storage       │ read           │ pxSrc (active)   │ N * 4      │
 * │    2    │ storage       │ read           │ pySrc (active)   │ N * 4      │
 * │    3    │ storage       │ read           │ speciesSrc       │ N * 4      │
 * │    4    │ storage       │ read           │ sortedIndices    │ N * 4      │
 * │    5    │ storage       │ read           │ cellOffsets      │ cells * 4  │
 * │    6    │ storage       │ read           │ cellCounts       │ cells * 4  │
 * │    7    │ storage       │ read_write     │ vxDelta          │ N * 4      │
 * │    8    │ storage       │ read_write     │ vyDelta          │ N * 4      │
 * └─────────┴───────────────┴────────────────┴──────────────────┴────────────┘
 * EXPECTED ENTRY COUNT: 9
 * STORAGE BUFFER COUNT: 8 (at WebGPU limit)
 *
 * PASS 5: INTEGRATE (integrate.wgsl)
 * ┌─────────┬───────────────┬────────────────┬──────────────────┬────────────┐
 * │ Binding │ Shader Type   │ Access         │ JS Buffer        │ Size       │
 * ├─────────┼───────────────┼────────────────┼──────────────────┼────────────┤
 * │    0    │ uniform       │ read           │ integrationParams│ 16 bytes   │
 * │    1    │ storage       │ read_write     │ px (active)      │ N * 4      │
 * │    2    │ storage       │ read_write     │ py (active)      │ N * 4      │
 * │    3    │ storage       │ read_write     │ vx (active)      │ N * 4      │
 * │    4    │ storage       │ read_write     │ vy (active)      │ N * 4      │
 * │    5    │ storage       │ read           │ vxDelta          │ N * 4      │
 * │    6    │ storage       │ read           │ vyDelta          │ N * 4      │
 * └─────────┴───────────────┴────────────────┴──────────────────┴────────────┘
 * EXPECTED ENTRY COUNT: 7
 */

import { device, queue, buffers, isWebGPUAvailable } from './webgpu-init.js';
import { MAX_SPECIES } from './config.js';

// ═══════════════════════════════════════════════════════════════════════════════
// BINDING CONTRACT VALIDATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Expected entry counts for each pass (from shader binding manifests above).
 * These are the canonical source of truth from the WGSL shader declarations.
 */
const EXPECTED_BIND_GROUP_ENTRIES = {
  binCount: 4,
  prefixSum: 3,
  binScatter: 5,  // Index mapping only (no cellOffsets - fillOffsets initialized by JS)
  forces: 9,      // Active buffer set only, matrix in uniform, no density
  density: 8,     // Grid-based density computation for visual sizing
  integrate: 7,
};

// ═══════════════════════════════════════════════════════════════════════════════
// PIPELINE STATE
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Compiled shader modules for each compute pass.
 * @type {Object.<string, GPUShaderModule>}
 */
let shaderModules = {};

/**
 * Compute pipelines for each pass.
 * @type {Object.<string, GPUComputePipeline>}
 */
let pipelines = {};

/**
 * Bind group layouts for each pass.
 * @type {Object.<string, GPUBindGroupLayout>}
 */
let bindGroupLayouts = {};

/**
 * Uniform buffers for passing parameters to shaders.
 * @type {Object.<string, GPUBuffer>}
 */
let uniformBuffers = {};

/**
 * Bind groups (created per-frame based on parity).
 * We don't cache these because they change with parity.
 * @type {Object.<string, GPUBindGroup>}
 */
let bindGroups = {};

/**
 * Whether pipelines have been initialized.
 * @type {boolean}
 */
let isPipelineReady = false;

// ═══════════════════════════════════════════════════════════════════════════════
// SHADER LOADING
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * VALIDATION: Verify shader compilation succeeded.
 * Checks for compilation errors that would cause silent failures later.
 *
 * @param {GPUShaderModule} shaderModule - The compiled shader module
 * @param {string} label - Shader label for error messages
 * @throws {Error} If shader compilation failed
 */
async function validateShaderCompilation(shaderModule, label) {
  const compilationInfo = await shaderModule.getCompilationInfo();

  if (compilationInfo.messages.length > 0) {
    const errors = compilationInfo.messages.filter((msg) => msg.type === 'error');
    const warnings = compilationInfo.messages.filter((msg) => msg.type === 'warning');

    if (errors.length > 0) {
      const errorDetails = errors
        .map((err) => `  Line ${err.lineNum}: ${err.message}`)
        .join('\n');
      throw new Error(
        `Shader compilation failed for "${label}":\n${errorDetails}`
      );
    }

    if (warnings.length > 0) {
      console.warn(
        `Shader compilation warnings for "${label}":`,
        warnings.map((w) => `Line ${w.lineNum}: ${w.message}`)
      );
    }
  }
}

/**
 * VALIDATION: Verify bind group layout extraction succeeded.
 * The layout must exist and be a valid GPUBindGroupLayout object.
 *
 * @param {GPUBindGroupLayout | null} layout - The extracted layout
 * @param {string} passName - Pass name for error messages
 * @throws {Error} If layout is null or invalid
 */
function validateBindGroupLayout(layout, passName) {
  if (!layout) {
    throw new Error(
      `Failed to extract bind group layout for pass "${passName}". ` +
        `Layout is null. This typically means the pipeline creation failed ` +
        `or getBindGroupLayout(0) was called on an invalid pipeline.`
    );
  }

  // Type check (GPUBindGroupLayout should be an object)
  if (typeof layout !== 'object') {
    throw new Error(
      `Invalid bind group layout for pass "${passName}". ` +
        `Expected GPUBindGroupLayout object, got ${typeof layout}.`
    );
  }
}

/**
 * VALIDATION: Verify bind group entry count matches shader expectations.
 * This catches mismatches between JS bind group creation and WGSL bindings.
 *
 * @param {Array} entries - The bind group entries array
 * @param {string} passName - Pass name (must match EXPECTED_BIND_GROUP_ENTRIES keys)
 * @param {string} phase - Phase description for error context (e.g., "bind group creation")
 * @throws {Error} If entry count doesn't match expected count
 */
function validateBindGroupEntryCount(entries, passName, phase) {
  const expected = EXPECTED_BIND_GROUP_ENTRIES[passName];

  if (expected === undefined) {
    throw new Error(
      `Internal error: No expected entry count defined for pass "${passName}". ` +
        `Check EXPECTED_BIND_GROUP_ENTRIES constant.`
    );
  }

  if (entries.length !== expected) {
    throw new Error(
      `Bind group entry count mismatch for pass "${passName}" during ${phase}:\n` +
        `  Expected: ${expected} entries (from shader manifest)\n` +
        `  Actual: ${entries.length} entries\n` +
        `  This means the JS bind group creation does not match the WGSL shader bindings.\n` +
        `  Check the binding manifest at the top of this file for the correct contract.`
    );
  }
}

/**
 * Load a shader module from a WGSL file.
 *
 * @param {string} path - Path to the shader file
 * @param {string} label - Label for debugging
 * @returns {Promise<GPUShaderModule>}
 */
async function loadShader(path, label) {
  const response = await fetch(path);
  if (!response.ok) {
    throw new Error(`Failed to load shader ${path}: ${response.statusText}`);
  }

  const code = await response.text();

  const shaderModule = device.createShaderModule({
    code,
    label,
  });

  // VALIDATION: Check shader compilation immediately
  await validateShaderCompilation(shaderModule, label);

  return shaderModule;
}

// ═══════════════════════════════════════════════════════════════════════════════
// PIPELINE INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Initialize all compute pipelines and buffers.
 * Call this once after WebGPU device initialization.
 *
 * @returns {Promise<{success: boolean, error?: string}>}
 */
export async function initPipelines() {
  if (!isWebGPUAvailable || !device) {
    return {
      success: false,
      error: 'WebGPU device not available',
    };
  }

  try {
    // ═════════════════════════════════════════════════════════════════════════
    // PHASE: SHADER LOADING
    // ═════════════════════════════════════════════════════════════════════════
    // Precondition: WebGPU device must be initialized
    // Postcondition: All shader modules compiled without errors

    console.log('[PHASE: SHADER LOADING] Loading WebGPU compute shaders...');

    const [binCountModule, prefixSumModule, binScatterModule, forcesModule, densityModule, integrateModule] =
      await Promise.all([
        loadShader('./shaders/bin-count.wgsl', 'Bin Count Shader'),
        loadShader('./shaders/prefix-sum.wgsl', 'Prefix Sum Shader'),
        loadShader('./shaders/bin-scatter.wgsl', 'Bin Scatter Shader'),
        loadShader('./shaders/forces.wgsl', 'Forces Shader'),
        loadShader('./shaders/density.wgsl', 'Density Shader'),
        loadShader('./shaders/integrate.wgsl', 'Integration Shader'),
      ]);

    shaderModules = {
      binCount: binCountModule,
      prefixSum: prefixSumModule,
      binScatter: binScatterModule,
      forces: forcesModule,
      density: densityModule,
      integrate: integrateModule,
    };

    console.log('[PHASE: SHADER LOADING] Success - Shaders loaded:', Object.keys(shaderModules).length);

    // ═════════════════════════════════════════════════════════════════════════
    // PHASE: UNIFORM BUFFER CREATION
    // ═════════════════════════════════════════════════════════════════════════
    // Precondition: Device initialized
    // Postcondition: All uniform buffers created with correct sizes

    // Grid parameters for bin-count, bin-scatter (32 bytes aligned)
    uniformBuffers.gridParams = device.createBuffer({
      size: 32,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      label: 'Grid Parameters Uniform',
    });

    // Scan parameters for prefix-sum (16 bytes aligned)
    uniformBuffers.scanParams = device.createBuffer({
      size: 16,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      label: 'Scan Parameters Uniform',
    });

    // Simulation parameters for forces (192 bytes: 12 params + 36 matrix floats)
    // SimParams struct layout:
    //   0-11: dt, W, H, rMax, fMul, gridW, gridH, mouseX, mouseY, mouseDown, particleCount, _pad
    //   12-47: matrix[36] (6x6 attraction matrix, row-major)
    uniformBuffers.simParams = device.createBuffer({
      size: 192, // 48 floats × 4 bytes
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      label: 'Simulation Parameters Uniform (with matrix)',
    });

    // Integration parameters (16 bytes aligned - W, H, friction, particleCount)
    uniformBuffers.integrationParams = device.createBuffer({
      size: 16,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      label: 'Integration Parameters Uniform',
    });

    // Density parameters (32 bytes aligned - W, H, rMax, gridW, gridH, particleCount, _pad x2)
    uniformBuffers.densityParams = device.createBuffer({
      size: 32,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      label: 'Density Parameters Uniform',
    });

    console.log('[PHASE: UNIFORM BUFFER CREATION] Success - Uniform buffers created:', Object.keys(uniformBuffers).length);

    // ═════════════════════════════════════════════════════════════════════════
    // PHASE: PIPELINE CREATION (with error scope validation)
    // ═════════════════════════════════════════════════════════════════════════
    // Precondition: Shader modules compiled and valid
    // Postcondition: All pipelines created, bind group layouts extracted and validated

    // Helper to create pipeline with error scope validation
    async function createPipelineWithValidation(name, shaderModule, entryPoint) {
      device.pushErrorScope('validation');
      const pipeline = device.createComputePipeline({
        layout: 'auto',
        compute: {
          module: shaderModule,
          entryPoint: entryPoint,
        },
        label: `${name} Pipeline`,
      });
      const error = await device.popErrorScope();
      if (error) {
        throw new Error(`Pipeline creation failed for "${name}": ${error.message}`);
      }
      console.log(`  ✓ ${name} pipeline created`);
      return pipeline;
    }

    console.log('[PHASE: PIPELINE CREATION] Creating compute pipelines...');

    // Pass 1: Bin Count
    pipelines.binCount = await createPipelineWithValidation('Bin Count', shaderModules.binCount, 'main');

    // Pass 2: Prefix Sum
    pipelines.prefixSum = await createPipelineWithValidation('Prefix Sum', shaderModules.prefixSum, 'main');

    // Pass 3: Bin Scatter
    pipelines.binScatter = await createPipelineWithValidation('Bin Scatter', shaderModules.binScatter, 'main');

    // Pass 4: Forces
    pipelines.forces = await createPipelineWithValidation('Forces', shaderModules.forces, 'computeForces');

    // Pass 4b: Density
    pipelines.density = await createPipelineWithValidation('Density', shaderModules.density, 'computeDensity');

    // Pass 5: Integration
    pipelines.integrate = await createPipelineWithValidation('Integration', shaderModules.integrate, 'integrate');

    // Extract bind group layouts for later bind group creation
    console.log('[PHASE: LAYOUT EXTRACTION] Extracting bind group layouts...');

    device.pushErrorScope('validation');
    bindGroupLayouts.binCount = pipelines.binCount.getBindGroupLayout(0);
    bindGroupLayouts.prefixSum = pipelines.prefixSum.getBindGroupLayout(0);
    bindGroupLayouts.binScatter = pipelines.binScatter.getBindGroupLayout(0);
    bindGroupLayouts.forces = pipelines.forces.getBindGroupLayout(0);
    bindGroupLayouts.density = pipelines.density.getBindGroupLayout(0);
    bindGroupLayouts.integrate = pipelines.integrate.getBindGroupLayout(0);
    const layoutError = await device.popErrorScope();
    if (layoutError) {
      throw new Error(`Bind group layout extraction failed: ${layoutError.message}`);
    }

    // VALIDATION: Verify all bind group layouts extracted successfully
    validateBindGroupLayout(bindGroupLayouts.binCount, 'binCount');
    validateBindGroupLayout(bindGroupLayouts.prefixSum, 'prefixSum');
    validateBindGroupLayout(bindGroupLayouts.binScatter, 'binScatter');
    validateBindGroupLayout(bindGroupLayouts.forces, 'forces');
    validateBindGroupLayout(bindGroupLayouts.density, 'density');
    validateBindGroupLayout(bindGroupLayouts.integrate, 'integrate');

    console.log('[PHASE: PIPELINE CREATION] Success - All pipelines and layouts validated');

    isPipelineReady = true;

    return {
      success: true,
      info: {
        shaderCount: Object.keys(shaderModules).length,
        pipelineCount: Object.keys(pipelines).length,
      },
    };
  } catch (error) {
    console.error('Pipeline initialization failed:', error);

    return {
      success: false,
      error: `Pipeline initialization error: ${error.message}`,
    };
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// BIND GROUP CREATION (PER-FRAME PHASE)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Create a single bind group with error scope validation.
 * Captures validation errors synchronously for debugging.
 *
 * @param {string} passName - Name of the pass for error messages
 * @param {GPUBindGroupLayout} layout - The bind group layout
 * @param {Array} entries - The bind group entries
 * @param {string} label - Label for the bind group
 * @returns {Promise<GPUBindGroup>} The created bind group
 * @throws {Error} If bind group creation fails validation
 */
async function createBindGroupWithValidation(passName, layout, entries, label) {
  device.pushErrorScope('validation');
  const bindGroup = device.createBindGroup({
    layout,
    entries,
    label,
  });
  const error = await device.popErrorScope();
  if (error) {
    // Build detailed error message with entry info
    const entryDetails = entries
      .map((e) => `    binding ${e.binding}: buffer=${e.resource.buffer?.label || 'unlabeled'}`)
      .join('\n');
    throw new Error(
      `Bind group creation failed for "${passName}":\n` +
        `  Error: ${error.message}\n` +
        `  Layout: ${layout.label || 'unlabeled'}\n` +
        `  Entries (${entries.length}):\n${entryDetails}`
    );
  }
  return bindGroup;
}

/**
 * Create bind groups for all passes based on current buffer parity.
 * This is called each frame because bind groups reference different buffers
 * depending on read/write parity.
 *
 * PHASE: PER-FRAME SETUP
 * Precondition: Pipelines initialized, bind group layouts extracted
 * Postcondition: All bind groups created with correct buffer bindings for current parity
 *
 * @param {number} parity - 0 or 1, determines which buffer set to read from
 * @param {number} gridW - Grid width in cells
 * @param {number} gridH - Grid height in cells
 * @returns {Promise<void>}
 */
async function createBindGroups(parity, gridW, gridH) {
  const numCells = gridW * gridH;

  // Determine source buffers based on parity
  const pxSrc = parity === 0 ? buffers.pxA : buffers.pxB;
  const pySrc = parity === 0 ? buffers.pyA : buffers.pyB;
  const vxSrc = parity === 0 ? buffers.vxA : buffers.vxB;
  const vySrc = parity === 0 ? buffers.vyA : buffers.vyB;
  const speciesSrc = parity === 0 ? buffers.speciesA : buffers.speciesB;
  const denSrc = parity === 0 ? buffers.denA : buffers.denB;

  // Determine destination buffers (opposite parity)
  const pxDst = parity === 0 ? buffers.pxB : buffers.pxA;
  const pyDst = parity === 0 ? buffers.pyB : buffers.pyA;
  const vxDst = parity === 0 ? buffers.vxB : buffers.vxA;
  const vyDst = parity === 0 ? buffers.vyB : buffers.vyA;
  const speciesDst = parity === 0 ? buffers.speciesB : buffers.speciesA;
  const denDst = parity === 0 ? buffers.denB : buffers.denA;

  // Pass 1: Bin Count (SoA layout - separate px/py buffers)
  const binCountEntries = [
    { binding: 0, resource: { buffer: uniformBuffers.gridParams } },
    { binding: 1, resource: { buffer: pxSrc } },
    { binding: 2, resource: { buffer: pySrc } },
    { binding: 3, resource: { buffer: buffers.gridCounts } },
  ];
  validateBindGroupEntryCount(binCountEntries, 'binCount', 'bind group creation');
  bindGroups.binCount = await createBindGroupWithValidation(
    'Bin Count',
    bindGroupLayouts.binCount,
    binCountEntries,
    'Bin Count Bind Group'
  );

  // Pass 2: Prefix Sum
  const prefixSumEntries = [
    { binding: 0, resource: { buffer: uniformBuffers.scanParams } },
    { binding: 1, resource: { buffer: buffers.gridCounts } },
    { binding: 2, resource: { buffer: buffers.gridOffsets } },
  ];
  validateBindGroupEntryCount(prefixSumEntries, 'prefixSum', 'bind group creation');
  bindGroups.prefixSum = await createBindGroupWithValidation(
    'Prefix Sum',
    bindGroupLayouts.prefixSum,
    prefixSumEntries,
    'Prefix Sum Bind Group'
  );

  // Pass 3: Bin Scatter (index mapping only - no physical scatter)
  //
  // ARCHITECTURAL DECISION: This pass only builds sortedIndices mapping.
  // It does NOT physically scatter particle data to sorted buffers.
  // The forces pass reads from original unsorted buffers using indirect indexing:
  //   jIdx = sortedIndices[j]; data = pxA[jIdx]
  //
  // This keeps us under WebGPU's 8-storage-buffer-per-stage limit.
  // Trade-off: Indirect memory access in forces vs. physical scatter overhead.
  // If profiling shows cache misses are a bottleneck, we can split into
  // multiple passes to physically scatter data.
  //
  // NOTE: fillPointers (binding 4) must be initialized with cell start offsets
  // (copy of gridOffsets) before this pass runs. Each thread atomically increments
  // fillPointers[cell] to get its write slot.
  const binScatterEntries = [
    { binding: 0, resource: { buffer: uniformBuffers.gridParams } },
    // Source positions (for cell computation)
    { binding: 1, resource: { buffer: pxSrc } },
    { binding: 2, resource: { buffer: pySrc } },
    // Output: sorted index mapping (sortedIndices[sortedIdx] = originalIdx)
    { binding: 3, resource: { buffer: buffers.sortedIndices } },
    // Atomic fill counters (initialized from gridOffsets before dispatch)
    { binding: 4, resource: { buffer: buffers.fillPointers } },
  ];
  validateBindGroupEntryCount(binScatterEntries, 'binScatter', 'bind group creation');
  bindGroups.binScatter = await createBindGroupWithValidation(
    'Bin Scatter',
    bindGroupLayouts.binScatter,
    binScatterEntries,
    'Bin Scatter Bind Group'
  );

  // Pass 4: Forces
  //
  // ARCHITECTURAL DECISION: JS binds only the ACTIVE buffer set based on parity.
  // The shader doesn't select at runtime - this saves 3 storage buffer slots.
  // Matrix is embedded in SimParams uniform (saves 1 slot).
  // Density output removed (saves 1 slot).
  // Result: Exactly 8 storage buffers (at WebGPU limit).
  const forcesEntries = [
    { binding: 0, resource: { buffer: uniformBuffers.simParams } },
    // Active buffer set only (JS selects based on parity)
    { binding: 1, resource: { buffer: pxSrc } },
    { binding: 2, resource: { buffer: pySrc } },
    { binding: 3, resource: { buffer: speciesSrc } },
    // Spatial grid data
    { binding: 4, resource: { buffer: buffers.sortedIndices } },
    { binding: 5, resource: { buffer: buffers.gridOffsets } },
    { binding: 6, resource: { buffer: buffers.gridCounts } },
    // Output: velocity deltas
    { binding: 7, resource: { buffer: buffers.vxDelta } },
    { binding: 8, resource: { buffer: buffers.vyDelta } },
  ];
  validateBindGroupEntryCount(forcesEntries, 'forces', 'bind group creation');
  bindGroups.forces = await createBindGroupWithValidation(
    'Forces',
    bindGroupLayouts.forces,
    forcesEntries,
    'Forces Bind Group'
  );

  // Pass 4b: Density
  // Uses same grid structure as forces, writes to ACTIVE density buffer
  // (density is computed for current positions, used for rendering current frame)
  const densityEntries = [
    { binding: 0, resource: { buffer: uniformBuffers.densityParams } },
    { binding: 1, resource: { buffer: pxSrc } },
    { binding: 2, resource: { buffer: pySrc } },
    { binding: 3, resource: { buffer: speciesSrc } },
    { binding: 4, resource: { buffer: buffers.sortedIndices } },
    { binding: 5, resource: { buffer: buffers.gridOffsets } },
    { binding: 6, resource: { buffer: buffers.gridCounts } },
    { binding: 7, resource: { buffer: denSrc } },  // Write to active density buffer
  ];
  validateBindGroupEntryCount(densityEntries, 'density', 'bind group creation');
  bindGroups.density = await createBindGroupWithValidation(
    'Density',
    bindGroupLayouts.density,
    densityEntries,
    'Density Bind Group'
  );

  // Pass 5: Integration (in-place update on active buffer)
  // Bind the active buffer set based on parity
  const pxActive = parity === 0 ? buffers.pxA : buffers.pxB;
  const pyActive = parity === 0 ? buffers.pyA : buffers.pyB;
  const vxActive = parity === 0 ? buffers.vxA : buffers.vxB;
  const vyActive = parity === 0 ? buffers.vyA : buffers.vyB;

  const integrateEntries = [
    { binding: 0, resource: { buffer: uniformBuffers.integrationParams } },
    // Active buffers (in-place read/write)
    { binding: 1, resource: { buffer: pxActive } },
    { binding: 2, resource: { buffer: pyActive } },
    { binding: 3, resource: { buffer: vxActive } },
    { binding: 4, resource: { buffer: vyActive } },
    // Velocity deltas (read)
    { binding: 5, resource: { buffer: buffers.vxDelta } },
    { binding: 6, resource: { buffer: buffers.vyDelta } },
  ];
  validateBindGroupEntryCount(integrateEntries, 'integrate', 'bind group creation');
  bindGroups.integrate = await createBindGroupWithValidation(
    'Integration',
    bindGroupLayouts.integrate,
    integrateEntries,
    'Integration Bind Group'
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// PHYSICS FRAME EXECUTION
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Run one physics frame using the 5-pass GPU compute pipeline.
 *
 * @param {Object} params - Frame parameters
 * @param {number} params.dt - Delta time
 * @param {number} params.particleCount - Number of active particles
 * @param {number} params.width - Canvas width
 * @param {number} params.height - Canvas height
 * @param {number} params.gridW - Grid width in cells
 * @param {number} params.gridH - Grid height in cells
 * @param {number} params.rMax - Interaction radius
 * @param {number} params.fMul - Force multiplier
 * @param {number} params.friction - Friction coefficient
 * @param {number} params.mouseX - Mouse X position
 * @param {number} params.mouseY - Mouse Y position
 * @param {number} params.mouseDown - Mouse button state (0 or 1)
 * @param {number} params.parity - Current buffer parity (0 or 1)
 * @param {Float32Array} params.matrix - Attraction matrix (6x6 = 36 floats)
 * @returns {Promise<void>}
 */
export async function runPhysicsFrame(params) {
  if (!isPipelineReady) {
    throw new Error('Pipelines not initialized. Call initPipelines() first.');
  }

  const {
    dt,
    particleCount,
    width,
    height,
    gridW,
    gridH,
    rMax,
    fMul,
    friction,
    mouseX,
    mouseY,
    mouseDown,
    parity,
    matrix,
  } = params;

  const numCells = gridW * gridH;
  const workgroupSize = 64;
  const particleWorkgroups = Math.ceil(particleCount / workgroupSize);

  // ═════════════════════════════════════════════════════════════════════════
  // PHASE: PER-FRAME UNIFORM UPDATE
  // ═════════════════════════════════════════════════════════════════════════
  // Precondition: Uniform buffers created
  // Postcondition: All uniform buffers contain current frame parameters

  // Grid parameters (used by bin-count and bin-scatter)
  const gridParamsData = new Uint32Array([
    gridW,
    gridH,
    0, // padding (will be overwritten by float view)
    0, // padding
    particleCount,
    0, // padding
    0, // padding
    0, // padding
  ]);
  const gridParamsFloat = new Float32Array(gridParamsData.buffer);
  gridParamsFloat[2] = width;
  gridParamsFloat[3] = height;
  queue.writeBuffer(uniformBuffers.gridParams, 0, gridParamsData);

  // Scan parameters (used by prefix-sum)
  const scanParamsData = new Uint32Array([numCells, 0, 0, 0]);
  queue.writeBuffer(uniformBuffers.scanParams, 0, scanParamsData);

  // Simulation parameters (used by forces)
  // Matches SimParams struct in forces.wgsl:
  //   0-11: dt, W, H, rMax, fMul, gridW, gridH, mouseX, mouseY, mouseDown, particleCount, _pad
  //   12-47: matrix[36] (6x6 attraction matrix)
  const simParamsData = new Float32Array(48); // 192 bytes / 4 = 48 floats
  simParamsData[0] = dt;
  simParamsData[1] = width;
  simParamsData[2] = height;
  simParamsData[3] = rMax;
  simParamsData[4] = fMul;
  const simParamsUint = new Uint32Array(simParamsData.buffer);
  simParamsUint[5] = gridW;
  simParamsUint[6] = gridH;
  simParamsData[7] = mouseX;
  simParamsData[8] = mouseY;
  simParamsData[9] = mouseDown ? 1.0 : 0.0;
  simParamsUint[10] = particleCount;
  simParamsUint[11] = 0; // padding (_pad0)
  // Copy attraction matrix (36 floats starting at index 12)
  for (let i = 0; i < 36; i++) {
    simParamsData[12 + i] = matrix[i];
  }
  queue.writeBuffer(uniformBuffers.simParams, 0, simParamsData);

  // Density parameters (32 bytes: W, H, rMax, gridW, gridH, particleCount, _pad x2)
  const densityParamsData = new Float32Array(8);
  densityParamsData[0] = width;
  densityParamsData[1] = height;
  densityParamsData[2] = rMax;
  const densityParamsUint = new Uint32Array(densityParamsData.buffer);
  densityParamsUint[3] = gridW;
  densityParamsUint[4] = gridH;
  densityParamsUint[5] = particleCount;
  densityParamsUint[6] = 0; // _pad0
  densityParamsUint[7] = 0; // _pad1
  queue.writeBuffer(uniformBuffers.densityParams, 0, densityParamsData);

  // Integration parameters (16 bytes: W, H, friction, particleCount)
  const integrationParamsData = new Float32Array(4);
  integrationParamsData[0] = width;
  integrationParamsData[1] = height;
  integrationParamsData[2] = friction;
  const integrationParamsUint = new Uint32Array(integrationParamsData.buffer);
  integrationParamsUint[3] = particleCount;
  queue.writeBuffer(uniformBuffers.integrationParams, 0, integrationParamsData);

  // ═════════════════════════════════════════════════════════════════════════
  // PHASE: BIND GROUP CREATION
  // ═════════════════════════════════════════════════════════════════════════
  // Precondition: Bind group layouts extracted, buffers ready
  // Postcondition: All bind groups created with parity-correct buffer bindings
  //
  // Note: createBindGroups is async because it uses error scopes to validate
  // each bind group creation. This catches shader↔JS binding mismatches
  // immediately with detailed error messages instead of failing silently.

  await createBindGroups(parity, gridW, gridH);

  // ═════════════════════════════════════════════════════════════════════════
  // PHASE: COMMAND ENCODING (DISPATCH)
  // ═════════════════════════════════════════════════════════════════════════
  // Precondition: Bind groups created, pipelines ready
  // Postcondition: Command buffer encoded with all 5 compute passes

  const commandEncoder = device.createCommandEncoder({
    label: 'Physics Frame Command Encoder',
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Clear gridCounts before bin-count (counts accumulate via atomicAdd)
  // ─────────────────────────────────────────────────────────────────────────────
  const gridCountBytes = numCells * 4; // u32 per cell
  commandEncoder.clearBuffer(buffers.gridCounts, 0, gridCountBytes);

  // ─────────────────────────────────────────────────────────────────────────────
  // Compute Pass 1: Grid building (bin-count and prefix-sum)
  // ─────────────────────────────────────────────────────────────────────────────
  const gridBuildPass = commandEncoder.beginComputePass({
    label: 'Grid Build Compute Pass',
  });

  // Pass 1: Bin Count
  gridBuildPass.setPipeline(pipelines.binCount);
  gridBuildPass.setBindGroup(0, bindGroups.binCount);
  gridBuildPass.dispatchWorkgroups(particleWorkgroups);

  // Pass 2: Prefix Sum
  gridBuildPass.setPipeline(pipelines.prefixSum);
  gridBuildPass.setBindGroup(0, bindGroups.prefixSum);
  gridBuildPass.dispatchWorkgroups(1); // Single workgroup for scan

  gridBuildPass.end();

  // ─────────────────────────────────────────────────────────────────────────────
  // Buffer Copy: Initialize fillPointers from gridOffsets
  // ─────────────────────────────────────────────────────────────────────────────
  // Bin-scatter atomically increments fillPointers[cell] to allocate write slots.
  // We initialize it with cell start offsets so the first particle in each cell
  // writes to the correct position.
  const fillPointerBytes = numCells * 4; // uint32 per cell
  commandEncoder.copyBufferToBuffer(
    buffers.gridOffsets, 0,
    buffers.fillPointers, 0,
    fillPointerBytes
  );

  // ─────────────────────────────────────────────────────────────────────────────
  // Compute Pass 2: Physics (bin-scatter, forces, integration)
  // ─────────────────────────────────────────────────────────────────────────────
  const physicsPass = commandEncoder.beginComputePass({
    label: 'Physics Compute Pass',
  });

  // Pass 3: Bin Scatter
  physicsPass.setPipeline(pipelines.binScatter);
  physicsPass.setBindGroup(0, bindGroups.binScatter);
  physicsPass.dispatchWorkgroups(particleWorkgroups);

  // Pass 4: Forces
  physicsPass.setPipeline(pipelines.forces);
  physicsPass.setBindGroup(0, bindGroups.forces);
  physicsPass.dispatchWorkgroups(particleWorkgroups);

  // Pass 4b: Density
  physicsPass.setPipeline(pipelines.density);
  physicsPass.setBindGroup(0, bindGroups.density);
  physicsPass.dispatchWorkgroups(particleWorkgroups);

  // Pass 5: Integration
  physicsPass.setPipeline(pipelines.integrate);
  physicsPass.setBindGroup(0, bindGroups.integrate);
  physicsPass.dispatchWorkgroups(particleWorkgroups);

  physicsPass.end();

  // ═════════════════════════════════════════════════════════════════════════
  // PHASE: GPU→CPU READBACK
  // ═════════════════════════════════════════════════════════════════════════
  // Precondition: Compute passes encoded
  // Postcondition: Results copied to SharedArrayBuffer for WebGL renderer

  // Determine which buffers to copy based on parity (integration writes to active buffers)
  const pxGPU = parity === 0 ? buffers.pxA : buffers.pxB;
  const pyGPU = parity === 0 ? buffers.pyA : buffers.pyB;
  const vxGPU = parity === 0 ? buffers.vxA : buffers.vxB;
  const vyGPU = parity === 0 ? buffers.vyA : buffers.vyB;
  const denGPU = parity === 0 ? buffers.denA : buffers.denB;
  const speciesGPU = parity === 0 ? buffers.speciesA : buffers.speciesB;

  // Import SharedArrayBuffer views for CPU-side update
  const { pxA, pyA, vxA, vyA, denA, speciesA, pxB, pyB, vxB, vyB, denB, speciesB } = await import(
    './buffers.js'
  );
  const pxCPU = parity === 0 ? pxA : pxB;
  const pyCPU = parity === 0 ? pyA : pyB;
  const vxCPU = parity === 0 ? vxA : vxB;
  const vyCPU = parity === 0 ? vyA : vyB;
  const denCPU = parity === 0 ? denA : denB;
  const speciesCPU = parity === 0 ? speciesA : speciesB;

  // Create staging buffers for readback (these are mapped on first creation)
  // Note: Staging buffers are created per-frame for simplicity. For production,
  // these should be cached and reused to avoid allocation overhead.
  const bytesPerParticle = particleCount * 4; // float32 = 4 bytes

  const stagingPx = device.createBuffer({
    size: bytesPerParticle,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    label: 'Staging Buffer (px)',
  });

  const stagingPy = device.createBuffer({
    size: bytesPerParticle,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    label: 'Staging Buffer (py)',
  });

  const stagingVx = device.createBuffer({
    size: bytesPerParticle,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    label: 'Staging Buffer (vx)',
  });

  const stagingVy = device.createBuffer({
    size: bytesPerParticle,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    label: 'Staging Buffer (vy)',
  });

  const stagingDen = device.createBuffer({
    size: bytesPerParticle,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    label: 'Staging Buffer (den)',
  });

  // Species staging buffer (u32 on GPU, will convert to u8 on CPU)
  const stagingSpecies = device.createBuffer({
    size: bytesPerParticle,  // u32 = 4 bytes per particle
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
    label: 'Staging Buffer (species)',
  });

  // Encode copy commands (GPU → staging buffers)
  commandEncoder.copyBufferToBuffer(pxGPU, 0, stagingPx, 0, bytesPerParticle);
  commandEncoder.copyBufferToBuffer(pyGPU, 0, stagingPy, 0, bytesPerParticle);
  commandEncoder.copyBufferToBuffer(vxGPU, 0, stagingVx, 0, bytesPerParticle);
  commandEncoder.copyBufferToBuffer(vyGPU, 0, stagingVy, 0, bytesPerParticle);
  commandEncoder.copyBufferToBuffer(denGPU, 0, stagingDen, 0, bytesPerParticle);
  commandEncoder.copyBufferToBuffer(speciesGPU, 0, stagingSpecies, 0, bytesPerParticle);

  // ─────────────────────────────────────────────────────────────────────────────
  // Submit work
  // ─────────────────────────────────────────────────────────────────────────────

  const commandBuffer = commandEncoder.finish();
  queue.submit([commandBuffer]);

  // Wait for GPU work to complete
  await queue.onSubmittedWorkDone();

  // Map staging buffers and copy to SharedArrayBuffer
  await stagingPx.mapAsync(GPUMapMode.READ);
  await stagingPy.mapAsync(GPUMapMode.READ);
  await stagingVx.mapAsync(GPUMapMode.READ);
  await stagingVy.mapAsync(GPUMapMode.READ);
  await stagingDen.mapAsync(GPUMapMode.READ);
  await stagingSpecies.mapAsync(GPUMapMode.READ);

  const pxMapped = new Float32Array(stagingPx.getMappedRange());
  const pyMapped = new Float32Array(stagingPy.getMappedRange());
  const vxMapped = new Float32Array(stagingVx.getMappedRange());
  const vyMapped = new Float32Array(stagingVy.getMappedRange());
  const denMapped = new Float32Array(stagingDen.getMappedRange());
  const speciesMapped = new Uint32Array(stagingSpecies.getMappedRange());  // GPU uses u32

  pxCPU.set(pxMapped.subarray(0, particleCount));
  pyCPU.set(pyMapped.subarray(0, particleCount));
  vxCPU.set(vxMapped.subarray(0, particleCount));
  vyCPU.set(vyMapped.subarray(0, particleCount));
  denCPU.set(denMapped.subarray(0, particleCount));
  // Convert species from u32 (GPU) to u8 (CPU SharedArrayBuffer)
  for (let i = 0; i < particleCount; i++) {
    speciesCPU[i] = speciesMapped[i];
  }

  stagingPx.unmap();
  stagingPy.unmap();
  stagingVx.unmap();
  stagingVy.unmap();
  stagingDen.unmap();
  stagingSpecies.unmap();

  // Destroy staging buffers (will be recreated next frame)
  stagingPx.destroy();
  stagingPy.destroy();
  stagingVx.destroy();
  stagingVy.destroy();
  stagingDen.destroy();
  stagingSpecies.destroy();
}

// ═══════════════════════════════════════════════════════════════════════════════
// INITIAL DATA UPLOAD
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Upload initial particle data from SharedArrayBuffer to GPU buffers.
 * Call this once after pipeline initialization and particle initialization.
 *
 * @param {number} particleCount - Number of active particles
 */
export async function uploadInitialData(particleCount) {
  if (!device || !queue) {
    console.error('Cannot upload initial data: WebGPU device not initialized');
    return { success: false, error: 'Device not initialized' };
  }

  try {
    // Import SharedArrayBuffer views
    const { pxA, pyA, vxA, vyA, speciesA, denA, pxB, pyB, vxB, vyB, speciesB, denB, matrix } =
      await import('./buffers.js');

    const bytesPerParticle = particleCount * 4; // float32 = 4 bytes

    // Convert species from uint8 to uint32 (WGSL requires u32 for storage buffers)
    const speciesA_u32 = new Uint32Array(particleCount);
    const speciesB_u32 = new Uint32Array(particleCount);
    for (let i = 0; i < particleCount; i++) {
      speciesA_u32[i] = speciesA[i];
      speciesB_u32[i] = speciesB[i];
    }

    // Upload A set (active buffer at startup)
    // CRITICAL: Use byteOffset - typed arrays are views at non-zero offsets into SharedArrayBuffer
    queue.writeBuffer(buffers.pxA, 0, pxA.buffer, pxA.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.pyA, 0, pyA.buffer, pyA.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.vxA, 0, vxA.buffer, vxA.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.vyA, 0, vyA.buffer, vyA.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.speciesA, 0, speciesA_u32);
    queue.writeBuffer(buffers.denA, 0, denA.buffer, denA.byteOffset, bytesPerParticle);

    // Upload B set (inactive at startup, but initialize anyway for consistency)
    queue.writeBuffer(buffers.pxB, 0, pxB.buffer, pxB.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.pyB, 0, pyB.buffer, pyB.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.vxB, 0, vxB.buffer, vxB.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.vyB, 0, vyB.buffer, vyB.byteOffset, bytesPerParticle);
    queue.writeBuffer(buffers.speciesB, 0, speciesB_u32);
    queue.writeBuffer(buffers.denB, 0, denB.buffer, denB.byteOffset, bytesPerParticle);

    // Upload attraction matrix (constant data)
    queue.writeBuffer(buffers.matrix, 0, matrix.buffer, matrix.byteOffset, matrix.byteLength);

    console.log(`Uploaded ${particleCount} particles to GPU (${bytesPerParticle * 12 + matrix.byteLength} bytes)`);

    return { success: true };
  } catch (error) {
    console.error('Failed to upload initial data:', error);
    return { success: false, error: error.message };
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════════════════════

export { isPipelineReady };
