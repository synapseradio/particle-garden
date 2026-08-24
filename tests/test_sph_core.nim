# Analytic tests for src/sph_core.nim: the pure 2D SPH kernel math, Tait
# equation of state, and XSPH velocity smoothing that the forces-sph.wgsl
# compute shader mirrors. Every function takes the smoothing radius h as a
# runtime parameter — nothing is precomputed against a fixed h — so these
# tests exercise the identities across two different radii.
#
# The poly6 normalization is verified by numerical integration rather than by
# pinning the closed-form constant: if the derived constant were wrong, the
# integral over the support disc would not equal 1.

import std/[unittest, math]
import ../src/sph_core
import ../src/shader_config

from ../src/memory_layout import MAX_PARTICLES
from ../src/physics_core import FRAME_DT_REFERENCE, frameFactor
# The stability harness below runs the fluid at the shipped defaults, so it
# reads them from the default authority rather than restating any of them.
from ../src/ui/state/simulation_state import initSimulationState
# The smoothing radius is the interaction radius times a fraction, so the
# reachable effective radii are the product of two ranges the slider contract
# owns. Read from there rather than restated here: raising either range
# re-scopes the sweep below without a second edit.
from ../src/config_ranges import SPH_RADIUS_FRACTION_MIN,
  SPH_RADIUS_FRACTION_MAX, INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX,
  FLUID_STRENGTH_MAX, SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX, SPH_SUBSTEPS_MIN,
  SPH_SUBSTEPS_MAX, TIME_SCALE_MIN, TIME_SCALE_MAX

const SPH_CORE_TESTS_LOADED* = true

# EPSILON for the analytic identities. The numerical integral uses a coarser
# tolerance (1e-3) since it is a Riemann approximation, not an exact identity.
const EPSILON = 1e-9
const INTEGRAL_TOLERANCE = 1e-3

let atReferenceFrame = frameFactor(FRAME_DT_REFERENCE)
  ## Every kernel and pressure number in this suite was measured on a frame
  ## worth FRAME_DT_REFERENCE, so the XSPH calls that are not about the frame
  ## pass this and read exactly what they read before the frame reached them.

proc integratePoly6OverDisc(smoothingRadius: float; steps: int): float =
  ## Numerically integrate poly6Weight2d(r, h) * 2*pi*r dr over [0, h] with the
  ## trapezoid rule. For a correctly 2D-normalized kernel this equals 1.
  let stepWidth = smoothingRadius / steps.float
  var total = 0.0
  for stepIndex in 0 .. steps:
    let radius = stepIndex.float * stepWidth
    let integrand = poly6Weight2d(radius, smoothingRadius) * 2.0 * PI * radius
    # Trapezoid: endpoints carry half weight.
    if stepIndex == 0 or stepIndex == steps:
      total += 0.5 * integrand
    else:
      total += integrand
  total * stepWidth

proc radiusFractionSweep(steps: int): seq[float] =
  ## The fraction range sampled end to end, endpoints included. The endpoints
  ## are the two that matter: the minimum is the smallest kernel the sliders
  ## reach, and the maximum is the shipped default.
  result = @[]
  for stepIndex in 0 .. steps:
    result.add SPH_RADIUS_FRACTION_MIN +
      (SPH_RADIUS_FRACTION_MAX - SPH_RADIUS_FRACTION_MIN) *
        stepIndex.float / steps.float

func normalizedDensityWeight(distance, smoothingRadius: float): float =
  ## The density weight forces-sph.wgsl forms: the poly6 weight divided by
  ## the self-weight, which is what makes an isolated particle read 1.0 and the
  ## accumulated density count neighbours.
  poly6Weight2d(distance, smoothingRadius) / poly6Weight2d(0.0, smoothingRadius)

func normalizedGradientWeight(distance, smoothingRadius: float): float =
  ## The gradient weight forces-sph.wgsl forms, by the same division. The
  ## pressure acceleration is this times the pair pressure, so the smoothing
  ## radius reaches the pressure term through here and nowhere else.
  spikyGradientMagnitude2d(distance, smoothingRadius) /
    spikyGradientMagnitude2d(0.0, smoothingRadius)


suite "Poly6 Kernel Is 2D-Normalized":
  test "poly6 integrates to 1 over its support disc for multiple radii":
    # CONTRACT: the 2D normalization constant must make the kernel a partition
    # of unity over the disc of radius h — the analytic warrant for using it as
    # a density estimator weight. Verified numerically for two radii.
    for smoothingRadius in [30.0, 75.0]:
      let integral = integratePoly6OverDisc(smoothingRadius, 200_000)
      check abs(integral - 1.0) < INTEGRAL_TOLERANCE

  test "poly6 has compact support: exactly 0 at and beyond h":
    # CONTRACT: a particle at or past the smoothing radius contributes no
    # density, so the neighbor search can stop at h.
    for smoothingRadius in [30.0, 75.0]:
      check poly6Weight2d(smoothingRadius, smoothingRadius) == 0.0
      check poly6Weight2d(smoothingRadius + 1.0, smoothingRadius) == 0.0
      check poly6Weight2d(smoothingRadius * 2.0, smoothingRadius) == 0.0

  test "poly6 is strictly positive and peaks at the center":
    let smoothingRadius = 50.0
    check poly6Weight2d(0.0, smoothingRadius) > 0.0
    check poly6Weight2d(0.0, smoothingRadius) >
      poly6Weight2d(25.0, smoothingRadius)
    check poly6Weight2d(25.0, smoothingRadius) >
      poly6Weight2d(49.0, smoothingRadius)


