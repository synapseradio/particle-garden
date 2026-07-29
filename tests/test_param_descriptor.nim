# Behavioral tests for the parameter descriptor table — the boundary contract
# the TypeScript UI reads instead of duplicating any range, default, or step.
# Every descriptor must agree with config_ranges (the range authority) and
# with the typed state defaults (the default authority), so the UI cannot
# drift from the simulation.

import std/[unittest, sets, math, strutils, sequtils]
import ../src/ui/api/param_descriptor
import ../src/ui/api/slider_curve
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

type FieldKind = enum
  ## What a state record holds under a given name, as far as a parameter write
  ## cares: a number it can assign, or nothing it can assign.
  fkAbsent  ## no field of that name, or one no float value can be written to
  fkInt
  fkFloat

proc numericFieldKind[T](record: T; name: string): FieldKind =
  ## Walk the record's fields and report what sits under `name`. The walk is the
  ## same one src/web_api.nim's dispatch performs, so what this finds is what a
  ## parameter write would land in.
  for fieldName, value in record.fieldPairs:
    if fieldName == name:
      when value is int: return fkInt
      elif value is float: return fkFloat
      else: return fkAbsent
  fkAbsent

proc numericFieldNames[T](record: T): HashSet[string] =
  ## Every field of the record a float value can be written to.
  for fieldName, value in record.fieldPairs:
    when value is int or value is float:
      result.incl fieldName

suite "Descriptor Table Covers The Full Tunable Inventory":
  test "every control the panel offers has exactly one descriptor":
    # The interface contract with the TypeScript UI: these ids, no others.
    let expectedIds = toHashSet([
      "particleCount", "speciesCount", "interactionRadius", "forceStrength",
      # crowdingStrength shapes the species force rather than adding a coupling:
      # it scales the attractive half by the receiving particle's local density,
      # and zero is the force law without it.
      "crowdingStrength",
      "friction", "timeScale", "ruleTemperature", "maxVelocity",
      "particleSize", "trailLength",
      "glowIntensity", "velocityGlowScale", "glowRadiusScale", "glowFalloff",
      "glowWarmth",
      "bloomIntensity", "exposure", "saturation", "contrast", "temperature",
      "repulsionEnd", "attractionPeak", "expRepulsionAlpha",
      "expAttractionBeta",
      "paletteSaturation", "paletteLightness",
      # fluidStrength is the coupling strength: the fluid's other three
      # numbers say what kind of fluid it is, and none says how much of it
      # acts.
      "fluidStrength",
      # sphRadiusFraction sets the neighbourhood the other fluid numbers are
      # measured in: the smoothing radius as a fraction of the interaction
      # radius, capped at 1 so it can never outrun the neighbour sweep.
      "sphRadiusFraction",
      "sphRestDensity", "sphStiffness", "sphViscosity", "sphSubsteps",
      "rdFeed", "rdKill", "rdDeposit", "rdFieldForce", "fieldOpacity",
      # climateSpeed drives the drifting climate.
      "climateSpeed",
      # cameraZoom is view state, routed through psCamera to the live camera
      # rather than to CONFIG, which is also why it never reaches the preset
      # schema.
      "cameraZoom",
      # The per-species chemistry columns. They hold one value per SPECIES
      # rather than one for the world, which is a cardinality the descriptor
      # carries, not a reason for a second table: every rule below — range
      # against the authority, default inside the range, notch reachability,
      # one clamp — is the same rule a slider answers to.
      "secretion", "tropism"])
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

  test "every hint numeral and notch coordinate stays reachable under its parameter's curve":
    # The curve warps the handle's travel, never the value set — so every
    # position a hint or a notch names must survive the round trip through
    # the curve pair exactly. Under cLinear this repeats the lattice checks
    # above; the moment a remedy assigns a curve, it starts earning its keep.
    for descriptor in descriptors:
      if descriptor.arity == paPerSpecies:
        continue # a grid cell has no track to curve
      for entry in descriptor.notches:
        check abs(valueAt(descriptor, positionOf(descriptor, entry.value)) -
          entry.value) < 1e-9
      for named in numeralsIn(descriptor.hint):
        check abs(valueAt(descriptor, positionOf(descriptor, named)) -
          named) < 1e-9

  test "the regime coordinates are no longer carried as hint numerals":
    # The regime coordinates live in the notches, checked by "Notches Mark Only
    # Reachable Positions" below under the same reachability rule plus a label.
    # A hint restating them is a second copy free to drift — one naming a
    # regime coordinate that no longer matches what the regime table holds.
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
    ("crowdingStrength", CROWDING_STRENGTH_MIN, CROWDING_STRENGTH_MAX),
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
    ("sphRadiusFraction", SPH_RADIUS_FRACTION_MIN, SPH_RADIUS_FRACTION_MAX),
    ("sphRestDensity", SPH_REST_DENSITY_MIN, SPH_REST_DENSITY_MAX),
    ("sphStiffness", SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX),
    ("sphViscosity", SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX),
    ("sphSubsteps", SPH_SUBSTEPS_MIN.float, SPH_SUBSTEPS_MAX.float),
    ("rdFeed", RD_FEED_MIN, RD_FEED_MAX),
    ("rdKill", RD_KILL_MIN, RD_KILL_MAX),
    ("rdDeposit", RD_DEPOSIT_MIN, RD_DEPOSIT_MAX),
    ("rdFieldForce", RD_FIELD_FORCE_MIN, RD_FIELD_FORCE_MAX),
    ("fieldOpacity", FIELD_OPACITY_RANGE_MIN, FIELD_OPACITY_RANGE_MAX),
    # The per-species columns answer to the same authority as every slider.
    # TROPISM_MAX is deliberately not -TROPISM_MIN (config_ranges records the
    # chemotaxis-stability asymmetry), so a symmetric guess here would be wrong.
    ("secretion", SECRETION_MIN, SECRETION_MAX),
    ("tropism", TROPISM_MIN, TROPISM_MAX),
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
    ("crowdingStrength", simDefaults.crowdingStrength),
    ("friction", simDefaults.friction),
    ("timeScale", simDefaults.timeScale),
    ("ruleTemperature", simDefaults.ruleTemperature),
    ("maxVelocity", simDefaults.maxVelocity),
    ("repulsionEnd", simDefaults.repulsionEnd),
    ("attractionPeak", simDefaults.attractionPeak),
    ("expRepulsionAlpha", simDefaults.expRepulsionAlpha),
    ("expAttractionBeta", simDefaults.expAttractionBeta),
    ("sphRadiusFraction", simDefaults.sphRadiusFraction),
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
    # field_core, which owns what a species does to the field by default
    ("secretion", RD_DEFAULT_SECRETION),
    ("tropism", RD_DEFAULT_TROPISM),
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
      elif descriptor.id in ["secretion", "tropism"]:
        # The per-species columns reach CONFIG too, but by reference rather
        # than through updateSimulation: the panel writes cells of the live
        # SPECIES_CHEMISTRY array and the frame loop uploads it. Naming that
        # path is what keeps setParam from looking like it should serve them.
        check descriptor.store == psSpeciesChemistry
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

