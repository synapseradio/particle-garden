#
# The typed record for every physics-side tunable: the ConfigObject fields the
# compute pipeline and force model read. web_api.nim holds this behind
# gardenAPI and mirrors each change synchronously into the flat CONFIG the hot
# paths consume; config.nim's createConfig copies these defaults, so the
# values below are the single authoritative defaults.
#
# Pure module: compiles on both the native (just test) and JS backends.
#
# ==============================================================================

import ../../field_core
import ../../climate_core  # CLIMATE_DEFAULT_SPEED, the drift-rate authority
import ../../config_ranges  # the bodies defaults and the measured mesh-size default

type
  SimulationState* = object
    ## Pure immutable data - updates go through a copied var and re-set.
    particleCount*: int
    speciesCount*: int
    interactionRadius*: int
    forceStrength*: float
    crowdingStrength*: float  ## How hard local density attenuates attraction:
                              ## every attractive contribution is scaled by
                              ## `1 / (1 + crowdingStrength * ln(1 + density))`.
                              ## Repulsion is untouched at every density, so the
                              ## term caps how tightly attraction can pack a
                              ## colony without cancelling what holds it apart.
                              ## Zero reproduces the force law with crowding absent.
    friction*: float
    ruleWildness*: float   ## Std dev sigma for the bell-curve rule randomizer
    timeScale*: float
    maxVelocity*: float
    repulsionEnd*: float      ## Where the repulsion zone ends (0-1)
    attractionPeak*: float    ## Where attraction peaks (0-1)
    forceModel*: int          ## 0=polynomial, 1=exponential
    expRepulsionAlpha*: float ## Exponential repulsion steepness
    expAttractionBeta*: float ## Exponential attraction range
    fluidStrength*: float     ## How much of the fluid's verdict on a particle's
                              ## velocity actually lands: multiplies the SPH
                              ## pass's whole per-pair contribution, pressure
                              ## and velocity smoothing together. The
                              ## three numbers below say what KIND of fluid this
                              ## is; this one says how much of it acts. Zero is
                              ## an ordinary value and skips the pass exactly.
    sphRestDensity*: float    ## SPH target density the Tait EOS drives toward.
                              ## Must exceed the isolated particle's normalized
                              ## self-density of 1.0, or isolation becomes the
                              ## zero-pressure state and the fluid disperses.
    sphStiffness*: float      ## SPH pressure gain (Tait stiffness)
    sphRadiusFraction*: float ## The SPH smoothing radius as a fraction of
                              ## interactionRadius. A fraction rather than a
                              ## length, so the fluid keeps its relative scale
                              ## when the interaction radius moves and a
                              ## smoothing radius past the neighbour sweep's
                              ## reach cannot be expressed.
    sphViscosity*: float      ## SPH XSPH viscosity strength
    longRangeStrength*: float ## How much of the long-range mesh's verdict on a
                              ## particle's velocity lands. It multiplies the
                              ## force pass alone and nothing earlier in the
                              ## chain, which is what keeps the density
                              ## accumulator's overflow bound a function of the
                              ## particle ceiling rather than of this slider.
                              ## Zero is an ordinary value and skips all five
                              ## passes exactly.
    longRangeReach*: float    ## The screening length lambda, in world units:
                              ## small confines the force to a neighbourhood,
                              ## large approaches the unscreened 2D limit, and
                              ## every value between is a continuous reach. No
                              ## mode and no kernel selector — the k-space
                              ## multiply makes the kernel a formula.
    longRangeGridIndex*: int  ## Which of config_ranges.LR_GRID_SIZES the mesh
                              ## runs at. The coupling's cost knob, and a
                              ## position rather than a number so a size the
                              ## transform cannot run on is unrepresentable.
    rdFeed*: float            ## Gray-Scott feed rate F
    rdKill*: float            ## Gray-Scott kill rate k
    rdDeposit*: float         ## Inhibitor each particle folds into its field
                              ## cell per frame. A perturbation on an already
                              ## ignited field, not what ignites it.
    rdFieldForce*: float      ## Gain converting the sampled field gradient
                              ## into a per-frame velocity impulse. Zero
                              ## leaves particles blind to the field.
    bodiesStrength*: float    ## How much of what a body says actually lands:
                              ## multiplies the whole output of both bodies
                              ## passes, the forces particles receive and the
                              ## reaction bodies receive. Zero is an ordinary
                              ## value and skips both passes exactly.
    bodyRadius*: float        ## The semi-axis a newly ignited body carries
                              ## along its own x. A body keeps what it was
                              ## ignited with while this moves on.
    bodyBand*: float          ## Proximity's reach either side of the surface,
                              ## and enclosure's ramp. A body's size says where
                              ## the surface is; this says how far from it the
                              ## forces reach.
    bodyProximity*: float     ## Signed pull toward the surface from either
                              ## side. Negative pushes off it instead.
    bodyEnclosure*: float     ## Signed hold across the surface: positive keeps
                              ## particles in, negative keeps them out, zero
                              ## does neither.
    bodyLifetime*: float      ## Seconds a body lives, attack through release.
                              ## Fixed at ignition, which is what lets Nim know
                              ## when a slot frees without reading the GPU.
    bodyIgnitionRate*: float  ## Bodies a second the world ignites on its own.
                              ## Zero means it ignites none and leaves every
                              ## body to the player.
    climateDrift*: bool       ## Whether the climate wanders on its own. Off by
                              ## default: the weather is something a user turns
                              ## on, never something that moves their sliders
                              ## unasked.
    climateSpeed*: float      ## Tours of the named regimes per minute, when
                              ## drift is on. See climate_core.
    forceWeather*: bool       ## Whether the force parameters wander on their
                              ## own. Off by default, on the same terms the
                              ## climate is: a weather moves a user's sliders
                              ## only once they ask for it.
    forceWeatherSpeed*: float ## Tours of the force waypoints per minute, when
                              ## the force weather is on. Independent of
                              ## climateSpeed — the two weathers run separately
                              ## and neither paces the other.

