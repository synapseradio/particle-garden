# ==============================================================================
# PARTICLE GARDEN - PRESET SCHEMA (Pure Versioned Serialization)
# ==============================================================================
#
# Pure, versioned schema for saving and loading simulation presets. Built on
# std/json only: no FFI, no DOM, no localStorage. Compiles on both the
# native (`nim c`) and JS (`nim js`) backends, so it is safe to import from
# both `tests/test_all.nim` and a future browser-side preset_store module.
#
# Validation-first: every entry point that accepts external JSON (`validate`,
# `parsePreset`) degrades hostile or stale input to safe, clamped defaults
# instead of raising. The one true rejection is a `schemaVersion` newer than
# this build understands, since this build cannot know what a newer
# version's fields mean.
#
# std/json's own `[]` and `hasKey` guard their JObject/JArray invariant with
# `assert`, which `-d:release` (this project's build mode, see
# particle_garden.nimble) compiles out. Calling them on a node of the wrong
# kind would then read a case-object field through the wrong variant arm.
# To stay crash-free under `-d:release`, this module never calls `[]` or
# `hasKey` on untrusted nodes; it goes through `field`/`elemAt` below, which
# are built on `getFields`/`getElems` — accessors whose kind checks are a
# real `if`, not an `assert`, verified against the Nim 2.2.10 stdlib source.
#
# Used by:
#   - tests/test_preset.nim (native test compilation)
#   - a future src/ui/presets/preset_store.nim (storage/UI half, not this
#     module's concern: see roadmap stage B2)
#
# ==============================================================================

import std/json

# ==============================================================================
# SECTION 1: SCHEMA VERSION
# ==============================================================================

const CURRENT_SCHEMA_VERSION* = 1
  ## The only schema version this build writes and fully understands.
  ## `validate` rejects any JSON claiming a higher version. Future bumps
  ## add a branch to `migrate` that upgrades a node one version forward;
  ## `CURRENT_SCHEMA_VERSION` moves up alongside it.

# ==============================================================================
# SECTION 2: SHAPE
# ==============================================================================

const MAX_SPECIES* = 6
  ## Mirrors memory_layout.MAX_SPECIES. Not imported directly: memory_layout
  ## is a cross-language contract file (WGSL shaders hardcode the same 6),
  ## and this module intentionally carries no dependency on it or on any
  ## other src/ module, to stay a leaf the storage/UI layer can build on
  ## without pulling in FFI-bearing code transitively.

const MATRIX_LEN* = MAX_SPECIES * MAX_SPECIES ## 36: the flattened 6x6 attraction matrix.

type
  PaletteColor* = array[3, float] ## Interleaved RGB, each channel in [0, 1].
  Matrix* = array[MATRIX_LEN, float] ## Row-major 6x6 attraction matrix, values in [-1, 1].
  Palette* = array[MAX_SPECIES, PaletteColor] ## One color per species slot, always 6 long.

  PresetSettings* = object
    ## Every CONFIG scalar a preset can restore. Mirrors config.nim's
    ## ConfigObject field-for-field (config.nim is not imported: it pulls
    ## in JsObject/FFI bindings this module must stay free of).
    particleCount*: int
    speciesCount*: int
    interactionRadius*: int
    forceStrength*: float
    friction*: float
    ruleTemperature*: float
    timeScale*: float
    particleSize*: int
    trails*: bool
    trailLength*: float
    glowIntensity*: float
    velocityGlowScale*: float
    maxVelocity*: float
    repulsionEnd*: float
    attractionPeak*: float
    forceModel*: int
    expRepulsionAlpha*: float
    expAttractionBeta*: float

  Preset* = object
    ## The full persisted shape: `{schemaVersion, name, createdAt, mode,
    ## settings, matrix[36], palette}`.
    schemaVersion*: int
    name*: string
    createdAt*: string
      ## ISO-8601 string, or "" for "unknown". This module has no clock
      ## access (pure, no FFI) — the storage layer stamps a real value on
      ## save; "" is the safe default when a preset is missing one.
    mode*: string
      ## A mode id, e.g. "particle-life" (the only mode today). Free-form:
      ## `validate` only checks it is a non-empty string. It does not
      ## restrict to a known-mode allowlist, so a v1 preset saved by a
      ## future build with mode="sph" or mode="rd" still round-trips
      ## through this same validator without a schema bump — the whole
      ## point of carrying the field before those modes exist.
    settings*: PresetSettings
    matrix*: Matrix
    palette*: Palette

