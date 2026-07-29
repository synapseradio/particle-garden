# ==============================================================================
# PARTICLE GARDEN - SLIDER CURVE TESTS (design E5)
# ==============================================================================
#
# The travel curve maps a handle POSITION in [0, 1] to a parameter VALUE and
# back, in Nim, so the panel computes no mapping. These pin the pair as mutual
# inverses on the descriptor's own step lattice, pin cLinear to the mapping
# the panel ran before curves existed, and pin the endpoints and monotonicity
# every curve owes the track.
#
# Run with: just test
#
# ==============================================================================

import std/[math, unittest]

const SLIDER_CURVE_TESTS_LOADED* = true

import ../src/ui/api/param_descriptor
import ../src/ui/api/slider_curve

proc curved(minValue, maxValue: float; precision: int;
    curve: SliderCurve; exponent = 0.0): ParamDescriptor =
  ## A descriptor shaped for curve math alone; everything else is inert.
  ParamDescriptor(id: "probe", label: "Probe", group: "test", kind: pkFloat,
    minValue: minValue, maxValue: maxValue,
    step: pow(10.0, -precision.float), precision: precision,
    defaultValue: minValue, curve: curve, curveExponent: exponent)

suite "The Curve Pair Are Mutual Inverses":
  test "position and value round-trip at the descriptor's precision":
    # Every lattice value comes back exactly from its own position, under
    # every curve the enum offers.
    let shapes = [
      curved(0.0, 3.0, 2, cLinear),
      curved(0.1, 200.0, 1, cLog),
      curved(0.0, 3.0, 2, cPower, 2.0)]
    for descriptor in shapes:
      var value = descriptor.minValue
      while value <= descriptor.maxValue + 1e-9:
        let landed = valueAt(descriptor, positionOf(descriptor, value))
        if abs(landed - value) > descriptor.step / 2.0 + 1e-9:
          checkpoint($descriptor.curve & " loses " & $value & " -> " &
            $landed)
        check abs(landed - value) <= descriptor.step / 2.0 + 1e-9
        value += descriptor.step * 25.0

  test "a linear curve reproduces the current position mapping exactly":
    let descriptor = curved(10.0, 60.0, 1, cLinear)
    check valueAt(descriptor, 0.5) == 35.0
    check positionOf(descriptor, 22.5) == 0.25
    # And against a served bound narrower than the envelope, the same line.
    check valueAt(descriptor, 0.5, boundMax = 30.0) == 20.0
    check positionOf(descriptor, 20.0, boundMax = 30.0) == 0.5

  test "position 0 and 1 map to the range endpoints under every curve":
    let shapes = [
      curved(0.0, 3.0, 2, cLinear),
      curved(0.1, 200.0, 1, cLog),
      curved(0.0, 3.0, 2, cPower, 2.0)]
    for descriptor in shapes:
      check abs(valueAt(descriptor, 0.0) - descriptor.minValue) < 1e-9
      check abs(valueAt(descriptor, 1.0) - descriptor.maxValue) < 1e-9

  test "a curve preserves monotonicity":
    let shapes = [
      curved(0.0, 3.0, 2, cLinear),
      curved(0.1, 200.0, 1, cLog),
      curved(0.0, 3.0, 2, cPower, 2.0)]
    for descriptor in shapes:
      var previous = valueAt(descriptor, 0.0)
      for i in 1 .. 100:
        let next = valueAt(descriptor, i.float / 100.0)
        check next >= previous - 1e-9
        previous = next

  test "positions clamp to the track and values to the served bounds":
    let descriptor = curved(0.0, 3.0, 2, cLinear)
    check valueAt(descriptor, -0.5) == descriptor.minValue
    check valueAt(descriptor, 1.5) == descriptor.maxValue
    check positionOf(descriptor, -1.0) == 0.0
    check positionOf(descriptor, 99.0) == 1.0
