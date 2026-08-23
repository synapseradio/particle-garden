# Behavioral tests for src/preset.nim: the versioned preset serialization
# contract. Covers round-trip fidelity, newer-schema-version rejection,
# clamp/default degradation of hostile input, and the migrate hook.

import std/unittest
import std/json
import ../src/memory_layout
import ../src/preset
import ../src/colormap_core  # the authority preset.nim mirrors fieldOpacity from
import ../src/field_core     # and the chemistry defaults it mirrors
import ../src/climate_core   # and the climate speed default
import ../src/ui/api/param_descriptor
import ../src/ui/state/simulation_state
import ../src/ui/state/render_state

const PRESET_TESTS_LOADED* = true

suite "Clamp Bounds Are The Live Slider Ranges":
  # preset.nim re-exports config_ranges.nim, the range authority the panel's
  # descriptors read — so preset bounds and UI ranges agree by construction,
  # not by mirrored literals. What remains testable here are the relations
  # between independent sources.

  test "the particle ceiling is the buffer allocation limit, not a stale UI copy":
    check PARTICLE_COUNT_MAX == memory_layout.MAX_PARTICLES

  test "the species ceiling equals the preset's own array sizing":
    check SPECIES_COUNT_MAX == preset.MAX_SPECIES

  test "every mirrored default equals the module that owns it":
    # preset.nim carries these as literals because its dependencies are
    # restricted to config_ranges and palette. A literal mirror drifts in
    # silence — a preset missing the field then restores a different value than
    # a fresh session starts at — so the agreement is asserted from here, where
    # both modules are importable.
    let defaults = defaultSettings()
    check defaults.fieldOpacity == FIELD_OPACITY_DEFAULT
    check defaults.rdFeed == RD_DEFAULT_FEED
    check defaults.rdKill == RD_DEFAULT_KILL
    check defaults.rdDeposit == RD_DEFAULT_DEPOSIT
    check defaults.rdFieldForce == RD_DEFAULT_FIELD_FORCE
    check defaults.climateSpeed == CLIMATE_DEFAULT_SPEED
    check defaults.forceWeatherSpeed == FORCE_WEATHER_DEFAULT_SPEED

  test "the default chemistry equals the per-species defaults it mirrors":
    let chemistry = defaultChemistry()
    for speciesIndex in 0 ..< preset.MAX_SPECIES:
      let base = speciesIndex * CHEMISTRY_STRIDE
      check chemistry[base] == RD_DEFAULT_SECRETION
      check chemistry[base + 1] == RD_DEFAULT_TROPISM

  test "every documented default lies inside its own clamp range":
    let defaults = defaultSettings()
    check defaults.particleCount == clamp(defaults.particleCount, PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX)
    check defaults.glowRadiusScale == clamp(defaults.glowRadiusScale, GLOW_RADIUS_SCALE_MIN, GLOW_RADIUS_SCALE_MAX)
    check defaults.glowFalloff == clamp(defaults.glowFalloff, GLOW_FALLOFF_MIN, GLOW_FALLOFF_MAX)
    check defaults.glowWarmth == clamp(defaults.glowWarmth, GLOW_WARMTH_MIN, GLOW_WARMTH_MAX)

  test "every preset default equals the state field that owns it":
    # THE TOTAL RELATION. This walks PresetSettings, SimulationState and
    # RenderState by fieldPairs, so a field added to any of the three is covered
    # without editing this test.
    #
    # preset.nim carries these as literals because its imports are restricted to
    # config_ranges and palette (see its header). Here both sides are
    # importable, so here is where the agreement is held.
    let defaults = defaultSettings()
    let sim = initSimulationState()
    let render = initRenderState()
    var total = 0
    var owned = 0
    for presetName, presetValue in defaults.fieldPairs:
      inc total
      var found = false
      for simName, simValue in sim.fieldPairs:
        when typeof(presetValue) is typeof(simValue):
          if presetName == simName:
            # Checkpointed only on disagreement: unittest prints every
            # checkpoint the test accumulated, so an unconditional one here
            # would bury the offending field under all forty-three others.
            if presetValue != simValue:
              checkpoint("preset default \"" & presetName & "\" is " &
                $presetValue & ", SimulationState owns " & $simValue)
            check presetValue == simValue
            found = true
      for renderName, renderValue in render.fieldPairs:
        when typeof(presetValue) is typeof(renderValue):
          if presetName == renderName:
            if presetValue != renderValue:
              checkpoint("preset default \"" & presetName & "\" is " &
                $presetValue & ", RenderState owns " & $renderValue)
            check presetValue == renderValue
            found = true
      if not found:
        checkpoint("preset key \"" & presetName &
          "\" names no field of either state record")
      check found
      if found: inc owned

    # NON-VACUITY. Both lines exist so this cannot pass by comparing nothing:
    # the walk must have run, and every key it saw must have found an owner.
    check total > 0
    check owned == total

  test "an out-of-range crowding strength clamps instead of rejecting":
    # Same treatment every slider-backed field gets, against the same authority
    # the panel reads — a hand-edited preset cannot hand the force law a
    # crowding strength the slider could never produce.
    var node = toJson(defaultPreset())
    node["settings"]["crowdingStrength"] = %99.0
    check validate(node).preset.settings.crowdingStrength ==
      CROWDING_STRENGTH_MAX
    node["settings"]["crowdingStrength"] = %(-4.0)
    check validate(node).preset.settings.crowdingStrength ==
      CROWDING_STRENGTH_MIN

  test "a matrix authored at the old [-1, 1] clamps into the served bounds":
    # The one stored-data change this schema makes: the attraction range is
    # an order of magnitude gentler, and an old preset's contrasts compress
    # into it rather than rejecting the file.
    var node = toJson(defaultPreset())
    node["matrix"].elems[0] = %1.0
    node["matrix"].elems[1] = %(-1.0)
    node["matrix"].elems[2] = %0.5
    let loaded = validate(node)
    check loaded.isOk
    check loaded.preset.matrix[0] == MATRIX_MAX_VALUE
    check loaded.preset.matrix[1] == MATRIX_MIN_VALUE
    check loaded.preset.matrix[2] == MATRIX_MAX_VALUE

  test "an out-of-range fluid scale clamps instead of rejecting":
    # Same treatment every slider-backed field gets. The floor matters more
    # here than elsewhere: a hand-edited zero would divide by zero in both SPH
    # kernel normalizations, and clamping to SPH_RADIUS_FRACTION_MIN is what
    # keeps that value out of the shader.
    var node = toJson(defaultPreset())
    node["settings"]["sphRadiusFraction"] = %4.0
    check validate(node).preset.settings.sphRadiusFraction ==
      SPH_RADIUS_FRACTION_MAX
    node["settings"]["sphRadiusFraction"] = %0.0
    check validate(node).preset.settings.sphRadiusFraction ==
      SPH_RADIUS_FRACTION_MIN

  test "out-of-range glow knobs clamp instead of rejecting":
    var node = toJson(defaultPreset())
    node["settings"]["glowRadiusScale"] = %99.0
    node["settings"]["glowFalloff"] = %(-1.0)
    node["settings"]["glowWarmth"] = %2.0
    let loaded = validate(node)
    check loaded.isOk
    check loaded.preset.settings.glowRadiusScale == GLOW_RADIUS_SCALE_MAX
    check loaded.preset.settings.glowFalloff == GLOW_FALLOFF_MIN
    check loaded.preset.settings.glowWarmth == GLOW_WARMTH_MAX

