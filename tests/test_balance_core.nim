## The shared unit and each writer's unit function (src/balance_core.nim).
##
## Every expectation comes from the design's own formulas, derived here
## independently of balance_core's arithmetic: the edge neighbour count from
## the onset number density, the cell area from the world and grid extents,
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
    longRangeGrid: LR_GRID_SIZES[LONG_RANGE_GRID_INDEX_DEFAULT],
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
    for grid in LR_GRID_SIZES:
      for radius in [INTERACTION_RADIUS_MIN.float, 50.0,
          INTERACTION_RADIUS_MAX.float]:
        for particleCount in [16_000, MAX_PARTICLES]:
          for strength in [0.5, 1.0]:
            var cfg = referenceConfig()
            cfg.longRangeGrid = grid
            cfg.interactionRadius = radius
            cfg.particleCount = particleCount
            cfg.longRangeStrength = strength
            let unit = unitImpulse(ufLongRange, cfg)
            let cellArea = (cfg.worldWidth / grid.w.float) *
              (cfg.worldHeight / grid.h.float)
            let nearest = colonyRadius(cfg) + radius
            var worst = 0.0
            for distanceStep in 0 .. 40:
              let distance = nearest + 50.0 * distanceStep.float
              for entry in [-MATRIX_MAX_VALUE, 0.5 * MATRIX_MAX_VALUE,
                  MATRIX_MAX_VALUE]:
                for swept in [0.25 * strength, strength]:
                  worst = max(worst, lrDiscPull(swept, entry, cellArea,
                    particleCount.float, distance) / FRAME_DT_REFERENCE)
            let attained = lrDiscPull(strength, cfg.attraction, cellArea,
              particleCount.float, nearest) / FRAME_DT_REFERENCE
            verdicts.judge("long range grid " & $grid & " R " & $radius &
              " N " & $particleCount & " strength " & $strength, unit, worst,
              attained, TOLERANCE_F64)
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
# THE CALIBRATION ARMS
# ==============================================================================
# Each arm steps the oracle world for hundreds of frames on sixteen seeds, so
# each one sits behind the define its own justfile recipe sets and outside the
# suite `just test` compiles. The 16 000-particle arms answer to
# `calibrateBalance`; the 128 000-particle arms to `calibrateBalance128k`.

