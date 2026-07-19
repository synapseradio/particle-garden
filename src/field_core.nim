# ==============================================================================
# PARTICLE GARDEN - FIELD CORE (Pure Reaction-Diffusion Math)
# ==============================================================================
#
# Pure functions for the Gray-Scott reaction-diffusion mode: the 5-point
# discrete Laplacian and one Gray-Scott step for a single grid cell. No side
# effects, no FFI — compiles on both the native (nimble test) and JS backends,
# and is the analytic mirror the rd-step.wgsl compute shader is written
# against (sph_core.nim and physics_core.nim play the same role for the SPH
# and particle-life force math).
#
# The field itself (the two concentration channels, activator and inhibitor)
# lives only on the GPU as a storage texture — there is no CPU-side grid here.
# These functions take one cell's neighborhood as five scalars and return the
# next step's two scalars, exactly the shape the shader's per-invocation body
# needs.
#
# Used by:
#   - tests/test_field_core.nim (native analytic tests)
#   - src/sim_registry.nim (RD_STEPS_PER_FRAME drives the frame's step count)
#
# ==============================================================================

# ==============================================================================
# FIELD DIMENSIONS
# ==============================================================================

const
  FIELD_W* = 512
    ## Storage-texture width for the reaction-diffusion field. Fixed and
    ## independent of the world size or particle count: the field is its own
    ## grid, not derived from the spatial hash the particle modes use.
  FIELD_H* = 512
    ## Storage-texture height. Square with FIELD_W by convention; nothing
    ## here requires it to stay square.

# ==============================================================================
# TUNING CONSTANTS
# ==============================================================================

const
  RD_DIFFUSION_A* = 1.0
    ## Activator diffusion rate Da. Classic Gray-Scott convention: the
    ## activator diffuses at the reference rate 1.0.
  RD_DIFFUSION_B* = 0.5
    ## Inhibitor diffusion rate Db. Half the activator's rate — the ratio
    ## Db/Da that produces Turing-pattern instability rather than a field
    ## that simply smooths itself flat.
  RD_DELTA_T* = 1.0
    ## Per-substep timestep. Gray-Scott's explicit-Euler update is stable at
    ## dt=1 for these diffusion rates and the Pearson feed/kill range below.
  RD_STEPS_PER_FRAME* = 8
    ## Reaction-diffusion substeps run per rendered frame. The pattern
    ## evolves slowly relative to a video frame, so multiple steps per frame
    ## buys visible motion without lowering dt (and hence stability).
  RD_PARTICLE_CEILING* = 32000
    ## Upper particle count for the reaction-diffusion mode. Particles are
    ## sources that deposit into the field and are pushed by its gradient;
    ## the field grid (not the particle count) is this mode's cost driver,
    ## so the ceiling matches SPH's rather than particle-life's larger one.
  RD_DEFAULT_FEED* = 0.030
    ## Feed rate F. Paired with RD_DEFAULT_KILL below, this sits in Pearson's
    ## self-replicating-spots regime (see the constants' test suite for the
    ## citation and the (F, k) range it names).
  RD_DEFAULT_KILL* = 0.062
    ## Kill rate k. See RD_DEFAULT_FEED.

# ==============================================================================
# 5-POINT LAPLACIAN STENCIL
# ==============================================================================

func laplacian5*(center, north, south, east, west: float): float =
  ## The discrete 2D Laplacian at one grid cell via the standard 5-point
  ## stencil: the sum of the four axis-neighbors minus 4 times the center.
  ## Zero on a constant field (no curvature to diffuse), linear in its five
  ## inputs, and reduces to -4*center when all neighbors are 0 (an isolated
  ## peak's own decay) or to a single neighbor's value when the other three
  ## neighbors and the center are 0.
  north + south + east + west - 4.0 * center

# ==============================================================================
# GRAY-SCOTT REACTION-DIFFUSION STEP
# ==============================================================================

func grayScottStep*(activator, inhibitor, laplacianA, laplacianB,
    diffusionA, diffusionB, feed, kill, deltaT: float):
    tuple[activator, inhibitor: float] =
  ## One explicit-Euler Gray-Scott step for a single cell, given its current
  ## activator/inhibitor concentrations and their precomputed Laplacians (see
  ## laplacian5). The classic two-channel reaction-diffusion system:
  ##   reaction = activator * inhibitor^2
  ##   activator' = activator + dt*(Da*lapA - reaction + feed*(1-activator))
  ##   inhibitor' = inhibitor + dt*(Db*lapB + reaction - (feed+kill)*inhibitor)
  ## The feed term replenishes the activator toward 1; the kill term (plus
  ## feed's equal drain) depletes the inhibitor. At the trivial steady state
  ## (activator=1, inhibitor=0) with no diffusion, both terms vanish for any
  ## feed/kill — the fixed point the tests pin analytically.
  let reaction = activator * inhibitor * inhibitor
  let nextActivator = activator + deltaT * (
    diffusionA * laplacianA - reaction + feed * (1.0 - activator))
  let nextInhibitor = inhibitor + deltaT * (
    diffusionB * laplacianB + reaction - (feed + kill) * inhibitor)
  (activator: nextActivator, inhibitor: nextInhibitor)
