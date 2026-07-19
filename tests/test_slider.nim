# ==============================================================================
# PARTICLE GARDEN - SLIDER TESTS
# ==============================================================================
#
# Unit tests for slider component and state modules.
# Tests pure logic without DOM.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/ui/controls/slider
import ../src/ui/state/simulation_state
import ../src/ui/state/render_state
import ../src/memory_layout  # MAX_PARTICLES / MAX_SPECIES for default-validity checks

# Exported symbol for test_all.nim to reference
const SLIDER_TESTS_LOADED* = true

# ==============================================================================
# SLIDER VALUE TESTS
# ==============================================================================

suite "SliderValue - Construction":
  test "intValue creates integer value":
    let value = intValue(42)
    check value.kind == svkInt
    check value.intVal == 42

  test "floatValue creates float value":
    let value = floatValue(3.14)
    check value.kind == svkFloat
    check abs(value.floatVal - 3.14) < 0.001

  test "toFloat converts int to float":
    let value = intValue(10)
    check abs(value.toFloat() - 10.0) < 0.001

  test "toFloat preserves float":
    let value = floatValue(2.5)
    check abs(value.toFloat() - 2.5) < 0.001

  test "toInt converts float to int":
    let value = floatValue(7.9)
    check value.toInt() == 7  # Truncates

  test "toInt preserves int":
    let value = intValue(25)
    check value.toInt() == 25


suite "SliderConfig - Creation":
  test "initSliderConfig with defaults":
    let config = initSliderConfig(
      "input1", "display1",
      svkFloat
    )
    check config.inputId == "input1"
    check config.displayId == "display1"
    check config.valueKind == svkFloat
    check config.precision == 0
    check config.minValue == 0.0
    check config.maxValue == 100.0

  test "initSliderConfig with custom values":
    let config = initSliderConfig(
      "slider", "value",
      svkInt,
      precision = 2,
      minValue = 10.0,
      maxValue = 500.0
    )
    check config.precision == 2
    check config.minValue == 10.0
    check config.maxValue == 500.0


suite "SliderValue - Parsing":
  test "parseSliderValue int":
    let value = parseSliderValue("42", svkInt)
    check value.kind == svkInt
    check value.intVal == 42

  test "parseSliderValue float":
    let value = parseSliderValue("3.14", svkFloat)
    check value.kind == svkFloat
    check abs(value.floatVal - 3.14) < 0.001

  test "parseSliderValue int invalid returns 0":
    let value = parseSliderValue("not a number", svkInt)
    check value.intVal == 0

  test "parseSliderValue float invalid returns 0.0":
    let value = parseSliderValue("abc", svkFloat)
    check value.floatVal == 0.0

  test "parseSliderValue empty string":
    let vi = parseSliderValue("", svkInt)
    let vf = parseSliderValue("", svkFloat)
    check vi.intVal == 0
    check vf.floatVal == 0.0


suite "SliderValue - Clamping":
  test "clampValue within range unchanged":
    let config = initSliderConfig("a", "b", svkInt, minValue = 0, maxValue = 100)
    let value = clampValue(intValue(50), config)
    check value.intVal == 50

  test "clampValue below min":
    let config = initSliderConfig("a", "b", svkInt, minValue = 10, maxValue = 100)
    let value = clampValue(intValue(5), config)
    check value.intVal == 10

  test "clampValue above max":
    let config = initSliderConfig("a", "b", svkFloat, minValue = 0, maxValue = 1.0)
    let value = clampValue(floatValue(1.5), config)
    check abs(value.floatVal - 1.0) < 0.001

  test "clampValue at boundary":
    let config = initSliderConfig("a", "b", svkInt, minValue = 0, maxValue = 100)
    let vMin = clampValue(intValue(0), config)
    let vMax = clampValue(intValue(100), config)
    check vMin.intVal == 0
    check vMax.intVal == 100


suite "SliderValue - Formatting":
  test "formatValue int":
    let value = intValue(1234)
    check formatValue(value, 0) == "1234"

  test "formatValue float no decimals":
    let value = floatValue(42.7)
    check formatValue(value, 0) == "42"

  test "formatValue float one decimal":
    let value = floatValue(3.14159)
    check formatValue(value, 1) == "3.1"

  test "formatValue float two decimals":
    let value = floatValue(0.956)
    check formatValue(value, 2) == "0.96"

  test "formatSliderValue uses config precision":
    let config = initSliderConfig("a", "b", svkFloat, precision = 2)
    let value = floatValue(1.2345)
    check formatSliderValue(value, config) == "1.23"