# ==============================================================================
# SECTION 3: CLAMP RANGES
#
# Derived from the live sliders in web/index.html (range) and the defaults
# in src/config.nim's createConfig() (value). Exported so a future
# preset_store/UI layer can reuse the same bounds instead of redefining
# them. See the file-level note on `trailLength` below for the one place
# these two sources disagreed and how it was resolved.
# ==============================================================================

const
  PARTICLE_COUNT_MIN* = 1000
  PARTICLE_COUNT_MAX* = 64000       ## web/index.html#particleCount slider.
  SPECIES_COUNT_MIN* = 2
  SPECIES_COUNT_MAX* = 6            ## web/index.html#speciesCount slider; matches MAX_SPECIES.
  INTERACTION_RADIUS_MIN* = 20
  INTERACTION_RADIUS_MAX* = 120     ## web/index.html#interactionRadius slider.
  FORCE_STRENGTH_MIN* = 0.1
  FORCE_STRENGTH_MAX* = 3.0         ## web/index.html#forceStrength slider.
  FRICTION_MIN* = 0.01
  FRICTION_MAX* = 0.2               ## web/index.html#friction slider.
  RULE_TEMPERATURE_MIN* = 0.1
  RULE_TEMPERATURE_MAX* = 0.6       ## web/index.html#ruleTemperature slider.
  TIME_SCALE_MIN* = 0.0
  TIME_SCALE_MAX* = 2.0             ## web/index.html#timeScale slider.
  PARTICLE_SIZE_MIN* = 1
  PARTICLE_SIZE_MAX* = 20
    ## No HTML slider exposes particleSize today (default 3 comes from
    ## config.nim and render_state.nim only). Range chosen to comfortably
    ## bound the default with headroom; the only other constraint found
    ## is webgpu_render.nim's `float32(particleSize + 1)` screen-space
    ## quad half-size, which imposes no documented ceiling. Fork decision.
  TRAIL_LENGTH_MIN* = 0.0
    ## web/index.html#trailLength's own slider bounds are [0.5, 0.99], but
    ## config.nim's default is 0.0 ("0 = no trails" per its comment) —
    ## outside that slider's range. Rather than clamp the documented
    ## default out of its own valid range, the minimum is widened to 0.0
    ## so both sources' stated defaults stay valid. Fork decision.
  TRAIL_LENGTH_MAX* = 0.99          ## web/index.html#trailLength slider.
  GLOW_INTENSITY_MIN* = 0.0
  GLOW_INTENSITY_MAX* = 3.0         ## web/index.html#glowIntensity slider.
  VELOCITY_GLOW_SCALE_MIN* = 0.0
  VELOCITY_GLOW_SCALE_MAX* = 3.0    ## web/index.html#velocityGlowScale slider.
  MAX_VELOCITY_MIN* = 0.0
  MAX_VELOCITY_MAX* = 100.0         ## web/index.html#maxVelocity slider.
  REPULSION_END_MIN* = 0.1
  REPULSION_END_MAX* = 0.9          ## web/index.html#repulsionEnd slider.
  ATTRACTION_PEAK_MIN* = 0.5
  ATTRACTION_PEAK_MAX* = 0.95       ## web/index.html#attractionPeak slider.
  FORCE_MODEL_MIN* = 0
  FORCE_MODEL_MAX* = 1              ## 0=polynomial, 1=exponential (config.nim comment).
  EXP_REPULSION_ALPHA_MIN* = 1.0
  EXP_REPULSION_ALPHA_MAX* = 15.0   ## web/index.html#expRepulsionAlpha slider.
  EXP_ATTRACTION_BETA_MIN* = 1.0
  EXP_ATTRACTION_BETA_MAX* = 10.0   ## web/index.html#expAttractionBeta slider.
  MATRIX_VALUE_MIN* = -1.0
  MATRIX_VALUE_MAX* = 1.0
    ## Matches src/ui/state/matrix_state.MATRIX_MIN_VALUE/MAX_VALUE.
    ## Duplicated rather than imported: that module lives under src/ui/,
    ## which this module must not depend on.
  PALETTE_CHANNEL_MIN* = 0.0
  PALETTE_CHANNEL_MAX* = 1.0        ## Each RGB channel, matching config.nim's COLORS values.

