# ==============================================================================
# PARAM DESCRIPTOR - The tunable-parameter contract for the UI layer (Pure)
# ==============================================================================
#
# One descriptor per user-facing tunable: id (the CONFIG field name), display
# label and group, value kind, range, step, precision, default, and which
# mutation path a write routes through. The TypeScript control panel reads
# this table via window.gardenAPI.descriptor() instead of duplicating any
# number, and web_api clamps every setParam against it — the one clamp
# authority.
#
# Ranges come from config_ranges (the range authority) and defaults from the
# typed state records (the default authority); tests/test_param_descriptor.nim
# pins both relations natively, so the UI and the simulation cannot drift.
#
# Pure module: no FFI, no DOM. Compiles on both the native (just test) and
# JS backends.
#
# ==============================================================================

import std/math
import ../../config_ranges
import ../../camera_core
import ../../field_core
import ../../palette
import ../state/simulation_state
import ../state/render_state

type
  ParamKind* = enum
    pkInt    ## Integer values (counts, radius, size, substeps)
    pkFloat  ## Floating point values

  ParamStore* = enum
    ## Which mutation path a parameter write routes through.
    psSimulation  ## updateSimulation -> CONFIG (physics mirror)
    psRender      ## updateRender -> CONFIG (visual mirror)
    psPalette     ## palette editor state -> COLORS regeneration
    psCamera      ## the live camera -> webgpu_render, NOT CONFIG
      ## The camera is VIEW state, not world state, and this is the whole
      ## reason it needs its own route. It is deliberately absent from CONFIG
      ## and therefore from the preset schema: a preset restores a world, and
      ## should not also seize where the user is standing to look at it.
      ## Loading a preset and being teleported reads as a bug, not a feature.
      ## `0` on the keyboard is the way back, and it cannot itself get lost.

  ParamNotch* = object
    ## A value on a slider worth stopping at, and what to call it.
    ##
    ## A notch is a CLAIM: that this particular position produces something
    ## worth seeing. The track stays continuous everywhere else — a notch marks
    ## the map, it does not fence the road. Where the claim comes from a
    ## published or measured value, that value lives beside the range it must
    ## satisfy (in config_ranges or the core module that measured it), never as
    ## a literal in the panel, so a range change and a notch change cannot
    ## drift apart. tests/test_param_descriptor.nim asserts every notch lies
    ## inside its own parameter's range.
    value*: float
    label*: string

  ParamDescriptor* = object
    id*: string           ## CONFIG field name (or palette state field)
    label*: string        ## Display label (verbatim from the control panel)
    group*: string        ## Stable group id the panel's sections key on. It
                          ## decides where a control sits, never whether it
                          ## appears: one world offers every control always.
    kind*: ParamKind
    minValue*: float
    maxValue*: float
    step*: float          ## Slider step: 1 for ints, 10^-precision for floats
    precision*: int       ## Decimal places for display (0 for ints)
    defaultValue*: float
    store*: ParamStore
    reinitOnCommit*: bool ## Commit triggers a particle re-initialization
    hint*: string         ## Optional one-line guidance rendered under the
                          ## slider. Empty for most parameters. Lives here, not
                          ## in the panel, because any value a hint names has to
                          ## be a position the slider can actually reach —
                          ## a property only the range, step and precision
                          ## beside it can settle.
    notches*: seq[ParamNotch]
                          ## Labelled positions worth stopping at. Empty for
                          ## most parameters — a notch is only warranted where
                          ## a specific value is known to produce something,
                          ## and inventing one would be the same defect as a
                          ## hint naming an unreachable number.

func notch(value: float; label: string): ParamNotch =
  ParamNotch(value: value, label: label)

type RegimeAxis* = enum
  ## Which coordinate of a named regime a slider carries. Feed and kill each
  ## show all six regimes, because a notch on one axis alone does not locate a
  ## regime — that is what the regime buttons are for.
  regimeFeed
  regimeKill

