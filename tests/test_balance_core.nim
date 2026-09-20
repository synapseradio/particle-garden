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
  ONSET_RATIO = 6.3
    ## x_on as the design carries it in (measured on 3 seeds, provisional
    ## until the onset gate records it).
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
    onsetRatio: ONSET_RATIO, attraction: MATRIX_MAX_VALUE,
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
        for band in [BODY_BAND_FLOOR, 120.0, BODY_BAND_CEILING]:
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
