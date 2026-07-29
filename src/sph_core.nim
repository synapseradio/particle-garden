# ==============================================================================
# PARTICLE GARDEN - SPH CORE (Pure 2D Smoothed-Particle-Hydrodynamics Math)
# ==============================================================================
#
# Pure functions for the SPH fluid: 2D smoothing kernels, the Tait
# equation of state, and the XSPH velocity-smoothing term. No side effects, no
# FFI — compiles on both the native (just test) and JS backends, and is the
# analytic mirror the forces-sph.wgsl compute shader is written against
# (physics_core.nim plays the same role for the species force math).
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
  SPH_DENSITY_HEADROOM* = 2.0
    ## How much of the accumulator's span stays free above the largest density
    ## the world can produce. The accumulation is atomic across threads, so no
    ## contribution sees the running total and none can check it before adding;
    ## headroom is what covers that, and it is the only thing that can.
  SPH_DEFAULT_GAMMA* = 7.0
    ## Tait exponent. 7 is the classic water value (Monaghan): stiff enough
    ## that density stays near rest without a vanishingly small timestep.
  SPH_XSPH_EPSILON* = 0.5
    ## XSPH blend fraction in [0, 1]. 0.5 is a strong-but-stable smoothing
    ## weight; the correction can never move a velocity by more than this
    ## fraction of the neighbor velocity gap (see xsphVelocityCorrection).
  SPH_MAX_SUBSTEPS* = 3
    ## Maximum physics substeps the executor may run per rendered frame. Higher
    ## stiffness needs a smaller effective timestep; substepping buys that
    ## without changing the render cadence.
  SPH_FORCE_SCALE* = 3.0
    ## Pressure acceleration gain, in px per frame squared. The primary
    ## aesthetic knob on how hard the fluid pushes back.
    ##
    ## It lives here rather than in the shader because the stability ceiling
    ## below is FITTED against it: the boundary scales with the product of this
    ## gain and the stiffness, so a change here moves the boundary by the same
    ## factor and invalidates the fitted coefficient. shader_config feeds it to
    ## forces-sph.wgsl as a placeholder, the way it feeds SPH_XSPH_EPSILON, and
    ## tests/test_shader_config.nim relates the two.
  SPH_MAX_PRESSURE_ACCEL* = 5000.0
    ## Per-pair clamp on the pressure acceleration, guarding the fixed-point
    ## i32 velocity delta from overflow. Reached only far above the stiffness
    ## envelope — at the shipped pressure-density ceiling one pair produces
    ## about 21 times the stiffness, so a stiffness near 236 is where this first
    ## binds — which is why it shapes the measured stability boundary only in
    ## runs deliberately driven past the ceiling.

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

func flooredTaitPressure*(density, restDensity, stiffness, gamma: float):
    float =
  ## The purely-repulsive Tait EOS the shader actually evaluates: density is
  ## floored at restDensity before taitPressure, so pressure is 0 at and below
  ## rest and strictly positive above it. Mirrors forces-sph.wgsl, which
  ## applies max(laggedDensity, restDensity) before sphTaitPressure for both
  ## the particle and its neighbor. The floor is why restDensity must sit
  ## above the isolated particle's self-density (the density accumulator
  ## starts at the normalized self-weight 1.0): if rest equals isolation,
  ## every contact reads as compression and the fluid disperses as a gas.
  taitPressure(max(density, restDensity), restDensity, stiffness, gamma)

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

# ==============================================================================
# THE STABLE STIFFNESS CEILING
# ==============================================================================