when defined(calibrateBalance) or defined(calibrateBalance128k):
  import ../src/preset
  import ../src/sim_registry

  const
    HELD_OUT_SEEDS = [
      20_011, 20_023, 20_029, 20_047, 20_051, 20_063, 20_071, 20_089,
      20_101, 20_107, 20_113, 20_117, 20_123, 20_129, 20_143, 20_147]
      ## PROVISIONAL. Sixteen seeds no bound was fitted on. The calibration
      ## run records the set it fitted on beside this one; until it does,
      ## these sixteen stand and only these are gated.
    T_95_ONE_SIDED_15_DF = 1.753
      ## Student's t at 5% one sided on 15 degrees of freedom, which is the
      ## sixteen seeds above.
    SETTLE_FRAMES = 600
      ## Frames a world runs before a body touches it, so the hold acts on a
      ## settled crowd rather than on uniform noise.
    HOLD_FRAMES = 100
    RELAXATION_FRAMES = 900
    STEP_COUNT = 900
    WINDOW_STEPS = [749, 799, 849, 899]
      ## The late window every settle statistic is read on.

  func meanOf(values: seq[float]): float =
    for value in values:
      result += value
    result /= values.len.float

  func sampleDeviation(values: seq[float]): float =
    let centre = meanOf(values)
    for value in values:
      result += (value - centre) * (value - centre)
    sqrt(result / (values.len - 1).float)

  func boundMargin(values: seq[float]): float =
    ## The one-sided allowance a gate against a fixed bound carries.
    T_95_ONE_SIDED_15_DF * sampleDeviation(values) / sqrt(values.len.float)

  func oracleParams(particleCount: int;
      sliderFriction, pressureStiffness, bodiesStrength: float): OracleParams =
    ## The shipped world at radius 50, with the three numbers each arm varies
    ## passed in. `sliderFriction` is the slider's value, which reaches the
    ## integrator as the retention factor one minus it (src/app.nim:193).
    let shipped = defaultSettings()
    var cfg = referenceConfig()
    cfg.particleCount = particleCount
    OracleParams(
      interactionRadius: shipped.interactionRadius.float32,
      worldWidth: BODY_WORLD_W.float32, worldHeight: BODY_WORLD_H.float32,
      minDistanceSq: PRODUCTION_TUNING.minDistanceSq.float32,
      forceModel: ofmPolynomial,
      forceMultiplier: shipped.forceStrength.float32,
      repulsionEnd: shipped.repulsionEnd.float32,
      attractionPeak: shipped.attractionPeak.float32,
      expAlpha: shipped.expRepulsionAlpha.float32,
      expBeta: shipped.expAttractionBeta.float32,
      crowdingStrength: shipped.crowdingStrength.float32,
      pressureOnset: crowdOnsetDensity(cfg).float32,
      pressureStiffness: pressureStiffness.float32,
      pressureImpulseMax: WORLD_PRESSURE_IMPULSE_MAX.float32,
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
      interactionRadius: shipped.interactionRadius.float,
      sphRadiusFraction: shipped.sphRadiusFraction,
      sphStiffness: shipped.sphStiffness,
      timeScale: shipped.timeScale,
      bodyBand: BODY_DEFAULT_BAND,
      bodyLive: bodiesLive)

  func plannedSubsteps(frameFactor: float; bodiesLive: bool): int =
    substepPlan(frameFactor, liveValues(bodiesLive)).count

  func selfAttractingMatrix(): seq[float32] =
    @[MATRIX_MAX_VALUE.float32]

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

  func holdingEnvelopes(): seq[float] =
    for _ in 0 ..< MAX_BODIES:
      result.add 1.0

  proc runFrames(world: var OracleWorld; frames: int; bodiesLive: bool) =
    let substeps = plannedSubsteps(1.0, bodiesLive)
    for _ in 0 ..< frames:
      stepFrame(world, 1.0, substeps)

  proc relaxationRatio(particleCount, seed: int): float =
    ## The weighted neighbour count a released crowd carries, over what the
    ## same seed reaches having never been compressed.
    let params = oracleParams(particleCount, defaultSettings().friction,
      WORLD_PRESSURE_STIFFNESS, BODY_STRENGTH_CEILING)
    var compressed = initOracleWorld(params, particleCount, 1,
      selfAttractingMatrix(), seed)
    var fresh = compressed

    runFrames(compressed, SETTLE_FRAMES, false)
    compressed.bodies = stackedBodies()
    compressed.bodyEnvelopes = holdingEnvelopes()
    runFrames(compressed, HOLD_FRAMES, true)
    compressed.bodies = @[]
    compressed.bodyEnvelopes = @[]
    runFrames(compressed, RELAXATION_FRAMES, false)

    runFrames(fresh, SETTLE_FRAMES + HOLD_FRAMES + RELAXATION_FRAMES, false)
    meanWeightedNeighbours(compressed) / meanWeightedNeighbours(fresh)

