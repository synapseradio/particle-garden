# ==============================================================================
# PARTICLE GARDEN - PARAM DESCRIPTOR TESTS
# ==============================================================================
#
# Behavioral tests for the parameter descriptor table — the boundary contract
# the TypeScript UI reads instead of duplicating any range, default, or step.
# Every descriptor must agree with config_ranges (the range authority) and
# with the typed state defaults (the default authority), so the UI cannot
# drift from the simulation the way dead index.html attributes once did.
#
# Run with: nimble test
#
# ==============================================================================

import std/[unittest, sets, math, strutils]
import ../src/ui/api/param_descriptor
import ../src/config_ranges
import ../src/ui/state/simulation_state
import ../src/ui/state/render_state
import ../src/palette

const PARAM_DESCRIPTOR_TESTS_LOADED* = true

let descriptors = buildParamDescriptors()

proc byId(id: string): ParamDescriptor =
  for descriptor in descriptors:
    if descriptor.id == id:
      return descriptor
  raise newException(KeyError, "no descriptor with id: " & id)

suite "Descriptor Table Covers The Full Slider Inventory":
  test "every ui.nim slider registration has exactly one descriptor":
    # The interface contract with the TypeScript UI: these ids, no others.
    let expectedIds = toHashSet([
      "particleCount", "speciesCount", "interactionRadius", "forceStrength",
      "friction", "timeScale", "ruleTemperature", "maxVelocity",
      "particleSize", "trailLength",
      "glowIntensity", "velocityGlowScale", "glowRadiusScale", "glowFalloff",
      "glowWarmth",
      "bloomIntensity", "exposure", "saturation", "contrast", "temperature",
      "repulsionEnd", "attractionPeak", "expRepulsionAlpha",
      "expAttractionBeta",
      "paletteSaturation", "paletteLightness",
      "sphRestDensity", "sphStiffness", "sphViscosity", "sphSubsteps",
      "rdFeed", "rdKill", "rdDeposit", "rdFieldForce", "fieldOpacity"])
    var seenIds = initHashSet[string]()
    for descriptor in descriptors:
      check descriptor.id notin seenIds
      seenIds.incl(descriptor.id)
    check seenIds == expectedIds

  test "every descriptor names a non-empty label and group":
    for descriptor in descriptors:
      check descriptor.label.len > 0
      check descriptor.group.len > 0


suite "Hints Name Only Reachable Slider Positions":
  # THE reason hints live in Nim rather than the panel. A hint that names a
  # value the slider cannot land on sends the user hunting for a setting that
  # does not exist — and TypeScript, which is handed the finished string, has
  # nothing to check it against. Here the range, step and precision that decide
  # reachability sit in the same object as the text.
  #
  # This caught a real defect: the panel's old kill-rate hint read
  # "movers ~.0609" against a slider whose step is 0.001.

  proc numeralsIn(hint: string): seq[float] =
    ## Every decimal numeral appearing in a hint, e.g. ".035" or "0.062".
    var current = ""
    for character in hint & " ":
      if character in {'0' .. '9', '.'}:
        current.add character
      else:
        if current.len > 0 and current != ".":
          try:
            result.add parseFloat(current)
          except ValueError:
            discard
        current = ""

  test "every numeral a hint names is a value its slider can actually reach":
    var checkedNumerals = 0
    for descriptor in descriptors:
      if descriptor.hint.len == 0:
        continue
      for named in numeralsIn(descriptor.hint):
        inc checkedNumerals
        # In range...
        check named >= descriptor.minValue
        check named <= descriptor.maxValue
        # ...on a step boundary measured from the range's start...
        let steps = (named - descriptor.minValue) / descriptor.step
        check abs(steps - round(steps)) < 1e-6
        # ...and unchanged by the rounding the readout applies.
        check abs(named - parseFloat(formatFloat(
          named, ffDecimal, descriptor.precision))) < 1e-9
    # Guards against the loop above silently checking nothing.
    check checkedNumerals > 0

  test "the reaction-diffusion regime hints are the ones carrying numerals":
    # Pins which hints the reachability test above is actually exercising, so
    # deleting a hint cannot quietly empty it.
    check numeralsIn(byId("rdFeed").hint).len == 4
    check numeralsIn(byId("rdKill").hint).len == 4

  test "hints that name no numeral are plain guidance":
    # The deposit and field-force hints describe direction, not coordinates.
    # They still mention 0, which must be a real slider position.
    for id in ["rdDeposit", "rdFieldForce"]:
      check byId(id).hint.len > 0
      check byId(id).minValue == 0.0

