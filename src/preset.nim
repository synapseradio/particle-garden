# ==============================================================================
# PARTICLE GARDEN - PRESET SCHEMA (Pure Versioned Serialization)
# ==============================================================================
#
# Pure, versioned schema for saving and loading simulation presets. Built on
# std/json only: no FFI, no DOM, no localStorage. Compiles on both the
# native (`nim c`) and JS (`nim js`) backends, so it is safe to import from
# both `tests/test_all.nim` and browser-side preset code.
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
#   - src/web_api.nim (snapshot/apply behind gardenAPI; the storage half
#     lives UI-side in web-ui/src/lib/presets.ts)
#
# Dependencies are restricted to pure, FFI-free leaf modules (config_ranges,
# palette), so this module still compiles identically on the native and JS
# backends and pulls no DOM/JsObject code in transitively.
#
# ==============================================================================

import std/json
import config_ranges
import palette

# The clamp bounds ARE the live slider ranges: the param descriptor table
# (ui/api/param_descriptor.nim) reads the same constants, so the preset
# schema and the UI cannot disagree about what values are representable.
export config_ranges

# ==============================================================================
# SECTION 1: SCHEMA VERSION
# ==============================================================================

const CURRENT_SCHEMA_VERSION* = 3
  ## The schema version this build writes and fully understands.
  ## `validate` rejects any JSON claiming a higher version. Bumps add a
  ## branch to `migrate` that upgrades a node one version forward;
  ## `CURRENT_SCHEMA_VERSION` moves up alongside it.
  ##
  ## v3 widens the species ceiling from 6 to 8: the flattened attraction
  ## matrix restrides on load (see `migrate`), while chemistry and palette
  ## are indexed per species slot and extend by ordinary per-slot repair.
  ##
  ## v2 carries coupling strengths and names no mode; v1 names a mode and
  ## carries a value for every scalar whether or not that mode reads it.
  ## `migrate` translates the first shape into the second — see
  ## LEGACY_MODE_COUPLINGS for why translation is the only mechanism that works.
  ##
  ## v2 also adds fields v1 has no slot for: per-species chemistry, the fluid
  ## strength, the two climate-drift settings, and the crowding strength. The
  ## v1 branch derives the fluid strength from the mode and pins the crowding
  ## strength at zero: v1 carries no crowding strength field, so a fixed value
  ## stands in rather than a default that could move independently.

# ==============================================================================
# SECTION 2: SHAPE
# ==============================================================================

const MAX_SPECIES* = 8
  ## Mirrors memory_layout.MAX_SPECIES. Not imported directly: memory_layout
  ## is a cross-language contract file (the WGSL twin generates from it),
  ## and this module intentionally carries no dependency on it or on any
  ## other src/ module, to stay a leaf the storage/UI layer can build on
  ## without pulling in FFI-bearing code transitively.

const MATRIX_LEN* = MAX_SPECIES * MAX_SPECIES ## 64: the flattened 8x8 attraction matrix.

const CHEMISTRY_STRIDE* = 2
  ## (secretion, tropism) per species slot. Mirrors config.nim's
  ## SPECIES_CHEMISTRY_STRIDE, as a literal for the same
  ## dependency-restriction reason MAX_SPECIES is one.

const CHEMISTRY_LEN* = MAX_SPECIES * CHEMISTRY_STRIDE ## 16: eight slots, two values each.