func initSimulationState*(): SimulationState =
  ## The authoritative physics defaults (copied into CONFIG by createConfig).
  SimulationState(
    particleCount: 32000,
    speciesCount: 4,
    interactionRadius: 50,
    forceStrength: 1.0,
    # Crowding starts off, so the shipped world is the force law every other
    # default was chosen against.
    crowdingStrength: 0.0,
    friction: 0.05,
    ruleWildness: 0.3,  # Tight bell curve: +/-0.99 is ~3.3 sigma out
    timeScale: 0.5,
    maxVelocity: 50.0,
    repulsionEnd: 0.5,     # Inner 50% is repulsion zone
    attractionPeak: 0.75,
    forceModel: 0,         # Polynomial (smooth curves)
    expRepulsionAlpha: 6.0,
    expAttractionBeta: 3.0,
    # The fluid starts silent, and that is a considered default rather than a
    # timid one. Every other coupling's default reproduces a world someone has
    # watched; forces at 1.0 with chemistry depositing is the world these
    # defaults reach. A fluid acting at full strength on top of both
    # at their defaults is a world nobody has tuned — its stiffness ceiling is
    # an unverified hypothesis — so it waits behind a slider the panel
    # always shows.
    fluidStrength: 0.0,
    sphRestDensity: 3.0,  # ~6 neighbors at r=0.5-0.6h settle at density 2.6-3.5
    sphStiffness: 8.0,
    # The whole interaction radius — every fluid world shipped runs the
    # fraction at 1.0, so a fresh world's fluid matches the fluid people
    # have already watched.
    sphRadiusFraction: 1.0,
    sphViscosity: 0.1,
    # The long-range mesh starts silent, like the fluid: the shipped world is
    # the one every other default was chosen against, and a coupling nobody has
    # watched act does not arrive switched on.
    longRangeStrength: 0.0,
    # Four times the neighbour sweep's maximum reach of 150, so the default
    # couples across distances the sweep cannot, and a sixth of the world's
    # width of 3840, so it is a reach rather than the unscreened limit.
    longRangeReach: 600.0,
    longRangeGridIndex: LONG_RANGE_GRID_INDEX_DEFAULT,
    rdFeed: RD_DEFAULT_FEED,
    rdKill: RD_DEFAULT_KILL,
    rdDeposit: RD_DEFAULT_DEPOSIT,
    rdFieldForce: RD_DEFAULT_FIELD_FORCE,
    # Bodies ship with the coupling acting and the world silent: a body pulls
    # as soon as a player makes one, and the world makes none until the
    # ignition rate is raised off its floor.
    bodiesStrength: BODIES_DEFAULT_STRENGTH,
    bodyRadius: BODY_DEFAULT_RADIUS,
    bodyBand: BODY_DEFAULT_BAND,
    bodyProximity: BODY_DEFAULT_PROXIMITY,
    bodyEnclosure: BODY_DEFAULT_ENCLOSURE,
    bodyLifetime: BODY_DEFAULT_LIFETIME,
    bodyIgnitionRate: BODY_DEFAULT_IGNITION_RATE,
    climateDrift: false,
    climateSpeed: CLIMATE_DEFAULT_SPEED,
    forceWeather: false,
    forceWeatherSpeed: FORCE_WEATHER_DEFAULT_SPEED
  )