suite "Preset Round-Trip Contract":
  test "default preset survives serialize then parse unchanged":
    let original = defaultPreset()
    let loaded = parsePreset(toJsonString(original))
    check loaded.isOk
    check loaded.preset == original

  test "a fully custom preset survives round-trip unchanged":
    var customPreset = defaultPreset()
    customPreset.name = "My Garden"
    customPreset.createdAt = "2026-07-19T12:00:00Z"
    customPreset.settings.particleCount = 32000
    customPreset.settings.speciesCount = 6
    customPreset.settings.interactionRadius = 80
    customPreset.settings.forceStrength = 2.5
    customPreset.settings.crowdingStrength = 1.25
    customPreset.settings.friction = 0.12
    customPreset.settings.ruleWildness = 0.45
    customPreset.settings.timeScale = 1.5
    customPreset.settings.particleSize = 5
    customPreset.settings.trails = true
    customPreset.settings.trailLength = 0.8
    customPreset.settings.glowIntensity = 2.0
    customPreset.settings.velocityGlowScale = 2.5
    customPreset.settings.maxVelocity = 75.0
    customPreset.settings.repulsionEnd = 0.3
    customPreset.settings.attractionPeak = 0.9
    customPreset.settings.forceModel = 1
    customPreset.settings.expRepulsionAlpha = 10.0
    customPreset.settings.expAttractionBeta = 7.5
    customPreset.settings.glowRadiusScale = 5.0
    customPreset.settings.glowFalloff = 9.0
    customPreset.settings.glowWarmth = 0.7
    customPreset.settings.sphRestDensity = 2.0
    customPreset.settings.sphStiffness = 20.0
    customPreset.settings.sphRadiusFraction = 0.35
    customPreset.settings.sphViscosity = 0.5
    customPreset.settings.sphSubsteps = 2
    customPreset.settings.rdFeed = 0.045
    customPreset.settings.rdKill = 0.058
    customPreset.settings.rdDeposit = 0.035
    customPreset.settings.rdFieldForce = 8.0
    customPreset.settings.bloomEnabled = true
    customPreset.settings.bloomIntensity = 1.8
    customPreset.settings.exposure = 1.4
    customPreset.settings.saturation = 1.3
    customPreset.settings.contrast = 1.2
    customPreset.settings.temperature = -0.4
    for matrixIndex in 0 ..< MATRIX_LEN:
      customPreset.matrix[matrixIndex] =
        (if matrixIndex mod 2 == 0: 0.05 else: -0.05)
    # Every slot a distinct in-band triple, filled by formula so the fixture
    # does not pin the species ceiling.
    for slot in 0 ..< preset.MAX_SPECIES:
      let base = slot.float / (preset.MAX_SPECIES * 4).float
      customPreset.palette[slot] = [base, base + 0.1, base + 0.2]

    let loaded = parsePreset(toJsonString(customPreset))
    check loaded.isOk
    check loaded.preset == customPreset

  test "serialized preset is valid JSON carrying the documented top-level keys":
    let node = toJson(defaultPreset())
    check node.kind == JObject
    for key in ["schemaVersion", "name", "createdAt", "settings", "matrix",
        "chemistry", "palette"]:
      check node.hasKey(key)
    check node["matrix"].kind == JArray
    check node["matrix"].len == MATRIX_LEN
    check node["chemistry"].kind == JArray
    check node["chemistry"].len == CHEMISTRY_LEN
    check node["palette"].kind == JArray
    check node["palette"].len == preset.MAX_SPECIES

  test "a saved preset names no mode":
    ## There is one world, so a preset is a point in it rather than a
    ## selection among worlds. A `mode` key on the wire is a world type under a
    ## label, and every reader then has to decide what it means.
    check not toJson(defaultPreset()).hasKey("mode")

