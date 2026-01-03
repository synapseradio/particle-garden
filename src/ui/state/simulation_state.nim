# ==============================================================================
# SIMULATION STATE - Physics simulation parameters
# ==============================================================================
#
# Pure state type for simulation parameters (particle count, forces, etc.)
# Can be wrapped in Observable[SimulationState] for reactive updates.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: STATE TYPE
# ==============================================================================

type
  SimulationState* = object
    ## Physics simulation parameters.
    ## Pure immutable data - updates return new state.
    particleCount*: int
    speciesCount*: int
    interactionRadius*: int
    forceStrength*: float
    friction*: float
    timeScale*: float
    maxVelocity*: float

# ==============================================================================
# SECTION 2: CONSTRUCTORS
# ==============================================================================

proc initSimulationState*(): SimulationState =
  ## Create default simulation state.
  SimulationState(
    particleCount: 16000,
    speciesCount: 4,
    interactionRadius: 50,
    forceStrength: 1.0,
    friction: 0.05,
    timeScale: 0.5,
    maxVelocity: 50.0
  )

proc initSimulationState*(
  particleCount, speciesCount, interactionRadius: int;
  forceStrength, friction, timeScale, maxVelocity: float
): SimulationState =
  ## Create simulation state with specific values.
  SimulationState(
    particleCount: particleCount,
    speciesCount: speciesCount,
    interactionRadius: interactionRadius,
    forceStrength: forceStrength,
    friction: friction,
    timeScale: timeScale,
    maxVelocity: maxVelocity
  )

# ==============================================================================
# SECTION 3: IMMUTABLE UPDATES
# ==============================================================================

proc withParticleCount*(state: SimulationState; count: int): SimulationState =
  result = state
  result.particleCount = count

proc withSpeciesCount*(state: SimulationState; count: int): SimulationState =
  result = state
  result.speciesCount = count

proc withInteractionRadius*(state: SimulationState; radius: int): SimulationState =
  result = state
  result.interactionRadius = radius

proc withForceStrength*(state: SimulationState; strength: float): SimulationState =
  result = state
  result.forceStrength = strength

proc withFriction*(state: SimulationState; friction: float): SimulationState =
  result = state
  result.friction = friction

proc withTimeScale*(state: SimulationState; scale: float): SimulationState =
  result = state
  result.timeScale = scale

proc withMaxVelocity*(state: SimulationState; velocity: float): SimulationState =
  result = state
  result.maxVelocity = velocity
