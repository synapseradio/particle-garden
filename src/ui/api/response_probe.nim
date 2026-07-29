# ==============================================================================
# PARTICLE GARDEN - RESPONSE PROBES (design E1-E3)
# ==============================================================================
#
# Every slider promises that moving it moves something the user can see. This
# module is where that promise becomes measurable: each descriptor names a
# probe — a pure function from (value, context) to a scalar observable drawn
# from the reference-oracle family — and three unit-free metrics judge the
# TRACK, not the number range: span (the ends differ), live fraction (most of
# the travel does something), cliff (no single movement jumps the world).
#
# Nothing in src/ imports this module; the native suite does, which is what
# makes the whole apparatus runnable without a browser. The descriptor table
# carries only the probe's NAME, so the panel ships no measurement code.
#
# Context and coordinates (design E2): every probe measures on a slice — all
# other parameters fixed. The default slice is the shipped defaults, read from
# the owning state records, never restated here. Reference coordinates the
# probes fix (a separation, a density, a velocity gap) are named constants
# below with the reason beside each.

import std/[math, tables, strformat]

import ../../config_ranges
import ../../physics_core
import ../../sph_core
import ../../field_core
import ../../bloom_core
import ../../colormap_core
import ../../climate_core
import ../../camera_core
import ../../glow_core
import ../../trail_core
import ../../palette
import ../../shader_config
import ../state/simulation_state
import ../state/render_state
import ../state/matrix_state
import param_descriptor

# ------------------------------------------------------------------------------
# The thresholds (design E3). Provisional starting hypotheses, written down so
# the first sweep has something to move; E5 replaces them with values set
# inside the measured gap between the must-pass and must-fail control sets.
# ------------------------------------------------------------------------------

const
  RESPONSE_EPSILON* = 1e-4
    ## Movement below this fraction of the reference magnitude counts as none.
  SPAN_MIN* = 0.05
  LIVE_FRACTION_MIN* = 0.60
  CLIFF_MAX* = 0.25

const
  ProbeBudgetClosedForm* = 256
    ## Samples per slice for probes that evaluate a formula.
  ProbeBudgetStepped* = 64
    ## Samples per slice for probes that step a simulation; the field probes
    ## integrate a 64x64 grid for dozens of frames per sample, and the native
    ## suite has to stay fast.

# ------------------------------------------------------------------------------
# Context
# ------------------------------------------------------------------------------

type
  ProbeContext* = object
    ## Every parameter other than the one under measurement, fixed at named
    ## coordinates. Defaults come from the owning state records; the camera
    ## zoom sits beside them because no state record owns the live camera.
    sim*: SimulationState
    render*: RenderState
    cameraZoom*: float

  ProbeBudget* = enum
    pbClosedForm
    pbStepped

  ProbeFn* = proc (value: float; ctx: ProbeContext): float {.nimcall.}

  ProbeSpec* = object
    fn*: ProbeFn
    budget*: ProbeBudget

func defaultProbeContext*(): ProbeContext =
  ## The default slice: shipped defaults with the camera at its zoom floor.
  ## No strength lift is needed today — every strength multiplying a probed
  ## observable defaults non-zero except crowdingStrength, whose gated term
  ## appears only inside its own probe (design E2's lift clause, discharged
  ## by inspection of the registry below).
  ProbeContext(
    sim: initSimulationState(),
    render: initRenderState(),
    cameraZoom: CAMERA_ZOOM_MIN)

# ------------------------------------------------------------------------------
# Named reference coordinates
# ------------------------------------------------------------------------------