const DEFAULT_MODE* = "particle-life"
const DEFAULT_PRESET_NAME* = "Untitled Preset"

const DEFAULT_PALETTE*: Palette = [
  ## Verbatim copy of config.nim SECTION 7's COLORS, regrouped into
  ## per-species triples. Duplicated rather than imported for the same
  ## reason as MATRIX_VALUE_MIN/MAX above: config.nim depends on JsObject.
  [1.0, 0.4, 0.4],   # Species 0: Red
  [0.4, 1.0, 0.4],   # Species 1: Green
  [0.4, 0.7, 1.0],   # Species 2: Blue
  [1.0, 1.0, 0.4],   # Species 3: Yellow
  [1.0, 0.4, 1.0],   # Species 4: Magenta
  [0.4, 1.0, 1.0]    # Species 5: Cyan
]

# ==============================================================================
# SECTION 4: DEFAULTS
# ==============================================================================

func defaultSettings*(): PresetSettings =
  ## Mirrors config.nim's createConfig() defaults exactly.
  PresetSettings(
    particleCount: 16000,
    speciesCount: 4,
    interactionRadius: 50,
    forceStrength: 1.0,
    friction: 0.05,
    ruleTemperature: 0.3,
    timeScale: 0.5,
    particleSize: 3,
    trails: false,
    trailLength: 0.0,
    glowIntensity: 0.8,
    velocityGlowScale: 1.0,
    maxVelocity: 50.0,
    repulsionEnd: 0.5,
    attractionPeak: 0.75,
    forceModel: 0,
    expRepulsionAlpha: 6.0,
    expAttractionBeta: 3.0
  )

func defaultMatrix*(): Matrix =
  ## All-neutral (zero force) matrix. There is no canonical "default rule
  ## set" elsewhere in the codebase — matrices are randomized at startup —
  ## so an all-zero matrix is the one deterministic, safe fallback.
  discard # zero-initialized by default

func defaultPreset*(): Preset =
  Preset(
    schemaVersion: CURRENT_SCHEMA_VERSION,
    name: DEFAULT_PRESET_NAME,
    createdAt: "",
    mode: DEFAULT_MODE,
    settings: defaultSettings(),
    matrix: defaultMatrix(),
    palette: DEFAULT_PALETTE
  )

# ==============================================================================
# SECTION 5: RESULT TYPE
# ==============================================================================

type
  PresetErrorKind* = enum
    pekNone              ## Parsed and validated cleanly (fields may still have been clamped/defaulted).
    pekInvalidJson        ## `jsonText` was not parseable JSON, or the root was not a JSON object.
    pekNewerSchemaVersion ## `schemaVersion` exceeds CURRENT_SCHEMA_VERSION; this build cannot interpret it.

  PresetLoadResult* = object
    ## Always carries a safe, usable `preset` — even on error, `preset`
    ## is `defaultPreset()` — so a caller that ignores `errorKind` still
    ## gets a valid preset rather than undefined behavior. `errorKind`
    ## and `errorMessage` exist for callers (the future preset_store /
    ## UI layer) that want to surface *why* a load was rejected or
    ## repaired.
    preset*: Preset
    errorKind*: PresetErrorKind
    errorMessage*: string