suite "Every Descriptor Is Internally Coherent":
  test "ranges are non-empty and defaults lie inside them":
    for descriptor in descriptors:
      check descriptor.minValue < descriptor.maxValue
      check descriptor.defaultValue >= descriptor.minValue
      check descriptor.defaultValue <= descriptor.maxValue

  test "step derives from kind and precision the way slider.nim derived it":
    for descriptor in descriptors:
      case descriptor.kind
      of pkInt:
        check descriptor.step == 1.0
      of pkFloat:
        if descriptor.precision <= 0:
          check descriptor.step == 1.0
        else:
          check abs(descriptor.step - pow(10.0, -float(descriptor.precision))) < 1e-12

  test "integer parameters are exactly the five integer CONFIG fields":
    for descriptor in descriptors:
      let expectInt = descriptor.id in [
        "particleCount", "speciesCount", "interactionRadius", "particleSize",
        "sphSubsteps"]
      check (descriptor.kind == pkInt) == expectInt

suite "Descriptors Agree With The Range Authority":
  test "simulation ranges match config_ranges":
    check byId("particleCount").minValue == PARTICLE_COUNT_MIN.float
    check byId("particleCount").maxValue == PARTICLE_COUNT_MAX.float
    check byId("speciesCount").minValue == SPECIES_COUNT_MIN.float
    check byId("speciesCount").maxValue == SPECIES_COUNT_MAX.float
    check byId("interactionRadius").minValue == INTERACTION_RADIUS_MIN.float
    check byId("interactionRadius").maxValue == INTERACTION_RADIUS_MAX.float
    check byId("forceStrength").minValue == FORCE_STRENGTH_MIN
    check byId("forceStrength").maxValue == FORCE_STRENGTH_MAX
    check byId("friction").minValue == FRICTION_MIN
    check byId("friction").maxValue == FRICTION_MAX
    check byId("timeScale").minValue == TIME_SCALE_MIN
    check byId("timeScale").maxValue == TIME_SCALE_MAX
    check byId("ruleTemperature").minValue == RULE_TEMPERATURE_MIN
    check byId("ruleTemperature").maxValue == RULE_TEMPERATURE_MAX
    check byId("maxVelocity").minValue == MAX_VELOCITY_MIN
    check byId("maxVelocity").maxValue == MAX_VELOCITY_MAX

  test "render and glow ranges match config_ranges":
    check byId("particleSize").minValue == PARTICLE_SIZE_MIN.float
    check byId("particleSize").maxValue == PARTICLE_SIZE_MAX.float
    check byId("trailLength").minValue == TRAIL_LENGTH_MIN
    check byId("trailLength").maxValue == TRAIL_LENGTH_MAX
    check byId("glowIntensity").minValue == GLOW_INTENSITY_MIN
    check byId("glowIntensity").maxValue == GLOW_INTENSITY_MAX
    check byId("velocityGlowScale").minValue == VELOCITY_GLOW_SCALE_MIN
    check byId("velocityGlowScale").maxValue == VELOCITY_GLOW_SCALE_MAX
    check byId("glowRadiusScale").minValue == GLOW_RADIUS_SCALE_MIN
    check byId("glowRadiusScale").maxValue == GLOW_RADIUS_SCALE_MAX
    check byId("glowFalloff").minValue == GLOW_FALLOFF_MIN
    check byId("glowFalloff").maxValue == GLOW_FALLOFF_MAX
    check byId("glowWarmth").minValue == GLOW_WARMTH_MIN
    check byId("glowWarmth").maxValue == GLOW_WARMTH_MAX

  test "bloom and grade ranges match config_ranges":
    check byId("bloomIntensity").minValue == BLOOM_INTENSITY_MIN
    check byId("bloomIntensity").maxValue == BLOOM_INTENSITY_MAX
    check byId("exposure").minValue == EXPOSURE_MIN
    check byId("exposure").maxValue == EXPOSURE_MAX
    check byId("saturation").minValue == SATURATION_MIN
    check byId("saturation").maxValue == SATURATION_MAX
    check byId("contrast").minValue == CONTRAST_MIN
    check byId("contrast").maxValue == CONTRAST_MAX
    check byId("temperature").minValue == TEMPERATURE_MIN
    check byId("temperature").maxValue == TEMPERATURE_MAX

  test "force model ranges match config_ranges":
    check byId("repulsionEnd").minValue == REPULSION_END_MIN
    check byId("repulsionEnd").maxValue == REPULSION_END_MAX
    check byId("attractionPeak").minValue == ATTRACTION_PEAK_MIN
    check byId("attractionPeak").maxValue == ATTRACTION_PEAK_MAX
    check byId("expRepulsionAlpha").minValue == EXP_REPULSION_ALPHA_MIN
    check byId("expRepulsionAlpha").maxValue == EXP_REPULSION_ALPHA_MAX
    check byId("expAttractionBeta").minValue == EXP_ATTRACTION_BETA_MIN
    check byId("expAttractionBeta").maxValue == EXP_ATTRACTION_BETA_MAX

  test "palette, sph, and rd ranges match config_ranges":
    check byId("paletteSaturation").minValue == PALETTE_SATURATION_MIN
    check byId("paletteSaturation").maxValue == PALETTE_SATURATION_MAX
    check byId("paletteLightness").minValue == PALETTE_LIGHTNESS_MIN
    check byId("paletteLightness").maxValue == PALETTE_LIGHTNESS_MAX
    check byId("sphRestDensity").minValue == SPH_REST_DENSITY_MIN
    check byId("sphRestDensity").maxValue == SPH_REST_DENSITY_MAX
    check byId("sphStiffness").minValue == SPH_STIFFNESS_MIN
    check byId("sphStiffness").maxValue == SPH_STIFFNESS_MAX
    check byId("sphViscosity").minValue == SPH_VISCOSITY_MIN
    check byId("sphViscosity").maxValue == SPH_VISCOSITY_MAX
    check byId("sphSubsteps").minValue == SPH_SUBSTEPS_MIN.float
    check byId("sphSubsteps").maxValue == SPH_SUBSTEPS_MAX.float
    check byId("rdFeed").minValue == RD_FEED_MIN
    check byId("rdFeed").maxValue == RD_FEED_MAX
    check byId("rdKill").minValue == RD_KILL_MIN
    check byId("rdKill").maxValue == RD_KILL_MAX
    check byId("rdDeposit").minValue == RD_DEPOSIT_MIN
    check byId("rdDeposit").maxValue == RD_DEPOSIT_MAX
    check byId("rdFieldForce").minValue == RD_FIELD_FORCE_MIN
    check byId("rdFieldForce").maxValue == RD_FIELD_FORCE_MAX
    check byId("fieldOpacity").minValue == FIELD_OPACITY_RANGE_MIN
    check byId("fieldOpacity").maxValue == FIELD_OPACITY_RANGE_MAX