suite "Every Routed Id Names A Field Of Its Store":
  # The relation src/web_api.nim's generated dispatch stands on. That dispatch
  # walks the routed record's field names and assigns the one the
  # descriptor id spells, so an id naming no field would write nowhere; the
  # build gate there turns that into a compile error, and these tests report the
  # same break natively, in a second rather than after a JS compile.
  #
  # Both records are pure modules, which is why the relation is checkable here
  # at all: nothing about it needs the browser.

  test "every simulation-store descriptor id names a field of SimulationState":
    let fields = numericFieldNames(initSimulationState())
    for descriptor in descriptors:
      if descriptor.store != psSimulation:
        continue
      if descriptor.id notin fields:
        checkpoint("SimulationState has no assignable field named " &
          descriptor.id)
      check descriptor.id in fields

  test "every render-store descriptor id names a field of RenderState":
    let fields = numericFieldNames(initRenderState())
    for descriptor in descriptors:
      if descriptor.store != psRender:
        continue
      if descriptor.id notin fields:
        checkpoint("RenderState has no assignable field named " & descriptor.id)
      check descriptor.id in fields

  test "each routed id names a field of the kind its descriptor declares":
    # The half of the relation a name match alone leaves open: a pkFloat
    # descriptor over an int field truncates every value it carries, silently,
    # because the dispatch coerces to whatever the FIELD holds.
    for descriptor in descriptors:
      let found =
        case descriptor.store
        of psSimulation: numericFieldKind(initSimulationState(), descriptor.id)
        of psRender: numericFieldKind(initRenderState(), descriptor.id)
        else: fkAbsent
      if found == fkAbsent:
        continue
      let expected = (if descriptor.kind == pkInt: fkInt else: fkFloat)
      if found != expected:
        checkpoint("field kind " & $found & " under descriptor " &
          descriptor.id & ", which declares " & $descriptor.kind)
      check found == expected

  test "the two routes that are not field assignments carry exactly their ids":
    # web_api's explicit arms are written against these ids by name, so a third
    # palette knob or a second camera control would reach an arm that does not
    # know it exists. The dispatch's own build gate says the same thing at
    # compile time; this says it here, where the message is a test name.
    var palette: seq[string]
    var camera: seq[string]
    for descriptor in descriptors:
      case descriptor.store
      of psPalette: palette.add descriptor.id
      of psCamera: camera.add descriptor.id
      else: discard
    check palette == @["paletteSaturation", "paletteLightness"]
    check camera == @["cameraZoom"]

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


