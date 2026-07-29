# ==============================================================================
# PARTICLE GARDEN - SHADER CONFIG TESTS
# ==============================================================================
#
# Behavioral tests for the shader configuration accessors. tools/wgsl_bundle.nim
# feeds these values into WGSL placeholder substitution, so a bad lookup silently
# misconfigures the GPU (wrong workgroup size, or a zero tunable that divides by
# zero in atomic accumulation). Tests run against the default activeConfig.
#
# Run with: just test
#
# ==============================================================================

import std/[math, strutils, tables, unittest]
import ../src/shader_config
import ../src/sph_core
import ../src/field_core
import ../src/bloom_core

const SHADER_CONFIG_TESTS_LOADED* = true

const knownShaders = [
  "bin-count", "bin-scatter", "forces", "integrate",
  "prefix-sum-local", "prefix-sum-blocks", "prefix-sum-final",
  # RD per-particle passes dispatch dsParticleWorkgroups, so their 1D workgroup
  # size follows the same warp-multiple contract as the particle passes.
  "field-deposit", "field-force",
]

suite "Workgroup Sizes Are Valid GPU Dispatch Sizes":
  test "getWorkgroupSize returns a positive multiple of 32 for every known shader":
    # CONTRACT: GPU workgroup sizes must be positive and a multiple of the warp/
    # wavefront granularity (32) to dispatch efficiently and correctly.
    for name in knownShaders:
      let size = getWorkgroupSize(name)
      check size > 0
      check size mod 32 == 0

  test "getWorkgroupSize falls back to the safe default 128 for an unknown shader":
    check getWorkgroupSize("no-such-shader") == 128


suite "Tunable Constants Stay In Physical Range":
  test "getTunableFloat returns a positive fixed-point scale":
    # WHY: fixedPointScale is the divisor for atomic accumulation; a zero here
    # would divide by zero when decoding accumulated forces.
    check getTunableFloat("FIXED_POINT_SCALE") > 0.0

  test "getTunableFloat returns non-negative values for every known constant":
    for name in ["MIN_DISTANCE_SQ", "MOUSE_RANGE_SQ", "BLAST_RANGE_SQ",
                 "DENSITY_SMOOTH_FACTOR", "FIXED_POINT_SCALE"]:
      check getTunableFloat(name) >= 0.0

  test "the emitted fixed-point reciprocal inverts the emitted scale":
    # fixed_point.wgsl declares both FIXED_POINT_SCALE and its reciprocal, and
    # multiplies by the latter to decode accumulated forces. Deriving the
    # reciprocal from the scale is the whole point: the two were independent
    # hand-written literals before, free to drift apart silently.
    let placeholders = getPlaceholderMap()
    let scale = parseFloat(placeholders["TUNABLE_FIXED_POINT_SCALE"])
    let inverse = parseFloat(placeholders["TUNABLE_INV_FIXED_POINT_SCALE"])
    check abs(scale * inverse - 1.0) < 1e-9

  test "getTunableFloat returns 0.0 for an unknown constant name":
    # Documents the fall-through: an unknown name yields 0.0, which callers must
    # not feed into a division. Pinned so the fall-through cannot change silently.
    check getTunableFloat("NOT_A_REAL_CONSTANT") == 0.0


const glowTunables = [
  ## The glow curve constants glow.wgsl consumes as {{TUNABLE_GLOW_*}}
  ## placeholders, with the defaults that reproduce the shader's former
  ## hard-coded values (glow.wgsl's retired const block).
  ("GLOW_VELOCITY_LOG_SCALE", 5.0),
  ("GLOW_VELOCITY_BASE", 0.5),
  ("GLOW_DENSITY_SCALE", 0.15),
  ("GLOW_DENSITY_MIN", 0.05),
  ("GLOW_DENSITY_MAX", 1.0),
  ("GLOW_DIVISOR", 24.0),
  ("GLOW_WARMTH_GREEN", 0.3),
  ("GLOW_WARMTH_BLUE", 0.6),
]

suite "Glow Tunables Feed The Bundler":
  test "getTunableFloat resolves every glow curve constant to its appearance-preserving default":
    # CONTRACT: these defaults must equal the constants glow.wgsl hard-coded
    # before S1, or the default visuals change silently.
    for (name, expected) in glowTunables:
      check getTunableFloat(name) == expected

  test "getPlaceholderMap emits a WGSL float literal for every TUNABLE_GLOW_ placeholder":
    # WHY: a bare "24" substituted into WGSL where f32 is expected is an
    # abstract-int that can fail type checking; the map must format floats.
    let placeholders = getPlaceholderMap()
    for (name, expected) in glowTunables:
      let placeholderName = "TUNABLE_" & name
      check placeholderName in placeholders
      check "." in placeholders[placeholderName]


