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

import std/unittest
import ../src/shader_config

const SHADER_CONFIG_TESTS_LOADED* = true

const knownShaders = [
  "bin-count", "bin-scatter", "forces", "integrate",
  "prefix-sum-local", "prefix-sum-blocks", "prefix-sum-final",
  "cell-stats", "render",
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