suite "Spiky Gradient Produces A Monotone Repulsive Magnitude":
  test "spiky gradient magnitude has compact support: 0 at and beyond h":
    for smoothingRadius in [30.0, 75.0]:
      check spikyGradientMagnitude2d(smoothingRadius, smoothingRadius) == 0.0
      check spikyGradientMagnitude2d(smoothingRadius + 5.0, smoothingRadius) == 0.0

  test "spiky gradient magnitude is strictly positive inside the support":
    # WHY: pressure forces need a non-vanishing repulsive gradient right up to
    # the support edge to resist compression.
    let smoothingRadius = 60.0
    for radius in [1.0, 15.0, 30.0, 45.0, 59.0]:
      check spikyGradientMagnitude2d(radius, smoothingRadius) > 0.0

  test "spiky gradient magnitude strictly decreases with distance":
    # CONTRACT: closer neighbors repel harder — the magnitude falls off
    # monotonically across (0, h).
    let smoothingRadius = 60.0
    var previous = spikyGradientMagnitude2d(0.5, smoothingRadius)
    for radius in [5.0, 15.0, 30.0, 45.0, 55.0, 59.5]:
      let current = spikyGradientMagnitude2d(radius, smoothingRadius)
      check current < previous
      previous = current


# forces-sph.wgsl multiplies the interaction radius by params.sphRadiusFraction
# to get the smoothing radius, so the reachable effective radii run from
# INTERACTION_RADIUS_MIN * SPH_RADIUS_FRACTION_MIN up to INTERACTION_RADIUS_MAX.
# Nothing in sph_core changes for that: every function already takes h as a
# parameter and recomputes its normalization from it. These tests pin the
# properties the shader change relies on, over the whole box the two ranges
# open.

suite "The Smoothing Radius Is A Fraction Of The Interaction Radius":
  test "fraction one reproduces today's kernels":
    # The top of the fraction range is exactly 1, so the fluid at full
    # interaction radius stays expressible — and expressible as the identical
    # arithmetic, not an approximation of it. Both kernels and both
    # weights the shader forms from them are compared exactly, because
    # multiplying by one is exact in binary and anything less than exact would
    # mean the top of the range had moved off 1.
    for interactionRadius in [INTERACTION_RADIUS_MIN.float, 50.0,
        INTERACTION_RADIUS_MAX.float]:
      let scaled = interactionRadius * SPH_RADIUS_FRACTION_MAX
      checkpoint("interaction radius " & $interactionRadius)
      check scaled == interactionRadius
      for distanceRatio in [0.0, 0.1, 0.25, 0.5, 0.75, 0.99]:
        let distance = distanceRatio * interactionRadius
        check poly6Weight2d(distance, scaled) ==
          poly6Weight2d(distance, interactionRadius)
        check spikyGradientMagnitude2d(distance, scaled) ==
          spikyGradientMagnitude2d(distance, interactionRadius)
        check normalizedDensityWeight(distance, scaled) ==
          normalizedDensityWeight(distance, interactionRadius)
        # The pressure term is the pair pressure times this weight and the XSPH
        # term is epsilon times the density weight times the velocity gap, so
        # holding the two weights fixed holds both terms fixed.
        check normalizedGradientWeight(distance, scaled) ==
          normalizedGradientWeight(distance, interactionRadius)
        check xsphVelocityCorrection(3.0, 11.0,
            normalizedDensityWeight(distance, scaled), SPH_XSPH_EPSILON,
            atReferenceFrame) ==
          xsphVelocityCorrection(3.0, 11.0,
            normalizedDensityWeight(distance, interactionRadius),
            SPH_XSPH_EPSILON, atReferenceFrame)

  test "kernel normalization holds across the fraction range":
    # CONTRACT: the poly6 constant is derived from h rather than precomputed
    # against one, so it stays a partition of unity at every effective radius
    # the fraction opens — including the smallest, where h to the 8th power in
    # the denominator is at its most extreme. Verified the way the suite
    # verifies it at full radius: by integrating over the support disc.
    for interactionRadius in [INTERACTION_RADIUS_MIN.float, 50.0,
        INTERACTION_RADIUS_MAX.float]:
      for fraction in radiusFractionSweep(6):
        let smoothingRadius = interactionRadius * fraction
        checkpoint("interaction radius " & $interactionRadius &
          ", fraction " & $fraction)
        check abs(integratePoly6OverDisc(smoothingRadius, 50_000) - 1.0) <
          INTEGRAL_TOLERANCE

  test "the fluid keeps its relative scale when the interaction radius moves":
    # CONTRACT: what a particle feels depends on distance measured in smoothing
    # radii, never on the radius itself — which is what makes a FRACTION the
    # right control. Move the interaction radius with the fraction held fixed
    # and the whole neighbourhood scales with it, so the interaction radius
    # stays one meaningful control rather than two coupled ones.
    for distanceRatio in [0.0, 0.2, 0.5, 0.9]:
      var densityReference = NaN
      var gradientReference = NaN
      for interactionRadius in [INTERACTION_RADIUS_MIN.float, 37.0, 50.0,
          INTERACTION_RADIUS_MAX.float]:
        for fraction in radiusFractionSweep(4):
          let smoothingRadius = interactionRadius * fraction
          let distance = distanceRatio * smoothingRadius
          checkpoint("ratio " & $distanceRatio & ", radius " &
            $interactionRadius & ", fraction " & $fraction)
          if densityReference.isNaN:
            densityReference = normalizedDensityWeight(distance, smoothingRadius)
            gradientReference =
              normalizedGradientWeight(distance, smoothingRadius)
          check abs(normalizedDensityWeight(distance, smoothingRadius) -
            densityReference) < EPSILON
          check abs(normalizedGradientWeight(distance, smoothingRadius) -
            gradientReference) < EPSILON


