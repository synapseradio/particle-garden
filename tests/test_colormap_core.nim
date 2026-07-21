# ==============================================================================
# PARTICLE GARDEN - COLORMAP CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/colormap_core.nim: the reaction-diffusion field
# colormaps and the polynomial ramp coefficients substituted into
# web/shaders/modules/colormap.wgsl. A bad ramp would recolour the whole RD
# field — visible, but invisible to the shader compiler, so it is pinned here.
#
# Run with: nimble test
#
# ==============================================================================

import std/[unittest, strutils]
import ../src/colormap_core

const COLORMAP_CORE_TESTS_LOADED* = true

func luminance(color: array[3, float]): float =
  color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722

suite "Perceptual Ramps Run Dark-To-Bright With Their Signature End Colours":
  test "inferno starts near black":
    let low = evalInferno(0.0)
    for channel in low:
      check channel < 0.05

  test "inferno ends bright warm yellow (red and green high, blue lower)":
    let high = evalInferno(1.0)
    check high[0] > 0.9   # red
    check high[1] > 0.9   # green
    check high[2] < 0.75  # blue stays below the warm channels

  test "viridis starts dark purple (blue present, green near zero)":
    let low = evalViridis(0.0)
    check low[2] > 0.2       # blue
    check low[1] < 0.05      # green nearly absent at the dark end
    check luminance(low) < 0.2

  test "viridis ends yellow (red and green high, blue low)":
    let high = evalViridis(1.0)
    check high[0] > 0.9
    check high[1] > 0.8
    check high[2] < 0.3

  test "both ramps grow strictly brighter from 0 to 1":
    check luminance(evalInferno(1.0)) > luminance(evalInferno(0.0))
    check luminance(evalViridis(1.0)) > luminance(evalViridis(0.0))

  test "ramp output is always clamped into the unit cube":
    for step in 0 .. 20:
      let rampT = step.float / 20.0
      for channel in evalInferno(rampT):
        check channel >= 0.0 and channel <= 1.0
      for channel in evalViridis(rampT):
        check channel >= 0.0 and channel <= 1.0


suite "Field Scalar Maps The Inhibitor Channel Into The Ramp Domain":
  test "fieldScalar clamps into [0, 1]":
    check fieldScalar(-1.0) == 0.0
    check fieldScalar(0.0) == 0.0
    check fieldScalar(10.0) == 1.0

  test "fieldScalar rises with the inhibitor concentration below saturation":
    # COLORMAP_FIELD_GAIN * 0.1 = 0.3 is still inside [0,1], so it is monotone.
    check fieldScalar(0.05) < fieldScalar(0.1)


suite "Two-Tone Ramp Reads Activator And Inhibitor Distinctly":
  test "inhibitor alone yields a warm colour (red exceeds blue)":
    let warm = evalTwoTone(0.0, 1.0)
    check warm[0] > warm[2]

  test "activator alone yields a cool colour (blue exceeds red)":
    let cool = evalTwoTone(1.0, 0.0)
    check cool[2] > cool[0]

  test "the two channels drive different hues, not the same one":
    let warm = evalTwoTone(0.0, 1.0)
    let cool = evalTwoTone(1.0, 0.0)
    # If the channels were not distinct these would collapse to one hue: the
    # inhibitor drives red hard while the activator flips the red/blue ordering.
    check abs(warm[0] - cool[0]) > 0.3
    check warm[0] > cool[0]   # inhibitor is red-dominant
    check cool[2] > warm[2]   # activator is blue-dominant


suite "Colormap Dispatch Selects By Index With An Inferno Fallback":
  test "each index selects its own ramp":
    let inhibitor = 0.3
    check evalColormap(COLORMAP_INDEX_INFERNO, 1.0, inhibitor) ==
      evalInferno(fieldScalar(inhibitor))
    check evalColormap(COLORMAP_INDEX_VIRIDIS, 1.0, inhibitor) ==
      evalViridis(fieldScalar(inhibitor))
    check evalColormap(COLORMAP_INDEX_TWO_TONE, 1.0, inhibitor) ==
      evalTwoTone(1.0, inhibitor)

  test "an out-of-range index falls back to inferno (matches the shader)":
    check evalColormap(99, 1.0, 0.3) == evalInferno(fieldScalar(0.3))
    check evalColormap(-1, 1.0, 0.3) == evalInferno(fieldScalar(0.3))


suite "Defaults Are Consistent And In Range":
  test "there are three colormaps and the default index is one of them":
    check COLORMAP_COUNT == 3
    check COLORMAP_DEFAULT_INDEX >= 0
    check COLORMAP_DEFAULT_INDEX < COLORMAP_COUNT

  test "the default field opacity sits inside its own range":
    check FIELD_OPACITY_DEFAULT >= FIELD_OPACITY_MIN
    check FIELD_OPACITY_DEFAULT <= FIELD_OPACITY_MAX


suite "WGSL Coefficient Emission":
  test "colormapCoeffsWgsl emits one vec3f literal per Horner term":
    let emitted = colormapCoeffsWgsl(INFERNO_COEFFS)
    check emitted.count("vec3f(") == COLORMAP_POLY_TERMS

  test "every emitted component carries a decimal point or exponent (f32-typed)":
    let emitted = colormapCoeffsWgsl(VIRIDIS_COEFFS)
    let inner = emitted.replace("vec3f(", "").replace(")", "")
    for token in inner.split(","):
      let value = token.strip()
      check "." in value or "e" in value
