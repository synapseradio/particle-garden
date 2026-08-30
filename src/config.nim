# ==============================================================================
# PARTICLE GARDEN - CONFIGURATION MODULE
# ==============================================================================
#
# Configuration and constants for Particle Garden simulation.
#
# IMPORTANT: Memory layout constants are defined in memory_layout.nim.
# This module re-exports them for JS consumption.
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays
import memory_layout
import field_core
import palette
import ui/state/simulation_state
import ui/state/render_state

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  ConfigObject* = ref object of JsObject
    ## Flat GPU-facing mirror of the typed records. Field semantics live on
    ## SimulationState (simulation_state.nim) and RenderState (render_state.nim);
    ## colormapIndex values are colormap_core.nim's COLORMAP_INDEX_* constants.
    particleCount* {.exportc.}: int
    speciesCount* {.exportc.}: int
    interactionRadius* {.exportc.}: int
    forceStrength* {.exportc.}: float
    crowdingStrength* {.exportc.}: float
    friction* {.exportc.}: float
    ruleWildness* {.exportc.}: float
    timeScale* {.exportc.}: float
    particleSize* {.exportc.}: int
    trails* {.exportc.}: bool
    trailLength* {.exportc.}: float
    glowIntensity* {.exportc.}: float
    velocityGlowScale* {.exportc.}: float
    maxVelocity* {.exportc.}: float
    repulsionEnd* {.exportc.}: float
    attractionPeak* {.exportc.}: float
    forceModel* {.exportc.}: int
    expRepulsionAlpha* {.exportc.}: float
    expAttractionBeta* {.exportc.}: float
    glowRadiusScale* {.exportc.}: float
    glowFalloff* {.exportc.}: float
    glowWarmth* {.exportc.}: float
    bloomEnabled* {.exportc.}: bool
    bloomIntensity* {.exportc.}: float
    exposure* {.exportc.}: float
    saturation* {.exportc.}: float
    contrast* {.exportc.}: float
    temperature* {.exportc.}: float
    colormapIndex* {.exportc.}: int
    fieldOpacity* {.exportc.}: float
    fluidStrength* {.exportc.}: float
    sphRestDensity* {.exportc.}: float
    sphStiffness* {.exportc.}: float
    sphRadiusFraction* {.exportc.}: float
    sphViscosity* {.exportc.}: float
    sphSubsteps* {.exportc.}: int
    rdFeed* {.exportc.}: float
    rdKill* {.exportc.}: float
    rdDeposit* {.exportc.}: float
    rdFieldForce* {.exportc.}: float
    climateDrift* {.exportc.}: bool
    climateSpeed* {.exportc.}: float
    forceWeather* {.exportc.}: bool
    forceWeatherSpeed* {.exportc.}: float
    cameraDrift* {.exportc.}: bool
    cameraDriftSpeed* {.exportc.}: float

  MemoryLayoutObject* = ref object of JsObject
    ## AoS memory layout offsets for particle buffers.
    ## Values and field semantics: memory_layout.OFFSETS (MemoryOffsets).
    particlesA* {.exportc.}: int
    particlesSorted* {.exportc.}: int
    sortedIndices* {.exportc.}: int
    reverseIndices* {.exportc.}: int
    velocityDeltaFixed* {.exportc.}: int
    gridCounts* {.exportc.}: int
    gridOffsets* {.exportc.}: int
    matrix* {.exportc.}: int
    sync* {.exportc.}: int
    totalSize* {.exportc.}: int

# ==============================================================================
# SECTION 2: BUFFER ALLOCATION LIMITS (re-exported from memory_layout)
# ==============================================================================

let MAX_PARTICLES* {.exportc.}: int = memory_layout.MAX_PARTICLES
let MAX_SPECIES* {.exportc.}: int = memory_layout.MAX_SPECIES
let MAX_GRID* {.exportc.}: int = memory_layout.MAX_GRID

# ==============================================================================
# SECTION 2b: PARTICLE STRUCT LAYOUT (re-exported from memory_layout)
# ==============================================================================

let PARTICLE_STRIDE* {.exportc.}: int = memory_layout.PARTICLE_STRIDE
let PARTICLE_POS_X_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_POS_X_OFFSET
let PARTICLE_POS_Y_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_POS_Y_OFFSET
let PARTICLE_VEL_X_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_VEL_X_OFFSET
let PARTICLE_VEL_Y_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_VEL_Y_OFFSET
let PARTICLE_SPECIES_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_SPECIES_OFFSET
let PARTICLE_DENSITY_OFFSET* {.exportc.}: int = memory_layout.PARTICLE_DENSITY_OFFSET

# ==============================================================================
# SECTION 3: WORLD DIMENSIONS (decoupled from canvas/display)
# ==============================================================================

# Fixed world size for physics simulation. This is independent of canvas/display
# resolution. Using 4K as reference ensures consistent particle density and
# physics behavior across all display sizes.
let WORLD_W* {.exportc.}: float = 3840.0
let WORLD_H* {.exportc.}: float = 2160.0

# ==============================================================================
# SECTION 4: SHARED BUFFER CONFIGURATION (re-exported from memory_layout)
# ==============================================================================

let WASM_MEMORY_PAGES* {.exportc.}: int = memory_layout.WASM_MEMORY_PAGES
let WASM_MEMORY_PAGES_MAX* {.exportc.}: int = memory_layout.WASM_MEMORY_PAGES_MAX
let WASM_DATA_OFFSET* {.exportc.}: int = memory_layout.WASM_DATA_OFFSET

# ==============================================================================
# SECTION 5: MEMORY LAYOUT (sourced from memory_layout.OFFSETS)
# ==============================================================================

