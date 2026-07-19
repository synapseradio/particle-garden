# ==============================================================================
# PARTICLE GARDEN - SPH CORE (Pure 2D Smoothed-Particle-Hydrodynamics Math)
# ==============================================================================
#
# Pure functions for the SPH fluid mode: 2D smoothing kernels, the Tait
# equation of state, and the XSPH velocity-smoothing term. No side effects, no
# FFI — compiles on both the native (nimble test) and JS backends, and is the
# analytic mirror the forces-sph.wgsl compute shader is written against
# (physics_core.nim plays the same role for the particle-life force math).
#
# Every function takes the smoothing radius h as a parameter. h is the runtime
# interactionRadius, so nothing is precomputed against a fixed h; the kernel
# normalization is recomputed from h on each call.
#
# Used by:
#   - tests/test_sph_core.nim (native analytic tests)
#   - src/shader_config.nim (single source for the SPH tunable defaults)
#
# ==============================================================================

import std/math

# ==============================================================================
# TUNING CONSTANTS
# ==============================================================================

const
  SPH_DEFAULT_GAMMA* = 7.0
    ## Tait exponent. 7 is the classic water value (Monaghan): stiff enough
    ## that density stays near rest without a vanishingly small timestep.
  SPH_XSPH_EPSILON* = 0.5
    ## XSPH blend fraction in [0, 1]. 0.5 is a strong-but-stable smoothing
    ## weight; the correction can never move a velocity by more than this
    ## fraction of the neighbor velocity gap (see xsphVelocityCorrection).
  SPH_PARTICLE_CEILING* = 32000
    ## Upper particle count for the SPH mode. SPH's neighbor pressure loop is
    ## heavier than the particle-life force loop, so the mode caps well below
    ## the global MAX_PARTICLES to hold interactive frame rates.
  SPH_MAX_SUBSTEPS* = 3
    ## Maximum physics substeps the executor may run per rendered frame. Higher
    ## stiffness needs a smaller effective timestep; substepping buys that
    ## without changing the render cadence.

# ==============================================================================
# SMOOTHING KERNELS (2D)
# ==============================================================================

func poly6Weight2d*(distance, smoothingRadius: float): float =
  ## The 2D-normalized poly6 kernel W(r, h) = C * (h^2 - r^2)^3, and 0 for
  ## r >= h. Used as the density-estimator weight.
  ##
  ## Derivation of the 2D normalization constant C. We require the kernel to
  ## integrate to 1 over its support disc:
  ##     ∫₀ʰ C (h² - r²)³ · 2πr dr = 1
  ## Substitute u = h² - r², du = -2r dr (so r dr = -du/2). The bounds map
  ## r: 0→h  to  u: h²→0, giving
  ##     2πC · (1/2) ∫₀^{h²} u³ du = 2πC · (1/2)(h⁸/4) = πC h⁸/4.
  ## Setting that equal to 1 yields C = 4 / (π h⁸). tests/test_sph_core.nim
  ## verifies this by numerically integrating the kernel over the disc.
  if distance >= smoothingRadius:
    return 0.0
  let normalization = 4.0 / (PI * pow(smoothingRadius, 8.0))
  let radiusSq = smoothingRadius * smoothingRadius
  let diff = radiusSq - distance * distance
  normalization * diff * diff * diff

func spikyGradientMagnitude2d*(distance, smoothingRadius: float): float =
  ## Magnitude of the 2D spiky kernel's radial gradient, and 0 for r >= h. The
  ## caller multiplies this by the (repulsive) unit direction; this function
  ## returns only the non-negative magnitude.
  ##
  ## The spiky kernel is W(r, h) = D (h - r)³ for r < h. Its 2D normalization
  ## follows the same partition-of-unity requirement:
  ##     ∫₀ʰ D (h - r)³ · 2πr dr = 1.
  ## With s = h - r the inner integral is ∫₀ʰ (h s³ - s⁴) ds = h⁵/20, so
  ## 2πD · h⁵/20 = 1 gives D = 10 / (π h⁵). The radial derivative is
  ## dW/dr = -3D (h - r)², whose magnitude is
  ##     |dW/dr| = 30 / (π h⁵) · (h - r)².
  ## This is strictly positive on (0, h), strictly decreasing in r, and 0 at h.
  if distance >= smoothingRadius:
    return 0.0
  let normalization = 30.0 / (PI * pow(smoothingRadius, 5.0))
  let diff = smoothingRadius - distance
  normalization * diff * diff

# ==============================================================================
# TAIT EQUATION OF STATE
# ==============================================================================

func taitPressure*(density, restDensity, stiffness, gamma: float): float =
  ## Tait equation of state: P = stiffness * ((density/restDensity)^gamma - 1).
  ## P(restDensity) == 0 for any stiffness and gamma, so a fluid at rest density
  ## feels no pressure force; P rises with compression and goes negative
  ## (cohesive) below rest density. Pressure scales linearly with stiffness at
  ## a fixed density ratio, which is what makes stiffness the pressure gain.
  stiffness * (pow(density / restDensity, gamma) - 1.0)

# ==============================================================================
# XSPH VELOCITY SMOOTHING
# ==============================================================================

func xsphVelocityCorrection*(velocitySelf, velocityNeighbor, neighborWeight,
    epsilon: float): float =
  ## One neighbor's contribution to the XSPH velocity-smoothing term, evaluated
  ## per velocity axis. The full XSPH correction is
  ##     ε Σⱼ (mⱼ/ρⱼ) (vⱼ - vᵢ) Wᵢⱼ,
  ## and this returns one summand along one axis: ε · w · (vⱼ - vᵢ), where w is
  ## the normalized neighbor weight (mⱼ/ρⱼ)·Wᵢⱼ.
  ##
  ## w is clamped to [0, 1] so that a single neighbor pair can never move the
  ## velocity by more than ε times the velocity gap |vⱼ - vᵢ| — the bound that
  ## keeps the smoothing from overshooting. The caller sums the per-neighbor
  ## corrections to form the full term.
  let weight = max(0.0, min(1.0, neighborWeight))
  epsilon * weight * (velocityNeighbor - velocitySelf)
