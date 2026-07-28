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
    # Reaction-diffusion field passes (S8). The deposit/force passes dispatch
    # per particle (1D, like the physics passes); resolve/rd-step dispatch per
    # field cell (2D), so their workgroup is a fieldStepX x fieldStepY tile.
    fieldDeposit*: int    ## field-deposit.wgsl: particles per workgroup (1D)
    fieldForce*: int      ## field-force.wgsl: particles per workgroup (1D)
    fieldStepX*: int      ## field-resolve.wgsl / rd-step.wgsl: cells per workgroup, X
    fieldStepY*: int      ## field-resolve.wgsl / rd-step.wgsl: cells per workgroup, Y

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

    # SPH fluid mode (forces-sph.wgsl). The default mirrors sph_core's
    # authoritative constant; test_shader_config relates them so there is one
    # source. Gamma reaches the shader through SimParams at runtime instead,
    # written straight from sph_core by webgpu_compute.
    sphXsphEpsilon*: float       ## XSPH velocity-smoothing weight (default 0.5)
    sphMaxDensityRatio*: float   ## Pressure-density ceiling, in multiples of rest (default 2.0)

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
    fieldDeposit: 128,    # Per-particle splat; matches the particle passes' divisor
    fieldForce: 128,      # Per-particle gradient sampling; matches fieldDeposit
    fieldStepX: 16,       # 16x16 = 256 invocations per 2D field tile (warp multiple)
    fieldStepY: 16,       # 512 field dim / 16 = 32 groups per axis (divides exactly)
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
    sphMaxDensityRatio: 2.0,      # Tait is a 7th power: without a ceiling on its
                                  # input, a compressed cluster feeds its own
                                  # pressure spike. 2.0 sits far above settled
                                  # fluid (~1.0) and normal compression (~1.5).
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
  of "field-deposit": activeConfig.workgroups.fieldDeposit
  of "field-force": activeConfig.workgroups.fieldForce
  of "field-step-x": activeConfig.workgroups.fieldStepX
  of "field-step-y": activeConfig.workgroups.fieldStepY
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
  of "SPH_MAX_DENSITY_RATIO": activeConfig.tuning.sphMaxDensityRatio
  else: 0.0

# =============================================================================
# PLACEHOLDER MAP FOR BUNDLER
# =============================================================================
# This generates the substitution map used by tools/wgsl_bundle.nim

import std/[strformat, tables]
# field_core is pure (no FFI); importing it keeps FIELD_W/FIELD_H sourced from
# the single reaction-diffusion authority rather than re-stated here.
import field_core
# bloom_core is pure; it computes the separable Gaussian blur weights so the
# HDR-bloom shader's kernel shape is native-tested, not hand-written in WGSL.
import bloom_core
# colormap_core is pure; it owns the reaction-diffusion field colormap ramp
# coefficients (and the two-tone constants), so colormap.wgsl's ramps are
# native-tested and single-sourced rather than hand-written in WGSL.
import colormap_core
# camera_core is pure; it owns CAMERA_SIZE_FLOOR, the floor the shader's
# apparent-scale mirror must share with the native-tested one. Substituted
# rather than restated so the two cannot drift.
import camera_core
# sph_core is pure; it derives the density accumulator's fixed-point scale from
# the particle budget, so the scale the shader encodes with and the
# native-tested one are one number.
import sph_core
# The particle budget that derivation is taken against.
from memory_layout import MAX_PARTICLES