proc createMemoryLayout(): MemoryLayoutObject =
  ## Convert memory_layout.OFFSETS to a JS-exportable object.
  result = MemoryLayoutObject()
  result.particlesA = memory_layout.OFFSETS.particlesA
  result.particlesSorted = memory_layout.OFFSETS.particlesSorted
  result.sortedIndices = memory_layout.OFFSETS.sortedIndices
  result.reverseIndices = memory_layout.OFFSETS.reverseIndices
  result.velocityDeltaFixed = memory_layout.OFFSETS.velocityDeltaFixed
  result.gridCounts = memory_layout.OFFSETS.gridCounts
  result.gridOffsets = memory_layout.OFFSETS.gridOffsets
  result.matrix = memory_layout.OFFSETS.matrix
  result.sync = memory_layout.OFFSETS.sync
  result.totalSize = memory_layout.OFFSETS.totalSize

var MEMORY_LAYOUT* {.exportc.}: MemoryLayoutObject = createMemoryLayout()

# ==============================================================================
# SECTION 6: RUNTIME CONFIGURATION
# ==============================================================================

proc createConfig(): ConfigObject =
  ## Copy the authoritative defaults from the pure typed records (natively
  ## tested in tests/test_sim_config.nim) into the flat GPU-facing mirror.
  ## Never write a default literal here; it belongs in simulation_state or
  ## render_state.
  let sim = initSimulationState()
  let visual = initRenderState()
  result = ConfigObject()
  result.particleCount = sim.particleCount
  result.speciesCount = sim.speciesCount
  result.interactionRadius = sim.interactionRadius
  result.forceStrength = sim.forceStrength
  result.crowdingStrength = sim.crowdingStrength
  result.friction = sim.friction
  result.ruleWildness = sim.ruleWildness
  result.timeScale = sim.timeScale
  result.maxVelocity = sim.maxVelocity
  result.repulsionEnd = sim.repulsionEnd
  result.attractionPeak = sim.attractionPeak
  result.forceModel = sim.forceModel
  result.expRepulsionAlpha = sim.expRepulsionAlpha
  result.expAttractionBeta = sim.expAttractionBeta
  result.fluidStrength = sim.fluidStrength
  result.sphRestDensity = sim.sphRestDensity
  result.sphStiffness = sim.sphStiffness
  result.sphRadiusFraction = sim.sphRadiusFraction
  result.sphViscosity = sim.sphViscosity
  result.sphSubsteps = sim.sphSubsteps
  result.rdFeed = sim.rdFeed
  result.rdKill = sim.rdKill
  result.rdDeposit = sim.rdDeposit
  result.rdFieldForce = sim.rdFieldForce
  result.climateDrift = sim.climateDrift
  result.climateSpeed = sim.climateSpeed
  result.forceWeather = sim.forceWeather
  result.forceWeatherSpeed = sim.forceWeatherSpeed
  result.particleSize = visual.particleSize
  result.trails = visual.trails
  result.trailLength = visual.trailLength
  result.glowIntensity = visual.glowIntensity
  result.velocityGlowScale = visual.velocityGlowScale
  result.glowRadiusScale = visual.glowRadiusScale
  result.glowFalloff = visual.glowFalloff
  result.glowWarmth = visual.glowWarmth
  result.bloomEnabled = visual.bloomEnabled
  result.bloomIntensity = visual.bloomIntensity
  result.exposure = visual.exposure
  result.saturation = visual.saturation
  result.contrast = visual.contrast
  result.temperature = visual.temperature
  result.colormapIndex = visual.colormapIndex
  result.fieldOpacity = visual.fieldOpacity
  result.cameraDrift = visual.cameraDrift
  result.cameraDriftSpeed = visual.cameraDriftSpeed

var CONFIG* {.exportc.}: ConfigObject = createConfig()

# ==============================================================================
# SECTION 7: COLOR PALETTE
# ==============================================================================
#
# COLORS holds one interleaved RGB triple per species, up to MAX_SPECIES.
# The default palette is the bright Open Color swatch set (psOpenColor —
# a user directive; see palette.nim's OPEN_COLOR_SWATCHES for provenance).
# MAX_SPECIES is defined in memory_layout.nim (the AoS/matrix contract)
# and re-exported above.

var COLORS* {.exportc.}: Float32Array =
  newFloat32Array(flattenPalette(generatePalette(MAX_SPECIES, psOpenColor)))

# ==============================================================================
# SECTION 8: SPECIES CHEMISTRY
# ==============================================================================
#
# SPECIES_CHEMISTRY holds one (secretion, tropism) pair per species slot, up to
# MAX_SPECIES, interleaved at SPECIES_CHEMISTRY_STRIDE. It sits beside COLORS
# rather than in the SharedArrayBuffer because no worker reads it: the frame
# loop copies it into the SpeciesChemistry uniform, and the control panel edits
# it in place through gardenAPI, exactly as it edits the attraction matrix.
#
# Every slot carries field_core's defaults, including the ones above the active
# speciesCount — growing the species count then exposes a defaulted species
# rather than one coupled to the field by whatever was left in memory.

var SPECIES_CHEMISTRY* {.exportc.}: Float32Array = block:
  let values = newFloat32Array(MAX_SPECIES * SPECIES_CHEMISTRY_STRIDE)
  for speciesIndex in 0 ..< MAX_SPECIES:
    let base = speciesIndex * SPECIES_CHEMISTRY_STRIDE
    values[base + SPECIES_SECRETION_SLOT] = RD_DEFAULT_SECRETION
    values[base + SPECIES_TROPISM_SLOT] = RD_DEFAULT_TROPISM
  values