func regimeNotches*(axis: RegimeAxis): seq[ParamNotch] =
  ## The six named regimes as notches on one axis, in RD_REGIMES order.
  for regime in RD_REGIMES:
    result.add notch(
      (case axis
       of regimeFeed: regime.feed
       of regimeKill: regime.kill),
      regime.label)

func paramStep(kind: ParamKind; precision: int): float =
  ## The step rule: ints step by 1; floats step by one unit of their display
  ## precision.
  case kind
  of pkInt: 1.0
  of pkFloat:
    if precision <= 0: 1.0 else: pow(10.0, -float(precision))

func intParam(id, label, group: string; minValue, maxValue, defaultValue: int;
    store: ParamStore; reinitOnCommit = false;
    notches: seq[ParamNotch] = @[]): ParamDescriptor =
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkInt,
    minValue: minValue.float, maxValue: maxValue.float,
    step: paramStep(pkInt, 0), precision: 0,
    defaultValue: defaultValue.float, store: store,
    reinitOnCommit: reinitOnCommit, notches: notches)

func floatParam(id, label, group: string;
    minValue, maxValue, defaultValue: float; precision: int;
    store: ParamStore; hint = "";
    notches: seq[ParamNotch] = @[]): ParamDescriptor =
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkFloat,
    minValue: minValue, maxValue: maxValue,
    step: paramStep(pkFloat, precision), precision: precision,
    defaultValue: defaultValue, store: store,
    reinitOnCommit: false, hint: hint, notches: notches)

func withDefaultNotch(descriptor: ParamDescriptor;
    position: Natural): ParamDescriptor =
  ## The descriptor carrying a notch at its own defaultValue, spliced in at
  ## `position` so the notch list keeps the order the panel reads it in.
  ##
  ## Reading the value off the built descriptor rather than naming it a second
  ## time is what keeps the marked position and the value a reset returns to
  ## from drifting apart: they are one number with one source.
  result = descriptor
  result.notches.insert(notch(descriptor.defaultValue, "default"), position)