when defined(calibrateBalance):

  const
    RELAXATION_BOUND_16K = 1.05
      ## PROVISIONAL. The bound on the released crowd's neighbour count over a
      ## fresh settle's at 16 000 particles. The calibration run replaces it.
    FAR_SPEED_MARGIN = 0.10
      ## PROVISIONAL. How much faster the crowd beyond a body's reach may run
      ## while the body holds, as a fraction of the same seed's no-body run.
    STACK_CLEARANCE = 2.0 * BODY_DEFAULT_BAND
      ## Enclosure falls to exactly zero at twice the band
      ## (src/body_core.nim:376-380), so past this a stacked body hands a
      ## particle nothing and the crowd out there is the far crowd.

  type CompressionTrial = object
    ## One seed's three arms of the stacked hold, read at the same held frame.
    seed: int
    pressuredPeak, controlPeak: float
    farHeld, farFree: float

  func attractingMatrix(speciesCount: int): seq[float32] =
    for _ in 0 ..< speciesCount * speciesCount:
      result.add MATRIX_MAX_VALUE.float32

  func armSpecies(index: int): int =
    ## One arm of the sixteen runs the self-attracting single species, which
    ## is the configuration that piles up hardest; the rest run four species
    ## that all attract.
    if index == 0: 1 else: 4

  func armMatrix(index: int): seq[float32] =
    if armSpecies(index) == 1: selfAttractingMatrix()
    else: attractingMatrix(armSpecies(index))

  proc compressionTrial(seed, index: int): CompressionTrial =
    ## One settled world held by the stacked bodies, the same world held with
    ## the world pressure switched off, and the same world left alone.
    let params = oracleParams(16_000, defaultSettings().friction,
      WORLD_PRESSURE_STIFFNESS, BODY_STRENGTH_CEILING)
    var settled = initOracleWorld(params, 16_000, armSpecies(index),
      armMatrix(index), seed)
    runFrames(settled, SETTLE_FRAMES, false)
    let stack = stackedBodies()

    var held = settled
    held.bodies = stack
    held.bodyEnvelopes = holdingEnvelopes()
    runFrames(held, HOLD_FRAMES, true)

    var control = settled
    control.params.pressureStiffness = 0.0
    control.bodies = stack
    control.bodyEnvelopes = holdingEnvelopes()
    runFrames(control, HOLD_FRAMES, true)

    var free = settled
    runFrames(free, HOLD_FRAMES, false)

    CompressionTrial(seed: seed,
      pressuredPeak: peakCrowdDensity(held),
      controlPeak: peakCrowdDensity(control),
      farHeld: meanSpeedBeyond(held, stack, STACK_CLEARANCE),
      farFree: meanSpeedBeyond(free, stack, STACK_CLEARANCE))

  func fixedFactors(frameFactor: float): seq[float] =
    for _ in 0 ..< STEP_COUNT:
      result.add frameFactor

  func alternatingFactors(lower, upper: float): seq[float] =
    for step in 0 ..< STEP_COUNT:
      result.add (if step mod 2 == 0: lower else: upper)

  func nextJitter(state: var uint64; lowest, highest: int): float =
    ## SplitMix64 again, so a seed reproduces a jittered arm exactly.
    state = state + 0x9E3779B97F4A7C15'u64
    var z = state
    z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
    z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
    z = z xor (z shr 31)
    float(lowest + int(z mod uint64(highest - lowest + 1)))

  func uniformFactors(seed, lowest, highest: int): seq[float] =
    var state = cast[uint64](seed.int64)
    for _ in 0 ..< STEP_COUNT:
      result.add nextJitter(state, lowest, highest)

  proc motionPerReferenceFrame(seed: int; frameFactors: seq[float];
      substepped: bool): float =
    ## The late window's mean speed divided by the frame factor the step that
    ## reached it advanced, which is the reading that compares one world
    ## across frame rates.
    let params = oracleParams(16_000, defaultSettings().friction,
      WORLD_PRESSURE_STIFFNESS, 0.0)
    var world = initOracleWorld(params, 16_000, 1, selfAttractingMatrix(),
      seed)
    var sampled = 0
    for step in 0 ..< frameFactors.len:
      let frameFactor = frameFactors[step]
      let substeps = if substepped: plannedSubsteps(frameFactor, false) else: 1
      stepFrame(world, frameFactor, substeps)
      if step in WINDOW_STEPS:
        result += meanSpeed(world) / frameFactor
        sampled += 1
    result /= sampled.float

  suite "A Compressed Crowd Stays Local And Below Its Collapse":
    var trials: seq[CompressionTrial]
    for index, seed in HELD_OUT_SEEDS:
      trials.add compressionTrial(seed, index)

    test "the held crowd's peak density stays below the stiffness-zero control's":
      var verdicts: Verdicts
      for trial in trials:
        checkpoint("seed " & $trial.seed & ": held peak " &
          $trial.pressuredPeak & " against control " & $trial.controlPeak)
        if not (trial.pressuredPeak < trial.controlPeak):
          verdicts.add "seed " & $trial.seed & ": a held peak of " &
            $trial.pressuredPeak & " is not below the stiffness-zero " &
            "control's " & $trial.controlPeak
      checkNoVerdicts(verdicts)

    test "the crowd beyond the bodies' reach runs within the margin of a no-body world":
      var ratios: seq[float]
      for trial in trials:
        checkpoint("seed " & $trial.seed & ": far held " & $trial.farHeld &
          " against far free " & $trial.farFree)
        ratios.add trial.farHeld / trial.farFree
      let bound = 1.0 + FAR_SPEED_MARGIN
      checkpoint("mean ratio " & $meanOf(ratios) & " against " & $bound &
        " + margin " & $boundMargin(ratios))
      check meanOf(ratios) <= bound + boundMargin(ratios)

  suite "Compression Is Not Remembered":
    var ratios: seq[float]
    for seed in HELD_OUT_SEEDS:
      ratios.add relaxationRatio(16_000, seed)

    test "a released crowd's neighbour count returns to a fresh settle's at 16 000 particles":
      for index, seed in HELD_OUT_SEEDS:
        checkpoint("seed " & $seed & ": ratio " & $ratios[index])
      checkpoint("mean ratio " & $meanOf(ratios) & " against " &
        $RELAXATION_BOUND_16K)
      check meanOf(ratios) <= RELAXATION_BOUND_16K

  suite "A Settling World Still Settles":
    let reference = block:
      var speeds: seq[float]
      for seed in HELD_OUT_SEEDS:
        speeds.add motionPerReferenceFrame(seed, fixedFactors(1.0), false)
      speeds

    test "no frame factor moves a world warmer per reference frame than frame factor 1":
      var verdicts: Verdicts
      for frameFactor in [2.0, 10.0, 30.0]:
        var ratios: seq[float]
        for index, seed in HELD_OUT_SEEDS:
          ratios.add motionPerReferenceFrame(seed,
            fixedFactors(frameFactor), true) / reference[index]
        let allowed = 1.0 + boundMargin(ratios)
        checkpoint("frame factor " & $frameFactor & ": mean ratio " &
          $meanOf(ratios) & " against " & $allowed)
        if not (meanOf(ratios) <= allowed):
          verdicts.add "frame factor " & $frameFactor & ": a mean ratio of " &
            $meanOf(ratios) & " runs warmer than frame factor 1's " & $allowed
      checkNoVerdicts(verdicts)

    test "no jittered frame factor moves a world warmer per reference frame than frame factor 1":
      var verdicts: Verdicts
      var uniform: seq[float]
      var alternating: seq[float]
      for index, seed in HELD_OUT_SEEDS:
        uniform.add motionPerReferenceFrame(seed,
          uniformFactors(seed, 8, 16), true) / reference[index]
        alternating.add motionPerReferenceFrame(seed,
          alternatingFactors(10.0, 13.0), true) / reference[index]
      for arm in [("uniform 8-16", uniform), ("alternating 10/13", alternating)]:
        let allowed = 1.0 + boundMargin(arm[1])
        checkpoint(arm[0] & ": mean ratio " & $meanOf(arm[1]) & " against " &
          $allowed)
        if not (meanOf(arm[1]) <= allowed):
          verdicts.add arm[0] & ": a mean ratio of " & $meanOf(arm[1]) &
            " runs warmer than frame factor 1's " & $allowed
      checkNoVerdicts(verdicts)