const
  RefAttractionDist = 0.7
    ## Normalized separation inside the shipped attraction zone (repulsionEnd
    ## defaults to 0.5), near the default attractionPeak so the bump is tall.
  RefRepulsionDist = 0.25
    ## Normalized separation inside the shipped repulsion zone.
  RefMidZoneDist = 0.45
    ## The fixed separation the repulsionEnd probe watches: shipped travel
    ## moves the zone boundary across it, so the force here swaps regimes.
  RefAttraction = 1.0
    ## A fully attractive matrix entry.
  RefCrowdDensity = 12.0
    ## A moderately crowded neighbourhood, inside the two-orders-of-magnitude
    ## band the logarithmic attenuation was shaped for.
  RefVelocityGap = 10.0
    ## Velocity difference across an SPH pair, px/frame.
  RefNeighborWeight = 0.5
    ## A mid-strength normalized neighbour weight.
  RefPairDistancePx = 6.0
    ## SPH pair separation in pixels: above the shader's 2 px minimum
    ## separation floor, inside every reachable kernel at the default radius.
  RefCompression = 1.2
    ## Density over rest density where pressure probes read the equation of
    ## state — the working compression, well under the 2.0 Tait clamp.
  RefFrameSpeed = 30.0
    ## Reference speed in px/frame for the travel and friction probes.
  RefCapProbeSpeed = 500.0
    ## A speed far above every reachable cap, so the soft cap always acts.
  RefGradient = 0.2
    ## Field gradient magnitude for the tropism probes.
  RefInhibitor = 0.3
    ## Inhibitor concentration a deposit lands on.
  RefVelocityNorm = 0.5
    ## Normalized particle speed for the glow probes.
  RefGlowDensity = 0.5
    ## Normalized neighbourhood density for the glow probes.
  RefTrailLight = (r: 0.30, g: 0.25, b: 0.20)
    ## HDR trail light entering the grade: warm, mid-brightness, chromatic —
    ## chosen off the grey axis so saturation and temperature have chroma to
    ## act on, and inside ACES's live region so exposure is not clamped.
  RefBloomLight = (r: 0.20, g: 0.15, b: 0.10)
    ## HDR bloom light before the bloomIntensity factor.
  RefWorldW = 1920.0
  RefWorldH = 1080.0
    ## Reference world extents for the camera probes, the same reference
    ## world test_camera_core measures in. The observable is a scale, so only
    ## the ratio matters, never the shipped world's absolute size.
  RefWorldSegment = 100.0
    ## World-space length whose apparent on-screen size the zoom probe reads.
  RefDensitySizeFloor = 0.7
    ## The density size multiplier's floor (render.wgsl:65-66); the composed
    ## visible-radius probe holds it at the worst corner (design E14).
  RefPaletteCount = 8
    ## Species count for the palette-distance probes.
  RefRuleSamples = 16
    ## Accepted draws the rule-temperature probe averages over.

# ------------------------------------------------------------------------------
# Probes
# ------------------------------------------------------------------------------

proc forceMultiplierProbe(value: float; ctx: ProbeContext): float =
  ## forceStrength: the shipped attraction-zone force at a fixed separation,
  ## scaled by the multiplier under measurement (forces.wgsl applies it after
  ## the curve).
  let curve = polynomialForce(RefAttractionDist.float32,
    RefAttraction.float32, ctx.sim.repulsionEnd.float32,
    ctx.sim.attractionPeak.float32,
    crowdingAttenuation(RefCrowdDensity.float32,
      ctx.sim.crowdingStrength.float32))
  abs(curve.float * value)

