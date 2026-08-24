# How much velocity each of the three force layers hands the integrator.
#
# forces.wgsl, forces-sph.wgsl and field-force.wgsl all atomicAdd into one
# velocityDeltaFixed buffer, and integrate.wgsl reads the sum, applies friction
# and compresses it through a logarithmic soft cap. Everything below measures
# the three contributions where they enter that buffer: before friction, before
# the cap, summed across the substeps webgpu_compute encodes per rendered frame,
# and attributed to the layer that produced them.
#
# The measurement runs through the pure mirrors the native suite can execute:
# physics_core for the species force, sph_core for the fluid, field_core for the
# reaction-diffusion field. Nothing in src/ reads anything defined here.

import std/[unittest, math, algorithm, os, strutils, times]
import ../src/physics_core
import ../src/sph_core
import ../src/field_core
import ../src/shader_config
from ../src/ui/state/simulation_state import initSimulationState
from ../src/memory_layout import MAX_GRID, MAX_SPECIES
from ../src/config_ranges import FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX,
  FLUID_STRENGTH_MIN, FLUID_STRENGTH_MAX, RD_FIELD_FORCE_MIN,
  RD_FIELD_FORCE_MAX, TIME_SCALE_MIN, TIME_SCALE_MAX, SPH_SUBSTEPS_MIN,
  SPH_SUBSTEPS_MAX, INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX,
  MATRIX_MAX_VALUE, SECRETION_MAX, TROPISM_MAX, RD_DEPOSIT_MAX

const FORCE_BUDGET_TESTS_LOADED* = true

# ==============================================================================
# THE REFERENCE SCENE
# ==============================================================================

const
  REFERENCE_WORLD_WIDTH = 3840.0
  REFERENCE_WORLD_HEIGHT = 2160.0
    ## src/config.nim's WORLD_W and WORLD_H. Read back from that file by the
    ## geometry test below rather than trusted, because this module is pure and
    ## config.nim carries FFI pragmas it cannot import.
  REFERENCE_PARTICLE_COUNT = 16000
    ## simulation_state's shipped particleCount. Every cost figure in the report
    ## is quoted at this count.
  REFERENCE_NUMBER_DENSITY = REFERENCE_PARTICLE_COUNT.float /
    (REFERENCE_WORLD_WIDTH * REFERENCE_WORLD_HEIGHT)
    ## 1.93e-3 particles per square pixel. The density every other geometry here
    ## is scaled to hold.
  REFERENCE_SEED = 0x9E3779B9'u32
    ## The fixed LCG seed test_sph_core and test_field_core both scatter from.
  REFERENCE_FRAME_SECONDS = 1.0 / 60.0
    ## The wall-clock frame app.nim's loop multiplies timeScale by.
  GRID_CELL_FLOOR = 16
    ## grid.nim floors the spatial hash cell at this, below the smallest
    ## interaction radius the slider offers.

  PARTICLE_SETTLE_FRAMES = 20
  PARTICLE_WINDOW_FRAMES = 10
  FIELD_SETTLE_FRAMES = 250
    ## Frames the field runs alone from its seed before any particle touches it.
    ## Measured: the grid-mean inhibitor gradient is within 1% of its limit by
    ## frame 210 and within 0.3% by frame 250, approached from both a sparse and
    ## a dense seed.
  FIELD_POINT_SETTLE_FRAMES = 120
    ## Frames a field point runs before its window opens. The settled field is
    ## reached with no particle in it, so introducing the population re-opens a
    ## transient: the deposit perturbs the pattern and the particles accelerate
    ## from rest. At 30 frames that transient is still running, at 0.24 relative
    ## drift across the window.
  FIELD_WINDOW_FRAMES = 20
  SETTLING_TOLERANCE = 0.05
    ## A run counts as settled when the mean budget over the first half of its
    ## measurement window and the mean over the second half differ by less than
    ## this fraction of the larger.

let
  shipped = initSimulationState()
  referenceSpeciesCount = shipped.speciesCount

# ==============================================================================
# THE ATTRACTION MATRIX
# ==============================================================================
# A cyclic chase at the edges of the matrix band: species i is drawn to its
# successor at +MATRIX_MAX_VALUE, pushed from its predecessor at
# -MATRIX_MAX_VALUE, and holds itself at half the band.
#
# Chosen to exercise, in one scene, every branch the force law has: the crowding
# gate's positive side (the successor and self entries), the negative side it
# leaves untouched (the predecessor entry), and a pair carrying no matrix entry
# at all, which is repulsion alone. No entry equals its transpose, so the two
# halves of a pair never cancel by symmetry, and every entry sits at a band edge,
# which is where the species force is largest and so where its budget is most
# favourably measured.

proc referenceMatrix(speciesCount: int): seq[seq[float32]] =
  result = newSeq[seq[float32]](MAX_SPECIES)
  for row in result.mitems:
    row = newSeq[float32](MAX_SPECIES)
  for i in 0 ..< speciesCount:
    result[i][i] = float32(MATRIX_MAX_VALUE * 0.5)
    result[i][(i + 1) mod speciesCount] = float32(MATRIX_MAX_VALUE)
    result[i][(i + speciesCount - 1) mod speciesCount] = float32(-MATRIX_MAX_VALUE)

# ==============================================================================
# THE FORCE CURVE
# ==============================================================================

type
  ForceCurve = enum
    fcPolynomial
      ## forces.wgsl MODEL 0 at the shipped repulsionEnd and attractionPeak,
      ## which is what simulation_state's forceModel 0 selects.
    fcFixed
      ## physics_core.calculateAttenuatedForce's 0.3/1.3/0.7 curve, which no
      ## shipped forceModel selects. Carried so the pair loop can be held to
      ## that mirror pair for pair.

func pairForce(curve: ForceCurve; normalizedDist, attraction, forceMultiplier,
    invDistance, crowdDensity, crowdingStrength, repulsionEnd,
    attractionPeak: float32): float32 =
  case curve
  of fcPolynomial:
    polynomialForce(normalizedDist, attraction, repulsionEnd, attractionPeak,
      crowdingAttenuation(crowdDensity, crowdingStrength)) *
      forceMultiplier * invDistance
  of fcFixed:
    calculateAttenuatedForce(normalizedDist, attraction, forceMultiplier,
      invDistance, crowdDensity, crowdingStrength)

# ==============================================================================
# THE SCENE
# ==============================================================================

type
  SceneParticle = object
    x, y: float
    vx, vy: float
    species: int
    crowdDensity: float
      ## Smoothed, as integrate.wgsl writes it: the crowding term reads this.
    sphDensity: float
      ## Lagged by one substep, exactly as forces-sph.wgsl reads it.

  SceneConfig = object
    particleCount: int
    worldWidth, worldHeight: float
    interactionRadius: float
    forceStrength: float
    fluidStrength: float
    fieldForceScale: float
    deposit: float
    timeScale: float
    substeps: int
    curve: ForceCurve
    crowdingStrength: float
    repulsionEnd, attractionPeak: float
    stiffness, restDensity, radiusFraction, viscosity: float
    friction, maxVelocity: float

  Layer = enum
    lySpecies, lyFluid, lyField

  Budget = object
    ## px per frame at the integrator's input, over every (particle, frame)
    ## sample in the measurement window.
    mean: float
    p95: float
    capSaturated: float
      ## Fraction of samples where this layer's own summed delta, after
      ## friction, clears the soft-cap threshold and so enters integrate.wgsl's
      ## compressive branch by itself.
    drift: float
      ## Relative gap between the window's first-half and second-half means.
    samples: int

proc referenceScene(): SceneConfig =
  SceneConfig(
    particleCount: REFERENCE_PARTICLE_COUNT,
    worldWidth: REFERENCE_WORLD_WIDTH,
    worldHeight: REFERENCE_WORLD_HEIGHT,
    interactionRadius: shipped.interactionRadius.float,
    forceStrength: shipped.forceStrength,
    fluidStrength: shipped.fluidStrength,
    fieldForceScale: shipped.rdFieldForce,
    deposit: shipped.rdDeposit,
    timeScale: shipped.timeScale,
    substeps: shipped.sphSubsteps,
    curve: fcPolynomial,
    crowdingStrength: shipped.crowdingStrength,
    repulsionEnd: shipped.repulsionEnd,
    attractionPeak: shipped.attractionPeak,
    stiffness: shipped.sphStiffness,
    restDensity: shipped.sphRestDensity,
    radiusFraction: shipped.sphRadiusFraction,
    viscosity: shipped.sphViscosity,
    friction: shipped.friction,
    maxVelocity: shipped.maxVelocity)

func effectiveSubsteps(cfg: SceneConfig): int =
  ## webgpu_compute encodes the whole frame description substepCount times, and
  ## substepCount is 1 unless the fluid acts. sphSubsteps therefore reaches the
  ## other two layers only through a world whose fluid is switched on.
  if cfg.fluidStrength != 0.0:
    clamp(cfg.substeps, SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX)
  else:
    1

func substepDtOf(cfg: SceneConfig): float =
  cfg.timeScale * REFERENCE_FRAME_SECONDS / effectiveSubsteps(cfg).float

func sceneGrid(cfg: SceneConfig): tuple[w, h: int] =
  ## grid.computeGridDimensions, whose cell tracks the interaction radius so a
  ## 3x3 stencil covers every interaction.
  let cellSize = max(int(cfg.interactionRadius), GRID_CELL_FLOOR)
  (w: clamp(int(cfg.worldWidth / cellSize.float), 1, MAX_GRID),
   h: clamp(int(cfg.worldHeight / cellSize.float), 1, MAX_GRID))

