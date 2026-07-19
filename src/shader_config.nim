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

    # Glow curve shaping (glow.wgsl). Defaults reproduce the constants the
    # shader hard-coded before they became {{TUNABLE_GLOW_*}} placeholders.
    glowVelocityLogScale*: float ## Log-curve compression of velocity->glow (default 5.0)
    glowVelocityBase*: float     ## Glow floor for stationary particles (default 0.5)
    glowDensityScale*: float     ## Density->glow gain (default 0.15)
    glowDensityMin*: float       ## Sparse-particle glow floor (default 0.05)
    glowDensityMax*: float       ## Density factor ceiling (default 1.0)
    glowDivisor*: float          ## Overall halo intensity divisor (default 24.0)
    glowWarmthGreen*: float      ## Green attenuation per unit warmth (default 0.3)
    glowWarmthBlue*: float       ## Blue attenuation per unit warmth (default 0.6)

    # SPH fluid mode (forces-sph.wgsl). Defaults mirror sph_core's authoritative
    # constants; test_shader_config relates them so there is one source.
    sphXsphEpsilon*: float       ## XSPH velocity-smoothing weight (default 0.5)
    sphGamma*: float             ## Tait equation-of-state exponent (default 7.0)

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
    render: 128,          # Vertex generation
  )

  PRODUCTION_TUNING* = TuningConstants(
    minDistanceSq: 4.0,           # 2px minimum separation
    mouseRangeSq: 90000.0,        # 300px mouse interaction radius
    blastRangeSq: 40000.0,        # 200px blast radius
    densitySmoothFactor: 0.7,     # Smooth density transitions
    fixedPointScale: 65536.0,     # 2^16 for atomic accumulation
    glowVelocityLogScale: 5.0,    # These eight reproduce glow.wgsl's former
    glowVelocityBase: 0.5,        # hard-coded curve constants exactly, so the
    glowDensityScale: 0.15,       # default appearance is unchanged.
    glowDensityMin: 0.05,
    glowDensityMax: 1.0,
    glowDivisor: 24.0,
    glowWarmthGreen: 0.3,
    glowWarmthBlue: 0.6,
    sphXsphEpsilon: 0.5,          # Mirrors sph_core.SPH_XSPH_EPSILON.
    sphGamma: 7.0,                # Mirrors sph_core.SPH_DEFAULT_GAMMA.
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
  of "GLOW_VELOCITY_LOG_SCALE": activeConfig.tuning.glowVelocityLogScale
  of "GLOW_VELOCITY_BASE": activeConfig.tuning.glowVelocityBase
  of "GLOW_DENSITY_SCALE": activeConfig.tuning.glowDensityScale
  of "GLOW_DENSITY_MIN": activeConfig.tuning.glowDensityMin
  of "GLOW_DENSITY_MAX": activeConfig.tuning.glowDensityMax
  of "GLOW_DIVISOR": activeConfig.tuning.glowDivisor
  of "GLOW_WARMTH_GREEN": activeConfig.tuning.glowWarmthGreen
  of "GLOW_WARMTH_BLUE": activeConfig.tuning.glowWarmthBlue
  of "SPH_XSPH_EPSILON": activeConfig.tuning.sphXsphEpsilon
  of "SPH_GAMMA": activeConfig.tuning.sphGamma
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
  result["WORKGROUP_SIZE_RENDER"] = $activeConfig.workgroups.render

  # Tunable constants (formatted as WGSL float literals)
  result["TUNABLE_MIN_DISTANCE_SQ"] = fmt"{activeConfig.tuning.minDistanceSq:.1f}"
  result["TUNABLE_MOUSE_RANGE_SQ"] = fmt"{activeConfig.tuning.mouseRangeSq:.1f}"
  result["TUNABLE_BLAST_RANGE_SQ"] = fmt"{activeConfig.tuning.blastRangeSq:.1f}"
  result["TUNABLE_DENSITY_SMOOTH_FACTOR"] = fmt"{activeConfig.tuning.densitySmoothFactor:.2f}"
  result["TUNABLE_FIXED_POINT_SCALE"] = fmt"{activeConfig.tuning.fixedPointScale:.1f}"

  # Glow curve constants (consumed by glow.wgsl). Two decimal places keep
  # 0.15/0.05 exact while remaining unambiguous WGSL f32 literals.
  result["TUNABLE_GLOW_VELOCITY_LOG_SCALE"] = fmt"{activeConfig.tuning.glowVelocityLogScale:.2f}"
  result["TUNABLE_GLOW_VELOCITY_BASE"] = fmt"{activeConfig.tuning.glowVelocityBase:.2f}"
  result["TUNABLE_GLOW_DENSITY_SCALE"] = fmt"{activeConfig.tuning.glowDensityScale:.2f}"
  result["TUNABLE_GLOW_DENSITY_MIN"] = fmt"{activeConfig.tuning.glowDensityMin:.2f}"
  result["TUNABLE_GLOW_DENSITY_MAX"] = fmt"{activeConfig.tuning.glowDensityMax:.2f}"
  result["TUNABLE_GLOW_DIVISOR"] = fmt"{activeConfig.tuning.glowDivisor:.2f}"
  result["TUNABLE_GLOW_WARMTH_GREEN"] = fmt"{activeConfig.tuning.glowWarmthGreen:.2f}"
  result["TUNABLE_GLOW_WARMTH_BLUE"] = fmt"{activeConfig.tuning.glowWarmthBlue:.2f}"

  # SPH fluid-mode constants (consumed by forces-sph.wgsl).
  result["TUNABLE_SPH_XSPH_EPSILON"] = fmt"{activeConfig.tuning.sphXsphEpsilon:.2f}"
  result["TUNABLE_SPH_GAMMA"] = fmt"{activeConfig.tuning.sphGamma:.2f}"