suite "Tait Equation Of State":
  test "pressure is exactly 0 at the rest density for any stiffness and gamma":
    # CONTRACT: P(restDensity) == 0 so a fluid at rest density feels no
    # pressure force. Holds independent of stiffness and gamma.
    for stiffness in [1.0, 8.0, 40.0]:
      for gamma in [1.0, 7.0]:
        check abs(taitPressure(1000.0, 1000.0, stiffness, gamma)) < EPSILON

  test "pressure strictly increases with density":
    # CONTRACT: compressed fluid (density above rest) pushes back harder.
    let restDensity = 1000.0
    var previous = taitPressure(restDensity, restDensity, 8.0, 7.0)
    for density in [1050.0, 1100.0, 1200.0, 1500.0]:
      let current = taitPressure(density, restDensity, 8.0, 7.0)
      check current > previous
      previous = current

  test "pressure below rest density is negative (cohesive)":
    check taitPressure(900.0, 1000.0, 8.0, 7.0) < 0.0

  test "pressure scales linearly with stiffness at a fixed density ratio":
    # CONTRACT: stiffness is the pressure gain — doubling it doubles the
    # pressure at any fixed density ratio.
    let base = taitPressure(1200.0, 1000.0, 8.0, 7.0)
    let doubled = taitPressure(1200.0, 1000.0, 16.0, 7.0)
    check abs(doubled - 2.0 * base) < 1e-6


suite "Floored Tait Pressure Mirrors The Shader's Purely-Repulsive EOS":
  test "pressure is 0 both at rest density and everywhere below it":
    # CONTRACT: forces-sph.wgsl floors density at restDensity before the EOS,
    # so an isolated particle (self-density 1.0) and a resting one both feel
    # zero pressure. With restDensity 3.0, isolation sits below rest and must
    # not repel — a restDensity of 1.0 makes isolation the zero-pressure state,
    # which turns every contact repulsive and the fluid into an expanding gas.
    let restDensity = 3.0
    check abs(flooredTaitPressure(
      1.0, restDensity, 8.0, SPH_DEFAULT_GAMMA)) < EPSILON
    check abs(flooredTaitPressure(
      restDensity, restDensity, 8.0, SPH_DEFAULT_GAMMA)) < EPSILON

  test "pressure is positive and strictly increasing above rest density":
    # CONTRACT: only compression past rest pushes back, and harder the more
    # compressed the neighborhood is.
    let restDensity = 3.0
    check flooredTaitPressure(4.0, restDensity, 8.0, SPH_DEFAULT_GAMMA) > 0.0
    var previous = 0.0
    for density in [3.5, 4.0, 5.0, 6.0]:
      let current = flooredTaitPressure(
        density, restDensity, 8.0, SPH_DEFAULT_GAMMA)
      check current > previous
      previous = current


suite "XSPH Velocity Correction Is Bounded By Epsilon Times The Velocity Gap":
  test "the correction magnitude never exceeds epsilon * |velocity difference|":
    # CONTRACT: XSPH smooths velocity toward the neighborhood mean without ever
    # overshooting — a single neighbor pair can move the velocity by at most
    # epsilon times the velocity gap, regardless of the (possibly out-of-range)
    # weight fed in. This is what keeps the smoothing stable.
    for velocitySelf in [-10.0, 0.0, 3.5, 20.0]:
      for velocityNeighbor in [-20.0, 0.0, 7.0, 15.0]:
        for neighborWeight in [-0.5, 0.0, 0.3, 1.0, 2.0]:
          for epsilon in [0.0, SPH_XSPH_EPSILON, 1.0]:
            let correction = xsphVelocityCorrection(
              velocitySelf, velocityNeighbor, neighborWeight, epsilon,
              atReferenceFrame)
            let velocityGap = abs(velocityNeighbor - velocitySelf)
            check abs(correction) <= epsilon * velocityGap + EPSILON

  test "the correction points toward the neighbor velocity":
    check xsphVelocityCorrection(5.0, 10.0, 0.5, SPH_XSPH_EPSILON,
      atReferenceFrame) > 0.0
    check xsphVelocityCorrection(5.0, 0.0, 0.5, SPH_XSPH_EPSILON,
      atReferenceFrame) < 0.0

  test "a zero weight or zero epsilon yields no correction":
    check xsphVelocityCorrection(5.0, 10.0, 0.0, SPH_XSPH_EPSILON,
      atReferenceFrame) == 0.0
    check xsphVelocityCorrection(5.0, 10.0, 0.5, 0.0, atReferenceFrame) == 0.0
    check xsphVelocityCorrection(5.0, 10.0, 0.5, SPH_XSPH_EPSILON, 0.0) == 0.0


suite "SPH Tuning Constants Are In Physical Range":
  test "gamma, epsilon, and substep bounds hold their documented values":
    check SPH_DEFAULT_GAMMA == 7.0
    check SPH_XSPH_EPSILON == 0.5
    check SPH_MAX_SUBSTEPS == 3

  test "the XSPH epsilon is a well-formed blend fraction in [0, 1]":
    check SPH_XSPH_EPSILON >= 0.0
    check SPH_XSPH_EPSILON <= 1.0


# What sets the worst case: forces-sph.wgsl divides each neighbour's poly6
# weight by the self-weight, so one neighbour contributes at most 1.0 and the
# accumulated density counts neighbours. Nothing bounds how many particles share
# a smoothing radius, so the largest density the world can produce is exactly
# MAX_PARTICLES: every particle the slider allows, gathered into one place.
#
# The accumulator must hold that, not clamp it. A shared FIXED_POINT_SCALE of
# 65536 spans 32768, which MAX_PARTICLES passes by 3.9x, and an i32 past its
# maximum wraps negative — a density the equation of state reads as maximal
# expansion and answers with force in the wrong direction. Clamping would answer
# the overflow by making the particle ceiling unreachable, so the density
# accumulator takes its own coarser scale instead, derived from the budget.