suite "The Force Weather Survives A Preset":
  test "a saved force weather round-trips its switch and its speed":
    var saved = defaultPreset()
    saved.settings.forceWeather = true
    saved.settings.forceWeatherSpeed = 1.25
    let loaded = parsePreset(toJsonString(saved))
    check loaded.isOk
    check loaded.preset.settings.forceWeather
    check loaded.preset.settings.forceWeatherSpeed == 1.25

  test "a force weather speed outside the range clamps on the way in":
    let tooFast = validate(%*{
      "schemaVersion": CURRENT_SCHEMA_VERSION,
      "settings": {"forceWeatherSpeed": FORCE_WEATHER_SPEED_MAX + 10.0}})
    check tooFast.preset.settings.forceWeatherSpeed == FORCE_WEATHER_SPEED_MAX
    let tooSlow = validate(%*{
      "schemaVersion": CURRENT_SCHEMA_VERSION,
      "settings": {"forceWeatherSpeed": FORCE_WEATHER_SPEED_MIN - 10.0}})
    check tooSlow.preset.settings.forceWeatherSpeed == FORCE_WEATHER_SPEED_MIN

  test "a preset saved before the force weather existed loads it switched off":
    # NOT A PINNED LEGACY BRANCH, and the distinction is the point. Off is both
    # the shipped default and the state every older world was running, so the
    # default alone preserves them — unlike crowdingStrength, whose non-zero
    # default would otherwise reach back and change a saved world. A v1 case for
    # these two would assert nothing.
    let older = validate(%*{
      "schemaVersion": 1, "mode": "particle-life",
      "settings": {"forceStrength": 1.5}})
    check not older.preset.settings.forceWeather
    check older.preset.settings.forceWeatherSpeed == FORCE_WEATHER_DEFAULT_SPEED


suite "Preset Schema Version Contract":
  test "a preset claiming a newer schemaVersion is rejected":
    ## Guessing at unknown future fields risks silently corrupting user intent
    let node = %*{
      "schemaVersion": CURRENT_SCHEMA_VERSION + 1,
      "name": "From the future",
      "mode": "particle-life"
    }
    let result = validate(node)
    check result.errorKind == pekNewerSchemaVersion
    check not result.isOk
    check result.errorMessage.len > 0

  test "rejection still returns a safe usable default preset":
    let node = %*{"schemaVersion": CURRENT_SCHEMA_VERSION + 100}
    let result = validate(node)
    check result.preset == defaultPreset()

  test "a preset at exactly the current schemaVersion is accepted":
    let node = %*{"schemaVersion": CURRENT_SCHEMA_VERSION}
    let result = validate(node)
    check result.isOk

  test "a missing schemaVersion is treated as the current version, not rejected":
    ## Absence degrades to "assume compatible", matching the module's
    ## defaulting stance for every other missing field
    let node = %*{"name": "No version field"}
    let result = validate(node)
    check result.isOk
    check result.preset.schemaVersion == CURRENT_SCHEMA_VERSION

  test "a non-integer schemaVersion is treated as the current version, not rejected":
    let node = %*{"schemaVersion": "not a number"}
    let result = validate(node)
    check result.isOk

suite "Preset Malformed Input Contract":
  test "unparseable JSON text never raises, and is reported as invalid":
    let result = parsePreset("{not: valid json,,,")
    check result.errorKind == pekInvalidJson
    check result.preset == defaultPreset()

  test "empty string input never raises, and is reported as invalid":
    let result = parsePreset("")
    check result.errorKind == pekInvalidJson

  test "structurally invalid JSON text is rejected outright: isOk false with a non-empty error":
    ## "not JSON at all" is a structural error (pekInvalidJson) and never
    ## returns isOk == true. This is distinct from a wrong-typed field
    ## inside an otherwise well-formed JSON object, which defaults/clamps
    ## per-field and stays isOk == true (see "wrong-typed scalar fields
    ## default rather than crash" below) — the schema's documented
    ## validation-first, never-silently-corrupt-but-still-usable stance.
    let result = parsePreset("not json at all")
    check not result.isOk
    check result.errorMessage.len > 0

  test "a JSON array root (not an object) is reported as invalid":
    let result = parsePreset("[1, 2, 3]")
    check result.errorKind == pekInvalidJson

  test "a JSON scalar root is reported as invalid":
    let result = parsePreset("\"just a string\"")
    check result.errorKind == pekInvalidJson

  test "wrong-typed scalar fields default rather than crash":
    let node = %*{
      "schemaVersion": CURRENT_SCHEMA_VERSION,
      "settings": {
        "particleCount": "sixteen thousand",
        "friction": true,
        "trails": "yes"
      }
    }
    let result = validate(node)
    check result.isOk
    check result.preset.settings.particleCount == defaultSettings().particleCount
    check result.preset.settings.friction == defaultSettings().friction
    check result.preset.settings.trails == defaultSettings().trails

  test "a completely empty object degrades to the full default preset":
    let result = validate(%*{})
    check result.isOk
    check result.preset.name == DEFAULT_PRESET_NAME
    check result.preset.settings == defaultSettings()
    check result.preset.matrix == defaultMatrix()
    check result.preset.chemistry == defaultChemistry()
    check result.preset.palette == DEFAULT_PALETTE

  test "a matrix that is not an array defaults to the neutral matrix":
    let node = %*{"matrix": "not an array"}
    let result = validate(node)
    check result.preset.matrix == defaultMatrix()

  test "a short matrix array fills missing entries with 0.0":
    let node = %*{"matrix": [0.05, -0.05]}
    let result = validate(node)
    check result.preset.matrix[0] == 0.05
    check result.preset.matrix[1] == -0.05
    check result.preset.matrix[2] == 0.0
    check result.preset.matrix[MATRIX_LEN - 1] == 0.0

  test "a non-numeric matrix entry defaults that slot to 0.0 without discarding the rest":
    let node = %*{"matrix": ["oops", 0.07]}
    let result = validate(node)
    check result.preset.matrix[0] == 0.0
    check result.preset.matrix[1] == 0.07

  test "a malformed palette entry falls back to that species' default color":
    let node = %*{"palette": [[0.9, 0.9, 0.9], "not a color"]}
    let result = validate(node)
    check result.preset.palette[0] == [0.9, 0.9, 0.9]
    check result.preset.palette[1] == DEFAULT_PALETTE[1]

  test "a malformed chemistry array falls back per slot without discarding the rest":
    let node = %*{"chemistry": [0.5, "oops"]}
    let result = validate(node)
    check result.preset.chemistry[0] == 0.5
    check result.preset.chemistry[1] == defaultChemistry()[1]
    check result.preset.chemistry[2] == defaultChemistry()[2]

  test "chemistry clamps each channel against its own asymmetric bound":
    ## Tropism's ceiling sits below the magnitude of its floor, so
    ## the two channels cannot share one clamp. A hand-edited preset asking for
    ## strong positive tropism comes back to the bound rather than landing raw
    ## in the uniform.
    let node = %*{"chemistry": [5.0, 5.0, -5.0, -5.0]}
    let result = validate(node)
    check result.preset.chemistry[0] == SECRETION_MAX
    check result.preset.chemistry[1] == TROPISM_MAX
    check result.preset.chemistry[2] == SECRETION_MIN
    check result.preset.chemistry[3] == TROPISM_MIN


