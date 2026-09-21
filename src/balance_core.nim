# ==============================================================================
# PARTICLE GARDEN - COUPLING BALANCE (Pure)
# ==============================================================================
#
# The one unit every velocity writer's largest push is stated in, and one unit
# function per writer returning that push in multiples of the unit. Reference
# oracle: each arm mirrors the shader named beside it, which no native test can
# execute.
#
# Imports the oracles and never the module that owns the ranges, so that module
# can import this one and assert against it.
#
# ==============================================================================

import std/math
import physics_core
import sph_core
import field_core
import long_range_core
import body_core

const
  u0* = FRAME_DT_REFERENCE
    ## The velocity one touching neighbour's repulsion core hands a particle at
    ## pair gain 1 over one reference frame. No slider moves it.

  CROWD_PACKING_CONSTANT* = 2.0 * PI / (3.0 * sqrt(3.0))
    ## The crowd density a hexagonal lattice of separation `s` carries in the
    ## continuum, `CROWD_PACKING_CONSTANT / s^2`, both in units of the
    ## interaction radius.
    ##
    ## DERIVED, NOT MEASURED. A crowd at areal number density `n` contributes
    ## `n * 2*PI * integral of u*(1-u) du over [0,1] = n*PI/3` to the signal,
    ## because a neighbour is weighted by `1 - u`. Packing that crowd on a
    ## hexagonal lattice of spacing `s` gives `n = 2/(sqrt(3)*s^2)`, the
    ## tightest arrangement of equal disks in the plane. Composing the two
    ## gives this constant, which latticeCrowdDensity meets as the spacing
    ## shrinks and a lattice's few shells give way to a continuum.

type
  UnitFnId* = enum
    ## One member per velocity writer, and one for the deposit, which writes
    ## the field. unitImpulse's exhaustive case makes a new member without an
    ## arm a compile error.
    ufSpecies
    ufWorldPressure
    ufFluid
    ufScent
    ufLongRange
    ufBodies
    ufMouse
    ufBlast
    ufDeposit

  UnitConfig* = object
    ## The world a unit function is evaluated in. Each arm reads the fields
    ## its writer answers to; the caller supplies the ranges' values, since
    ## this module cannot import their owner.
    particleCount*: int
    interactionRadius*: float
    worldWidth*, worldHeight*: float
    onsetRatio*: float
      ## x_on: the onset crowd density over the world's mean crowd density.
    crowdRatio*: float
      ## x: the crowd density the world pressure is stated at, over the
      ## world's mean crowd density.
    pressureStiffness*: float
      ## K, the world pressure's stiffness.
    pressureImpulseMax*: float
      ## q_max, the largest impulse one pair may exchange.
    attraction*: float
      ## The largest self-attraction matrix entry.
    pairGain*: float
    repulsionEnd*, attractionPeak*: float
    fluidStrength*: float
    viscosity*: float
    maxVelocity*: float
    scentGain*: float
      ## Velocity per reference frame per unit per-cell gradient per world
      ## unit a cell spans.
    tropism*: float
      ## The largest-magnitude tropism.
    patternScale*: float
    longRangeStrength*: float
    longRangeGrid*: tuple[w, h: int]
    bodiesStrength*: float
    liveBodies*: int
    blastStrength*: float
    blastRange*: float
    depositGain*: float
    secretion*: float
      ## The largest-magnitude secretion.

func inUnits(force: float): float =
  ## A force the shaders scale by dt, as the impulse it hands over one
  ## reference frame, in multiples of u0.
  force * FRAME_DT_REFERENCE / u0

func meanCrowdDensity*(cfg: UnitConfig): float =
  ## The crowd density a uniform world holds: N * pi * R^2 / (3 A).
  cfg.particleCount.float * PI * cfg.interactionRadius *
    cfg.interactionRadius / (3.0 * cfg.worldWidth * cfg.worldHeight)

func latticeCrowdDensity*(spacing: float): float =
  ## The crowd density signal a hexagonal lattice of this separation produces,
  ## counted site by site: every site inside the interaction radius carries the
  ## proximity weight `1 - u` that forces.wgsl accumulates. Spacing and
  ## distance are both in units of the interaction radius.
  ##
  ## Counted rather than integrated because at the separations the pair law
  ## rests at, a handful of shells fit inside the radius and the continuum
  ## value runs high: 4.84 against 3.80 at a spacing of 0.5.
  # A site at lattice index (a, b) sits at spacing times sqrt(a^2 + ab + b^2),
  # which is at least sqrt(3)/2 times the larger index, so no site past this
  # ring reaches the radius.
  let rings = int(ceil(2.0 / (sqrt(3.0) * spacing)))
  for alongX in -rings .. rings:
    for alongDiagonal in -rings .. rings:
      if alongX == 0 and alongDiagonal == 0:
        continue
      let x = (alongX.float + 0.5 * alongDiagonal.float) * spacing
      let y = alongDiagonal.float * spacing * sqrt(3.0) * 0.5
      let distance = sqrt(x * x + y * y)
      if distance < 1.0:
        result += 1.0 - distance

