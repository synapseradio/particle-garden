# ==============================================================================
# PARTICLE GARDEN - BLOOM CORE (Pure)
# ==============================================================================
#
# The single native-tested source for the separable Gaussian blur kernel and
# the bloom/grade default values. Pure (no FFI, no DOM): compiles on both the
# native (nimble test) and JS backends.
#
# Two consumers, mirroring the field_core precedent:
#   - shader_config.nim substitutes the kernel weights into blur.wgsl as
#     {{BLOOM_WEIGHTS}} / {{BLOOM_WEIGHT_COUNT}} placeholders. The weights are
#     computed HERE, in Nim, so the falloff shape is natively testable rather
#     than hand-written in WGSL (a user-accepted design decision).
#   - ui/state/render_state.nim and config_ranges.nim read the BLOOM_DEFAULT_*
#     constants below, the same way they read field_core's RD_DEFAULT_*.
#
# The blur is symmetric and separable: the shader samples the centre tap once
# and each side tap twice (uv +/- offset), so it needs only the HALF kernel
# (centre + one side), length radius + 1. The full 2*radius+1 kernel is
# normalized to sum 1, which makes the half kernel satisfy
# centre + 2*sum(sides) == 1 — the invariant the shader relies on to preserve
# total brightness.
#
# ==============================================================================

import std/[math, strutils]

const
  BLOOM_BLUR_RADIUS* = 4
    ## Taps per side in each separable blur pass. The WGSL kernel array is
    ## BLOOM_BLUR_RADIUS + 1 long (centre + one side).
  BLOOM_BLUR_SIGMA* = 2.0
    ## Standard deviation of the Gaussian, in half-resolution texels.

  # Bloom + colour-grade defaults. Homed here (a pure leaf) so render_state.nim
  # can seed them into the authoritative RenderState and config_ranges.nim can
  # static-assert them in range — exactly the field_core RD_DEFAULT_* pattern.
  BLOOM_DEFAULT_ENABLED* = false
    ## Bloom is opt-in: the default look is the non-bloom quality floor, so the
    ## default appearance is unchanged from before S9. The toggle turns it on.
  BLOOM_DEFAULT_INTENSITY* = 1.0
  BLOOM_DEFAULT_EXPOSURE* = 1.0
  BLOOM_DEFAULT_SATURATION* = 1.0
  BLOOM_DEFAULT_CONTRAST* = 1.0
  BLOOM_DEFAULT_TEMPERATURE* = 0.0
    ## Signed warm/cool shift; 0 is neutral (no tint).

func gaussianKernel1D*(radius: int, sigma: float): seq[float] =
  ## The full 1-D Gaussian kernel of length 2*radius + 1, normalized so its
  ## elements sum to exactly 1. Symmetric about the centre index `radius`.
  result = newSeq[float](2 * radius + 1)
  let twoSigmaSq = 2.0 * sigma * sigma
  var total = 0.0
  for tap in -radius .. radius:
    let weight = exp(-(tap.float * tap.float) / twoSigmaSq)
    result[tap + radius] = weight
    total += weight
  for index in 0 ..< result.len:
    result[index] = result[index] / total

func bloomHalfKernel*(): seq[float] =
  ## The centre tap plus one side of the module's normalized kernel, length
  ## BLOOM_BLUR_RADIUS + 1. Index 0 is the centre weight; index i is the weight
  ## applied to BOTH the +i and -i taps. Because the full kernel sums to 1,
  ## `result[0] + 2 * sum(result[1..])` == 1.
  let full = gaussianKernel1D(BLOOM_BLUR_RADIUS, BLOOM_BLUR_SIGMA)
  for index in 0 .. BLOOM_BLUR_RADIUS:
    result.add full[BLOOM_BLUR_RADIUS + index]

func bloomWeightCount*(): int =
  ## Length of the half kernel — the WGSL `array<f32, N>` element count.
  BLOOM_BLUR_RADIUS + 1

func bloomWeightsWgsl*(): string =
  ## The half kernel as a comma-separated list of WGSL f32 literals, ready to
  ## paste inside `array<f32, N>( ... )`. Each value carries a decimal point so
  ## it types as f32, never abstract-int.
  var parts: seq[string]
  for weight in bloomHalfKernel():
    parts.add formatFloat(weight, ffDecimal, 8)
  parts.join(", ")