suite "Cardinality Rides On The Descriptor, Not On A Second Table":
  # Secretion and tropism hold one value per SPECIES where a slider holds one
  # for the world. That difference is a member — an arity, plus the slot the
  # value occupies inside a species' stride — so the panel branches on it to
  # render a grid row instead of a slider. A second record shape would owe the
  # panel every guarantee this one already gives (range, default, clamp, notch
  # reachability) and would be free to drift from it on each one.

  proc perSpecies(): seq[ParamDescriptor] =
    for descriptor in descriptors:
      if descriptor.arity == paPerSpecies:
        result.add descriptor

  test "the per-species columns are exactly secretion and tropism":
    var ids: HashSet[string]
    for descriptor in perSpecies():
      ids.incl descriptor.id
    check ids == toHashSet(["secretion", "tropism"])

  test "every other descriptor is scalar":
    # The default cardinality, stated so a new descriptor cannot acquire a slot
    # by accident and start indexing a per-species array it has no place in.
    for descriptor in descriptors:
      if descriptor.id notin ["secretion", "tropism"]:
        check descriptor.arity == paScalar

  test "the columns fill one species' stride exactly, with no slot spare":
    # The panel indexes as species * stride + slot. A repeated slot aliases two
    # columns onto one number; a gap means the stride reserves space nothing
    # writes, and a slot at or past the stride overruns into the next species.
    var slots: HashSet[int]
    for descriptor in perSpecies():
      check descriptor.slot >= 0
      check descriptor.slot < SPECIES_CHEMISTRY_STRIDE
      slots.incl descriptor.slot
    check slots == toHashSet(toSeq(0 ..< SPECIES_CHEMISTRY_STRIDE))

  test "one clamp serves both cardinalities":
    # THE FOLD'S POINT. clampParamValue is the only clamp on the boundary, so a
    # grid cell and a slider cannot disagree about what a range means.
    for descriptor in perSpecies():
      check clampParamValue(descriptor, descriptor.minValue - 100.0) ==
        descriptor.minValue
      check clampParamValue(descriptor, descriptor.maxValue + 100.0) ==
        descriptor.maxValue
      check clampParamValue(descriptor, descriptor.defaultValue) ==
        descriptor.defaultValue

  test "every per-species column carries a hint, because neither name explains itself":
    # "Secretion" and "Tropism" are the field's own vocabulary, not the user's,
    # and both are signed — which direction a negative value means is exactly
    # what a bare label cannot say.
    for descriptor in perSpecies():
      check descriptor.hint.len > 0


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

  test "the particle-count notch is only the default — its range ceiling is the one budget":
    # PARTICLE_COUNT_MAX (the allocation capability) is the only ceiling this
    # slider has, and "descriptors agree with the range authority" above
    # already pins its max there. No second notch survives to drift from it.
    check byId("particleCount").notches.len == 1
    check byId("particleCount").notches[0].label == "default"

  test "every coupling strength offers a notch at zero":
    # Zero is an ordinary value of a coupling strength, and an unmarked off
    # position hides the setting that isolates what a coupling contributes.
    for id in ["forceStrength", "fluidStrength", "rdDeposit", "rdFieldForce"]:
      let descriptor = byId(id)
      checkpoint("coupling strength " & id)
      check descriptor.minValue == 0.0
      check descriptor.notches.anyIt(it.value == 0.0)

  test "the camera zoom notches lie inside the camera range":
    # The notch constants are checked against the range directly, so the
    # relation holds whether or not a descriptor carries them.
    for value in [CAMERA_ZOOM_NOTCH_WORLD, CAMERA_ZOOM_NOTCH_CREATURE]:
      check value >= CAMERA_ZOOM_MIN
      check value <= CAMERA_ZOOM_MAX