func contactFloorDensity*(cfg: UnitConfig): float =
  ## rho_floor: the crowd density of a hexagonal lattice at the pair law's rest
  ## spacing, where the polynomial repulsion ramp lands at zero and the
  ## attraction bump starts. One neighbour resting there weighs `1 - spacing`
  ## and the floor holds the six a lattice packs, so no lone pair reaches the
  ## onset in a world too sparse for the density ratio to mean anything.
  latticeCrowdDensity(cfg.repulsionEnd)

func crowdOnsetDensity*(cfg: UnitConfig): float =
  ## rho_on = max(x_on * rho-bar, rho_floor), the crowd density the world
  ## pressure starts at: read in the world's own mean, with the contact floor
  ## under it.
  max(cfg.onsetRatio * meanCrowdDensity(cfg), contactFloorDensity(cfg))

func edgeNeighbourSum*(cfg: UnitConfig): float =
  ## Neighbours in the inward half of the attraction annulus of a particle on
  ## the edge of a clump at the onset density. A crowd density rho counts
  ## 3 rho / (pi R^2) particles per unit area, so the half annulus holds
  ## 1.5 rho (1 - repulsionEnd^2).
  1.5 * cfg.onsetRatio * meanCrowdDensity(cfg) *
    (1.0 - cfg.repulsionEnd * cfg.repulsionEnd)

func referenceColonyRadius*(cfg: UnitConfig): float =
  ## Every particle in one disc at the onset density: sqrt(A / (pi x_on)),
  ## independent of the interaction radius.
  sqrt(cfg.worldWidth * cfg.worldHeight / (PI * cfg.onsetRatio))

