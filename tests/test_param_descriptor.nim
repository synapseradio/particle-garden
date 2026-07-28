# ==============================================================================
# PARTICLE GARDEN - PARAM DESCRIPTOR TESTS
# ==============================================================================
#
# Behavioral tests for the parameter descriptor table — the boundary contract
# the TypeScript UI reads instead of duplicating any range, default, or step.
# Every descriptor must agree with config_ranges (the range authority) and
# with the typed state defaults (the default authority), so the UI cannot
# drift from the simulation.
#
# Run with: just test
#
# ==============================================================================

import std/[unittest, sets, math, strutils, sequtils]
import ../src/ui/api/param_descriptor
import ../src/config_ranges
import ../src/field_core  # SPECIES_CHEMISTRY_STRIDE and the chemistry defaults
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
  test "every slider the panel offers has exactly one descriptor":
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
      # fluidStrength is the coupling strength design D14 introduces: the
      # fluid's other three numbers say what kind of fluid it is, and none says
      # how much of it acts.
      "fluidStrength",
      "sphRestDensity", "sphStiffness", "sphViscosity", "sphSubsteps",
      "rdFeed", "rdKill", "rdDeposit", "rdFieldForce", "fieldOpacity",
      # climateSpeed drives the drifting climate. This set is the interface
      # contract with the panel, so every id the panel reads appears in it.
      "climateSpeed",
      # cameraZoom is view state, routed through psCamera to the live camera
      # rather than to CONFIG, which is also why it never reaches the preset
      # schema.
      "cameraZoom"])
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
  # What this forbids concretely: a kill-rate hint reading "movers ~.0609"
  # against a slider whose step is 0.001.

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

  test "the regime coordinates are no longer carried as hint numerals":
    # The regime coordinates live in the notches, checked by "Notches Mark Only
    # Reachable Positions" below under the same reachability rule plus a label.
    # A hint restating them is a second copy free to drift — one naming a coral
    # at (0.055, 0.062) against the regime table's (0.082, 0.059).
    check numeralsIn(byId("rdFeed").hint).len == 0
    check numeralsIn(byId("rdKill").hint).len == 0
    check byId("rdFeed").notches.len == RD_REGIMES.len
    check byId("rdKill").notches.len == RD_REGIMES.len

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

  test "step derives from kind and precision":
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
  # One row per parameter, against the constant config_ranges holds for it. The
  # relation is identical for every id, so it is stated once and the table
  # carries what differs — which is also what a new parameter adds here.
  let rangeExpectations: seq[(string, float, float)] = @[
    # Simulation
    ("particleCount", PARTICLE_COUNT_MIN.float, PARTICLE_COUNT_MAX.float),
    ("speciesCount", SPECIES_COUNT_MIN.float, SPECIES_COUNT_MAX.float),
    ("interactionRadius", INTERACTION_RADIUS_MIN.float,
      INTERACTION_RADIUS_MAX.float),
    ("forceStrength", FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX),
    ("friction", FRICTION_MIN, FRICTION_MAX),
    ("timeScale", TIME_SCALE_MIN, TIME_SCALE_MAX),
    ("ruleTemperature", RULE_TEMPERATURE_MIN, RULE_TEMPERATURE_MAX),
    ("maxVelocity", MAX_VELOCITY_MIN, MAX_VELOCITY_MAX),
    # Render and glow
    ("particleSize", PARTICLE_SIZE_MIN.float, PARTICLE_SIZE_MAX.float),
    ("trailLength", TRAIL_LENGTH_MIN, TRAIL_LENGTH_MAX),
    ("glowIntensity", GLOW_INTENSITY_MIN, GLOW_INTENSITY_MAX),
    ("velocityGlowScale", VELOCITY_GLOW_SCALE_MIN, VELOCITY_GLOW_SCALE_MAX),
    ("glowRadiusScale", GLOW_RADIUS_SCALE_MIN, GLOW_RADIUS_SCALE_MAX),
    ("glowFalloff", GLOW_FALLOFF_MIN, GLOW_FALLOFF_MAX),
    ("glowWarmth", GLOW_WARMTH_MIN, GLOW_WARMTH_MAX),
    # Bloom and grade
    ("bloomIntensity", BLOOM_INTENSITY_MIN, BLOOM_INTENSITY_MAX),
    ("exposure", EXPOSURE_MIN, EXPOSURE_MAX),
    ("saturation", SATURATION_MIN, SATURATION_MAX),
    ("contrast", CONTRAST_MIN, CONTRAST_MAX),
    ("temperature", TEMPERATURE_MIN, TEMPERATURE_MAX),
    # Force model
    ("repulsionEnd", REPULSION_END_MIN, REPULSION_END_MAX),
    ("attractionPeak", ATTRACTION_PEAK_MIN, ATTRACTION_PEAK_MAX),
    ("expRepulsionAlpha", EXP_REPULSION_ALPHA_MIN, EXP_REPULSION_ALPHA_MAX),
    ("expAttractionBeta", EXP_ATTRACTION_BETA_MIN, EXP_ATTRACTION_BETA_MAX),
    # Palette, SPH, and the reaction-diffusion field
    ("paletteSaturation", PALETTE_SATURATION_MIN, PALETTE_SATURATION_MAX),
    ("paletteLightness", PALETTE_LIGHTNESS_MIN, PALETTE_LIGHTNESS_MAX),
    ("sphRestDensity", SPH_REST_DENSITY_MIN, SPH_REST_DENSITY_MAX),
    ("sphStiffness", SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX),
    ("sphViscosity", SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX),
    ("sphSubsteps", SPH_SUBSTEPS_MIN.float, SPH_SUBSTEPS_MAX.float),
    ("rdFeed", RD_FEED_MIN, RD_FEED_MAX),
    ("rdKill", RD_KILL_MIN, RD_KILL_MAX),
    ("rdDeposit", RD_DEPOSIT_MIN, RD_DEPOSIT_MAX),
    ("rdFieldForce", RD_FIELD_FORCE_MIN, RD_FIELD_FORCE_MAX),
    ("fieldOpacity", FIELD_OPACITY_RANGE_MIN, FIELD_OPACITY_RANGE_MAX),
  ]

  test "every listed parameter's range is the one config_ranges holds":
    for (id, expectedMin, expectedMax) in rangeExpectations:
      let descriptor = byId(id)
      if descriptor.minValue != expectedMin or
          descriptor.maxValue != expectedMax:
        checkpoint("range drift for " & id)
      check descriptor.minValue == expectedMin
      check descriptor.maxValue == expectedMax