suite "A Legacy Preset Loads As The World It Described":
  # The mechanism is translation, not subtraction, and these tests make the
  # difference observable. A v1 file carries a value for every scalar, including
  # the couplings its mode hides, so treating an absent strength as zero does
  # nothing at all — nothing is absent — and the hidden defaults switch their
  # couplings on.

  func v1Preset(mode: string): JsonNode =
    ## A v1 file: a mode id, and a value for every scalar whether or not that
    ## mode reads it.
    %*{
      "schemaVersion": 1,
      "name": "Saved before the merge",
      "mode": mode,
      "settings": {
        "forceStrength": 1.5,
        "sphStiffness": 12.0,
        "rdDeposit": 0.02,
        "rdFieldForce": 30.0
      }
    }

  test "a legacy particle-life preset does NOT switch chemistry on":
    ## This file carries deposit 0.02 and field force 30 from sliders sitting
    ## at their defaults behind a mode that hides them. A world with no
    ## chemistry must not acquire it on reopening.
    let result = validate(v1Preset("particle-life"))
    check result.isOk
    check result.preset.settings.rdDeposit == 0.0
    check result.preset.settings.rdFieldForce == 0.0

  test "a legacy preset keeps the strengths its mode did use":
    let result = validate(v1Preset("particle-life"))
    check result.preset.settings.forceStrength == 1.5

  test "a legacy preset zeroes the strengths its mode excluded":
    let sph = validate(v1Preset("sph"))
    check sph.preset.settings.forceStrength == 0.0
    check sph.preset.settings.rdDeposit == 0.0
    check sph.preset.settings.rdFieldForce == 0.0
    let rd = validate(v1Preset("reaction-diffusion"))
    check rd.preset.settings.forceStrength == 0.0
    check rd.preset.settings.rdDeposit == 0.02
    # Rescaled, not carried over: the v1 file's 30 was written against a field
    # grid ten times coarser, where it meant the same motion through the pattern
    # that 3 means here. See preset.V1_FIELD_FORCE_SCALE.
    check rd.preset.settings.rdFieldForce == 30.0 * V1_FIELD_FORCE_SCALE

  test "a legacy sph preset arrives with its fluid acting":
    ## v1 has no fluidStrength field at all, so this is derived rather than
    ## read: an "sph" preset described a world running its fluid, and every
    ## other v1 world ran none.
    check validate(v1Preset("sph")).preset.settings.fluidStrength == 1.0
    check validate(v1Preset("particle-life")).preset.settings.fluidStrength == 0.0
    check validate(
      v1Preset("reaction-diffusion")).preset.settings.fluidStrength == 0.0

  test "a preset saved before this change applies with crowding strength zero":
    ## Crowding did not exist when a v1 file was written, so no v1 world was ever
    ## tuned against it. The v1 branch pins the strength to zero rather than
    ## letting it default, which is what stops the shipped default — measured
    ## later, and non-zero — from reaching back and adding a term to a world
    ## someone saved without one.
    ##
    ## The fixture carries a crowding strength on purpose. Pinning that a value
    ## the file DOES hold still decodes to zero is what makes this able to fail:
    ## a fixture without the field would pass with or without the pin, for as
    ## long as the shipped default happened to be zero.
    for mode in ["particle-life", "sph", "reaction-diffusion", "some-future-mode"]:
      var legacy = v1Preset(mode)
      legacy["settings"]["crowdingStrength"] = %2.0
      checkpoint("legacy mode " & mode)
      check validate(legacy).preset.settings.crowdingStrength == 0.0

  test "a preset saved before this change applies with fraction 1.0":
    ## The smoothing radius was the whole interaction radius when a v1 file was
    ## written, so that is the kernel the world it describes ran. The v1
    ## branch pins the fraction to 1.0 rather than letting it default, which is
    ## what stops the shipped default — measured later, and below 1 —
    ## from rescaling a fluid someone already watched.
    ##
    ## The fixture carries a fraction on purpose, for the reason the crowding
    ## test above carries a strength: pinning that a value the file DOES hold
    ## still decodes to 1.0 is what makes this able to fail, where a fixture
    ## without the key would pass for as long as the default happened to be 1.
    for mode in ["particle-life", "sph", "reaction-diffusion",
        "some-future-mode"]:
      var legacy = v1Preset(mode)
      legacy["settings"]["sphRadiusFraction"] = %0.2
      checkpoint("legacy mode " & mode)
      check validate(legacy).preset.settings.sphRadiusFraction == 1.0
      check validate(legacy).preset.settings.sphRadiusFraction ==
        SPH_RADIUS_FRACTION_MAX

  test "an unrecognised legacy mode keeps what it carries rather than emptying":
    ## Forward-compatible in the same spirit v1's free-form `mode` field was: a
    ## preset from a build this one does not know about loads as the world it
    ## describes, rather than being emptied by a table lookup that missed.
    let result = validate(v1Preset("some-future-mode"))
    check result.isOk
    check result.preset.settings.forceStrength == 1.5
    check result.preset.settings.rdDeposit == 0.02

  test "a current-schema preset applies exactly the strengths it carries":
    ## No translation, no mode consulted. What the file says is what loads.
    let node = %*{
      "schemaVersion": CURRENT_SCHEMA_VERSION,
      "settings": {
        "forceStrength": 0.5,
        "fluidStrength": 0.25,
        "rdDeposit": 0.01,
        "rdFieldForce": 10.0
      }
    }
    let result = validate(node)
    check result.preset.settings.forceStrength == 0.5
    check result.preset.settings.fluidStrength == 0.25
    check result.preset.settings.rdDeposit == 0.01
    check result.preset.settings.rdFieldForce == 10.0

  test "a current-schema preset carrying a stray mode key ignores it":
    ## Belt and braces: the mode table is reachable only from the v1 branch, so
    ## a `mode` key at the current version must not translate anything.
    let node = %*{
      "schemaVersion": CURRENT_SCHEMA_VERSION,
      "mode": "sph",
      "settings": {"forceStrength": 1.5, "rdDeposit": 0.02}
    }
    let result = validate(node)
    check result.preset.settings.forceStrength == 1.5
    check result.preset.settings.rdDeposit == 0.02

  test "translated strengths still pass through the ordinary clamp":
    ## The translation writes onto the settings node and lets validateSettings
    ## run, so a v1 file with an out-of-range value cannot use the v1
    ## branch as a second, unclamped way in.
    let node = %*{
      "schemaVersion": 1,
      "mode": "particle-life",
      "settings": {"forceStrength": 999.0}
    }
    let result = validate(node)
    check result.preset.settings.forceStrength == FORCE_STRENGTH_MAX

