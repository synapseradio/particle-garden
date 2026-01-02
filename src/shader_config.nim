# =============================================================================
# SHADER CONFIGURATION
# =============================================================================
# Centralized configuration for WGSL shader constants and workgroup sizes.
#
# Values here are substituted into shaders via {{PLACEHOLDER}} syntax.
# See tools/wgsl_bundle.nim for the substitution mechanism.
#
# TUNING GUIDE:
# - Workgroup sizes should be multiples of 32 (warp/wavefront size)
# - Larger workgroups = better occupancy but more register pressure
# - Smaller workgroups = more flexible scheduling
# =============================================================================

type
  ShaderProfile* = enum
    ## Build profile affecting shader configuration
    spProduction    ## Validated defaults
    spDevelopment   ## Debug-friendly, may enable additional checks

  WorkgroupConfig* = object
    ## Workgroup sizes for each compute shader.
    ## Must match the @workgroup_size() directive in WGSL.
    binCount*: int        ## bin-count.wgsl: particles per workgroup
    binScatter*: int      ## bin-scatter.wgsl: particles per workgroup
    forces*: int          ## forces.wgsl: particles per workgroup
    integrate*: int       ## integrate.wgsl: particles per workgroup
    prefixSumLocal*: int  ## prefix-sum-local.wgsl: cells per workgroup (must match BLOCK_SIZE)
    prefixSumBlocks*: int ## prefix-sum-blocks.wgsl: blocks per workgroup
    prefixSumFinal*: int  ## prefix-sum-final.wgsl: cells per workgroup
    cellStats*: int       ## cell-stats.wgsl: threads per cell
    render*: int          ## render.wgsl: vertices per workgroup

  TuningConstants* = object
    ## Physics and rendering constants that can be tuned without shader edits.
    ## These become {{TUNABLE_*}} placeholders in WGSL.

    # Force calculation
    minDistanceSq*: float     ## Minimum distance squared to prevent div/zero (default 4.0)
    mouseRangeSq*: float      ## Mouse interaction radius squared (default 90000.0 = 300px)
    blastRangeSq*: float      ## Blast effect radius squared (default 40000.0 = 200px)

    # Density estimation
    densitySmoothFactor*: float  ## Smoothing for density updates (default 0.7)

    # Fixed-point arithmetic (DO NOT CHANGE unless you know what you're doing)
    fixedPointScale*: float      ## Scale for atomic float accumulation (default 65536.0 = 2^16)

  ShaderConfig* = object
    ## Complete shader configuration
    profile*: ShaderProfile
    workgroups*: WorkgroupConfig
    tuning*: TuningConstants

const
  # ==========================================================================
  # PRODUCTION CONFIGURATION
  # ==========================================================================
  # These are validated defaults that work across most GPUs.

  PRODUCTION_WORKGROUPS* = WorkgroupConfig(
    binCount: 128,        # Good balance for particle binning
    binScatter: 128,      # Matches binCount for consistency
    forces: 128,          # Main physics loop - optimized for memory coalescing
    integrate: 128,       # Velocity integration
    prefixSumLocal: 256,  # Must match BLOCK_SIZE in shader
    prefixSumBlocks: 256, # Single workgroup processes all blocks
    prefixSumFinal: 256,  # Matches local for consistency
    cellStats: 64,        # Per-cell statistics (smaller due to shared memory)
    render: 128,          # Vertex generation
  )

  PRODUCTION_TUNING* = TuningConstants(
    minDistanceSq: 4.0,           # 2px minimum separation
    mouseRangeSq: 90000.0,        # 300px mouse interaction radius
    blastRangeSq: 40000.0,        # 200px blast radius
    densitySmoothFactor: 0.7,     # Smooth density transitions
    fixedPointScale: 65536.0,     # 2^16 for atomic accumulation
  )

  PRODUCTION_CONFIG* = ShaderConfig(
    profile: spProduction,
    workgroups: PRODUCTION_WORKGROUPS,
    tuning: PRODUCTION_TUNING,
  )

# Current active configuration (can be modified for development)
var activeConfig* = PRODUCTION_CONFIG

# =============================================================================
# CONFIGURATION ACCESSORS
# =============================================================================

proc getWorkgroupSize*(name: string): int =
  ## Get workgroup size by shader name
  case name
  of "bin-count": activeConfig.workgroups.binCount
  of "bin-scatter": activeConfig.workgroups.binScatter
  of "forces": activeConfig.workgroups.forces
  of "integrate": activeConfig.workgroups.integrate
  of "prefix-sum-local": activeConfig.workgroups.prefixSumLocal
  of "prefix-sum-blocks": activeConfig.workgroups.prefixSumBlocks
  of "prefix-sum-final": activeConfig.workgroups.prefixSumFinal
  of "cell-stats": activeConfig.workgroups.cellStats
  of "render": activeConfig.workgroups.render
  else: 128  # Safe default

proc getTunableFloat*(name: string): float =
  ## Get tunable constant by name
  case name
  of "MIN_DISTANCE_SQ": activeConfig.tuning.minDistanceSq
  of "MOUSE_RANGE_SQ": activeConfig.tuning.mouseRangeSq
  of "BLAST_RANGE_SQ": activeConfig.tuning.blastRangeSq
  of "DENSITY_SMOOTH_FACTOR": activeConfig.tuning.densitySmoothFactor
  of "FIXED_POINT_SCALE": activeConfig.tuning.fixedPointScale
  else: 0.0

# =============================================================================
# PLACEHOLDER MAP FOR BUNDLER
# =============================================================================
# This generates the substitution map used by tools/wgsl_bundle.nim

import std/[strformat, tables]

proc getPlaceholderMap*(): Table[string, string] =
  ## Generate placeholder substitutions for the shader bundler
  result = initTable[string, string]()

  # Workgroup sizes
  result["WORKGROUP_SIZE_BIN_COUNT"] = $activeConfig.workgroups.binCount
  result["WORKGROUP_SIZE_BIN_SCATTER"] = $activeConfig.workgroups.binScatter
  result["WORKGROUP_SIZE_FORCES"] = $activeConfig.workgroups.forces
  result["WORKGROUP_SIZE_INTEGRATE"] = $activeConfig.workgroups.integrate
  result["WORKGROUP_SIZE_PREFIX_SUM_LOCAL"] = $activeConfig.workgroups.prefixSumLocal
  result["WORKGROUP_SIZE_PREFIX_SUM_BLOCKS"] = $activeConfig.workgroups.prefixSumBlocks
  result["WORKGROUP_SIZE_PREFIX_SUM_FINAL"] = $activeConfig.workgroups.prefixSumFinal
  result["WORKGROUP_SIZE_CELL_STATS"] = $activeConfig.workgroups.cellStats
  result["WORKGROUP_SIZE_RENDER"] = $activeConfig.workgroups.render

  # Tunable constants (formatted as WGSL float literals)
  result["TUNABLE_MIN_DISTANCE_SQ"] = fmt"{activeConfig.tuning.minDistanceSq:.1f}"
  result["TUNABLE_MOUSE_RANGE_SQ"] = fmt"{activeConfig.tuning.mouseRangeSq:.1f}"
  result["TUNABLE_BLAST_RANGE_SQ"] = fmt"{activeConfig.tuning.blastRangeSq:.1f}"
  result["TUNABLE_DENSITY_SMOOTH_FACTOR"] = fmt"{activeConfig.tuning.densitySmoothFactor:.2f}"
  result["TUNABLE_FIXED_POINT_SCALE"] = fmt"{activeConfig.tuning.fixedPointScale:.1f}"
