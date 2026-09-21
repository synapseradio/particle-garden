## The shared unit and each writer's unit function (src/balance_core.nim).
##
## Every expectation comes from the design's own formulas, derived here
## independently of balance_core's arithmetic: the edge neighbour count from
## the onset number density, the long-range unit U(R) from the reference
## colony's radius,
## the world units per field cell from the world width over FIELD_W. Each unit
## function is held two ways: no configuration a sweep of its writer's oracle
## reaches exceeds it, and the oracle evaluated at the function's own
## maximizing configuration gives it back.

import std/[math, unittest]
import ../src/balance_core
import ../src/physics_core
import ../src/sph_core
import ../src/field_core
import ../src/long_range_core
import ../src/body_core
import ../src/memory_layout
import ../src/config_ranges
import ../src/shader_config

const BALANCE_CORE_TESTS_LOADED* = true

const
  ONSET_RATIO = CROWD_ONSET_RATIO
  TOLERANCE_F64 = 1e-9
  TOLERANCE_F32 = 1e-6
    ## The pair law, mouse and blast mirrors compute in f32, as the shader does.
  ANGLE_STEPS = 12

type Verdicts = seq[string]

proc judge(verdicts: var Verdicts; label: string;
    unit, worstSwept, attained, tolerance: float) =
  if not (worstSwept <= unit * (1.0 + tolerance)):
    verdicts.add label & ": a swept impulse of " & $worstSwept &
      " exceeds the unit function's " & $unit
  if not (unit > 0.0 and abs(attained - unit) <= tolerance * unit):
    verdicts.add label & ": the oracle at the function's own configuration " &
      "gives " & $attained & " against the unit function's " & $unit

template checkNoVerdicts(verdicts: Verdicts) =
  for message in verdicts[0 ..< min(verdicts.len, 4)]:
    checkpoint message
  check verdicts.len == 0

func angles(fromAngle, toAngle: float): seq[float] =
  for step in 0 .. ANGLE_STEPS:
    result.add fromAngle + (toAngle - fromAngle) * step.float / ANGLE_STEPS.float

func referenceConfig(): UnitConfig =
  ## Design N2's reference configuration: 16 000 particles at radius 50, one
  ## self-attracting species at MATRIX_MAX_VALUE, pattern scale 1, one live
  ## body; every gain at 1.
  UnitConfig(particleCount: 16_000, interactionRadius: 50.0,
    worldWidth: BODY_WORLD_W, worldHeight: BODY_WORLD_H,
    onsetRatio: ONSET_RATIO, crowdRatio: ONSET_RATIO,
    pressureStiffness: WORLD_PRESSURE_STIFFNESS,
    pressureImpulseMax: WORLD_PRESSURE_IMPULSE_MAX,
    attraction: MATRIX_MAX_VALUE,
    pairGain: 1.0, repulsionEnd: 0.5, attractionPeak: 0.75,
    fluidStrength: 1.0, viscosity: SPH_VISCOSITY_MAX,
    maxVelocity: MAX_VELOCITY_MAX, scentGain: 1.0, tropism: TROPISM_MIN,
    patternScale: 1.0, longRangeStrength: 1.0,
    bodiesStrength: 1.0, liveBodies: 1, blastStrength: 1.0,
    blastRange: sqrt(PRODUCTION_TUNING.blastRangeSq),
    depositGain: 1.0, secretion: SECRETION_MAX)

func edgeNeighbourCount(cfg: UnitConfig): float =
  ## Neighbours in the inward half of the attraction annulus of a particle on
  ## a clump's edge, at the onset number density x_on * N / A.
  let numberDensity = cfg.onsetRatio * cfg.particleCount.float /
    (cfg.worldWidth * cfg.worldHeight)
  let radius = cfg.interactionRadius
  numberDensity * PI * radius * radius *
    (1.0 - cfg.repulsionEnd * cfg.repulsionEnd) / 2.0

func colonyRadius(cfg: UnitConfig): float =
  ## The reference colony: every particle in one disc at the onset density.
  sqrt(cfg.worldWidth * cfg.worldHeight / (PI * cfg.onsetRatio))

