# ==============================================================================
# PARTICLE GARDEN - SPH CORE TESTS
# ==============================================================================
#
# Analytic tests for src/sph_core.nim: the pure 2D SPH kernel math, Tait
# equation of state, and XSPH velocity smoothing that the forces-sph.wgsl
# compute shader mirrors (roadmap S7). Every function takes the smoothing
# radius h as a runtime parameter — nothing is precomputed against a fixed h —
# so these tests exercise the identities across two different radii.
#
# The poly6 normalization is verified by numerical integration rather than by
# pinning the closed-form constant: if the derived constant were wrong, the
# integral over the support disc would not equal 1.
#
# Run with: just test
#
# ==============================================================================

import std/[unittest, math]
import ../src/sph_core

from ../src/memory_layout import MAX_PARTICLES
# The smoothing radius is the interaction radius times a fraction, so the
# reachable effective radii are the product of two ranges the slider contract
# owns. Read from there rather than restated here: raising either range
# re-scopes the sweep below without a second edit.
from ../src/config_ranges import SPH_RADIUS_FRACTION_MIN,
  SPH_RADIUS_FRACTION_MAX, INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX

const SPH_CORE_TESTS_LOADED* = true

# EPSILON for the analytic identities. The numerical integral uses a coarser
# tolerance (1e-3) since it is a Riemann approximation, not an exact identity.
const EPSILON = 1e-9
const INTEGRAL_TOLERANCE = 1e-3

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
  ## reach, and the maximum is today's fluid.
  result = @[]
  for stepIndex in 0 .. steps:
    result.add SPH_RADIUS_FRACTION_MIN +
      (SPH_RADIUS_FRACTION_MAX - SPH_RADIUS_FRACTION_MIN) *
        stepIndex.float / steps.float

func normalizedDensityWeight(distance, smoothingRadius: float): float =
  ## The density weight forces-sph.wgsl:248 forms: the poly6 weight divided by
  ## the self-weight, which is what makes an isolated particle read 1.0 and the
  ## accumulated density count neighbours.
  poly6Weight2d(distance, smoothingRadius) / poly6Weight2d(0.0, smoothingRadius)

func normalizedGradientWeight(distance, smoothingRadius: float): float =
  ## The gradient weight forces-sph.wgsl:249 forms, by the same division. The
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
    # Monotonically decreasing from the center out to the support edge.
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


# ==============================================================================
# THE SMOOTHING RADIUS IS A FRACTION OF THE INTERACTION RADIUS
# ==============================================================================
#
# forces-sph.wgsl multiplies the interaction radius by params.sphRadiusFraction
# to get the smoothing radius, so the reachable effective radii run from
# INTERACTION_RADIUS_MIN * SPH_RADIUS_FRACTION_MIN up to INTERACTION_RADIUS_MAX.
# Nothing in sph_core changes for that: every function already takes h as a
# parameter and recomputes its normalization from it. These tests pin the
# properties the shader change relies on, over the whole box the two ranges
# open.

suite "The Smoothing Radius Is A Fraction Of The Interaction Radius":
  test "fraction one reproduces today's kernels":
    # CONTRACT: the top of the fraction range is exactly 1, so the fluid a world
    # ran before the fraction existed stays expressible — and expressible as the
    # identical arithmetic, not an approximation of it. Both kernels and both
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
            normalizedDensityWeight(distance, scaled), SPH_XSPH_EPSILON) ==
          xsphVelocityCorrection(3.0, 11.0,
            normalizedDensityWeight(distance, interactionRadius),
            SPH_XSPH_EPSILON)

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
              velocitySelf, velocityNeighbor, neighborWeight, epsilon)
            let velocityGap = abs(velocityNeighbor - velocitySelf)
            check abs(correction) <= epsilon * velocityGap + EPSILON

  test "the correction points toward the neighbor velocity":
    # A slower neighbor drags the velocity down; a faster one pulls it up.
    check xsphVelocityCorrection(5.0, 10.0, 0.5, SPH_XSPH_EPSILON) > 0.0
    check xsphVelocityCorrection(5.0, 0.0, 0.5, SPH_XSPH_EPSILON) < 0.0

  test "a zero weight or zero epsilon yields no correction":
    check xsphVelocityCorrection(5.0, 10.0, 0.0, SPH_XSPH_EPSILON) == 0.0
    check xsphVelocityCorrection(5.0, 10.0, 0.5, 0.0) == 0.0


suite "SPH Tuning Constants Are In Physical Range":
  test "gamma, epsilon, and substep bounds hold their documented values":
    check SPH_DEFAULT_GAMMA == 7.0
    check SPH_XSPH_EPSILON == 0.5
    check SPH_MAX_SUBSTEPS == 3

  test "the XSPH epsilon is a well-formed blend fraction in [0, 1]":
    check SPH_XSPH_EPSILON >= 0.0
    check SPH_XSPH_EPSILON <= 1.0


# ==============================================================================
# THE DENSITY A FIXED-POINT BUFFER CAN HOLD
# ==============================================================================
#
# WHAT SETS THE WORST CASE. forces-sph.wgsl divides each neighbour's poly6
# weight by the self-weight, so one neighbour contributes at most 1.0 and the
# accumulated density counts neighbours. Nothing bounds how many particles share
# a smoothing radius, so the largest density the world can produce is exactly
# MAX_PARTICLES: every particle the slider allows, gathered into one place.
#
# THE ACCUMULATOR MUST HOLD THAT, not clamp it. A shared FIXED_POINT_SCALE of
# 65536 spans 32768, which MAX_PARTICLES passes by 3.9x, and an i32 past its
# maximum wraps NEGATIVE — a density the equation of state reads as maximal
# expansion and answers with force in the wrong direction. Clamping would answer
# the overflow by making the particle ceiling unreachable, so the density
# accumulator takes its own coarser scale instead, derived from the budget.

suite "The Full Particle Budget Encodes Without Saturating":
  const I32_MAX = 2147483647.0
  let scale = sphDensityFixedPointScale(MAX_PARTICLES)

  test "the whole particle budget in one smoothing radius encodes as itself":
    # THE CONTRACT: 128000 particles is a reachable setting, so the density it
    # produces has to survive the round trip rather than saturate on the way in.
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