suite "The Full Particle Budget Encodes Without Saturating":
  const I32_MAX = 2147483647.0
  let scale = sphDensityFixedPointScale(MAX_PARTICLES)

  test "the whole particle budget in one smoothing radius encodes as itself":
    # The full particle budget (MAX_PARTICLES) is a reachable setting, so the
    # density it produces has to survive the round trip rather than saturate on
    # the way in.
    check float(MAX_PARTICLES) * scale < I32_MAX
    check fixedPointCeiling(scale) > float(MAX_PARTICLES)

  test "the scale keeps the stated headroom above the budget":
    # The accumulation is atomic across threads, so the total is formed by adds
    # that never see each other. Headroom is what absorbs that.
    check fixedPointCeiling(scale) >=
      float(MAX_PARTICLES) * SPH_DENSITY_HEADROOM

  test "the scale is a power of two so encoding introduces no rounding":
    let exponent = log2(scale)
    check abs(exponent - round(exponent)) < 1e-12

  test "the scale follows the particle budget rather than a literal":
    # Raising MAX_PARTICLES must move the scale with it. A budget that grows by
    # 4x drops the scale by 4x and still fits, which is what makes the ceiling a
    # one-constant change instead of a silent overflow.
    for budget in [MAX_PARTICLES, MAX_PARTICLES * 4, MAX_PARTICLES * 64]:
      let budgetScale = sphDensityFixedPointScale(budget)
      check float(budget) * budgetScale < I32_MAX
      check fixedPointCeiling(budgetScale) >=
        float(budget) * SPH_DENSITY_HEADROOM

  test "one particle's own weight stays far above the accumulator's resolution":
    # An isolated particle reads exactly 1.0. The scale is only useful if that
    # value is resolved with room to spare, or the fluid loses its rest state.
    check 1.0 / scale < 0.001

# What it is: a small periodic world running the fluid alone: the density,
# pressure and XSPH loop of `web/shaders/src/forces-sph.wgsl` and the friction,
# soft velocity cap and toroidal wrap of `web/shaders/src/integrate.wgsl`,
# stepped substepCount times per frame the way `src/webgpu_compute.nim`
# steps them. Same shape as test_field_core's chemotaxis harness: the shipped
# arithmetic, run natively, so a bound on it is measured rather than asserted.
#
# What it measures: the largest stiffness at which a compressed neighbourhood
# still comes to rest. Past that the pressure solver overshoots every substep,
# friction cannot remove what it injects, and the fluid churns for as long as it
# runs. That is the boundary `stableStiffnessCeiling` is fitted under.
#
# Why not divergence: nothing here can reach infinity, and that is by design in
# the shader rather than an accident: the Tait input is clamped at
# SPH_MAX_DENSITY_RATIO times rest, each pair's acceleration at
# SPH_MAX_PRESSURE_ACCEL, and every speed at maxVelocity through the log soft
# cap. An unstable fluid therefore saturates instead of exploding, so the run
# reports the residual speed and the non-finite check below stays as the guard
# it is — it fires only if one of those clamps is ever removed.
#
# The configuration is dimensionless: each run seeds the same neighbourhood
# measured in smoothing radii: the box is HARNESS_BOX_RADII radii across and
# holds the particle count that puts the seeded density at
# HARNESS_SEED_DENSITY_RATIO times rest. Only the discretisation then varies
# with h, which is what isolates the stability question from "is there a fluid
# here at all". A world whose number density is fixed instead would simply run
# out of neighbours as h shrank.

const
  HARNESS_BOX_RADII = 4.0
    ## Box side in smoothing radii. Above 2 so the minimum-image convention
    ## below never lets a particle meet the same neighbour twice, and small
    ## enough that the pair loop stays affordable in the suite.
  HARNESS_SEED_DENSITY_RATIO = 2.0
    ## Seeded compression, in multiples of rest density. Exactly the ceiling
    ## forces-sph.wgsl clamps its Tait input at, so the seed is the most
    ## compressed neighbourhood the equation of state answers to: past it the
    ## per-pair pressure stops growing.
  HARNESS_FRAMES = 120
    ## Frames per run. Friction alone empties a disturbance long before this
    ## (0.95 per substep is a factor of 1e-3 in 120 frames), so residual motion
    ## at the end is motion the scheme is still injecting.
  HARNESS_SETTLED_TAIL = 4
    ## The run reports the mean speed over its last 1/N frames.
  HARNESS_AT_REST_SPEED = 0.5
    ## Residual RMS speed, in px per frame, at or below which the fluid counts
    ## as having come to rest. It sits between two floors that are two orders of
    ## magnitude apart: a run at negligible stiffness drifts at about 3e-4 px
    ## per frame, and an unstable one settles above 1. Measured either side of
    ## it, the boundary moves by about a fifth per factor of two in this
    ## threshold, and the fitted coefficient carries that as margin.
  HARNESS_REFERENCE_FRAME_SECONDS = 1.0 / 60.0
    ## Wall-clock frame the harness reads its timestep against, so a timeScale
    ## names a dt the way app.nim's loop produces one.

type
  HarnessParticle = object
    x, y, vx, vy: float
    sphDensity: float   ## Lagged, exactly as the shader reads it
  HarnessRun = object
    ## What one run reports. `settledSpeed` is the verdict; the rest are what a
    ## failing run needs in its checkpoint to be diagnosable.
    finite: bool
    peakSpeed: float
    settledSpeed: float
    peakDensity: float
    frames: int

func harnessParticleCount(): int =
  ## Particles that put the seeded density at HARNESS_SEED_DENSITY_RATIO times
  ## rest inside a HARNESS_BOX_RADII box, for ANY h.
  ##
  ## A uniform number density n reads as density 1 + n * integral of the
  ## normalized poly6 over its disc, and that integral is pi h^2 / 4 (substitute
  ## u = r^2/h^2 in 2 pi int r (1 - r^2/h^2)^3 dr). So n = 4 (D - 1) / (pi h^2)
  ## and the count in a box of side k h is 4 (D - 1) k^2 / pi — free of h, which
  ## is the point.
  let restDensity = initSimulationState().sphRestDensity
  int(4.0 * (HARNESS_SEED_DENSITY_RATIO * restDensity - 1.0) / PI *
    HARNESS_BOX_RADII * HARNESS_BOX_RADII)

