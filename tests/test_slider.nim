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
    let v = intValue(42)
    check v.kind == svkInt
    check v.intVal == 42

  test "floatValue creates float value":
    let v = floatValue(3.14)
    check v.kind == svkFloat
    check abs(v.floatVal - 3.14) < 0.001

  test "toFloat converts int to float":
    let v = intValue(10)
    check abs(v.toFloat() - 10.0) < 0.001

  test "toFloat preserves float":
    let v = floatValue(2.5)
    check abs(v.toFloat() - 2.5) < 0.001

  test "toInt converts float to int":
    let v = floatValue(7.9)
    check v.toInt() == 7  # Truncates

  test "toInt preserves int":
    let v = intValue(25)
    check v.toInt() == 25


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
    let v = parseSliderValue("42", svkInt)
    check v.kind == svkInt
    check v.intVal == 42

  test "parseSliderValue float":
    let v = parseSliderValue("3.14", svkFloat)
    check v.kind == svkFloat
    check abs(v.floatVal - 3.14) < 0.001

  test "parseSliderValue int invalid returns 0":
    let v = parseSliderValue("not a number", svkInt)
    check v.intVal == 0

  test "parseSliderValue float invalid returns 0.0":
    let v = parseSliderValue("abc", svkFloat)
    check v.floatVal == 0.0

  test "parseSliderValue empty string":
    let vi = parseSliderValue("", svkInt)
    let vf = parseSliderValue("", svkFloat)
    check vi.intVal == 0
    check vf.floatVal == 0.0


suite "SliderValue - Clamping":
  test "clampValue within range unchanged":
    let config = initSliderConfig("a", "b", svkInt, minValue = 0, maxValue = 100)
    let v = clampValue(intValue(50), config)
    check v.intVal == 50

  test "clampValue below min":
    let config = initSliderConfig("a", "b", svkInt, minValue = 10, maxValue = 100)
    let v = clampValue(intValue(5), config)
    check v.intVal == 10

  test "clampValue above max":
    let config = initSliderConfig("a", "b", svkFloat, minValue = 0, maxValue = 1.0)
    let v = clampValue(floatValue(1.5), config)
    check abs(v.floatVal - 1.0) < 0.001

  test "clampValue at boundary":
    let config = initSliderConfig("a", "b", svkInt, minValue = 0, maxValue = 100)
    let vMin = clampValue(intValue(0), config)
    let vMax = clampValue(intValue(100), config)
    check vMin.intVal == 0
    check vMax.intVal == 100


suite "SliderValue - Formatting":
  test "formatValue int":
    let v = intValue(1234)
    check formatValue(v, 0) == "1234"

  test "formatValue float no decimals":
    let v = floatValue(42.7)
    check formatValue(v, 0) == "42"

  test "formatValue float one decimal":
    let v = floatValue(3.14159)
    check formatValue(v, 1) == "3.1"

  test "formatValue float two decimals":
    let v = floatValue(0.956)
    check formatValue(v, 2) == "0.96"

  test "formatSliderValue uses config precision":
    let config = initSliderConfig("a", "b", svkFloat, precision = 2)
    let v = floatValue(1.2345)
    check formatSliderValue(v, config) == "1.23"


suite "Slider - Basic Operations":
  test "newIntSlider creates slider":
    let s = newIntSlider("in", "out", 50, minValue = 0, maxValue = 100)
    check s.getInt() == 50
    check s.config.valueKind == svkInt

  test "newFloatSlider creates slider":
    let s = newFloatSlider("in", "out", 0.75, precision = 2)
    check abs(s.getFloat() - 0.75) < 0.001
    check s.config.precision == 2

  test "setInt updates value":
    let s = newIntSlider("in", "out", 10)
    s.setInt(20)
    check s.getInt() == 20

  test "setFloat updates value":
    let s = newFloatSlider("in", "out", 0.5)
    s.setFloat(0.8)
    check abs(s.getFloat() - 0.8) < 0.001

  test "setValue clamps to range":
    let s = newIntSlider("in", "out", 50, minValue = 0, maxValue = 100)
    s.setInt(200)
    check s.getInt() == 100
    s.setInt(-50)
    check s.getInt() == 0

  test "getDisplayText formats correctly":
    let s = newFloatSlider("in", "out", 1.234, precision = 2)
    check s.getDisplayText() == "1.23"


