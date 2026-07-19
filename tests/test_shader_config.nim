# ==============================================================================
# PARTICLE GARDEN - SHADER CONFIG TESTS
# ==============================================================================
#
# Behavioral tests for the shader configuration accessors. tools/wgsl_bundle.nim
# feeds these values into WGSL placeholder substitution, so a bad lookup silently
# misconfigures the GPU (wrong workgroup size, or a zero tunable that divides by
# zero in atomic accumulation). Tests run against the default activeConfig.
#
# Run with: nimble test
#
# ==============================================================================

import std/[strutils, tables, unittest]
import ../src/shader_config
import ../src/sph_core

const SHADER_CONFIG_TESTS_LOADED* = true

const knownShaders = [
  "bin-count", "bin-scatter", "forces", "integrate",
  "prefix-sum-local", "prefix-sum-blocks", "prefix-sum-final",
  "render",
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
  # The SPH shader constants have two homes by necessity: sph_core.nim (the
  # native-tested authority) and shader_config's placeholder map (what the
  # bundler substitutes into forces-sph.wgsl). These tests relate the two so
  # they cannot silently disagree — a single source, checked.

  test "getTunableFloat resolves each SPH constant to sph_core's value":
    check getTunableFloat("SPH_XSPH_EPSILON") == SPH_XSPH_EPSILON
    check getTunableFloat("SPH_GAMMA") == SPH_DEFAULT_GAMMA

  test "getPlaceholderMap emits a WGSL float literal for every SPH placeholder":
    let placeholders = getPlaceholderMap()
    for placeholderName in ["TUNABLE_SPH_XSPH_EPSILON", "TUNABLE_SPH_GAMMA"]:
      check placeholderName in placeholders
      check "." in placeholders[placeholderName]