suite "Descriptors Agree With The Default Authority":
  let simDefaults = initSimulationState()
  let renderDefaults = initRenderState()

  # One row per parameter, against the authority that owns its default: the
  # typed simulation state, the typed render state, or palette.nim. Reading a
  # row tells you which of the three a parameter answers to.
  let defaultExpectations: seq[(string, float)] = @[
    # initSimulationState
    ("particleCount", simDefaults.particleCount.float),
    ("speciesCount", simDefaults.speciesCount.float),
    ("interactionRadius", simDefaults.interactionRadius.float),
    ("forceStrength", simDefaults.forceStrength),
    ("friction", simDefaults.friction),
    ("timeScale", simDefaults.timeScale),
    ("ruleTemperature", simDefaults.ruleTemperature),
    ("maxVelocity", simDefaults.maxVelocity),
    ("repulsionEnd", simDefaults.repulsionEnd),
    ("attractionPeak", simDefaults.attractionPeak),
    ("expRepulsionAlpha", simDefaults.expRepulsionAlpha),
    ("expAttractionBeta", simDefaults.expAttractionBeta),
    ("sphRestDensity", simDefaults.sphRestDensity),
    ("sphStiffness", simDefaults.sphStiffness),
    ("sphViscosity", simDefaults.sphViscosity),
    ("sphSubsteps", simDefaults.sphSubsteps.float),
    ("rdFeed", simDefaults.rdFeed),
    ("rdKill", simDefaults.rdKill),
    ("rdDeposit", simDefaults.rdDeposit),
    ("rdFieldForce", simDefaults.rdFieldForce),
    # initRenderState
    ("particleSize", renderDefaults.particleSize.float),
    ("trailLength", renderDefaults.trailLength),
    ("glowIntensity", renderDefaults.glowIntensity),
    ("velocityGlowScale", renderDefaults.velocityGlowScale),
    ("glowRadiusScale", renderDefaults.glowRadiusScale),
    ("glowFalloff", renderDefaults.glowFalloff),
    ("glowWarmth", renderDefaults.glowWarmth),
    ("bloomIntensity", renderDefaults.bloomIntensity),
    ("exposure", renderDefaults.exposure),
    ("saturation", renderDefaults.saturation),
    ("contrast", renderDefaults.contrast),
    ("temperature", renderDefaults.temperature),
    ("fieldOpacity", renderDefaults.fieldOpacity),
    # palette.nim
    ("paletteSaturation", DEFAULT_SATURATION),
    ("paletteLightness", DEFAULT_LIGHTNESS),
  ]

  test "every listed parameter's default is the one its authority holds":
    for (id, expectedDefault) in defaultExpectations:
      let descriptor = byId(id)
      if descriptor.defaultValue != expectedDefault:
        checkpoint("default drift for " & id)
      check descriptor.defaultValue == expectedDefault