func harnessSeed(count: int; boxSide: float): seq[HarnessParticle] =
  ## Deterministic scatter, at rest. The same fixed LCG test_field_core seeds
  ## with, and for the same reason: a lattice would place every particle at the
  ## one arrangement whose pressure forces cancel by symmetry, which is the
  ## arrangement that flatters a stability claim.
  var state = 0x9E3779B9'u32
  for _ in 0 ..< count:
    state = state * 1664525'u32 + 1013904223'u32
    let sampleX = (state shr 8).float / 16777216.0
    state = state * 1664525'u32 + 1013904223'u32
    let sampleY = (state shr 8).float / 16777216.0
    result.add HarnessParticle(
      x: sampleX * boxSide, y: sampleY * boxSide, sphDensity: 0.0)

func harnessWrap(position, span: float): float =
  ## Toroidal wrap by true modulo rather than integrate.wgsl's single subtract.
  ## One span suffices in the shipped world — WORLD_W across against the
  ## shipped default maxVelocity per frame — and does not here, where the box
  ## is a few smoothing radii wide and a saturated run crosses it several times
  ## in one frame.
  result = position - span * floor(position / span)
  if result >= span or result < 0.0: result = 0.0

proc runFluidHarness(stiffness, smoothingRadius: float; substeps: int;
    dt: float; frames = HARNESS_FRAMES): HarnessRun =
  ## One run of the fluid alone, from the seeded compression.
  let sim = initSimulationState()
  let count = harnessParticleCount()
  let boxSide = HARNESS_BOX_RADII * smoothingRadius
  let substepDt = dt / substeps.float
  let restDensity = sim.sphRestDensity
  let maxPressureDensity =
    restDensity * getTunableFloat("SPH_MAX_DENSITY_RATIO")
  let minDistanceSq = getTunableFloat("MIN_DISTANCE_SQ")
  # app.nim hands the shader 1 - friction, and the fluid's own strength
  # multiplies the whole pass, so the ceiling is measured where it is largest.
  let friction = 1.0 - sim.friction
  let fluidStrength = FLUID_STRENGTH_MAX
  let velocitySmoothing = sim.sphViscosity + SPH_XSPH_EPSILON
  let softCapThreshold = sim.maxVelocity * 0.5
  let selfPoly6 = poly6Weight2d(0.0, smoothingRadius)
  let selfSpikyGradient = spikyGradientMagnitude2d(0.0, smoothingRadius)
  let radiusSq = smoothingRadius * smoothingRadius

  var particles = harnessSeed(count, boxSide)
  var deltaVelocityX = newSeq[float](count)
  var deltaVelocityY = newSeq[float](count)
  var densityAccum = newSeq[float](count)
  var pressureTerm = newSeq[float](count)
  var laggedDensity = newSeq[float](count)
  var speeds: seq[float] = @[]
  result.finite = true

  for frame in 0 ..< frames:
    result.frames = frame + 1
    for _ in 0 ..< substeps:
      # Lagged pressure over density squared, per particle. The shader forms
      # this once for the particle and once per pair for its neighbour; both
      # read the same lagged field, so hoisting it changes no arithmetic and
      # takes the 7th power out of the pair loop.
      for index in 0 ..< count:
        let density = clamp(
          particles[index].sphDensity, restDensity, maxPressureDensity)
        pressureTerm[index] =
          taitPressure(density, restDensity, stiffness, SPH_DEFAULT_GAMMA) /
            (density * density)
        laggedDensity[index] = particles[index].sphDensity
        deltaVelocityX[index] = 0.0
        deltaVelocityY[index] = 0.0
        densityAccum[index] = 1.0  # the normalized self-density

      for i in 0 ..< count:
        for j in i + 1 ..< count:
          # Minimum image, which is what the shader's toroidal cell offsets do.
          var separationX = particles[j].x - particles[i].x
          var separationY = particles[j].y - particles[i].y
          if separationX > boxSide * 0.5: separationX -= boxSide
          elif separationX < -boxSide * 0.5: separationX += boxSide
          if separationY > boxSide * 0.5: separationY -= boxSide
          elif separationY < -boxSide * 0.5: separationY += boxSide
          let distanceSq = separationX * separationX + separationY * separationY
          if distanceSq <= 0.0 or distanceSq >= radiusSq: continue
          let distance = sqrt(max(distanceSq, minDistanceSq))
          let invDistance = 1.0 / distance
          let directionX = separationX * invDistance
          let directionY = separationY * invDistance
          let densityWeight =
            poly6Weight2d(distance, smoothingRadius) / selfPoly6
          let gradientWeight =
            spikyGradientMagnitude2d(distance, smoothingRadius) /
              selfSpikyGradient
          let pressureAccel = clamp(
            SPH_FORCE_SCALE * (pressureTerm[i] + pressureTerm[j]) *
              gradientWeight,
            -SPH_MAX_PRESSURE_ACCEL, SPH_MAX_PRESSURE_ACCEL)
          let smoothDenominator =
            max(max(laggedDensity[i], laggedDensity[j]), 1.0)
          let smoothCoefficient =
            velocitySmoothing * densityWeight / smoothDenominator
          let pairDeltaX = fluidStrength *
            ((-pressureAccel * directionX) * substepDt +
              smoothCoefficient * (particles[j].vx - particles[i].vx))
          let pairDeltaY = fluidStrength *
            ((-pressureAccel * directionY) * substepDt +
              smoothCoefficient * (particles[j].vy - particles[i].vy))
          deltaVelocityX[i] += pairDeltaX
          deltaVelocityY[i] += pairDeltaY
          # Newton's third law, the half-neighbour pair's other half.
          deltaVelocityX[j] -= pairDeltaX
          deltaVelocityY[j] -= pairDeltaY
          densityAccum[i] += densityWeight
          densityAccum[j] += densityWeight

      var sumOfSquares = 0.0
      for index in 0 ..< count:
        particles[index].sphDensity = densityAccum[index]
        if densityAccum[index] > result.peakDensity:
          result.peakDensity = densityAccum[index]
        var velocityX = (particles[index].vx + deltaVelocityX[index]) * friction
        var velocityY = (particles[index].vy + deltaVelocityY[index]) * friction
        let speed = sqrt(velocityX * velocityX + velocityY * velocityY)
        if speed > softCapThreshold and speed > 0.0:
          let compressed = softCapThreshold + ln(1.0 + (speed - softCapThreshold))
          let scale = min(compressed, sim.maxVelocity) / speed
          velocityX *= scale
          velocityY *= scale
        particles[index].vx = velocityX
        particles[index].vy = velocityY
        particles[index].x = harnessWrap(particles[index].x + velocityX, boxSide)
        particles[index].y = harnessWrap(particles[index].y + velocityY, boxSide)
        sumOfSquares += velocityX * velocityX + velocityY * velocityY
        # NaN fails both comparisons with itself and an infinity fails neither,
        # so both have to be named to catch a diverged velocity.
        if velocityX != velocityX or velocityY != velocityY or
            abs(velocityX) > 1.0e30 or abs(velocityY) > 1.0e30:
          result.finite = false

      let rootMeanSquare = sqrt(sumOfSquares / count.float)
      speeds.add rootMeanSquare
      if rootMeanSquare > result.peakSpeed: result.peakSpeed = rootMeanSquare
      # A diverged run has answered the question and every later frame only
      # propagates the infinities, which is what keeps this affordable.
      if not result.finite: return

  let tailStart = speeds.len - speeds.len div HARNESS_SETTLED_TAIL
  var total = 0.0
  for index in tailStart ..< speeds.len: total += speeds[index]
  result.settledSpeed = total / float(speeds.len - tailStart)