suite "SPH Tunables Mirror sph_core's Authoritative Constants":
  # XSPH epsilon has two homes by necessity: sph_core.nim (the native-tested
  # authority) and shader_config's placeholder map (what the bundler
  # substitutes into forces-sph.wgsl). These tests relate the two so they
  # cannot silently disagree — a single source, checked. Gamma needs no such
  # mirror: it reaches the shader through SimParams, written straight from
  # sph_core by webgpu_compute.

  test "getTunableFloat resolves XSPH epsilon to sph_core's value":
    check getTunableFloat("SPH_XSPH_EPSILON") == SPH_XSPH_EPSILON

  test "getTunableFloat resolves the pressure gain and its clamp to sph_core":
    # The stability ceiling stableStiffnessCeiling serves is FITTED against the
    # pressure gain: the boundary moves with the product of gain and stiffness,
    # so a gain changed on one side of the mirror alone leaves the ceiling
    # describing a fluid the shader no longer runs. The clamp joins it because
    # runs driven past the ceiling are where it starts binding.
    check getTunableFloat("SPH_FORCE_SCALE") == SPH_FORCE_SCALE
    check getTunableFloat("SPH_MAX_PRESSURE_ACCEL") == SPH_MAX_PRESSURE_ACCEL

  test "getPlaceholderMap emits a WGSL float literal for every SPH placeholder":
    let placeholders = getPlaceholderMap()
    for placeholderName in ["TUNABLE_SPH_XSPH_EPSILON",
                            "TUNABLE_SPH_MAX_DENSITY_RATIO",
                            "TUNABLE_SPH_FORCE_SCALE",
                            "TUNABLE_SPH_MAX_PRESSURE_ACCEL"]:
      check placeholderName in placeholders
      check "." in placeholders[placeholderName]

  test "the pressure-density ceiling stays above the rest-density floor":
    # forces-sph clamps the Tait input to [restDensity, restDensity * ratio].
    # At a ratio of 1.0 that collapses to exactly restDensity, making
    # Tait(rest, rest) identically zero — the fluid would lose all pressure
    # response and collapse. The ceiling must leave headroom above the floor.
    check getTunableFloat("SPH_MAX_DENSITY_RATIO") > 1.0

  test "the ceiling bounds the gamma-power term to a finite factor":
    # The whole point of the ceiling: (density/rest)^gamma is bounded because
    # density/rest is. Pinned so raising the ratio stays a deliberate act.
    let ratio = getTunableFloat("SPH_MAX_DENSITY_RATIO")
    check pow(ratio, SPH_DEFAULT_GAMMA) < 1000.0


suite "HDR-Bloom Blur Kernel Feeds The Bundler":
  # blur.wgsl declares `array<f32, {{BLOOM_WEIGHT_COUNT}}>({{BLOOM_WEIGHTS}})`.
  # The count must match the number of emitted literals, or the WGSL array
  # constructor is malformed and the shader fails to compile.

  test "getPlaceholderMap exposes the bloom weight count and weight list":
    let placeholders = getPlaceholderMap()
    check "BLOOM_WEIGHT_COUNT" in placeholders
    check "BLOOM_WEIGHTS" in placeholders
    check placeholders["BLOOM_WEIGHT_COUNT"] == $bloomWeightCount()

  test "the emitted weight list has exactly BLOOM_WEIGHT_COUNT f32 literals":
    let placeholders = getPlaceholderMap()
    let literals = placeholders["BLOOM_WEIGHTS"].split(", ")
    check literals.len == bloomWeightCount()
    for literal in literals:
      check "." in literal


suite "Reaction-Diffusion Field Dispatch Divides The Field Evenly":
  # The RD field passes (field-resolve, rd-step) are the only 2D dispatches: a
  # workgroup covers a fieldStepX x fieldStepY tile of the FIELD_W x FIELD_H field.
  # The executor dispatches ceil(FIELD_W / fieldStepX) x ceil(FIELD_H / fieldStepY)
  # groups; these must divide the field exactly, or edge tiles run past the field
  # (guarded in-shader, but wasteful) or leave cells unprocessed.

  test "the 2D field workgroup tile divides FIELD_W x FIELD_H exactly":
    let fieldStepX = getWorkgroupSize("field-step-x")
    let fieldStepY = getWorkgroupSize("field-step-y")
    check fieldStepX > 0
    check fieldStepY > 0
    check FIELD_W mod fieldStepX == 0
    check FIELD_H mod fieldStepY == 0
    # Total invocations per workgroup stays a warp multiple even though each
    # dimension (16) is not, so 2D occupancy matches the 1D passes.
    check (fieldStepX * fieldStepY) mod 32 == 0

  test "getPlaceholderMap exposes the field dimensions and workgroup placeholders":
    let placeholders = getPlaceholderMap()
    for placeholderName in ["FIELD_W", "FIELD_H",
                            "WORKGROUP_SIZE_FIELD_X", "WORKGROUP_SIZE_FIELD_Y",
                            "WORKGROUP_SIZE_FIELD_DEPOSIT", "WORKGROUP_SIZE_FIELD_FORCE"]:
      check placeholderName in placeholders
    # Field dimensions must match field_core's single source of truth.
    check placeholders["FIELD_W"] == $FIELD_W
    check placeholders["FIELD_H"] == $FIELD_H