suite "Store Routing Sends Each Parameter To Its Mutation Path":
  test "palette knobs route to the palette store, everything else to CONFIG":
    # cameraZoom is the one parameter that reaches NEITHER CONFIG nor the
    # palette: it writes the live view. That is the whole reason psCamera
    # exists, and the reason a preset cannot carry it — so it is named here
    # explicitly rather than folded into the CONFIG arm, which would quietly
    # let a future descriptor escape the routing contract.
    for descriptor in descriptors:
      if descriptor.id in ["paletteSaturation", "paletteLightness"]:
        check descriptor.store == psPalette
      elif descriptor.id == "cameraZoom":
        check descriptor.store == psCamera
      else:
        check descriptor.store in [psSimulation, psRender]

  test "the camera is the only parameter that never reaches CONFIG":
    # Stated as its own claim because it is a boundary, not a detail: anything
    # routed through psCamera is absent from the preset schema by construction,
    # and a second one appearing silently would widen that hole without anyone
    # deciding to.
    var cameraRouted: seq[string]
    for descriptor in descriptors:
      if descriptor.store == psCamera:
        cameraRouted.add descriptor.id
    check cameraRouted == @["cameraZoom"]

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

  test "integer parameters truncate fractional values":
    # CONTRACT: integer parameters truncate through int() rather than rounding,
    # so a drag position lands on the value below it and never above.
    check clampParamValue(byId("speciesCount"), 4.9) == 4.0
    check clampParamValue(byId("particleSize"), 2.2) == 2.0


suite "The Chemistry Field Table Is Its Own Small Contract":
  # Secretion and tropism are per-species, so they cannot live in the slider
  # table (every consumer of that table assumes one value per id). They get
  # their own table, and it owes the panel the same guarantees: a range to
  # clamp against, a default inside it, and a distinct slot to index by.

  test "the table names exactly secretion and tropism":
    var ids: HashSet[string]
    for field in buildChemistryFields():
      ids.incl field.id
    check ids == toHashSet(["secretion", "tropism"])

  test "every chemistry field carries a non-empty range holding its default":
    # The same relation the slider table asserts against config_ranges: a
    # default outside its own range would mean the panel opens on a value it
    # will not let the user return to.
    for field in buildChemistryFields():
      check field.minValue < field.maxValue
      check field.defaultValue >= field.minValue
      check field.defaultValue <= field.maxValue

  test "chemistry ranges come from the range authority":
    for field in buildChemistryFields():
      case field.id
      of "secretion":
        check field.minValue == SECRETION_MIN
        check field.maxValue == SECRETION_MAX
      of "tropism":
        check field.minValue == TROPISM_MIN
        check field.maxValue == TROPISM_MAX
      else:
        check false  # a new field needs its range relation stated here

  test "each field occupies a distinct slot inside one species' stride":
    # The panel computes an index as species * stride + slot. Two fields
    # sharing a slot, or a slot past the stride, would alias or overrun.
    var slots: HashSet[int]
    for field in buildChemistryFields():
      check field.slot >= 0
      check field.slot < SPECIES_CHEMISTRY_STRIDE
      slots.incl field.slot
    check slots.len == buildChemistryFields().len

  test "every chemistry field carries a hint, because neither name explains itself":
    # "Secretion" and "Tropism" are the field's own vocabulary, not the user's,
    # and both are signed — which direction a negative value means is exactly
    # what a bare label cannot say.
    for field in buildChemistryFields():
      check field.hint.len > 0

  test "the step is one unit of the field's own display precision":
    for field in buildChemistryFields():
      check field.precision > 0
      check abs(field.step - pow(10.0, -float(field.precision))) < 1e-12

  test "clamping holds a chemistry value inside its range":
    for field in buildChemistryFields():
      check clampChemistryValue(field, field.minValue - 100.0) == field.minValue
      check clampChemistryValue(field, field.maxValue + 100.0) == field.maxValue
      check clampChemistryValue(field, field.defaultValue) == field.defaultValue