func comesToRest(run: HarnessRun): bool =
  ## The verdict one run returns.
  run.finite and run.settledSpeed <= HARNESS_AT_REST_SPEED

proc harnessDt(timeScale: float): float =
  timeScale * HARNESS_REFERENCE_FRAME_SECONDS

proc measuredBoundary(smoothingRadius: float; substeps: int;
    timeScale: float): float =
  ## Bisect for the largest stiffness whose seeded compression comes to rest.
  ## The bracket is wide enough to hold the boundary anywhere the reachable box
  ## puts it and narrow enough that fourteen halvings resolve it to a fraction
  ## of a percent.
  let dt = harnessDt(timeScale)
  var low = 0.05
  var high = 1.0e5
  for _ in 0 ..< 14:
    let middle = sqrt(low * high)
    if comesToRest(runFluidHarness(middle, smoothingRadius, substeps, dt)):
      low = middle
    else:
      high = middle
  sqrt(low * high)

# The boundary at the points the claims below compare. Measured once at module
# scope because bisecting is the expensive thing this file does and four of the
# five tests read the same numbers.
let
  harnessDefaultRadius = initSimulationState().interactionRadius.float
    ## The shipped interaction radius, at fraction 1.
  harnessDefaultTimeScale = initSimulationState().timeScale
  boundaryReference =
    measuredBoundary(harnessDefaultRadius, 1, harnessDefaultTimeScale)
  boundaryMoreSubsteps = measuredBoundary(
    harnessDefaultRadius, SPH_SUBSTEPS_MAX, harnessDefaultTimeScale)
  boundaryWiderKernel = measuredBoundary(
    INTERACTION_RADIUS_MAX.float, 1, harnessDefaultTimeScale)
  boundarySlowTime = measuredBoundary(harnessDefaultRadius, 1, TIME_SCALE_MIN)
  boundaryFastTime = measuredBoundary(harnessDefaultRadius, 1, TIME_SCALE_MAX)