const
  SPH_STABILITY_COEFFICIENT* = 0.0025
    ## The fitted stability coefficient: the largest stiffness this integrator
    ## holds still at is `SPH_STABILITY_COEFFICIENT * h * substeps / dt`, with h
    ## the smoothing radius in world pixels and dt the substepped frame's
    ## timestep in seconds. Linear in h rather than the Courant square: this
    ## integrator normalizes both kernels by their self-weight and advances
    ## position by the velocity itself, so one factor each of 1/h and dt
    ## survives. Measured, fitted and re-checked by tests/test_sph_core.nim's
    ## stability harness, which also records the fit's anchor numbers.
  SPH_CEILING_REFERENCE_FRAME_SECONDS* = 1.0 / 60.0
    ## The frame the served ceiling reads its timestep against. app.nim forms
    ## the real timestep from the frame the browser actually delivered, capped
    ## at 50 ms, so a ceiling built from it would move every frame and shrink
    ## threefold during a hitch. A hitch is transient and the friction recovers
    ## from it; a slider whose dormant region breathes is not recoverable. The
    ## measurement was taken against this frame, so it is a condition of the
    ## coefficient above rather than a separate choice.

func stableStiffnessCeiling*(smoothingRadius: float; substeps: int;
    dt: float; envelopeMax: float): float =
  ## The largest stiffness the fluid holds still at, given how far its kernel
  ## reaches, how many substeps it takes, and how long a substepped frame is.
  ## Never above `envelopeMax`, which is the absolute bound the range authority
  ## declares and the only thing this ceiling is clamped against.
  ##
  ## The envelope arrives as an argument rather than being read here because
  ## config_ranges imports this module for SPH_MAX_SUBSTEPS; the range authority
  ## therefore hands its own constant to the function it bounds.
  ##
  ## THE SMOOTHING RADIUS IN PIXELS, not the fraction. The fraction alone cannot
  ## answer: the boundary follows the radius the kernel actually spans, so the
  ## same fraction against a 10 px interaction radius and a 150 px one describe
  ## fluids fifteen times apart in stability. The caller multiplies the two the
  ## way forces-sph.wgsl does.
  ##
  ## The stored stiffness this bounds is never rewritten — it stays absolute
  ## pressure gain, and the bound applies where the value takes effect.
  if dt <= 0.0 or substeps <= 0 or smoothingRadius <= 0.0:
    return 0.0
  min(envelopeMax,
    SPH_STABILITY_COEFFICIENT * smoothingRadius * substeps.float / dt)

# ==============================================================================
# FIXED-POINT DENSITY ENCODING
# ==============================================================================

func fixedPointCeiling*(fixedPointScale: float): float =
  ## Largest value an i32 atomic accumulator represents at this scale. The
  ## delta buffers encode floats as `i32(value * scale)`, so the signed 32-bit
  ## range divided by the scale is the whole representable span.
  2147483647.0 / fixedPointScale

func sphDensityFixedPointScale*(maxParticles: int): float =
  ## Fixed-point scale for the kernel-density accumulator, derived from the
  ## particle budget it has to hold.
  ##
  ## WHAT THE WORST CASE IS. forces-sph.wgsl divides each neighbour's poly6
  ## weight by the self-weight, so a neighbour contributes at most 1.0 and the
  ## accumulated density counts neighbours. Nothing bounds how many particles
  ## share a smoothing radius, so the largest density the world can reach is
  ## exactly `maxParticles` — every particle the slider allows, in one place.
  ##
  ## WHY THIS IS NOT THE SHARED SCALE. Velocity deltas want fine resolution near
  ## zero and stay small, so they take FIXED_POINT_SCALE at 65536. Density is a
  ## large positive count and wants range instead. Sharing one scale forces the
  ## count to fit in 32768, which the particle ceiling passes by 3.9x, and an
  ## i32 past its maximum wraps NEGATIVE — a density the equation of state reads
  ## as maximal expansion and answers with force in the wrong direction.
  ## Clamping instead would answer that by making the ceiling unreachable, which
  ## is not what a maximum means.
  ##
  ## Powers of two, because a float scaled by one is exact in binary: doubling
  ## the budget halves the scale and re-encodes every density identically, so
  ## raising MAX_PARTICLES stays a one-constant change.
  const i32Max = 2147483647.0
  let needed = float(maxParticles) * SPH_DENSITY_HEADROOM
  result = 1.0
  # Budgets past the whole signed range need a scale below 1. Held separately
  # from the doubling below so both directions terminate.
  while result * needed > i32Max:
    result *= 0.5
  while result * 2.0 * needed <= i32Max:
    result *= 2.0