suite "Preset Clamp Behavior Contract":
  test "particleCount above the slider max clamps down to the max":
    let node = %*{"settings": {"particleCount": 999999999}}
    let result = validate(node)
    check result.preset.settings.particleCount == PARTICLE_COUNT_MAX

  test "particleCount below the slider min clamps up to the min":
    let node = %*{"settings": {"particleCount": -50}}
    let result = validate(node)
    check result.preset.settings.particleCount == PARTICLE_COUNT_MIN

  test "speciesCount clamps into [2, 8]":
    let tooLow = validate(%*{"settings": {"speciesCount": 0}})
    let tooHigh = validate(%*{"settings": {"speciesCount": 99}})
    check tooLow.preset.settings.speciesCount == SPECIES_COUNT_MIN
    check tooHigh.preset.settings.speciesCount == SPECIES_COUNT_MAX

  test "friction clamps into [0.01, 0.2]":
    let tooLow = validate(%*{"settings": {"friction": -1.0}})
    let tooHigh = validate(%*{"settings": {"friction": 100.0}})
    check tooLow.preset.settings.friction == FRICTION_MIN
    check tooHigh.preset.settings.friction == FRICTION_MAX

  test "an in-range value passes through clamp unchanged":
    let node = %*{"settings": {"forceStrength": 1.7}}
    let result = validate(node)
    check result.preset.settings.forceStrength == 1.7

  test "SPH settings clamp into their ranges and substeps cap at SPH_SUBSTEPS_MAX":
    let node = %*{"settings": {
      "sphRestDensity": 99.0,
      "sphStiffness": -5.0,
      "sphViscosity": 3.0,
      "sphSubsteps": 99
    }}
    let result = validate(node)
    check result.preset.settings.sphRestDensity == SPH_REST_DENSITY_MAX
    check result.preset.settings.sphStiffness == SPH_STIFFNESS_MIN
    check result.preset.settings.sphViscosity == SPH_VISCOSITY_MAX
    check result.preset.settings.sphSubsteps == SPH_SUBSTEPS_MAX

  test "a missing SPH field defaults rather than crashing":
    let result = validate(%*{"settings": {}})
    check result.preset.settings.sphRestDensity == defaultSettings().sphRestDensity
    check result.preset.settings.sphSubsteps == defaultSettings().sphSubsteps

  test "reaction-diffusion settings clamp into their ranges":
    let node = %*{"settings": {
      "rdFeed": 99.0,
      "rdKill": -5.0,
      "rdDeposit": 99.0,
      "rdFieldForce": -5.0
    }}
    let result = validate(node)
    check result.preset.settings.rdFeed == RD_FEED_MAX
    check result.preset.settings.rdKill == RD_KILL_MIN
    check result.preset.settings.rdDeposit == RD_DEPOSIT_MAX
    check result.preset.settings.rdFieldForce == RD_FIELD_FORCE_MIN

  test "a missing reaction-diffusion field defaults rather than crashing":
    # A preset carrying neither of the two coupling knobs still loads: no schema
    # bump covers their absence, and validateSettings supplies the default for
    # any absent field.
    let result = validate(%*{"settings": {}})
    check result.preset.settings.rdFeed == defaultSettings().rdFeed
    check result.preset.settings.rdKill == defaultSettings().rdKill
    check result.preset.settings.rdDeposit == defaultSettings().rdDeposit
    check result.preset.settings.rdFieldForce == defaultSettings().rdFieldForce

  test "bloom and grade settings clamp into their ranges":
    let node = %*{"settings": {
      "bloomIntensity": 99.0,
      "exposure": -5.0,
      "saturation": 99.0,
      "contrast": -5.0,
      "temperature": 99.0
    }}
    let result = validate(node)
    check result.preset.settings.bloomIntensity == BLOOM_INTENSITY_MAX
    check result.preset.settings.exposure == EXPOSURE_MIN
    check result.preset.settings.saturation == SATURATION_MAX
    check result.preset.settings.contrast == CONTRAST_MIN
    check result.preset.settings.temperature == TEMPERATURE_MAX

  test "a missing bloom field defaults rather than crashing":
    ## A preset missing the bloom fields entirely falls back to the defaults
    ## on load without a schema bump.
    let result = validate(%*{"settings": {}})
    check result.preset.settings.bloomEnabled == defaultSettings().bloomEnabled
    check result.preset.settings.exposure == defaultSettings().exposure

  test "matrix values clamp into the served band":
    var arr = newSeq[float](MATRIX_LEN)
    arr[0] = 5.0
    arr[1] = -5.0
    let node = %*{"matrix": arr}
    let result = validate(node)
    check result.preset.matrix[0] == MATRIX_MAX_VALUE
    check result.preset.matrix[1] == MATRIX_MIN_VALUE

  test "palette channel values clamp into [0, 1]":
    let node = %*{"palette": [[2.0, -1.0, 0.5]]}
    let result = validate(node)
    check result.preset.palette[0] == [PALETTE_CHANNEL_MAX, PALETTE_CHANNEL_MIN, 0.5]

  test "the default preset's own settings already fall inside every clamp range":
    ## Validating the defaults must be a no-op; otherwise defaultPreset() and
    ## validate(toJson(defaultPreset())) would diverge
    let defaults = defaultSettings()
    check defaults.particleCount == clamp(defaults.particleCount, PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX)
    check defaults.speciesCount == clamp(defaults.speciesCount, SPECIES_COUNT_MIN, SPECIES_COUNT_MAX)
    check defaults.interactionRadius == clamp(defaults.interactionRadius, INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX)
    check defaults.forceStrength == clamp(defaults.forceStrength, FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX)
    check defaults.friction == clamp(defaults.friction, FRICTION_MIN, FRICTION_MAX)
    check defaults.ruleWildness == clamp(defaults.ruleWildness, RULE_WILDNESS_MIN, RULE_WILDNESS_MAX)
    check defaults.timeScale == clamp(defaults.timeScale, TIME_SCALE_MIN, TIME_SCALE_MAX)
    check defaults.particleSize == clamp(defaults.particleSize, PARTICLE_SIZE_MIN, PARTICLE_SIZE_MAX)
    check defaults.trailLength == clamp(defaults.trailLength, TRAIL_LENGTH_MIN, TRAIL_LENGTH_MAX)
    check defaults.glowIntensity == clamp(defaults.glowIntensity, GLOW_INTENSITY_MIN, GLOW_INTENSITY_MAX)
    check defaults.velocityGlowScale == clamp(defaults.velocityGlowScale, VELOCITY_GLOW_SCALE_MIN, VELOCITY_GLOW_SCALE_MAX)
    check defaults.maxVelocity == clamp(defaults.maxVelocity, MAX_VELOCITY_MIN, MAX_VELOCITY_MAX)
    check defaults.repulsionEnd == clamp(defaults.repulsionEnd, REPULSION_END_MIN, REPULSION_END_MAX)
    check defaults.attractionPeak == clamp(defaults.attractionPeak, ATTRACTION_PEAK_MIN, ATTRACTION_PEAK_MAX)
    check defaults.forceModel == clamp(defaults.forceModel, FORCE_MODEL_MIN, FORCE_MODEL_MAX)
    check defaults.expRepulsionAlpha == clamp(defaults.expRepulsionAlpha, EXP_REPULSION_ALPHA_MIN, EXP_REPULSION_ALPHA_MAX)
    check defaults.expAttractionBeta == clamp(defaults.expAttractionBeta, EXP_ATTRACTION_BETA_MIN, EXP_ATTRACTION_BETA_MAX)

