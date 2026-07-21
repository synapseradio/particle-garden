# ==============================================================================
# PARAM DESCRIPTOR - The tunable-parameter contract for the UI layer (Pure)
# ==============================================================================
#
# One descriptor per user-facing tunable: id (the CONFIG field name), display
# label and group, value kind, range, step, precision, default, and which
# mutation path a write routes through. The TypeScript control panel reads
# this table via window.gardenAPI.descriptor() instead of duplicating any
# number, and web_api clamps every setParam against it — the clamp authority
# that used to live in slider.nim.
#
# Ranges come from config_ranges (the range authority) and defaults from the
# typed state records (the default authority); tests/test_param_descriptor.nim
# pins both relations natively, so the UI and the simulation cannot drift.
#
# Pure module: no FFI, no DOM. Compiles on both the native (nimble test) and
# JS backends.
#
# ==============================================================================

import std/math
import ../../config_ranges
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

  ParamDescriptor* = object
    id*: string           ## CONFIG field name (or palette state field)
    label*: string        ## Display label (verbatim from the control panel)
    group*: string        ## Stable group id the UI sections key on
    kind*: ParamKind
    minValue*: float
    maxValue*: float
    step*: float          ## Slider step: 1 for ints, 10^-precision for floats
    precision*: int       ## Decimal places for display (0 for ints)
    defaultValue*: float
    store*: ParamStore
    reinitOnCommit*: bool ## Commit triggers a particle re-initialization

func paramStep(kind: ParamKind; precision: int): float =
  ## The step rule slider.nim's bindToDOM used: ints step by 1; floats step
  ## by one unit of their display precision.
  case kind
  of pkInt: 1.0
  of pkFloat:
    if precision <= 0: 1.0 else: pow(10.0, -float(precision))

func intParam(id, label, group: string; minValue, maxValue, defaultValue: int;
    store: ParamStore; reinitOnCommit = false): ParamDescriptor =
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkInt,
    minValue: minValue.float, maxValue: maxValue.float,
    step: paramStep(pkInt, 0), precision: 0,
    defaultValue: defaultValue.float, store: store,
    reinitOnCommit: reinitOnCommit)

func floatParam(id, label, group: string;
    minValue, maxValue, defaultValue: float; precision: int;
    store: ParamStore): ParamDescriptor =
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkFloat,
    minValue: minValue, maxValue: maxValue,
    step: paramStep(pkFloat, precision), precision: precision,
    defaultValue: defaultValue, store: store,
    reinitOnCommit: false)

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
      psSimulation, reinitOnCommit = true),
    intParam("speciesCount", "Species", "simulation",
      SPECIES_COUNT_MIN, SPECIES_COUNT_MAX, sim.speciesCount,
      psSimulation, reinitOnCommit = true),
    intParam("interactionRadius", "Interaction Radius", "simulation",
      INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX, sim.interactionRadius,
      psSimulation),
    floatParam("forceStrength", "Force Strength", "simulation",
      FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX, sim.forceStrength, 1,
      psSimulation),
    floatParam("friction", "Friction", "simulation",
      FRICTION_MIN, FRICTION_MAX, sim.friction, 2, psSimulation),
    floatParam("timeScale", "Time Scale", "simulation",
      TIME_SCALE_MIN, TIME_SCALE_MAX, sim.timeScale, 1, psSimulation),
    floatParam("ruleTemperature", "🌡️ Temperature", "simulation",
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

    # SPH Fluid section
    floatParam("sphRestDensity", "Rest Density", "sph",
      SPH_REST_DENSITY_MIN, SPH_REST_DENSITY_MAX, sim.sphRestDensity, 2,
      psSimulation),
    floatParam("sphStiffness", "Stiffness", "sph",
      SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX, sim.sphStiffness, 1,
      psSimulation),
    floatParam("sphViscosity", "Viscosity", "sph",
      SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX, sim.sphViscosity, 2,
      psSimulation),
    intParam("sphSubsteps", "Substeps", "sph",
      SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX, sim.sphSubsteps, psSimulation),

    # Reaction-Diffusion section
    floatParam("rdFeed", "Feed (F)", "rd",
      RD_FEED_MIN, RD_FEED_MAX, sim.rdFeed, 3, psSimulation),
    floatParam("rdKill", "Kill (k)", "rd",
      RD_KILL_MIN, RD_KILL_MAX, sim.rdKill, 3, psSimulation),
    floatParam("fieldOpacity", "Field Opacity", "rd",
      FIELD_OPACITY_RANGE_MIN, FIELD_OPACITY_RANGE_MAX, visual.fieldOpacity,
      2, psRender),
  ]

func clampParamValue*(descriptor: ParamDescriptor; value: float): float =
  ## Coerce a raw UI value into the descriptor's range. Integer parameters
  ## additionally truncate through int(), the same coercion slider.nim's
  ## clampValue applied, so a drag position lands on the same value it
  ## always did.
  let clamped = max(descriptor.minValue, min(descriptor.maxValue, value))
  case descriptor.kind
  of pkInt: float(int(clamped))
  of pkFloat: clamped