proc sceneSeed(cfg: SceneConfig; speciesCount: int): seq[SceneParticle] =
  ## Deterministic scatter at rest, from REFERENCE_SEED. A lattice would put
  ## every particle at the one arrangement whose forces cancel by symmetry.
  var state = REFERENCE_SEED
  for index in 0 ..< cfg.particleCount:
    state = state * 1664525'u32 + 1013904223'u32
    let sampleX = (state shr 8).float / 16777216.0
    state = state * 1664525'u32 + 1013904223'u32
    let sampleY = (state shr 8).float / 16777216.0
    result.add SceneParticle(
      x: sampleX * cfg.worldWidth, y: sampleY * cfg.worldHeight,
      species: index mod speciesCount)

# ==============================================================================
# ONE SUBSTEP OF THE FORCE SWEEP
# ==============================================================================

type SweepResult = object
  speciesX, speciesY: seq[float]
  fluidX, fluidY: seq[float]

proc forceSweep(cfg: SceneConfig; particles: var seq[SceneParticle];
    matrix: seq[seq[float32]]; substepDt: float): SweepResult =
  ## One substep of forces.wgsl and forces-sph.wgsl over the whole population,
  ## returning each layer's velocity delta for each particle.
  ##
  ## The neighbour iteration is physics_core.getNeighborCell over the full 3x3
  ## block. forces.wgsl visits 5 cells and applies each pair to both particles
  ## through Newton's third law; both per-pair contributions are antisymmetric
  ## under swapping the pair, so gathering all nine cells from the receiving
  ## particle's side accumulates the same sum.
  let count = particles.len
  let grid = sceneGrid(cfg)
  let invCellWidth = float32(grid.w.float / cfg.worldWidth)
  let invCellHeight = float32(grid.h.float / cfg.worldHeight)
  let smoothingRadius = cfg.interactionRadius * cfg.radiusFraction
  let smoothingRadiusSq = smoothingRadius * smoothingRadius
  let minDistanceSq = getTunableFloat("MIN_DISTANCE_SQ")
  let densitySmoothFactor = getTunableFloat("DENSITY_SMOOTH_FACTOR")
  let maxPressureDensity =
    cfg.restDensity * getTunableFloat("SPH_MAX_DENSITY_RATIO")
  let velocitySmoothing = cfg.viscosity + SPH_XSPH_EPSILON
  let selfPoly6 = poly6Weight2d(0.0, smoothingRadius)
  let selfSpikyGradient = spikyGradientMagnitude2d(0.0, smoothingRadius)
  let fluidActs = cfg.fluidStrength != 0.0

  var cells = newSeq[seq[int]](grid.w * grid.h)
  for index in 0 ..< count:
    let coords = computeCellCoords(particles[index].x.float32,
      particles[index].y.float32, grid.w, grid.h, invCellWidth, invCellHeight)
    cells[cellCoordsToIndex(coords.cx, coords.cy, grid.w)].add index

  # The pressure over density squared each particle carries into this substep,
  # formed from the lagged density the shader reads and hoisted out of the pair
  # loop the way forces-sph.wgsl hoists it.
  var pressureTerm = newSeq[float](count)
  var laggedDensity = newSeq[float](count)
  if fluidActs:
    for index in 0 ..< count:
      let density = clamp(particles[index].sphDensity, cfg.restDensity,
        maxPressureDensity)
      pressureTerm[index] =
        taitPressure(density, cfg.restDensity, cfg.stiffness,
          SPH_DEFAULT_GAMMA) / (density * density)
      laggedDensity[index] = particles[index].sphDensity

  result.speciesX = newSeq[float](count)
  result.speciesY = newSeq[float](count)
  result.fluidX = newSeq[float](count)
  result.fluidY = newSeq[float](count)
  var crowdDensity = newSeq[float](count)
  var sphDensity = newSeq[float](count)

  for index in 0 ..< count:
    let coords = computeCellCoords(particles[index].x.float32,
      particles[index].y.float32, grid.w, grid.h, invCellWidth, invCellHeight)
    var forceX = 0.0
    var forceY = 0.0
    var fluidX = 0.0
    var fluidY = 0.0
    var crowdAccum = 0.0
    var densityAccum = 1.0  # forces-sph.wgsl's normalized self-density
    let attenuationDensity = particles[index].crowdDensity.float32
    for offsetY in -1 .. 1:
      for offsetX in -1 .. 1:
        let neighbour = getNeighborCell(coords.cx, coords.cy, offsetX, offsetY,
          grid.w, grid.h, cfg.worldWidth.float32, cfg.worldHeight.float32)
        for other in cells[neighbour.cell]:
          if other == index: continue
          let separationX = (particles[other].x.float32 + neighbour.wrapX) -
            particles[index].x.float32
          let separationY = (particles[other].y.float32 + neighbour.wrapY) -
            particles[index].y.float32
          let normalized = normalizeDistance(separationX, separationY,
            cfg.interactionRadius.float32, float32(minDistanceSq))
          if normalized.valid:
            let attraction =
              matrix[particles[index].species][particles[other].species]
            let magnitude = pairForce(cfg.curve, normalized.normalizedDist,
              attraction, cfg.forceStrength.float32, normalized.invD,
              attenuationDensity, cfg.crowdingStrength.float32,
              cfg.repulsionEnd.float32, cfg.attractionPeak.float32)
            forceX += float(separationX * magnitude)
            forceY += float(separationY * magnitude)
            crowdAccum += float(1.0'f32 - normalized.normalizedDist)

          if fluidActs:
            let distanceSq = float(separationX * separationX +
              separationY * separationY)
            if distanceSq > 0.0 and distanceSq < smoothingRadiusSq:
              let distance = sqrt(max(distanceSq, minDistanceSq))
              let invDistance = 1.0 / distance
              let directionX = float(separationX) * invDistance
              let directionY = float(separationY) * invDistance
              let densityWeight =
                poly6Weight2d(distance, smoothingRadius) / selfPoly6
              let gradientWeight =
                spikyGradientMagnitude2d(distance, smoothingRadius) /
                  selfSpikyGradient
              let pressureAccel = clamp(
                SPH_FORCE_SCALE * (pressureTerm[index] + pressureTerm[other]) *
                  gradientWeight,
                -SPH_MAX_PRESSURE_ACCEL, SPH_MAX_PRESSURE_ACCEL)
              let smoothDenominator =
                max(max(laggedDensity[index], laggedDensity[other]), 1.0)
              let smoothCoefficient =
                velocitySmoothing * densityWeight / smoothDenominator
              fluidX += cfg.fluidStrength *
                ((-pressureAccel * directionX) * substepDt +
                  smoothCoefficient * (particles[other].vx - particles[index].vx))
              fluidY += cfg.fluidStrength *
                ((-pressureAccel * directionY) * substepDt +
                  smoothCoefficient * (particles[other].vy - particles[index].vy))
              densityAccum += densityWeight

    # forces.wgsl multiplies the accumulated species force by params.dt at the
    # atomicAdd; the fluid's pressure term already carries it and its velocity
    # blend deliberately does not.
    result.speciesX[index] = forceX * substepDt
    result.speciesY[index] = forceY * substepDt
    result.fluidX[index] = fluidX
    result.fluidY[index] = fluidY
    crowdDensity[index] = crowdAccum
    sphDensity[index] = densityAccum

  for index in 0 ..< count:
    particles[index].crowdDensity =
      particles[index].crowdDensity * densitySmoothFactor +
        crowdDensity[index] * (1.0 - densitySmoothFactor)
    if fluidActs:
      particles[index].sphDensity = sphDensity[index]

proc integrateParticle(cfg: SceneConfig; particle: var SceneParticle;
    deltaX, deltaY: float) =
  ## integrate.wgsl: friction on the summed delta, the logarithmic soft cap,
  ## then a position advanced by the velocity itself with a toroidal wrap.
  let retention = 1.0 - cfg.friction
  var velocityX = (particle.vx + deltaX) * retention
  var velocityY = (particle.vy + deltaY) * retention
  let speed = sqrt(velocityX * velocityX + velocityY * velocityY)
  let softCapThreshold = cfg.maxVelocity * 0.5
  if speed > softCapThreshold and speed > 0.0:
    let compressed = softCapThreshold + ln(1.0 + (speed - softCapThreshold))
    let scale = min(compressed, cfg.maxVelocity) / speed
    velocityX = velocityX * scale
    velocityY = velocityY * scale
  particle.vx = velocityX
  particle.vy = velocityY
  particle.x = wrapPosition(float32(particle.x + velocityX),
    float32(cfg.worldWidth)).float
  particle.y = wrapPosition(float32(particle.y + velocityY),
    float32(cfg.worldHeight)).float

# ==============================================================================
# THE BUDGET
# ==============================================================================

type BudgetAccumulator = object
  samples: seq[float]
  frameMeans: seq[float]
  saturated: int

proc addFrame(accumulator: var BudgetAccumulator; magnitudes: seq[float];
    cfg: SceneConfig) =
  let retention = 1.0 - cfg.friction
  let softCapThreshold = cfg.maxVelocity * 0.5
  var total = 0.0
  for magnitude in magnitudes:
    accumulator.samples.add magnitude
    total += magnitude
    if magnitude * retention > softCapThreshold:
      inc accumulator.saturated
  accumulator.frameMeans.add total / magnitudes.len.float

proc finish(accumulator: BudgetAccumulator): Budget =
  if accumulator.samples.len == 0:
    return Budget()
  var sorted = accumulator.samples
  sort(sorted)
  var total = 0.0
  for value in sorted: total += value
  let half = accumulator.frameMeans.len div 2
  var firstHalf = 0.0
  var secondHalf = 0.0
  for index in 0 ..< half: firstHalf += accumulator.frameMeans[index]
  for index in half ..< accumulator.frameMeans.len:
    secondHalf += accumulator.frameMeans[index]
  let firstMean = (if half > 0: firstHalf / half.float else: 0.0)
  let secondMean = secondHalf / float(accumulator.frameMeans.len - half)
  let largest = max(abs(firstMean), abs(secondMean))
  Budget(
    mean: total / sorted.len.float,
    p95: sorted[int(0.95 * float(sorted.len - 1))],
    capSaturated: accumulator.saturated.float / sorted.len.float,
    drift: (if largest > 0.0: abs(firstMean - secondMean) / largest else: 0.0),
    samples: sorted.len)

func magnitudes(xs, ys: seq[float]): seq[float] =
  result = newSeq[float](xs.len)
  for index in 0 ..< xs.len:
    result[index] = sqrt(xs[index] * xs[index] + ys[index] * ys[index])

# ==============================================================================
# THE PARTICLE SCENE: THE SPECIES AND FLUID LAYERS
# ==============================================================================

proc runParticleScene(cfg: SceneConfig; settleFrames, windowFrames: int):
    tuple[species, fluid: Budget, secondsPerFrame: float] =
  let matrix = referenceMatrix(referenceSpeciesCount)
  var particles = sceneSeed(cfg, referenceSpeciesCount)
  let substepDt = substepDtOf(cfg)
  let substeps = effectiveSubsteps(cfg)
  var speciesAccumulator = BudgetAccumulator()
  var fluidAccumulator = BudgetAccumulator()
  let start = epochTime()
  let frames = settleFrames + windowFrames
  for frame in 0 ..< frames:
    var speciesX = newSeq[float](particles.len)
    var speciesY = newSeq[float](particles.len)
    var fluidX = newSeq[float](particles.len)
    var fluidY = newSeq[float](particles.len)
    for _ in 0 ..< substeps:
      let sweep = forceSweep(cfg, particles, matrix, substepDt)
      for index in 0 ..< particles.len:
        speciesX[index] += sweep.speciesX[index]
        speciesY[index] += sweep.speciesY[index]
        fluidX[index] += sweep.fluidX[index]
        fluidY[index] += sweep.fluidY[index]
        integrateParticle(cfg, particles[index],
          sweep.speciesX[index] + sweep.fluidX[index],
          sweep.speciesY[index] + sweep.fluidY[index])
    if frame >= settleFrames:
      speciesAccumulator.addFrame(magnitudes(speciesX, speciesY), cfg)
      fluidAccumulator.addFrame(magnitudes(fluidX, fluidY), cfg)
  result.species = speciesAccumulator.finish()
  result.fluid = fluidAccumulator.finish()
  result.secondsPerFrame = (epochTime() - start) / frames.float

# ==============================================================================
# THE FIELD SCENE
# ==============================================================================
# The reaction-diffusion field runs on a periodic patch of the shipped grid at
# the shipped pixels per cell, carrying the sub-population the reference number
# density places in it. The full FIELD_W x FIELD_H grid is 2.36 million cells
# and its seven substeps per frame cost about 0.73 s per frame in this build,
# which no measurement horizon here can afford.
#
# What makes the patch answer for the whole grid is that the pattern is local:
# its diameter is about nine cells against a patch of 128, and the grid-mean
# gradient converges to the same limit from seeds an order of magnitude apart in
# coverage (0.0354 from both, measured).

const
  FIELD_PATCH_CELLS = 128
  FIELD_PIXELS_PER_CELL = REFERENCE_WORLD_WIDTH / FIELD_W.float
    ## 1.875 px. The shipped world width over the shipped field width, which is
    ## what decides how far one unit of fieldForceScale carries a particle.
  FIELD_PATCH_PX = FIELD_PATCH_CELLS.float * FIELD_PIXELS_PER_CELL
  FIELD_PATCH_PARTICLES =
    int(round(REFERENCE_NUMBER_DENSITY * FIELD_PATCH_PX * FIELD_PATCH_PX))
  FIELD_SEED_BLOB_RADIUS = 6.0
  FIELD_SEED_BLOB_COUNT = 24
    ## The seed test_field_core's own field harness ignites from, scaled to this
    ## patch's area. NOT RD_SEED_BLOB_RADIUS: a blob at that radius does not
    ## ignite on the shipped grid either, which the report records separately.
    ## The settled pattern does not depend on which of these seeds reaches it.

type FieldGrid = seq[float]

var fieldPrev: seq[int]
var fieldNext: seq[int]

proc initFieldWrap() =
  fieldPrev = newSeq[int](FIELD_PATCH_CELLS)
  fieldNext = newSeq[int](FIELD_PATCH_CELLS)
  for index in 0 ..< FIELD_PATCH_CELLS:
    fieldPrev[index] = fieldWrap(index - 1, FIELD_PATCH_CELLS)
    fieldNext[index] = fieldWrap(index + 1, FIELD_PATCH_CELLS)

func at(field: FieldGrid; x, y: int): float = field[y * FIELD_PATCH_CELLS + x]

proc fieldStencil(field: FieldGrid; x, y: int): float =
  let north = fieldPrev[y]
  let south = fieldNext[y]
  let east = fieldNext[x]
  let west = fieldPrev[x]
  laplacian9(field.at(x, y), field.at(x, north), field.at(x, south),
    field.at(east, y), field.at(west, y), field.at(east, north),
    field.at(west, north), field.at(east, south), field.at(west, south))

proc fieldSubstep(sourceA, sourceB: FieldGrid; targetA, targetB: var FieldGrid;
    feed, kill: float) =
  for y in 0 ..< FIELD_PATCH_CELLS:
    for x in 0 ..< FIELD_PATCH_CELLS:
      let (a, b) = grayScottStep(sourceA.at(x, y), sourceB.at(x, y),
        fieldStencil(sourceA, x, y), fieldStencil(sourceB, x, y),
        RD_DIFFUSION_A, RD_DIFFUSION_B, feed, kill, RD_DELTA_T)
      targetA[y * FIELD_PATCH_CELLS + x] = a
      targetB[y * FIELD_PATCH_CELLS + x] = b

proc fieldAdvance(fieldA, fieldB, scratchA, scratchB: var FieldGrid;
    rdSteps: int) =
  for index in 0 ..< rdSteps:
    if index mod 2 == 0: fieldSubstep(fieldA, fieldB, scratchA, scratchB,
      shipped.rdFeed, shipped.rdKill)
    else: fieldSubstep(scratchA, scratchB, fieldA, fieldB,
      shipped.rdFeed, shipped.rdKill)
  fieldA = scratchA
  fieldB = scratchB

func fieldCellOf(position: float): int =
  ## World pixel to field cell, the mapping field-deposit.wgsl and
  ## field-force.wgsl both perform.
  clamp(int(position / FIELD_PATCH_PX * FIELD_PATCH_CELLS.float), 0,
    FIELD_PATCH_CELLS - 1)

proc depositInto(fieldB: var FieldGrid; particles: seq[SceneParticle];
    deposit: float) =
  ## field-deposit.wgsl's normalized splat, folded once per rendered frame by
  ## field-resolve.wgsl. The caller passes the deposit webgpu_compute writes,
  ## which carries the step count's renormalization.
  if deposit == 0.0: return
  let normalization = depositSplatNormalization(RD_DEPOSIT_SPLAT_RADIUS)
  let extent = int(RD_DEPOSIT_SPLAT_RADIUS)
  for particle in particles:
    let cellX = fieldCellOf(particle.x)
    let cellY = fieldCellOf(particle.y)
    for dy in -extent .. extent:
      for dx in -extent .. extent:
        let weight = depositSplatWeight(
          sqrt((dx * dx + dy * dy).float), RD_DEPOSIT_SPLAT_RADIUS)
        if weight == 0.0: continue
        let y = fieldWrap(cellY + dy, FIELD_PATCH_CELLS)
        let x = fieldWrap(cellX + dx, FIELD_PATCH_CELLS)
        fieldB[y * FIELD_PATCH_CELLS + x] = fieldB[y * FIELD_PATCH_CELLS + x] +
          RD_DEPOSIT_FRAME_SCALE * weight / normalization *
          speciesDeposit(deposit, SECRETION_MAX)

proc fieldForceOn(fieldB: FieldGrid; particle: SceneParticle;
    fieldForceScale, tropism: float): tuple[x, y: float] =
  ## field-force.wgsl: a central-difference gradient of the inhibitor channel,
  ## scaled by fieldForceScale and signed by the species tropism. No dt.
  let cellX = fieldCellOf(particle.x)
  let cellY = fieldCellOf(particle.y)
  let gradientX = (fieldB.at(fieldNext[cellX], cellY) -
    fieldB.at(fieldPrev[cellX], cellY)) * 0.5
  let gradientY = (fieldB.at(cellX, fieldNext[cellY]) -
    fieldB.at(cellX, fieldPrev[cellY])) * 0.5
  (x: speciesTropismForce(gradientX, fieldForceScale, tropism),
   y: speciesTropismForce(gradientY, fieldForceScale, tropism))

proc fieldPatchConfig(base: SceneConfig): SceneConfig =
  result = base
  result.particleCount = FIELD_PATCH_PARTICLES
  result.worldWidth = FIELD_PATCH_PX
  result.worldHeight = FIELD_PATCH_PX

proc seededField(): tuple[a, b: FieldGrid] =
  result.a = newSeq[float](FIELD_PATCH_CELLS * FIELD_PATCH_CELLS)
  result.b = newSeq[float](FIELD_PATCH_CELLS * FIELD_PATCH_CELLS)
  for y in 0 ..< FIELD_PATCH_CELLS:
    for x in 0 ..< FIELD_PATCH_CELLS:
      let cell = rdSeedCell(x, y, REFERENCE_SEED, FIELD_PATCH_CELLS,
        FIELD_PATCH_CELLS, FIELD_SEED_BLOB_COUNT, FIELD_SEED_BLOB_RADIUS)
      result.a[y * FIELD_PATCH_CELLS + x] = cell.activator
      result.b[y * FIELD_PATCH_CELLS + x] = cell.inhibitor

proc meanGradient(fieldB: FieldGrid): float =
  for y in 0 ..< FIELD_PATCH_CELLS:
    for x in 0 ..< FIELD_PATCH_CELLS:
      let gradientX = (fieldB.at(fieldNext[x], y) -
        fieldB.at(fieldPrev[x], y)) * 0.5
      let gradientY = (fieldB.at(x, fieldNext[y]) -
        fieldB.at(x, fieldPrev[y])) * 0.5
      result += sqrt(gradientX * gradientX + gradientY * gradientY)
  result / float(FIELD_PATCH_CELLS * FIELD_PATCH_CELLS)

proc settledField(): tuple[a, b: FieldGrid] =
  ## The field alone, from its seed, with no particle touching it.
  initFieldWrap()
  var (fieldA, fieldB) = seededField()
  var scratchA = newSeq[float](fieldA.len)
  var scratchB = newSeq[float](fieldB.len)
  for _ in 0 ..< FIELD_SETTLE_FRAMES:
    fieldAdvance(fieldA, fieldB, scratchA, scratchB, RD_STEPS_PER_FRAME)
  (a: fieldA, b: fieldB)

let settledFieldPair = settledField()

proc runFieldScene(base: SceneConfig; settleFrames, windowFrames: int):
    tuple[field, species: Budget, secondsPerFrame: float] =
  ## The patch carrying its particles: deposit, reaction-diffusion, field force
  ## and species force, in the order sim_registry.buildFrame encodes them.
  ##
  ## The chemistry and the deposit fold carry fncOncePerFrame, so they run once
  ## however many substeps the frame encodes; the field force and the species
  ## force carry fncEverySubstep and run inside the loop. Time Scale sets the
  ## step count through rdStepsForTimeScale, and the deposit is renormalized by
  ## depositFrameScale so the rate per field step is what webgpu_compute writes.
  initFieldWrap()
  let cfg = fieldPatchConfig(base)
  let matrix = referenceMatrix(referenceSpeciesCount)
  var particles = sceneSeed(cfg, referenceSpeciesCount)
  var fieldA = settledFieldPair.a
  var fieldB = settledFieldPair.b
  var scratchA = newSeq[float](fieldA.len)
  var scratchB = newSeq[float](fieldB.len)
  let substepDt = substepDtOf(cfg)
  let substeps = effectiveSubsteps(cfg)
  let rdSteps = rdStepsForTimeScale(cfg.timeScale, RD_REFERENCE_TIME_SCALE)
  let tropism = RD_DEFAULT_TROPISM
  var fieldAccumulator = BudgetAccumulator()
  var speciesAccumulator = BudgetAccumulator()
  let start = epochTime()
  let frames = settleFrames + windowFrames
  for frame in 0 ..< frames:
    var fieldX = newSeq[float](particles.len)
    var fieldY = newSeq[float](particles.len)
    var speciesX = newSeq[float](particles.len)
    var speciesY = newSeq[float](particles.len)
    depositInto(fieldB, particles,
      cfg.deposit * depositFrameScale(rdSteps) / RD_DEPOSIT_FRAME_SCALE)
    fieldAdvance(fieldA, fieldB, scratchA, scratchB, rdSteps)
    for _ in 0 ..< substeps:
      let sweep = forceSweep(cfg, particles, matrix, substepDt)
      for index in 0 ..< particles.len:
        let impulse = fieldForceOn(fieldB, particles[index],
          frameScaledFieldForce(cfg.fieldForceScale, frameFactor(substepDt)),
          tropism)
        fieldX[index] += impulse.x
        fieldY[index] += impulse.y
        speciesX[index] += sweep.speciesX[index]
        speciesY[index] += sweep.speciesY[index]
        integrateParticle(cfg, particles[index],
          impulse.x + sweep.speciesX[index], impulse.y + sweep.speciesY[index])
    if frame >= settleFrames:
      fieldAccumulator.addFrame(magnitudes(fieldX, fieldY), cfg)
      speciesAccumulator.addFrame(magnitudes(speciesX, speciesY), cfg)
  result.field = fieldAccumulator.finish()
  result.species = speciesAccumulator.finish()
  result.secondsPerFrame = (epochTime() - start) / frames.float

# ==============================================================================
# THE ONE ENTRY POINT
# ==============================================================================

proc layerBudget(cfg: SceneConfig; layer: Layer): Budget =
  ## px per frame this layer hands the integrator, before friction and before
  ## the soft cap, summed across the frame's substeps.
  case layer
  of lySpecies: runParticleScene(cfg, PARTICLE_SETTLE_FRAMES,
    PARTICLE_WINDOW_FRAMES).species
  of lyFluid: runParticleScene(cfg, PARTICLE_SETTLE_FRAMES,
    PARTICLE_WINDOW_FRAMES).fluid
  of lyField: runFieldScene(cfg, FIELD_POINT_SETTLE_FRAMES,
    FIELD_WINDOW_FRAMES).field

# ==============================================================================
# FIDELITY: THE SPECIES LIMB AGAINST ITS MIRROR
# ==============================================================================

proc bruteForceSpeciesDelta(cfg: SceneConfig; particles: seq[SceneParticle];
    matrix: seq[seq[float32]]; substepDt: float): seq[tuple[x, y: float]] =
  ## Every ordered pair, minimum image through physics_core.wrapDelta, with no
  ## spatial hash anywhere: the sum calculateAttenuatedForce defines for this
  ## arrangement. Valid only while the world spans more than twice the
  ## interaction radius, which the fidelity scene below holds.
  let halfWidth = float32(cfg.worldWidth * 0.5)
  let halfHeight = float32(cfg.worldHeight * 0.5)
  let minDistanceSq = getTunableFloat("MIN_DISTANCE_SQ")
  for index in 0 ..< particles.len:
    var forceX = 0.0
    var forceY = 0.0
    for other in 0 ..< particles.len:
      if other == index: continue
      let separationX = wrapDelta(
        float32(particles[other].x - particles[index].x),
        float32(cfg.worldWidth), halfWidth)
      let separationY = wrapDelta(
        float32(particles[other].y - particles[index].y),
        float32(cfg.worldHeight), halfHeight)
      let normalized = normalizeDistance(separationX, separationY,
        cfg.interactionRadius.float32, float32(minDistanceSq))
      if not normalized.valid: continue
      let magnitude = calculateAttenuatedForce(normalized.normalizedDist,
        matrix[particles[index].species][particles[other].species],
        cfg.forceStrength.float32, normalized.invD,
        particles[index].crowdDensity.float32, cfg.crowdingStrength.float32)
      forceX += float(separationX * magnitude)
      forceY += float(separationY * magnitude)
    result.add (x: forceX * substepDt, y: forceY * substepDt)

proc fidelityScene(): SceneConfig =
  ## Small enough for an all-pairs reference, wide enough that the minimum image
  ## is unique (400 px against a 50 px radius) and that the spatial hash holds
  ## more than three cells per axis.
  result = referenceScene()
  result.particleCount = 400
  result.worldWidth = 400.0
  result.worldHeight = 400.0
  result.curve = fcFixed
  result.crowdingStrength = 0.75

# ==============================================================================
# FIDELITY: THE FLUID LIMB AGAINST THE STABILITY VERDICTS
# ==============================================================================
# test_sph_core measures the largest stiffness at which a seeded compression
# still comes to rest, in a box HARNESS_BOX_RADII smoothing radii across holding
# the count that puts the seeded density at twice rest. The same box run through
# this file's fluid limb has to return the same verdicts.

const
  FLUID_BOX_RADII = 4.0
  FLUID_SEED_DENSITY_RATIO = 2.0
  FLUID_VERDICT_FRAMES = 120
  FLUID_AT_REST_SPEED = 0.5
    ## test_sph_core's threshold: residual RMS speed in px per frame at or below
    ## which the fluid counts as having come to rest.

func fluidBoxParticleCount(restDensity: float): int =
  int(4.0 * (FLUID_SEED_DENSITY_RATIO * restDensity - 1.0) / PI *
    FLUID_BOX_RADII * FLUID_BOX_RADII)

proc fluidBoxConfig(stiffness: float; substeps: int): SceneConfig =
  result = referenceScene()
  result.forceStrength = 0.0
  result.fluidStrength = FLUID_STRENGTH_MAX
  result.substeps = substeps
  result.stiffness = stiffness
  result.worldWidth = FLUID_BOX_RADII * result.interactionRadius *
    result.radiusFraction
  result.worldHeight = result.worldWidth
  result.particleCount = fluidBoxParticleCount(result.restDensity)

proc fluidComesToRest(stiffness: float; substeps = 1): bool =
  ## The residual RMS speed over the run's last quarter, against the same
  ## threshold test_sph_core reads its boundary at.
  let cfg = fluidBoxConfig(stiffness, substeps)
  let matrix = referenceMatrix(referenceSpeciesCount)
  var particles = sceneSeed(cfg, referenceSpeciesCount)
  let substepDt = substepDtOf(cfg)
  let substeps = effectiveSubsteps(cfg)
  var speeds: seq[float] = @[]
  for _ in 0 ..< FLUID_VERDICT_FRAMES:
    for _ in 0 ..< substeps:
      let sweep = forceSweep(cfg, particles, matrix, substepDt)
      var sumOfSquares = 0.0
      for index in 0 ..< particles.len:
        integrateParticle(cfg, particles[index], sweep.fluidX[index],
          sweep.fluidY[index])
        sumOfSquares += particles[index].vx * particles[index].vx +
          particles[index].vy * particles[index].vy
        if particles[index].vx != particles[index].vx or
            abs(particles[index].vx) > 1.0e30:
          return false
      speeds.add sqrt(sumOfSquares / particles.len.float)
  let tailStart = speeds.len - speeds.len div 4
  var total = 0.0
  for index in tailStart ..< speeds.len: total += speeds[index]
  total / float(speeds.len - tailStart) <= FLUID_AT_REST_SPEED

# ==============================================================================
# FIDELITY: THE FIELD LIMB AGAINST THE CHEMOTAXIS MEASUREMENT
# ==============================================================================
# test_field_core brackets the chemotactic collapse on the deposit axis. At
# fifteen times RD_DEPOSIT_MAX with the field force at its maximum, a population
# at TROPISM_MAX diverges the field, while the same deposit laid down by a
# frozen population stays finite. That pair is the measurement: neither run
# alone carries it, because the divergence has to belong to the up-gradient
# motion rather than to the deposit amplitude.

const
  CHEMOTAXIS_GRID = 64
  CHEMOTAXIS_PARTICLES = 256
  CHEMOTAXIS_FRAMES = 120
  CHEMOTAXIS_COLLAPSE_DEPOSIT_MULTIPLE = 15.0
    ## Smallest deposit, in multiples of RD_DEPOSIT_MAX, at which test_field_core
    ## measures some tropism diverging the field.
  CHEMOTAXIS_WORLD_PX =
    CHEMOTAXIS_GRID.float * 1920.0 / FIELD_W.float
    ## test_field_core's chemotaxis geometry, taken from its own reference
    ## window width rather than from this file's patch.

proc chemotaxisStaysFinite(tropism, deposit, fieldForceScale: float): bool =
  ## test_field_core's chemotaxis run, driven through this file's field force
  ## and integrator. Reports whether the inhibitor channel stays finite.
  var prev = newSeq[int](CHEMOTAXIS_GRID)
  var next = newSeq[int](CHEMOTAXIS_GRID)
  for index in 0 ..< CHEMOTAXIS_GRID:
    prev[index] = fieldWrap(index - 1, CHEMOTAXIS_GRID)
    next[index] = fieldWrap(index + 1, CHEMOTAXIS_GRID)

  var fieldA = newSeq[float](CHEMOTAXIS_GRID * CHEMOTAXIS_GRID)
  var fieldB = newSeq[float](CHEMOTAXIS_GRID * CHEMOTAXIS_GRID)
  for index in 0 ..< fieldA.len: fieldA[index] = 1.0
  var scratchA = newSeq[float](fieldA.len)
  var scratchB = newSeq[float](fieldB.len)

  proc cellOf(position: float): int =
    clamp(int(position / CHEMOTAXIS_WORLD_PX * CHEMOTAXIS_GRID.float), 0,
      CHEMOTAXIS_GRID - 1)

  proc stencil(field: seq[float]; x, y: int): float =
    laplacian9(field[y * CHEMOTAXIS_GRID + x],
      field[prev[y] * CHEMOTAXIS_GRID + x], field[next[y] * CHEMOTAXIS_GRID + x],
      field[y * CHEMOTAXIS_GRID + next[x]], field[y * CHEMOTAXIS_GRID + prev[x]],
      field[prev[y] * CHEMOTAXIS_GRID + next[x]],
      field[prev[y] * CHEMOTAXIS_GRID + prev[x]],
      field[next[y] * CHEMOTAXIS_GRID + next[x]],
      field[next[y] * CHEMOTAXIS_GRID + prev[x]])

  var state = REFERENCE_SEED
  var particles: seq[SceneParticle] = @[]
  for _ in 0 ..< CHEMOTAXIS_PARTICLES:
    state = state * 1664525'u32 + 1013904223'u32
    let sampleX = (state shr 8).float / 16777216.0
    state = state * 1664525'u32 + 1013904223'u32
    let sampleY = (state shr 8).float / 16777216.0
    particles.add SceneParticle(x: sampleX * CHEMOTAXIS_WORLD_PX,
      y: sampleY * CHEMOTAXIS_WORLD_PX)

  var cfg = referenceScene()
  cfg.worldWidth = CHEMOTAXIS_WORLD_PX
  cfg.worldHeight = CHEMOTAXIS_WORLD_PX

  let normalization = depositSplatNormalization(RD_DEPOSIT_SPLAT_RADIUS)
  let extent = int(RD_DEPOSIT_SPLAT_RADIUS)
  for _ in 0 ..< CHEMOTAXIS_FRAMES:
    for particle in particles:
      let cellX = cellOf(particle.x)
      let cellY = cellOf(particle.y)
      for dy in -extent .. extent:
        for dx in -extent .. extent:
          let weight = depositSplatWeight(
            sqrt((dx * dx + dy * dy).float), RD_DEPOSIT_SPLAT_RADIUS)
          if weight == 0.0: continue
          let y = fieldWrap(cellY + dy, CHEMOTAXIS_GRID)
          let x = fieldWrap(cellX + dx, CHEMOTAXIS_GRID)
          fieldB[y * CHEMOTAXIS_GRID + x] = fieldB[y * CHEMOTAXIS_GRID + x] +
            RD_DEPOSIT_FRAME_SCALE * weight / normalization *
            speciesDeposit(deposit, SECRETION_MAX)
    for index in 0 ..< RD_STEPS_PER_FRAME:
      let readA = (if index mod 2 == 0: fieldA else: scratchA)
      let readB = (if index mod 2 == 0: fieldB else: scratchB)
      var writeA = newSeq[float](fieldA.len)
      var writeB = newSeq[float](fieldB.len)
      for y in 0 ..< CHEMOTAXIS_GRID:
        for x in 0 ..< CHEMOTAXIS_GRID:
          let (a, b) = grayScottStep(readA[y * CHEMOTAXIS_GRID + x],
            readB[y * CHEMOTAXIS_GRID + x], stencil(readA, x, y),
            stencil(readB, x, y), RD_DIFFUSION_A, RD_DIFFUSION_B,
            shipped.rdFeed, shipped.rdKill, RD_DELTA_T)
          writeA[y * CHEMOTAXIS_GRID + x] = a
          writeB[y * CHEMOTAXIS_GRID + x] = b
      if index mod 2 == 0:
        scratchA = writeA
        scratchB = writeB
      else:
        fieldA = writeA
        fieldB = writeB
    fieldA = scratchA
    fieldB = scratchB

    for particle in particles.mitems:
      let cellX = cellOf(particle.x)
      let cellY = cellOf(particle.y)
      let gradientX = (fieldB[cellY * CHEMOTAXIS_GRID + next[cellX]] -
        fieldB[cellY * CHEMOTAXIS_GRID + prev[cellX]]) * 0.5
      let gradientY = (fieldB[next[cellY] * CHEMOTAXIS_GRID + cellX] -
        fieldB[prev[cellY] * CHEMOTAXIS_GRID + cellX]) * 0.5
      integrateParticle(cfg, particle,
        speciesTropismForce(gradientX, fieldForceScale, tropism),
        speciesTropismForce(gradientY, fieldForceScale, tropism))

    for value in fieldB:
      if value != value or value > 1.0e30: return false
  true

# ==============================================================================
# THE SWEEPS
# ==============================================================================

type SweepRow = object
  point: string
  species, fluid, field: Budget

func sweepPoints(low, high: float; count: int): seq[float] =
  for index in 0 ..< count:
    result.add low + (high - low) * index.float / float(count - 1)

proc particlePoint(cfg: SceneConfig): tuple[species, fluid: Budget] =
  let run = runParticleScene(cfg, PARTICLE_SETTLE_FRAMES,
    PARTICLE_WINDOW_FRAMES)
  (species: run.species, fluid: run.fluid)

proc fieldPoint(cfg: SceneConfig): Budget =
  runFieldScene(cfg, FIELD_POINT_SETTLE_FRAMES, FIELD_WINDOW_FRAMES).field

proc fullScaleConfig(): SceneConfig =
  ## Every coupling at the top of its own range. The shared axes below are swept
  ## here, because the octave band the report closes on is a full-scale
  ## comparison and a shared axis has to move all three layers at once.
  result = referenceScene()
  result.forceStrength = FORCE_STRENGTH_MAX
  result.fluidStrength = FLUID_STRENGTH_MAX
  result.fieldForceScale = RD_FIELD_FORCE_MAX

proc sharedAxisRow(cfg: SceneConfig; point: string): SweepRow =
  let particle = particlePoint(cfg)
  SweepRow(point: point, species: particle.species, fluid: particle.fluid,
    field: fieldPoint(cfg))

# ==============================================================================
# THE MEASUREMENT
# ==============================================================================

proc fullScaleSpeciesConfig(): SceneConfig =
  result = referenceScene()
  result.forceStrength = FORCE_STRENGTH_MAX

proc fullScaleFluidConfig(): SceneConfig =
  result = referenceScene()
  result.fluidStrength = FLUID_STRENGTH_MAX

proc fullScaleFieldConfig(): SceneConfig =
  result = referenceScene()
  result.fieldForceScale = RD_FIELD_FORCE_MAX

proc fixedCurveConfig(): SceneConfig =
  result = referenceScene()
  result.curve = fcFixed

let
  referenceRun = runParticleScene(referenceScene(),
    PARTICLE_SETTLE_FRAMES, PARTICLE_WINDOW_FRAMES)
  referenceFieldRun = runFieldScene(referenceScene(),
    FIELD_POINT_SETTLE_FRAMES, FIELD_WINDOW_FRAMES)
  unsettledFieldRun = runFieldScene(referenceScene(), 0, FIELD_WINDOW_FRAMES)
    ## The same scene measured from the frame the population is scattered,
    ## before down-gradient tropism has carried anything toward a flat.
  unsettledSpecies = runParticleScene(referenceScene(), 0,
    PARTICLE_WINDOW_FRAMES).species
  unsettledFluid = runParticleScene(fullScaleFluidConfig(), 0,
    PARTICLE_WINDOW_FRAMES).fluid
  referenceSpeciesFixedCurve = runParticleScene(fixedCurveConfig(),
    PARTICLE_SETTLE_FRAMES, PARTICLE_WINDOW_FRAMES).species
  fullScaleSpecies = runParticleScene(fullScaleSpeciesConfig(),
    PARTICLE_SETTLE_FRAMES, PARTICLE_WINDOW_FRAMES).species
  fullScaleFluid = runParticleScene(fullScaleFluidConfig(),
    PARTICLE_SETTLE_FRAMES, PARTICLE_WINDOW_FRAMES).fluid
  fullScaleField = runFieldScene(fullScaleFieldConfig(),
    FIELD_POINT_SETTLE_FRAMES, FIELD_WINDOW_FRAMES).field

func octaveRatio(a, b, c: float): float =
  max(max(a, b), c) / min(min(a, b), c)

let octaveBand = octaveRatio(fullScaleSpecies.mean, fullScaleFluid.mean,
  fullScaleField.mean)

# The five swept axes.

let speciesStrengthSweep = block:
  var rows: seq[SweepRow]
  for value in sweepPoints(FORCE_STRENGTH_MIN, FORCE_STRENGTH_MAX, 11):
    var cfg = referenceScene()
    cfg.forceStrength = value
    let particle = particlePoint(cfg)
    rows.add SweepRow(point: value.formatFloat(ffDecimal, 2),
      species: particle.species, fluid: particle.fluid)
  rows

let fluidStrengthSweep = block:
  var rows: seq[SweepRow]
  for value in sweepPoints(FLUID_STRENGTH_MIN, FLUID_STRENGTH_MAX, 11):
    var cfg = referenceScene()
    cfg.fluidStrength = value
    let particle = particlePoint(cfg)
    rows.add SweepRow(point: value.formatFloat(ffDecimal, 2),
      species: particle.species, fluid: particle.fluid)
  rows

let fieldForceSweep = block:
  var rows: seq[SweepRow]
  for value in sweepPoints(RD_FIELD_FORCE_MIN, RD_FIELD_FORCE_MAX, 11):
    var cfg = referenceScene()
    cfg.fieldForceScale = value
    rows.add SweepRow(point: value.formatFloat(ffDecimal, 2),
      field: fieldPoint(cfg))
  rows

let timeScaleSweep = block:
  var rows: seq[SweepRow]
  for value in [TIME_SCALE_MIN, shipped.timeScale, TIME_SCALE_MAX]:
    var cfg = fullScaleConfig()
    cfg.timeScale = value
    rows.add sharedAxisRow(cfg, value.formatFloat(ffDecimal, 2))
  rows

let substepSweep = block:
  var rows: seq[SweepRow]
  for value in [SPH_SUBSTEPS_MIN, SPH_SUBSTEPS_MAX]:
    var cfg = fullScaleConfig()
    cfg.substeps = value
    rows.add sharedAxisRow(cfg, $value)
  rows

let densitySweep = block:
  var rows: seq[SweepRow]
  for multiple in [0.5, 1.0, 2.0]:
    var cfg = fullScaleConfig()
    cfg.particleCount = int(round(REFERENCE_PARTICLE_COUNT.float * multiple))
    rows.add sharedAxisRow(cfg, multiple.formatFloat(ffDecimal, 1) & "x")
  rows

let radiusSweep = block:
  var rows: seq[SweepRow]
  for value in [INTERACTION_RADIUS_MIN, shipped.interactionRadius,
      INTERACTION_RADIUS_MAX]:
    var cfg = fullScaleConfig()
    cfg.interactionRadius = value.float
    rows.add sharedAxisRow(cfg, $value)
  rows

# ==============================================================================
# THE REPORT
# ==============================================================================

const
  PREDICTED_SPECIES_BUDGET = 3.0e-4
  PREDICTED_FIELD_BUDGET = 0.27
    ## Pre-registered before this harness ran, and kept here so the comparison
    ## below cannot be written after the fact.

proc repositoryRoot(): string = currentSourcePath().parentDir.parentDir

proc repositoryCommit(): string =
  let headPath = repositoryRoot() / ".git" / "HEAD"
  if not fileExists(headPath): return "unknown"
  let head = readFile(headPath).strip()
  if not head.startsWith("ref: "): return head[0 ..< min(12, head.len)]
  let refPath = repositoryRoot() / ".git" / head[5 .. ^1]
  if not fileExists(refPath): return "unknown"
  readFile(refPath).strip()[0 ..< 12]

proc scientific(value: float): string = value.formatFloat(ffScientific, 3)

proc budgetLine(label: string; budget: Budget): string =
  "| " & label & " | " & scientific(budget.mean) & " | " &
    scientific(budget.p95) & " | " & budget.capSaturated.formatFloat(ffDecimal, 4) &
    " | " & budget.drift.formatFloat(ffDecimal, 4) & " |\n"

proc particleSweepTable(rows: seq[SweepRow]; axis: string): string =
  result = "| " & axis & " | species mean | species p95 | fluid mean | " &
    "fluid p95 |\n|---|---|---|---|---|\n"
  for row in rows:
    result.add "| " & row.point & " | " & scientific(row.species.mean) &
      " | " & scientific(row.species.p95) & " | " & scientific(row.fluid.mean) &
      " | " & scientific(row.fluid.p95) & " |\n"
  result.add "\n"

proc fieldSweepTable(rows: seq[SweepRow]; axis: string): string =
  result = "| " & axis & " | field mean | field p95 | cap saturated |\n" &
    "|---|---|---|---|\n"
  for row in rows:
    result.add "| " & row.point & " | " & scientific(row.field.mean) & " | " &
      scientific(row.field.p95) & " | " &
      row.field.capSaturated.formatFloat(ffDecimal, 4) & " |\n"
  result.add "\n"

proc sharedSweepTable(rows: seq[SweepRow]; axis: string): string =
  result = "| " & axis & " | species mean | fluid mean | field mean |\n" &
    "|---|---|---|---|\n"
  for row in rows:
    result.add "| " & row.point & " | " & scientific(row.species.mean) &
      " | " & scientific(row.fluid.mean) & " | " & scientific(row.field.mean) &
      " |\n"
  result.add "\n"

proc forceBudgetReportMarkdown(): string =
  let speciesRatio = referenceRun.species.mean / PREDICTED_SPECIES_BUDGET
  let fieldRatio = referenceFieldRun.field.mean / PREDICTED_FIELD_BUDGET
  result = """# Force budget

How much velocity each of the three force layers hands the integrator, in
pixels per frame, read where the layer writes into `velocityDeltaFixed`: before
friction, before the logarithmic soft cap, and summed across the substeps a
rendered frame encodes. `tests/test_force_budget.nim` writes this file.

## Conditions

| what | value |
|---|---|
| commit | """ & repositoryCommit() & """ |
| seed | 0x9E3779B9, a fixed LCG |
| world | """ & $int(REFERENCE_WORLD_WIDTH) & " x " &
    $int(REFERENCE_WORLD_HEIGHT) & """ px, toroidal |
| particles | """ & $REFERENCE_PARTICLE_COUNT & """ |
| number density | """ & scientific(REFERENCE_NUMBER_DENSITY) &
    """ particles per square px |
| species | """ & $referenceSpeciesCount & """, on a cyclic-chase matrix at the band edges |
| interaction radius | """ & $shipped.interactionRadius & """ px |
| friction | """ & shipped.friction.formatFloat(ffDecimal, 2) & """ |
| maxVelocity | """ & shipped.maxVelocity.formatFloat(ffDecimal, 1) & """ px per frame |
| timeScale | """ & shipped.timeScale.formatFloat(ffDecimal, 2) & """ |
| force curve | polynomial, repulsionEnd """ &
    shipped.repulsionEnd.formatFloat(ffDecimal, 2) & """, attractionPeak """ &
    shipped.attractionPeak.formatFloat(ffDecimal, 2) & """ |
| particle horizon | """ & $PARTICLE_SETTLE_FRAMES & """ settling frames, """ &
    $PARTICLE_WINDOW_FRAMES & """ measured |
| field horizon | """ & $FIELD_SETTLE_FRAMES &
    """ frames of field alone, then """ & $FIELD_POINT_SETTLE_FRAMES &
    """ settling and """ & $FIELD_WINDOW_FRAMES & """ measured |
| settling tolerance | """ & SETTLING_TOLERANCE.formatFloat(ffDecimal, 2) &
    """ relative drift across the window |
| species agreement tolerance | 1e-4 relative, against an all-pairs reference |
| runtime | """ & referenceRun.secondsPerFrame.formatFloat(ffDecimal, 3) &
    """ s per frame at """ & $REFERENCE_PARTICLE_COUNT & """ particles |

The field runs on a periodic patch of the shipped grid, """ &
    $FIELD_PATCH_CELLS & " by " & $FIELD_PATCH_CELLS &
    """ cells at the shipped """ &
    FIELD_PIXELS_PER_CELL.formatFloat(ffDecimal, 3) & """ px per cell, holding
the """ & $FIELD_PATCH_PARTICLES & """ particles the reference number density
places in it. The full grid is 2.36 million cells and costs about 0.73 s per
frame in this build, which no horizon here can afford.

## The three layers

Each layer is measured with the other couplings at their shipped defaults, and
the fluid's shipped default is zero, so the fluid's own default budget is zero
by construction.

| layer | shipped default | full scale | full-scale p95 | cap saturated |
|---|---|---|---|---|
| species | """ & scientific(referenceRun.species.mean) & " | " &
    scientific(fullScaleSpecies.mean) & " | " &
    scientific(fullScaleSpecies.p95) & " | " &
    fullScaleSpecies.capSaturated.formatFloat(ffDecimal, 4) & """ |
| fluid | """ & scientific(referenceRun.fluid.mean) & " | " &
    scientific(fullScaleFluid.mean) & " | " & scientific(fullScaleFluid.p95) &
    " | " & fullScaleFluid.capSaturated.formatFloat(ffDecimal, 4) & """ |
| field | """ & scientific(referenceFieldRun.field.mean) & " | " &
    scientific(fullScaleField.mean) & " | " & scientific(fullScaleField.p95) &
    " | " & fullScaleField.capSaturated.formatFloat(ffDecimal, 4) & """ |

Full scale means forceStrength """ & FORCE_STRENGTH_MAX.formatFloat(ffDecimal, 1) &
    """, fluidStrength """ & FLUID_STRENGTH_MAX.formatFloat(ffDecimal, 1) &
    """ and rdFieldForce """ & RD_FIELD_FORCE_MAX.formatFloat(ffDecimal, 1) & """.

Under the fixed 0.3/1.3/0.7 curve, which no shipped forceModel selects, the
species budget at the shipped defaults reads """ &
    scientific(referenceSpeciesFixedCurve.mean) & """. Under the polynomial
curve forceModel 0 ships, it reads """ &
    scientific(referenceRun.species.mean) & """.

## The pre-registered prediction

The prediction went on the record before this harness ran: about 3e-4 px per
frame from the species force at the shipped defaults, and about 0.27 from the
field force.

| layer | predicted | measured | measured over predicted |
|---|---|---|---|
| species | 3.000e-04 | """ & scientific(referenceRun.species.mean) & " | " &
    speciesRatio.formatFloat(ffDecimal, 1) & """ |
| field | 2.700e-01 | """ & scientific(referenceFieldRun.field.mean) & " | " &
    fieldRatio.formatFloat(ffDecimal, 3) & """ |

Both predictions missed, in opposite directions, and the measurement stands.

The species force delivers more than predicted. The prediction treated the
arrangement as the seeded scatter. It does not stay that way: over the settling
frames attraction pulls neighbours together, local density rises, and the force
rises with it.

The field force delivers far less than predicted. The prediction multiplied the
field force scale by the inhibitor gradient averaged over every cell of the
grid, a gradient of """ &
    scientific(PREDICTED_FIELD_BUDGET / shipped.rdFieldForce) &
    """ per cell. Particles do not sample cells uniformly. The shipped tropism
is """ & RD_DEFAULT_TROPISM.formatFloat(ffDecimal, 1) & """, full
down-gradient, so each particle is driven toward the flats of the pattern and
comes to rest where the gradient is small.

Measured from the frame the population is scattered, before that sorting has
happened, the same scene reads """ &
    scientific(unsettledFieldRun.field.mean) & """ px per frame. After """ &
    $FIELD_POINT_SETTLE_FRAMES & """ settling frames it reads """ &
    scientific(referenceFieldRun.field.mean) &
    """. The distance between those two numbers is the whole of the
disagreement with the prediction.

## Settling

Every number above is measured after the settling frames, on a world that has
had time to arrange itself. That arrangement is most of the answer, and the
three layers move in opposite directions as it forms.

| layer | fresh scatter | settled | settled over fresh |
|---|---|---|---|
| species | """ & scientific(unsettledSpecies.mean) & " | " &
    scientific(referenceRun.species.mean) & " | " &
    (referenceRun.species.mean / unsettledSpecies.mean).formatFloat(
      ffDecimal, 2) & """ |
| fluid | """ & scientific(unsettledFluid.mean) & " | " &
    scientific(fullScaleFluid.mean) & " | " &
    (fullScaleFluid.mean / unsettledFluid.mean).formatFloat(ffDecimal, 2) & """ |
| field | """ & scientific(unsettledFieldRun.field.mean) & " | " &
    scientific(referenceFieldRun.field.mean) & " | " &
    (referenceFieldRun.field.mean / unsettledFieldRun.field.mean).formatFloat(
      ffDecimal, 2) & """ |

The species force rises as the world settles, because attraction gathers
neighbours and the force grows with local density. The fluid and the field both
fall, and for the same reason in two guises: each is a restoring force acting
against a disorder it is busy removing. Pressure drives the population toward
the locally uniform spacing where pressure cancels. Down-gradient tropism drives
each particle toward a flat of the pattern, where the gradient it reads is
small.

A budget quoted on a fresh scatter therefore describes a transient. The
species row is measured at the shipped defaults, the fluid row at full scale,
because the shipped fluid strength is zero.

## Species strength

Every other coupling at its shipped default.

""" & particleSweepTable(speciesStrengthSweep, "forceStrength") & """
## Fluid strength

Every other coupling at its shipped default. The species column moves along
this axis because the fluid rearranges the population the species force acts on,
and because a fluid above zero makes the frame take sphSubsteps substeps
instead of one.

""" & particleSweepTable(fluidStrengthSweep, "fluidStrength") & """
## Field force

Every other coupling at its shipped default.

""" & fieldSweepTable(fieldForceSweep, "rdFieldForce") & """
## timeScale

Shared axis, every coupling at full scale.

""" & sharedSweepTable(timeScaleSweep, "timeScale") & """
`params.dt` is a gain rather than a timestep: `integrate.wgsl` advances position
by the velocity itself with no dt. The species force multiplies by dt once and
so scales with this axis. The field force reaches the axis by two routes at
once. `frameScaledFieldForce` multiplies its gain by the frame's dt as a
multiple of `FRAME_DT_REFERENCE`, and `rdStepsForTimeScale` sets how many
reaction-diffusion steps a frame runs, so the pattern the force reads evolves at
a rate this axis sets too. The two compound, which is why the column climbs
faster than the axis above the reference.

## sphSubsteps

Shared axis, every coupling at full scale. The axis bites only where the fluid
acts, because `webgpu_compute` encodes one substep per frame otherwise.

""" & sharedSweepTable(substepSweep, "sphSubsteps") & """
The chemistry carries `fncOncePerFrame`, so the deposit fold and the
reaction-diffusion chain run once however many substeps the frame encodes, and
the field the force reads is the same field at either substep count. The species
force and the field force divide dt by the substep count and run that many
times, so what each sums over a frame is left where it was. That leaves one
route for this axis to reach either column: particles move between substeps and
therefore sample their neighbors and the field from different places.

## Number density

Shared axis, every coupling at full scale, as a multiple of the reference
""" & scientific(REFERENCE_NUMBER_DENSITY) & """ particles per square px. The
world is held and the count varies.

""" & sharedSweepTable(densitySweep, "density") & """
## Interaction radius

Shared axis, every coupling at full scale. No term of the field force reads the
interaction radius. Its column still moves along this axis, because a wider
radius changes where the species force carries the particles, and a particle
elsewhere reads a different part of the pattern.

""" & sharedSweepTable(radiusSweep, "interactionRadius") & """
## The octave band

The three layers at full scale span a factor of """ &
    octaveBand.formatFloat(ffDecimal, 1) & """, against a band of 2.

| layer | full-scale mean |
|---|---|
| species | """ & scientific(fullScaleSpecies.mean) & """ |
| fluid | """ & scientific(fullScaleFluid.mean) & """ |
| field | """ & scientific(fullScaleField.mean) & """ |

`tests/test_force_budget.nim` carries that comparison as a test, and it is red.
A slider at full travel means a different amount of velocity depending on which
layer it belongs to, by the factor above.

## The seed radius

Separate from the budget, and found while building the field limb.

`RD_SEED_BLOB_RADIUS` is 24 cells, and a field seeded with it does not ignite.
Measured on the shipped grid itself rather than on the patch: `FIELD_W` by
`FIELD_H` at 2048 by 1152, `RD_SEED_BLOB_COUNT` at 48, radius 24, feed 0.030,
kill 0.062, no particle deposit, 200 frames. The seed starts with 1.776% of
cells above `FIELD_ALIVE_THRESHOLD` and a peak inhibitor of 0.25000. By frame
25 the peak is 0.00066, and from frame 50 to the end of the run it is 0.00000
with no cell alive.

Domain fraction does not account for it. On a 128-cell patch, holding the blob
at the shipped 2.34% of the width (radius 1.5) fails to ignite at one, 24 and 85
blobs, the last of which matches the shipped 3.68% areal coverage. Holding the
radius at 24 and growing the domain to 512 cells, where the blob spans 9.38% of
the width and 3.45% of the area, also fails. A radius-6 blob at that same 9.38%
of the width does ignite, reaching 29.2% of cells alive. Changing the radius
flips the outcome across every domain fraction tried, and holding the domain
fraction at the shipped value changes nothing.

What this bounds is the seed on its own. The run carries no particle deposit,
while `RD_DEFAULT_DEPOSIT` ships at 0.02 and every particle folds chemical into
the field each frame, so the running app reaches the field by a second route
this measurement excludes. Whether the shipped world shows a pattern is
therefore a question about deposit, unanswered here; what is answered is that
the seed the reseed path lays down dies within 50 frames if nothing feeds it.

`RD_SEED_BLOB_RADIUS` stands unchanged.

## Deviations

The species and fluid layers are measured on the full reference world with the
field force silent, because the reaction-diffusion field cannot run at world
scale inside a test. The field layer is measured on the patch with the species
force at its shipped default. No measurement here carries all three couplings
at once.

The field patch is seeded with blobs of radius 6 rather than
`RD_SEED_BLOB_RADIUS`, because a blob at the shipped radius does not ignite.
The settled pattern does not depend on which seed reaches it: seeds an order of
magnitude apart in coverage converge to the same grid-mean gradient of 0.0354
and the same 29.2% of cells alive.
"""

suite "The Reference Scene Is The Shipped Geometry":
  test "the world constants equal the ones config.nim declares":
    # config.nim carries FFI pragmas this pure module cannot import, so the
    # agreement is held by reading that file, the way test_field_core holds its
    # own copy of the same two numbers.
    let source = readFile(repositoryRoot() / "src" / "config.nim")
    check ("WORLD_W* {.exportc.}: float = " &
      REFERENCE_WORLD_WIDTH.formatFloat(ffDecimal, 1)) in source
    check ("WORLD_H* {.exportc.}: float = " &
      REFERENCE_WORLD_HEIGHT.formatFloat(ffDecimal, 1)) in source

  test "the reference particle count equals the shipped default":
    check REFERENCE_PARTICLE_COUNT == shipped.particleCount

suite "The Report Is The Deliverable":
  test "the report regenerates byte for byte from the same seed":
    check forceBudgetReportMarkdown() == forceBudgetReportMarkdown()

  test "the report records every swept axis":
    let markdown = forceBudgetReportMarkdown()
    for heading in ["## Species strength", "## Fluid strength",
        "## Field force", "## timeScale", "## sphSubsteps",
        "## Number density", "## Interaction radius", "## The octave band",
        "## Settling", "## The seed radius", "## Deviations"]:
      checkpoint("missing " & heading)
      check heading in markdown
    let reportPath = repositoryRoot() / "docs" / "force-budget-report.md"
    writeFile(reportPath, markdown)
    check fileExists(reportPath)

suite "The Species Limb Reproduces Its Mirror":
  test "the species limb equals calculateAttenuatedForce over every pair":
    # CONTRACT: physics_core.calculateAttenuatedForce, summed over every
    # neighbour by minimum image, is what one substep of the species force is.
    # The limb reaches the same sum through the spatial hash and
    # getNeighborCell's wrap offsets, so agreement covers the sweep, the
    # wrapping and the force call together.
    let cfg = fidelityScene()
    let matrix = referenceMatrix(referenceSpeciesCount)
    var particles = sceneSeed(cfg, referenceSpeciesCount)
    for particle in particles.mitems:
      particle.crowdDensity = 3.0
    let substepDt = substepDtOf(cfg)
    let expected = bruteForceSpeciesDelta(cfg, particles, matrix, substepDt)
    let measured = forceSweep(cfg, particles, matrix, substepDt)
    var worst = 0.0
    var largest = 0.0
    for index in 0 ..< particles.len:
      worst = max(worst, abs(measured.speciesX[index] - expected[index].x))
      worst = max(worst, abs(measured.speciesY[index] - expected[index].y))
      largest = max(largest, abs(expected[index].x))
      largest = max(largest, abs(expected[index].y))
    # Relative, because the two paths sum the same float32 pair forces in two
    # different orders: the spatial hash walks cell by cell, the reference walks
    # by particle index. Restricting the sweep to the centre cell alone lands
    # this at 5.4e-3 absolute against a largest delta of the same order, five
    # decades above where correct agreement sits.
    checkpoint("worst disagreement " & worst.formatFloat(ffScientific, 3) &
      " against a largest delta of " & largest.formatFloat(ffScientific, 3))
    check worst < 1.0e-4 * largest

suite "The Fluid Limb Reproduces The Stability Verdicts":
  test "the shipped stiffness comes to rest and a stiffness far above it does not":
    # CONTRACT: sph_core.stableStiffnessCeiling puts the boundary at
    # 0.0025 * h * substeps / dt, which is 15 at the shipped radius, one substep
    # and the shipped timeScale. The shipped stiffness of 8 sits below it and
    # must settle; 400 sits far above it and must not.
    checkpoint("ceiling at these settings: " &
      stableStiffnessCeiling(shipped.interactionRadius.float *
        shipped.sphRadiusFraction, 1,
        shipped.timeScale * REFERENCE_FRAME_SECONDS,
        40.0).formatFloat(ffDecimal, 2))
    check fluidComesToRest(shipped.sphStiffness)
    check not fluidComesToRest(400.0)

suite "The Field Limb Reproduces The Chemotaxis Measurement":
  test "chemotaxis diverges the field where a frozen population at the same deposit does not":
    # CONTRACT: test_field_core's collapse bracket. At fifteen times
    # RD_DEPOSIT_MAX with the field force at its maximum, a population at
    # TROPISM_MAX runs away and a frozen one does not, so the divergence belongs
    # to the up-gradient motion rather than to the deposit amplitude.
    let collapseDeposit = RD_DEPOSIT_MAX * CHEMOTAXIS_COLLAPSE_DEPOSIT_MULTIPLE
    check not chemotaxisStaysFinite(TROPISM_MAX, collapseDeposit,
      RD_FIELD_FORCE_MAX)
    check chemotaxisStaysFinite(0.0, collapseDeposit, RD_FIELD_FORCE_MAX)

suite "A Silent Coupling Delivers Nothing":
  test "the species budget is exactly zero at force strength zero":
    var cfg = referenceScene()
    cfg.forceStrength = FORCE_STRENGTH_MIN
    check layerBudget(cfg, lySpecies).mean == 0.0

  test "the fluid budget is exactly zero at fluid strength zero":
    var cfg = referenceScene()
    cfg.fluidStrength = FLUID_STRENGTH_MIN
    check layerBudget(cfg, lyFluid).mean == 0.0

  test "the field budget is exactly zero at field force zero":
    var cfg = referenceScene()
    cfg.fieldForceScale = RD_FIELD_FORCE_MIN
    check layerBudget(cfg, lyField).mean == 0.0

suite "The Same Seed Gives The Same Numbers":
  test "two runs of the reference scene agree bit for bit":
    let first = runParticleScene(referenceScene(),
      PARTICLE_SETTLE_FRAMES, PARTICLE_WINDOW_FRAMES)
    let second = runParticleScene(referenceScene(),
      PARTICLE_SETTLE_FRAMES, PARTICLE_WINDOW_FRAMES)
    check first.species.mean == second.species.mean
    check first.species.p95 == second.species.p95
    check first.fluid.mean == second.fluid.mean

suite "Every Measured Run Has Settled":
  test "each layer's window drifts less than the settling tolerance":
    # The criterion: the mean budget over the window's first half and over its
    # second half differ by less than SETTLING_TOLERANCE of the larger.
    checkpoint("species drift " & referenceRun.species.drift.formatFloat(
      ffDecimal, 4) & ", field drift " &
      referenceFieldRun.field.drift.formatFloat(ffDecimal, 4))
    check referenceRun.species.drift < SETTLING_TOLERANCE
    check referenceFieldRun.field.drift < SETTLING_TOLERANCE

suite "The Three Layers Sit Inside One Octave":
  test "the full-scale budgets span at most a factor of two":
    # WRITTEN RED against today's constants. The three layers are ranged
    # independently, so their full-scale budgets stand orders of magnitude
    # apart, and this compares them on one scale. What turns it green is a
    # re-ranging of FORCE_STRENGTH_MAX, FLUID_STRENGTH_MAX and
    # RD_FIELD_FORCE_MAX against each other, so that a slider at full travel
    # means the same amount of velocity whichever layer it belongs to.
    let ratio = octaveRatio(fullScaleSpecies.mean, fullScaleFluid.mean,
      fullScaleField.mean)
    checkpoint("species " & fullScaleSpecies.mean.formatFloat(ffScientific, 3) &
      ", fluid " & fullScaleFluid.mean.formatFloat(ffScientific, 3) &
      ", field " & fullScaleField.mean.formatFloat(ffScientific, 3) &
      ", ratio " & ratio.formatFloat(ffDecimal, 1))
    check ratio <= 2.0