proc getPlaceholderMap*(): Table[string, string] =
  ## Generate placeholder substitutions for the shader bundler
  result = initTable[string, string]()

  # Workgroup sizes
  result["WORKGROUP_SIZE_BIN_COUNT"] = $activeConfig.workgroups.binCount
  result["WORKGROUP_SIZE_BIN_SCATTER"] = $activeConfig.workgroups.binScatter
  result["WORKGROUP_SIZE_FORCES"] = $activeConfig.workgroups.forces
  # forces-sph dispatches per-particle exactly like forces, and its dispatch
  # divisor is the shared per-particle workgroup size, so it reuses forces'.
  result["WORKGROUP_SIZE_FORCES_SPH"] = $activeConfig.workgroups.forces
  result["WORKGROUP_SIZE_INTEGRATE"] = $activeConfig.workgroups.integrate
  result["WORKGROUP_SIZE_PREFIX_SUM_LOCAL"] = $activeConfig.workgroups.prefixSumLocal
  result["WORKGROUP_SIZE_PREFIX_SUM_BLOCKS"] = $activeConfig.workgroups.prefixSumBlocks
  result["WORKGROUP_SIZE_PREFIX_SUM_FINAL"] = $activeConfig.workgroups.prefixSumFinal

  # Reaction-diffusion field passes. The 1D deposit/force passes resolve their
  # {{WORKGROUP_SIZE}} shortcut through these keys (WORKGROUP_SIZE_FIELD_DEPOSIT /
  # _FIELD_FORCE from the shader filename); the 2D resolve/rd-step passes read
  # the explicit X/Y placeholders since one {{WORKGROUP_SIZE}} cannot carry two
  # dimensions. FIELD_W/FIELD_H come from field_core, the single source of truth.
  result["WORKGROUP_SIZE_FIELD_DEPOSIT"] = $activeConfig.workgroups.fieldDeposit
  result["WORKGROUP_SIZE_FIELD_FORCE"] = $activeConfig.workgroups.fieldForce
  result["WORKGROUP_SIZE_FIELD_X"] = $activeConfig.workgroups.fieldStepX
  result["WORKGROUP_SIZE_FIELD_Y"] = $activeConfig.workgroups.fieldStepY
  result["FIELD_W"] = $FIELD_W
  result["FIELD_H"] = $FIELD_H

  # Field seed geometry (consumed by field-seed.wgsl, which mirrors
  # field_core.rdSeedCell). Sourced from field_core so the natively-tested
  # oracle and the shader cannot be given different blob counts or radii.
  result["RD_SEED_BLOB_COUNT"] = $RD_SEED_BLOB_COUNT
  result["RD_SEED_BLOB_RADIUS"] = fmt"{RD_SEED_BLOB_RADIUS:.1f}"
  result["RD_SEED_CORE_ACTIVATOR"] = fmt"{RD_SEED_CORE_ACTIVATOR:.2f}"
  result["RD_SEED_CORE_INHIBITOR"] = fmt"{RD_SEED_CORE_INHIBITOR:.2f}"

  # Deposit splat kernel (consumed by field-deposit.wgsl, which mirrors
  # field_core.depositSplatWeight). The radius is the measured ignition floor
  # and the normalization is the discrete sum of weights over exactly the cell
  # offsets the shader visits — computing it here rather than in WGSL is what
  # keeps the shader's conservation identical to the tested oracle's, since a
  # continuous-Gaussian approximation would disagree with the discrete sum.
  result["RD_DEPOSIT_CELL_MAX"] = fmt"{RD_DEPOSIT_CELL_MAX:.4f}"
  result["RD_DEPOSIT_FRAME_SCALE"] = fmt"{RD_DEPOSIT_FRAME_SCALE:.6f}"
  result["RD_DEPOSIT_SPLAT_RADIUS"] = fmt"{RD_DEPOSIT_SPLAT_RADIUS:.1f}"
  result["RD_DEPOSIT_SPLAT_EXTENT"] = $int(RD_DEPOSIT_SPLAT_RADIUS)
  result["RD_DEPOSIT_SPLAT_SIGMA"] = fmt"{RD_DEPOSIT_SPLAT_SIGMA:.4f}"
  result["RD_DEPOSIT_SPLAT_NORMALIZATION"] =
    fmt"{depositSplatNormalization(RD_DEPOSIT_SPLAT_RADIUS):.6f}"

  # Tunable constants (formatted as WGSL float literals)
  result["TUNABLE_MIN_DISTANCE_SQ"] = fmt"{activeConfig.tuning.minDistanceSq:.1f}"
  result["TUNABLE_MOUSE_RANGE_SQ"] = fmt"{activeConfig.tuning.mouseRangeSq:.1f}"
  result["TUNABLE_BLAST_RANGE_SQ"] = fmt"{activeConfig.tuning.blastRangeSq:.1f}"
  result["TUNABLE_DENSITY_SMOOTH_FACTOR"] = fmt"{activeConfig.tuning.densitySmoothFactor:.2f}"
  result["TUNABLE_FIXED_POINT_SCALE"] = fmt"{activeConfig.tuning.fixedPointScale:.1f}"
  # fixed_point.wgsl multiplies by the reciprocal rather than dividing, so the
  # bundler emits it too. Deriving it here is what keeps the pair consistent:
  # a hand-written inverse can drift from the scale it is supposed to invert.
  # Sixteen places render the 2^-16 default exactly.
  result["TUNABLE_INV_FIXED_POINT_SCALE"] =
    fmt"{1.0 / activeConfig.tuning.fixedPointScale:.16f}"

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
  result["TUNABLE_SPH_MAX_DENSITY_RATIO"] = fmt"{activeConfig.tuning.sphMaxDensityRatio:.2f}"
  # The density accumulator's own fixed-point scale, coarser than the shared
  # one so the full particle budget encodes instead of clamping. Derived from
  # MAX_PARTICLES by sph_core, never written as a literal, so raising the
  # particle ceiling carries the encoding with it.
  let sphDensityScale = sphDensityFixedPointScale(MAX_PARTICLES)
  result["SPH_DENSITY_FIXED_POINT_SCALE"] = fmt"{sphDensityScale:.1f}"
  result["SPH_DENSITY_INV_FIXED_POINT_SCALE"] = fmt"{1.0 / sphDensityScale:.16f}"

  # HDR-bloom separable-blur kernel (consumed by blur.wgsl). The half kernel
  # (centre + one side) and its element count come from bloom_core, the single
  # native-tested source of the Gaussian shape.
  result["BLOOM_WEIGHT_COUNT"] = $bloomWeightCount()
  result["BLOOM_WEIGHTS"] = bloomWeightsWgsl()

  # Reaction-diffusion field colormaps (consumed by the colormap.wgsl module).
  # The polynomial ramp coefficients, the two-tone constants, and the field
  # scalar gain all come from colormap_core, the single native-tested authority.
  result["COLORMAP_POLY_TERMS"] = $COLORMAP_POLY_TERMS
  result["COLORMAP_INFERNO_COEFFS"] = colormapCoeffsWgsl(INFERNO_COEFFS)
  result["COLORMAP_VIRIDIS_COEFFS"] = colormapCoeffsWgsl(VIRIDIS_COEFFS)
  result["COLORMAP_FIELD_GAIN"] = wgslScalar(COLORMAP_FIELD_GAIN)
  result["FIELD_LIGHT_STRENGTH"] = wgslScalar(FIELD_LIGHT_STRENGTH)
  result["CAMERA_SIZE_FLOOR"] = wgslScalar(CAMERA_SIZE_FLOOR.float)
  result["COLORMAP_TWO_TONE_WARM"] = wgslVec3(TWO_TONE_WARM)
  result["COLORMAP_TWO_TONE_COOL"] = wgslVec3(TWO_TONE_COOL)
  result["COLORMAP_TWO_TONE_INHIBITOR_GAIN"] = wgslScalar(TWO_TONE_INHIBITOR_GAIN)
  result["COLORMAP_TWO_TONE_COOL_LEVEL"] = wgslScalar(TWO_TONE_COOL_LEVEL)