suite "Notches Mark Only Reachable Positions":
  # A notch is a claim that a value is worth stopping at. A notch outside its
  # own slider's range is a labelled position the user cannot reach — the same
  # defect class as a hint naming an unreachable number, and the reason the
  # regime coordinates live beside the ranges they must satisfy.

  test "every notch value lies inside its parameter's range":
    for descriptor in buildParamDescriptors():
      for entry in descriptor.notches:
        check entry.value >= descriptor.minValue
        check entry.value <= descriptor.maxValue

  test "every notch sits on a position the slider can actually land on":
    # In-range is not enough. A notch off the step grid is a tick the handle
    # slides past without ever stopping on, so snapping to it would leave the
    # readout showing a value the slider cannot hold. Same rule the hint
    # numerals above are held to, for the same reason.
    var checkedNotches = 0
    for descriptor in buildParamDescriptors():
      for entry in descriptor.notches:
        inc checkedNotches
        let steps = (entry.value - descriptor.minValue) / descriptor.step
        check abs(steps - round(steps)) < 1e-6
        # And unchanged by the rounding the readout applies.
        check abs(entry.value - parseFloat(formatFloat(
          entry.value, ffDecimal, descriptor.precision))) < 1e-9
    check checkedNotches > 0

  test "every notch carries a label":
    # An unlabelled tick is a mark with no claim attached — it tells the user
    # to stop somewhere without saying why.
    for descriptor in buildParamDescriptors():
      for entry in descriptor.notches:
        check entry.label.len > 0

  test "no parameter declares the same notch value twice":
    # Two labels on one position is a contradiction the panel cannot render,
    # and usually means a default coincides with a named value.
    for descriptor in buildParamDescriptors():
      var seen: HashSet[float]
      for entry in descriptor.notches:
        check entry.value notin seen
        seen.incl entry.value

  test "feed and kill each carry all six named regimes":
    # A regime is a POINT, so both axes must offer the same six labels — a
    # notch on one axis alone does not locate one.
    for id in ["rdFeed", "rdKill"]:
      let labels = byId(id).notches.mapIt(it.label)
      check labels.len == RD_REGIMES.len
      for regime in RD_REGIMES:
        check regime.label in labels

  test "each regime's notch values are the coordinates the range authority holds":
    # The panel must not be able to show a coordinate the regime buttons do not
    # set, so both read RD_REGIMES rather than restating numbers.
    for regime in RD_REGIMES:
      var feedFound, killFound = false
      for entry in byId("rdFeed").notches:
        if entry.label == regime.label and entry.value == regime.feed:
          feedFound = true
      for entry in byId("rdKill").notches:
        if entry.label == regime.label and entry.value == regime.kill:
          killFound = true
      check feedFound
      check killFound

  test "the high-feed deposit notch is the floor the regime table measured":
    # One measurement, two consumers: the Deposit slider's notch and the floor
    # the regime buttons raise the deposit to. If they drift, a user could pick
    # Coral, land on the notch, and still see nothing.
    for regime in RD_REGIMES:
      if regime.minDeposit > 0.0:
        check regime.minDeposit == RD_REGIME_HIGH_FEED_DEPOSIT
    check byId("rdDeposit").notches.anyIt(
      it.value == RD_REGIME_HIGH_FEED_DEPOSIT)

  test "the particle-count notch marks the world's one budget":
    # One world, one budget, one tick.
    check byId("particleCount").notches.anyIt(
      it.value == PARTICLE_BUDGET.float)

  test "every coupling strength offers a notch at zero":
    # Zero is an ordinary value of a coupling strength (design D13), and an
    # unmarked off position hides the setting that isolates what a coupling
    # contributes.
    for id in ["forceStrength", "fluidStrength", "rdDeposit", "rdFieldForce"]:
      let descriptor = byId(id)
      checkpoint("coupling strength " & id)
      check descriptor.minValue == 0.0
      check descriptor.notches.anyIt(it.value == 0.0)

  test "the camera zoom notches lie inside the camera range":
    # The notch constants are checked against the range directly, so the
    # relation holds whether or not a descriptor carries them.
    for value in [CAMERA_ZOOM_NOTCH_TILED, CAMERA_ZOOM_NOTCH_WORLD,
        CAMERA_ZOOM_NOTCH_CREATURE]:
      check value >= CAMERA_ZOOM_MIN
      check value <= CAMERA_ZOOM_MAX
