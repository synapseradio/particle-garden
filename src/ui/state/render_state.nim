# ==============================================================================
# RENDER STATE - Visual rendering parameters
# ==============================================================================
#
# Pure state type for render settings (trails, glow, particle size, etc.)
# Can be wrapped in Observable[RenderState] for reactive updates.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: STATE TYPE
# ==============================================================================

type
  RenderState* = object
    ## Visual rendering parameters.
    ## Pure immutable data - updates return new state.
    particleSize*: int
    trails*: bool
    trailAlpha*: float
    glowIntensity*: float
    velocityGlowScale*: float

# ==============================================================================
# SECTION 2: CONSTRUCTORS
# ==============================================================================

func initRenderState*(): RenderState =
  ## Create default render state.
  RenderState(
    particleSize: 3,
    trails: false,
    trailAlpha: 0.96,
    glowIntensity: 0.8,
    velocityGlowScale: 1.0
  )

func initRenderState*(
  particleSize: int;
  trails: bool;
  trailAlpha, glowIntensity, velocityGlowScale: float
): RenderState =
  ## Create render state with specific values.
  RenderState(
    particleSize: particleSize,
    trails: trails,
    trailAlpha: trailAlpha,
    glowIntensity: glowIntensity,
    velocityGlowScale: velocityGlowScale
  )

# ==============================================================================
# SECTION 3: IMMUTABLE UPDATES
# ==============================================================================

func withParticleSize*(state: RenderState; size: int): RenderState =
  result = state
  result.particleSize = size

func withTrails*(state: RenderState; enabled: bool): RenderState =
  result = state
  result.trails = enabled

func withTrailAlpha*(state: RenderState; alpha: float): RenderState =
  result = state
  result.trailAlpha = alpha

func withGlowIntensity*(state: RenderState; intensity: float): RenderState =
  result = state
  result.glowIntensity = intensity

func withVelocityGlowScale*(state: RenderState; scale: float): RenderState =
  result = state
  result.velocityGlowScale = scale

# ==============================================================================
# SECTION 4: QUERIES
# ==============================================================================

func hasTrails*(state: RenderState): bool =
  state.trails

func hasGlow*(state: RenderState): bool =
  state.glowIntensity > 0.0