# Most bounds are the envelope in the descriptor and nothing else. One is not:
# the stiffness the fluid can hold depends on how far its kernel reaches, how
# many substeps it takes, and how long a frame is, so the descriptor cites a
# registered ceiling function instead of pretending its declared maximum is the
# whole story. The envelope constants do not move — store-time clamping still
# runs against them — and the ceiling applies where the value takes effect.

suite "A Derived Bound Cites A Registered Ceiling":
  test "every descriptor carries a bound, and only the fluid's stiffness derives":
    var derived: seq[string] = @[]
    for descriptor in descriptors:
      case descriptor.bound.kind
      of bConstant: discard
      of bDerived: derived.add descriptor.id
    check derived == @["sphStiffness"]
    check byId("sphStiffness").bound.ceilingId == pcStableStiffness

  test "every bDerived descriptor cites a registered ceiling":
    # A registered ceiling is one this build can evaluate. The citation is an
    # enum rather than a name, so an unregistered one cannot be written down at
    # all; what stays checkable is that the function behind it answers with a
    # usable number everywhere its inputs can go.
    for descriptor in descriptors:
      if descriptor.bound.kind != bDerived: continue
      for inputs in ceilingInputBox():
        let ceiling = evaluateCeiling(descriptor.bound.ceilingId, inputs)
        checkpoint(descriptor.id & " at radius " & $inputs.interactionRadius &
          ", fraction " & $inputs.sphRadiusFraction &
          ", substeps " & $inputs.sphSubsteps &
          ", time scale " & $inputs.timeScale)
        check ceiling > 0.0
        check ceiling <= descriptor.maxValue
      check ceilingReason(descriptor.bound.ceilingId).len > 0

  test "the minimum ceiling is the corner it claims to be":
    # minimumCeiling names one corner of the deriving inputs' box. This is the
    # sweep that says the corner is the smallest point in it — without which
    # "every notch sits below the minimum ceiling" would be a claim about an
    # arbitrary point.
    for id in ParamCeilingId:
      let floorValue = minimumCeiling(id)
      check floorValue > 0.0
      for inputs in ceilingInputBox():
        checkpoint($id & " at radius " & $inputs.interactionRadius &
          ", fraction " & $inputs.sphRadiusFraction &
          ", substeps " & $inputs.sphSubsteps &
          ", time scale " & $inputs.timeScale)
        check evaluateCeiling(id, inputs) >= floorValue

  test "every notch of a bDerived parameter sits below the minimum ceiling over its input box":
    # A notch is a claim that a position is worth stopping at. On a parameter
    # whose effect is capped, a notch above the worst-case cap names a position
    # the fluid can never honour — a label pointing into the dormant region.
    for descriptor in descriptors:
      if descriptor.bound.kind != bDerived: continue
      let floorValue = minimumCeiling(descriptor.bound.ceilingId)
      for entry in descriptor.notches:
        checkpoint(descriptor.id & " notch " & entry.label &
          " at " & $entry.value & " against minimum ceiling " & $floorValue)
        check entry.value <= floorValue

  test "store-time clamping still runs against the envelope alone":
    # The three parts stay separate: the envelope owns what can be STORED, the
    # ceiling owns what TAKES EFFECT. A clamp that knew about the ceiling would
    # destroy the stored value, which is the failure this separation exists to
    # prevent.
    let stiffness = byId("sphStiffness")
    check clampParamValue(stiffness, SPH_STIFFNESS_MAX) == SPH_STIFFNESS_MAX
    check clampParamValue(stiffness, SPH_STIFFNESS_MAX + 10.0) ==
      SPH_STIFFNESS_MAX

