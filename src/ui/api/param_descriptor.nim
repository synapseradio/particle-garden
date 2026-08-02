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
# How many values a tunable stands for is a member of the descriptor (see
# ParamArity), not a reason for a second table: the per-species chemistry
# columns answer to the same range, default, step, clamp and notch rules the
# sliders do, and the panel branches on the arity to draw a grid row instead
# of a slider.
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
import ../../sph_core
import ../state/simulation_state
import ../state/render_state

type
  ParamKind* = enum
    pkInt    ## Integer values (counts, radius, size, substeps)
    pkFloat

  ParamStore* = enum
    ## Which mutation path a parameter write routes through.
    psSimulation  ## updateSimulation -> CONFIG (physics mirror)
    psRender      ## updateRender -> CONFIG (visual mirror)
    psPalette     ## palette editor state -> COLORS regeneration
    psSpeciesChemistry
      ## a cell of the live SPECIES_CHEMISTRY array -> the field passes
      ## Written by reference, the same contract the attraction matrix uses:
      ## the frame loop copies the array into its uniform every frame, so an
      ## edit lands next frame with no upload call and no updateSimulation
      ## round trip. setParam therefore does not route these — the panel writes
      ## the cell it edited and clamps it against this table first.
    psCamera      ## the live camera -> webgpu_render, NOT CONFIG
      ## The camera is VIEW state, not world state, and this is the whole
      ## reason it needs its own route. It is deliberately absent from CONFIG
      ## and therefore from the preset schema: a preset restores a world, and
      ## should not also seize where the user is standing to look at it.
      ## Loading a preset and being teleported reads as a bug, not a feature.
      ## `0` on the keyboard is the way back, and it cannot itself get lost.

  ParamArity* = enum
    ## How many values one descriptor stands for. This is the member that lets
    ## secretion and tropism sit in the table beside the sliders instead of in
    ## a parallel one: everything else about a tunable — its range, default,
    ## step, precision, hint, notches and clamp — is the same question whether
    ## the world holds one of it or each species holds its own.
    paScalar      ## One value for the world, reached by id through getParam.
    paPerSpecies  ## One value per species, interleaved in a live array; `slot`
                  ## says where inside a species' stride it sits.

  ParamCeilingId* = enum
    ## The registered ceiling functions, one member per function. A citation is
    ## this enum rather than a name, so a descriptor cannot cite a ceiling that
    ## does not exist and `evaluateCeiling` cannot be missing a case — the
    ## compiler settles both, where a string table would need a test to.
    pcStableStiffness  ## sph_core.stableStiffnessCeiling

  SliderCurve* = enum
    ## The travel curve. Position, in [0, 1], is what the user's
    ## hand moves; the curve decides what a distance of travel buys where.
    cLinear
    cLog    ## equal travel multiplies the value equally; demands a floor
            ## above zero, and the static gate below holds the pair together
    cPower  ## equal travel buys more near the floor, by the exponent

  ResponseHorizon* = enum
    ## When the world answers a move of this control. Acknowledgement — the
    ## handle, the readout, the brief highlight — is the panel's own and
    ## always lands in the same tick; this declares the RESPONSE, which is
    ## the world changing.
    rhInstant     ## visible in the next frame; every render-store parameter
    rhSettling    ## visible over roughly a second as motion redistributes
    rhStructural  ## visible over many seconds, or on the next commit

  ParamBoundKind* = enum
    bConstant  ## the declared range is the whole bound
    bDerived   ## a registered ceiling bounds the value's EFFECT

  ParamBound* = object
    ## What bounds a parameter, beyond the envelope every parameter has.
    ##
    ## Three parts stay separate here, and the separation is the mechanism. The
    ## ENVELOPE is the descriptor's own min and max: it owns what can be stored,
    ## what a preset clamps against, and every build-time assertion, and a
    ## derived bound changes none of it. The CEILING is a pure function of other
    ## live parameters, registered under a ParamCeilingId and cited from here.
    ## The EFFECT-TIME CLAMP applies that ceiling where the value takes effect
    ## and never at store time, so shrinking a ceiling input lowers what the
    ## simulation runs and restoring it brings the stored value back whole.
    ##
    ## Which bounds may derive at all: a bound that is an exact structural fact
    ## folds into the parameterisation and becomes unrepresentable instead (the
    ## SPH radius fraction is that kind, capped at 1 by its own range). A bound
    ## that is a FITTED empirical estimate stays a named clamp and never
    ## redefines the value it bounds — re-parameterising stiffness as a fraction
    ## of a fitted ceiling would silently rescale every saved preset each time
    ## the fit moved.
    case kind*: ParamBoundKind
    of bConstant: discard
    of bDerived:
      ceilingId*: ParamCeilingId

  CeilingInputs* = object
    ## The live values a registered ceiling may read. One record for every
    ## ceiling rather than one per function: a ceiling is a pure function of the
    ## world's current parameters, and naming them in one place is what lets the
    ## panel and the CONFIG mirror evaluate any of them from the same snapshot.
    interactionRadius*: int
    sphRadiusFraction*: float
    sphSubsteps*: int
    timeScale*: float

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
    reinitOnCommit*: bool
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
    curve*: SliderCurve   ## How handle travel maps to value:
                          ## cLinear until a measured remedy assigns
                          ## otherwise. The curve changes nothing but the
                          ## handle's position — stored values, presets,
                          ## clamps, notches and the readout all keep the
                          ## value, never the position.
    curveExponent*: float ## The exponent cPower warps travel by; meaningful
                          ## only there, and the gate below rejects one that
                          ## would invert or flatten the mapping.
    probe*: string        ## Id of this parameter's response probe in
                          ## response_probe.nim's registry — the declared
                          ## observable the parameter promises to move.
                          ## Empty only where `exemption` says why; the
                          ## native suite asserts the union covers the table.
    exemption*: string    ## The written reason this parameter carries no
                          ## probe. Empty wherever `probe` is set — a claim
                          ## reviewers can argue with, never a hole.
    horizon*: ResponseHorizon
                          ## When the world answers a move; the panel shows
                          ## settling until it elapses. rhInstant by default.
    horizonReview*: bool  ## True on a non-instant horizon no stepping mirror
                          ## executes — the claim is review-enforced, and
                          ## labelled so a reader knows which kind they hold.
    dormantWhen*: string  ## Dormancy-predicate id (dormancy.nim registry);
                          ## empty = never dormant. Never a predicate over
                          ## this control's own value alone.
    bound*: ParamBound    ## What bounds the value beyond its envelope.
                          ## bConstant for every parameter whose range is the
                          ## whole story, which is all but one of them, and it
                          ## is the zero value so a descriptor that says nothing
                          ## about bounds says the ordinary thing.
    case arity*: ParamArity
    of paScalar: discard
    of paPerSpecies:
      slot*: int          ## Offset inside one species' stride. The panel reads
                          ## a cell as species * stride + slot, so the stride
                          ## arithmetic crosses the boundary as two numbers the
                          ## simulation owns rather than as a TypeScript
                          ## literal. Only reachable on this branch: slot 0 is
                          ## a real slot, so a scalar carrying a default 0
                          ## would be indistinguishable from secretion's.