suite "Preset Migration Hook Contract":
  test "migrate is the identity transform at the current version":
    let node = toJson(defaultPreset())
    let migrated = migrate(node, CURRENT_SCHEMA_VERSION)
    check migrated == node

  test "validate routes an older-versioned node through migrate before field validation":
    ## A pre-v1 preset (schemaVersion 0) proves the migrate hook is
    ## wired into the validate path rather than only defined. A v0-tagged node
    ## falls through the same steps a v1 node does and is then field-validated,
    ## so this pins the wiring each added migration step extends.
    ##
    ## The deposit assertion is what makes it non-vacuous: the fixture carries a
    ## nonzero rdDeposit behind a mode that hides chemistry, so a zero coming
    ## back proves the mode translation ran. A branch narrowed to exactly one
    ## version would leave the 0.02 standing and fail here.
    let fixture = %*{
      "schemaVersion": 0,
      "name": "Legacy Preset",
      "mode": "particle-life",
      "settings": {"particleCount": 20000, "rdDeposit": 0.02},
      "matrix": newSeq[float](MATRIX_LEN),
      "palette": DEFAULT_PALETTE
    }
    let result = validate(fixture)
    check result.isOk
    check result.preset.schemaVersion == CURRENT_SCHEMA_VERSION
    check result.preset.name == "Legacy Preset"
    check result.preset.settings.particleCount == 20000
    check result.preset.settings.rdDeposit == 0.0

  test "a negative schemaVersion still migrates and validates rather than rejecting":
    let node = %*{"schemaVersion": -1, "name": "Very old"}
    let result = validate(node)
    check result.isOk
    check result.preset.schemaVersion == CURRENT_SCHEMA_VERSION