suite "Slider - Basic Operations":
  test "newIntSlider creates slider":
    let slider = newIntSlider("in", "out", 50, minValue = 0, maxValue = 100)
    check slider.getInt() == 50
    check slider.config.valueKind == svkInt

  test "newFloatSlider creates slider":
    let slider = newFloatSlider("in", "out", 0.75, precision = 2)
    check abs(slider.getFloat() - 0.75) < 0.001
    check slider.config.precision == 2

  test "setInt updates value":
    let slider = newIntSlider("in", "out", 10)
    slider.setInt(20)
    check slider.getInt() == 20

  test "setFloat updates value":
    let slider = newFloatSlider("in", "out", 0.5)
    slider.setFloat(0.8)
    check abs(slider.getFloat() - 0.8) < 0.001

  test "setValue clamps to range":
    let slider = newIntSlider("in", "out", 50, minValue = 0, maxValue = 100)
    slider.setInt(200)
    check slider.getInt() == 100
    slider.setInt(-50)
    check slider.getInt() == 0

  test "getDisplayText formats correctly":
    let slider = newFloatSlider("in", "out", 1.234, precision = 2)
    check slider.getDisplayText() == "1.23"


suite "Slider - Callbacks":
  test "onChange called on setValue":
    var callCount = 0
    let slider = newIntSlider("in", "out", 10)
    slider.onChange = proc() = callCount += 1
    slider.setInt(20)
    check callCount == 1

  test "onChange not called when nil":
    let slider = newIntSlider("in", "out", 10)
    # Should not crash
    slider.setInt(20)
    check slider.getInt() == 20


# ==============================================================================
# SIMULATION STATE TESTS
# ==============================================================================

suite "SimulationState - Initialization":
  test "initSimulationState defaults sit within the engine's valid ranges":
    # The exact default values are tunable and deliberately not pinned. What must
    # hold is that the shipped defaults are usable: a particle count above
    # MAX_PARTICLES would overflow the buffers, a species count above MAX_SPECIES
    # would index past the attraction matrix, and the rates must stay sane.
    let state = initSimulationState()
    check state.particleCount > 0
    check state.particleCount <= MAX_PARTICLES
    check state.speciesCount >= 1
    check state.speciesCount <= MAX_SPECIES
    check state.interactionRadius > 0
    check state.forceStrength > 0.0
    check state.friction >= 0.0
    check state.friction < 1.0
    check state.timeScale > 0.0
    check state.maxVelocity > 0.0

  test "field updates on a copied var leave the source untouched":
    # The update idiom the UI uses: copy, mutate the copy, re-set. Value
    # semantics must guarantee the source state is unaffected.
    let original = initSimulationState()
    var updated = original
    updated.particleCount = 5000
    updated.forceStrength = 2.5
    check updated.particleCount == 5000
    check abs(updated.forceStrength - 2.5) < 0.001
    check original.particleCount == initSimulationState().particleCount
    check original.forceStrength == initSimulationState().forceStrength


# ==============================================================================
# RENDER STATE TESTS
# ==============================================================================

suite "RenderState - Initialization":
  test "initRenderState defaults sit within valid display ranges":
    # Exact values are tunable; these bounds are the real contract: a
    # non-positive particle size renders nothing, and glow scales must be
    # non-negative.
    let state = initRenderState()
    check state.particleSize > 0
    check state.trailLength >= 0.0
    check state.glowIntensity >= 0.0
    check state.velocityGlowScale >= 0.0


suite "RenderState - Queries":
  test "hasTrails false by default":
    let state = initRenderState()
    check state.hasTrails() == false

  test "hasTrails true when enabled":
    var state = initRenderState()
    state.trails = true
    check state.hasTrails() == true

  test "hasGlow true when intensity > 0":
    let state = initRenderState()
    check state.hasGlow() == true

  test "hasGlow false when intensity is 0":
    var state = initRenderState()
    state.glowIntensity = 0.0
    check state.hasGlow() == false