func notch(value: float; label: string): ParamNotch =
  ParamNotch(value: value, label: label)

func derivedBound(ceilingId: ParamCeilingId): ParamBound =
  ParamBound(kind: bDerived, ceilingId: ceilingId)

# ==============================================================================
# THE CEILING REGISTRY
# ==============================================================================

func ceilingInputs*(sim: SimulationState): CeilingInputs =
  ## The snapshot every registered ceiling reads. Taken from the simulation
  ## state rather than from CONFIG so the value lands in the same tick as the
  ## write that moved it — the synchronous-mirror invariant web_api keeps.
  CeilingInputs(
    interactionRadius: sim.interactionRadius,
    sphRadiusFraction: sim.sphRadiusFraction,
    sphSubsteps: sim.sphSubsteps,
    timeScale: sim.timeScale)

func evaluateCeiling*(id: ParamCeilingId; inputs: CeilingInputs): float =
  ## The registered ceiling function behind a citation.
  case id
  of pcStableStiffness:
    # The smoothing radius the shader forms (forces-sph.wgsl multiplies these
    # two), and the timestep app.nim's loop hands the substepped frame, taken
    # against sph_core's reference frame rather than the one the browser
    # happened to deliver.
    stableStiffnessCeiling(
      inputs.interactionRadius.float * inputs.sphRadiusFraction,
      inputs.sphSubsteps,
      inputs.timeScale * SPH_CEILING_REFERENCE_FRAME_SECONDS,
      SPH_STIFFNESS_MAX)