func unitImpulse*(id: UnitFnId; cfg: UnitConfig): float =
  ## The writer's largest per-particle impulse at `cfg`, in multiples of u0.
  ## The deposit answers in field concentration per cell per field step.
  case id
  of ufSpecies:
    # forces.wgsl: attraction only, every edge neighbour at the bump's peak
    # and pulling straight inward. The law scales the unit bump by 4.0; that
    # is its shape, and the gain is pairGain alone.
    let atPeak = polynomialForce(cfg.attractionPeak.float32,
      cfg.attraction.float32, cfg.repulsionEnd.float32,
      cfg.attractionPeak.float32, 1.0'f32)
    inUnits(cfg.pairGain * atPeak.float * edgeNeighbourSum(cfg))
  of ufWorldPressure:
    # forces.wgsl, per pair: the impulse is largest where both particles carry
    # the stated crowd density and the pair touches, so the proximity weight
    # is 1 and the two pressures are equal. It saturates at q_max.
    let onset = crowdOnsetDensity(cfg).float32
    let pressure = crowdPressure(
      (cfg.crowdRatio * meanCrowdDensity(cfg)).float32, onset)
    worldPressureMagnitude(pressure, pressure, 0.0'f32,
      cfg.pressureStiffness.float32, cfg.pressureImpulseMax.float32).float / u0
  of ufFluid:
    # forces-sph.wgsl, per pair: SPH_FORCE_SCALE times the pair pressure,
    # which reaches the clamp inside the ranges at the lowest rest density,
    # plus the blend at full weight across the widest velocity gap.
    let blend = (cfg.viscosity + SPH_XSPH_EPSILON) * 2.0 * cfg.maxVelocity
    cfg.fluidStrength * (inUnits(SPH_MAX_PRESSURE_ACCEL) + blend / u0)
  of ufScent:
    # field-force.wgsl. The per-cell gradient grows as the pattern shrinks,
    # as 1 / sqrt(patternScale).
    let gradient = RD_INHIBITOR_GRADIENT_PEAK / sqrt(cfg.patternScale)
    let forceScale = cfg.scentGain *
      worldUnitsPerCell(FIELD_W.float, cfg.worldWidth)
    abs(speciesTropismForce(gradient, forceScale, cfg.tropism)) / u0
  of ufLongRange:
    # lr-force.wgsl in the pair unit: one interaction radius past the edge of
    # the reference colony.
    let unit = lrPairUnit(cfg.interactionRadius, cfg.onsetRatio,
      cfg.worldWidth, cfg.worldHeight)
    lrDiscPull(cfg.longRangeStrength, cfg.attraction, unit,
      cfg.particleCount.float,
      referenceColonyRadius(cfg) + cfg.interactionRadius) / u0
  of ufBodies:
    # body-force.wgsl: a body's pull peaks at BODY_FORCE_CEILING, its shape,
    # and every live body can stack on one particle.
    cfg.liveBodies.float * BODY_FORCE_CEILING * cfg.bodiesStrength / u0
  of ufMouse:
    # forces.wgsl: 300 at the pointer.
    inUnits(300.0)
  of ufBlast:
    # forces.wgsl: the divisor floor of 10 puts the peak at distance 10.
    inUnits(cfg.blastStrength * 3000.0 * (1.0 - 10.0 / cfg.blastRange))
  of ufDeposit:
    # field-deposit.wgsl, per particle, at the reference field-step count
    # depositFrameScale holds the rate to.
    abs(speciesDeposit(cfg.depositGain, cfg.secretion))

func longRangeFullEffectGain*(cfg: UnitConfig): float =
  ## g_LR: the long-range gain at which strength 1 pulls a particle one
  ## interaction radius past the reference colony's edge as hard as the pair
  ## force at `cfg.pairGain` holds that edge (F_LR = F_edge).
  var atUnitStrength = cfg
  atUnitStrength.longRangeStrength = 1.0
  unitImpulse(ufSpecies, cfg) / unitImpulse(ufLongRange, atUnitStrength)

# ==============================================================================
# THE STEPPED ORACLE WORLD
# ==============================================================================
# A torus of particles stepped frame by frame on the CPU, so a number the GPU
# would have to be running to report can be read off a native run instead. Each
# substep runs the passes the frame runs, in the frame's order: forces.wgsl's
# pair block over a uniform bin grid, forces-sph.wgsl's fluid block while the
# fluid acts, body-force.wgsl's body block, then integrate.wgsl.
#
# Four differences from a GPU frame, each of which moves the low bits of a
# result:
#   - The fluid block evaluates sph_core's kernels and equation of state in
#     f64 where the shader runs f32, and sums a particle's own register in f64
#     before the f32 split.
#   - The GPU splits a pair by sorted cell position; this splits it by particle
#     index. Which member of a pair plays "this" therefore differs, and with it
#     which side of the pair is quantized per pair rather than once per
#     particle.
#   - Float summation order differs from the shader's, which accumulates in
#     cell order.
#   - The pair block here carries the world pressure, which forces.wgsl does
#     not yet carry.

type
  OracleForceModel* = enum
    ## The two arms forces.wgsl dispatches between on params.forceModel.
    ofmPolynomial
    ofmExponential

  OracleFluidParams* = object
    ## Every number forces-sph.wgsl reads. Strength 0 skips the pass, as the
    ## frame skips it (src/sim_registry.nim's "Fluid" node).
    strength*: float
    radiusFraction*: float
    restDensity*, viscosity*, gamma*: float
    stiffness*: float
      ## The effective stiffness substepPlan hands the frame.
    blend*: float
      ## The XSPH fraction the shader compiles in as SPH_XSPH_EPSILON.
    pressureGain*: float
      ## The shader's SPH_FORCE_SCALE.
    maxPressureAccel*: float
    maxDensityRatio*: float
    densityScale*: float
      ## SPH_DENSITY_FIXED_POINT_SCALE, the kernel density's own encoding.
    coarseShift*: int
      ## VELOCITY_COARSE_SHIFT: the fluid splits every velocity integer across
      ## the fine and coarse words, as the shader does.

  OracleParams* = object
    ## Every number the stepped world reads. The caller supplies each one,
    ## since this module cannot import the module that owns the ranges.
    interactionRadius*: float32
    worldWidth*, worldHeight*: float32
    minDistanceSq*: float32
    forceModel*: OracleForceModel
    forceMultiplier*: float32
    repulsionEnd*, attractionPeak*: float32
    expAlpha*, expBeta*: float32
    crowdingStrength*: float32
    pressureOnset*: float32
      ## rho_on. Zero stiffness leaves it unread.
    pressureStiffness*: float32
    pressureImpulseMax*: float32
    friction*: float32
      ## The retention factor the shader's `params.friction` holds, which is
      ## one minus the slider's friction (src/app.nim:193). Retention 1 damps
      ## nothing; retention 0 stops every particle each step.
    maxVelocity*: float32
    fixedPointScale*: float32
    crowdDensityScale*: float32
      ## The coarser scale a crowd neighbour count is encoded at, which
      ## forces.wgsl:323 names CROWD_DENSITY_FIXED_POINT_SCALE.
    densitySmoothFactor*: float32
    bodiesStrength*: float
    fluid*: OracleFluidParams

  OracleWorld* = object
    ## One world mid-flight. The caller reads and writes `bodies` between
    ## frames; every other field belongs to the step.
    params*: OracleParams
    speciesCount*: int
    matrix*: seq[float32]
      ## Row-major, `matrix[a * speciesCount + b]` being what species `a` feels
      ## toward species `b`.
    posX*, posY*: seq[float32]
    velX*, velY*: seq[float32]
    species*: seq[int]
    colonyDensity*, crowdDensity*: seq[float32]
      ## Both smoothed, as integrate.wgsl:68-79 smooths them.
    sphDensity*: seq[float32]
      ## The fluid's kernel density, stored unsmoothed as integrate.wgsl:89-90
      ## stores it, and read one substep late as the lagged density.
    bodies*: seq[Body]
    bodyEnvelopes*: seq[float]
      ## One envelope per body, in the order `bodies` holds them.
    gridW, gridH: int
    cellStart, cursor: seq[int]
    cellOf, ordered: seq[int]
    deltaFixed, coarseFixed: seq[int32]
    colonyFixed, crowdFixed, sphFixed: seq[int32]
    bodyAccumulators: seq[BodyAccumulator]
    rngState: uint64

func nextBits(state: var uint64): uint64 =
  ## SplitMix64. A seed reproduces a world without a dependency on the
  ## stdlib generator's version.
  state = state + 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

func nextUnit(state: var uint64): float32 =
  ## A draw from [0, 1), 24 bits wide, so every value is exact in f32.
  float32(float(nextBits(state) shr 40) / 16777216.0)

func nextIndex(state: var uint64; bound: int): int =
  int(nextBits(state) mod uint64(bound))

func wrapAdd(sum, word: int32): int32 =
  ## One atomicAdd on an i32, wrapping as WGSL's do.
  cast[int32](cast[uint32](sum) + cast[uint32](word))

proc initOracleWorld*(params: OracleParams; particleCount, speciesCount: int;
    matrix: seq[float32]; seed: int): OracleWorld =
  ## A world of `particleCount` particles at rest, placed uniformly at random
  ## from `seed` and assigned species from the same stream.
  doAssert matrix.len == speciesCount * speciesCount,
    "the matrix holds one entry per ordered species pair"
  let gridW = int(params.worldWidth / params.interactionRadius)
  let gridH = int(params.worldHeight / params.interactionRadius)
  # Below three cells on a side, the nine-cell stencil reaches the same cell
  # twice across the wrap and counts those pairs twice.
  doAssert gridW >= 3 and gridH >= 3,
    "the world spans fewer than three interaction radii on a side"
  result = OracleWorld(params: params, speciesCount: speciesCount,
    matrix: matrix,
    posX: newSeq[float32](particleCount), posY: newSeq[float32](particleCount),
    velX: newSeq[float32](particleCount), velY: newSeq[float32](particleCount),
    species: newSeq[int](particleCount),
    colonyDensity: newSeq[float32](particleCount),
    crowdDensity: newSeq[float32](particleCount),
    sphDensity: newSeq[float32](particleCount),
    gridW: gridW, gridH: gridH,
    cellStart: newSeq[int](gridW * gridH + 1),
    cursor: newSeq[int](gridW * gridH + 1),
    cellOf: newSeq[int](particleCount),
    ordered: newSeq[int](particleCount),
    deltaFixed: newSeq[int32](particleCount * 2),
    coarseFixed: newSeq[int32](particleCount * 2),
    colonyFixed: newSeq[int32](particleCount),
    crowdFixed: newSeq[int32](particleCount),
    sphFixed: newSeq[int32](particleCount),
    rngState: cast[uint64](seed.int64))
  for i in 0 ..< particleCount:
    result.posX[i] = nextUnit(result.rngState) * params.worldWidth
    result.posY[i] = nextUnit(result.rngState) * params.worldHeight
    result.species[i] = nextIndex(result.rngState, speciesCount)

proc rebin(world: var OracleWorld) =
  ## A counting sort of the particles into cells one interaction radius wide.
  let cells = world.gridW * world.gridH
  let invCellW = float32(world.gridW) / world.params.worldWidth
  let invCellH = float32(world.gridH) / world.params.worldHeight
  for cell in 0 .. cells:
    world.cellStart[cell] = 0
  for i in 0 ..< world.posX.len:
    let coords = computeCellCoords(world.posX[i], world.posY[i],
      world.gridW, world.gridH, invCellW, invCellH)
    world.cellOf[i] = cellCoordsToIndex(coords.cx, coords.cy, world.gridW)
    world.cellStart[world.cellOf[i] + 1] += 1
  for cell in 1 .. cells:
    world.cellStart[cell] += world.cellStart[cell - 1]
  for cell in 0 .. cells:
    world.cursor[cell] = world.cellStart[cell]
  for i in 0 ..< world.cellOf.len:
    let cell = world.cellOf[i]
    world.ordered[world.cursor[cell]] = i
    world.cursor[cell] += 1

proc sweepPairs(world: var OracleWorld) =
  ## forces.wgsl's neighbour loop: both density channels and both force terms,
  ## each pair visited once.
  let p = world.params
  let radiusSq = p.interactionRadius * p.interactionRadius
  let invRadius = 1.0'f32 / p.interactionRadius
  let invCellW = float32(world.gridW) / p.worldWidth
  let invCellH = float32(world.gridH) / p.worldHeight
  let pairParams = PairImpulseParams(
    forceMultiplier: p.forceMultiplier,
    pressureOnset: p.pressureOnset,
    pressureStiffness: p.pressureStiffness,
    pressureImpulseMax: p.pressureImpulseMax,
    fixedPointScale: p.fixedPointScale)
  for this in 0 ..< world.posX.len:
    let thisX = world.posX[this]
    let thisY = world.posY[this]
    let thisSpecies = world.species[this]
    let crowdThis = world.crowdDensity[this]
    # forces.wgsl:140-141 hoists the receiving particle's attenuation out of
    # the neighbour loop.
    let attenuationOnThis = crowdingAttenuation(crowdThis, p.crowdingStrength)
    var forceOnThisX = 0.0'f32
    var forceOnThisY = 0.0'f32
    var colonyAccum = 0.0'f32
    var crowdAccum = 0.0'f32
    let coords = computeCellCoords(thisX, thisY, world.gridW, world.gridH,
      invCellW, invCellH)
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let neighbour = getNeighborCell(coords.cx, coords.cy, dx, dy,
          world.gridW, world.gridH, p.worldWidth, p.worldHeight)
        for slot in world.cellStart[neighbour.cell] ..<
            world.cellStart[neighbour.cell + 1]:
          let other = world.ordered[slot]
          if other <= this:
            continue
          let separationX = world.posX[other] + neighbour.wrapX - thisX
          let separationY = world.posY[other] + neighbour.wrapY - thisY
          let distanceSq = separationX * separationX + separationY * separationY
          if distanceSq <= 0.0'f32 or distanceSq >= radiusSq:
            continue
          let distance = sqrt(max(distanceSq, p.minDistanceSq))
          let invDistance = 1.0'f32 / distance
          let normalizedDist = distance * invRadius
          let otherSpecies = world.species[other]
          let crowdOther = world.crowdDensity[other]
          let attenuationOnOther = crowdingAttenuation(crowdOther,
            p.crowdingStrength)
          let attractionOnThis =
            world.matrix[thisSpecies * world.speciesCount + otherSpecies]
          let attractionOnOther =
            world.matrix[otherSpecies * world.speciesCount + thisSpecies]
          var magnitudeOnThis, magnitudeOnOther: float32
          case p.forceModel
          of ofmPolynomial:
            magnitudeOnThis = polynomialForce(normalizedDist, attractionOnThis,
              p.repulsionEnd, p.attractionPeak, attenuationOnThis)
            magnitudeOnOther = polynomialForce(normalizedDist,
              attractionOnOther, p.repulsionEnd, p.attractionPeak,
              attenuationOnOther)
          of ofmExponential:
            magnitudeOnThis = exponentialForce(normalizedDist, attractionOnThis,
              p.expAlpha, p.expBeta, attenuationOnThis)
            magnitudeOnOther = exponentialForce(normalizedDist,
              attractionOnOther, p.expAlpha, p.expBeta, attenuationOnOther)
          let impulse = pairImpulse(pairParams, separationX, separationY,
            invDistance, normalizedDist, magnitudeOnThis, magnitudeOnOther,
            crowdThis, crowdOther)
          forceOnThisX += impulse.speciesOnThis.x
          forceOnThisY += impulse.speciesOnThis.y
          world.deltaFixed[other * 2] = wrapAdd(world.deltaFixed[other * 2],
            forcesVelocityDeltaFixed(impulse.speciesOnOther.x,
              p.fixedPointScale))
          world.deltaFixed[other * 2 + 1] =
            wrapAdd(world.deltaFixed[other * 2 + 1],
              forcesVelocityDeltaFixed(impulse.speciesOnOther.y,
                p.fixedPointScale))
          # The pressure is quantized once for the pair and negated, so the two
          # sides cannot disagree.
          let onOther = pressureOnOther(impulse)
          world.deltaFixed[this * 2] = wrapAdd(world.deltaFixed[this * 2],
            impulse.pressureOnThis.x)
          world.deltaFixed[this * 2 + 1] =
            wrapAdd(world.deltaFixed[this * 2 + 1], impulse.pressureOnThis.y)
          world.deltaFixed[other * 2] = wrapAdd(world.deltaFixed[other * 2],
            onOther.x)
          world.deltaFixed[other * 2 + 1] =
            wrapAdd(world.deltaFixed[other * 2 + 1], onOther.y)
          let proximityWeight = 1.0'f32 - normalizedDist
          crowdAccum += proximityWeight
          world.crowdFixed[other] = wrapAdd(world.crowdFixed[other],
            int32(proximityWeight * p.crowdDensityScale))
          if otherSpecies == thisSpecies:
            colonyAccum += proximityWeight
            world.colonyFixed[other] = wrapAdd(world.colonyFixed[other],
              int32(proximityWeight * p.fixedPointScale))
    world.deltaFixed[this * 2] = wrapAdd(world.deltaFixed[this * 2],
      forcesVelocityDeltaFixed(forceOnThisX, p.fixedPointScale))
    world.deltaFixed[this * 2 + 1] = wrapAdd(world.deltaFixed[this * 2 + 1],
      forcesVelocityDeltaFixed(forceOnThisY, p.fixedPointScale))
    world.colonyFixed[this] = wrapAdd(world.colonyFixed[this],
      int32(colonyAccum * p.fixedPointScale))
    world.crowdFixed[this] = wrapAdd(world.crowdFixed[this],
      int32(crowdAccum * p.crowdDensityScale))

proc addSplit(world: var OracleWorld; slot: int; words: VelocityWords) =
  world.deltaFixed[slot] = wrapAdd(world.deltaFixed[slot], words.fine)
  world.coarseFixed[slot] = wrapAdd(world.coarseFixed[slot], words.coarse)

proc sweepFluid(world: var OracleWorld) =
  ## forces-sph.wgsl's neighbour loop (:240-326): the pressure and the
  ## velocity blend on both sides of each pair, and the fresh kernel density.
  let p = world.params
  let f = p.fluid
  let smoothingRadius = p.interactionRadius * f.radiusFraction.float32
  let radiusSq = smoothingRadius * smoothingRadius
  let h = smoothingRadius.float
  let selfPoly6 = poly6Weight2d(0.0, h)
  let selfSpiky = spikyGradientMagnitude2d(0.0, h)
  let invSelfPoly6 = if selfPoly6 > 0.0: 1.0 / selfPoly6 else: 0.0
  let invSelfSpiky = if selfSpiky > 0.0: 1.0 / selfSpiky else: 0.0
  let invCellW = float32(world.gridW) / p.worldWidth
  let invCellH = float32(world.gridH) / p.worldHeight
  # The shader forms each side's pressure from its lagged density alone, so it
  # is formed here once per particle.
  let n = world.posX.len
  var pressureDensity = newSeq[float](n)
  var pressureOverDensitySq = newSeq[float](n)
  for i in 0 ..< n:
    pressureDensity[i] = clamp(world.sphDensity[i].float, f.restDensity,
      f.restDensity * f.maxDensityRatio)
    pressureOverDensitySq[i] = taitPressure(pressureDensity[i],
      f.restDensity, f.stiffness, f.gamma) /
      (pressureDensity[i] * pressureDensity[i])
  for this in 0 ..< n:
    let thisX = world.posX[this]
    let thisY = world.posY[this]
    let laggedThis = world.sphDensity[this].float
    var sumX = 0.0
    var sumY = 0.0
    var densityAccum = 1.0
    let coords = computeCellCoords(thisX, thisY, world.gridW, world.gridH,
      invCellW, invCellH)
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let neighbour = getNeighborCell(coords.cx, coords.cy, dx, dy,
          world.gridW, world.gridH, p.worldWidth, p.worldHeight)
        for slot in world.cellStart[neighbour.cell] ..<
            world.cellStart[neighbour.cell + 1]:
          let other = world.ordered[slot]
          if other <= this:
            continue
          let separationX = world.posX[other] + neighbour.wrapX - thisX
          let separationY = world.posY[other] + neighbour.wrapY - thisY
          let distanceSq = separationX * separationX + separationY * separationY
          if distanceSq <= 0.0'f32 or distanceSq >= radiusSq:
            continue
          let distance = sqrt(max(distanceSq, p.minDistanceSq))
          let invDistance = 1.0'f32 / distance
          let directionX = (separationX * invDistance).float
          let directionY = (separationY * invDistance).float
          let densityWeight = poly6Weight2d(distance.float, h) * invSelfPoly6
          let gradientWeight =
            spikyGradientMagnitude2d(distance.float, h) * invSelfSpiky
          let pairPressure =
            pressureOverDensitySq[this] + pressureOverDensitySq[other]
          let pressureAccel = clamp(f.pressureGain * pairPressure *
            gradientWeight, -f.maxPressureAccel, f.maxPressureAccel)
          let smoothDenominator =
            max(max(laggedThis, world.sphDensity[other].float), 1.0)
          let smoothCoefficient =
            (f.viscosity + f.blend) * densityWeight / smoothDenominator
          let gapX = (world.velX[other] - world.velX[this]).float
          let gapY = (world.velY[other] - world.velY[this]).float
          let pairX = f.strength *
            ((-pressureAccel * directionX) * FRAME_DT_REFERENCE +
              smoothCoefficient * gapX)
          let pairY = f.strength *
            ((-pressureAccel * directionY) * FRAME_DT_REFERENCE +
              smoothCoefficient * gapY)
          sumX += pairX
          sumY += pairY
          densityAccum += densityWeight
          world.addSplit(other * 2, splitVelocityWord(
            int32(-pairX * p.fixedPointScale.float), f.coarseShift))
          world.addSplit(other * 2 + 1, splitVelocityWord(
            int32(-pairY * p.fixedPointScale.float), f.coarseShift))
          world.sphFixed[other] = wrapAdd(world.sphFixed[other],
            int32(densityWeight * f.densityScale))
    world.addSplit(this * 2, splitVelocitySum(sumX.float32,
      p.fixedPointScale, f.coarseShift))
    world.addSplit(this * 2 + 1, splitVelocitySum(sumY.float32,
      p.fixedPointScale, f.coarseShift))
    world.sphFixed[this] = wrapAdd(world.sphFixed[this],
      int32(densityAccum * f.densityScale))

proc applyBodies(world: var OracleWorld; dtSeconds: float) =
  ## body-force.wgsl: every live body's pull on every particle, summed and
  ## encoded once per particle, with the negated sum taken by the body.
  if world.bodies.len == 0:
    return
  let p = world.params
  let worldW = p.worldWidth.float
  let worldH = p.worldHeight.float
  world.bodyAccumulators.setLen(world.bodies.len)
  for slot in 0 ..< world.bodyAccumulators.len:
    world.bodyAccumulators[slot] = BodyAccumulator()
  for i in 0 ..< world.posX.len:
    let atX = world.posX[i].float
    let atY = world.posY[i].float
    var totalX = 0.0
    var totalY = 0.0
    for slot in 0 ..< world.bodies.len:
      let envelope = world.bodyEnvelopes[slot]
      if envelope == 0.0:
        continue
      let force = bodyForceAt(world.bodies[slot], atX, atY, worldW, worldH,
        envelope, p.bodiesStrength)
      if force.x == 0.0 and force.y == 0.0:
        continue
      totalX += force.x
      totalY += force.y
      addBodyReaction(world.bodyAccumulators[slot], world.bodies[slot],
        atX, atY, worldW, worldH, force.x, force.y)
    # A body's pull is already a velocity per reference frame, so no dt meets
    # it at the encode.
    world.deltaFixed[i * 2] = wrapAdd(world.deltaFixed[i * 2],
      encodeVelocityDelta(totalX.float32, p.fixedPointScale))
    world.deltaFixed[i * 2 + 1] = wrapAdd(world.deltaFixed[i * 2 + 1],
      encodeVelocityDelta(totalY.float32, p.fixedPointScale))
  for slot in 0 ..< world.bodies.len:
    let reaction = decoded(world.bodyAccumulators[slot])
    world.bodies[slot] = bodyRigidStep(world.bodies[slot], reaction.forceX,
      reaction.forceY, reaction.torque, dtSeconds, worldW, worldH)

when defined(calibratePerStepCap):
  func perStepCapVelocity(velocity: tuple[x, y: float32];
      deltaFixed: tuple[x, y: int32];
      invFixedPointScale, frameFactor, friction, maxVelocity: float32):
      tuple[x, y: float32] =
    ## integrateVelocity with the soft cap acting on the speed per step, as
    ## integrate.wgsl did before the cap moved to per reference frame.
    let newVelX = (velocity.x + decodeVelocityDelta(deltaFixed.x,
      invFixedPointScale, frameFactor)) * friction
    let newVelY = (velocity.y + decodeVelocityDelta(deltaFixed.y,
      invFixedPointScale, frameFactor)) * friction
    let speed = sqrt(newVelX * newVelX + newVelY * newVelY)
    if speed <= 0.0'f32:
      return (x: newVelX, y: newVelY)
    let scale = postStepSpeed(speed, 1.0'f32, maxVelocity) / speed
    (x: newVelX * scale, y: newVelY * scale)

proc integrateParticles(world: var OracleWorld; subFrameFactor: float32) =
  ## integrate.wgsl: both densities smoothed, the delta decoded once against
  ## the substep's frame factor, friction, the speed cap, then the position.
  let p = world.params
  let invFixed = 1.0'f32 / p.fixedPointScale
  let invCrowd = 1.0'f32 / p.crowdDensityScale
  let carried = p.densitySmoothFactor
  let arriving = 1.0'f32 - carried
  let fluidActs = p.fluid.strength != 0.0
  let invSph =
    if fluidActs: 1.0'f32 / p.fluid.densityScale.float32 else: 0.0'f32
  for i in 0 ..< world.posX.len:
    world.colonyDensity[i] = world.colonyDensity[i] * carried +
      float32(world.colonyFixed[i]) * invFixed * arriving
    world.crowdDensity[i] = world.crowdDensity[i] * carried +
      float32(world.crowdFixed[i]) * invCrowd * arriving
    world.sphDensity[i] = float32(world.sphFixed[i]) * invSph
    let decodedX = decodeVelocityWords(
      (fine: world.deltaFixed[i * 2], coarse: world.coarseFixed[i * 2]),
      invFixed, subFrameFactor, p.fluid.coarseShift)
    let decodedY = decodeVelocityWords(
      (fine: world.deltaFixed[i * 2 + 1], coarse: world.coarseFixed[i * 2 + 1]),
      invFixed, subFrameFactor, p.fluid.coarseShift)
    # integrateVelocity decodes one word, so the two are rejoined above and a
    # zero word passed, which adds exactly nothing.
    let joined = (x: world.velX[i] + decodedX, y: world.velY[i] + decodedY)
    # Two diagnostic variants, never the shipped integrate: the per-step cap
    # of before the per-reference-frame one, and friction as retention^ff.
    let retention = when defined(calibrateFrictionPerFrame):
        pow(p.friction, subFrameFactor)
      else: p.friction
    let stepped = when defined(calibratePerStepCap):
        perStepCapVelocity(joined, (x: 0'i32, y: 0'i32), invFixed,
          subFrameFactor, retention, p.maxVelocity)
      else:
        integrateVelocity(joined, (x: 0'i32, y: 0'i32), invFixed,
          subFrameFactor, retention, p.maxVelocity)
    world.velX[i] = stepped.x
    world.velY[i] = stepped.y
    world.posX[i] = wrapPosition(world.posX[i] + stepped.x, p.worldWidth)
    world.posY[i] = wrapPosition(world.posY[i] + stepped.y, p.worldHeight)

proc stepFrame*(world: var OracleWorld; frameFactor: float; substeps: int) =
  ## One frame, taken in `substeps` equal substeps. Each advances
  ## `frameFactor / substeps` reference frames and runs every pass, which is
  ## what a substep is for.
  let taken = max(substeps, 1)
  let subFrameFactor = frameFactor / taken.float
  for _ in 0 ..< taken:
    for i in 0 ..< world.deltaFixed.len:
      world.deltaFixed[i] = 0
      world.coarseFixed[i] = 0
    for i in 0 ..< world.colonyFixed.len:
      world.colonyFixed[i] = 0
      world.crowdFixed[i] = 0
      world.sphFixed[i] = 0
    rebin(world)
    sweepPairs(world)
    if world.params.fluid.strength != 0.0:
      sweepFluid(world)
    applyBodies(world, subFrameFactor * FRAME_DT_REFERENCE)
    integrateParticles(world, subFrameFactor.float32)

func meanSpeed*(world: OracleWorld): float =
  ## The mean of |v| over every particle, in world units per reference frame.
  if world.posX.len == 0:
    return 0.0
  for i in 0 ..< world.posX.len:
    result += sqrt(world.velX[i].float * world.velX[i].float +
      world.velY[i].float * world.velY[i].float)
  result /= world.posX.len.float

func meanSpeedBeyond*(world: OracleWorld; bodies: seq[Body];
    clearance: float): float =
  ## The mean of |v| over the particles no body in `bodies` reaches within
  ## `clearance` of its surface. With no body, every particle.
  var counted = 0
  for i in 0 ..< world.posX.len:
    var reached = false
    for body in bodies:
      let sample = sampleBody(body, world.posX[i].float, world.posY[i].float,
        world.params.worldWidth.float, world.params.worldHeight.float)
      if abs(sample.distance) < clearance:
        reached = true
        break
    if reached:
      continue
    result += sqrt(world.velX[i].float * world.velX[i].float +
      world.velY[i].float * world.velY[i].float)
    counted += 1
  if counted > 0:
    result /= counted.float

func peakCrowdDensity*(world: OracleWorld): float =
  ## The busiest particle's smoothed crowd density.
  for value in world.crowdDensity:
    result = max(result, value.float)

func meanWeightedNeighbours*(world: OracleWorld): float =
  ## The mean smoothed crowd density, which is a neighbour count weighted by
  ## the proximity weight forces.wgsl:319 gives each neighbour.
  if world.crowdDensity.len == 0:
    return 0.0
  for value in world.crowdDensity:
    result += value.float
  result /= world.crowdDensity.len.float

func summedVelocityDelta*(world: OracleWorld): tuple[x, y: float] =
  ## The last substep's velocity delta summed over every particle, per
  ## component, in fixed-point quanta, with the coarse word rejoined to the
  ## fine. At force multiplier zero with no body live and no fluid, the only
  ## writer left is the world pressure, whose pair integer is negated for the
  ## other side, so the sum reads exactly zero.
  let coarseUnit = float(1 shl world.params.fluid.coarseShift)
  for i in 0 ..< world.posX.len:
    result.x += world.deltaFixed[i * 2].float +
      world.coarseFixed[i * 2].float * coarseUnit
    result.y += world.deltaFixed[i * 2 + 1].float +
      world.coarseFixed[i * 2 + 1].float * coarseUnit