suite "The Fluid Has A Measured Stability Boundary":
  # The stiffness envelope is a function of the fluid's configuration written
  # down as a constant. These tests measure the function.
  #
  # The fit behind sph_core.SPH_STABILITY_COEFFICIENT: written as the
  # coefficient k * dt / (h * substeps), the boundary measured 0.00312 at the
  # widest kernel the sliders reach (150 px, one substep), 0.00367 at the
  # default 50 px kernel, and 0.0111 at a 5 px one. It falls as the kernel
  # widens, so the smallest of those anchors a law linear in h; 0.0025 sits a
  # fifth below it, leaving margin from 1.25x at the anchor to about 4x at a
  # narrow kernel. The growth in h is sublinear — about 0.86 over the wide
  # end, flattening below a few pixels where the shader's 2 px minimum
  # separation takes over — which is why the linear law anchored at the widest
  # kernel under-promises everywhere else.

  test "the harness separates a fluid that settles from one that never does":
    # Without this the tests below are vacuous: a harness that called every run
    # stable would place the boundary wherever the bracket's top happened to be.
    checkpoint("boundary " & $boundaryReference)
    let dt = harnessDt(harnessDefaultTimeScale)
    let quiet = runFluidHarness(
      boundaryReference * 0.25, harnessDefaultRadius, 1, dt)
    let churning = runFluidHarness(
      boundaryReference * 8.0, harnessDefaultRadius, 1, dt)
    check comesToRest(quiet)
    check not comesToRest(churning)
    # And the difference is not marginal: the unstable run sits orders of
    # magnitude above the threshold, in the regime where the soft velocity cap
    # is what bounds the fluid rather than the pressure balance.
    check churning.settledSpeed > 10.0 * HARNESS_AT_REST_SPEED
    check quiet.settledSpeed < 0.25 * HARNESS_AT_REST_SPEED

  test "substepping buys stiffness, at least in proportion":
    # sph_core's own prose already says this ("Higher stiffness needs a smaller
    # effective timestep; substepping buys that"). This is the arithmetic under
    # it. Bounded above as well as below, because the derived ceiling below is
    # linear in the substep count and would over-promise if the real return
    # were sublinear.
    checkpoint("1 substep " & $boundaryReference &
      ", 3 substeps " & $boundaryMoreSubsteps)
    let substepRatio = SPH_SUBSTEPS_MAX.float
    check boundaryMoreSubsteps >= substepRatio * boundaryReference
    check boundaryMoreSubsteps <= substepRatio * substepRatio * boundaryReference

  test "a wider kernel raises the boundary, and by LESS than in proportion":
    # A deviation from the textbook weakly-compressible prediction, and the one
    # the derived ceiling is built on. That prediction has the boundary growing
    # like (h * substeps / dt) squared, and marked it a hypothesis pending this
    # measurement. Tripling the smoothing radius multiplies the boundary by
    # about 2.5 — sublinear, where the square predicts nine.
    #
    # Read off the shader rather than fitted: the textbook form collects
    # one factor of 1/h from the pressure gradient and one from advancing
    # position by velocity times dt. This integrator has neither. Both kernels
    # are divided by their self-weight (forces-sph.wgsl), which makes
    # the pressure magnitude radius-independent on purpose, and integrate.wgsl
    # advances position by the velocity itself, not by velocity
    # times a timestep. One factor of 1/h survives, through the kernel's spatial
    # derivative, and one factor of dt, through the velocity update.
    #
    # The upper bound is the load-bearing half: the ceiling's linear-in-h law is
    # anchored at the widest kernel the sliders reach, so it sits below the
    # boundary at every narrower one exactly while the growth stays sublinear.
    checkpoint("radius 50 " & $boundaryReference &
      ", radius " & $INTERACTION_RADIUS_MAX & " " & $boundaryWiderKernel)
    let radiusRatio = INTERACTION_RADIUS_MAX.float / harnessDefaultRadius
    check boundaryWiderKernel > boundaryReference
    check boundaryWiderKernel <= radiusRatio * boundaryReference

  test "the boundary is inversely proportional to the timestep":
    # Two further points, at the ends of the time-scale slider rather than at
    # the default it was fitted under. Stiffness times timestep is the same
    # number at all three, which is the one exponent this integrator does share
    # with the Courant form.
    let products = [
      boundaryReference * harnessDt(harnessDefaultTimeScale),
      boundarySlowTime * harnessDt(TIME_SCALE_MIN),
      boundaryFastTime * harnessDt(TIME_SCALE_MAX)]
    checkpoint("stiffness * dt at three time scales: " & $products)
    for product in products:
      check abs(product - products[0]) <= 0.05 * products[0]

  test "the boundary sits inside the stiffness envelope at the shipped default":
    # The envelope the range authority declares (SPH_STIFFNESS_MIN to
    # SPH_STIFFNESS_MAX). At the default
    # fluid — whole interaction radius, one substep, default time scale — the
    # measured boundary lands inside it, which is what makes a derived ceiling
    # worth serving: most of that slider's upper travel is already a place the
    # fluid cannot hold still.
    checkpoint("boundary " & $boundaryReference &
      " against envelope " & $SPH_STIFFNESS_MIN & ".." & $SPH_STIFFNESS_MAX)
    check boundaryReference > SPH_STIFFNESS_MIN
    check boundaryReference < SPH_STIFFNESS_MAX


# The suite above measures where the fluid stops holding still. This one holds
# `stableStiffnessCeiling` under that measurement, so re-running the suite
# re-checks the fit rather than trusting the coefficient's comment.

const CEILING_BOX_RADII = [5.0, 50.0, INTERACTION_RADIUS_MAX.float]
  ## Smoothing radii spanning the reachable box. 5 is a tenth of the default
  ## interaction radius — a narrow kernel that still reaches past the distance
  ## floor MIN_DISTANCE_SQ enforces — and the top is the widest kernel the sliders
  ## offer, which is where the linear law is anchored and therefore tightest.
const CEILING_BOX_TIME_SCALES = [TIME_SCALE_MIN, TIME_SCALE_MAX]