func ceilingName*(id: ParamCeilingId): string =
  ## The citation's name across the boundary. Written here rather than derived
  ## from the enum's spelling, so renaming the member cannot silently rename an
  ## interface string the panel reads.
  case id
  of pcStableStiffness: "stableStiffness"

func ceilingReason*(id: ParamCeilingId): string =
  ## Why the region above this ceiling is dormant, in the words the panel
  ## shows. It lives here because it is a claim about the simulation, and the
  ## panel restates neither the claim nor the number behind it.
  case id
  of pcStableStiffness:
    "above the stable ceiling at the current fluid radius and substeps"

func ceilingInputBox*(): seq[CeilingInputs] =
  ## Every corner of the box the ceiling inputs range over, plus the shipped
  ## default. What "over the whole reachable box" means for the sweeps that
  ## check a ceiling: each input at each end of its own range, and the
  ## configuration a fresh world actually runs.
  for interactionRadius in [INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX]:
    for fraction in [SPH_RADIUS_FRACTION_MIN, SPH_RADIUS_FRACTION_MAX]:
      for substeps in [SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX]:
        for timeScale in [TIME_SCALE_MIN, TIME_SCALE_MAX]:
          result.add CeilingInputs(
            interactionRadius: interactionRadius,
            sphRadiusFraction: fraction,
            sphSubsteps: substeps,
            timeScale: timeScale)
  result.add ceilingInputs(initSimulationState())

func minimumCeiling*(id: ParamCeilingId): float =
  ## The smallest value a ceiling takes anywhere its inputs can go — the floor
  ## every labelled notch on the parameter it bounds must sit below, since a
  ## notch above it names a position some reachable world can never honour.
  ##
  ## Read off one corner rather than swept, because every registered ceiling
  ## rises with the interaction radius, the radius fraction and the substep
  ## count and falls as the time scale lengthens the frame. That monotonicity is
  ## what makes a corner the answer, and tests/test_param_descriptor.nim sweeps
  ## the box to hold this corner to it.
  evaluateCeiling(id, CeilingInputs(
    interactionRadius: INTERACTION_RADIUS_MIN,
    sphRadiusFraction: SPH_RADIUS_FRACTION_MIN,
    sphSubsteps: SPH_SUBSTEPS_MIN,
    timeScale: TIME_SCALE_MAX))

func effectiveSimulation*(sim: SimulationState): SimulationState =
  ## The state as the frame RUNS it: every stored value, with each derived
  ## parameter's effect bounded by its live ceiling.
  ##
  ## This is the effect-time clamp, and the returned record is a copy — the
  ## stored state is never modified, so shrinking a ceiling input lowers what
  ## the fluid does and restoring it brings the stored value back whole, with no
  ## hysteresis. web_api mirrors THIS into CONFIG; getParam, the preset
  ## snapshot and the slider all keep reading the stored record, which is why
  ## the handle never moves on its own.
  ##
  ## One field per derived parameter, paired by hand with the descriptor that
  ## cites the same ceiling — Nim has no way to reach a state field from a
  ## descriptor id, so the pairing is written twice and
  ## tests/test_param_descriptor.nim holds the two together.
  result = sim
  result.sphStiffness = min(sim.sphStiffness,
    evaluateCeiling(pcStableStiffness, ceilingInputs(sim)))

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
  case kind
  of pkInt: 1.0
  of pkFloat:
    if precision <= 0: 1.0 else: pow(10.0, -float(precision))

func intParam(id, label, group: string; minValue, maxValue, defaultValue: int;
    store: ParamStore; reinitOnCommit = false;
    notches: seq[ParamNotch] = @[]; probe = "";
    exemption = ""; horizon = rhInstant; horizonReview = false;
    dormantWhen = ""): ParamDescriptor =
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkInt,
    minValue: minValue.float, maxValue: maxValue.float,
    step: paramStep(pkInt, 0), precision: 0,
    defaultValue: defaultValue.float, store: store,
    reinitOnCommit: reinitOnCommit, notches: notches, arity: paScalar,
    probe: probe, exemption: exemption, horizon: horizon,
    horizonReview: horizonReview, dormantWhen: dormantWhen)