func buildParamDescriptors*(): seq[ParamDescriptor] =
  ## The full tunable inventory, in the order the control panel presents it.
  ## Group ids are stable interface strings the UI keys sections on; the
  ## force-polynomial/force-exponential split mirrors the show/hide the
  ## force-model buttons perform.
  let sim = initSimulationState()
  let visual = initRenderState()
  @[
    # Main simulation sliders
    intParam("particleCount", "Particles", "simulation",
      PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX, sim.particleCount,
      psSimulation, reinitOnCommit = true).withDefaultNotch(0),
    intParam("speciesCount", "Species", "simulation",
      SPECIES_COUNT_MIN, SPECIES_COUNT_MAX, sim.speciesCount,
      psSimulation, reinitOnCommit = true),
    # "grid" rather than "simulation": interactionRadius is the neighbor search
    # radius forces.wgsl uses and the smoothing radius forces-sph.wgsl uses.
    # The group says where the control sits, never whether it appears.
    intParam("interactionRadius", "Interaction Radius", "grid",
      INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX, sim.interactionRadius,
      psSimulation),
    # A coupling strength, and its zero notch says so. Zero removes short-range
    # repulsion along with attraction (fMul scales both force zones), so
    # particles pass freely through each other — hence a notch label naming
    # what happens rather than "off".
    floatParam("forceStrength", "Force Strength", "species",
      FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX, sim.forceStrength, 1,
      psSimulation,
      notches = @[
        notch(FORCE_STRENGTH_MIN, "no forces"),
      ]).withDefaultNotch(1),
    floatParam("friction", "Friction", "simulation",
      FRICTION_MIN, FRICTION_MAX, sim.friction, 2, psSimulation),
    floatParam("timeScale", "Time Scale", "simulation",
      TIME_SCALE_MIN, TIME_SCALE_MAX, sim.timeScale, 1, psSimulation),
    floatParam("ruleTemperature", "🌡️ Temperature", "species",
      RULE_TEMPERATURE_MIN, RULE_TEMPERATURE_MAX, sim.ruleTemperature, 2,
      psSimulation),
    floatParam("maxVelocity", "Max Velocity", "simulation",
      MAX_VELOCITY_MIN, MAX_VELOCITY_MAX, sim.maxVelocity, 0, psSimulation),

    # Render sliders (outside the collapsible sections)
    intParam("particleSize", "Particle Size", "render",
      PARTICLE_SIZE_MIN, PARTICLE_SIZE_MAX, visual.particleSize, psRender),
    floatParam("trailLength", "Trail Length", "render",
      TRAIL_LENGTH_MIN, TRAIL_LENGTH_MAX, visual.trailLength, 0, psRender),

    # Glow section
    floatParam("glowIntensity", "Intensity", "glow",
      GLOW_INTENSITY_MIN, GLOW_INTENSITY_MAX, visual.glowIntensity, 1,
      psRender),
    floatParam("velocityGlowScale", "Velocity Sweep", "glow",
      VELOCITY_GLOW_SCALE_MIN, VELOCITY_GLOW_SCALE_MAX,
      visual.velocityGlowScale, 1, psRender),
    floatParam("glowRadiusScale", "Halo Radius", "glow",
      GLOW_RADIUS_SCALE_MIN, GLOW_RADIUS_SCALE_MAX, visual.glowRadiusScale, 1,
      psRender),
    floatParam("glowFalloff", "Halo Falloff", "glow",
      GLOW_FALLOFF_MIN, GLOW_FALLOFF_MAX, visual.glowFalloff, 1, psRender),
    floatParam("glowWarmth", "Warmth", "glow",
      GLOW_WARMTH_MIN, GLOW_WARMTH_MAX, visual.glowWarmth, 2, psRender),

    # Bloom & Grade section
    floatParam("bloomIntensity", "Bloom Intensity", "bloom",
      BLOOM_INTENSITY_MIN, BLOOM_INTENSITY_MAX, visual.bloomIntensity, 2,
      psRender),
    floatParam("exposure", "Exposure", "bloom",
      EXPOSURE_MIN, EXPOSURE_MAX, visual.exposure, 2, psRender),
    floatParam("saturation", "Saturation", "bloom",
      SATURATION_MIN, SATURATION_MAX, visual.saturation, 2, psRender),
    floatParam("contrast", "Contrast", "bloom",
      CONTRAST_MIN, CONTRAST_MAX, visual.contrast, 2, psRender),
    floatParam("temperature", "Temperature", "bloom",
      TEMPERATURE_MIN, TEMPERATURE_MAX, visual.temperature, 2, psRender),

    # Force Model section (polynomial vs exponential parameter pairs)
    floatParam("repulsionEnd", "Repulsion End", "force-polynomial",
      REPULSION_END_MIN, REPULSION_END_MAX, sim.repulsionEnd, 2,
      psSimulation),
    floatParam("attractionPeak", "Attraction Peak", "force-polynomial",
      ATTRACTION_PEAK_MIN, ATTRACTION_PEAK_MAX, sim.attractionPeak, 2,
      psSimulation),
    floatParam("expRepulsionAlpha", "Repulsion α", "force-exponential",
      EXP_REPULSION_ALPHA_MIN, EXP_REPULSION_ALPHA_MAX,
      sim.expRepulsionAlpha, 2, psSimulation),
    floatParam("expAttractionBeta", "Attraction β", "force-exponential",
      EXP_ATTRACTION_BETA_MIN, EXP_ATTRACTION_BETA_MAX,
      sim.expAttractionBeta, 2, psSimulation),

    # Palette section (routes to the palette editor state, not CONFIG)
    floatParam("paletteSaturation", "Saturation", "palette",
      PALETTE_SATURATION_MIN, PALETTE_SATURATION_MAX, DEFAULT_SATURATION, 2,
      psPalette),
    floatParam("paletteLightness", "Lightness", "palette",
      PALETTE_LIGHTNESS_MIN, PALETTE_LIGHTNESS_MAX, DEFAULT_LIGHTNESS, 2,
      psPalette),

    # SPH Fluid section. fluidStrength leads it because it is the coupling
    # strength and the three below it are the fluid's character: they say what
    # KIND of fluid this is — how hard it resists compression, what spacing it
    # relaxes to, how fast it shears — while this one says how much of that
    # fluid's verdict on a particle's velocity actually lands (design D14).
    floatParam("fluidStrength", "Fluid", "fluid",
      FLUID_STRENGTH_MIN, FLUID_STRENGTH_MAX, sim.fluidStrength, 2,
      psSimulation,
      hint = "how much of the fluid acts; the three below shape what kind of fluid it is",
      notches = @[
        notch(FLUID_STRENGTH_MIN, "no fluid"),
        notch(FLUID_STRENGTH_MAX, "full"),
      ]),
    floatParam("sphRestDensity", "Rest Density", "fluid",
      SPH_REST_DENSITY_MIN, SPH_REST_DENSITY_MAX, sim.sphRestDensity, 2,
      psSimulation),
    floatParam("sphStiffness", "Stiffness", "fluid",
      SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX, sim.sphStiffness, 1,
      psSimulation),
    floatParam("sphViscosity", "Viscosity", "fluid",
      SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX, sim.sphViscosity, 2,
      psSimulation),
    intParam("sphSubsteps", "Substeps", "fluid",
      SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX, sim.sphSubsteps, psSimulation),

    # Reaction-Diffusion section. Feed and kill carry the six named regimes as
    # notches, so the living parts of the plane are positions the user can
    # reach by name instead of by accident. The coordinates live in
    # config_ranges beside the ranges they must satisfy, and no hint restates
    # them: a hint naming values the notches already mark is a second copy free
    # to drift from the (0.082, 0.059) the regime table transcribes.
    floatParam("rdFeed", "Breath In", "rd",
      RD_FEED_MIN, RD_FEED_MAX, sim.rdFeed, 3, psSimulation,
      hint = "the feed rate F; a regime needs both axes, so the buttons set the pair",
      notches = regimeNotches(regimeFeed)),
    floatParam("rdKill", "Breath Out", "rd",
      RD_KILL_MIN, RD_KILL_MAX, sim.rdKill, 3, psSimulation,
      hint = "the kill rate k; a regime needs both axes, so the buttons set the pair",
      notches = regimeNotches(regimeKill)),
    # "Secretion Rate", not "Secretion": the per-species chemistry grid has a
    # Secretion column too, and the two are different KINDS of quantity — this
    # is the base amount every particle lays down, that is each species' signed
    # share of it. Two controls under one word would leave a user unable to
    # tell which they were looking at. Each hint names the other.
    floatParam("rdDeposit", "Secretion Rate", "rd",
      RD_DEPOSIT_MIN, RD_DEPOSIT_MAX, sim.rdDeposit, 3, psSimulation,
      hint = "base amount every particle lays down; each species scales it " &
        "in Species Chemistry. 0 leaves the pattern undisturbed",
      notches = @[
        notch(RD_DEPOSIT_MIN, "inert"),
        # The measured floor for Worms and Coral to appear at all. Without it
        # those two regimes are dead buttons — see RD_REGIMES' minDeposit.
        notch(RD_REGIME_HIGH_FEED_DEPOSIT, "high-feed"),
      ]).withDefaultNotch(1),
    # One decimal, where the other strengths take none: the range divides by
    # FIELD_PATTERN_SHRINK (field_core.RD_DEFAULT_FIELD_FORCE says why), so the
    # default and the ceiling stop landing on whole numbers as the field grid
    # gets finer. A slider that cannot stop on its own default is a broken one.
    floatParam("rdFieldForce", "Scent-following", "rd",
      RD_FIELD_FORCE_MIN, RD_FIELD_FORCE_MAX, sim.rdFieldForce, 1,
      psSimulation,
      hint = "how hard the pattern pushes particles; 0 leaves them blind",
      notches = @[
        notch(RD_FIELD_FORCE_MIN, "blind"),
      ]).withDefaultNotch(1),
    floatParam("climateSpeed", "Drift", "rd",
      CLIMATE_SPEED_MIN, CLIMATE_SPEED_MAX, sim.climateSpeed, 2, psSimulation,
      hint = "tours of the named regimes per minute, while Weather is on"),
    # "rd-field" rather than "rd": this is the field's appearance, not its
    # physics, and the panel puts the colormap selector between the two groups.
    floatParam("fieldOpacity", "Field Opacity", "rd-field",
      FIELD_OPACITY_RANGE_MIN, FIELD_OPACITY_RANGE_MAX, visual.fieldOpacity,
      2, psRender),
    # The camera. psCamera, not psRender: this writes the live view, never
    # CONFIG, so it stays out of the preset schema for the reason recorded on
    # the enum. Its notches name the two scales worth stopping at rather than
    # positions on a number line — world is the whole world fitted to the
    # window and the widest view the slider offers, creature is close enough
    # that the attraction matrix reads as individual motion.
    floatParam("cameraZoom", "Zoom", "camera",
      CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX, CAMERA_DEFAULT_ZOOM.float, 2, psCamera,
      # No numerals in this hint. The reachability test reads every number a
      # hint names as a slider position, and the zero key is a KEY — spelling it
      # as a digit makes the test report an unreachable value, correctly.
      hint = "the wheel zooms at the cursor; the zero key returns to the whole world",
      notches = @[
        notch(CAMERA_ZOOM_NOTCH_WORLD, "world"),
        notch(CAMERA_ZOOM_NOTCH_CREATURE, "creature"),
      ]),
  ]