suite "The Derived Stiffness Ceiling Holds Under The Measurement":
  test "the derived ceiling sits below the measured stability boundary across the box":
    # Run the fluid AT its own ceiling at each corner and require it to come to
    # rest. Cheaper than bisecting at every corner and a more direct statement
    # of the claim: the ceiling is a stiffness the fluid holds.
    for smoothingRadius in CEILING_BOX_RADII:
      for substeps in [SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX]:
        for timeScale in CEILING_BOX_TIME_SCALES:
          let dt = harnessDt(timeScale)
          let ceiling = stableStiffnessCeiling(
            smoothingRadius, substeps, dt, SPH_STIFFNESS_MAX)
          let run = runFluidHarness(ceiling, smoothingRadius, substeps, dt)
          checkpoint("radius " & $smoothingRadius & ", substeps " & $substeps &
            ", time scale " & $timeScale & ", ceiling " & $ceiling &
            ", settled " & $run.settledSpeed)
          check comesToRest(run)
    # And the shipped default, which is the configuration a fresh world runs.
    let defaultDt = harnessDt(harnessDefaultTimeScale)
    let defaultSubsteps = initSimulationState().sphSubsteps
    let defaultCeiling = stableStiffnessCeiling(
      harnessDefaultRadius, defaultSubsteps, defaultDt, SPH_STIFFNESS_MAX)
    checkpoint("default ceiling " & $defaultCeiling)
    check comesToRest(runFluidHarness(
      defaultCeiling, harnessDefaultRadius, defaultSubsteps, defaultDt))

  test "the margin over the boundary is bounded, so the ceiling is not free":
    # The other side of the same claim. A ceiling of zero would pass the test
    # above and serve nobody, so this pins how far below the boundary it may
    # sit: eight times the ceiling has to be a stiffness the fluid cannot hold,
    # at the corner where the law is anchored and at the shipped default.
    for (smoothingRadius, substeps, timeScale) in [
        (INTERACTION_RADIUS_MAX.float, SPH_SUBSTEPS_MIN,
          harnessDefaultTimeScale),
        (harnessDefaultRadius, initSimulationState().sphSubsteps,
          harnessDefaultTimeScale)]:
      let dt = harnessDt(timeScale)
      let ceiling = stableStiffnessCeiling(
        smoothingRadius, substeps, dt, SPH_STIFFNESS_MAX)
      let run = runFluidHarness(ceiling * 8.0, smoothingRadius, substeps, dt)
      checkpoint("radius " & $smoothingRadius & ", ceiling " & $ceiling &
        ", settled at eight times " & $run.settledSpeed)
      check not comesToRest(run)

  test "the ceiling never exceeds the stiffness envelope":
    # By construction rather than by luck — the envelope arrives as the
    # function's own argument and bounds its result — so this test guards the
    # construction rather than discovering it. The sweep is what makes "over
    # the whole reachable box" mean something: every combination of the three
    # deriving inputs, at the ends of each of their ranges.
    for smoothingRadius in [SPH_RADIUS_FRACTION_MIN * INTERACTION_RADIUS_MIN.float,
        SPH_RADIUS_FRACTION_MAX * INTERACTION_RADIUS_MAX.float]:
      for substeps in SPH_SUBSTEPS_MIN .. SPH_SUBSTEPS_MAX:
        for timeScale in [TIME_SCALE_MIN, TIME_SCALE_MAX]:
          let ceiling = stableStiffnessCeiling(smoothingRadius, substeps,
            harnessDt(timeScale), SPH_STIFFNESS_MAX)
          checkpoint("radius " & $smoothingRadius & ", substeps " & $substeps &
            ", time scale " & $timeScale)
          check ceiling <= SPH_STIFFNESS_MAX
          check ceiling > 0.0

  test "the ceiling is monotone increasing in radius fraction and in substeps":
    # The two claims the panel makes when it greys part of the slider out: a
    # narrower kernel takes less stiffness, and more substeps buy more of it.
    # Compared strictly below the envelope, since the clamp makes the function
    # flat once it binds — flat is not a counterexample to increasing, but a
    # test that could not tell them apart would pass on a constant.
    let dt = harnessDt(TIME_SCALE_MAX)  # the corner where the clamp never binds
    for substeps in SPH_SUBSTEPS_MIN .. SPH_SUBSTEPS_MAX:
      var previous = 0.0
      for fraction in radiusFractionSweep(8):
        let ceiling = stableStiffnessCeiling(
          fraction * INTERACTION_RADIUS_MAX.float, substeps, dt,
          SPH_STIFFNESS_MAX)
        checkpoint("fraction " & $fraction & ", substeps " & $substeps)
        check ceiling > previous
        previous = ceiling
    for fraction in radiusFractionSweep(4):
      var previous = 0.0
      for substeps in SPH_SUBSTEPS_MIN .. SPH_SUBSTEPS_MAX:
        let ceiling = stableStiffnessCeiling(
          fraction * INTERACTION_RADIUS_MAX.float, substeps, dt,
          SPH_STIFFNESS_MAX)
        checkpoint("fraction " & $fraction & ", substeps " & $substeps)
        check ceiling > previous
        previous = ceiling

suite "XSPH Smoothing Answers To The Frame":
  # The pressure term already multiplies by params.dt, so Time Scale reaches it.
  # The velocity blend did not, which left half of what fluidStrength multiplies
  # deaf to the clock. These hold the blend to the same response, and hold the
  # reference frame itself unmoved so no shipped number shifts.

  test "the correction is unchanged at the reference frame":
    check xsphVelocityCorrection(3.0, 11.0, 0.4, SPH_XSPH_EPSILON,
        frameFactor(FRAME_DT_REFERENCE)) ==
      SPH_XSPH_EPSILON * 0.4 * (11.0 - 3.0)

  test "the correction is proportional to the frame factor":
    let atReference = xsphVelocityCorrection(3.0, 11.0, 0.4, SPH_XSPH_EPSILON, 1.0)
    for factor in [0.0, 0.25, 1.0, 2.5, 10.0]:
      check abs(xsphVelocityCorrection(3.0, 11.0, 0.4, SPH_XSPH_EPSILON, factor) -
        atReference * factor) < 1e-12

  test "a frame split into substeps blends by the same total":
    # The pass runs once per substep, so n substeps of dt/n must deliver what
    # one step of dt delivers, exactly as the pressure term already does.
    for substeps in [1, 2, 3]:
      let dt = 2.0 * FRAME_DT_REFERENCE
      let perSubstep = xsphVelocityCorrection(3.0, 11.0, 0.4, SPH_XSPH_EPSILON,
        frameFactor(dt / substeps.float))
      check abs(perSubstep * substeps.float -
        xsphVelocityCorrection(3.0, 11.0, 0.4, SPH_XSPH_EPSILON,
          frameFactor(dt))) < 1e-12

  test "one pair still cannot overshoot the velocity gap at the reference frame":
    # The bound that keeps the smoothing from overshooting. It is stated at the
    # reference frame because that is where it was measured; above it the blend
    # strengthens with the clock, the way the pressure term already does.
    for velocitySelf in [-10.0, 0.0, 3.5, 20.0]:
      for velocityNeighbor in [-20.0, 0.0, 7.0, 15.0]:
        for neighborWeight in [-0.5, 0.0, 0.3, 1.0, 2.0]:
          for epsilon in [0.0, SPH_XSPH_EPSILON, 1.0]:
            let correction = xsphVelocityCorrection(velocitySelf,
              velocityNeighbor, neighborWeight, epsilon,
              frameFactor(FRAME_DT_REFERENCE))
            check abs(correction) <=
              epsilon * abs(velocityNeighbor - velocitySelf) + EPSILON