func floatParam(id, label, group: string;
    minValue, maxValue, defaultValue: float; precision: int;
    store: ParamStore; hint = "";
    notches: seq[ParamNotch] = @[];
    bound = ParamBound(kind: bConstant); probe = "";
    curve = cLinear; curveExponent = 0.0;
    horizon = rhInstant; horizonReview = false;
    dormantWhen = ""): ParamDescriptor =
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkFloat,
    minValue: minValue, maxValue: maxValue,
    step: paramStep(pkFloat, precision), precision: precision,
    defaultValue: defaultValue, store: store,
    reinitOnCommit: false, hint: hint, notches: notches, bound: bound,
    arity: paScalar, probe: probe, curve: curve,
    curveExponent: curveExponent, horizon: horizon,
    horizonReview: horizonReview, dormantWhen: dormantWhen)

func perSpeciesParam(id, label, group: string; slot: int;
    minValue, maxValue, defaultValue: float; precision: int;
    hint = ""; probe = ""; horizon = rhInstant; horizonReview = false;
    dormantWhen = ""): ParamDescriptor =
  ## A column of the per-species grid. Continuous and signed like the sliders
  ## it sits beside, so it takes pkFloat and the same step rule; what differs
  ## is that one of these exists per species, at `slot` inside the stride.
  ##
  ## No notches parameter. A notch marks a position on a track, and a column
  ## renders as a numeric cell with no track to mark — so one added here would
  ## reach nobody. Whoever gives the grid something to draw a notch on adds the
  ## parameter back in that same change.
  ParamDescriptor(
    id: id, label: label, group: group, kind: pkFloat,
    minValue: minValue, maxValue: maxValue,
    step: paramStep(pkFloat, precision), precision: precision,
    defaultValue: defaultValue, store: psSpeciesChemistry,
    reinitOnCommit: false, hint: hint,
    arity: paPerSpecies, slot: slot, probe: probe, horizon: horizon,
    horizonReview: horizonReview, dormantWhen: dormantWhen)

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
    intParam("particleCount", "Particles", "simulation",
      PARTICLE_COUNT_MIN, PARTICLE_COUNT_MAX, sim.particleCount,
      psSimulation, reinitOnCommit = true,
      exemption = "the observable is the count of things drawn — " &
        "structural and self-evident, and probing it would measure the " &
        "probe", horizon = rhStructural,
      horizonReview = true).withDefaultNotch(0),
    intParam("speciesCount", "Species", "simulation",
      SPECIES_COUNT_MIN, SPECIES_COUNT_MAX, sim.speciesCount,
      psSimulation, reinitOnCommit = true,
      exemption = "the observable is how many kinds are drawn — the same " &
        "structural count particleCount is exempt for",
      horizon = rhStructural, horizonReview = true),
    # "grid" rather than "simulation": interactionRadius is the neighbor search
    # radius forces.wgsl uses and the smoothing radius forces-sph.wgsl uses.
    # The group says where the control sits, never whether it appears.
    # No coupling dormancy: it feeds the world-intrinsic density pass, which
    # no strength's zero switches off.
    intParam("interactionRadius", "Interaction Radius", "grid",
      INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX, sim.interactionRadius,
      psSimulation, probe = "force.reachAtFixedApproach",
      horizon = rhSettling, horizonReview = true),
    # A coupling strength, and its zero notch says so. Zero removes short-range
    # repulsion along with attraction (fMul scales both force zones), so
    # particles pass freely through each other — hence a notch label naming
    # what happens rather than "off".
    floatParam("forceStrength", "Force Strength", "species",
      FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX, sim.forceStrength, 1,
      psSimulation,
      notches = @[
        notch(FORCE_STRENGTH_MIN, "no forces"),
      ], probe = "force.multiplier",
      horizon = rhSettling, horizonReview = true).withDefaultNotch(1),
    # Beside forceStrength because it shapes that force rather than adding
    # another: it scales the ATTRACTIVE half alone, so a crowded colony pulls
    # itself in less hard while the short-range repulsion holding it apart is
    # untouched. Off at zero, which is today's force law exactly.
    floatParam("crowdingStrength", "Crowding", "species",
      CROWDING_STRENGTH_MIN, CROWDING_STRENGTH_MAX, sim.crowdingStrength, 2,
      psSimulation,
      hint = "how much a crowd weakens its own attraction; repulsion is never weakened",
      notches = @[
        notch(CROWDING_STRENGTH_MIN, "off"),
      ], probe = "force.crowdingShare",
      horizon = rhSettling, horizonReview = true, dormantWhen = "forceOff"),
    floatParam("friction", "Friction", "simulation",
      FRICTION_MIN, FRICTION_MAX, sim.friction, 2, psSimulation,
      probe = "motion.frictionRetention",
      horizon = rhSettling, horizonReview = true),
    floatParam("timeScale", "Time Scale", "simulation",
      TIME_SCALE_MIN, TIME_SCALE_MAX, sim.timeScale, 1, psSimulation,
      probe = "motion.frameTravel",
      horizon = rhSettling, horizonReview = true),
    # Structural: the consumer is the randomize action, which answers at the
    # next commit and is always available — hence no dormancy either.
    floatParam("ruleTemperature", "🌡️ Temperature", "species",
      RULE_TEMPERATURE_MIN, RULE_TEMPERATURE_MAX, sim.ruleTemperature, 2,
      psSimulation, probe = "matrix.sampleSpread",
      horizon = rhStructural, horizonReview = true),
    floatParam("maxVelocity", "Max Velocity", "simulation",
      MAX_VELOCITY_MIN, MAX_VELOCITY_MAX, sim.maxVelocity, 0, psSimulation,
      probe = "motion.softCap",
      horizon = rhSettling, horizonReview = true),

    # Outside the collapsible sections
    intParam("particleSize", "Particle Size", "render",
      PARTICLE_SIZE_MIN, PARTICLE_SIZE_MAX, visual.particleSize, psRender,
      probe = "render.visibleRadius"),
    floatParam("trailLength", "Trail Length", "render",
      TRAIL_LENGTH_MIN, TRAIL_LENGTH_MAX, visual.trailLength, 0, psRender,
      probe = "render.trailPersistence"),

    floatParam("glowIntensity", "Intensity", "glow",
      GLOW_INTENSITY_MIN, GLOW_INTENSITY_MAX, visual.glowIntensity, 1,
      psRender, probe = "glow.clampedIntegral"),
    floatParam("velocityGlowScale", "Velocity Sweep", "glow",
      VELOCITY_GLOW_SCALE_MIN, VELOCITY_GLOW_SCALE_MAX,
      visual.velocityGlowScale, 1, psRender, probe = "glow.velocityIntegral"),
    floatParam("glowRadiusScale", "Halo Radius", "glow",
      GLOW_RADIUS_SCALE_MIN, GLOW_RADIUS_SCALE_MAX, visual.glowRadiusScale, 1,
      psRender, probe = "glow.radiusIntegral"),
    floatParam("glowFalloff", "Halo Falloff", "glow",
      GLOW_FALLOFF_MIN, GLOW_FALLOFF_MAX, visual.glowFalloff, 1, psRender,
      probe = "glow.falloffIntegral"),
    floatParam("glowWarmth", "Warmth", "glow",
      GLOW_WARMTH_MIN, GLOW_WARMTH_MAX, visual.glowWarmth, 2, psRender,
      probe = "glow.warmth"),

    # Bloom & Grade section
    # All five grade sliders name the bloom toggle: the tonemap uniform is
    # written every frame but consumed only inside the bloom present path,
    # a branch no gate sees — the predicate and that branch agree by review.
    floatParam("bloomIntensity", "Bloom Intensity", "bloom",
      BLOOM_INTENSITY_MIN, BLOOM_INTENSITY_MAX, visual.bloomIntensity, 2,
      psRender, probe = "grade.bloomLuminance", dormantWhen = "bloomOff"),
    floatParam("exposure", "Exposure", "bloom",
      EXPOSURE_MIN, EXPOSURE_MAX, visual.exposure, 2, psRender,
      probe = "grade.exposureLuminance", dormantWhen = "bloomOff"),
    floatParam("saturation", "Saturation", "bloom",
      SATURATION_MIN, SATURATION_MAX, visual.saturation, 2, psRender,
      probe = "grade.chromaSpread", dormantWhen = "bloomOff"),
    floatParam("contrast", "Contrast", "bloom",
      CONTRAST_MIN, CONTRAST_MAX, visual.contrast, 2, psRender,
      probe = "grade.contrastSpread", dormantWhen = "bloomOff"),
    floatParam("temperature", "Temperature", "bloom",
      TEMPERATURE_MIN, TEMPERATURE_MAX, visual.temperature, 2, psRender,
      probe = "grade.temperatureSplit", dormantWhen = "bloomOff"),

    # Force Model section (polynomial vs exponential parameter pairs)
    floatParam("repulsionEnd", "Repulsion End", "force-polynomial",
      REPULSION_END_MIN, REPULSION_END_MAX, sim.repulsionEnd, 2,
      psSimulation, probe = "force.polyAtMidzone",
      horizon = rhSettling, horizonReview = true, dormantWhen = "forceOff"),
    floatParam("attractionPeak", "Attraction Peak", "force-polynomial",
      ATTRACTION_PEAK_MIN, ATTRACTION_PEAK_MAX, sim.attractionPeak, 2,
      psSimulation, probe = "force.polyPeakLocation",
      horizon = rhSettling, horizonReview = true, dormantWhen = "forceOff"),
    floatParam("expRepulsionAlpha", "Repulsion α", "force-exponential",
      EXP_REPULSION_ALPHA_MIN, EXP_REPULSION_ALPHA_MAX,
      sim.expRepulsionAlpha, 2, psSimulation, probe = "force.expRepulsion",
      horizon = rhSettling, horizonReview = true, dormantWhen = "forceOff"),
    floatParam("expAttractionBeta", "Attraction β", "force-exponential",
      EXP_ATTRACTION_BETA_MIN, EXP_ATTRACTION_BETA_MAX,
      sim.expAttractionBeta, 2, psSimulation,
      probe = "force.expAttraction",
      horizon = rhSettling, horizonReview = true, dormantWhen = "forceOff"),

    # Palette section (routes to the palette editor state, not CONFIG)
    floatParam("paletteSaturation", "Saturation", "palette",
      PALETTE_SATURATION_MIN, PALETTE_SATURATION_MAX, DEFAULT_SATURATION, 2,
      psPalette, probe = "palette.pairwiseDistance.saturation"),
    floatParam("paletteLightness", "Lightness", "palette",
      PALETTE_LIGHTNESS_MIN, PALETTE_LIGHTNESS_MAX, DEFAULT_LIGHTNESS, 2,
      psPalette, probe = "palette.meanLuminance"),

    # SPH Fluid section. fluidStrength leads it because it is the coupling
    # strength and the four below it are the fluid's character: they say what
    # KIND of fluid this is — how far a particle's neighbourhood reaches, how
    # hard it resists compression, what spacing it relaxes to, how fast it
    # shears — while this one says how much of that fluid's verdict on a
    # particle's velocity actually lands.
    floatParam("fluidStrength", "Fluid", "fluid",
      FLUID_STRENGTH_MIN, FLUID_STRENGTH_MAX, sim.fluidStrength, 2,
      psSimulation,
      hint = "how much of the fluid acts; the four below shape what kind of fluid it is",
      notches = @[
        notch(FLUID_STRENGTH_MIN, "no fluid"),
        notch(FLUID_STRENGTH_MAX, "full"),
      ], probe = "sph.pairShare",
      horizon = rhSettling, horizonReview = true),
    # Ahead of the other three because it sets the neighbourhood they are
    # measured in: a rest density counts neighbours inside this radius, and a
    # stiffness is stable only against it. A fraction rather than a
    # length keeps the interaction radius one control instead of two coupled
    # ones, and caps the kernel at the neighbour sweep's reach.
    floatParam("sphRadiusFraction", "Fluid Scale", "fluid",
      SPH_RADIUS_FRACTION_MIN, SPH_RADIUS_FRACTION_MAX, sim.sphRadiusFraction,
      2, psSimulation,
      hint = "how far the fluid's kernel reaches, as a fraction of the interaction radius",
      notches = @[
        notch(SPH_RADIUS_FRACTION_MAX, "whole radius"),
      ], probe = "sph.fractionCeiling",
      horizon = rhSettling, horizonReview = true, dormantWhen = "fluidOff"),
    floatParam("sphRestDensity", "Rest Density", "fluid",
      SPH_REST_DENSITY_MIN, SPH_REST_DENSITY_MAX, sim.sphRestDensity, 2,
      psSimulation, probe = "sph.reachablePressureBand",
      horizon = rhSettling, horizonReview = true, dormantWhen = "fluidOff"),
    # The one derived bound this mechanism serves. The envelope below is still
    # the whole of what can be STORED — a preset carrying 40 loads as 40 — while
    # how much of it the fluid can honour depends on the three controls around
    # it, so the descriptor cites the ceiling instead of claiming its maximum is
    # always available.
    floatParam("sphStiffness", "Stiffness", "fluid",
      SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX, sim.sphStiffness, 1,
      psSimulation,
      hint = "how hard the fluid resists compression; a narrower kernel, " &
        "fewer substeps or a faster world hold less of it",
      bound = derivedBound(pcStableStiffness), probe = "sph.pressureGain",
      horizon = rhSettling, horizonReview = true, dormantWhen = "fluidOff"),
    floatParam("sphViscosity", "Viscosity", "fluid",
      SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX, sim.sphViscosity, 2,
      psSimulation, probe = "sph.velocityBlend",
      horizon = rhSettling, horizonReview = true, dormantWhen = "fluidOff"),
    intParam("sphSubsteps", "Substeps", "fluid",
      SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX, sim.sphSubsteps, psSimulation,
      exemption = "a three-position integer count of whole physics passes: " &
        "every step legitimately moves the stable ceiling by its share, so " &
        "the cliff bar — written for divisible travel — cannot hold " &
        "(measured cliff 0.60 for a uniform-as-possible three-point " &
        "response). The remedy ladder ran dry: no dead end to re-range, no " &
        "curve moves a count, re-stepping a whole pass is meaningless, and " &
        "no partner shapes it. Its ceiling consequence stays measured " &
        "through sphStiffness's deriving-box corner slices, and the count " &
        "itself is pinned by the measured stability fit " &
        "(sph_core.stableStiffnessCeiling)",
      horizon = rhSettling, horizonReview = true, dormantWhen = "fluidOff"),

    # Reaction-Diffusion section. Feed and kill carry the six named regimes as
    # notches, so the living parts of the plane are positions the user can
    # reach by name instead of by accident. The coordinates live in
    # config_ranges beside the ranges they must satisfy, and no hint restates
    # them: a hint naming values the notches already mark is a second copy free
    # to drift from the (0.082, 0.059) the regime table transcribes.
    floatParam("rdFeed", "Breath In", "rd",
      RD_FEED_MIN, RD_FEED_MAX, sim.rdFeed, 3, psSimulation,
      hint = "the feed rate F; a regime needs both axes, so the buttons set the pair",
      notches = regimeNotches(regimeFeed),
      probe = "field.aliveFraction.feed",
      horizon = rhStructural, dormantWhen = "fieldSubcritical"),
    floatParam("rdKill", "Breath Out", "rd",
      RD_KILL_MIN, RD_KILL_MAX, sim.rdKill, 3, psSimulation,
      hint = "the kill rate k; a regime needs both axes, so the buttons set the pair",
      notches = regimeNotches(regimeKill),
      probe = "field.aliveFraction.kill",
      horizon = rhStructural, dormantWhen = "fieldSubcritical"),
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
      ], probe = "field.resolvedDeposit",
      horizon = rhStructural).withDefaultNotch(1),
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
      ], probe = "field.tropism",
      horizon = rhSettling, horizonReview = true).withDefaultNotch(1),
    floatParam("climateSpeed", "Drift", "rd",
      CLIMATE_SPEED_MIN, CLIMATE_SPEED_MAX, sim.climateSpeed, 2, psSimulation,
      hint = "tours of the named regimes per minute, while Weather is on",
      probe = "climate.phaseStep",
      horizon = rhSettling, horizonReview = true),
    # "simulation", where friction and the other toured force parameters
    # document, rather than "rd" beside the climate speed it shares a tour
    # implementation with: someone asking what moved their force sliders looks
    # where those sliders are. It reads the same probe because the observable is
    # the same one — phase advanced per second, whatever table lies underneath.
    floatParam("forceWeatherSpeed", "Force Drift", "simulation",
      FORCE_WEATHER_SPEED_MIN, FORCE_WEATHER_SPEED_MAX, sim.forceWeatherSpeed,
      2, psSimulation,
      hint = "tours of the force waypoints per minute, while Force Weather is on",
      probe = "climate.phaseStep",
      horizon = rhSettling, horizonReview = true),
    # "rd-field" rather than "rd": this is the field's appearance, not its
    # physics, and the panel puts the colormap selector between the two groups.
    floatParam("fieldOpacity", "Field Opacity", "rd-field",
      FIELD_OPACITY_RANGE_MIN, FIELD_OPACITY_RANGE_MAX, visual.fieldOpacity,
      2, psRender, probe = "colormap.coverage", dormantWhen = "fieldUnlit"),

    # Species chemistry: what each species does to the field, and what the
    # field does back. One value per species, so these carry paPerSpecies and a
    # slot; the panel renders the pair as grid columns beside the attraction
    # matrix rather than as sliders. Both hints name the sign, because both
    # values are signed and a bare label cannot say which way negative runs.
    perSpeciesParam("secretion", "Secretion", "chemistry",
      SPECIES_SECRETION_SLOT, SECRETION_MIN, SECRETION_MAX,
      RD_DEFAULT_SECRETION, 2,
      hint = "this species' share of the Secretion Rate; negative erodes the " &
        "field instead of building it",
      probe = "field.speciesDeposit",
      horizon = rhStructural, horizonReview = true,
      dormantWhen = "depositOff"),
    perSpeciesParam("tropism", "Tropism", "chemistry",
      SPECIES_TROPISM_SLOT, TROPISM_MIN, TROPISM_MAX, RD_DEFAULT_TROPISM, 2,
      hint = "negative flees its own trail, positive chases it",
      probe = "field.tropismWeight",
      horizon = rhSettling, horizonReview = true,
      dormantWhen = "tropismOff"),

    # The camera. psCamera, not psRender: this writes the live view, never
    # CONFIG, so it stays out of the preset schema for the reason recorded on
    # the enum. Its notches name the two scales worth stopping at rather than
    # positions on a number line — world is the whole world fitted to the
    # window and the widest view the slider offers, creature is close enough
    # that the attraction matrix reads as individual motion.
    floatParam("cameraZoom", "Zoom", "camera",
      CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX, CAMERA_DEFAULT_ZOOM.float, 2, psCamera,
      probe = "camera.apparentScale",
      # No numerals in this hint. The reachability test reads every number a
      # hint names as a slider position, and the zero key is a KEY — spelling it
      # as a digit makes the test report an unreachable value, correctly.
      hint = "the wheel zooms at the cursor; the zero key returns to the whole world",
      notches = @[
        notch(CAMERA_ZOOM_NOTCH_WORLD, "world"),
        notch(CAMERA_ZOOM_NOTCH_CREATURE, "creature"),
      ]),
  ]

func clampParamValue*(descriptor: ParamDescriptor; value: float): float =
  ## Coerce a raw UI value into the descriptor's range. Integer parameters
  ## additionally truncate through int().
  let clamped = max(descriptor.minValue, min(descriptor.maxValue, value))
  case descriptor.kind
  of pkInt: float(int(clamped))
  of pkFloat: clamped

static:
  # THE CURVE-FLOOR GATE. A logarithm has no zero, so giving a
  # parameter logarithmic travel and giving it a positive floor are one
  # decision — and a flat or inverted power warp is no curve at all. Checked
  # here beside the descriptors rather than in config_ranges because the
  # pairing is per-descriptor: the range authority cannot see which of its
  # constants carries which curve.
  for descriptor in buildParamDescriptors():
    if descriptor.curve == cLog:
      doAssert descriptor.minValue > 0.0,
        "descriptor " & descriptor.id & " pairs cLog with a range minimum " &
        "at or below zero; the curve and the floor are one decision"
    if descriptor.curve == cPower:
      doAssert descriptor.curveExponent > 0.0,
        "descriptor " & descriptor.id & " carries a cPower exponent that " &
        "would invert or flatten the mapping"