func isOk*(loadResult: PresetLoadResult): bool =
  loadResult.errorKind == pekNone

# ==============================================================================
# SECTION 6: SAFE JSON ACCESS
# ==============================================================================

proc field(node: JsonNode; key: string): JsonNode =
  ## Nil-safe field lookup. See the file header: this exists instead of
  ## `node[key]`/`node.hasKey(key)` because those guard their JObject
  ## invariant with `assert`, which `-d:release` strips. std/json's own
  ## `getOrDefault` guards the same invariant with a real `if`, so it is
  ## safe to build on directly.
  node.getOrDefault(key)

proc elemAt(node: JsonNode; index: int): JsonNode =
  ## Nil-safe array indexing, built on std/json's `{}` operator for the
  ## same reason as `field`. Only ever called with `index >= 0` in this module.
  node{index}

func clampInt(value, lowBound, highBound: int): int =
  max(lowBound, min(highBound, value))

func clampFloat(value, lowBound, highBound: float): float =
  max(lowBound, min(highBound, value))

# ==============================================================================
# SECTION 7: FIELD VALIDATION
# ==============================================================================

proc validateSettings(node: JsonNode): PresetSettings =
  ## Every field independently defaults (missing or wrong JSON type) or
  ## clamps (present, right type, out of range). One bad field never
  ## invalidates the rest.
  let defaults = defaultSettings()
  result.particleCount = clampInt(
    field(node, "particleCount").getInt(defaults.particleCount), PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX)
  result.speciesCount = clampInt(
    field(node, "speciesCount").getInt(defaults.speciesCount), SPECIES_COUNT_MIN, SPECIES_COUNT_MAX)
  result.interactionRadius = clampInt(
    field(node, "interactionRadius").getInt(defaults.interactionRadius), INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX)
  result.forceStrength = clampFloat(
    field(node, "forceStrength").getFloat(defaults.forceStrength), FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX)
  result.friction = clampFloat(
    field(node, "friction").getFloat(defaults.friction), FRICTION_MIN, FRICTION_MAX)
  result.ruleTemperature = clampFloat(
    field(node, "ruleTemperature").getFloat(defaults.ruleTemperature), RULE_TEMPERATURE_MIN, RULE_TEMPERATURE_MAX)
  result.timeScale = clampFloat(
    field(node, "timeScale").getFloat(defaults.timeScale), TIME_SCALE_MIN, TIME_SCALE_MAX)
  result.particleSize = clampInt(
    field(node, "particleSize").getInt(defaults.particleSize), PARTICLE_SIZE_MIN, PARTICLE_SIZE_MAX)
  result.trails = field(node, "trails").getBool(defaults.trails)
  result.trailLength = clampFloat(
    field(node, "trailLength").getFloat(defaults.trailLength), TRAIL_LENGTH_MIN, TRAIL_LENGTH_MAX)
  result.glowIntensity = clampFloat(
    field(node, "glowIntensity").getFloat(defaults.glowIntensity), GLOW_INTENSITY_MIN, GLOW_INTENSITY_MAX)
  result.velocityGlowScale = clampFloat(
    field(node, "velocityGlowScale").getFloat(defaults.velocityGlowScale), VELOCITY_GLOW_SCALE_MIN, VELOCITY_GLOW_SCALE_MAX)
  result.maxVelocity = clampFloat(
    field(node, "maxVelocity").getFloat(defaults.maxVelocity), MAX_VELOCITY_MIN, MAX_VELOCITY_MAX)
  result.repulsionEnd = clampFloat(
    field(node, "repulsionEnd").getFloat(defaults.repulsionEnd), REPULSION_END_MIN, REPULSION_END_MAX)
  result.attractionPeak = clampFloat(
    field(node, "attractionPeak").getFloat(defaults.attractionPeak), ATTRACTION_PEAK_MIN, ATTRACTION_PEAK_MAX)
  result.forceModel = clampInt(
    field(node, "forceModel").getInt(defaults.forceModel), FORCE_MODEL_MIN, FORCE_MODEL_MAX)
  result.expRepulsionAlpha = clampFloat(
    field(node, "expRepulsionAlpha").getFloat(defaults.expRepulsionAlpha), EXP_REPULSION_ALPHA_MIN, EXP_REPULSION_ALPHA_MAX)
  result.expAttractionBeta = clampFloat(
    field(node, "expAttractionBeta").getFloat(defaults.expAttractionBeta), EXP_ATTRACTION_BETA_MIN, EXP_ATTRACTION_BETA_MAX)

