# ==============================================================================
# SIMULATION STATE - Physics simulation parameters
# ==============================================================================
#
# The typed record for every physics-side tunable: the nineteen ConfigObject
# fields the compute pipeline and force model read. ui.nim holds this in an
# Observable and mirrors each change synchronously into the flat CONFIG the
# hot paths consume; config.nim's createConfig copies these defaults, so the
# values below are the single authoritative defaults.
#
# Pure module: compiles on both the native (nimble test) and JS backends.
#
# ==============================================================================

import ../../field_core
import ../../climate_core  # CLIMATE_DEFAULT_SPEED, the drift-rate authority

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
    sphRestDensity*: float    ## SPH target density the Tait EOS drives toward.
                              ## Must exceed the isolated particle's normalized
                              ## self-density of 1.0, or isolation becomes the
                              ## zero-pressure state and the fluid disperses.
    sphStiffness*: float      ## SPH pressure gain (Tait stiffness)
    sphViscosity*: float      ## SPH XSPH viscosity strength
    sphSubsteps*: int         ## SPH physics substeps per rendered frame.
                              ## 2 halves the effective timestep the stiff
                              ## gamma=7 EOS integrates at; capped by
                              ## SPH_MAX_SUBSTEPS.
    rdFeed*: float            ## Gray-Scott feed rate F
    rdKill*: float            ## Gray-Scott kill rate k
    rdDeposit*: float         ## Inhibitor each particle folds into its field
                              ## cell per frame. A perturbation on an already
                              ## ignited field, not what ignites it.
    rdFieldForce*: float      ## Gain converting the sampled field gradient
                              ## into a per-frame velocity impulse. Zero
                              ## leaves particles blind to the field.
    climateDrift*: bool       ## Whether the climate wanders on its own. Off by
                              ## default: the weather is something a user turns
                              ## on, never something that moves their sliders
                              ## unasked.
    climateSpeed*: float      ## Tours of the named regimes per minute, when
                              ## drift is on. See climate_core.

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
    expAttractionBeta: 3.0,
    sphRestDensity: 3.0,  # ~6 neighbors at r=0.5-0.6h settle at density 2.6-3.5
    sphStiffness: 8.0,
    sphViscosity: 0.1,
    sphSubsteps: 2,
    rdFeed: RD_DEFAULT_FEED,
    rdKill: RD_DEFAULT_KILL,
    rdDeposit: RD_DEFAULT_DEPOSIT,
    rdFieldForce: RD_DEFAULT_FIELD_FORCE,
    climateDrift: false,     # Weather is opt-in; nothing moves unasked.
    climateSpeed: CLIMATE_DEFAULT_SPEED
  )