proc forceReachProbe(value: float; ctx: ProbeContext): float =
  ## interactionRadius: force at the same RELATIVE position of a growing
  ## reach. The curve value is fixed by the normalized distance; the radius
  ## enters through the shader's 1/distance conversion, so the same relative
  ## approach softens as the reach grows.
  let curve = polynomialForce(RefAttractionDist.float32,
    RefAttraction.float32, ctx.sim.repulsionEnd.float32,
    ctx.sim.attractionPeak.float32, 1.0'f32)
  abs(curve.float * ctx.sim.forceStrength) / (RefAttractionDist * value)

proc crowdingShareProbe(value: float; ctx: ProbeContext): float =
  ## crowdingStrength: the share of its attraction a particle LOSES at the
  ## reference density — zero at strength zero (today's force law), rising as
  ## the cap engages.
  1.0 - crowdingAttenuation(RefCrowdDensity.float32, value.float32).float

proc frictionProbe(value: float; ctx: ProbeContext): float =
  ## friction: the post-step speed of a below-cap mover. Friction is a
  ## retention factor in integrate.wgsl, so this is linear until the cap.
  postStepSpeed(RefFrameSpeed.float32, value.float32,
    ctx.sim.maxVelocity.float32).float

proc maxVelocityProbe(value: float; ctx: ProbeContext): float =
  ## maxVelocity: the post-step speed of a mover far above every cap, so the
  ## observable follows the cap itself.
  postStepSpeed(RefCapProbeSpeed.float32, ctx.sim.friction.float32,
    value.float32).float

proc timeScaleProbe(value: float; ctx: ProbeContext): float =
  ## timeScale: how far a reference speed travels in one rendered frame.
  ## app.nim multiplies the frame's dt by timeScale before anything integrates.
  RefFrameSpeed * value

proc ruleTemperatureProbe(value: float; ctx: ProbeContext): float =
  ## ruleTemperature: the mean magnitude of accepted rule draws at sigma =
  ## value, driven through sampleRuleValue with a deterministic cycle of
  ## standard-normal quantiles (rejection sampling forbids a live RNG here —
  ## the probe must be a function). The smallest quantile keeps acceptance
  ## reachable at every sigma the range serves.
  const quantiles = [0.01, -0.05, 0.2533, -0.2533, 0.6745, -0.6745,
    1.2816, -1.2816]
  var cursor = 0
  proc nextQuantile(): float =
    result = quantiles[cursor mod quantiles.len]
    inc cursor
  if value <= 0.0:
    return 0.0
  var total = 0.0
  for _ in 0 ..< RefRuleSamples:
    total += abs(sampleRuleValue(value, nextQuantile))
  total / RefRuleSamples.float

proc repulsionEndProbe(value: float; ctx: ProbeContext): float =
  ## repulsionEnd: the force at a fixed mid-track separation while the zone
  ## boundary sweeps across it — repulsive Hermite on one side, attraction
  ## bump on the other. The partner peak lifts just above the boundary where
  ## the shipped default would degenerate the bump zone (the shader leaves
  ## that region unguarded; the probe declares the lifted coordinate instead
  ## of measuring undefined math).
  let peak = max(ctx.sim.attractionPeak, value + 0.01)
  polynomialForce(RefMidZoneDist.float32, RefAttraction.float32,
    value.float32, peak.float32, 1.0'f32).float

proc attractionPeakProbe(value: float; ctx: ProbeContext): float =
  ## attractionPeak: the bump sampled at a fixed attraction-zone separation
  ## while the peak position travels.
  polynomialForce(RefAttractionDist.float32, RefAttraction.float32,
    ctx.sim.repulsionEnd.float32, value.float32, 1.0'f32).float

proc expRepulsionProbe(value: float; ctx: ProbeContext): float =
  ## expRepulsionAlpha: the exponential model's repulsion decay in isolation
  ## (attraction zero removes the other term).
  abs(exponentialForce(RefRepulsionDist.float32, 0.0'f32, value.float32,
    ctx.sim.expAttractionBeta.float32, 1.0'f32).float)

proc expAttractionProbe(value: float; ctx: ProbeContext): float =
  ## expAttractionBeta: the attraction term in isolation — the model at the
  ## reference attraction minus the model at attraction zero.
  let alpha = ctx.sim.expRepulsionAlpha.float32
  let withAttraction = exponentialForce(RefAttractionDist.float32,
    RefAttraction.float32, alpha, value.float32, 1.0'f32)
  let repulsionOnly = exponentialForce(RefAttractionDist.float32, 0.0'f32,
    alpha, value.float32, 1.0'f32)
  (withAttraction - repulsionOnly).float

proc fluidStrengthProbe(value: float; ctx: ProbeContext): float =
  ## fluidStrength: the one factor every SPH velocity delta passes through
  ## (forces-sph.wgsl), scaling the reference pair's pressure impulse.
  value * flooredTaitPressure(RefCompression * ctx.sim.sphRestDensity,
    ctx.sim.sphRestDensity, ctx.sim.sphStiffness, SPH_DEFAULT_GAMMA) *
    SPH_CEILING_REFERENCE_FRAME_SECONDS

proc sphRestDensityProbe(value: float; ctx: ProbeContext): float =
  ## sphRestDensity: pressure at a FIXED absolute density while rest density
  ## travels — the compression ratio, and with it the equation of state's
  ## answer, moves with the parameter.
  let fixedDensity = RefCompression * initSimulationState().sphRestDensity
  flooredTaitPressure(fixedDensity, value, ctx.sim.sphStiffness,
    SPH_DEFAULT_GAMMA)

proc sphStiffnessProbe(value: float; ctx: ProbeContext): float =
  ## sphStiffness: pressure at the reference compression. Linear in the gain
  ## by the Tait form.
  flooredTaitPressure(RefCompression * ctx.sim.sphRestDensity,
    ctx.sim.sphRestDensity, value, SPH_DEFAULT_GAMMA)

proc sphViscosityProbe(value: float; ctx: ProbeContext): float =
  ## sphViscosity: one pair's velocity blend. forces-sph.wgsl folds viscosity
  ## and the XSPH epsilon into one symmetric diffusion coefficient, so the
  ## mirror's XSPH summand carries it with epsilon = viscosity + the constant.
  xsphVelocityCorrection(0.0, RefVelocityGap, RefNeighborWeight,
    value + SPH_XSPH_EPSILON)

proc sphSubstepsProbe(value: float; ctx: ProbeContext): float =
  ## sphSubsteps: the stable stiffness ceiling the substep count buys at the
  ## default kernel — the shipped consequence of substepping (C3).
  stableStiffnessCeiling(
    ctx.sim.sphRadiusFraction * ctx.sim.interactionRadius.float,
    max(1, int(value)),
    ctx.sim.timeScale * SPH_CEILING_REFERENCE_FRAME_SECONDS,
    SPH_STIFFNESS_MAX)

proc sphKernelReachProbe(value: float; ctx: ProbeContext): float =
  ## sphRadiusFraction: the poly6 weight a fixed-separation pair carries as
  ## the smoothing radius scales under the fraction.
  poly6Weight2d(RefPairDistancePx,
    value * ctx.sim.interactionRadius.float)

# --- the stepped field probes --------------------------------------------------

const
  FieldProbeGrid = 64
    ## Grid edge for the stepped probes, the field harness's own size.
  FieldProbeFrames = 60
    ## Frames each sample integrates before the statistic is read.
  FieldProbeAliveThreshold = 0.15
    ## Inhibitor concentration above which a cell counts as alive — the same
    ## threshold tests/test_field_core.nim reads patterns with.

type FieldProbeField = array[FieldProbeGrid, array[FieldProbeGrid, float]]

proc fieldAliveFraction(feed, kill, deposit: float): float =
  ## The fraction of cells holding a live pattern after the declared horizon:
  ## a deterministic center seed plus a scattered deposit mask, advanced with
  ## the shipped frame shape — one deposit fold, then RD_STEPS_PER_FRAME
  ## Gray-Scott substeps (field_core owns every constant).
  var activator, inhibitor, scratchA, scratchB: FieldProbeField
  for y in 0 ..< FieldProbeGrid:
    for x in 0 ..< FieldProbeGrid:
      activator[y][x] = 1.0
      inhibitor[y][x] =
        if abs(x - FieldProbeGrid div 2) < 4 and
           abs(y - FieldProbeGrid div 2) < 4: 0.5
        else: 0.0

  template wrapPrev(i: int): int = (i + FieldProbeGrid - 1) mod FieldProbeGrid
  template wrapNext(i: int): int = (i + 1) mod FieldProbeGrid

  for _ in 0 ..< FieldProbeFrames:
    # The frame's single deposit fold, on the scattered mask.
    for y in 0 ..< FieldProbeGrid:
      for x in 0 ..< FieldProbeGrid:
        if (y * FieldProbeGrid + x) mod 16 == 0:
          inhibitor[y][x] = resolveCellDeposit(inhibitor[y][x], deposit)
    for _ in 0 ..< RD_STEPS_PER_FRAME:
      for y in 0 ..< FieldProbeGrid:
        let north = wrapPrev(y)
        let south = wrapNext(y)
        for x in 0 ..< FieldProbeGrid:
          let east = wrapNext(x)
          let west = wrapPrev(x)
          let lapA = laplacian9(activator[y][x],
            activator[north][x], activator[south][x],
            activator[y][east], activator[y][west],
            activator[north][east], activator[north][west],
            activator[south][east], activator[south][west])
          let lapB = laplacian9(inhibitor[y][x],
            inhibitor[north][x], inhibitor[south][x],
            inhibitor[y][east], inhibitor[y][west],
            inhibitor[north][east], inhibitor[north][west],
            inhibitor[south][east], inhibitor[south][west])
          let next = grayScottStep(activator[y][x], inhibitor[y][x],
            lapA, lapB, RD_DIFFUSION_A, RD_DIFFUSION_B, feed, kill,
            RD_DELTA_T)
          scratchA[y][x] = next.activator
          scratchB[y][x] = next.inhibitor
      activator = scratchA
      inhibitor = scratchB

  var alive = 0
  for y in 0 ..< FieldProbeGrid:
    for x in 0 ..< FieldProbeGrid:
      if inhibitor[y][x] > FieldProbeAliveThreshold: inc alive
  alive.float / (FieldProbeGrid * FieldProbeGrid).float

proc rdFeedProbe(value: float; ctx: ProbeContext): float =
  ## rdFeed: the alive fraction after the horizon, feed under measurement.
  ## Expected to fail the metrics on the default slice: most of the feed-kill
  ## rectangle admits no nontrivial fixed point on any single slice (D2).
  fieldAliveFraction(value, ctx.sim.rdKill, ctx.sim.rdDeposit)

proc rdKillProbe(value: float; ctx: ProbeContext): float =
  ## rdKill: the alive fraction after the horizon, kill under measurement.
  fieldAliveFraction(ctx.sim.rdFeed, value, ctx.sim.rdDeposit)

proc rdDepositProbe(value: float; ctx: ProbeContext): float =
  ## rdDeposit: one cell's inhibitor after this frame's deposit lands,
  ## through the shipped resolve fold (cap, per-step scale, floor).
  resolveCellDeposit(RefInhibitor, value)

proc rdFieldForceProbe(value: float; ctx: ProbeContext): float =
  ## rdFieldForce: the tropism force a reference gradient exerts at full
  ## species tropism, linear in the scale under measurement.
  speciesTropismForce(RefGradient, value, 1.0)

proc climateSpeedProbe(value: float; ctx: ProbeContext): float =
  ## climateSpeed: phase advanced per second. The tour period is its inverse;
  ## the probe reads the step to keep the zero-speed endpoint finite.
  tourPhaseStep(value, 1.0)

# --- render-side probes ---------------------------------------------------------

proc glowUniformsFor(ctx: ProbeContext): GlowUniforms =
  GlowUniforms(
    baseSize: ctx.render.particleSize.float + 1.0,
    glowIntensity: ctx.render.glowIntensity,
    velocityGlowScale: ctx.render.velocityGlowScale,
    glowRadiusScale: ctx.render.glowRadiusScale,
    glowFalloff: ctx.render.glowFalloff,
    glowWarmth: ctx.render.glowWarmth,
    glowDensityFloor: 0.0)

proc glowIntensityProbe(value: float; ctx: ProbeContext): float =
  ## glowIntensity: the display-clamped halo alpha integral — the observable
  ## that saturates where the screen stops answering, which is exactly the
  ## deadness the metric must see (design E1). DECLARED COORDINATE: full
  ## speed with the velocity coupling at its ceiling and density past the
  ## factor's clamp — the brightest halo the shipped sliders reach — because
  ## at the shipped velocityGlowScale of 1.0 nothing clamps anywhere on the
  ## track (test_glow_core measures alpha peaking at 0.5 there), and the
  ## clamp is the thing this probe exists to look at.
  var uniforms = glowUniformsFor(ctx)
  uniforms.glowIntensity = value
  uniforms.velocityGlowScale = VELOCITY_GLOW_SCALE_MAX
  haloAlphaIntegralClamped(glowTuning(), uniforms, 1.0, 1.0)

proc velocityGlowProbe(value: float; ctx: ProbeContext): float =
  var uniforms = glowUniformsFor(ctx)
  uniforms.velocityGlowScale = value
  haloAlphaIntegralClamped(glowTuning(), uniforms, RefVelocityNorm,
    RefGlowDensity)

proc glowRadiusProbe(value: float; ctx: ProbeContext): float =
  var uniforms = glowUniformsFor(ctx)
  uniforms.glowRadiusScale = value
  haloAlphaIntegralClamped(glowTuning(), uniforms, RefVelocityNorm,
    RefGlowDensity)

proc glowFalloffProbe(value: float; ctx: ProbeContext): float =
  var uniforms = glowUniformsFor(ctx)
  uniforms.glowFalloff = value
  haloAlphaIntegralClamped(glowTuning(), uniforms, RefVelocityNorm,
    RefGlowDensity)

proc glowWarmthProbe(value: float; ctx: ProbeContext): float =
  ## glowWarmth: the warmth shift itself — alpha ignores warmth by design, so
  ## the integral would read this control as dead while the colour moves.
  var uniforms = glowUniformsFor(ctx)
  uniforms.glowWarmth = value
  haloWarmth(glowTuning(), uniforms, RefGlowDensity)

proc trailPersistenceProbe(value: float; ctx: ProbeContext): float =
  ## trailLength: the 1/e persistence horizon in frames. Geometric in the
  ## slider — steep at one end, flat elsewhere — the one-dimensional
  ## calibration anchor expected to fail (design E3).
  persistenceFrames(value)

proc bloomIntensityProbe(value: float; ctx: ProbeContext): float =
  ## bloomIntensity: graded output luminance with the bloom term scaled by
  ## the value, the trail and grade held at reference (tonemap.wgsl's light
  ## sum feeding tonemapGrade).
  let graded = gradedRgb(
    RefTrailLight.r + value * RefBloomLight.r,
    RefTrailLight.g + value * RefBloomLight.g,
    RefTrailLight.b + value * RefBloomLight.b,
    ctx.render.exposure, ctx.render.saturation, ctx.render.contrast,
    ctx.render.temperature)
  tonemapLuminance(graded.r, graded.g, graded.b)

proc exposureProbe(value: float; ctx: ProbeContext): float =
  let graded = gradedRgb(
    RefTrailLight.r + ctx.render.bloomIntensity * RefBloomLight.r,
    RefTrailLight.g + ctx.render.bloomIntensity * RefBloomLight.g,
    RefTrailLight.b + ctx.render.bloomIntensity * RefBloomLight.b,
    value, ctx.render.saturation, ctx.render.contrast,
    ctx.render.temperature)
  tonemapLuminance(graded.r, graded.g, graded.b)

proc saturationProbe(value: float; ctx: ProbeContext): float =
  ## saturation: chroma spread of the graded colour. Luminance is provably
  ## invariant under the saturation mix (pinned in test_bloom_core), so a
  ## luminance observable would read this control as dead while the colour
  ## visibly drains.
  let graded = gradedRgb(RefTrailLight.r, RefTrailLight.g, RefTrailLight.b,
    ctx.render.exposure, value, ctx.render.contrast, ctx.render.temperature)
  abs(graded.r - graded.g) + abs(graded.g - graded.b) +
    abs(graded.b - graded.r)

proc contrastProbe(value: float; ctx: ProbeContext): float =
  ## contrast: total channel distance from the 0.5 pivot.
  let graded = gradedRgb(RefTrailLight.r, RefTrailLight.g, RefTrailLight.b,
    ctx.render.exposure, ctx.render.saturation, value,
    ctx.render.temperature)
  abs(graded.r - 0.5) + abs(graded.g - 0.5) + abs(graded.b - 0.5)

proc temperatureProbe(value: float; ctx: ProbeContext): float =
  ## temperature: the red-blue split the grade's last stage creates.
  let graded = gradedRgb(RefTrailLight.r, RefTrailLight.g, RefTrailLight.b,
    ctx.render.exposure, ctx.render.saturation, ctx.render.contrast, value)
  graded.r - graded.b

proc fieldOpacityProbe(value: float; ctx: ProbeContext): float =
  ## fieldOpacity: the composited field coverage over the background at a
  ## reference field sample — linear end to end, a must-pass anchor.
  fieldCoverage(0, 0.4, 0.5, value)

proc paletteDistance(saturation, lightness: float): float =
  let colors = generatePalette(RefPaletteCount, psGolden, saturation,
    lightness)
  var total = 0.0
  var pairs = 0
  for i in 0 ..< colors.len:
    for j in (i + 1) ..< colors.len:
      let dr = colors[i].red - colors[j].red
      let dg = colors[i].green - colors[j].green
      let db = colors[i].blue - colors[j].blue
      total += sqrt(dr * dr + dg * dg + db * db)
      inc pairs
  if pairs == 0: 0.0 else: total / pairs.float

proc paletteSaturationProbe(value: float; ctx: ProbeContext): float =
  ## paletteSaturation: mean pairwise colour distance across the generated
  ## species palette — how far apart the species actually look.
  paletteDistance(value, DEFAULT_LIGHTNESS)

proc paletteLightnessProbe(value: float; ctx: ProbeContext): float =
  paletteDistance(DEFAULT_SATURATION, value)

proc cameraApparentScale(zoom: float): float =
  ## The on-screen span of a fixed world segment at a zoom, through the
  ## camera transform mirror.
  let camera = zoomedAt(initCamera(RefWorldW.float32, RefWorldH.float32),
    zoom.float32, 0.0'f32, 0.0'f32, RefWorldW.float32, RefWorldH.float32)
  let west = worldToScreenUv(0.0'f32, 0.0'f32, camera, RefWorldW.float32,
    RefWorldH.float32)
  let east = worldToScreenUv(RefWorldSegment.float32, 0.0'f32, camera,
    RefWorldW.float32, RefWorldH.float32)
  abs(east.x - west.x).float

proc cameraZoomProbe(value: float; ctx: ProbeContext): float =
  cameraApparentScale(value)

proc visibleRadiusProbe(value: float; ctx: ProbeContext): float =
  ## particleSize: the COMPOSED on-screen radius (design E14) — the size
  ## parameter through the density multiplier's floor and the camera's
  ## apparent scale on this slice. The zoom-corner slices are what make the
  ## sweep, not review, hold the visibility floor.
  (value + 1.0) * RefDensitySizeFloor * cameraApparentScale(ctx.cameraZoom)

proc secretionProbe(value: float; ctx: ProbeContext): float =
  ## secretion (per species): the deposit a species' particle actually lands,
  ## through the shipped species-deposit composition.
  speciesDeposit(ctx.sim.rdDeposit, value)

proc tropismProbe(value: float; ctx: ProbeContext): float =
  ## tropism (per species): the force the reference gradient exerts on a
  ## species at this tropism weight.
  speciesTropismForce(RefGradient, ctx.sim.rdFieldForce, value)

# ------------------------------------------------------------------------------
# The registry
# ------------------------------------------------------------------------------

proc probeRegistry*(): Table[string, ProbeSpec] =
  ## Probe id -> function + budget. The descriptor carries the id; the native
  ## suite asserts every carried id resolves here and every entry is carried.
  result = {
    "force.multiplier": ProbeSpec(fn: forceMultiplierProbe,
      budget: pbClosedForm),
    "force.reachAtFixedApproach": ProbeSpec(fn: forceReachProbe,
      budget: pbClosedForm),
    "force.crowdingShare": ProbeSpec(fn: crowdingShareProbe,
      budget: pbClosedForm),
    "force.polyAtMidzone": ProbeSpec(fn: repulsionEndProbe,
      budget: pbClosedForm),
    "force.polyPeakSample": ProbeSpec(fn: attractionPeakProbe,
      budget: pbClosedForm),
    "force.expRepulsion": ProbeSpec(fn: expRepulsionProbe,
      budget: pbClosedForm),
    "force.expAttraction": ProbeSpec(fn: expAttractionProbe,
      budget: pbClosedForm),
    "motion.frictionRetention": ProbeSpec(fn: frictionProbe,
      budget: pbClosedForm),
    "motion.softCap": ProbeSpec(fn: maxVelocityProbe, budget: pbClosedForm),
    "motion.frameTravel": ProbeSpec(fn: timeScaleProbe,
      budget: pbClosedForm),
    "matrix.sampleSpread": ProbeSpec(fn: ruleTemperatureProbe,
      budget: pbClosedForm),
    "sph.pairShare": ProbeSpec(fn: fluidStrengthProbe,
      budget: pbClosedForm),
    "sph.pressureAtFixedDensity": ProbeSpec(fn: sphRestDensityProbe,
      budget: pbClosedForm),
    "sph.pressureGain": ProbeSpec(fn: sphStiffnessProbe,
      budget: pbClosedForm),
    "sph.velocityBlend": ProbeSpec(fn: sphViscosityProbe,
      budget: pbClosedForm),
    "sph.substepCeiling": ProbeSpec(fn: sphSubstepsProbe,
      budget: pbClosedForm),
    "sph.kernelReach": ProbeSpec(fn: sphKernelReachProbe,
      budget: pbClosedForm),
    "field.aliveFraction.feed": ProbeSpec(fn: rdFeedProbe,
      budget: pbStepped),
    "field.aliveFraction.kill": ProbeSpec(fn: rdKillProbe,
      budget: pbStepped),
    "field.resolvedDeposit": ProbeSpec(fn: rdDepositProbe,
      budget: pbClosedForm),
    "field.tropism": ProbeSpec(fn: rdFieldForceProbe,
      budget: pbClosedForm),
    "field.speciesDeposit": ProbeSpec(fn: secretionProbe,
      budget: pbClosedForm),
    "field.tropismWeight": ProbeSpec(fn: tropismProbe,
      budget: pbClosedForm),
    "climate.phaseStep": ProbeSpec(fn: climateSpeedProbe,
      budget: pbClosedForm),
    "render.trailPersistence": ProbeSpec(fn: trailPersistenceProbe,
      budget: pbClosedForm),
    "render.visibleRadius": ProbeSpec(fn: visibleRadiusProbe,
      budget: pbClosedForm),
    "glow.clampedIntegral": ProbeSpec(fn: glowIntensityProbe,
      budget: pbClosedForm),
    "glow.velocityIntegral": ProbeSpec(fn: velocityGlowProbe,
      budget: pbClosedForm),
    "glow.radiusIntegral": ProbeSpec(fn: glowRadiusProbe,
      budget: pbClosedForm),
    "glow.falloffIntegral": ProbeSpec(fn: glowFalloffProbe,
      budget: pbClosedForm),
    "glow.warmth": ProbeSpec(fn: glowWarmthProbe, budget: pbClosedForm),
    "grade.bloomLuminance": ProbeSpec(fn: bloomIntensityProbe,
      budget: pbClosedForm),
    "grade.exposureLuminance": ProbeSpec(fn: exposureProbe,
      budget: pbClosedForm),
    "grade.chromaSpread": ProbeSpec(fn: saturationProbe,
      budget: pbClosedForm),
    "grade.contrastSpread": ProbeSpec(fn: contrastProbe,
      budget: pbClosedForm),
    "grade.temperatureSplit": ProbeSpec(fn: temperatureProbe,
      budget: pbClosedForm),
    "colormap.coverage": ProbeSpec(fn: fieldOpacityProbe,
      budget: pbClosedForm),
    "palette.pairwiseDistance.saturation": ProbeSpec(
      fn: paletteSaturationProbe, budget: pbClosedForm),
    "palette.pairwiseDistance.lightness": ProbeSpec(
      fn: paletteLightnessProbe, budget: pbClosedForm),
    "camera.apparentScale": ProbeSpec(fn: cameraZoomProbe,
      budget: pbClosedForm),
  }.toTable

# ------------------------------------------------------------------------------
# Slices (design E2)
# ------------------------------------------------------------------------------

type
  SliceSpec* = object
    name*: string
    ctx*: ProbeContext

proc slicesFor*(descriptor: ParamDescriptor): seq[SliceSpec] =
  ## The declared context slices for a descriptor: the default slice always;
  ## the composed visible-radius observable adds the zoom corners (E14); the
  ## derived stiffness bound adds the corners of its deriving box (E2). No
  ## joint-group slices exist yet — E5's entry rule decides whether any joint
  ## group is declared, and it declares the slices with it.
  result = @[SliceSpec(name: "default", ctx: defaultProbeContext())]
  case descriptor.id
  of "particleSize":
    var low = defaultProbeContext()
    low.cameraZoom = CAMERA_ZOOM_MIN
    var high = defaultProbeContext()
    high.cameraZoom = CAMERA_ZOOM_MAX
    result = @[
      SliceSpec(name: "zoomFloor", ctx: low),
      SliceSpec(name: "zoomCeiling", ctx: high)]
  of "sphStiffness":
    for fraction in [SPH_RADIUS_FRACTION_MIN, SPH_RADIUS_FRACTION_MAX]:
      for substeps in [SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX]:
        var corner = defaultProbeContext()
        corner.sim.sphRadiusFraction = fraction
        corner.sim.sphSubsteps = substeps
        result.add SliceSpec(
          name: &"fraction={fraction} substeps={substeps}", ctx: corner)
  else:
    discard

proc servedMax*(descriptor: ParamDescriptor; ctx: ProbeContext): float =
  ## The top of the track ON THIS SLICE. For a ceiling-bound descriptor the
  ## track spans the interval the descriptor currently serves, so position
  ## keeps meaning "fraction of what I can reach" (design E2).
  if descriptor.bound.kind == bDerived:
    evaluateCeiling(descriptor.bound.ceilingId, CeilingInputs(
      interactionRadius: ctx.sim.interactionRadius,
      sphRadiusFraction: ctx.sim.sphRadiusFraction,
      sphSubsteps: ctx.sim.sphSubsteps,
      timeScale: ctx.sim.timeScale))
  else:
    descriptor.maxValue

# ------------------------------------------------------------------------------
# The metrics (design E2)
# ------------------------------------------------------------------------------

type
  SliceMeasurement* = object
    sliceName*: string
    span*: float
    liveFraction*: float
    cliff*: float
    deadStart*: float
    deadEnd*: float
      ## The longest run of dead track, as positions in [0, 1]. Equal when no
      ## pair is dead.

proc measureSlice*(descriptor: ParamDescriptor; spec: ProbeSpec;
    slice: SliceSpec): SliceMeasurement =
  ## Span, live fraction, and cliff over track positions on one slice. Where
  ## the parameter's own step lattice is coarser than the budget the real
  ## lattice is sampled, so a cliff between true adjacent steps is a cliff
  ## the metric sees.
  let low = descriptor.minValue
  let high = servedMax(descriptor, slice.ctx)
  let budget = case spec.budget
    of pbClosedForm: ProbeBudgetClosedForm
    of pbStepped: ProbeBudgetStepped
  var sampleCount = budget
  if descriptor.step > 0.0:
    let latticePoints = int((high - low) / descriptor.step + 1.5)
    if latticePoints >= 2 and latticePoints < budget:
      sampleCount = latticePoints

  var responses = newSeq[float](sampleCount)
  for i in 0 ..< sampleCount:
    let position = i.float / (sampleCount - 1).float
    responses[i] = spec.fn(low + position * (high - low), slice.ctx)

  var reference = 0.0
  for r in responses:
    reference = max(reference, abs(r))

  result.sliceName = slice.name
  if reference <= 0.0:
    return

  let spanAbs = abs(responses[^1] - responses[0])
  result.span = spanAbs / reference

  if spanAbs <= 0.0:
    return

  var livePairs = 0
  var maxDelta = 0.0
  var runStart = 0
  var bestStart = 0
  var bestLen = 0
  var runLen = 0
  for i in 1 ..< sampleCount:
    let delta = abs(responses[i] - responses[i - 1])
    if delta / spanAbs > RESPONSE_EPSILON:
      inc livePairs
      runLen = 0
      runStart = i
    else:
      inc runLen
      if runLen > bestLen:
        bestLen = runLen
        bestStart = runStart
    maxDelta = max(maxDelta, delta)
  result.liveFraction = livePairs.float / (sampleCount - 1).float
  result.cliff = maxDelta / spanAbs
  if bestLen > 0:
    result.deadStart = bestStart.float / (sampleCount - 1).float
    result.deadEnd = (bestStart + bestLen).float / (sampleCount - 1).float

proc passes*(measurement: SliceMeasurement): bool =
  measurement.span >= SPAN_MIN and
    measurement.liveFraction >= LIVE_FRACTION_MIN and
    measurement.cliff <= CLIFF_MAX

# ------------------------------------------------------------------------------
# The measured table (E3.5's deliverable)
# ------------------------------------------------------------------------------

proc legibilityReportMarkdown*(): string =
  ## The full measured table, every probed descriptor's metrics per slice —
  ## the artifact E5 calibrates from. The caller owns where it lands on disk.
  let registry = probeRegistry()
  result = "# Control legibility: the measured table\n\n"
  result.add "Span, live fraction, and cliff per declared slice (design " &
    "E2), at the provisional thresholds SPAN_MIN=" & $SPAN_MIN &
    ", LIVE_FRACTION_MIN=" & $LIVE_FRACTION_MIN & ", CLIFF_MAX=" &
    $CLIFF_MAX & ", RESPONSE_EPSILON=" & $RESPONSE_EPSILON &
    " (src/ui/api/response_probe.nim). Regenerated by " &
    "tests/test_response_probe.nim; edits here are overwritten.\n\n"
  result.add "| parameter | slice | span | live | cliff | dead run | " &
    "verdict |\n"
  result.add "|---|---|---|---|---|---|---|\n"
  for descriptor in buildParamDescriptors():
    if descriptor.probe.len == 0:
      continue
    let spec = registry[descriptor.probe]
    for slice in slicesFor(descriptor):
      let m = measureSlice(descriptor, spec, slice)
      let dead =
        if m.deadEnd > m.deadStart:
          &"{m.deadStart:.2f}-{m.deadEnd:.2f}"
        else:
          "none"
      let verdict = if m.passes: "pass" else: "FAIL"
      result.add &"| {descriptor.id} | {m.sliceName} | {m.span:.4f} | " &
        &"{m.liveFraction:.3f} | {m.cliff:.3f} | {dead} | {verdict} |\n"