suite "Slider - Callbacks":
  test "onChange called on setValue":
    var callCount = 0
    let s = newIntSlider("in", "out", 10)
    s.onChange = proc() = callCount += 1
    s.setInt(20)
    check callCount == 1

  test "onChange not called when nil":
    let s = newIntSlider("in", "out", 10)
    # Should not crash
    s.setInt(20)
    check s.getInt() == 20


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

  test "initSimulationState with values":
    let state = initSimulationState(
      particleCount = 1000,
      speciesCount = 6,
      interactionRadius = 100,
      forceStrength = 2.0,
      friction = 0.1,
      timeScale = 1.0,
      maxVelocity = 100.0
    )
    check state.particleCount == 1000
    check state.speciesCount == 6


suite "SimulationState - Updates":
  test "withParticleCount":
    let state = initSimulationState().withParticleCount(5000)
    check state.particleCount == 5000
    # Other values preserved
    check state.speciesCount == 4

  test "withSpeciesCount":
    let state = initSimulationState().withSpeciesCount(6)
    check state.speciesCount == 6

  test "withInteractionRadius":
    let state = initSimulationState().withInteractionRadius(75)
    check state.interactionRadius == 75

  test "withForceStrength":
    let state = initSimulationState().withForceStrength(2.5)
    check abs(state.forceStrength - 2.5) < 0.001

  test "withFriction":
    let state = initSimulationState().withFriction(0.15)
    check abs(state.friction - 0.15) < 0.001

  test "withTimeScale":
    let state = initSimulationState().withTimeScale(0.75)
    check abs(state.timeScale - 0.75) < 0.001

  test "withMaxVelocity":
    let state = initSimulationState().withMaxVelocity(75.0)
    check abs(state.maxVelocity - 75.0) < 0.001

  test "chained updates":
    let state = initSimulationState()
      .withParticleCount(10000)
      .withSpeciesCount(5)
      .withForceStrength(1.5)
    check state.particleCount == 10000
    check state.speciesCount == 5
    check abs(state.forceStrength - 1.5) < 0.001


# ==============================================================================
# RENDER STATE TESTS
# ==============================================================================

suite "RenderState - Initialization":
  test "initRenderState defaults sit within valid display ranges":
    # Exact values are tunable; these bounds are the real contract: a non-positive
    # particle size renders nothing, and trailAlpha must be a valid [0, 1] alpha.
    let state = initRenderState()
    check state.particleSize > 0
    check state.trailAlpha >= 0.0
    check state.trailAlpha <= 1.0
    check state.glowIntensity >= 0.0
    check state.velocityGlowScale >= 0.0

  test "initRenderState with values":
    let state = initRenderState(
      particleSize = 5,
      trails = true,
      trailAlpha = 0.9,
      glowIntensity = 1.2,
      velocityGlowScale = 0.5
    )
    check state.particleSize == 5
    check state.trails == true
    check abs(state.trailAlpha - 0.9) < 0.001


suite "RenderState - Updates":
  test "withParticleSize":
    let state = initRenderState().withParticleSize(5)
    check state.particleSize == 5

  test "withTrails":
    let state = initRenderState().withTrails(true)
    check state.trails == true

  test "withTrailAlpha":
    let state = initRenderState().withTrailAlpha(0.85)
    check abs(state.trailAlpha - 0.85) < 0.001

  test "withGlowIntensity":
    let state = initRenderState().withGlowIntensity(1.5)
    check abs(state.glowIntensity - 1.5) < 0.001

  test "withVelocityGlowScale":
    let state = initRenderState().withVelocityGlowScale(0.75)
    check abs(state.velocityGlowScale - 0.75) < 0.001


suite "RenderState - Queries":
  test "hasTrails false by default":
    let state = initRenderState()
    check state.hasTrails() == false

  test "hasTrails true when enabled":
    let state = initRenderState().withTrails(true)
    check state.hasTrails() == true

  test "hasGlow true when intensity > 0":
    let state = initRenderState()
    check state.hasGlow() == true

  test "hasGlow false when intensity is 0":
    let state = initRenderState().withGlowIntensity(0.0)
    check state.hasGlow() == false