proc validateMatrix(node: JsonNode): Matrix =
  ## Missing/non-numeric entries default to 0.0 (neutral); present numeric
  ## entries clamp to [-1, 1]. Repaired per-index, so one bad slot in an
  ## otherwise-good 36-element array does not discard the other 35.
  for matrixIndex in 0 ..< MATRIX_LEN:
    result[matrixIndex] = clampFloat(
      elemAt(node, matrixIndex).getFloat(0.0), MATRIX_VALUE_MIN, MATRIX_VALUE_MAX)

proc validateColor(node: JsonNode; fallback: PaletteColor): PaletteColor =
  ## A color is valid only as a whole 3-element numeric triple; a
  ## malformed triple falls back to `fallback` entirely rather than
  ## guessing per-channel, since a partially-decoded RGB triple is not a
  ## meaningfully "safer" color than a species' own default.
  let elems = node.getElems()
  if elems.len == 3:
    [
      clampFloat(elems[0].getFloat(fallback[0]), PALETTE_CHANNEL_MIN, PALETTE_CHANNEL_MAX),
      clampFloat(elems[1].getFloat(fallback[1]), PALETTE_CHANNEL_MIN, PALETTE_CHANNEL_MAX),
      clampFloat(elems[2].getFloat(fallback[2]), PALETTE_CHANNEL_MIN, PALETTE_CHANNEL_MAX)
    ]
  else:
    fallback

proc validatePalette(node: JsonNode): Palette =
  ## Repaired per-species-slot: one malformed color falls back to that
  ## slot's default without discarding the other five.
  for speciesIndex in 0 ..< MAX_SPECIES:
    result[speciesIndex] = validateColor(
      elemAt(node, speciesIndex), DEFAULT_PALETTE[speciesIndex])

proc validateMode(node: JsonNode): string =
  let modeName = node.getStr("")
  if modeName.len > 0: modeName else: DEFAULT_MODE

# ==============================================================================
# SECTION 8: MIGRATE + VALIDATE + PARSE
# ==============================================================================

proc migrate*(node: JsonNode; fromVersion: int): JsonNode =
  ## Upgrades a preset JSON node from `fromVersion` to
  ## CURRENT_SCHEMA_VERSION. v1 is the only version that has ever existed,
  ## so this is the identity transform today. A future schema bump adds a
  ## step here, e.g.:
  ##   if fromVersion < 2: node = /* rewrite v1 shape -> v2 shape */
  ##   if fromVersion < 3: node = /* rewrite v2 shape -> v3 shape */
  ## each falling through to the next, so a preset many versions old
  ## still upgrades in one call.
  node