type
  PaletteColor* = array[3, float] ## Interleaved RGB, each channel in [0, 1].
  Matrix* = array[MATRIX_LEN, float] ## Row-major 8x8 attraction matrix, values in [-1, 1].
  Palette* = array[MAX_SPECIES, PaletteColor] ## One color per species slot.
  Chemistry* = array[CHEMISTRY_LEN, float]
    ## Interleaved (secretion, tropism) per species slot.
    ## A DIMENSION rather than a scalar, which is why it sits beside `matrix`
    ## in the Preset rather than inside PresetSettings: the settings record
    ## holds one number per name, and this holds MAX_SPECIES x 2.

  PresetSettings* = object
    ## Every CONFIG scalar a preset can restore. Mirrors config.nim's
    ## ConfigObject field-for-field (config.nim is not imported: it pulls
    ## in JsObject/FFI bindings this module must stay free of).
    particleCount*: int
    speciesCount*: int
    interactionRadius*: int
    forceStrength*: float
    crowdingStrength*: float
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
    glowRadiusScale*: float
    glowFalloff*: float
    glowWarmth*: float
    fluidStrength*: float
    sphRestDensity*: float
    sphStiffness*: float
    sphRadiusFraction*: float
    sphViscosity*: float
    sphSubsteps*: int
    rdFeed*: float
    rdKill*: float
    rdDeposit*: float
    rdFieldForce*: float
    climateDrift*: bool
    climateSpeed*: float
    forceWeather*: bool
    forceWeatherSpeed*: float
    bloomEnabled*: bool
    bloomIntensity*: float
    exposure*: float
    saturation*: float
    contrast*: float
    temperature*: float
    colormapIndex*: int
    fieldOpacity*: float

  Preset* = object
    ## The full persisted shape: `{schemaVersion, name, createdAt, settings,
    ## matrix[64], chemistry[16], palette}`.
    ##
    ## NO MODE FIELD, and its absence is the schema saying there is one world.
    ## A preset is a POINT in that world's parameter space: the strengths it
    ## carries are what it restores, and nothing consults a mode to decide what
    ## those strengths mean. v1's `mode` survives only inside `migrate`, which
    ## reads it off the raw JSON to translate an old file forward.
    schemaVersion*: int
    name*: string
    createdAt*: string
      ## ISO-8601 string, or "" for "unknown". This module has no clock
      ## access (pure, no FFI) — the storage layer stamps a real value on
      ## save; "" is the safe default when a preset is missing one.
    settings*: PresetSettings
    matrix*: Matrix
    chemistry*: Chemistry
    palette*: Palette

# ==============================================================================
# SECTION 3: CLAMP RANGES
#
# The slider-backed bounds live in config_ranges.nim (imported and
# re-exported above) — the same constants the param descriptor table reads,
# so the preset schema clamps to exactly what the UI can produce. Only
# bounds with no slider are defined here.
# ==============================================================================

const
  FORCE_MODEL_MIN* = 0
  FORCE_MODEL_MAX* = 1              ## 0=polynomial, 1=exponential (config.nim comment).
  PALETTE_CHANNEL_MIN* = 0.0
  PALETTE_CHANNEL_MAX* = 1.0        ## Each RGB channel, matching config.nim's COLORS values.

static:
  doAssert MAX_SPECIES == SPECIES_COUNT_MAX,
    "preset array sizing and the species slider ceiling must agree"

const DEFAULT_PRESET_NAME* = "Untitled Preset"

func openColorDefaultPalette(): Palette =
  ## The default palette is palette.nim's Open Color swatch set — the same
  ## source config.nim initializes COLORS from — regrouped into the
  ## per-species triples the preset schema stores.
  for speciesIndex in 0 ..< MAX_SPECIES:
    # Mod-wrapped like generatePalette's psOpenColor branch, so a species
    # count past the swatch count reuses hues instead of indexing out.
    let swatch = OPEN_COLOR_SWATCHES[speciesIndex mod OPEN_COLOR_SWATCHES.len]
    result[speciesIndex] = [swatch.red, swatch.green, swatch.blue]

