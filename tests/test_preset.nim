# ==============================================================================
# PARTICLE GARDEN - PRESET SCHEMA TESTS
# ==============================================================================
#
# Behavioral tests for src/preset.nim: the versioned preset serialization
# contract. Covers round-trip fidelity, newer-schema-version rejection,
# clamp/default degradation of hostile input, and the migrate hook.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import std/json
import ../src/memory_layout
import ../src/preset

const PRESET_TESTS_LOADED* = true

# ==============================================================================
# CLAMP BOUNDS TRACK THE LIVE SLIDER REGISTRATIONS
# ==============================================================================

suite "Clamp Bounds Are The Live Slider Ranges":
  # STRUCTURE: preset.nim re-exports config_ranges.nim, the same module
  # ui.nim's configSlider registrations read — so preset bounds and UI ranges
  # agree by construction, not by mirrored literals. What remains testable
  # here are the relations between independent sources.

  test "the particle ceiling is the buffer allocation limit, not a stale UI copy":
    # The bug this replaces: preset bounds pinned to dead web/index.html
    # attributes (a 64000 ceiling against a live 128000 slider).
    check PARTICLE_COUNT_MAX == memory_layout.MAX_PARTICLES

  test "the species ceiling equals the preset's own array sizing":
    check SPECIES_COUNT_MAX == preset.MAX_SPECIES

  test "every documented default lies inside its own clamp range":
    let defaults = defaultSettings()
    check defaults.particleCount == clamp(defaults.particleCount, PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX)
    check defaults.glowRadiusScale == clamp(defaults.glowRadiusScale, GLOW_RADIUS_SCALE_MIN, GLOW_RADIUS_SCALE_MAX)
    check defaults.glowFalloff == clamp(defaults.glowFalloff, GLOW_FALLOFF_MIN, GLOW_FALLOFF_MAX)
    check defaults.glowWarmth == clamp(defaults.glowWarmth, GLOW_WARMTH_MIN, GLOW_WARMTH_MAX)

  test "glow knob defaults mirror config.nim's createConfig":
    let defaults = defaultSettings()
    check defaults.glowRadiusScale == 3.0
    check defaults.glowFalloff == 6.0
    check defaults.glowWarmth == 0.4

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

# ==============================================================================
# ROUND-TRIP CONTRACT
# ==============================================================================

suite "Preset Round-Trip Contract":
  test "default preset survives serialize then parse unchanged":
    ## CONTRACT: toJson -> toJsonString -> parsePreset reproduces the same preset
    ## WHY: This is the save/load contract every future preset_store call depends on
    let original = defaultPreset()
    let loaded = parsePreset(toJsonString(original))
    check loaded.isOk
    check loaded.preset == original

  test "a fully custom preset survives round-trip unchanged":
    ## CONTRACT: Non-default values for every field round-trip exactly
    var customPreset = defaultPreset()
    customPreset.name = "My Garden"
    customPreset.createdAt = "2026-07-19T12:00:00Z"
    customPreset.mode = "particle-life"
    customPreset.settings.particleCount = 32000
    customPreset.settings.speciesCount = 6
    customPreset.settings.interactionRadius = 80
    customPreset.settings.forceStrength = 2.5
    customPreset.settings.friction = 0.12
    customPreset.settings.ruleTemperature = 0.45
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
    for matrixIndex in 0 ..< MATRIX_LEN:
      customPreset.matrix[matrixIndex] =
        (if matrixIndex mod 2 == 0: 0.5 else: -0.5)
    customPreset.palette = [
      [0.1, 0.2, 0.3], [0.4, 0.5, 0.6], [0.7, 0.8, 0.9],
      [0.15, 0.25, 0.35], [0.45, 0.55, 0.65], [0.75, 0.85, 0.95]
    ]

    let loaded = parsePreset(toJsonString(customPreset))
    check loaded.isOk
    check loaded.preset == customPreset

  test "serialized preset is valid JSON carrying the documented top-level keys":
    ## CONTRACT: the wire shape is {schemaVersion, name, createdAt, mode, settings, matrix, palette}
    let node = toJson(defaultPreset())
    check node.kind == JObject
    for key in ["schemaVersion", "name", "createdAt", "mode", "settings", "matrix", "palette"]:
      check node.hasKey(key)
    check node["matrix"].kind == JArray
    check node["matrix"].len == MATRIX_LEN
    check node["palette"].kind == JArray
    check node["palette"].len == preset.MAX_SPECIES