suite "Descriptors Agree With The Default Authority":
  let simDefaults = initSimulationState()
  let renderDefaults = initRenderState()

  test "simulation-store defaults come from initSimulationState":
    check byId("particleCount").defaultValue == simDefaults.particleCount.float
    check byId("speciesCount").defaultValue == simDefaults.speciesCount.float
    check byId("interactionRadius").defaultValue ==
      simDefaults.interactionRadius.float
    check byId("forceStrength").defaultValue == simDefaults.forceStrength
    check byId("friction").defaultValue == simDefaults.friction
    check byId("timeScale").defaultValue == simDefaults.timeScale
    check byId("ruleTemperature").defaultValue == simDefaults.ruleTemperature
    check byId("maxVelocity").defaultValue == simDefaults.maxVelocity
    check byId("repulsionEnd").defaultValue == simDefaults.repulsionEnd
    check byId("attractionPeak").defaultValue == simDefaults.attractionPeak
    check byId("expRepulsionAlpha").defaultValue ==
      simDefaults.expRepulsionAlpha
    check byId("expAttractionBeta").defaultValue ==
      simDefaults.expAttractionBeta
    check byId("sphRestDensity").defaultValue == simDefaults.sphRestDensity
    check byId("sphStiffness").defaultValue == simDefaults.sphStiffness
    check byId("sphViscosity").defaultValue == simDefaults.sphViscosity
    check byId("sphSubsteps").defaultValue == simDefaults.sphSubsteps.float
    check byId("rdFeed").defaultValue == simDefaults.rdFeed
    check byId("rdKill").defaultValue == simDefaults.rdKill
    check byId("rdDeposit").defaultValue == simDefaults.rdDeposit
    check byId("rdFieldForce").defaultValue == simDefaults.rdFieldForce

  test "render-store defaults come from initRenderState":
    check byId("particleSize").defaultValue == renderDefaults.particleSize.float
    check byId("trailLength").defaultValue == renderDefaults.trailLength
    check byId("glowIntensity").defaultValue == renderDefaults.glowIntensity
    check byId("velocityGlowScale").defaultValue ==
      renderDefaults.velocityGlowScale
    check byId("glowRadiusScale").defaultValue == renderDefaults.glowRadiusScale
    check byId("glowFalloff").defaultValue == renderDefaults.glowFalloff
    check byId("glowWarmth").defaultValue == renderDefaults.glowWarmth
    check byId("bloomIntensity").defaultValue == renderDefaults.bloomIntensity
    check byId("exposure").defaultValue == renderDefaults.exposure
    check byId("saturation").defaultValue == renderDefaults.saturation
    check byId("contrast").defaultValue == renderDefaults.contrast
    check byId("temperature").defaultValue == renderDefaults.temperature
    check byId("fieldOpacity").defaultValue == renderDefaults.fieldOpacity

  test "palette-store defaults come from palette.nim":
    check byId("paletteSaturation").defaultValue == DEFAULT_SATURATION
    check byId("paletteLightness").defaultValue == DEFAULT_LIGHTNESS

