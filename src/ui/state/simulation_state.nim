# ==============================================================================
# SIMULATION STATE - Physics simulation parameters
# ==============================================================================
#
# The typed record for every physics-side tunable: the thirteen ConfigObject
# fields the compute pipeline and force model read. ui.nim holds this in an
# Observable and mirrors each change synchronously into the flat CONFIG the
# hot paths consume; config.nim's createConfig copies these defaults, so the
# values below are the single authoritative defaults.
#
# Pure module: compiles on both the native (nimble test) and JS backends.
#
# ==============================================================================

type
  SimulationState* = object
    ## Physics simulation parameters.
    ## Pure immutable data - updates go through a copied var and re-set.
    particleCount*: int
    speciesCount*: int
    interactionRadius*: int
    forceStrength*: float
    friction*: float
    ruleTemperature*: float   ## Std dev sigma for the bell-curve rule randomizer
    timeScale*: float
    maxVelocity*: float
    repulsionEnd*: float      ## Where the repulsion zone ends (0-1)
    attractionPeak*: float    ## Where attraction peaks (0-1)
    forceModel*: int          ## 0=polynomial, 1=exponential
    expRepulsionAlpha*: float ## Exponential repulsion steepness
    expAttractionBeta*: float ## Exponential attraction range

func initSimulationState*(): SimulationState =
  ## The authoritative physics defaults (copied into CONFIG by createConfig).
  SimulationState(
    particleCount: 16000,
    speciesCount: 4,
    interactionRadius: 50,
    forceStrength: 1.0,
    friction: 0.05,
    ruleTemperature: 0.3,  # Tight bell curve: +/-0.99 is ~3.3 sigma out
    timeScale: 0.5,
    maxVelocity: 50.0,
    repulsionEnd: 0.5,     # Inner 50% is repulsion zone
    attractionPeak: 0.75,  # Attraction peaks at 75% of radius
    forceModel: 0,         # Polynomial (smooth curves)
    expRepulsionAlpha: 6.0,
    expAttractionBeta: 3.0
  )
