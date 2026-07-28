# ==============================================================================
# PARTICLE GARDEN - BLOOM CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/bloom_core.nim: the separable Gaussian blur kernel
# computed in Nim and substituted into blur.wgsl. A bad kernel would blur the
# HDR bloom source with the wrong shape or brightness — visible, but invisible
# to the shader compiler, so it is pinned here.
#
# Run with: just test
#
# ==============================================================================

import std/[unittest, strutils]
import ../src/bloom_core

const BLOOM_CORE_TESTS_LOADED* = true

suite "Gaussian Kernel Is Normalized, Symmetric, And Falls Off From The Centre":
  test "the full kernel sums to ~1 so the blur preserves total brightness":
    let kernel = gaussianKernel1D(BLOOM_BLUR_RADIUS, BLOOM_BLUR_SIGMA)
    var total = 0.0
    for weight in kernel:
      total += weight
    check abs(total - 1.0) < 1e-9

  test "the full kernel has an odd length of 2*radius + 1":
    check gaussianKernel1D(4, 2.0).len == 9
    check gaussianKernel1D(1, 1.0).len == 3

  test "the kernel is symmetric about its centre":
    let kernel = gaussianKernel1D(BLOOM_BLUR_RADIUS, BLOOM_BLUR_SIGMA)
    for offset in 1 .. BLOOM_BLUR_RADIUS:
      check abs(kernel[BLOOM_BLUR_RADIUS + offset] -
               kernel[BLOOM_BLUR_RADIUS - offset]) < 1e-12

  test "weights fall off monotonically as they leave the centre":
    let kernel = gaussianKernel1D(BLOOM_BLUR_RADIUS, BLOOM_BLUR_SIGMA)
    for offset in 1 .. BLOOM_BLUR_RADIUS:
      # Each tap is strictly dimmer than the one nearer the centre.
      check kernel[BLOOM_BLUR_RADIUS + offset] <
            kernel[BLOOM_BLUR_RADIUS + offset - 1]

  test "the centre weight is the single largest tap":
    let kernel = gaussianKernel1D(BLOOM_BLUR_RADIUS, BLOOM_BLUR_SIGMA)
    for index in 0 ..< kernel.len:
      if index != BLOOM_BLUR_RADIUS:
        check kernel[index] < kernel[BLOOM_BLUR_RADIUS]

  test "a larger sigma spreads weight outward (centre tap shrinks)":
    let tight = gaussianKernel1D(BLOOM_BLUR_RADIUS, 1.0)
    let wide = gaussianKernel1D(BLOOM_BLUR_RADIUS, 3.0)
    check wide[BLOOM_BLUR_RADIUS] < tight[BLOOM_BLUR_RADIUS]


suite "Half Kernel Feeds The Separable Shader":
  test "the half kernel is centre + one side, length radius + 1":
    check bloomHalfKernel().len == BLOOM_BLUR_RADIUS + 1
    check bloomWeightCount() == BLOOM_BLUR_RADIUS + 1

  test "centre + twice the sides sums to ~1, the shader's brightness invariant":
    # The shader samples the centre once and each side tap twice (uv +/- off).
    let half = bloomHalfKernel()
    var total = half[0]
    for index in 1 ..< half.len:
      total += 2.0 * half[index]
    check abs(total - 1.0) < 1e-9

  test "the half kernel index 0 is the centre (largest) weight":
    let half = bloomHalfKernel()
    for index in 1 ..< half.len:
      check half[index] < half[0]


suite "WGSL Weight Emission":
  test "bloomWeightsWgsl emits one decimal-point f32 literal per half-kernel tap":
    let emitted = bloomWeightsWgsl()
    let parts = emitted.split(", ")
    check parts.len == bloomWeightCount()
    for part in parts:
      # Every value must carry a decimal point so WGSL types it as f32.
      check "." in part