proc validate*(node: JsonNode): PresetLoadResult =
  ## Validates and normalizes an already-parsed JSON node into a `Preset`.
  ## Missing or malformed fields default or clamp (see SECTION 7); the one
  ## rejection is `schemaVersion` newer than this build understands, since
  ## there is no safe way to interpret fields from a future schema.
  if node == nil or node.kind != JObject:
    return PresetLoadResult(
      preset: defaultPreset(),
      errorKind: pekInvalidJson,
      errorMessage: "preset root is not a JSON object")

  let versionNode = field(node, "schemaVersion")
  let version =
    if versionNode != nil and versionNode.kind == JInt: versionNode.getInt(CURRENT_SCHEMA_VERSION)
    else: CURRENT_SCHEMA_VERSION
      ## A missing or wrong-typed schemaVersion degrades to "assume
      ## current", matching the module's defaulting stance elsewhere,
      ## rather than being treated as a reject condition.

  if version > CURRENT_SCHEMA_VERSION:
    return PresetLoadResult(
      preset: defaultPreset(),
      errorKind: pekNewerSchemaVersion,
      errorMessage: "preset schemaVersion " & $version &
        " is newer than the supported version " & $CURRENT_SCHEMA_VERSION)

  let working = if version < CURRENT_SCHEMA_VERSION: migrate(node, version) else: node

  result = PresetLoadResult(
    preset: Preset(
      schemaVersion: CURRENT_SCHEMA_VERSION,
      name: field(working, "name").getStr(DEFAULT_PRESET_NAME),
      createdAt: field(working, "createdAt").getStr(""),
      mode: validateMode(field(working, "mode")),
      settings: validateSettings(field(working, "settings")),
      matrix: validateMatrix(field(working, "matrix")),
      palette: validatePalette(field(working, "palette"))
    ),
    errorKind: pekNone,
    errorMessage: ""
  )

proc parsePreset*(jsonText: string): PresetLoadResult =
  ## Entry point for raw preset text (e.g. an Import file, or a
  ## localStorage value). Malformed JSON text is caught and reported as
  ## `pekInvalidJson` rather than propagating a `JsonParsingError`.
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except ValueError as e:
    return PresetLoadResult(
      preset: defaultPreset(),
      errorKind: pekInvalidJson,
      errorMessage: "malformed JSON: " & e.msg)
  validate(node)

# ==============================================================================
# SECTION 9: SERIALIZATION
# ==============================================================================

proc toJson*(settings: PresetSettings): JsonNode =
  result = newJObject()
  result["particleCount"] = %settings.particleCount
  result["speciesCount"] = %settings.speciesCount
  result["interactionRadius"] = %settings.interactionRadius
  result["forceStrength"] = %settings.forceStrength
  result["friction"] = %settings.friction
  result["ruleTemperature"] = %settings.ruleTemperature
  result["timeScale"] = %settings.timeScale
  result["particleSize"] = %settings.particleSize
  result["trails"] = %settings.trails
  result["trailLength"] = %settings.trailLength
  result["glowIntensity"] = %settings.glowIntensity
  result["velocityGlowScale"] = %settings.velocityGlowScale
  result["maxVelocity"] = %settings.maxVelocity
  result["repulsionEnd"] = %settings.repulsionEnd
  result["attractionPeak"] = %settings.attractionPeak
  result["forceModel"] = %settings.forceModel
  result["expRepulsionAlpha"] = %settings.expRepulsionAlpha
  result["expAttractionBeta"] = %settings.expAttractionBeta

proc toJson*(preset: Preset): JsonNode =
  result = newJObject()
  result["schemaVersion"] = %preset.schemaVersion
  result["name"] = %preset.name
  result["createdAt"] = %preset.createdAt
  result["mode"] = %preset.mode
  result["settings"] = toJson(preset.settings)

  var matrixArr = newJArray()
  for matrixValue in preset.matrix:
    matrixArr.add(%matrixValue)
  result["matrix"] = matrixArr

  var paletteArr = newJArray()
  for color in preset.palette:
    var colorArr = newJArray()
    for channel in color:
      colorArr.add(%channel)
    paletteArr.add(colorArr)
  result["palette"] = paletteArr

proc toJsonString*(preset: Preset): string =
  $toJson(preset)