const DEFAULT_PALETTE*: Palette = openColorDefaultPalette()

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
    # Mirrors simulation_state.initSimulationState's crowdingStrength: the
    # shipped world runs the force law without the crowding term, so a preset
    # that never mentions one restores none.
    crowdingStrength: 0.0,
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
    expAttractionBeta: 3.0,
    glowRadiusScale: 3.0,
    glowFalloff: 6.0,
    glowWarmth: 0.4,
    # Mirrors simulation_state.initSimulationState's fluidStrength: the shipped
    # world runs no fluid, so a preset that never mentions one restores none.
    fluidStrength: 0.0,
    sphRestDensity: 3.0,
    sphStiffness: 8.0,
    # Mirrors simulation_state.initSimulationState's sphRadiusFraction: the
    # whole interaction radius, which is the kernel every fluid world runs.
    # One-world moves this below 1 for fresh worlds; presets
    # older than this schema version get 1.0 pinned in the v1 branch below,
    # never the shipped default.
    sphRadiusFraction: 1.0,
    sphViscosity: 0.1,
    sphSubsteps: 2,
    # Mirrors field_core.RD_DEFAULT_FEED/KILL/DEPOSIT/FIELD_FORCE as literals
    # rather than an import: this module's dependencies are intentionally
    # restricted to config_ranges and palette (see file header), the same
    # reason sphRestDensity etc. above are literals rather than sph_core
    # imports.
    rdFeed: 0.030,
    rdKill: 0.062,
    rdDeposit: 0.02,
    rdFieldForce: 7.5,
    # Mirrors simulation_state's climate defaults. Weather is opt-in, so a
    # preset missing these restores a world that moves only when asked.
    climateDrift: false,
    climateSpeed: 0.25,
    forceWeather: false,
    forceWeatherSpeed: 0.5,
    # Mirrors bloom_core.BLOOM_DEFAULT_* as literals rather than an import,
    # for the same dependency-restriction reason as the sph/rd defaults above.
    bloomEnabled: false,
    bloomIntensity: 1.0,
    exposure: 1.0,
    saturation: 1.0,
    contrast: 1.0,
    temperature: 0.0,
    # Mirrors colormap_core.COLORMAP_DEFAULT_INDEX / FIELD_OPACITY_DEFAULT as
    # literals rather than an import, for the same dependency-restriction reason
    # as the sph/rd/bloom defaults above.
    colormapIndex: 0,
    # Mirrors colormap_core.FIELD_OPACITY_DEFAULT. A hand-mirrored constant
    # drifts silently, so tests/test_preset.nim asserts the two agree.
    fieldOpacity: 0.0
  )

func defaultMatrix*(): Matrix =
  ## All-neutral (zero force) matrix. There is no canonical "default rule
  ## set" elsewhere in the codebase — matrices are randomized at startup —
  ## so an all-zero matrix is the one deterministic, safe fallback.
  discard # zero-initialized by default

func defaultChemistry*(): Chemistry =
  ## Mirrors field_core's RD_DEFAULT_SECRETION / RD_DEFAULT_TROPISM for every
  ## species slot: full positive secretion, and the negative, down-gradient
  ## tropism. Literals for the same dependency-restriction reason as
  ## defaultSettings above.
  for speciesIndex in 0 ..< MAX_SPECIES:
    let base = speciesIndex * CHEMISTRY_STRIDE
    result[base] = 1.0       ## secretion
    result[base + 1] = -1.0  ## tropism

