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
# Run with: nimble test
#
# ==============================================================================

import std/[unittest, math]
import ../src/sph_core

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
    # not repel — the pre-fix restDensity of 1.0 made isolation the
    # zero-pressure state, so every contact was repulsive and the fluid
    # behaved as an expanding gas.
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
  test "gamma, epsilon, ceiling, and substep bounds hold their documented values":
    check SPH_DEFAULT_GAMMA == 7.0
    check SPH_XSPH_EPSILON == 0.5
    check SPH_PARTICLE_CEILING == 32000
    check SPH_MAX_SUBSTEPS == 3

  test "the XSPH epsilon is a well-formed blend fraction in [0, 1]":
    check SPH_XSPH_EPSILON >= 0.0
    check SPH_XSPH_EPSILON <= 1.0