suite "v2 -> v3 Matrix Restride":
  # Every schemaVersion <= 2 file stores its attraction matrix flattened
  # row-major at stride OLD_MAX_SPECIES. Reloaded at the wider stride without
  # remapping, old index 6 (row 1, col 0) would read as row 0, col 6 — the
  # matrix scrambles silently, since elemAt is nil-safe and just fills zeros
  # past the old tail. These pin the remap: old flat index i lands at
  # (i div OLD_MAX_SPECIES) * MAX_SPECIES + (i mod OLD_MAX_SPECIES), and
  # every slot in a new row or column stays 0 (neutral).

  proc strideSixMatrix(): seq[float] =
    ## 36 pairwise-distinct values, all inside the served band (±0.33), so a
    ## clamp cannot mask a misplaced slot.
    for oldIndex in 0 ..< OLD_MAX_SPECIES * OLD_MAX_SPECIES:
      result.add (oldIndex + 1).float * 0.005

  test "validate restrides a v2 matrix so every rule keeps its row and column":
    let old = strideSixMatrix()
    let node = %*{"schemaVersion": 2, "matrix": old}
    let result = validate(node)
    check result.isOk
    for oldIndex in 0 ..< old.len:
      let newIndex = (oldIndex div OLD_MAX_SPECIES) * preset.MAX_SPECIES +
        (oldIndex mod OLD_MAX_SPECIES)
      check result.preset.matrix[newIndex] == old[oldIndex]

  test "the new rows and columns of a restrided v2 matrix are neutral":
    let node = %*{"schemaVersion": 2, "matrix": strideSixMatrix()}
    let result = validate(node)
    for row in 0 ..< preset.MAX_SPECIES:
      for col in 0 ..< preset.MAX_SPECIES:
        if row >= OLD_MAX_SPECIES or col >= OLD_MAX_SPECIES:
          check result.preset.matrix[row * preset.MAX_SPECIES + col] == 0.0

  test "a v1 file falls through the mode translation and the restride in one call":
    # The migrate ladder falls through, so a v1 file gets both the coupling
    # translation (rdDeposit zeroed behind a particle-life mode) and the
    # matrix restride. Old slot 6 is row 1 col 0; it must land at the new
    # row 1 col 0 rather than staying at flat index 6 (row 0, col 6).
    let node = %*{
      "schemaVersion": 1,
      "mode": "particle-life",
      "settings": {"rdDeposit": 0.02},
      "matrix": strideSixMatrix()
    }
    let result = validate(node)
    check result.isOk
    check result.preset.settings.rdDeposit == 0.0
    check result.preset.matrix[preset.MAX_SPECIES] == 7.0 * 0.005
    check result.preset.matrix[6] == 0.0

  test "a v2 file without a matrix still loads with the neutral default":
    let result = validate(%*{"schemaVersion": 2, "name": "No matrix"})
    check result.isOk
    for value in result.preset.matrix:
      check value == 0.0

  test "chemistry and palette are indexed per species slot and need no restride":
    # Six entries fill the first six slots; the two new slots repair with each
    # slot's own default, exactly as a current-version file missing them would.
    var chemistry: seq[float]
    for slot in 0 ..< OLD_MAX_SPECIES * 2:
      chemistry.add 0.5
    let node = %*{"schemaVersion": 2, "chemistry": chemistry}
    let result = validate(node)
    check result.isOk
    for slot in 0 ..< OLD_MAX_SPECIES * 2:
      check result.preset.chemistry[slot] == 0.5
    let defaults = defaultChemistry()
    for slot in OLD_MAX_SPECIES * 2 ..< CHEMISTRY_LEN:
      check result.preset.chemistry[slot] == defaults[slot]


