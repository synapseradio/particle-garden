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

proc initRenderState*(): RenderState =
  ## Create default render state.
  RenderState(
    particleSize: 3,
    trails: false,
    trailAlpha: 0.96,
    glowIntensity: 0.8,
    velocityGlowScale: 1.0
  )

proc initRenderState*(
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

proc withParticleSize*(state: RenderState; size: int): RenderState =
  result = state
  result.particleSize = size

proc withTrails*(state: RenderState; enabled: bool): RenderState =
  result = state
  result.trails = enabled

proc withTrailAlpha*(state: RenderState; alpha: float): RenderState =
  result = state
  result.trailAlpha = alpha

proc withGlowIntensity*(state: RenderState; intensity: float): RenderState =
  result = state
  result.glowIntensity = intensity

proc withVelocityGlowScale*(state: RenderState; scale: float): RenderState =
  result = state
  result.velocityGlowScale = scale

# ==============================================================================
# SECTION 4: QUERIES
# ==============================================================================

proc hasTrails*(state: RenderState): bool =
  state.trails

proc hasGlow*(state: RenderState): bool =
  state.glowIntensity > 0.0