suite "Store Routing Sends Each Parameter To Its Mutation Path":
  test "palette knobs route to the palette store, everything else to CONFIG":
    for descriptor in descriptors:
      if descriptor.id in ["paletteSaturation", "paletteLightness"]:
        check descriptor.store == psPalette
      else:
        check descriptor.store in [psSimulation, psRender]

  test "render-pipeline parameters route to the render store":
    for id in ["particleSize", "trailLength", "glowIntensity",
        "velocityGlowScale", "glowRadiusScale", "glowFalloff", "glowWarmth",
        "bloomIntensity", "exposure", "saturation", "contrast", "temperature",
        "fieldOpacity"]:
      check byId(id).store == psRender

  test "only the two count parameters re-initialize particles on commit":
    for descriptor in descriptors:
      let expectReinit = descriptor.id in ["particleCount", "speciesCount"]
      check descriptor.reinitOnCommit == expectReinit

suite "Clamping Is The Descriptor's Job":
  test "values below the range clamp to the minimum":
    let descriptor = byId("forceStrength")
    check clampParamValue(descriptor, descriptor.minValue - 100.0) ==
      descriptor.minValue

  test "values above the range clamp to the maximum":
    let descriptor = byId("forceStrength")
    check clampParamValue(descriptor, descriptor.maxValue + 100.0) ==
      descriptor.maxValue

  test "in-range values pass through unchanged":
    check clampParamValue(byId("friction"), 0.25) == 0.25

  test "integer parameters truncate fractional values like the old slider":
    # slider.nim's clampValue converted through int(); the descriptor keeps
    # that exact behavior so a drag position lands on the same value.
    check clampParamValue(byId("speciesCount"), 4.9) == 4.0
    check clampParamValue(byId("particleSize"), 2.2) == 2.0