suite "v3 -> v4 Matrix Restride":
  # v3 raised the ceiling to 8 and v4 raises it to 12, by the same mechanism.
  # The stride a v3 file was written at is spelled here as a literal rather
  # than read from preset.nim, so the fixture stays an independent oracle: if
  # the migration's own idea of the old stride drifts, these fail.
  const V3_STRIDE = 8

  proc strideEightMatrix(): seq[float] =
    ## 64 pairwise-distinct values, all inside the served band (±0.33), so a
    ## clamp cannot mask a misplaced slot.
    for oldIndex in 0 ..< V3_STRIDE * V3_STRIDE:
      result.add (oldIndex + 1).float * 0.004

  test "validate restrides a v3 matrix so every rule keeps its row and column":
    let old = strideEightMatrix()
    let result = validate(%*{"schemaVersion": 3, "matrix": old})
    check result.isOk
    for oldIndex in 0 ..< old.len:
      let newIndex = (oldIndex div V3_STRIDE) * preset.MAX_SPECIES +
        (oldIndex mod V3_STRIDE)
      check result.preset.matrix[newIndex] == old[oldIndex]

  test "the new rows and columns of a restrided v3 matrix are neutral":
    let result = validate(%*{"schemaVersion": 3, "matrix": strideEightMatrix()})
    for row in 0 ..< preset.MAX_SPECIES:
      for col in 0 ..< preset.MAX_SPECIES:
        if row >= V3_STRIDE or col >= V3_STRIDE:
          check result.preset.matrix[row * preset.MAX_SPECIES + col] == 0.0

  test "a v2 file restrides once through each step rather than twice through one":
    # The ladder falls through, so a v2 matrix crosses two restrides: 6 -> 8
    # then 8 -> 12. Composed, old flat index i must still land at
    # (i div 6) * 12 + (i mod 6). A v3 branch that restrided straight to 12
    # would scramble here, because the v4 branch would then read a 12-stride
    # array as an 8-stride one.
    var old: seq[float]
    for oldIndex in 0 ..< OLD_MAX_SPECIES * OLD_MAX_SPECIES:
      old.add (oldIndex + 1).float * 0.005
    let result = validate(%*{"schemaVersion": 2, "matrix": old})
    check result.isOk
    for oldIndex in 0 ..< old.len:
      let newIndex = (oldIndex div OLD_MAX_SPECIES) * preset.MAX_SPECIES +
        (oldIndex mod OLD_MAX_SPECIES)
      check result.preset.matrix[newIndex] == old[oldIndex]

  test "a v3 file without a matrix still loads with the neutral default":
    let result = validate(%*{"schemaVersion": 3, "name": "No matrix"})
    check result.isOk
    for value in result.preset.matrix:
      check value == 0.0

  test "a v3 file's chemistry and palette extend by per-slot repair":
    # Species-major with a fixed per-species stride, so the four new slots take
    # each slot's own default exactly as a current-version file missing them
    # would. Nothing restrides.
    var chemistry: seq[float]
    for slot in 0 ..< V3_STRIDE * 2:
      chemistry.add 0.5
    let result = validate(%*{"schemaVersion": 3, "chemistry": chemistry})
    check result.isOk
    for slot in 0 ..< V3_STRIDE * 2:
      check result.preset.chemistry[slot] == 0.5
    let defaults = defaultChemistry()
    for slot in V3_STRIDE * 2 ..< CHEMISTRY_LEN:
      check result.preset.chemistry[slot] == defaults[slot]


# The stiffness a preset carries is stored absolutely and clamped at load
# against the envelope, exactly as every other field is. What the fluid can
# honour of it depends on the radius fraction and substeps that same preset
# carries, and that bound applies only where the value takes effect — after
# the apply lands, from the final state, never during the apply. That is why
# presetApplySteps needs no ordering among scalars: it writes every scalar in
# one pass (src/ui/presets/preset_store_core.nim).

suite "A Preset's Stiffness Survives A Fluid That Cannot Hold It":
  test "a preset carrying envelope-max stiffness with a narrow kernel round-trips intact":
    var customPreset = defaultPreset()
    customPreset.settings.sphStiffness = SPH_STIFFNESS_MAX
    customPreset.settings.sphRadiusFraction = SPH_RADIUS_FRACTION_MIN
    customPreset.settings.sphSubsteps = SPH_SUBSTEPS_MIN
    let loaded = parsePreset(toJsonString(customPreset))
    check loaded.isOk
    # Stored, not effective: the load clamps against the envelope and nothing
    # else, so the number the user saved is the number that comes back.
    check loaded.preset.settings.sphStiffness == SPH_STIFFNESS_MAX
    check loaded.preset.settings.sphRadiusFraction == SPH_RADIUS_FRACTION_MIN

  test "the fluid that preset describes runs at its own ceiling":
    # The other half of the same claim, taken through the state the apply
    # produces rather than through the wire: the effective stiffness is what
    # this preset's own fraction and substeps imply, and the stored one is
    # still the envelope maximum.
    var customPreset = defaultPreset()
    customPreset.settings.sphStiffness = SPH_STIFFNESS_MAX
    customPreset.settings.sphRadiusFraction = SPH_RADIUS_FRACTION_MIN
    customPreset.settings.sphSubsteps = SPH_SUBSTEPS_MIN
    let settings = parsePreset(toJsonString(customPreset)).preset.settings

    var applied = initSimulationState()
    applied.sphStiffness = settings.sphStiffness
    applied.sphRadiusFraction = settings.sphRadiusFraction
    applied.sphSubsteps = settings.sphSubsteps
    applied.interactionRadius = settings.interactionRadius
    applied.timeScale = settings.timeScale

    let ceiling = evaluateCeiling(pcStableStiffness, ceilingInputs(applied))
    check effectiveSimulation(applied).sphStiffness == ceiling
    check ceiling < SPH_STIFFNESS_MAX
    check applied.sphStiffness == SPH_STIFFNESS_MAX

  test "a preset saved from a narrow-kernel world does not bake in that ceiling":
    # What reading the mirrored value into a snapshot would cost: re-saving a
    # world would ratchet its stiffness down every time. The snapshot takes the
    # stored record, so a round trip through the effective state changes
    # nothing.
    var applied = initSimulationState()
    applied.sphStiffness = SPH_STIFFNESS_MAX
    applied.sphRadiusFraction = SPH_RADIUS_FRACTION_MIN
    discard effectiveSimulation(applied)
    check applied.sphStiffness == SPH_STIFFNESS_MAX