# ==============================================================================
# SPECIES CHEMISTRY FIELDS
# ==============================================================================
#
# Secretion and tropism are not sliders on a single CONFIG field — there is one
# of each per species, edited in a grid beside the attraction matrix. They get
# their own small table rather than entries in buildParamDescriptors because
# every consumer of that table assumes one value per id.
#
# The table is what the panel loops over: it carries the slot each field
# occupies in the interleaved chemistry array, so the TypeScript side computes
# an index without knowing what a stride is. Ranges come from config_ranges and
# defaults from field_core, the same two authorities the slider table uses.

type
  ChemistryField* = object
    id*: string           ## Stable id the UI passes back to clamp a value
    label*: string        ## Display label
    slot*: int            ## Index within one species' chemistry stride
    minValue*: float
    maxValue*: float
    step*: float
    precision*: int
    defaultValue*: float
    hint*: string         ## One-line guidance, same role as ParamDescriptor's

func chemistryField(id, label: string; slot: int;
    minValue, maxValue, defaultValue: float; precision: int;
    hint = ""): ChemistryField =
  ChemistryField(
    id: id, label: label, slot: slot,
    minValue: minValue, maxValue: maxValue,
    step: paramStep(pkFloat, precision), precision: precision,
    defaultValue: defaultValue, hint: hint)

func buildChemistryFields*(): seq[ChemistryField] =
  ## The per-species chemistry inventory, in the order the editor shows it.
  @[
    chemistryField("secretion", "Secretion", SPECIES_SECRETION_SLOT,
      SECRETION_MIN, SECRETION_MAX, RD_DEFAULT_SECRETION, 2,
      hint = "this species' share of the Secretion Rate; negative erodes the " &
        "field instead of building it"),
    chemistryField("tropism", "Tropism", SPECIES_TROPISM_SLOT,
      TROPISM_MIN, TROPISM_MAX, RD_DEFAULT_TROPISM, 2,
      hint = "negative flees its own trail, positive chases it"),
  ]

func clampChemistryValue*(field: ChemistryField; value: float): float =
  ## Coerce a raw UI value into the field's range. No integer case: both
  ## chemistry fields are continuous and signed.
  max(field.minValue, min(field.maxValue, value))

func clampParamValue*(descriptor: ParamDescriptor; value: float): float =
  ## Coerce a raw UI value into the descriptor's range. Integer parameters
  ## additionally truncate through int().
  let clamped = max(descriptor.minValue, min(descriptor.maxValue, value))
  case descriptor.kind
  of pkInt: float(int(clamped))
  of pkFloat: clamped