# ==============================================================================
# SCHEMA VERSION CONTRACT
# ==============================================================================

suite "Preset Schema Version Contract":
  test "a preset claiming a newer schemaVersion is rejected":
    ## CONTRACT: validate refuses to interpret fields from a schema it postdates
    ## WHY: guessing at unknown future fields risks silently corrupting user intent
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
    ## CONTRACT: even a rejected load never leaves the caller without a valid Preset
    let node = %*{"schemaVersion": CURRENT_SCHEMA_VERSION + 100}
    let result = validate(node)
    check result.preset == defaultPreset()

  test "a preset at exactly the current schemaVersion is accepted":
    let node = %*{"schemaVersion": CURRENT_SCHEMA_VERSION}
    let result = validate(node)
    check result.isOk

  test "a missing schemaVersion is treated as the current version, not rejected":
    ## BEHAVIORAL: absence degrades to "assume compatible", matching the
    ## module's defaulting stance for every other missing field
    let node = %*{"name": "No version field"}
    let result = validate(node)
    check result.isOk
    check result.preset.schemaVersion == CURRENT_SCHEMA_VERSION

  test "a non-integer schemaVersion is treated as the current version, not rejected":
    let node = %*{"schemaVersion": "not a number"}
    let result = validate(node)
    check result.isOk

# ==============================================================================
# MALFORMED INPUT CONTRACT
# ==============================================================================

suite "Preset Malformed Input Contract":
  test "unparseable JSON text never raises, and is reported as invalid":
    ## CONTRACT: parsePreset on garbage text degrades to a typed error, never an unhandled exception
    let result = parsePreset("{not: valid json,,,")
    check result.errorKind == pekInvalidJson
    check result.preset == defaultPreset()

  test "empty string input never raises, and is reported as invalid":
    let result = parsePreset("")
    check result.errorKind == pekInvalidJson

  test "structurally invalid JSON text is rejected outright: isOk false with a non-empty error":
    ## CONTRACT: "not JSON at all" is a structural error (pekInvalidJson) and
    ## never returns isOk == true. This is distinct from a wrong-typed FIELD
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
    ## CONTRACT: a string where a number is expected degrades to the field default
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
    check result.preset.mode == DEFAULT_MODE
    check result.preset.settings == defaultSettings()
    check result.preset.matrix == defaultMatrix()
    check result.preset.palette == DEFAULT_PALETTE

  test "a matrix that is not an array defaults to the neutral matrix":
    let node = %*{"matrix": "not an array"}
    let result = validate(node)
    check result.preset.matrix == defaultMatrix()

  test "a short matrix array fills missing entries with 0.0":
    let node = %*{"matrix": [0.5, -0.5]}
    let result = validate(node)
    check result.preset.matrix[0] == 0.5
    check result.preset.matrix[1] == -0.5
    check result.preset.matrix[2] == 0.0
    check result.preset.matrix[MATRIX_LEN - 1] == 0.0

  test "a non-numeric matrix entry defaults that slot to 0.0 without discarding the rest":
    let node = %*{"matrix": ["oops", 0.7]}
    let result = validate(node)
    check result.preset.matrix[0] == 0.0
    check result.preset.matrix[1] == 0.7

  test "a malformed palette entry falls back to that species' default color":
    let node = %*{"palette": [[0.9, 0.9, 0.9], "not a color"]}
    let result = validate(node)
    check result.preset.palette[0] == [0.9, 0.9, 0.9]
    check result.preset.palette[1] == DEFAULT_PALETTE[1]

  test "a missing mode defaults to particle-life":
    let result = validate(%*{})
    check result.preset.mode == DEFAULT_MODE

  test "an unrecognized mode string is preserved, not rejected":
    ## CONTRACT: mode is forward-compatible; a future SPH/RD preset must
    ## round-trip through this same v1 validator without a schema bump
    let node = %*{"mode": "sph"}
    let result = validate(node)
    check result.isOk
    check result.preset.mode == "sph"

  test "an empty-string mode defaults to particle-life":
    let node = %*{"mode": ""}
    let result = validate(node)
    check result.preset.mode == DEFAULT_MODE