when defined(calibrateBalance128k):

  const SETTLE_BOUND = 1.177
    ## PROVISIONAL. The bound on the settle statistic: the late-window mean
    ## speed with the world pressure over the same seed's without it, at
    ## friction zero. The calibration run replaces it with the bound its own
    ## seeds derive.

  proc lateWindowSpeed(particleCount, seed: int; stiffness: float): float =
    ## The late-window mean speed of a world at friction zero, which is the
    ## denominator's conditions as much as the numerator's.
    let params = oracleParams(particleCount, FRICTION_MIN, stiffness, 0.0)
    var world = initOracleWorld(params, particleCount, 1,
      selfAttractingMatrix(), seed)
    var sampled = 0
    for step in 0 ..< STEP_COUNT:
      stepFrame(world, 1.0, 1)
      if step in WINDOW_STEPS:
        result += meanSpeed(world)
        sampled += 1
    result /= sampled.float

  suite "Compression Is Not Remembered":
    var ratios: seq[float]
    for seed in HELD_OUT_SEEDS:
      ratios.add relaxationRatio(128_000, seed)

    test "a released crowd's neighbour count returns to a fresh settle's at 128 000 particles":
      for index, seed in HELD_OUT_SEEDS:
        checkpoint("seed " & $seed & ": ratio " & $ratios[index])
      let allowed = 1.0 + boundMargin(ratios)
      checkpoint("mean ratio " & $meanOf(ratios) & " against " & $allowed)
      check meanOf(ratios) <= allowed

  suite "A Settling World Still Settles":

    test "the world pressure leaves a friction-zero world settling at 128 000 particles":
      var settles: seq[float]
      for seed in HELD_OUT_SEEDS:
        let withTerm = lateWindowSpeed(128_000, seed, WORLD_PRESSURE_STIFFNESS)
        let withoutTerm = lateWindowSpeed(128_000, seed, 0.0)
        checkpoint("seed " & $seed & ": with " & $withTerm & " without " &
          $withoutTerm)
        settles.add withTerm / withoutTerm
      checkpoint("mean settle statistic " & $meanOf(settles) & " against " &
        $SETTLE_BOUND)
      check meanOf(settles) <= SETTLE_BOUND
