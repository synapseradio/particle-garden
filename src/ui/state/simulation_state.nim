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

func initSimulationState*(): SimulationState =
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

func initSimulationState*(
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

func withParticleCount*(state: SimulationState; count: int): SimulationState =
  result = state
  result.particleCount = count

func withSpeciesCount*(state: SimulationState; count: int): SimulationState =
  result = state
  result.speciesCount = count

func withInteractionRadius*(state: SimulationState; radius: int): SimulationState =
  result = state
  result.interactionRadius = radius

func withForceStrength*(state: SimulationState; strength: float): SimulationState =
  result = state
  result.forceStrength = strength

func withFriction*(state: SimulationState; friction: float): SimulationState =
  result = state
  result.friction = friction

func withTimeScale*(state: SimulationState; scale: float): SimulationState =
  result = state
  result.timeScale = scale

func withMaxVelocity*(state: SimulationState; velocity: float): SimulationState =
  result = state
  result.maxVelocity = velocity