suite "The Effective Value Is Bounded Without The Stored One Moving":
  test "a fluid that cannot hold the stored stiffness runs at its ceiling":
    var sim = initSimulationState()
    sim.sphStiffness = SPH_STIFFNESS_MAX
    sim.sphRadiusFraction = SPH_RADIUS_FRACTION_MIN
    let effective = effectiveSimulation(sim)
    checkpoint("ceiling " & $evaluateCeiling(pcStableStiffness, ceilingInputs(sim)))
    check effective.sphStiffness < sim.sphStiffness
    check effective.sphStiffness ==
      evaluateCeiling(pcStableStiffness, ceilingInputs(sim))
    # The stored record is untouched — this is a pure function of a copy.
    check sim.sphStiffness == SPH_STIFFNESS_MAX

  test "shrinking the fraction drops the effective stiffness":
    var sim = initSimulationState()
    sim.sphStiffness = SPH_STIFFNESS_MAX
    var previous = Inf
    for fraction in [SPH_RADIUS_FRACTION_MAX, 0.5, 0.25,
        SPH_RADIUS_FRACTION_MIN]:
      sim.sphRadiusFraction = fraction
      let effective = effectiveSimulation(sim).sphStiffness
      checkpoint("fraction " & $fraction & " -> " & $effective)
      check effective <= previous
      previous = effective
    check previous < SPH_STIFFNESS_MAX

  test "restoring the fraction restores the stored value's full effect, with no hysteresis":
    # The whole point of clamping at effect time rather than at store time: the
    # stored value survives the trip, so the fluid comes back exactly as it was.
    var sim = initSimulationState()
    sim.sphStiffness = SPH_STIFFNESS_MAX
    sim.sphRadiusFraction = SPH_RADIUS_FRACTION_MAX
    sim.sphSubsteps = SPH_SUBSTEPS_MAX
    let before = effectiveSimulation(sim).sphStiffness
    for fraction in [SPH_RADIUS_FRACTION_MIN, 0.3, 0.7,
        SPH_RADIUS_FRACTION_MAX]:
      sim.sphRadiusFraction = fraction
      discard effectiveSimulation(sim)
    check effectiveSimulation(sim).sphStiffness == before
    check sim.sphStiffness == SPH_STIFFNESS_MAX

  test "a ceiling input other than the fraction moves the effective value too":
    # Substeps and time scale are inputs on the same footing, so each of them
    # alone has to move the effect. Time scale runs the other way: a world run
    # faster has a longer timestep and holds less stiffness.
    var sim = initSimulationState()
    sim.sphStiffness = SPH_STIFFNESS_MAX
    sim.sphRadiusFraction = 0.5
    sim.sphSubsteps = SPH_SUBSTEPS_MIN
    let fewSubsteps = effectiveSimulation(sim).sphStiffness
    sim.sphSubsteps = SPH_SUBSTEPS_MAX
    let manySubsteps = effectiveSimulation(sim).sphStiffness
    check manySubsteps > fewSubsteps

    sim.timeScale = TIME_SCALE_MIN
    let slowWorld = effectiveSimulation(sim).sphStiffness
    sim.timeScale = TIME_SCALE_MAX
    let fastWorld = effectiveSimulation(sim).sphStiffness
    check slowWorld > fastWorld

  test "every parameter with a constant bound passes through untouched":
    # effectiveSimulation is the one place a stored value and a running value
    # differ, and it may differ in exactly the derived ones.
    var sim = initSimulationState()
    sim.sphRadiusFraction = SPH_RADIUS_FRACTION_MIN
    sim.sphStiffness = SPH_STIFFNESS_MAX
    let effective = effectiveSimulation(sim)
    check effective.interactionRadius == sim.interactionRadius
    check effective.sphRadiusFraction == sim.sphRadiusFraction
    check effective.sphSubsteps == sim.sphSubsteps
    check effective.sphViscosity == sim.sphViscosity
    check effective.sphRestDensity == sim.sphRestDensity
    check effective.fluidStrength == sim.fluidStrength
    check effective.timeScale == sim.timeScale

  test "the shipped default is never clamped in its own world":
    # A derived ceiling that bit the defaults would be shipping a fluid nobody
    # chose. The default stiffness stays reachable at the default fraction and
    # time scale whatever the substep slider is set to.
    var sim = initSimulationState()
    for substeps in SPH_SUBSTEPS_MIN .. SPH_SUBSTEPS_MAX:
      sim.sphSubsteps = substeps
      checkpoint("substeps " & $substeps)
      check effectiveSimulation(sim).sphStiffness == sim.sphStiffness