# ==============================================================================
# CLAMP BEHAVIOR CONTRACT
# ==============================================================================

suite "Preset Clamp Behavior Contract":
  test "particleCount above the slider max clamps down to the max":
    let node = %*{"settings": {"particleCount": 999999999}}
    let result = validate(node)
    check result.preset.settings.particleCount == PARTICLE_COUNT_MAX

  test "particleCount below the slider min clamps up to the min":
    let node = %*{"settings": {"particleCount": -50}}
    let result = validate(node)
    check result.preset.settings.particleCount == PARTICLE_COUNT_MIN

  test "speciesCount clamps into [2, 6]":
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

  test "matrix values clamp into [-1, 1]":
    var arr = newSeq[float](MATRIX_LEN)
    arr[0] = 5.0
    arr[1] = -5.0
    let node = %*{"matrix": arr}
    let result = validate(node)
    check result.preset.matrix[0] == MATRIX_VALUE_MAX
    check result.preset.matrix[1] == MATRIX_VALUE_MIN

  test "palette channel values clamp into [0, 1]":
    let node = %*{"palette": [[2.0, -1.0, 0.5]]}
    let result = validate(node)
    check result.preset.palette[0] == [PALETTE_CHANNEL_MAX, PALETTE_CHANNEL_MIN, 0.5]

  test "the default preset's own settings already fall inside every clamp range":
    ## DEFENSIVE: validating the defaults must be a no-op; otherwise
    ## defaultPreset() and validate(toJson(defaultPreset())) would diverge
    let defaults = defaultSettings()
    check defaults.particleCount == clamp(defaults.particleCount, PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX)
    check defaults.speciesCount == clamp(defaults.speciesCount, SPECIES_COUNT_MIN, SPECIES_COUNT_MAX)
    check defaults.interactionRadius == clamp(defaults.interactionRadius, INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX)
    check defaults.forceStrength == clamp(defaults.forceStrength, FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX)
    check defaults.friction == clamp(defaults.friction, FRICTION_MIN, FRICTION_MAX)
    check defaults.ruleTemperature == clamp(defaults.ruleTemperature, RULE_TEMPERATURE_MIN, RULE_TEMPERATURE_MAX)
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

# ==============================================================================
# MIGRATION HOOK CONTRACT
# ==============================================================================

suite "Preset Migration Hook Contract":
  test "migrate is the identity transform at the current version":
    ## CONTRACT: v1 is the only version that has ever existed, so migrating
    ## from CURRENT_SCHEMA_VERSION must return the node unchanged
    let node = toJson(defaultPreset())
    let migrated = migrate(node, CURRENT_SCHEMA_VERSION)
    check migrated == node

  test "validate routes an older-versioned node through migrate before field validation":
    ## FIXTURE: simulates a hypothetical pre-v1 preset (schemaVersion 0) to
    ## prove the migrate hook is wired into the validate path, not just
    ## defined. Since migrate is identity today, a v0-tagged node is
    ## field-validated exactly as a v1 node would be — the fixture exists
    ## to pin that wiring so a future `if fromVersion < 2` branch has a
    ## regression test to extend rather than a blank slate.
    let fixture = %*{
      "schemaVersion": 0,
      "name": "Legacy Preset",
      "mode": "particle-life",
      "settings": {"particleCount": 20000},
      "matrix": newSeq[float](MATRIX_LEN),
      "palette": DEFAULT_PALETTE
    }
    let result = validate(fixture)
    check result.isOk
    check result.preset.schemaVersion == CURRENT_SCHEMA_VERSION
    check result.preset.name == "Legacy Preset"
    check result.preset.settings.particleCount == 20000

  test "a negative schemaVersion still migrates and validates rather than rejecting":
    let node = %*{"schemaVersion": -1, "name": "Very old"}
    let result = validate(node)
    check result.isOk
    check result.preset.schemaVersion == CURRENT_SCHEMA_VERSION