suite "Every Writer Answers In The Pair Unit":

  test "one touching neighbour's repulsion at pair gain 1 over the reference frame is exactly u0":
    # The force law hands contact -1 in both models (polynomial Hermite ramp
    # and exponential repulsion at r = 0), and forces.wgsl multiplies it by the
    # pair gain and params.dt.
    for repulsionEnd in [REPULSION_END_MIN, 0.5, REPULSION_END_MAX]:
      let contact = polynomialForce(0.0'f32, MATRIX_MAX_VALUE.float32,
        repulsionEnd.float32, ATTRACTION_PEAK_MAX.float32, 1.0'f32)
      check -contact.float * 1.0 * FRAME_DT_REFERENCE == u0
    let exponentialContact = exponentialForce(0.0'f32, 0.0'f32,
      EXP_REPULSION_ALPHA_MAX.float32, EXP_ATTRACTION_BETA_MIN.float32,
      1.0'f32)
    check -exponentialContact.float * 1.0 * FRAME_DT_REFERENCE == u0

  test "the species unit bounds every swept neighbour placement and its own placement attains it":
    var verdicts: Verdicts
    for pairGain in [1.0, FORCE_STRENGTH_MAX]:
      for shape in [(0.1, 0.5), (0.3, 0.65), (0.5, 0.75), (0.9, 0.95)]:
        for particleCount in [1_000, 16_000, MAX_PARTICLES]:
          for radius in [INTERACTION_RADIUS_MIN.float, 50.0,
              INTERACTION_RADIUS_MAX.float]:
            var cfg = referenceConfig()
            cfg.pairGain = pairGain
            cfg.repulsionEnd = shape[0]
            cfg.attractionPeak = shape[1]
            cfg.particleCount = particleCount
            cfg.interactionRadius = radius
            let unit = unitImpulse(ufSpecies, cfg)
            let count = edgeNeighbourCount(cfg)
            # Every neighbour placed alike: the sum of `count` identical
            # inward components, per unit of u0.
            var worst = 0.0
            for step in 0 ..< 200:
              let r = (step.float / 200.0).float32
              for entry in [-MATRIX_MAX_VALUE, 0.5 * MATRIX_MAX_VALUE,
                  MATRIX_MAX_VALUE]:
                for attenuation in [0.3'f32, 1.0'f32]:
                  let polynomial = polynomialForce(r, entry.float32,
                    shape[0].float32, shape[1].float32, attenuation)
                  var exponentialPeak = 0.0'f32
                  for alpha in [EXP_REPULSION_ALPHA_MIN, EXP_REPULSION_ALPHA_MAX]:
                    for beta in [EXP_ATTRACTION_BETA_MIN, EXP_ATTRACTION_BETA_MAX]:
                      let attractionPart =
                        exponentialForce(r, entry.float32, alpha.float32,
                          beta.float32, attenuation) -
                        exponentialForce(r, 0.0'f32, alpha.float32,
                          beta.float32, attenuation)
                      exponentialPeak = max(exponentialPeak, attractionPart)
                  for theta in angles(-PI / 2.0, PI / 2.0):
                    for magnitude in [polynomial, exponentialPeak]:
                      worst = max(worst,
                        count * pairGain * magnitude.float * cos(theta))
            let attained = count * pairGain * polynomialForce(
              shape[1].float32, cfg.attraction.float32, shape[0].float32,
              shape[1].float32, 1.0'f32).float
            verdicts.judge("species gain " & $pairGain & " shape " & $shape &
              " N " & $particleCount & " R " & $radius, unit, worst, attained,
              TOLERANCE_F32)
    checkNoVerdicts(verdicts)

  test "the world-pressure unit bounds every swept pair and a touching pair at the crowd attains it":
    # forces.wgsl exchanges min(K (phi_this + phi_other) (1 - r/R) / 120,
    # q_max) per pair. It is largest where both particles carry the stated
    # crowd density and the pair touches.
    var verdicts: Verdicts
    for particleCount in [1_000, 16_000, MAX_PARTICLES]:
      for radius in [INTERACTION_RADIUS_MIN.float, 50.0,
          INTERACTION_RADIUS_MAX.float]:
        for onsetMultiple in [1.5, 3.0, 12.0]:
          var cfg = referenceConfig()
          cfg.particleCount = particleCount
          cfg.interactionRadius = radius
          let density = onsetMultiple * crowdOnsetDensity(cfg)
          cfg.crowdRatio = density / meanCrowdDensity(cfg)
          let unit = unitImpulse(ufWorldPressure, cfg)
          let onset = crowdOnsetDensity(cfg).float32
          var worst = 0.0
          for shareThis in [0.0, 0.5, 1.0]:
            for shareOther in [0.0, 0.5, 1.0]:
              for proximityStep in 0 .. 10:
                let normalizedDistance = proximityStep.float / 10.0
                worst = max(worst, worldPressureMagnitude(
                  crowdPressure((density * shareThis).float32, onset),
                  crowdPressure((density * shareOther).float32, onset),
                  normalizedDistance.float32,
                  cfg.pressureStiffness.float32,
                  cfg.pressureImpulseMax.float32).float / u0)
          let touching = crowdPressure(density.float32, onset)
          let attained = worldPressureMagnitude(touching, touching, 0.0'f32,
            cfg.pressureStiffness.float32,
            cfg.pressureImpulseMax.float32).float / u0
          verdicts.judge("world pressure N " & $particleCount & " R " &
            $radius & " at " & $onsetMultiple & " times the onset", unit,
            worst, attained, TOLERANCE_F32)
    checkNoVerdicts(verdicts)

  test "the fluid unit bounds every swept pair and its own pair attains it":
    let densityRatio = PRODUCTION_TUNING.sphMaxDensityRatio
    var verdicts: Verdicts
    for fluidStrength in [0.5, 1.0]:
      for viscosity in [SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX]:
        for maxVelocity in [50.0, MAX_VELOCITY_MAX]:
          var cfg = referenceConfig()
          cfg.fluidStrength = fluidStrength
          cfg.viscosity = viscosity
          cfg.maxVelocity = maxVelocity
          let unit = unitImpulse(ufFluid, cfg)
          var worst = 0.0
          for restDensity in [SPH_REST_DENSITY_MIN, 1.0, SPH_REST_DENSITY_MAX]:
            let ceilingDensity = restDensity * densityRatio
            for stiffness in [SPH_STIFFNESS_MIN, SPH_STIFFNESS_MAX]:
              for laggedThis in [1.0, 2.0, 8.0]:
                for laggedOther in [1.0, 8.0]:
                  let densityThis = clamp(laggedThis, restDensity, ceilingDensity)
                  let densityOther = clamp(laggedOther, restDensity, ceilingDensity)
                  let pressureThis = flooredTaitPressure(densityThis,
                    restDensity, stiffness, SPH_DEFAULT_GAMMA)
                  let pressureOther = flooredTaitPressure(densityOther,
                    restDensity, stiffness, SPH_DEFAULT_GAMMA)
                  for weight in [0.0, 0.5, 1.0]:
                    for gap in [0.0, maxVelocity, 2.0 * maxVelocity]:
                      for gapAngle in angles(0.0, 2.0 * PI):
                        let delta = sphPairVelocityDelta(pressureThis,
                          densityThis, pressureOther, densityOther, weight,
                          weight, laggedThis, laggedOther, viscosity,
                          fluidStrength, (x: 1.0, y: 0.0),
                          (x: gap * cos(gapAngle), y: gap * sin(gapAngle)))
                        worst = max(worst,
                          hypot(delta.x, delta.y) / FRAME_DT_REFERENCE)
          # The clamp binds at the lowest rest density and the stiffest fluid,
          # and the blend is largest at full weight against an unit
          # denominator with the gap opposing the direction.
          let ceilingDensity = SPH_REST_DENSITY_MIN * densityRatio
          let pressure = flooredTaitPressure(ceilingDensity,
            SPH_REST_DENSITY_MIN, SPH_STIFFNESS_MAX, SPH_DEFAULT_GAMMA)
          let own = sphPairVelocityDelta(pressure, ceilingDensity, pressure,
            ceilingDensity, 1.0, 1.0, 1.0, 1.0, viscosity, fluidStrength,
            (x: 1.0, y: 0.0),
            (x: -2.0 * maxVelocity, y: 0.0))
          verdicts.judge("fluid strength " & $fluidStrength & " viscosity " &
            $viscosity & " maxVelocity " & $maxVelocity, unit, worst,
            hypot(own.x, own.y) / FRAME_DT_REFERENCE, TOLERANCE_F64)
    checkNoVerdicts(verdicts)

  test "the scent unit bounds every swept gradient and tropism and its own gradient attains it":
    var verdicts: Verdicts
    for scentGain in [1.0, 4.0]:
      for patternScale in [1.0, 0.5, 0.25]:
        var cfg = referenceConfig()
        cfg.scentGain = scentGain
        cfg.patternScale = patternScale
        let unit = unitImpulse(ufScent, cfg)
        # Today's slider value is the gain in world units: it spans one cell.
        let forceScale = scentGain * cfg.worldWidth / FIELD_W.float
        # The per-cell gradient grows as the pattern shrinks, as 1/sqrt(s).
        let gradientBound = RD_INHIBITOR_GRADIENT_PEAK / sqrt(patternScale)
        var worst = 0.0
        for gradientStep in 0 .. 10:
          let gradient = gradientBound * gradientStep.float / 10.0
          for direction in angles(0.0, 2.0 * PI):
            for tropismStep in 0 .. 6:
              let tropism = TROPISM_MIN +
                (TROPISM_MAX - TROPISM_MIN) * tropismStep.float / 6.0
              let push = (
                x: speciesTropismForce(gradient * cos(direction), forceScale, tropism),
                y: speciesTropismForce(gradient * sin(direction), forceScale, tropism))
              worst = max(worst, hypot(push.x, push.y) / FRAME_DT_REFERENCE)
        let attained = abs(speciesTropismForce(gradientBound, forceScale,
          cfg.tropism)) / FRAME_DT_REFERENCE
        verdicts.judge("scent gain " & $scentGain & " scale " & $patternScale,
          unit, worst, attained, TOLERANCE_F64)
    checkNoVerdicts(verdicts)

  test "the long-range unit bounds every swept distance past the colony and one radius past its edge attains it":
    var verdicts: Verdicts
    for radius in [INTERACTION_RADIUS_MIN.float, 50.0,
        INTERACTION_RADIUS_MAX.float]:
      for particleCount in [16_000, MAX_PARTICLES]:
        for strength in [0.5, 1.0]:
          var cfg = referenceConfig()
          cfg.interactionRadius = radius
          cfg.particleCount = particleCount
          cfg.longRangeStrength = strength
          let unit = unitImpulse(ufLongRange, cfg)
          let a = colonyRadius(cfg)
          let pairUnit = FRAME_DT_REFERENCE * radius * radius * (a + radius) /
            (a * a)
          let nearest = a + radius
          var worst = 0.0
          for distanceStep in 0 .. 40:
            let distance = nearest + 50.0 * distanceStep.float
            for entry in [-MATRIX_MAX_VALUE, 0.5 * MATRIX_MAX_VALUE,
                MATRIX_MAX_VALUE]:
              for swept in [0.25 * strength, strength]:
                worst = max(worst, lrDiscPull(swept, entry, pairUnit,
                  particleCount.float, distance) / FRAME_DT_REFERENCE)
          let attained = lrDiscPull(strength, cfg.attraction, pairUnit,
            particleCount.float, nearest) / FRAME_DT_REFERENCE
          verdicts.judge("long range R " & $radius & " N " & $particleCount &
            " strength " & $strength, unit, worst, attained, TOLERANCE_F64)
    checkNoVerdicts(verdicts)

  test "the bodies unit bounds every swept body stack and a full stack holding at its band attains it":
    const bodyRadius = 200.0
    let centre = (x: BODY_WORLD_W / 2.0, y: BODY_WORLD_H / 2.0)
    var verdicts: Verdicts
    for strength in [0.5, BODIES_STRENGTH_MAX]:
      for liveBodies in [1, 3, MAX_BODIES]:
        var cfg = referenceConfig()
        cfg.bodiesStrength = strength
        cfg.liveBodies = liveBodies
        let unit = unitImpulse(ufBodies, cfg)
        var worst = 0.0
        for band in [BODY_BAND_MIN, 120.0, BODY_BAND_CEILING]:
          for anisotropy in [BODY_ANISOTROPY_FLOOR, 1.0, BODY_ANISOTROPY_CEILING]:
            for proximity in [-BODY_FORCE_CEILING, 0.0, BODY_FORCE_CEILING]:
              for enclosure in [-BODY_FORCE_CEILING, 0.0, BODY_FORCE_CEILING]:
                let body = Body(centerX: centre.x, centerY: centre.y,
                  radius: bodyRadius, anisotropy: anisotropy,
                  bandWidth: band, proximity: proximity, enclosure: enclosure)
                for offsetStep in 0 .. 60:
                  let offset = (bodyRadius + 3.0 * band) *
                    offsetStep.float / 60.0
                  for direction in angles(0.0, PI / 2.0):
                    for envelope in [0.5, 1.0]:
                      let one = bodyForceAt(body,
                        centre.x + offset * cos(direction),
                        centre.y + offset * sin(direction),
                        BODY_WORLD_W, BODY_WORLD_H, envelope, strength)
                      worst = max(worst, liveBodies.float *
                        hypot(one.x, one.y) / FRAME_DT_REFERENCE)
        let holding = Body(centerX: centre.x, centerY: centre.y,
          radius: bodyRadius, anisotropy: 1.0, bandWidth: 120.0,
          proximity: 0.0, enclosure: BODY_FORCE_CEILING)
        var stack = (x: 0.0, y: 0.0)
        for _ in 0 ..< liveBodies:
          let one = bodyForceAt(holding, centre.x + bodyRadius + 120.0,
            centre.y, BODY_WORLD_W, BODY_WORLD_H, 1.0, strength)
          stack = (x: stack.x + one.x, y: stack.y + one.y)
        verdicts.judge("bodies strength " & $strength & " live " & $liveBodies,
          unit, worst, hypot(stack.x, stack.y) / FRAME_DT_REFERENCE,
          TOLERANCE_F64)
    checkNoVerdicts(verdicts)

  test "the mouse unit bounds every swept pointer offset and an offset at the pointer attains it":
    var verdicts: Verdicts
    let unit = unitImpulse(ufMouse, referenceConfig())
    var worst = 0.0
    for mouseRange in [30.0'f32, 300.0'f32, 3000.0'f32]:
      for distanceStep in 1 .. 100:
        let distance = mouseRange * distanceStep.float32 / 100.0'f32
        for direction in angles(0.0, 2.0 * PI):
          for buttonSign in [-1.0'f32, 0.0'f32, 1.0'f32]:
            let push = mouseForce(distance * cos(direction).float32,
              distance * sin(direction).float32, mouseRange, buttonSign)
            worst = max(worst, hypot(push.x.float, push.y.float))
    # The magnitude is 300 at the pointer itself, where the shader's
    # distance > 0 guard leaves only a limit to approach.
    let atPointer = mouseForce(1e-5'f32, 0.0'f32, 300.0'f32, 1.0'f32)
    verdicts.judge("mouse", unit, worst,
      hypot(atPointer.x.float, atPointer.y.float), TOLERANCE_F32)
    checkNoVerdicts(verdicts)

  test "the blast unit bounds every swept offset and strength and an offset at the divisor floor attains it":
    var verdicts: Verdicts
    for blastStrength in [0.02, 0.5, 1.0]:
      for blastRange in [100.0, sqrt(PRODUCTION_TUNING.blastRangeSq)]:
        var cfg = referenceConfig()
        cfg.blastStrength = blastStrength
        cfg.blastRange = blastRange
        let unit = unitImpulse(ufBlast, cfg)
        var worst = 0.0
        for distanceStep in 1 .. 200:
          let distance = blastRange * distanceStep.float / 200.0
          for swept in [0.5 * blastStrength, blastStrength]:
            let push = blastForce(distance.float32, 0.0'f32, swept.float32,
              blastRange.float32)
            worst = max(worst, hypot(push.x.float, push.y.float))
        let atFloor = blastForce(10.0'f32, 0.0'f32, blastStrength.float32,
          blastRange.float32)
        verdicts.judge("blast strength " & $blastStrength & " range " &
          $blastRange, unit, worst, hypot(atFloor.x.float, atFloor.y.float),
          TOLERANCE_F32)
    checkNoVerdicts(verdicts)

  test "the deposit unit bounds every swept amount and secretion and full secretion attains it":
    var verdicts: Verdicts
    for depositGain in [RD_DEPOSIT_MAX, 1.0]:
      var cfg = referenceConfig()
      cfg.depositGain = depositGain
      let unit = unitImpulse(ufDeposit, cfg)
      var worst = 0.0
      for amountStep in 0 .. 10:
        let amount = depositGain * amountStep.float / 10.0
        for secretionStep in 0 .. 10:
          let secretion = SECRETION_MIN +
            (SECRETION_MAX - SECRETION_MIN) * secretionStep.float / 10.0
          worst = max(worst, abs(speciesDeposit(amount, secretion)))
      verdicts.judge("deposit gain " & $depositGain, unit, worst,
        abs(speciesDeposit(depositGain, cfg.secretion)), TOLERANCE_F64)
    checkNoVerdicts(verdicts)

suite "The Onset Follows The World And Keeps A Contact Floor":
  ## The onset is max(x_on * rho-bar, rho_floor). The floor is the crowd
  ## density of a hexagonal lattice at the pair law's rest spacing, counted
  ## site by site in the weight forces.wgsl accumulates.
  const SINGLE_SHELL_SPACINGS = [0.6, 0.7, 0.75, 0.9]
    ## Above 1/sqrt(3) the second shell sits outside the interaction radius,
    ## so the lattice's whole contribution is its six nearest neighbours.

  test "one shell of six neighbours is the whole floor where only one fits":
    for spacing in SINGLE_SHELL_SPACINGS:
      checkpoint("spacing " & $spacing)
      check abs(latticeCrowdDensity(spacing) - 6.0 * (1.0 - spacing)) <
        TOLERANCE_F64

  test "the counted lattice meets the packing constant as the spacing shrinks":
    # The constant is the continuum of the same lattice, so the two meet where
    # a lattice's few shells give way to a crowd.
    var previousGap = 1.0
    for spacing in [0.1, 0.05, 0.02, 0.01]:
      let continuum = CROWD_PACKING_CONSTANT / (spacing * spacing)
      let gap = abs(latticeCrowdDensity(spacing) - continuum) / continuum
      checkpoint("spacing " & $spacing & " gap " & $gap)
      check gap < previousGap
      previousGap = gap
    check previousGap < 1.0e-3

  test "the floor falls as the rest spacing widens and outruns a resting pair":
    # One neighbour resting at the pair law's own spacing weighs 1 - spacing.
    # The floor is the six of them a lattice holds, so no lone pair reaches it.
    var previous = Inf
    for step in 0 .. 16:
      let spacing = REPULSION_END_MIN +
        (REPULSION_END_MAX - REPULSION_END_MIN) * step.float / 16.0
      let floorDensity = latticeCrowdDensity(spacing)
      checkpoint("spacing " & $spacing & " floor " & $floorDensity)
      check floorDensity < previous
      check floorDensity >= 6.0 * (1.0 - spacing) - TOLERANCE_F64
      previous = floorDensity

  test "the onset is the world's own density where the world is dense":
    var cfg = referenceConfig()
    cfg.particleCount = MAX_PARTICLES
    cfg.interactionRadius = INTERACTION_RADIUS_MAX.float
    check crowdOnsetDensity(cfg) == ONSET_RATIO * meanCrowdDensity(cfg)
    check crowdOnsetDensity(cfg) > contactFloorDensity(cfg)
    # It follows the count and the radius the density itself follows.
    var denser = cfg
    denser.particleCount = cfg.particleCount * 2
    check abs(crowdOnsetDensity(denser) - 2.0 * crowdOnsetDensity(cfg)) <
      TOLERANCE_F64 * crowdOnsetDensity(cfg)
    var wider = cfg
    wider.interactionRadius = cfg.interactionRadius * 2.0
    check abs(crowdOnsetDensity(wider) - 4.0 * crowdOnsetDensity(cfg)) <
      TOLERANCE_F64 * crowdOnsetDensity(cfg)

  test "the onset is the contact floor where the world is sparse":
    var cfg = referenceConfig()
    cfg.particleCount = PARTICLE_COUNT_MIN
    cfg.interactionRadius = INTERACTION_RADIUS_MIN.float
    check ONSET_RATIO * meanCrowdDensity(cfg) < contactFloorDensity(cfg)
    check crowdOnsetDensity(cfg) == contactFloorDensity(cfg)

  test "the onset never falls below the contact floor":
    for particleCount in [PARTICLE_COUNT_MIN, 1_000, 16_000, MAX_PARTICLES]:
      for radius in [INTERACTION_RADIUS_MIN.float, 50.0,
          INTERACTION_RADIUS_MAX.float]:
        for repulsionEnd in [REPULSION_END_MIN, 0.5, REPULSION_END_MAX]:
          var cfg = referenceConfig()
          cfg.particleCount = particleCount
          cfg.interactionRadius = radius
          cfg.repulsionEnd = repulsionEnd
          checkpoint("N " & $particleCount & " R " & $radius & " rest " &
            $repulsionEnd)
          check crowdOnsetDensity(cfg) >= contactFloorDensity(cfg)
          check contactFloorDensity(cfg) == latticeCrowdDensity(repulsionEnd)

# ==============================================================================
# THE FLUID MIRROR AND ITS ARMS
# ==============================================================================
# The stepped world's fluid block is held against sph_core's pair term, summed
# pair by pair over the torus, and each fluid arm's sides are held to differ in
# the one term the arm reads (design N8).

import std/random
import ../src/preset

const
  FLUID_TEST_SPAN = 300.0'f32
  FLUID_TEST_PARTICLES = 400
    ## About 35 neighbours inside the interaction radius, and a few dozen
    ## pairs inside the smallest smoothing radius.
  FLUID_TEST_RADIUS = 50.0'f32
  FLUID_TEST_SEED = 20_260_921
  UNCAPPED_VELOCITY = 1.0e6'f32
    ## Far above any speed a stirred world reaches, so the soft cap never acts.
  F32_ROUNDING = 1.0 / 4_194_304.0
    ## 2^-22: two f32 roundings of half an ulp each, with room to spare.
  FLUID_ARM_RADIUS = 50.0
  FLUID_ARM_FORCE_STRENGTH = 0.2
    ## The shipped Force Strength on the 0-1 scale.
  FLUID_ARM_PAIR_GAIN = 5.0
    ## g_pair (design N2): the new scale's 0.2 is today's force multiplier 1.

func shippedFluid(): OracleFluidParams =
  ## forces-sph.wgsl's inputs at the shipped fluid settings, at fluid 1.
  let shipped = defaultSettings()
  OracleFluidParams(strength: 1.0,
    radiusFraction: shipped.sphRadiusFraction,
    restDensity: shipped.sphRestDensity, viscosity: shipped.sphViscosity,
    gamma: SPH_DEFAULT_GAMMA, stiffness: shipped.sphStiffness,
    blend: SPH_XSPH_EPSILON, pressureGain: SPH_FORCE_SCALE,
    maxPressureAccel: SPH_MAX_PRESSURE_ACCEL,
    maxDensityRatio: PRODUCTION_TUNING.sphMaxDensityRatio,
    densityScale: sphDensityFixedPointScale(MAX_PARTICLES),
    coarseShift: VELOCITY_COARSE_SHIFT)

func fluidOnlyParams(fluid: OracleFluidParams;
    retention = 1.0'f32): OracleParams =
  ## A world whose species term and world pressure hand nothing, so every
  ## velocity change is the fluid's.
  OracleParams(interactionRadius: FLUID_TEST_RADIUS,
    worldWidth: FLUID_TEST_SPAN, worldHeight: FLUID_TEST_SPAN,
    minDistanceSq: PRODUCTION_TUNING.minDistanceSq.float32,
    forceModel: ofmPolynomial, forceMultiplier: 0.0'f32,
    repulsionEnd: 0.5'f32, attractionPeak: 0.75'f32,
    pressureOnset: 1.0'f32, pressureStiffness: 0.0'f32,
    pressureStepBound: PRESSURE_STEP_BOUND.float32,
    stiffnessFixedPointScale: STIFFNESS_FIXED_POINT_SCALE.float32,
    stiffnessCoarseShift: STIFFNESS_COARSE_SHIFT,
    friction: retention, maxVelocity: UNCAPPED_VELOCITY,
    fixedPointScale: PRODUCTION_TUNING.fixedPointScale.float32,
    crowdDensityScale: sphDensityFixedPointScale(MAX_PARTICLES).float32,
    densitySmoothFactor: PRODUCTION_TUNING.densitySmoothFactor.float32,
    fluid: fluid)

proc stirredWorld(params: OracleParams; seed: int): OracleWorld =
  ## Particles placed from `seed`, each given a velocity and a lagged density
  ## that runs from below rest to above the pressure-density ceiling.
  result = initOracleWorld(params, FLUID_TEST_PARTICLES, 1, @[0.0'f32], seed)
  var draws = initRand(seed)
  let f = params.fluid
  for i in 0 ..< FLUID_TEST_PARTICLES:
    result.velX[i] = draws.rand(-20.0 .. 20.0).float32
    result.velY[i] = draws.rand(-20.0 .. 20.0).float32
    result.sphDensity[i] = (f.restDensity *
      draws.rand(0.5 .. f.maxDensityRatio + 1.0)).float32

type FluidExpectation = object
  ## sph_core's pair term summed pair by pair, per particle.
  delta: seq[tuple[x, y: float]]
  ownRegister: seq[tuple[x, y: float]]
    ## The part summed in the particle's own f32 register: its pairs as the
    ## lower index.
  density: seq[float]
  pairs: seq[int]
  clampedPairs, blendedPairs: int

func minimumImage(fromAt, toAt, span: float32): float32 =
  ## The separation forces-sph.wgsl forms, `(other + wrap) - this`, with the
  ## wrap that brings the two within half a world.
  var best = toAt - fromAt
  for wrap in [-span, span]:
    let wrapped = (toAt + wrap) - fromAt
    if abs(wrapped) < abs(best):
      best = wrapped
  best

func expectFluid(world: OracleWorld): FluidExpectation =
  ## Every pair over the torus, through sph_core's pair term. sph_core bakes
  ## in SPH_XSPH_EPSILON and SPH_FORCE_SCALE, so an arm's zero side reaches it
  ## as the viscosity or stiffness that gives the same term.
  let p = world.params
  let f = p.fluid
  doAssert f.pressureGain in [0.0, SPH_FORCE_SCALE],
    "sph_core's pair term carries SPH_FORCE_SCALE or no pressure at all"
  doAssert f.maxPressureAccel == SPH_MAX_PRESSURE_ACCEL
  let oracleViscosity =
    if f.blend == SPH_XSPH_EPSILON: f.viscosity
    else: f.viscosity + f.blend - SPH_XSPH_EPSILON
  let oracleStiffness = if f.pressureGain == 0.0: 0.0 else: f.stiffness
  let h = (p.interactionRadius * f.radiusFraction.float32).float
  let n = world.posX.len
  result.delta = newSeq[tuple[x, y: float]](n)
  result.ownRegister = newSeq[tuple[x, y: float]](n)
  result.density = newSeq[float](n)
  result.pairs = newSeq[int](n)
  for i in 0 ..< n:
    result.density[i] = 1.0
  for i in 0 ..< n:
    for j in i + 1 ..< n:
      let separationX = minimumImage(world.posX[i], world.posX[j], p.worldWidth)
      let separationY = minimumImage(world.posY[i], world.posY[j], p.worldHeight)
      let distanceSq = separationX * separationX + separationY * separationY
      let radius = p.interactionRadius * f.radiusFraction.float32
      if distanceSq <= 0.0'f32 or distanceSq >= radius * radius:
        continue
      let distance = sqrt(max(distanceSq, p.minDistanceSq))
      let invDistance = 1.0'f32 / distance
      let direction = (x: (separationX * invDistance).float,
        y: (separationY * invDistance).float)
      let densityWeight = poly6Weight2d(distance.float, h) /
        poly6Weight2d(0.0, h)
      let gradientWeight = spikyGradientMagnitude2d(distance.float, h) /
        spikyGradientMagnitude2d(0.0, h)
      let laggedI = world.sphDensity[i].float
      let laggedJ = world.sphDensity[j].float
      let ceilingDensity = f.restDensity * f.maxDensityRatio
      let densityI = clamp(laggedI, f.restDensity, ceilingDensity)
      let densityJ = clamp(laggedJ, f.restDensity, ceilingDensity)
      let pressureI = flooredTaitPressure(densityI, f.restDensity,
        oracleStiffness, f.gamma)
      let pressureJ = flooredTaitPressure(densityJ, f.restDensity,
        oracleStiffness, f.gamma)
      let gap = (x: (world.velX[j] - world.velX[i]).float,
        y: (world.velY[j] - world.velY[i]).float)
      let onI = sphPairVelocityDelta(pressureI, densityI, pressureJ, densityJ,
        gradientWeight, densityWeight, laggedI, laggedJ, oracleViscosity,
        f.strength, direction, gap)
      let unclamped = SPH_FORCE_SCALE * (pressureI / (densityI * densityI) +
        pressureJ / (densityJ * densityJ)) * gradientWeight
      if abs(unclamped) > SPH_MAX_PRESSURE_ACCEL:
        result.clampedPairs += 1
      if (oracleViscosity + SPH_XSPH_EPSILON) * densityWeight *
          hypot(gap.x, gap.y) > 0.0:
        result.blendedPairs += 1
      result.delta[i] = (x: result.delta[i].x + onI.x,
        y: result.delta[i].y + onI.y)
      result.ownRegister[i] = (x: result.ownRegister[i].x + onI.x,
        y: result.ownRegister[i].y + onI.y)
      result.delta[j] = (x: result.delta[j].x - onI.x,
        y: result.delta[j].y - onI.y)
      result.density[i] += densityWeight
      result.density[j] += densityWeight
      result.pairs[i] += 1
      result.pairs[j] += 1

type MirrorReading = object
  verdicts: Verdicts
  expectation: FluidExpectation

proc mirrorStep(label: string; fluid: OracleFluidParams;
    frameFactor = 1.0; retention = 1.0'f32): MirrorReading =
  ## One mirrored step of a stirred world against sph_core's pair term. The
  ## tolerance is one quantum per encode a particle's delta passes through
  ## (one per pair it meets as the higher index, one for its own register,
  ## one spare), plus the f32 roundings of its own register, the velocity add
  ## and the friction multiply.
  var world = stirredWorld(fluidOnlyParams(fluid, retention), FLUID_TEST_SEED)
  let before = world
  let expected = expectFluid(before)
  stepFrame(world, frameFactor, 1)
  let quantum = 1.0 / PRODUCTION_TUNING.fixedPointScale
  let densityQuantum = 1.0 / fluid.densityScale
  result.expectation = expected
  for i in 0 ..< world.posX.len:
    for axis in 0 .. 1:
      let v0 = (if axis == 0: before.velX[i] else: before.velY[i]).float
      let v1 = (if axis == 0: world.velX[i] else: world.velY[i]).float
      let delta =
        if axis == 0: expected.delta[i].x else: expected.delta[i].y
      let own =
        if axis == 0: expected.ownRegister[i].x else: expected.ownRegister[i].y
      let want = (v0 + frameFactor * delta) * retention.float
      let allowed = frameFactor * (expected.pairs[i].float + 2.0) * quantum +
        (abs(v0) + frameFactor * (abs(delta) + abs(own))) * F32_ROUNDING
      if not (abs(v1 - want) <= allowed):
        result.verdicts.add label & ": particle " & $i & " axis " & $axis &
          " steps to " & $v1 & " where sph_core's pair term gives " & $want &
          " (allowed " & $allowed & ", " & $expected.pairs[i] & " pairs)"
    let density = world.sphDensity[i].float
    let densityAllowed = (expected.pairs[i].float + 2.0) * densityQuantum +
      expected.density[i] * F32_ROUNDING
    if not (abs(density - expected.density[i]) <= densityAllowed):
      result.verdicts.add label & ": particle " & $i & " stores density " &
        $density & " where the kernel sum is " & $expected.density[i]

type
  FluidTerm = enum
    ## The three effects design N8 reads one at a time, each named for the
    ## OracleFluidParams field it moves.
    ftBlend = "blend"
    ftPressureGain = "pressureGain"
    ftRadiusFraction = "radiusFraction"

  FluidArm = object
    term: FluidTerm
    reference: OracleFluidParams
      ## The side each step's structure survival is compared with.
    steps: seq[OracleFluidParams]

func fluidArms(): array[FluidTerm, FluidArm] =
  ## Design N8's arms. The stiffness is the stored one; the calibration hands
  ## each side the effective stiffness substepPlan derives from it.
  let shipped = shippedFluid()
  var blended = shipped
  blended.viscosity = SPH_VISCOSITY_MIN
  var unblended = blended
  unblended.blend = 0.0
  var unpressured = shipped
  unpressured.pressureGain = 0.0
  var whole = shipped
  whole.radiusFraction = SPH_RADIUS_FRACTION_MAX
  var fractions: seq[OracleFluidParams]
  for fraction in [0.75, 0.5, 0.25, SPH_RADIUS_FRACTION_MIN]:
    var step = whole
    step.radiusFraction = fraction
    fractions.add step
  result[ftBlend] = FluidArm(term: ftBlend, reference: unblended,
    steps: @[blended])
  result[ftPressureGain] = FluidArm(term: ftPressureGain,
    reference: unpressured, steps: @[shipped])
  result[ftRadiusFraction] = FluidArm(term: ftRadiusFraction,
    reference: whole, steps: fractions)

func armWorldParams(fluid: OracleFluidParams;
    particleCount: int): OracleParams =
  ## The world every arm side and its fluid-zero comparison stand on: radius
  ## 50, the species force at its shipped default, crowding 0, the world
  ## pressure acting at the onset config_ranges holds.
  let shipped = defaultSettings()
  var cfg = referenceConfig()
  cfg.particleCount = particleCount
  cfg.interactionRadius = FLUID_ARM_RADIUS
  cfg.repulsionEnd = shipped.repulsionEnd
  cfg.attractionPeak = shipped.attractionPeak
  OracleParams(
    interactionRadius: FLUID_ARM_RADIUS.float32,
    worldWidth: cfg.worldWidth.float32, worldHeight: cfg.worldHeight.float32,
    minDistanceSq: PRODUCTION_TUNING.minDistanceSq.float32,
    forceModel: ofmPolynomial,
    forceMultiplier: (FLUID_ARM_PAIR_GAIN * FLUID_ARM_FORCE_STRENGTH).float32,
    repulsionEnd: cfg.repulsionEnd.float32,
    attractionPeak: cfg.attractionPeak.float32,
    expAlpha: shipped.expRepulsionAlpha.float32,
    expBeta: shipped.expAttractionBeta.float32,
    crowdingStrength: 0.0'f32,
    pressureOnset: crowdOnsetDensity(cfg).float32,
    pressureStiffness: WORLD_PRESSURE_STIFFNESS.float32,
    pressureImpulseMax: WORLD_PRESSURE_IMPULSE_MAX.float32,
    pressureStepBound: PRESSURE_STEP_BOUND.float32,
    stiffnessFixedPointScale: STIFFNESS_FIXED_POINT_SCALE.float32,
    stiffnessCoarseShift: STIFFNESS_COARSE_SHIFT,
    friction: (1.0 - shipped.friction).float32,
    maxVelocity: shipped.maxVelocity.float32,
    fixedPointScale: PRODUCTION_TUNING.fixedPointScale.float32,
    crowdDensityScale: sphDensityFixedPointScale(MAX_PARTICLES).float32,
    densitySmoothFactor: PRODUCTION_TUNING.densitySmoothFactor.float32,
    fluid: fluid)

func differingFields[T: object](a, b: T): seq[string] =
  for name, left, right in fieldPairs(a, b):
    if left != right:
      result.add name

suite "The Fluid Mirror Steps As The Oracle Does":

  test "one mirrored step at the shipped fluid matches sph_core's pair term":
    let reading = mirrorStep("shipped", shippedFluid())
    check reading.expectation.blendedPairs > 0
    checkNoVerdicts(reading.verdicts)

  test "one mirrored step matches across viscosity, radius fraction and strength":
    var verdicts: Verdicts
    for viscosity in [SPH_VISCOSITY_MIN, SPH_VISCOSITY_MAX]:
      for fraction in [SPH_RADIUS_FRACTION_MAX, 0.5, SPH_RADIUS_FRACTION_MIN]:
        for strength in [0.5, FLUID_STRENGTH_MAX]:
          var fluid = shippedFluid()
          fluid.viscosity = viscosity
          fluid.radiusFraction = fraction
          fluid.strength = strength
          let reading = mirrorStep("viscosity " & $viscosity & " fraction " &
            $fraction & " strength " & $strength, fluid)
          check reading.expectation.pairs.len > 0
          verdicts.add reading.verdicts
    checkNoVerdicts(verdicts)

  test "one mirrored step matches where the pressure clamp binds":
    var fluid = shippedFluid()
    fluid.restDensity = SPH_REST_DENSITY_MIN
    fluid.stiffness = SPH_STIFFNESS_MAX
    let reading = mirrorStep("clamped", fluid)
    checkpoint($reading.expectation.clampedPairs & " clamped pairs")
    check reading.expectation.clampedPairs > 0
    checkNoVerdicts(reading.verdicts)

  test "one mirrored step matches at each arm's side":
    var verdicts: Verdicts
    for arm in fluidArms():
      verdicts.add mirrorStep($arm.term & " reference", arm.reference).verdicts
      for index, step in arm.steps:
        verdicts.add mirrorStep($arm.term & " step " & $index, step).verdicts
    checkNoVerdicts(verdicts)

  test "the frame factor and friction meet the fluid's delta only in integrate":
    var verdicts: Verdicts
    verdicts.add mirrorStep("frame factor 2", shippedFluid(),
      frameFactor = 2.0).verdicts
    verdicts.add mirrorStep("retention 0.9", shippedFluid(),
      retention = 0.9'f32).verdicts
    checkNoVerdicts(verdicts)

  test "the summed velocity delta rejoins both words, so a fluid step sums to its quantization":
    # Each pair's integer is negated for the other side, so the sum departs
    # from zero only by the truncation at each encode and the f32 rounding of
    # each own register.
    var world = stirredWorld(fluidOnlyParams(shippedFluid()), FLUID_TEST_SEED)
    let expected = expectFluid(world)
    stepFrame(world, 1.0, 1)
    let scale = PRODUCTION_TUNING.fixedPointScale
    var allowed = (x: 0.0, y: 0.0)
    for i in 0 ..< expected.pairs.len:
      allowed.x += expected.pairs[i].float + 2.0 +
        abs(expected.ownRegister[i].x) * scale * F32_ROUNDING
      allowed.y += expected.pairs[i].float + 2.0 +
        abs(expected.ownRegister[i].y) * scale * F32_ROUNDING
    let summed = summedVelocityDelta(world)
    checkpoint("summed " & $summed & " quanta, allowed " & $allowed)
    check abs(summed.x) <= allowed.x
    check abs(summed.y) <= allowed.y

  test "at strength zero the pass is skipped and no velocity moves":
    var fluid = shippedFluid()
    fluid.strength = 0.0
    var world = stirredWorld(fluidOnlyParams(fluid), FLUID_TEST_SEED)
    let before = world
    stepFrame(world, 1.0, 1)
    check world.velX == before.velX
    check world.velY == before.velY
    for density in world.sphDensity:
      check density == 0.0'f32

suite "Each Effect Is Read Alone":

  test "each step differs from the side it is compared with in the arm's term alone":
    for arm in fluidArms():
      for step in arm.steps:
        checkpoint($arm.term & ": " & $differingFields(arm.reference, step))
        check differingFields(arm.reference, step) == @[$arm.term]

  test "every side and its fluid-zero world share one species and world setting":
    for arm in fluidArms():
      var fluidZero = arm.reference
      fluidZero.strength = 0.0
      let zeroWorld = armWorldParams(fluidZero, MAX_PARTICLES)
      for side in @[arm.reference] & arm.steps:
        check differingFields(armWorldParams(side, MAX_PARTICLES),
          zeroWorld) == @["fluid"]
        check differingFields(side, fluidZero) == @["strength"] or
          differingFields(side, fluidZero) == @["strength", $arm.term]

  test "every side runs fluid 1 over crowding 0 with the world pressure acting":
    for arm in fluidArms():
      for side in @[arm.reference] & arm.steps:
        let world = armWorldParams(side, MAX_PARTICLES)
        check side.strength == FLUID_STRENGTH_MAX
        check world.crowdingStrength == 0.0'f32
        check world.pressureStiffness > 0.0'f32
        if arm.term == ftBlend:
          check side.viscosity == SPH_VISCOSITY_MIN

  test "each arm's term moves one mirrored step and the blend and pressure leave the density alone":
    var verdicts: Verdicts
    for arm in fluidArms():
      var reference = stirredWorld(fluidOnlyParams(arm.reference),
        FLUID_TEST_SEED)
      stepFrame(reference, 1.0, 1)
      for index, step in arm.steps:
        var stepped = stirredWorld(fluidOnlyParams(step), FLUID_TEST_SEED)
        stepFrame(stepped, 1.0, 1)
        let label = $arm.term & " step " & $index
        if stepped.velX == reference.velX and stepped.velY == reference.velY:
          verdicts.add label & ": both sides step every velocity alike, " &
            "so the arm reads no effect"
        if arm.term != ftRadiusFraction and
            stepped.sphDensity != reference.sphDensity:
          verdicts.add label & ": the " & $arm.term &
            " moved the kernel density, which it has no part in"
    checkNoVerdicts(verdicts)

# The fluid arms themselves step 128 000-particle worlds for 900 frames, so
# they sit behind `calibrateFluid`, which only `just calibrate-fluid` sets. A
# test-name filter (`'The Blend Arm::*'`) runs one arm alone, and
# `-d:calibrateSmoke` runs a reduced world that proves the arm runs and records
# nothing. The arms report and assert no gate.

when defined(calibrateFluid):
  import std/[strutils, tables, times, typedthreads]
  import ../src/sim_registry

  const
    FLUID_SEEDS = [42, 7, 1001]
    FLUID_PARTICLES =
      when defined(calibrateSmoke): 8_000 else: MAX_PARTICLES
    FLUID_FRAME_DIVISOR = when defined(calibrateSmoke): 15 else: 1

  func fluidScaled(frames: int): int = max(frames div FLUID_FRAME_DIVISOR, 1)

  const
    FLUID_STEPS = fluidScaled(900)
    FLUID_WINDOW = [fluidScaled(750) - 1, fluidScaled(800) - 1,
      fluidScaled(850) - 1, fluidScaled(900) - 1]
      ## 749, 799, 849 and 899 in the recipe.

  func fluidSpeciesCount(): int = defaultSettings().speciesCount

  func selfAttraction(speciesCount: int): seq[float32] =
    ## Each species attracting itself at the matrix maximum and indifferent
    ## to the rest, so the fluid-zero world sorts by species and sigma's
    ## denominator stands clear of zero.
    for row in 0 ..< speciesCount:
      for column in 0 ..< speciesCount:
        result.add (if row == column: MATRIX_MAX_VALUE.float32 else: 0.0'f32)

  func armPlan(fluid: OracleFluidParams): SubstepPlan =
    ## What the app's plan runs for this fluid at frame factor 1: the count
    ## and the effective stiffness follow the radius fraction and stiffness.
    let shipped = defaultSettings()
    substepPlan(1.0, LiveValues(
      forces: shipped.forceStrength, fluid: fluid.strength, scent: 0.0,
      deposit: 0.0, bodies: 0.0, longRange: 0.0,
      maxVelocity: shipped.maxVelocity,
      interactionRadius: FLUID_ARM_RADIUS,
      sphRadiusFraction: fluid.radiusFraction,
      sphStiffness: fluid.stiffness,
      timeScale: shipped.timeScale,
      bodyBand: BODY_DEFAULT_BAND, bodyLive: false))

  type
    FluidRun = object
      params: OracleParams
      substeps: int
      seed: int

    FluidReading = object
      share: float
        ## S: the mean share of a particle's proximity-weighted neighbours
        ## that are its own species, over the window.
      variation: float
        ## The coefficient of variation of the crowd density, over the window.
      kernelNeighbours: float
        ## The mean kernel density less the particle's own weight at the last
        ## window step: zero where the kernel meets no neighbour.

  func planned(fluid: OracleFluidParams; seed: int): FluidRun =
    let plan = armPlan(fluid)
    var effective = fluid
    effective.stiffness = plan.effStiffness
    var params = armWorldParams(effective, FLUID_PARTICLES)
    params.maxVelocity = plan.effMaxVelocity.float32
    FluidRun(params: params, substeps: plan.count, seed: seed)

  func ownSpeciesShare(world: OracleWorld): float =
    var counted = 0
    for i in 0 ..< world.crowdDensity.len:
      if world.crowdDensity[i] > 0.0'f32:
        result += world.colonyDensity[i].float / world.crowdDensity[i].float
        counted += 1
    if counted > 0:
      result /= counted.float

  func crowdVariation(world: OracleWorld): float =
    let mean = meanWeightedNeighbours(world)
    var spread = 0.0
    for value in world.crowdDensity:
      spread += (value.float - mean) * (value.float - mean)
    sqrt(spread / world.crowdDensity.len.float) / mean

  proc runFluid(run: FluidRun): FluidReading {.gcsafe.} =
    let speciesCount = fluidSpeciesCount()
    var world = initOracleWorld(run.params, FLUID_PARTICLES, speciesCount,
      selfAttraction(speciesCount), run.seed)
    for step in 0 ..< FLUID_STEPS:
      stepFrame(world, 1.0, run.substeps)
      if step in FLUID_WINDOW:
        result.share += ownSpeciesShare(world)
        result.variation += crowdVariation(world)
    result.share /= FLUID_WINDOW.len.float
    result.variation /= FLUID_WINDOW.len.float
    for density in world.sphDensity:
      result.kernelNeighbours += density.float - 1.0
    result.kernelNeighbours /= world.sphDensity.len.float

  type FluidSlot = object
    run: FluidRun
    output: ptr FluidReading

  proc runFluidSlot(slot: FluidSlot) {.thread.} =
    slot.output[] = runFluid(slot.run)

  var fluidMemo: Table[string, FluidReading]
    ## The fluid-zero worlds every arm reads against step once per process.

  proc fluidReadings(runs: seq[FluidRun]): seq[FluidReading] =
    ## Every run not yet stepped in this process, stepped at once, one thread
    ## each.
    var missing: seq[FluidRun]
    for run in runs:
      if $run notin fluidMemo and run notin missing:
        missing.add run
    var stepped = newSeq[FluidReading](missing.len)
    var threads = newSeq[Thread[FluidSlot]](missing.len)
    let started = epochTime()
    for i in 0 ..< missing.len:
      createThread(threads[i], runFluidSlot,
        FluidSlot(run: missing[i], output: addr stepped[i]))
    joinThreads(threads)
    echo "  stepped ", missing.len, " worlds of ", FLUID_PARTICLES,
      " particles for ", FLUID_STEPS, " frames in ",
      formatFloat(epochTime() - started, ffDecimal, 1), " s"
    for i, run in missing:
      fluidMemo[$run] = stepped[i]
    for run in runs:
      result.add fluidMemo[$run]

  func shown(value: float): string = formatFloat(value, ffDecimal, 4)

  func meanAndSpread(values: seq[float]): tuple[mean, spread: float] =
    ## The mean and the largest single seed's distance from it (design C5).
    for value in values:
      result.mean += value
    result.mean /= values.len.float
    for value in values:
      result.spread = max(result.spread, abs(value - result.mean))

  func sideLabel(term: FluidTerm; side: OracleFluidParams): string =
    case term
    of ftBlend: "blend " & $side.blend
    of ftPressureGain: "pressure gain " & $side.pressureGain
    of ftRadiusFraction: "radius fraction " & $side.radiusFraction

  proc reportArm(arm: FluidArm) =
    ## sigma and E for every side against the fluid-zero world, per seed and
    ## as the three-seed mean, and whether each step's mean sigma is not
    ## lower than the reference's.
    let speciesCount = fluidSpeciesCount()
    let chance = 1.0 / speciesCount.float
    let sides = @[arm.reference] & arm.steps
    var fluidZero = arm.reference
    fluidZero.strength = 0.0
    var runs: seq[FluidRun]
    for seed in FLUID_SEEDS:
      runs.add planned(fluidZero, seed)
    for side in sides:
      for seed in FLUID_SEEDS:
        runs.add planned(side, seed)
    let zeroRun = runs[0]
    echo "  ", FLUID_PARTICLES, " particles, radius ", FLUID_ARM_RADIUS,
      ", Force Strength ", FLUID_ARM_FORCE_STRENGTH, " (force multiplier ",
      zeroRun.params.forceMultiplier, "), crowding ",
      zeroRun.params.crowdingStrength, ", world pressure K ",
      zeroRun.params.pressureStiffness, " at onset ratio ", ONSET_RATIO,
      " (onset density ", shown(zeroRun.params.pressureOnset.float), ")"
    echo "  ", speciesCount, " species, each attracting itself at ",
      MATRIX_MAX_VALUE, " and indifferent to the rest; ", FLUID_STEPS,
      " frames at frame factor 1, window ", FLUID_WINDOW, "; seeds ",
      FLUID_SEEDS
    let readings = fluidReadings(runs)
    let zero = readings[0 ..< FLUID_SEEDS.len]
    for i, seed in FLUID_SEEDS:
      echo "  fluid 0, seed ", seed, ": S ", shown(zero[i].share),
        ", crowd variation ", shown(zero[i].variation)
      checkpoint("seed " & $seed & ": fluid-zero S " & $zero[i].share &
        " against chance " & $chance)
      check zero[i].share > chance
    var sigmaMeans: seq[float]
    for index, side in sides:
      let plan = armPlan(side)
      echo "  ", (if index == 0: "reference " else: "step "),
        sideLabel(arm.term, side), ": ", plan.count,
        " substeps, effective stiffness ", shown(plan.effStiffness)
      var sigmas, evens: seq[float]
      for i, seed in FLUID_SEEDS:
        let reading = readings[FLUID_SEEDS.len * (index + 1) + i]
        let sigma = (reading.share - chance) / (zero[i].share - chance)
        let evenness = reading.variation / zero[i].variation
        sigmas.add sigma
        evens.add evenness
        echo "    seed ", seed, ": S ", shown(reading.share), ", sigma ",
          shown(sigma), ", E ", shown(evenness), ", kernel neighbours ",
          shown(reading.kernelNeighbours)
        check sigma == sigma and evenness == evenness
      let sigma = meanAndSpread(sigmas)
      let evenness = meanAndSpread(evens)
      echo "    mean sigma ", shown(sigma.mean), " (largest seed distance ",
        shown(sigma.spread), "), mean E ", shown(evenness.mean),
        " (largest seed distance ", shown(evenness.spread), ")"
      sigmaMeans.add sigma.mean
    for index in 1 ..< sides.len:
      echo "  ", sideLabel(arm.term, sides[index]), ": mean sigma ",
        shown(sigmaMeans[index]),
        (if sigmaMeans[index] >= sigmaMeans[0]: " is not lower than "
         else: " is lower than "), sideLabel(arm.term, sides[0]), "'s ",
        shown(sigmaMeans[0])

  suite "The Blend Arm":
    test "the blend at SPH_XSPH_EPSILON against 0, at Viscosity 0":
      reportArm(fluidArms()[ftBlend])

  suite "The Pressure Arm":
    test "the pressure gain at SPH_FORCE_SCALE against 0":
      reportArm(fluidArms()[ftPressureGain])

  suite "The Radius Fraction Arm":
    test "radius fraction 1 against 0.75, 0.5, 0.25 and 0.1":
      reportArm(fluidArms()[ftRadiusFraction])

# ==============================================================================
# T5a-T5d: THE STEP LIMIT BOUNDS EACH MODE BY ITS SIGN
# (crowding-redesign design §8, addendum of 21-09-2026 23:50)
# ==============================================================================
# An oracle independent of stepLimit's own formula: a finite-difference
# Jacobian of the float pressure force, checked against the analytic sum
# sweepPairs accumulates. Fixed phi = ((x - x_on)/x_on)^2 (addendum, Decision
# 2(b)): every particle in a trial crowd shares one density at the pressure
# law's own onset ratio, so the pressure between any pair depends only on
# their positions, not on a simulated smoothed density.
#
# The addendum's proof splits a mode by the sign of its stiffness: a
# restoring mode (lambda >= 0) is bounded by the particle's radial slope D
# (T5a); a sliding mode (lambda < 0) is the transverse pair term's own
# physical growth, which D does not bound, so the limit's claim there is only
# that it never amplifies the mode past the unlimited map's own radius, and
# never grows it faster per reference frame past ff 1 than at ff 1 (T5b).
# T5c holds the same split on the full coupled Hessian, and T5d confirms the
# crowds are hard enough to break the restoring bound when the limit is off.

const
  T5_FRAME_FACTORS = [0.42'f64, 1.0'f64, 2.0'f64, 4.2'f64, 10.0'f64, 30.0'f64]
  T5_RETENTIONS = [1.0'f64, 0.95'f64]
  T5_RADII = [10.0'f64, 50.0'f64, 150.0'f64]
  T5_TRIALS = 20
  T5_PARTICLES = 200
  T5C_TRIALS = 6
  T5C_PARTICLES = 60
  T5_EPS = 1.0e-3'f64
  T5_TOL = 1.0e-6'f64

func pressureForceOn(xs, ys: seq[float64]; i: int; worldSize, radius, phi,
    stiffness, impulseMax: float64): tuple[x, y: float64] =
  ## The float pressure force physics_core.worldPressureMagnitude gives
  ## particle `i` from every neighbour within `radius`, at the same distance
  ## floor sweepPairs reads (PRODUCTION_TUNING.minDistanceSq).
  let half = worldSize * 0.5
  let floorSq = PRODUCTION_TUNING.minDistanceSq
  for j in 0 ..< xs.len:
    if j == i: continue
    let dx = wrapDelta((xs[j] - xs[i]).float32, worldSize.float32,
      half.float32).float64
    let dy = wrapDelta((ys[j] - ys[i]).float32, worldSize.float32,
      half.float32).float64
    let distSq = dx * dx + dy * dy
    if distSq <= 0.0 or distSq >= radius * radius: continue
    let dist = sqrt(max(distSq, floorSq))
    let invDist = 1.0 / dist
    let normalizedDist = dist / radius
    let magnitude = worldPressureMagnitude(phi.float32, phi.float32,
      normalizedDist.float32, stiffness.float32, impulseMax.float32).float64
    result.x += -magnitude * dx * invDist
    result.y += -magnitude * dy * invDist

func blockEigenvalues(xs, ys: seq[float64]; i: int; worldSize, radius, phi,
    stiffness, impulseMax: float64): array[2, float64] =
  ## The two eigenvalues of the symmetrized central-difference 2x2 Jacobian
  ## of pressureForceOn with particle `i`'s own position: the local
  ## restoring or sliding "spring constant" a linearization around this
  ## crowd sees, split by sign in T5a/T5b.
  var plusXxs = xs
  plusXxs[i] += T5_EPS
  var minusXxs = xs
  minusXxs[i] -= T5_EPS
  var plusYys = ys
  plusYys[i] += T5_EPS
  var minusYys = ys
  minusYys[i] -= T5_EPS
  let fPlusX = pressureForceOn(plusXxs, ys, i, worldSize, radius, phi,
    stiffness, impulseMax)
  let fMinusX = pressureForceOn(minusXxs, ys, i, worldSize, radius, phi,
    stiffness, impulseMax)
  let fPlusY = pressureForceOn(xs, plusYys, i, worldSize, radius, phi,
    stiffness, impulseMax)
  let fMinusY = pressureForceOn(xs, minusYys, i, worldSize, radius, phi,
    stiffness, impulseMax)
  let inv2Eps = 1.0 / (2.0 * T5_EPS)
  let xx = -(fPlusX.x - fMinusX.x) * inv2Eps
  let xy = -(fPlusY.x - fMinusY.x) * inv2Eps
  let yx = -(fPlusX.y - fMinusX.y) * inv2Eps
  let yy = -(fPlusY.y - fMinusY.y) * inv2Eps
  let sxy = 0.5 * (xy + yx)
  let trace = xx + yy
  let diff = sqrt(max(0.0, ((xx - yy) * 0.5) ^ 2 + sxy * sxy))
  [trace * 0.5 + diff, trace * 0.5 - diff]

func pressureStiffnessSum(xs, ys: seq[float64]; i: int; worldSize, radius,
    phi, stiffness, impulseMax: float64): float64 =
  ## D_i: the sum sweepPairs accumulates for particle `i`.
  let half = worldSize * 0.5
  let invRadius = 1.0 / radius
  for j in 0 ..< xs.len:
    if j == i: continue
    let dx = wrapDelta((xs[j] - xs[i]).float32, worldSize.float32,
      half.float32).float64
    let dy = wrapDelta((ys[j] - ys[i]).float32, worldSize.float32,
      half.float32).float64
    let distSq = dx * dx + dy * dy
    if distSq <= 0.0 or distSq >= radius * radius: continue
    result += pairStiffnessSlope(phi.float32, phi.float32, stiffness.float32,
      impulseMax.float32, invRadius.float32).float64

func fullHessian(xs, ys: seq[float64]; worldSize, radius, phi, stiffness,
    impulseMax: float64): seq[seq[float64]] =
  ## The unsymmetrized central-difference Hessian of the full crowd's
  ## pressure force, row `2*i + axis` holding particle i's force response to
  ## the perturbed coordinate in column order [x0, y0, x1, y1, ...].
  let n = xs.len
  result = newSeq[seq[float64]](2 * n)
  for row in 0 ..< 2 * n: result[row] = newSeq[float64](2 * n)
  for col in 0 ..< 2 * n:
    var xp = xs
    var xm = xs
    var yp = ys
    var ym = ys
    let k = col div 2
    if col mod 2 == 0: xp[k] += T5_EPS; xm[k] -= T5_EPS
    else: yp[k] += T5_EPS; ym[k] -= T5_EPS
    for i in 0 ..< n:
      let fp = pressureForceOn(xp, yp, i, worldSize, radius, phi, stiffness,
        impulseMax)
      let fm = pressureForceOn(xm, ym, i, worldSize, radius, phi, stiffness,
        impulseMax)
      result[2 * i][col] = -(fp.x - fm.x) / (2.0 * T5_EPS)
      result[2 * i + 1][col] = -(fp.y - fm.y) / (2.0 * T5_EPS)

func jacobiEigen(a: var seq[seq[float64]]): seq[float64] =
  ## Eigenvalues of a symmetric matrix by cyclic Jacobi rotation: the
  ## off-diagonal sum shrinks monotonically to zero, leaving the diagonal as
  ## the spectrum (Golub & Van Loan, "Matrix Computations", the classical
  ## Jacobi eigenvalue algorithm).
  let n = a.len
  for sweep in 0 ..< 60:
    var off = 0.0
    for p in 0 ..< n:
      for q in p + 1 ..< n: off += a[p][q] * a[p][q]
    if off < 1e-22: break
    for p in 0 ..< n:
      for q in p + 1 ..< n:
        if abs(a[p][q]) < 1e-300: continue
        let theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q])
        let t = (if theta >= 0: 1.0 else: -1.0) /
          (abs(theta) + sqrt(theta * theta + 1.0))
        let cs = 1.0 / sqrt(t * t + 1.0)
        let sn = t * cs
        for k in 0 ..< n:
          let akp = a[k][p]
          let akq = a[k][q]
          a[k][p] = cs * akp - sn * akq
          a[k][q] = sn * akp + cs * akq
        for k in 0 ..< n:
          let apk = a[p][k]
          let aqk = a[q][k]
          a[p][k] = cs * apk - sn * aqk
          a[q][k] = sn * apk + cs * aqk
  for i in 0 ..< n: result.add a[i][i]

func rho(kappa, retention: float64): float64 =
  ## The larger |root| of mu^2 - (1 + r - r*kappa) mu + r = 0, the
  ## characteristic polynomial of the one-step map v' = r(v - kappa*x),
  ## x' = x + v' for a mode of stiffness kappa = ff*s*lambda (addendum,
  ## Decision 1).
  let t = 1.0 + retention - retention * kappa
  let disc = t * t - 4.0 * retention
  if disc >= 0.0:
    max(abs((t + sqrt(disc)) * 0.5), abs((t - sqrt(disc)) * 0.5))
  else:
    sqrt(retention)

type T5Crowd = object
  xs, ys: seq[float64]
  worldSize, radius, phi: float64

func t5Crowd(seed, particles: int): T5Crowd =
  ## `particles` placed uniformly at random, at a radius from {10, 50, 150}
  ## and a crowd ratio x from [7, 16] (crowding-redesign design §8). The
  ## world spans the area whose mean crowd density (N pi R^2 / 3A, the same
  ## expression meanCrowdDensity uses) equals x at onset 1, so a uniformly
  ## placed particle's expected neighbour-weighted density matches phi. phi
  ## is the pressure law's own ratio to the onset (addendum, Decision 2(b)),
  ## not the onset-at-1 approximation the unaddended T5 used.
  var rng = initRand(seed)
  let radius = T5_RADII[rng.rand(0 .. 2)]
  let x = rng.rand(7.0 .. 16.0)
  let worldSize = radius * sqrt(particles.float64 * PI / (3.0 * x))
  var xs = newSeq[float64](particles)
  var ys = newSeq[float64](particles)
  for i in 0 ..< particles:
    xs[i] = rng.rand(0.0 .. worldSize)
    ys[i] = rng.rand(0.0 .. worldSize)
  let ratio = (x - ONSET_RATIO) / ONSET_RATIO
  T5Crowd(xs: xs, ys: ys, worldSize: worldSize, radius: radius,
    phi: ratio * ratio)

suite "A Limited Step Cannot Overshoot":

  test "a restoring mode stays inside the bound (T5a)":
    var verdicts: Verdicts
    for trial in 0 ..< T5_TRIALS:
      let crowd = t5Crowd(trial, T5_PARTICLES)
      for i in 0 ..< crowd.xs.len:
        let lams = blockEigenvalues(crowd.xs, crowd.ys, i, crowd.worldSize,
          crowd.radius, crowd.phi, WORLD_PRESSURE_STIFFNESS,
          WORLD_PRESSURE_IMPULSE_MAX)
        let d = pressureStiffnessSum(crowd.xs, crowd.ys, i, crowd.worldSize,
          crowd.radius, crowd.phi, WORLD_PRESSURE_STIFFNESS,
          WORLD_PRESSURE_IMPULSE_MAX)
        for frameFactor in T5_FRAME_FACTORS:
          let s = stepLimit(frameFactor.float32, d.float32,
            PRESSURE_STEP_BOUND.float32).float64
          for lam in lams:
            if lam < 0.0: continue
            let kappa = frameFactor * s * lam
            if kappa > PRESSURE_STEP_BOUND * 0.5 * (1.0 + T5_TOL):
              verdicts.add "trial " & $trial & " particle " & $i & " ff " &
                $frameFactor & ": restoring ff*s*lambda " & $kappa &
                " passes theta/2 " & $(PRESSURE_STEP_BOUND * 0.5)
    checkNoVerdicts(verdicts)

  test "the limit never speeds a sliding mode (T5b)":
    var verdicts: Verdicts
    for trial in 0 ..< T5_TRIALS:
      let crowd = t5Crowd(trial, T5_PARTICLES)
      for i in 0 ..< crowd.xs.len:
        let lams = blockEigenvalues(crowd.xs, crowd.ys, i, crowd.worldSize,
          crowd.radius, crowd.phi, WORLD_PRESSURE_STIFFNESS,
          WORLD_PRESSURE_IMPULSE_MAX)
        let d = pressureStiffnessSum(crowd.xs, crowd.ys, i, crowd.worldSize,
          crowd.radius, crowd.phi, WORLD_PRESSURE_STIFFNESS,
          WORLD_PRESSURE_IMPULSE_MAX)
        let s1 = stepLimit(1.0'f32, d.float32, PRESSURE_STEP_BOUND.float32).float64
        for lam in lams:
          if lam >= 0.0: continue
          for retention in T5_RETENTIONS:
            let kappaOne = 1.0 * s1 * lam
            let refGrowth = ln(rho(kappaOne, retention))
            for frameFactor in T5_FRAME_FACTORS:
              let s = stepLimit(frameFactor.float32, d.float32,
                PRESSURE_STEP_BOUND.float32).float64
              let limited = rho(frameFactor * s * lam, retention)
              let unlimited = rho(frameFactor * lam, retention)
              if limited > unlimited * (1.0 + T5_TOL):
                verdicts.add "trial " & $trial & " particle " & $i & " ff " &
                  $frameFactor & " retention " & $retention &
                  ": limited radius " & $limited &
                  " exceeds the unlimited map's " & $unlimited
              if frameFactor >= 1.0:
                let growth = ln(limited) / frameFactor
                if growth > refGrowth * (1.0 + T5_TOL) + 1e-15:
                  verdicts.add "trial " & $trial & " particle " & $i &
                    " ff " & $frameFactor & " retention " & $retention &
                    ": growth per reference frame " & $growth &
                    " exceeds ff 1's " & $refGrowth
    checkNoVerdicts(verdicts)

  test "the coupled map keeps the bound (T5c)":
    var verdicts: Verdicts
    for trial in 0 ..< T5C_TRIALS:
      let crowd = t5Crowd(trial, T5C_PARTICLES)
      let n = crowd.xs.len
      let h = fullHessian(crowd.xs, crowd.ys, crowd.worldSize, crowd.radius,
        crowd.phi, WORLD_PRESSURE_STIFFNESS, WORLD_PRESSURE_IMPULSE_MAX)
      var d = newSeq[float64](n)
      for i in 0 ..< n:
        d[i] = pressureStiffnessSum(crowd.xs, crowd.ys, i, crowd.worldSize,
          crowd.radius, crowd.phi, WORLD_PRESSURE_STIFFNESS,
          WORLD_PRESSURE_IMPULSE_MAX)
      var referenceGrowth = 0.0
      for frameFactor in T5_FRAME_FACTORS:
        var a = newSeq[seq[float64]](2 * n)
        for row in 0 ..< 2 * n:
          a[row] = newSeq[float64](2 * n)
          for col in 0 ..< 2 * n:
            let si = stepLimit(frameFactor.float32, d[row div 2].float32,
              PRESSURE_STEP_BOUND.float32).float64
            let sj = stepLimit(frameFactor.float32, d[col div 2].float32,
              PRESSURE_STEP_BOUND.float32).float64
            a[row][col] = frameFactor * sqrt(si * sj) * 0.5 *
              (h[row][col] + h[col][row])
        let eig = jacobiEigen(a)
        var largest = -Inf
        var smallest = Inf
        for e in eig:
          largest = max(largest, e)
          smallest = min(smallest, e)
        if largest > PRESSURE_STEP_BOUND * (1.0 + T5_TOL):
          verdicts.add "trial " & $trial & " ff " & $frameFactor &
            ": largest coupled eigenvalue " & $largest & " passes theta " &
            $PRESSURE_STEP_BOUND
        if smallest < 0.0:
          let growth = ln(rho(smallest, 1.0)) / frameFactor
          if frameFactor == 1.0:
            referenceGrowth = growth
          elif frameFactor > 1.0 and
              growth > referenceGrowth * (1.0 + T5_TOL) + 1e-15:
            verdicts.add "trial " & $trial & " ff " & $frameFactor &
              ": most negative coupled mode's growth per reference frame " &
              $growth & " exceeds ff 1's " & $referenceGrowth
    checkNoVerdicts(verdicts)

  test "the unlimited control overshoots at frame factor 30 (T5d)":
    var blockExceeded = false
    for trial in 0 ..< T5_TRIALS:
      let crowd = t5Crowd(trial, T5_PARTICLES)
      for i in 0 ..< crowd.xs.len:
        let lams = blockEigenvalues(crowd.xs, crowd.ys, i, crowd.worldSize,
          crowd.radius, crowd.phi, WORLD_PRESSURE_STIFFNESS,
          WORLD_PRESSURE_IMPULSE_MAX)
        for retention in T5_RETENTIONS:
          for lam in lams:
            if lam >= 0.0 and 30.0 * lam > 2.0 * (1.0 + retention) / retention:
              blockExceeded = true
    var coupledExceeded = false
    for trial in 0 ..< T5C_TRIALS:
      let crowd = t5Crowd(trial, T5C_PARTICLES)
      let n = crowd.xs.len
      let h = fullHessian(crowd.xs, crowd.ys, crowd.worldSize, crowd.radius,
        crowd.phi, WORLD_PRESSURE_STIFFNESS, WORLD_PRESSURE_IMPULSE_MAX)
      var a = newSeq[seq[float64]](2 * n)
      for row in 0 ..< 2 * n:
        a[row] = newSeq[float64](2 * n)
        for col in 0 ..< 2 * n:
          a[row][col] = 30.0 * 0.5 * (h[row][col] + h[col][row])
      for e in jacobiEigen(a):
        if e > 4.0: coupledExceeded = true
    check blockExceeded
    check coupledExceeded

# ==============================================================================
# T7: A BALANCE HOLDS AT EVERY FRAME FACTOR (crowding-redesign design §8, "buys")
# ==============================================================================
# Integration, not calibration: a small enough world to run in `just test`,
# on the design's own reference world (radius 50, one self-attracting species
# at MATRIX_MAX_VALUE) held down to 2 000 particles, one body live for the
# whole run. What C4b keeps ("a static balance is unchanged by the limit")
# means the body compresses the crowd against it to the same peak, whatever
# the frame factor: the ratio of the two runs' final peak crowd density,
# meaned over the three gate seeds, does not exceed 1 (specs/coupling-
# contract/spec.md:183-187's convention, on peak density rather than motion).

const
  T7_PARTICLES = 2_000
  T7_SEEDS = [42, 7, 1001]
  T7_STEPS = 900
  T7_HELD_FF = 30.0
  T7_FREE_FF = 0.25

func t7Params(): OracleParams =
  let shipped = defaultSettings()
  var cfg = referenceConfig()
  cfg.particleCount = T7_PARTICLES
  OracleParams(
    interactionRadius: cfg.interactionRadius.float32,
    worldWidth: cfg.worldWidth.float32, worldHeight: cfg.worldHeight.float32,
    minDistanceSq: PRODUCTION_TUNING.minDistanceSq.float32,
    forceModel: ofmPolynomial,
    forceMultiplier: shipped.forceStrength.float32,
    repulsionEnd: shipped.repulsionEnd.float32,
    attractionPeak: shipped.attractionPeak.float32,
    expAlpha: shipped.expRepulsionAlpha.float32,
    expBeta: shipped.expAttractionBeta.float32,
    crowdingStrength: 0.0'f32,
    pressureOnset: crowdOnsetDensity(cfg).float32,
    pressureStiffness: WORLD_PRESSURE_STIFFNESS.float32,
    pressureImpulseMax: WORLD_PRESSURE_IMPULSE_MAX.float32,
    pressureStepBound: PRESSURE_STEP_BOUND.float32,
    stiffnessFixedPointScale: STIFFNESS_FIXED_POINT_SCALE.float32,
    stiffnessCoarseShift: STIFFNESS_COARSE_SHIFT,
    friction: (1.0 - shipped.friction).float32,
    maxVelocity: shipped.maxVelocity.float32,
    fixedPointScale: PRODUCTION_TUNING.fixedPointScale.float32,
    crowdDensityScale: sphDensityFixedPointScale(MAX_PARTICLES).float32,
    densitySmoothFactor: PRODUCTION_TUNING.densitySmoothFactor.float32,
    bodiesStrength: BODIES_DEFAULT_STRENGTH,
    fluid: OracleFluidParams(strength: 0.0, coarseShift: VELOCITY_COARSE_SHIFT))

func t7Body(): Body =
  let masses = bodyInverseMasses(BODY_DEFAULT_RADIUS, 1.0)
  Body(centerX: BODY_WORLD_W * 0.5, centerY: BODY_WORLD_H * 0.5,
    radius: BODY_DEFAULT_RADIUS, anisotropy: 1.0,
    bandWidth: BODY_DEFAULT_BAND,
    proximity: BODY_PROXIMITY_MAX, enclosure: BODY_ENCLOSURE_MAX,
    invMass: masses.invMass, invInertia: masses.invInertia)

func t7PeakDensity(frameFactor: float; seed: int): float =
  var world = initOracleWorld(t7Params(), T7_PARTICLES, 1,
    @[MATRIX_MAX_VALUE.float32], seed)
  world.bodies = @[t7Body()]
  world.bodyEnvelopes = @[1.0]
  for _ in 0 ..< T7_STEPS:
    stepFrame(world, frameFactor, 1)
  peakCrowdDensity(world)

suite "A Balance Holds At Every Frame Factor":

  test "a held crowd settles to the same peak density at ff 30 as at ff 0.25 (T7)":
    var ratios: seq[float]
    for seed in T7_SEEDS:
      let held = t7PeakDensity(T7_HELD_FF, seed)
      let free = t7PeakDensity(T7_FREE_FF, seed)
      ratios.add held / free
    var meanRatio = 0.0
    for ratio in ratios: meanRatio += ratio
    meanRatio /= ratios.len.float
    checkpoint "peak-density ratios by seed: " & $ratios
    check meanRatio <= 1.0

# ==============================================================================
# THE CALIBRATION ARMS
# ==============================================================================
# Each arm steps the oracle world at 128 000 particles for hundreds of frames on
# the three gate seeds, so every arm sits behind `calibrateBalance`, outside the
# suite `just test` compiles. Each test holds its own work, so a test-name
# filter on the command line (`'Suite Name::*'`) runs one arm alone.

when defined(calibrateBalance):
  import std/[algorithm, strutils, tables, typedthreads]
  import ../src/preset
  import ../src/sim_registry

  const
    GATE_SEEDS = [42, 7, 1001]
    SMOKE_PARTICLES = 8_000
    CALIBRATION_PARTICLES {.intdefine: "calibrateParticles".} =
      when defined(calibrateSmoke): SMOKE_PARTICLES else: MAX_PARTICLES
    FRAME_DIVISOR = when defined(calibrateSmoke): 15 else: 1
      ## A smoke run steps this fraction of the recipe's frames. Its readings
      ## show the arm runs and say nothing about the values it records.
    CALIBRATION_RADIUS = 50.0
    ONSET_RATIO_OVERRIDE {.strdefine: "calibrateOnsetRatio".} = ""
    CALIBRATION_ONSET_RATIO =
      if ONSET_RATIO_OVERRIDE.len == 0: CROWD_ONSET_RATIO
      else: parseFloat(ONSET_RATIO_OVERRIDE)
      ## x_on for every arm the term acts in, so the stacked hold can run at
      ## the onset G1.1 records before config_ranges holds it.

  func scaled(frames: int): int = max(frames div FRAME_DIVISOR, 1)

  const
    SETTLE_FRAMES = scaled(600)
      ## Frames a world runs before a body touches it, so the hold acts on a
      ## settled crowd rather than on uniform noise.
    HOLD_FRAMES = scaled(100)
    RELAXATION_FRAMES = scaled(900)
    STEP_COUNT = scaled(900)
    WINDOW_STEPS = [scaled(750) - 1, scaled(800) - 1, scaled(850) - 1,
      scaled(900) - 1]
      ## The late window every settle statistic is read on: 749, 799, 849 and
      ## 899 in the recipe.
    SETTLE_BOUND = WORLD_PRESSURE_SETTLE_BOUND
    FAR_SPEED_MARGIN = 0.0734
      ## How much faster the crowd beyond a body's reach may run while the
      ## stacked bodies hold, as a fraction of the same seed's no-body run: G1.3's
      ## mean ratio 0.9316 plus its largest seed distance 0.1419, less 1.
    STACK_CLEARANCE = 2.0 * BODY_DEFAULT_BAND
      ## Enclosure falls to exactly zero at twice the band
      ## (src/body_core.nim:376-380), so past this a stacked body hands a
      ## particle nothing and the crowd out there is the far crowd.

  func meanOf(values: seq[float]): float =
    for value in values:
      result += value
    result /= values.len.float

  func largestDistance(values: seq[float]): float =
    let centre = meanOf(values)
    for value in values:
      result = max(result, abs(value - centre))

  func derivedBound(values: seq[float]): float =
    ## design C5: a run's mean plus its largest single seed's distance from it.
    meanOf(values) + largestDistance(values)

  func calibrationConfig(): UnitConfig =
    let shipped = defaultSettings()
    result = referenceConfig()
    result.particleCount = CALIBRATION_PARTICLES
    result.interactionRadius = CALIBRATION_RADIUS
    result.onsetRatio = CALIBRATION_ONSET_RATIO
    result.repulsionEnd = shipped.repulsionEnd
    result.attractionPeak = shipped.attractionPeak

  func oracleParams(sliderFriction, pressureStiffness,
      bodiesStrength: float): OracleParams =
    ## The shipped world at radius 50 and the calibration particle count, with
    ## the three numbers each arm varies passed in. `sliderFriction` is the
    ## slider's value, which reaches the integrator as the retention factor one
    ## minus it (src/app.nim:193), applied once per step.
    let shipped = defaultSettings()
    let cfg = calibrationConfig()
    OracleParams(
      interactionRadius: cfg.interactionRadius.float32,
      worldWidth: cfg.worldWidth.float32, worldHeight: cfg.worldHeight.float32,
      minDistanceSq: PRODUCTION_TUNING.minDistanceSq.float32,
      forceModel: ofmPolynomial,
      forceMultiplier: shipped.forceStrength.float32,
      repulsionEnd: cfg.repulsionEnd.float32,
      attractionPeak: cfg.attractionPeak.float32,
      expAlpha: shipped.expRepulsionAlpha.float32,
      expBeta: shipped.expAttractionBeta.float32,
      crowdingStrength: shipped.crowdingStrength.float32,
      pressureOnset: crowdOnsetDensity(cfg).float32,
      pressureStiffness: pressureStiffness.float32,
      pressureImpulseMax: WORLD_PRESSURE_IMPULSE_MAX.float32,
      pressureStepBound: PRESSURE_STEP_BOUND.float32,
      stiffnessFixedPointScale: STIFFNESS_FIXED_POINT_SCALE.float32,
      stiffnessCoarseShift: STIFFNESS_COARSE_SHIFT,
      friction: (1.0 - sliderFriction).float32,
      maxVelocity: shipped.maxVelocity.float32,
      fixedPointScale: PRODUCTION_TUNING.fixedPointScale.float32,
      crowdDensityScale: sphDensityFixedPointScale(MAX_PARTICLES).float32,
      densitySmoothFactor: PRODUCTION_TUNING.densitySmoothFactor.float32,
      bodiesStrength: bodiesStrength)

  func liveValues(bodiesLive: bool): LiveValues =
    ## What the substep rule reads for these arms: the species term acting,
    ## every other coupling silent, and the bodies live only while they hold.
    let shipped = defaultSettings()
    LiveValues(
      forces: shipped.forceStrength, fluid: 0.0, scent: 0.0, deposit: 0.0,
      bodies: (if bodiesLive: BODIES_DEFAULT_STRENGTH else: 0.0),
      longRange: 0.0,
      maxVelocity: shipped.maxVelocity,
      interactionRadius: CALIBRATION_RADIUS,
      sphRadiusFraction: shipped.sphRadiusFraction,
      sphStiffness: shipped.sphStiffness,
      timeScale: shipped.timeScale,
      bodyBand: BODY_DEFAULT_BAND,
      bodyLive: bodiesLive)

  static:
    # The arms below step every schedule at one substep: with no fluid
    # acting and no live body, substepPlan asks for no more (integrate's step
    # limit, crowding-redesign design §3.4, holds every frame factor stable
    # without a substep count of its own).
    for frameFactor in 1 .. 30:
      doAssert substepPlan(frameFactor.float, liveValues(false)).count == 1,
        "a species-only world asks for more than one substep at frame " &
          "factor " & $frameFactor

  func attractingMatrix(speciesCount: int): seq[float32] =
    ## Each species attracting itself at the matrix maximum and indifferent to
    ## the rest. With every entry at the maximum and crowding at 0, species
    ## labels change no force and any count steps the one-species world.
    for row in 0 ..< speciesCount:
      for column in 0 ..< speciesCount:
        result.add (if row == column: MATRIX_MAX_VALUE.float32 else: 0.0'f32)

  func stackedBodies(): seq[Body] =
    ## MAX_BODIES shells on one centre with their normals aligned, each gain at
    ## its ceiling: the worst case a particle between them can feel.
    let masses = bodyInverseMasses(BODY_DEFAULT_RADIUS, 1.0)
    for _ in 0 ..< MAX_BODIES:
      result.add Body(
        centerX: BODY_WORLD_W * 0.5, centerY: BODY_WORLD_H * 0.5,
        radius: BODY_DEFAULT_RADIUS, anisotropy: 1.0,
        bandWidth: BODY_DEFAULT_BAND,
        proximity: BODY_PROXIMITY_MAX, enclosure: BODY_ENCLOSURE_MAX,
        invMass: masses.invMass, invInertia: masses.invInertia)

  # --- One thread per seed -----------------------------------------------------

  type Slot[A, R] = object
    input: A
    work: proc (input: A): R {.nimcall, gcsafe.}
    output: ptr R

  proc runSlot[A, R](slot: Slot[A, R]) {.thread.} =
    slot.output[] = slot.work(slot.input)

  proc inParallel[A, R](inputs: seq[A];
      work: proc (input: A): R {.nimcall, gcsafe.}): seq[R] =
    ## `work` over every input at once, one thread each, results in input order.
    result = newSeq[R](inputs.len)
    var threads = newSeq[Thread[Slot[A, R]]](inputs.len)
    for i in 0 ..< inputs.len:
      createThread(threads[i], runSlot[A, R],
        Slot[A, R](input: inputs[i], work: work, output: addr result[i]))
    joinThreads(threads)

  # --- Windowed runs -----------------------------------------------------------

  type
    WindowRun = object
      ## One world stepped through a frame-factor schedule.
      params: OracleParams
      speciesCount: int
      seed: int
      frameFactors: seq[float]
      substeps: seq[int]

    WindowReading = object
      motion: float
        ## Mean speed over the frame factor, averaged over WINDOW_STEPS: motion
        ## per reference frame, which compares one world across frame rates.
      crowdP999: seq[float]
        ## The p99.9 smoothed crowd density at each of WINDOW_STEPS.
      capContact: int
        ## Particle-steps at a WINDOW_STEPS frame whose per-reference-frame
        ## speed passes integrate.wgsl's soft-cap threshold (arm C, §3.5).

    Schedule = proc (seed: int): seq[float] {.noSideEffect, gcsafe.}

  func percentile999(values: seq[float32]): float =
    var ordered = values
    ordered.sort()
    ordered[max(int(ceil(0.999 * ordered.len.float)) - 1, 0)].float

  func capContactCount(world: OracleWorld; frameFactor,
      maxVelocity: float32): int =
    ## Particles whose per-reference-frame speed passes integrate.wgsl's
    ## soft-cap threshold (integrate.wgsl:107).
    let threshold = maxVelocity * 0.5'f32
    for i in 0 ..< world.velX.len:
      let speed = sqrt(world.velX[i] * world.velX[i] +
        world.velY[i] * world.velY[i]) / frameFactor
      if speed > threshold:
        inc result

  proc runWindow(run: WindowRun): WindowReading {.gcsafe.} =
    var world = initOracleWorld(run.params, CALIBRATION_PARTICLES,
      run.speciesCount, attractingMatrix(run.speciesCount), run.seed)
    for step in 0 ..< run.frameFactors.len:
      stepFrame(world, run.frameFactors[step], run.substeps[step])
      if step in WINDOW_STEPS:
        result.motion += meanSpeed(world) / run.frameFactors[step]
        result.crowdP999.add percentile999(world.crowdDensity)
        result.capContact += capContactCount(world,
          run.frameFactors[step].float32, run.params.maxVelocity)
    result.motion /= WINDOW_STEPS.len.float

  func windowRuns(params: OracleParams; speciesCount: int;
      schedule: Schedule): seq[WindowRun] =
    ## One run per gate seed. No coupling here asks for more than one
    ## substep (fluid off, no live body): the step limit holds every frame
    ## factor stable without a substep count of its own.
    for seed in GATE_SEEDS:
      let factors = schedule(seed)
      var substeps: seq[int]
      for frameFactor in factors:
        substeps.add 1
      result.add WindowRun(params: params, speciesCount: speciesCount,
        seed: seed, frameFactors: factors, substeps: substeps)

  var windowMemo: Table[string, WindowReading]
    ## A gate and a reporting arm that read the same world step it once.

  proc readings(runs: seq[WindowRun]): seq[WindowReading] =
    ## Every run not yet stepped in this process, stepped at once.
    var missing: seq[WindowRun]
    for run in runs:
      if $run notin windowMemo and run notin missing:
        missing.add run
    let stepped = inParallel(missing, runWindow)
    for i, run in missing:
      windowMemo[$run] = stepped[i]
    for run in runs:
      result.add windowMemo[$run]

  func fixedFactors(frameFactor: float): Schedule =
    result = func (seed: int): seq[float] =
      for _ in 0 ..< STEP_COUNT:
        result.add frameFactor

  func alternatingFactors(seed: int): seq[float] =
    for step in 0 ..< STEP_COUNT:
      result.add (if step mod 2 == 0: 10.0 else: 13.0)

  func nextJitter(state: var uint64; lowest, highest: int): float =
    ## SplitMix64 again, so a seed reproduces a jittered arm exactly.
    state = state + 0x9E3779B97F4A7C15'u64
    var z = state
    z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
    z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
    z = z xor (z shr 31)
    float(lowest + int(z mod uint64(highest - lowest + 1)))

  func uniformFactors(seed: int): seq[float] =
    ## Frame factors drawn uniformly from the integers 8 to 16.
    var state = cast[uint64](seed.int64)
    for _ in 0 ..< STEP_COUNT:
      result.add nextJitter(state, 8, 16)

  func heldFrames(seed: int): seq[float] =
    ## ff 0.42 with single ff-30 steps at 300, 500 and 700 (§3.5 arm D).
    for step in 0 ..< STEP_COUNT:
      result.add (if step in [300, 500, 700]: 30.0 else: 0.42)

  func motions(readings: seq[WindowReading]): seq[float] =
    for reading in readings:
      result.add reading.motion

  func capContacts(readings: seq[WindowReading]): seq[int] =
    for reading in readings:
      result.add reading.capContact

  func ratios(numerators, denominators: seq[float]): seq[float] =
    for i in 0 ..< numerators.len:
      result.add numerators[i] / denominators[i]

  proc frictionMotion(friction, stiffness: float; schedule: Schedule):
      seq[float] =
    ## The self-attracting world at `stiffness` and `friction` through
    ## `schedule`.
    motions(readings(windowRuns(oracleParams(friction, stiffness, 0.0), 1,
      schedule)))

  proc frictionCapContact(friction, stiffness: float;
      schedule: Schedule): seq[int] =
    capContacts(readings(windowRuns(oracleParams(friction, stiffness, 0.0),
      1, schedule)))

  proc shippedFrictionMotion(schedule: Schedule): seq[float] =
    ## The self-attracting world at K and shipped friction through `schedule`.
    frictionMotion(defaultSettings().friction, WORLD_PRESSURE_STIFFNESS,
      schedule)

  proc frameFactorOneMotion(): seq[float] =
    shippedFrictionMotion(fixedFactors(1.0))

  proc settleStatistics(stiffness: float): seq[float] =
    ## L per seed: the friction-zero late-window speed with the term at
    ## `stiffness` over the same seed's without it.
    let without = frictionMotion(FRICTION_MIN, 0.0, fixedFactors(1.0))
    let with = frictionMotion(FRICTION_MIN, stiffness, fixedFactors(1.0))
    ratios(with, without)

  # --- The stacked hold --------------------------------------------------------

  type
    CompressionRun = object
      params: OracleParams
      seed: int
      stack: seq[Body]
      freeSubsteps, heldSubsteps: int

    CompressionTrial = object
      ## One seed's settled world held by the stacked bodies, the same world
      ## held at stiffness zero, and the same world left alone, then the held
      ## world released beside the untouched one.
      seed: int
      heldPeaks, controlPeaks: seq[float]
        ## The busiest particle's crowd density at each held frame.
      farHeld, farFree: float
      afterRelease, fresh: float
        ## Mean weighted neighbours RELAXATION_FRAMES after the release, and
        ## the untouched world's at the same frame.

  proc runCompression(run: CompressionRun): CompressionTrial {.gcsafe.} =
    result.seed = run.seed
    var settled = initOracleWorld(run.params, CALIBRATION_PARTICLES, 1,
      attractingMatrix(1), run.seed)
    for _ in 0 ..< SETTLE_FRAMES:
      stepFrame(settled, 1.0, run.freeSubsteps)
    var held = settled
    held.bodies = run.stack
    held.bodyEnvelopes = newSeq[float](run.stack.len)
    for envelope in held.bodyEnvelopes.mitems:
      envelope = 1.0
    var control = held
    control.params.pressureStiffness = 0.0
    var free = settled
    for _ in 0 ..< HOLD_FRAMES:
      stepFrame(held, 1.0, run.heldSubsteps)
      stepFrame(control, 1.0, run.heldSubsteps)
      stepFrame(free, 1.0, run.freeSubsteps)
      result.heldPeaks.add peakCrowdDensity(held)
      result.controlPeaks.add peakCrowdDensity(control)
    result.farHeld = meanSpeedBeyond(held, run.stack, STACK_CLEARANCE)
    result.farFree = meanSpeedBeyond(free, run.stack, STACK_CLEARANCE)
    held.bodies = @[]
    held.bodyEnvelopes = @[]
    for _ in 0 ..< RELAXATION_FRAMES:
      stepFrame(held, 1.0, run.freeSubsteps)
      stepFrame(free, 1.0, run.freeSubsteps)
    result.afterRelease = meanWeightedNeighbours(held)
    result.fresh = meanWeightedNeighbours(free)

  var compressionMemo: seq[CompressionTrial]

  proc compressionTrials(): seq[CompressionTrial] =
    if compressionMemo.len == 0:
      let params = oracleParams(defaultSettings().friction,
        WORLD_PRESSURE_STIFFNESS, BODY_STRENGTH_CEILING)
      var runs: seq[CompressionRun]
      for seed in GATE_SEEDS:
        runs.add CompressionRun(params: params, seed: seed,
          stack: stackedBodies(),
          freeSubsteps: substepPlan(1.0, liveValues(false)).count,
          heldSubsteps: substepPlan(1.0, liveValues(true)).count)
      compressionMemo = inParallel(runs, runCompression)
    compressionMemo

  # --- The gates ---------------------------------------------------------------

  suite "A Compressed Crowd Stays Local And Below Its Collapse":

    test "the held crowd's mean peak density stays below the stiffness-zero control's":
      var held, control: seq[float]
      for trial in compressionTrials():
        checkpoint("seed " & $trial.seed & ": held peak " &
          $trial.heldPeaks[^1] & " against control " & $trial.controlPeaks[^1])
        held.add trial.heldPeaks[^1]
        control.add trial.controlPeaks[^1]
      check meanOf(held) < meanOf(control)

    test "the crowd beyond the bodies' reach runs within the margin of a no-body world":
      var far: seq[float]
      for trial in compressionTrials():
        checkpoint("seed " & $trial.seed & ": far held " & $trial.farHeld &
          " against far free " & $trial.farFree)
        far.add trial.farHeld / trial.farFree
      checkpoint("mean ratio " & $meanOf(far) & " against " &
        $(1.0 + FAR_SPEED_MARGIN))
      check meanOf(far) <= 1.0 + FAR_SPEED_MARGIN

  suite "Compression Is Not Remembered":

    test "a released crowd's mean neighbour count returns to a fresh settle's":
      var relaxation: seq[float]
      for trial in compressionTrials():
        checkpoint("seed " & $trial.seed & ": after " & $trial.afterRelease &
          " fresh " & $trial.fresh)
        relaxation.add trial.afterRelease / trial.fresh
      checkpoint("mean ratio " & $meanOf(relaxation) & " against 1")
      check meanOf(relaxation) <= 1.0

  suite "A Settling World Still Settles":

    test "the world pressure leaves a friction-zero world settling within B_L":
      let settles = settleStatistics(WORLD_PRESSURE_STIFFNESS)
      checkpoint("settle statistics " & $settles & ", mean " &
        $meanOf(settles) & " against " & $SETTLE_BOUND)
      check meanOf(settles) <= SETTLE_BOUND

  const ARM_AB_FRAME_FACTORS = [0.42, 2.0, 4.2, 10.0, 30.0]
    ## §3.5's sustained schedules, arms A and B.

  suite "Every Frame Factor Settles No Warmer":
    ## Gate G1, §3.5 arms A-D: the criterion holds only when every arm below
    ## passes, at 128 000 (and, per the coverage note, 16 000 at radius 150,
    ## run separately).

    test "arm A: every sustained frame factor settles no warmer at shipped friction":
      let reference = frameFactorOneMotion()
      var verdicts: Verdicts
      for frameFactor in ARM_AB_FRAME_FACTORS:
        let warmth = ratios(shippedFrictionMotion(fixedFactors(frameFactor)),
          reference)
        checkpoint("frame factor " & $frameFactor & ": mean ratio " &
          $meanOf(warmth))
        if not (meanOf(warmth) <= 1.0):
          verdicts.add "frame factor " & $frameFactor & ": a mean ratio of " &
            $meanOf(warmth) & " runs warmer than frame factor 1"
      checkNoVerdicts(verdicts)

    test "arm B: at friction zero, the stiffness term worsens no sustained frame factor past the species world":
      var verdicts: Verdicts
      for frameFactor in ARM_AB_FRAME_FACTORS:
        let withTerm = ratios(frictionMotion(FRICTION_MIN,
          WORLD_PRESSURE_STIFFNESS, fixedFactors(frameFactor)),
          frictionMotion(FRICTION_MIN, WORLD_PRESSURE_STIFFNESS,
            fixedFactors(1.0)))
        let withoutTerm = ratios(frictionMotion(FRICTION_MIN, 0.0,
          fixedFactors(frameFactor)), frictionMotion(FRICTION_MIN, 0.0,
            fixedFactors(1.0)))
        let bound = derivedBound(withoutTerm)
        checkpoint("frame factor " & $frameFactor & ": mean ratio " &
          $meanOf(withTerm) & " against the stiffness-zero bound " & $bound)
        if not (meanOf(withTerm) <= bound):
          verdicts.add "frame factor " & $frameFactor & ": a mean ratio of " &
            $meanOf(withTerm) & " exceeds the stiffness-zero bound of " &
            $bound
      checkNoVerdicts(verdicts)

    test "arm C: no schedule holds more particle-steps against the cap than the stiffness-zero world":
      var verdicts: Verdicts
      proc checkArm(label: string; friction: float; schedule: Schedule) =
        let withTerm = frictionCapContact(friction, WORLD_PRESSURE_STIFFNESS,
          schedule)
        let withoutTerm = frictionCapContact(friction, 0.0, schedule)
        checkpoint(label & ": cap contact " & $withTerm &
          " against the stiffness-zero world's " & $withoutTerm)
        for i in 0 ..< withTerm.len:
          if withTerm[i] > withoutTerm[i]:
            verdicts.add label & " seed " & $GATE_SEEDS[i] &
              ": cap contact " & $withTerm[i] &
              " exceeds the stiffness-zero world's " & $withoutTerm[i]
      for frameFactor in ARM_AB_FRAME_FACTORS:
        checkArm("frame factor " & $frameFactor & " (shipped friction)",
          defaultSettings().friction, fixedFactors(frameFactor))
        checkArm("frame factor " & $frameFactor & " (friction zero)",
          FRICTION_MIN, fixedFactors(frameFactor))
      checkArm("uniform 8-16", defaultSettings().friction, uniformFactors)
      checkArm("alternating 10/13", defaultSettings().friction,
        alternatingFactors)
      checkArm("held frames", defaultSettings().friction, heldFrames)
      checkNoVerdicts(verdicts)

    test "arm D: unsteady schedules settle no warmer at shipped friction":
      let reference = frameFactorOneMotion()
      let heldReference = shippedFrictionMotion(fixedFactors(0.42))
      let arms = [
        ("uniform 8-16", shippedFrictionMotion(uniformFactors), reference),
        ("alternating 10/13", shippedFrictionMotion(alternatingFactors),
          reference),
        ("held frames", shippedFrictionMotion(heldFrames), heldReference)]
      var verdicts: Verdicts
      for arm in arms:
        let warmth = ratios(arm[1], arm[2])
        checkpoint(arm[0] & ": mean ratio " & $meanOf(warmth))
        if not (meanOf(warmth) <= 1.0):
          verdicts.add arm[0] & ": a mean ratio of " & $meanOf(warmth) &
            " runs warmer than its reference"
      checkNoVerdicts(verdicts)

  # --- The reporting arms ------------------------------------------------------
  # Each prints markdown for the scratchpad record its task names and asserts
  # nothing.

  func shown(value: float): string = formatFloat(value, ffDecimal, 4)

  func shownAll(values: seq[float]): string =
    for i, value in values:
      if i > 0:
        result.add ", "
      result.add shown(value)

  proc printConditions(arm: string) =
    echo ""
    echo "## ", arm
    echo ""
    when defined(calibrateSmoke):
      echo "SMOKE RUN: these numbers show the arm runs and are no measurement."
    echo "- particles ", CALIBRATION_PARTICLES, ", radius ", CALIBRATION_RADIUS,
      ", polynomial model, seeds ", $GATE_SEEDS
    echo "- frames: ", STEP_COUNT, " steps, window ", $WINDOW_STEPS,
      "; settle ", SETTLE_FRAMES, ", hold ", HOLD_FRAMES, ", release ",
      RELAXATION_FRAMES
    echo "- x_on ", CALIBRATION_ONSET_RATIO, ", K ", WORLD_PRESSURE_STIFFNESS,
      ", q_max ", WORLD_PRESSURE_IMPULSE_MAX, ", shipped friction ",
      defaultSettings().friction, " (retention applied once per step)"

  suite "Gate G1.1 Readings":

    test "the onset arm prints the p99.9 crowd ratio, the contact floor and the band's bottom":
      printConditions("G1.1 onset: no coupling but the species force, " &
        "shipped friction, frame factor 1, all species attracting at the " &
        "matrix maximum")
      let cfg = calibrationConfig()
      let mean = meanCrowdDensity(cfg)
      let floorDensity = contactFloorDensity(cfg)
      let params = oracleParams(defaultSettings().friction, 0.0, 0.0)
      var runs: seq[WindowRun]
      for species in [1, 4]:
        runs.add windowRuns(params, species, fixedFactors(1.0))
      let got = readings(runs)
      echo "- uniform crowd density rho-bar ", shown(mean)
      echo "- contact floor at the preset repulsionEnd ", cfg.repulsionEnd,
        ": rho ", shown(floorDensity), ", x ", shown(floorDensity / mean)
      echo ""
      echo "| species | seed | p99.9 x at each window step | end of window |"
      echo "|---|---|---|---|"
      var ends: seq[float]
      for i, run in runs:
        var ratiosAlong: seq[float]
        for density in got[i].crowdP999:
          ratiosAlong.add density / mean
        ends.add ratiosAlong[^1]
        echo "| ", run.speciesCount, " | ", run.seed, " | ",
          shownAll(ratiosAlong), " | ", shown(ratiosAlong[^1]), " |"
      echo ""
      echo "- band of end-of-window p99.9 x: ", shown(min(ends)), " to ",
        shown(max(ends))
      echo "- one species mean ", shown(meanOf(ends[0 ..< GATE_SEEDS.len])),
        ", four species mean ", shown(meanOf(ends[GATE_SEEDS.len .. ^1]))
      echo "- bottom of the band, smallest run: ", shown(min(ends))
      echo "- bottom of the band, mean less the largest distance: ",
        shown(meanOf(ends) - largestDistance(ends))
      echo "- unmeasured: other particle counts, radii, species counts and " &
        "the exponential model"

  suite "Gate G1.2 Readings":

    test "the stiffness arm prints L at K 540 and 1728 and the bound B_L":
      printConditions("G1.2 stiffness: one self-attracting species, " &
        "FRICTION_MIN, no viscosity, frame factor 1")
      let stiffnesses = [0.0, WORLD_PRESSURE_STIFFNESS, 1728.0]
      var runs: seq[WindowRun]
      for stiffness in stiffnesses:
        runs.add windowRuns(oracleParams(FRICTION_MIN, stiffness, 0.0), 1,
          fixedFactors(1.0))
      discard readings(runs)
      let chosen = settleStatistics(WORLD_PRESSURE_STIFFNESS)
      let stiffer = settleStatistics(1728.0)
      let without = motions(readings(runs[0 ..< GATE_SEEDS.len]))
      echo "| seed | speed without the term | L at K 540 | L at K 1728 |"
      echo "|---|---|---|---|"
      for i, seed in GATE_SEEDS:
        echo "| ", seed, " | ", shown(without[i]), " | ", shown(chosen[i]),
          " | ", shown(stiffer[i]), " |"
      echo ""
      let bound = derivedBound(chosen)
      echo "- mean L at K 540 ", shown(meanOf(chosen)), ", largest distance ",
        shown(largestDistance(chosen)), ", B_L ", shown(bound)
      echo "- mean L at K 1728 ", shown(meanOf(stiffer)), ": ",
        (if meanOf(stiffer) > bound: "exceeds B_L" else: "DOES NOT exceed B_L")

  suite "Gate G1.3 Readings":

    test "the stacked-hold arm prints its peaks, release ratios and far-crowd margin":
      printConditions("G1.3 stacked hold: one self-attracting species, " &
        $MAX_BODIES & " aligned bodies at their ceilings, stiffness-zero " &
        "control bounded to the held frames")
      let trials = compressionTrials()
      echo "| seed | held peak at last held frame | control peak | " &
        "smallest control less held, at held frame | held frames above " &
        "control | after / fresh | far held / far free |"
      echo "|---|---|---|---|---|---|---|"
      var release, far, heldEnd, controlEnd: seq[float]
      var reachedAtEnd = false
      for trial in trials:
        var gap = Inf
        var gapFrame = 0
        var above = 0
        # Both worlds read their first held frame's density off the same
        # settled positions, and the next few part by one lagged step only.
        for frame in 1 ..< trial.heldPeaks.len:
          let frameGap = trial.controlPeaks[frame] - trial.heldPeaks[frame]
          if frameGap < 0.0:
            above += 1
          if frameGap < gap:
            gap = frameGap
            gapFrame = frame + 1
        if trial.heldPeaks[^1] >= trial.controlPeaks[^1]:
          reachedAtEnd = true
        release.add trial.afterRelease / trial.fresh
        far.add trial.farHeld / trial.farFree
        heldEnd.add trial.heldPeaks[^1]
        controlEnd.add trial.controlPeaks[^1]
        echo "| ", trial.seed, " | ", shown(trial.heldPeaks[^1]), " | ",
          shown(trial.controlPeaks[^1]), " | ",
          formatFloat(gap, ffScientific, 3), " at ", gapFrame, " | ", above,
          " | ", shown(trial.afterRelease), " / ", shown(trial.fresh), " = ",
          shown(release[^1]), " | ", shown(trial.farHeld), " / ",
          shown(trial.farFree), " = ", shown(far[^1]), " |"
      echo ""
      echo "- mean held peak ", shown(meanOf(heldEnd)), " against control ",
        shown(meanOf(controlEnd))
      echo "- a seed's held peak at or above the control's at the last held " &
        "frame: ", (if reachedAtEnd: "YES, which returns the design" else: "no")
      echo "- mean after-release ratio ", shown(meanOf(release))
      echo "- far-crowd ratio mean ", shown(meanOf(far)), ", bound mean + " &
        "largest distance ", shown(derivedBound(far)), ", margin ",
        shown(derivedBound(far) - 1.0)