func defaultPreset*(): Preset =
  Preset(
    schemaVersion: CURRENT_SCHEMA_VERSION,
    name: DEFAULT_PRESET_NAME,
    createdAt: "",
    settings: defaultSettings(),
    matrix: defaultMatrix(),
    chemistry: defaultChemistry(),
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
    ## and `errorMessage` exist for callers (the preset store / UI layer)
    ## that want to surface *why* a load was rejected or repaired.
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
  result.crowdingStrength = clampFloat(
    field(node, "crowdingStrength").getFloat(defaults.crowdingStrength),
    CROWDING_STRENGTH_MIN, CROWDING_STRENGTH_MAX)
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
  result.glowRadiusScale = clampFloat(
    field(node, "glowRadiusScale").getFloat(defaults.glowRadiusScale), GLOW_RADIUS_SCALE_MIN, GLOW_RADIUS_SCALE_MAX)
  result.glowFalloff = clampFloat(
    field(node, "glowFalloff").getFloat(defaults.glowFalloff), GLOW_FALLOFF_MIN, GLOW_FALLOFF_MAX)
  result.glowWarmth = clampFloat(
    field(node, "glowWarmth").getFloat(defaults.glowWarmth), GLOW_WARMTH_MIN, GLOW_WARMTH_MAX)
  result.fluidStrength = clampFloat(
    field(node, "fluidStrength").getFloat(defaults.fluidStrength),
    FLUID_STRENGTH_MIN, FLUID_STRENGTH_MAX)
  result.sphRestDensity = clampFloat(
    field(node, "sphRestDensity").getFloat(defaults.sphRestDensity), SPH_REST_DENSITY_MIN, SPH_REST_DENSITY_MAX)
  result.sphStiffness = clampFloat(
    field(node, "sphStiffness").getFloat(defaults.sphStiffness), SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX)
  result.sphRadiusFraction = clampFloat(
    field(node, "sphRadiusFraction").getFloat(defaults.sphRadiusFraction),
    SPH_RADIUS_FRACTION_MIN, SPH_RADIUS_FRACTION_MAX)
  result.sphViscosity = clampFloat(
    field(node, "sphViscosity").getFloat(defaults.sphViscosity), SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX)
  result.sphSubsteps = clampInt(
    field(node, "sphSubsteps").getInt(defaults.sphSubsteps), SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX)
  result.rdFeed = clampFloat(
    field(node, "rdFeed").getFloat(defaults.rdFeed), RD_FEED_MIN, RD_FEED_MAX)
  result.rdKill = clampFloat(
    field(node, "rdKill").getFloat(defaults.rdKill), RD_KILL_MIN, RD_KILL_MAX)
  result.rdDeposit = clampFloat(
    field(node, "rdDeposit").getFloat(defaults.rdDeposit),
    RD_DEPOSIT_MIN, RD_DEPOSIT_MAX)
  result.rdFieldForce = clampFloat(
    field(node, "rdFieldForce").getFloat(defaults.rdFieldForce),
    RD_FIELD_FORCE_MIN, RD_FIELD_FORCE_MAX)
  result.climateDrift = field(node, "climateDrift").getBool(defaults.climateDrift)
  result.climateSpeed = clampFloat(
    field(node, "climateSpeed").getFloat(defaults.climateSpeed),
    CLIMATE_SPEED_MIN, CLIMATE_SPEED_MAX)
  # NO LEGACY PINNING FOR THESE TWO, and that is the rule rather than an
  # oversight. The versioned decode pins a field only where its shipped default
  # differs from the value that preserves a saved world (crowdingStrength and
  # the fluid fraction are the two that do). Force weather ships off, and off is
  # also what every world saved before it existed was running, so the default
  # already preserves them and a v1 case here would assert nothing.
  result.forceWeather =
    field(node, "forceWeather").getBool(defaults.forceWeather)
  result.forceWeatherSpeed = clampFloat(
    field(node, "forceWeatherSpeed").getFloat(defaults.forceWeatherSpeed),
    FORCE_WEATHER_SPEED_MIN, FORCE_WEATHER_SPEED_MAX)
  result.bloomEnabled = field(node, "bloomEnabled").getBool(defaults.bloomEnabled)
  result.bloomIntensity = clampFloat(
    field(node, "bloomIntensity").getFloat(defaults.bloomIntensity), BLOOM_INTENSITY_MIN, BLOOM_INTENSITY_MAX)
  result.exposure = clampFloat(
    field(node, "exposure").getFloat(defaults.exposure), EXPOSURE_MIN, EXPOSURE_MAX)
  result.saturation = clampFloat(
    field(node, "saturation").getFloat(defaults.saturation), SATURATION_MIN, SATURATION_MAX)
  result.contrast = clampFloat(
    field(node, "contrast").getFloat(defaults.contrast), CONTRAST_MIN, CONTRAST_MAX)
  result.temperature = clampFloat(
    field(node, "temperature").getFloat(defaults.temperature), TEMPERATURE_MIN, TEMPERATURE_MAX)
  result.colormapIndex = clampInt(
    field(node, "colormapIndex").getInt(defaults.colormapIndex), COLORMAP_INDEX_MIN, COLORMAP_INDEX_MAX)
  result.fieldOpacity = clampFloat(
    field(node, "fieldOpacity").getFloat(defaults.fieldOpacity), FIELD_OPACITY_RANGE_MIN, FIELD_OPACITY_RANGE_MAX)

proc validateMatrix(node: JsonNode): Matrix =
  ## Missing/non-numeric entries default to 0.0 (neutral); present numeric
  ## entries clamp to [-1, 1]. Repaired per-index, so one bad slot in an
  ## otherwise-good array does not discard the rest.
  for matrixIndex in 0 ..< MATRIX_LEN:
    result[matrixIndex] = clampFloat(
      elemAt(node, matrixIndex).getFloat(0.0), MATRIX_MIN_VALUE, MATRIX_MAX_VALUE)

proc validateChemistry(node: JsonNode): Chemistry =
  ## Repaired per slot, like the matrix: a missing or non-numeric entry falls
  ## back to that slot's default rather than discarding the rest.
  ##
  ## The two channels clamp against DIFFERENT ranges, and asymmetrically —
  ## tropism's ceiling sits below the magnitude of its floor, so a
  ## hand-edited preset asking for strong positive tropism is brought back to
  ## the bound rather than landing raw in the uniform.
  let defaults = defaultChemistry()
  for speciesIndex in 0 ..< MAX_SPECIES:
    let secretionAt = speciesIndex * CHEMISTRY_STRIDE
    let tropismAt = secretionAt + 1
    result[secretionAt] = clampFloat(
      elemAt(node, secretionAt).getFloat(defaults[secretionAt]),
      SECRETION_MIN, SECRETION_MAX)
    result[tropismAt] = clampFloat(
      elemAt(node, tropismAt).getFloat(defaults[tropismAt]),
      TROPISM_MIN, TROPISM_MAX)

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
  ## slot's default without discarding the rest.
  for speciesIndex in 0 ..< MAX_SPECIES:
    result[speciesIndex] = validateColor(
      elemAt(node, speciesIndex), DEFAULT_PALETTE[speciesIndex])

# ==============================================================================
# SECTION 8: MIGRATE + VALIDATE + PARSE
# ==============================================================================

type
  LegacyCouplings = object
    ## What a v1 mode id meant, as the strengths that say the same thing.
    ## `keep` names a strength the mode's world actually used, so the preset's
    ## own value survives; anything not kept is zeroed.
    keepForces: bool
    keepFluid: bool
    keepChemistry: bool

const LEGACY_MODE_COUPLINGS: array[3, (string, LegacyCouplings)] = [
  ("particle-life", LegacyCouplings(
    keepForces: true, keepFluid: false, keepChemistry: false)),
  ("sph", LegacyCouplings(
    keepForces: false, keepFluid: true, keepChemistry: false)),
  ("reaction-diffusion", LegacyCouplings(
    keepForces: false, keepFluid: false, keepChemistry: true)),
]
  ## THE ONLY PLACE IN THE CODEBASE THAT NAMES A MODE, and it is history rather
  ## than model: a table about files on disk, reachable only from the v1 branch
  ## of `migrate`. No live path reaches it, and a new coupling adds no row.
  ##
  ## WHY TRANSLATION AND NOT SUBTRACTION. Treating an absent strength as zero
  ## cannot work: v1 serializes every scalar unconditionally and parses each
  ## with a nonzero default, so a v1 particle-life file carries a deposit and a
  ## field force from sliders its mode hid. Loading it untranslated switches
  ## chemistry on in a world that has none. The mode id is the only record of
  ## which values that world reads, so the decode consults it once and drops it.

const OLD_MAX_SPECIES* = 6
  ## The species ceiling every schemaVersion <= 2 file was written against —
  ## the stride its flattened attraction matrix uses. The v3 branch of
  ## `migrate` remaps that stride onto MAX_SPECIES; tests/test_preset.nim
  ## pins the remap.

const V1_FIELD_FORCE_SCALE* = 0.25
  ## What a v1 field force multiplies by to mean the same thing here.
  ##
  ## The v1 field grid was 512 cells across; this one is four times finer.
  ## field-force.wgsl turns a gradient measured PER CELL into an impulse in
  ## WORLD units, so the same number carries a particle four times further
  ## across a pattern built from four-times-smaller cells. This is
  ## 1 / field_core.FIELD_PATTERN_SHRINK, mirrored as a literal for the same
  ## dependency-restriction reason MAX_SPECIES is one, and tests/test_preset.nim
  ## checks it against field_core's own constant.

proc legacyCouplingsFor(modeName: string): LegacyCouplings =
  ## An unrecognised mode keeps everything it carries, minus the fluid it has no
  ## field for. Forward-compatible in the same spirit v1's free-form `mode`
  ## field was: a preset from a build this one does not know about loads as the
  ## world it describes rather than being emptied by a table lookup that missed.
  for (modeId, couplings) in LEGACY_MODE_COUPLINGS:
    if modeId == modeName: return couplings
  LegacyCouplings(keepForces: true, keepFluid: false, keepChemistry: true)

proc migrate*(node: JsonNode; fromVersion: int): JsonNode =
  ## Upgrades a preset JSON node from `fromVersion` to CURRENT_SCHEMA_VERSION.
  ## Steps fall through, so a preset many versions old still upgrades in one
  ## call.
  result = node
  if fromVersion < 2:
    # v1 -> v2: modes become strengths. The mode says which of the values this
    # file carries are live; every other coupling strength zeroes. Written onto
    # the settings node so the ordinary clamp path validates the result — a
    # translation bypassing validateSettings is a second, unclamped way in.
    let settings = field(result, "settings")
    if settings != nil and settings.kind == JObject:
      let legacy = legacyCouplingsFor(field(result, "mode").getStr(""))
      if not legacy.keepForces:
        settings["forceStrength"] = %0.0
      if not legacy.keepChemistry:
        settings["rdDeposit"] = %0.0
        settings["rdFieldForce"] = %0.0
      elif settings.hasKey("rdFieldForce"):
        # RESCALE RATHER THAN CLAMP. A v1 field force is a number of WORLD
        # units per unit of gradient per FIELD CELL, so it only means what it
        # meant while the cell covered what it covered. The field grid is finer
        # than the one v1 wrote against, and the ceiling came down by the same
        # factor to hold a particle's response fixed
        # (field_core.RD_DEFAULT_FIELD_FORCE derives it), so a v1 value carried
        # over verbatim would clamp to the new maximum and land stronger than
        # the world it was saved from. Scaling it restores that world; clamping
        # would silently rewrite it.
        settings["rdFieldForce"] =
          %(field(settings, "rdFieldForce").getFloat(0.0) * V1_FIELD_FORCE_SCALE)
      # v1 carries no fluidStrength to keep or drop, so this derives one: a
      # v1 fluid world runs its fluid at full effect, every other runs none.
      settings["fluidStrength"] = %(if legacy.keepFluid: 1.0 else: 0.0)
      # Pinned, not defaulted. A v1 file has no crowding strength field, so
      # every world it describes runs the force law without one. Letting the
      # field default would hand that world the shipped default the moment
      # the default moves off zero, changing a value the file never
      # specified. Written unconditionally, so a v1 file that somehow carries
      # the key is overwritten rather than trusted.
      settings["crowdingStrength"] = %0.0
      # Pinned for the same reason, at the other end of its range. A v1 file's
      # smoothing radius is always the whole interaction radius — the only
      # kernel a v1 fluid describes — not the shipped default, which sits
      # below 1. Defaulting instead would rescale every migrated fluid the
      # moment that default changes. Written unconditionally, so a v1 file
      # that somehow carries the key is overwritten rather than trusted.
      settings["sphRadiusFraction"] = %1.0
  if fromVersion < 3:
    # v2 -> v3: the species ceiling grew from 6 to 8, so the flattened
    # row-major matrix restrides — old index i (row i div 6, col i mod 6)
    # keeps its row and column, and every slot in a new row or column stays
    # 0 (neutral). Without the remap, elemAt's nil-safe reads would scramble
    # the matrix silently: old index 6 (row 1, col 0) lands at row 0, col 6.
    # Chemistry and palette are indexed per species slot, so their new slots
    # repair with defaults through the ordinary validation path.
    let oldMatrix = field(result, "matrix")
    if oldMatrix != nil and oldMatrix.kind == JArray:
      var restrided = newSeq[JsonNode](MATRIX_LEN)
      for slot in 0 ..< MATRIX_LEN:
        restrided[slot] = %0.0
      for oldIndex in 0 ..< min(oldMatrix.len, OLD_MAX_SPECIES * OLD_MAX_SPECIES):
        let newIndex = (oldIndex div OLD_MAX_SPECIES) * MAX_SPECIES +
          (oldIndex mod OLD_MAX_SPECIES)
        restrided[newIndex] = oldMatrix[oldIndex]
      result["matrix"] = %restrided

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
      settings: validateSettings(field(working, "settings")),
      matrix: validateMatrix(field(working, "matrix")),
      chemistry: validateChemistry(field(working, "chemistry")),
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
  except ValueError as err:
    return PresetLoadResult(
      preset: defaultPreset(),
      errorKind: pekInvalidJson,
      errorMessage: "malformed JSON: " & err.msg)
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
  result["crowdingStrength"] = %settings.crowdingStrength
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
  result["glowRadiusScale"] = %settings.glowRadiusScale
  result["glowFalloff"] = %settings.glowFalloff
  result["glowWarmth"] = %settings.glowWarmth
  result["fluidStrength"] = %settings.fluidStrength
  result["sphRestDensity"] = %settings.sphRestDensity
  result["sphStiffness"] = %settings.sphStiffness
  result["sphRadiusFraction"] = %settings.sphRadiusFraction
  result["sphViscosity"] = %settings.sphViscosity
  result["sphSubsteps"] = %settings.sphSubsteps
  result["rdFeed"] = %settings.rdFeed
  result["rdKill"] = %settings.rdKill
  result["rdDeposit"] = %settings.rdDeposit
  result["rdFieldForce"] = %settings.rdFieldForce
  result["climateDrift"] = %settings.climateDrift
  result["climateSpeed"] = %settings.climateSpeed
  result["forceWeather"] = %settings.forceWeather
  result["forceWeatherSpeed"] = %settings.forceWeatherSpeed
  result["bloomEnabled"] = %settings.bloomEnabled
  result["bloomIntensity"] = %settings.bloomIntensity
  result["exposure"] = %settings.exposure
  result["saturation"] = %settings.saturation
  result["contrast"] = %settings.contrast
  result["temperature"] = %settings.temperature
  result["colormapIndex"] = %settings.colormapIndex
  result["fieldOpacity"] = %settings.fieldOpacity

proc toJson*(preset: Preset): JsonNode =
  result = newJObject()
  result["schemaVersion"] = %preset.schemaVersion
  result["name"] = %preset.name
  result["createdAt"] = %preset.createdAt
  result["settings"] = toJson(preset.settings)

  var matrixArr = newJArray()
  for matrixValue in preset.matrix:
    matrixArr.add(%matrixValue)
  result["matrix"] = matrixArr

  var chemistryArr = newJArray()
  for chemistryValue in preset.chemistry:
    chemistryArr.add(%chemistryValue)
  result["chemistry"] = chemistryArr

  var paletteArr = newJArray()
  for color in preset.palette:
    var colorArr = newJArray()
    for channel in color:
      colorArr.add(%channel)
    paletteArr.add(colorArr)
  result["palette"] = paletteArr

proc toJsonString*(preset: Preset): string =
  $toJson(preset)
