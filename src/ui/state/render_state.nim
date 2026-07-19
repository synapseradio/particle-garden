# ==============================================================================
# RENDER STATE - Visual rendering parameters
# ==============================================================================
#
# The typed record for every visual-side tunable: the eight ConfigObject
# fields the render/glow pipeline reads. ui.nim holds this in an Observable
# and mirrors each change synchronously into the flat CONFIG the hot paths
# consume; config.nim's createConfig copies these defaults, so the values
# below are the single authoritative defaults.
#
# Pure module: compiles on both the native (nimble test) and JS backends.
#
# ==============================================================================

type
  RenderState* = object
    ## Visual rendering parameters.
    ## Pure immutable data - updates go through a copied var and re-set.
    particleSize*: int
    trails*: bool
    trailLength*: float       ## 0-100 particle diameters (0 = no trails)
    glowIntensity*: float
    velocityGlowScale*: float
    glowRadiusScale*: float   ## Glow halo radius = (particleSize+1) * this
    glowFalloff*: float       ## Gaussian falloff exponent (higher = tighter)
    glowWarmth*: float        ## Density-driven warm shift, [0,1]

func initRenderState*(): RenderState =
  ## The authoritative render defaults (copied into CONFIG by createConfig).
  ## (particleSize + 1) * glowRadiusScale must stay 12.0 to reproduce the
  ## radius glow.wgsl hard-coded before the knobs existed (pinned by
  ## tests/test_sim_config.nim).
  RenderState(
    particleSize: 3,
    trails: false,
    trailLength: 0.0,
    glowIntensity: 0.8,      # Subtle glow
    velocityGlowScale: 1.0,  # Full velocity-to-glow influence
    glowRadiusScale: 3.0,
    glowFalloff: 6.0,
    glowWarmth: 0.4
  )

func hasTrails*(state: RenderState): bool =
  state.trails

func hasGlow*(state: RenderState): bool =
  state.glowIntensity > 0.0
