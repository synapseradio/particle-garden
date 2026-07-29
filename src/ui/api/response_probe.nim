# ==============================================================================
# PARTICLE GARDEN - RESPONSE PROBES
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
# Context and coordinates: every probe measures on a slice — all
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
# The thresholds. Calibrated inside the measured gap between the must-pass
# and must-fail anchor sets; the distribution each constant sits against is
# recorded beside it.
# ------------------------------------------------------------------------------

const
  RESPONSE_EPSILON* = 1e-4
    ## Movement below this fraction of the reference magnitude counts as none.
    ## Unmoved by calibration: neither anchor set separates on it, so the
    ## provisional hypothesis stands until a measurement gives it an edge to
    ## sit against.
  SPAN_MIN* = 0.15
    ## CALIBRATED inside the measured gap. Must-fail edge: rdFeed's
    ## span 0.131 on its old default slice; must-pass edge: sphViscosity's
    ## 0.667 (the smallest of the five). Placed near the fail edge so the
    ## modest-but-live resolved-deposit response (0.211) stays outside the
    ## remedy net; every must-pass control clears it by at least 4x.
  LIVE_FRACTION_MIN* = 0.70
    ## CALIBRATED. Must-fail edge: rdKill's 0.514; must-pass edge:
    ## 1.000 (all five). 0.70 sits between, above the fail edge by a third,
    ## and leaves expAttractionBeta's measured 0.875 — a live control with a
    ## short flat tail — clear of the bar.
  CLIFF_MAX* = 0.25
    ## KEPT at the provisional value, which the measurement showed already
    ## inside the gap: must-pass cliffs reach 0.020, the must-fail edge
    ## (rdFeed) measured 1.364.

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
  ## appears only inside its own probe (discharged by inspection of the
  ## registry below).
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
  RefCompression = 1.2
    ## Density over rest density where pressure probes read the equation of
    ## state — the working compression, well under the 2.0 Tait clamp.
  RefFrameSpeed = 30.0
    ## Reference speed in px/frame for the travel and friction probes.
  RefCapProbeSpeed = MAX_VELOCITY_MAX * 3.0
    ## A speed far above every reachable cap, so the soft cap always acts.
    ## Derived from the range it must outrun: the remedy pass found the
    ## old fixed 500 sat below the cap's active region over the top half of
    ## the track once friction damped it, contradicting this comment's own
    ## claim — the dead half the first sweep measured was the probe's, never
    ## the control's.
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
    ## visible-radius probe holds it at the worst corner.
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
  ## observable follows the cap itself. DECLARED LIFT: damping held at
  ## identity, because the shipped friction default (0.05) sets the cap's
  ## INPUT to a crawl and the first sweep measured that crawl as a dead top
  ## half — the observable here is the cap alone.
  postStepSpeed(RefCapProbeSpeed.float32, 1.0'f32, value.float32).float

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
  ## attractionPeak: where the pull is strongest — the argmax separation of
  ## the shipped bump over the attraction zone, which is the spacing a
  ## bound pair settles toward. A location observable rather than a height
  ## one: any FIXED sample separation sits inside or near some peak's
  ## travel, and the height read there spikes as the peak crosses or
  ## approaches it (measured cliff 0.57 sampling mid-travel, 0.31 sampling
  ## 0.025 past the highest peak): the probe's coordinate both times,
  ## never the control.
  const gridSamples = 512
  let zoneLow = ctx.sim.repulsionEnd
  var bestDist = zoneLow
  var bestPull = -1.0
  for i in 0 ..< gridSamples:
    let dist = zoneLow + (1.0 - zoneLow) * (i.float + 0.5) / gridSamples.float
    let pull = abs(polynomialForce(dist.float32, RefAttraction.float32,
      ctx.sim.repulsionEnd.float32, value.float32, 1.0'f32).float)
    if pull > bestPull:
      bestPull = pull
      bestDist = dist
  bestDist

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
  ## sphRestDensity: the pressure available across the neighbourhood
  ## densities a world can reach at this rest setting, integrated from the
  ## rest floor up to the smaller of the Tait input ceiling
  ## (SPH_MAX_DENSITY_RATIO multiples of rest, shader_config) and the
  ## densest neighbourhood any configured rest can drive at that ceiling.
  ## The first sweep read pressure at ONE fixed density and measured 90% of
  ## the track dead — truly it had measured that any single density lies
  ## inside at most one clamp-octave of rest settings. The parameter's own
  ## promise is where the pressure regime SITS, and the band integral is
  ## that promise as one scalar. The band floors at the isolated particle's
  ## normalized self-density 1.0 (forces-sph.wgsl's normalization), below
  ## which no world density exists.
  let ratioCeiling = getTunableFloat("SPH_MAX_DENSITY_RATIO")
  let packedDensity = ratioCeiling * SPH_REST_DENSITY_MAX
  let bandLow = max(value, 1.0)
  let bandHigh = min(value * ratioCeiling, packedDensity)
  if bandHigh <= bandLow:
    return 0.0
  const bandSamples = 32
  var total = 0.0
  for i in 0 ..< bandSamples:
    let density = bandLow +
      (bandHigh - bandLow) * (i.float + 0.5) / bandSamples.float
    total += flooredTaitPressure(density, value, ctx.sim.sphStiffness,
      SPH_DEFAULT_GAMMA)
  total * (bandHigh - bandLow) / bandSamples.float

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

proc sphFractionCeilingProbe(value: float; ctx: ProbeContext): float =
  ## sphRadiusFraction: the stable stiffness ceiling the fraction buys — the
  ## measured linear stability law (sph_core.stableStiffnessCeiling), the
  ## fraction's shipped consequence. The first sweep read a poly6 weight at
  ## one fixed pair separation and measured the kernel-support edge and the
  ## normalization spike of coordinates no world holds still (span 0.13,
  ## cliff 1.25); the kernel math itself stays pinned by test_sph_core. The
  ## calibration note on the inert region below ~2.5 px stands in
  ## config_ranges, untouched by this observable.
  stableStiffnessCeiling(
    value * ctx.sim.interactionRadius.float,
    ctx.sim.sphSubsteps,
    ctx.sim.timeScale * SPH_CEILING_REFERENCE_FRAME_SECONDS,
    SPH_STIFFNESS_MAX)

# --- the stepped field probes --------------------------------------------------

const
  FieldProbeGrid = 64
    ## Grid edge for the stepped probes, the field harness's own size.
  FieldProbeFrames* = 60
    ## Frames each sample integrates before the statistic is read — the
    ## executable form of the structural response horizon, which is why the
    ## horizon suite names it.
  FieldProbeAliveThreshold = FIELD_ALIVE_THRESHOLD
    ## Aliveness read from field_core's single authority, the same number
    ## the pattern tests and the shader's alive-cell census read.

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
  ## Most of the feed-kill rectangle admits no nontrivial fixed point on any
  ## single slice, which is why the pair is judged through its joint group's
  ## regime-point slices rather than whole-track metrics.
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
  ## deadness the metric must see. DECLARED COORDINATE: full
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
  ## trailLength: the 1/e persistence horizon in frames. Linear in the
  ## slider: the shipped mapping decays to a fixed residual over a frame
  ## count proportional to the length (trail_core.persistenceFrames), so
  ## the horizon measures live end to end.
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
  ## paletteLightness: the palette's mean luminance. Its promise is that the
  ## colours LIGHTEN together, and the first sweep measured why pairwise
  ## distance cannot see that: both lightness endpoints collapse every
  ## colour (to black, to white), so the endpoint span read exactly zero
  ## over a control that visibly moves everything — a mid-track-peaked
  ## observable is the wrong shape for the endpoint span, not a dead
  ## control.
  let colors = generatePalette(RefPaletteCount, psGolden,
    DEFAULT_SATURATION, value)
  if colors.len == 0:
    return 0.0
  var total = 0.0
  for color in colors:
    total += tonemapLuminance(color.red, color.green, color.blue)
  total / colors.len.float

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
  ## particleSize: the COMPOSED on-screen radius — the size
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
    "force.polyPeakLocation": ProbeSpec(fn: attractionPeakProbe,
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
    "sph.reachablePressureBand": ProbeSpec(fn: sphRestDensityProbe,
      budget: pbClosedForm),
    "sph.pressureGain": ProbeSpec(fn: sphStiffnessProbe,
      budget: pbClosedForm),
    "sph.velocityBlend": ProbeSpec(fn: sphViscosityProbe,
      budget: pbClosedForm),
    "sph.fractionCeiling": ProbeSpec(fn: sphFractionCeilingProbe,
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
    "palette.meanLuminance": ProbeSpec(
      fn: paletteLightnessProbe, budget: pbClosedForm),
    "camera.apparentScale": ProbeSpec(fn: cameraZoomProbe,
      budget: pbClosedForm),
  }.toTable

# ------------------------------------------------------------------------------
# Slices
# ------------------------------------------------------------------------------

type
  SliceSpec* = object
    name*: string
    ctx*: ProbeContext

const
  JointMembers* = ["rdFeed", "rdKill"]
    ## THE FEED/KILL JOINT GROUP. Its named points
    ## are the regime table (config_ranges.RD_REGIMES — the same points the
    ## notches draw from), and each member is measured on slices with its
    ## partner fixed at every point's coordinate, deposit floored at the
    ## regime's measured minimum. ENTRY EVIDENCE: the members' live
    ## boundaries move with the partner across the point slices by more
    ## than JointPointNeighbourhood (measured: rdKill's live top end
    ## travels 0.35 of the track between the waves and worms slices,
    ## rdFeed's live bottom 0.24) — asserted by
    ## tests/test_response_probe.nim and recorded per slice in
    ## docs/control-legibility-report.md — so no partner-independent
    ## placement of the live region serves them and the pair enters the
    ## group. Hull non-overlap is NOT the instrument: hulls can overlap
    ## while the live region inside them shifts with the partner, so
    ## overlap fails to place one live position on every slice.
    ## Members are judged by
    ## the group's guarantees (live within JointPointNeighbourhood of every
    ## named point, on that point's slice), never by whole-track metrics no
    ## jointly-shaped control can satisfy.
  JointPointNeighbourhood* = 0.10
    ## Track fraction around a named point within which the member must
    ## measure live on that point's slice.

proc slicesFor*(descriptor: ParamDescriptor): seq[SliceSpec] =
  ## The declared context slices for a descriptor: the default slice always;
  ## the composed visible-radius observable adds the zoom corners; the
  ## derived stiffness bound adds the corners of its deriving box; a
  ## joint-group member takes the slices through its group's named points in
  ## place of the default, because its live region is jointly shaped and the
  ## default slice is a single line through it.
  result = @[SliceSpec(name: "default", ctx: defaultProbeContext())]
  case descriptor.id
  of "rdFeed", "rdKill":
    result = @[]
    for regime in RD_REGIMES:
      var pointCtx = defaultProbeContext()
      pointCtx.sim.rdFeed = regime.feed
      pointCtx.sim.rdKill = regime.kill
      pointCtx.sim.rdDeposit = max(pointCtx.sim.rdDeposit, regime.minDeposit)
      result.add SliceSpec(name: regime.id, ctx: pointCtx)
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
  ## keeps meaning "fraction of what I can reach".
  if descriptor.bound.kind == bDerived:
    evaluateCeiling(descriptor.bound.ceilingId, CeilingInputs(
      interactionRadius: ctx.sim.interactionRadius,
      sphRadiusFraction: ctx.sim.sphRadiusFraction,
      sphSubsteps: ctx.sim.sphSubsteps,
      timeScale: ctx.sim.timeScale))
  else:
    descriptor.maxValue

# ------------------------------------------------------------------------------
# The metrics
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
    liveStart*: float
    liveEnd*: float
      ## The outermost live pairs' positions — the live interval the joint
      ## group's entry evidence compares across slices. Both zero when no
      ## pair is live.

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
  var firstLive = -1
  var lastLive = -1
  for i in 1 ..< sampleCount:
    let delta = abs(responses[i] - responses[i - 1])
    if delta / spanAbs > RESPONSE_EPSILON:
      inc livePairs
      if firstLive < 0:
        firstLive = i - 1
      lastLive = i
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
  if firstLive >= 0:
    result.liveStart = firstLive.float / (sampleCount - 1).float
    result.liveEnd = lastLive.float / (sampleCount - 1).float

proc passes*(measurement: SliceMeasurement): bool =
  measurement.span >= SPAN_MIN and
    measurement.liveFraction >= LIVE_FRACTION_MIN and
    measurement.cliff <= CLIFF_MAX

# ------------------------------------------------------------------------------
# The measured table
# ------------------------------------------------------------------------------

proc allSliceMeasurements*(): OrderedTable[string, seq[SliceMeasurement]] =
  ## Every probed descriptor's metrics on every declared slice, measured
  ## once. The sweep's assertions and the emitted table both read this
  ## shared result, so the stepped field probes run a single pass however
  ## many claims are checked against them.
  let registry = probeRegistry()
  result = initOrderedTable[string, seq[SliceMeasurement]]()
  for descriptor in buildParamDescriptors():
    if descriptor.probe.len == 0:
      continue
    var rows: seq[SliceMeasurement]
    for slice in slicesFor(descriptor):
      rows.add measureSlice(descriptor, registry[descriptor.probe], slice)
    result[descriptor.id] = rows

proc legibilityReportMarkdown*(
    measured: OrderedTable[string, seq[SliceMeasurement]]): string =
  ## The measured table, every probed descriptor's metrics per slice — the
  ## artifact the calibration reads. The caller owns where it lands on disk.
  ## Joint-group members print their measurements with a `joint` verdict:
  ## their bar is the group's own guarantees, never whole-track metrics.
  result = "# Control legibility: the measured table\n\n"
  result.add "Span, live fraction, and cliff per declared slice, " &
    "at the calibrated thresholds SPAN_MIN=" & $SPAN_MIN &
    ", LIVE_FRACTION_MIN=" & $LIVE_FRACTION_MIN & ", CLIFF_MAX=" &
    $CLIFF_MAX & ", RESPONSE_EPSILON=" & $RESPONSE_EPSILON &
    " (src/ui/api/response_probe.nim records the calibration beside each " &
    "constant). Regenerated by tests/test_response_probe.nim; edits here " &
    "are overwritten.\n\n"
  result.add "| parameter | slice | span | live | cliff | dead run | " &
    "live interval | verdict |\n"
  result.add "|---|---|---|---|---|---|---|---|\n"
  for id, rows in measured:
    for m in rows:
      let dead =
        if m.deadEnd > m.deadStart:
          &"{m.deadStart:.2f}-{m.deadEnd:.2f}"
        else:
          "none"
      let live =
        if m.liveEnd > m.liveStart:
          &"{m.liveStart:.2f}-{m.liveEnd:.2f}"
        else:
          "none"
      let verdict =
        if id in JointMembers: "joint"
        elif m.passes: "pass"
        else: "FAIL"
      result.add &"| {id} | {m.sliceName} | {m.span:.4f} | " &
        &"{m.liveFraction:.3f} | {m.cliff:.3f} | {dead} | {live} | " &
        &"{verdict} |\n"
