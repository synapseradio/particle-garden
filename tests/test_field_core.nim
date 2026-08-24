# Analytic tests for src/field_core.nim: the pure 9-point Laplacian stencil and
# Gray-Scott reaction-diffusion step that the rd-step.wgsl compute shader
# mirrors. Every function is a plain scalar-in/scalar-out math
# function — the field grid itself lives only on the GPU (a storage texture),
# so these tests exercise one cell's update in isolation.

import std/unittest
import std/math
import std/[os, strutils]
import ../src/field_core
import ../src/config_ranges
# The wrap integrate.wgsl performs, taken from the suite's own tested oracle
# rather than reimplemented beside it.
from ../src/physics_core import wrapPosition, FRAME_DT_REFERENCE, frameFactor

const FIELD_CORE_TESTS_LOADED* = true

const EPSILON = 1e-9

# The shipped-frame harness
#
# evolve() mirrors one reaction-diffusion frame in the order webgpu_compute
# encodes it: fieldResolve folds every particle's deposit into the inhibitor
# channel once, then RD_STEPS_PER_FRAME Gray-Scott substeps run. Anything that
# claims a seed does or does not ignite has to be measured through this order —
# a per-substep deposit would force the field ~7x harder than the real frame.
#
# The grid is held at HARNESS_GRID (64x64) and the frame count low: `just test`
# compiles debug, and this is the only compute-heavy test in the suite.

const
  HARNESS_GRID = 64
    ## Field side length for the harness. Small enough to keep the native
    ## suite fast, large enough that a blob of HARNESS_BLOB_RADIUS has room to
    ## grow structure rather than immediately wrapping into itself.
  HARNESS_FRAMES = 60
    ## Frames per evolve() run. At RD_STEPS_PER_FRAME substeps each this is
    ## enough for Gray-Scott spots to divide and fill from the seed.
  HARNESS_BLOB_COUNT = 6
    ## Blobs the harness seeds. RD_SEED_BLOB_COUNT is calibrated for the
    ## shipped field, far larger than this 64x64 harness grid; 6 keeps the
    ## same rough coverage fraction here instead of flooding it.
  HARNESS_BLOB_RADIUS = 6.0
  HARNESS_DEPOSIT_COVERAGE = 16
    ## One cell in HARNESS_DEPOSIT_COVERAGE receives a particle deposit. The
    ## fraction (6.25%) is far denser than the shipped FIELD_W x FIELD_H
    ## field, where the 16000-particle default puts that population on ~0.7%
    ## of cells (1 in ~147) and the 128000 maximum on ~5.4%; as an areal rate
    ## this models the densest legitimate population, ~9x the default's.
    ## Direction per consumer: the negative and ceiling
    ## tests hold at this inflated rate and so hold a fortiori at the
    ## default's; the comparative tests normalize totals and cancel the
    ## coverage; the positive ignition observations do NOT survive
    ## de-inflation (measured: no ignition at 1/9.2 of this drive) — real
    ## cold-start ignition is per-nucleus, carried by the splat kernel and
    ## colony density and warranted by the in-app observation, never by this
    ## global rate. If secretion becomes population-normalized, recalibration
    ## rides that change.
  ALIVE_THRESHOLD = FIELD_ALIVE_THRESHOLD
    ## field_core's single aliveness authority, shared with the stepped
    ## probes and the shader's alive-cell census.
    ## Inhibitor concentration above which a cell reads as pattern rather than
    ## background. Gray-Scott's background sits at ~0 inhibitor.
  IGNITION_FRAME_BUDGET = 30
    ## Frames a colony may take to lift the field off the trivial fixed point
    ## before the cold start reads as a bug rather than a dawn.
    ##
    ## OBSERVED at the shipped radius and deposit: ignition on frame 12 (and on
    ## frame 4 at radius 8). The budget sits at 2.5x the observation so that
    ## retuning a diffusion or climate constant has to slow ignition
    ## substantially before this flakes. It also caps the sweep runs below:
    ## anything that has not ignited by here is counted as not igniting.

type
  DepositProfile = enum
    ## The two seed families the reaction-diffusion literature sweeps when
    ## locating a critical nucleus, since no closed-form 2D critical radius
    ## exists (docs/research/ignition-threshold.md).
    dpTopHat, dpGaussian
  HarnessField = array[HARNESS_GRID, array[HARNESS_GRID, float]]
  FieldStats = object
    ## Summary of the inhibitor channel after a run. std/mean is the structure
    ## metric: a flat field (dead or flooded) has a low ratio, real spots a
    ## high one.
    mean: float
    std: float
    maxB: float
    aliveFraction: float

func grayScottDiscriminant(feed, kill: float): float =
  ## Discriminant of (F+k)*V^2 - F*V + F*(F+k) = 0, the quadratic whose roots
  ## are the nontrivial fixed points' inhibitor concentrations. Non-negative
  ## exactly where a nontrivial homogeneous fixed point exists.
  feed * (feed - 4.0 * (feed + kill) * (feed + kill))

const
  HARNESS_PREV = block:
    ## Wrapped index of the cell before each row/column, resolved at compile
    ## time. The stencil needs eight wrapped lookups per cell per channel, and
    ## a runtime `mod` in that position dominates the sweep's cost.
    var table: array[HARNESS_GRID, int]
    for i in 0 ..< HARNESS_GRID:
      table[i] = (i + HARNESS_GRID - 1) mod HARNESS_GRID
    table
  HARNESS_NEXT = block:
    var table: array[HARNESS_GRID, int]
    for i in 0 ..< HARNESS_GRID:
      table[i] = (i + 1) mod HARNESS_GRID
    table

func harnessStencil(field: HarnessField, x, y: int): float =
  let
    north = HARNESS_PREV[y]
    south = HARNESS_NEXT[y]
    east = HARNESS_NEXT[x]
    west = HARNESS_PREV[x]
  laplacian9(
    center = field[y][x],
    north = field[north][x], south = field[south][x],
    east = field[y][east], west = field[y][west],
    ne = field[north][east], nw = field[north][west],
    se = field[south][east], sw = field[south][west])

func depositMask(): HarnessField =
  ## Static particle coverage: the cells a stationary particle population
  ## deposits into every frame. Deterministic (index-derived, not random) so a
  ## failing threshold means the physics moved, never the mask.
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      result[y][x] =
        if (y * HARNESS_GRID + x) mod HARNESS_DEPOSIT_COVERAGE == 0: 1.0
        else: 0.0

func maskTotal(mask: HarnessField): float =
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      result += mask[y][x]

const SCATTERED_MASK_TOTAL = (HARNESS_GRID * HARNESS_GRID) div
  HARNESS_DEPOSIT_COVERAGE
  ## depositMask()'s total weight: one cell in HARNESS_DEPOSIT_COVERAGE holds
  ## 1.0. The clustered masks normalize to this so the comparison isolates
  ## coherence from magnitude.

func clusteredDepositMask(radius: float, profile: DepositProfile):
    HarnessField =
  ## depositMask()'s total deposit, gathered into discs of `radius` instead of
  ## scattered one cell in HARNESS_DEPOSIT_COVERAGE.
  ##
  ## The total mask weight is normalized to match depositMask() EXACTLY. That
  ## is what makes the comparison mean anything: the two masks place the same
  ## deposit, so a difference in outcome is a difference in spatial coherence
  ## and nothing else. Without the normalization a wider kernel would simply be
  ## depositing more, and "clustering ignites" would be an artifact.
  ##
  ## Disc centers sit on a square lattice — deterministic, so a failing
  ## threshold means the physics moved and never the placement.
  ##
  ## Only each disc's own bounding box is visited, wrapping into the grid.
  ## Both profiles are exactly zero beyond the radius, so this touches the same
  ## cells a full-grid scan would have written and skips the ones it would have
  ## added zero to.
  let target = SCATTERED_MASK_TOTAL.float
  let perDisc = max(1.0, PI * radius * radius)
  let discCount = max(1, int(round(target / perDisc)))
  let side = max(1, int(ceil(sqrt(discCount.float))))
  let spacing = HARNESS_GRID.float / side.float
  let extent = int(ceil(radius))
  var placed = 0
  for gridY in 0 ..< side:
    for gridX in 0 ..< side:
      if placed >= discCount: break
      let centerX = int((gridX.float + 0.5) * spacing)
      let centerY = int((gridY.float + 0.5) * spacing)
      for dy in -extent .. extent:
        for dx in -extent .. extent:
          let distance = sqrt((dx * dx + dy * dy).float)
          let weight =
            case profile
            of dpTopHat: (if distance <= radius: 1.0 else: 0.0)
            of dpGaussian: depositSplatWeight(distance, radius)
          if weight == 0.0: continue
          let y = (centerY + dy + HARNESS_GRID) mod HARNESS_GRID
          let x = (centerX + dx + HARNESS_GRID) mod HARNESS_GRID
          result[y][x] = result[y][x] + weight
      inc placed
  let actual = maskTotal(result)
  if actual > 0.0:
    let scale = target / actual
    for y in 0 ..< HARNESS_GRID:
      for x in 0 ..< HARNESS_GRID:
        result[y][x] = result[y][x] * scale

func flatSeed(): tuple[a, b: HarnessField] =
  ## The state createFieldResources clears the field textures to: activator 1,
  ## inhibitor 0 everywhere. Gray-Scott's trivial fixed point.
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      result.a[y][x] = 1.0
      result.b[y][x] = 0.0

func blobSeed(nonce: uint32): tuple[a, b: HarnessField] =
  ## The seed field-seed.wgsl writes, evaluated through rdSeedCell.
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      let cell = rdSeedCell(x, y, nonce, HARNESS_GRID, HARNESS_GRID,
        HARNESS_BLOB_COUNT, HARNESS_BLOB_RADIUS)
      result.a[y][x] = cell.activator
      result.b[y][x] = cell.inhibitor

func substep(sourceA, sourceB: HarnessField, targetA, targetB: var HarnessField,
    feed, kill: float) =
  ## One Gray-Scott substep over the whole grid, reading one field pair and
  ## writing the other.
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      let (a, b) = grayScottStep(
        activator = sourceA[y][x], inhibitor = sourceB[y][x],
        laplacianA = harnessStencil(sourceA, x, y),
        laplacianB = harnessStencil(sourceB, x, y),
        diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
        feed = feed, kill = kill, deltaT = RD_DELTA_T)
      targetA[y][x] = a
      targetB[y][x] = b

func advanceFrame(fieldA, fieldB, scratchA, scratchB: var HarnessField,
    mask: HarnessField, deposit, feed, kill: float,
    substeps = RD_STEPS_PER_FRAME, depositScale = RD_DEPOSIT_FRAME_SCALE) =
  ## One shipped frame in the order webgpu_compute encodes it: fieldResolve
  ## folds every particle's deposit into the inhibitor channel once — scaled
  ## by RD_DEPOSIT_FRAME_SCALE, mirroring field-resolve.wgsl — then
  ## RD_STEPS_PER_FRAME Gray-Scott substeps run. The two trailing parameters
  ## exist for the fold-invariance test; every other caller takes the shipped
  ## defaults. A non-default substep count must stay ODD or the copy-back
  ## below returns the wrong buffer.
  ##
  ## The substeps ping-pong between the field pair and a caller-owned scratch
  ## pair, exactly as the GPU ping-pongs its two field textures. Because
  ## RD_STEPS_PER_FRAME is odd — asserted in field_core.nim, and the same
  ## parity the real frame depends on — the live state lands in scratch, so
  ## the frame closes with one copy back rather than one per substep.
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      fieldB[y][x] = fieldB[y][x] + depositScale * mask[y][x] * deposit
  for index in 0 ..< substeps:
    if index mod 2 == 0:
      substep(fieldA, fieldB, scratchA, scratchB, feed, kill)
    else:
      substep(scratchA, scratchB, fieldA, fieldB, feed, kill)
  fieldA = scratchA
  fieldB = scratchB

func evolve(seedA, seedB: HarnessField, frames: int, deposit: float,
    feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL,
    mask = depositMask(), substeps = RD_STEPS_PER_FRAME,
    depositScale = RD_DEPOSIT_FRAME_SCALE): FieldStats =
  ## Run `frames` shipped frames from a seed and summarize the inhibitor
  ## channel. The two trailing parameters pass through to advanceFrame for
  ## the fold-invariance test; every other caller takes the shipped defaults.
  var fieldA = seedA
  var fieldB = seedB
  var scratchA, scratchB: HarnessField

  for _ in 0 ..< frames:
    advanceFrame(fieldA, fieldB, scratchA, scratchB, mask, deposit, feed, kill,
      substeps, depositScale)

  const CELLS = HARNESS_GRID * HARNESS_GRID
  var total = 0.0
  var alive = 0
  var peak = 0.0
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      let value = fieldB[y][x]
      total += value
      if value > peak: peak = value
      if value > ALIVE_THRESHOLD: inc alive
  let mean = total / CELLS.float
  var variance = 0.0
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      let centered = fieldB[y][x] - mean
      variance += centered * centered
  FieldStats(
    mean: mean,
    std: sqrt(variance / CELLS.float),
    maxB: peak,
    aliveFraction: alive.float / CELLS.float)

func framesToIgnite(mask: HarnessField, deposit: float,
    budget = IGNITION_FRAME_BUDGET,
    feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL): int =
  ## Frame on which the field first crosses ALIVE_THRESHOLD anywhere, starting
  ## from the trivial fixed point, or -1 if it never does within `budget`.
  ##
  ## Returning the frame rather than a bool is what lets one sweep answer both
  ## "does this radius ignite" and "does it ignite fast enough", and it stops
  ## early on success — which is most of why the sweep below is affordable.
  let seed = flatSeed()
  var fieldA = seed.a
  var fieldB = seed.b
  var scratchA, scratchB: HarnessField
  for frame in 0 ..< budget:
    advanceFrame(fieldA, fieldB, scratchA, scratchB, mask, deposit, feed, kill)
    for y in 0 ..< HARNESS_GRID:
      for x in 0 ..< HARNESS_GRID:
        if fieldB[y][x] > ALIVE_THRESHOLD: return frame + 1
  -1


# The field harness above holds its deposit mask fixed. This one lets the
# particles move, which is what a tropism bound is a claim about: deposit
# raises the field, the field's gradient moves the particle, the moved particle
# deposits again. Positive tropism closes that loop with the sign that
# Keller-Segel says admits chemotactic collapse.
#
# It reuses advanceFrame, so the field advances through exactly the shipped
# frame order. The particle half mirrors field-force.wgsl's gradient sample and
# integrate.wgsl's friction, soft velocity cap, and toroidal wrap.
#
# UNITS. field-force.wgsl computes an impulse in WORLD pixels from a gradient
# per FIELD CELL, so how many pixels a cell spans decides how far a given
# fieldForceScale actually moves a particle. The harness therefore runs in
# pixels with the same pixels-per-cell the shipped field has at a reference
# window width: 1920 px across FIELD_W cells is 3.75 px per cell, so a 64-cell
# harness world is 240 px wide. Everything below is that geometry, and the
# collapse point measured here is a statement about it.

const
  CHEMOTAXIS_PARTICLES = 256
    ## Particles the harness carries. Enough that a collapse concentrates a
    ## measurable mass, few enough that the splat stays cheaper than the field.
  CHEMOTAXIS_FRAMES = 120
    ## Frames per run. Long enough for the field to ignite (measured at frame
    ## 12 under uniform coverage) and for aggregation to develop and settle
    ## after it. Held down deliberately: the field half of a frame is the
    ## suite's most expensive operation, and these runs are its heaviest user.
  CHEMOTAXIS_REFERENCE_WORLD_WIDTH = 1920.0
    ## Reference window width the harness geometry is derived from. Only the
    ## ratio to FIELD_W matters: it sets how many pixels one field cell spans,
    ## and therefore how far one unit of fieldForceScale carries a particle
    ## across the pattern.
  CHEMOTAXIS_WORLD_PX =
    HARNESS_GRID.float * CHEMOTAXIS_REFERENCE_WORLD_WIDTH / FIELD_W.float
    ## Harness world width in pixels: 240, giving the shipped 3.75 px per cell.
  CHEMOTAXIS_FRICTION = 0.95
    ## The multiplier integrate.wgsl applies, at simulation_state's default
    ## friction of 0.05 (app.nim passes 1 - friction).
  CHEMOTAXIS_MAX_VELOCITY = 50.0
    ## simulation_state's default maxVelocity, in px per frame.
  CHEMOTAXIS_TILE = 8
    ## Side of the occupancy tile, in field cells. Wider than the deposit splat
    ## radius, so one tile is about the scale at which a cluster's deposits
    ## fully overlap and reinforce each other.
  CHEMOTAXIS_TILES = HARNESS_GRID div CHEMOTAXIS_TILE
  CHEMOTAXIS_UNIFORM_OCCUPANCY = 1.0 / (CHEMOTAXIS_TILES * CHEMOTAXIS_TILES).float
    ## Peak tile occupancy a perfectly uniform population would show: 1/64.

type
  ChemotaxisParticle = object
    x, y: float    ## World position in pixels
    vx, vy: float  ## Velocity in pixels per frame
  ChemotaxisRun = object
    ## What one run reports, at two spatial scales. peakTile is clustering:
    ## the fraction of the population inside the most crowded CHEMOTAXIS_TILE
    ## square. peakCell is concentration: the fraction inside a single field
    ## cell. The pair is what separates a colony pooling in a spot — high tile,
    ## low cell — from a chemotactic collapse, which drives BOTH toward 1
    ## because collapse concentrates mass to a point.
    peakTile: float
    peakCell: float
    maxB: float
    finite: bool

func chemotaxisSeed(count: int): seq[ChemotaxisParticle] =
  ## Deterministic scatter across the harness world. A fixed LCG rather than a
  ## lattice: a lattice would place every particle on a tile boundary, which is
  ## the one arrangement that flatters an occupancy metric.
  var state = 0x9E3779B9'u32
  for _ in 0 ..< count:
    state = state * 1664525'u32 + 1013904223'u32
    let sampleX = (state shr 8).float / 16777216.0
    state = state * 1664525'u32 + 1013904223'u32
    let sampleY = (state shr 8).float / 16777216.0
    result.add ChemotaxisParticle(
      x: sampleX * CHEMOTAXIS_WORLD_PX, y: sampleY * CHEMOTAXIS_WORLD_PX)

func chemotaxisCell(position: float): int =
  ## World pixel -> field cell, the mapping field-deposit.wgsl and
  ## field-force.wgsl both perform.
  clamp(int(position / CHEMOTAXIS_WORLD_PX * HARNESS_GRID.float),
    0, HARNESS_GRID - 1)

func chemotaxisMask(particles: seq[ChemotaxisParticle], secretion: float):
    HarnessField =
  ## This frame's deposit mask: every particle's normalized splat kernel,
  ## scaled by its species' signed secretion. advanceFrame multiplies the
  ## result by the deposit amplitude, so mask * deposit is speciesDeposit
  ## spread over the kernel.
  let normalization = depositSplatNormalization(RD_DEPOSIT_SPLAT_RADIUS)
  let extent = int(RD_DEPOSIT_SPLAT_RADIUS)
  for particle in particles:
    let cellX = chemotaxisCell(particle.x)
    let cellY = chemotaxisCell(particle.y)
    for dy in -extent .. extent:
      for dx in -extent .. extent:
        let weight = depositSplatWeight(
          sqrt((dx * dx + dy * dy).float), RD_DEPOSIT_SPLAT_RADIUS)
        if weight == 0.0: continue
        let y = (cellY + dy + HARNESS_GRID) mod HARNESS_GRID
        let x = (cellX + dx + HARNESS_GRID) mod HARNESS_GRID
        result[y][x] = result[y][x] + weight / normalization * secretion

func chemotaxisAdvanceParticles(particles: var seq[ChemotaxisParticle],
    inhibitor: HarnessField, fieldForceScale, tropism: float) =
  ## One particle step: sample the inhibitor gradient, convert it to an impulse
  ## through the species' tropism, then apply integrate.wgsl's friction, soft
  ## velocity cap and toroidal wrap.
  for particle in particles.mitems:
    let cellX = chemotaxisCell(particle.x)
    let cellY = chemotaxisCell(particle.y)
    let east = inhibitor[cellY][HARNESS_NEXT[cellX]]
    let west = inhibitor[cellY][HARNESS_PREV[cellX]]
    let north = inhibitor[HARNESS_PREV[cellY]][cellX]
    let south = inhibitor[HARNESS_NEXT[cellY]][cellX]
    let gradX = (east - west) * 0.5
    let gradY = (south - north) * 0.5

    var velocityX = (particle.vx +
      speciesTropismForce(gradX, fieldForceScale, tropism)) * CHEMOTAXIS_FRICTION
    var velocityY = (particle.vy +
      speciesTropismForce(gradY, fieldForceScale, tropism)) * CHEMOTAXIS_FRICTION

    let speed = sqrt(velocityX * velocityX + velocityY * velocityY)
    let softCap = CHEMOTAXIS_MAX_VELOCITY * 0.5
    if speed > softCap:
      let compressed = softCap + ln(1.0 + (speed - softCap))
      let scale = min(compressed, CHEMOTAXIS_MAX_VELOCITY) / speed
      velocityX = velocityX * scale
      velocityY = velocityY * scale

    particle.vx = velocityX
    particle.vy = velocityY
    # wrapPosition carries a position across at most one world span, which is
    # all a step here can cross: the soft cap holds each velocity component at
    # or below CHEMOTAXIS_MAX_VELOCITY, itself a fraction of
    # CHEMOTAXIS_WORLD_PX. f32 at the boundary because f32 is the width
    # integrate.wgsl wraps in.
    particle.x = wrapPosition(
      float32(particle.x + velocityX), float32(CHEMOTAXIS_WORLD_PX)).float
    particle.y = wrapPosition(
      float32(particle.y + velocityY), float32(CHEMOTAXIS_WORLD_PX)).float

func chemotaxisPeakOccupancy(particles: seq[ChemotaxisParticle]):
    tuple[tile, cell: float] =
  ## Fraction of the population inside the most crowded tile, and inside the
  ## most crowded single field cell. Uniform gives 1/64 and roughly 1/4096;
  ## a collapse drives both toward 1.
  var tiles: array[CHEMOTAXIS_TILES, array[CHEMOTAXIS_TILES, int]]
  var cells: array[HARNESS_GRID, array[HARNESS_GRID, int]]
  for particle in particles:
    let cellX = chemotaxisCell(particle.x)
    let cellY = chemotaxisCell(particle.y)
    inc tiles[cellY div CHEMOTAXIS_TILE][cellX div CHEMOTAXIS_TILE]
    inc cells[cellY][cellX]
  var peakTile = 0
  for row in tiles:
    for count in row:
      if count > peakTile: peakTile = count
  var peakCell = 0
  for row in cells:
    for count in row:
      if count > peakCell: peakCell = count
  (tile: peakTile.float / particles.len.float,
   cell: peakCell.float / particles.len.float)

proc runChemotaxis(tropism: float, deposit = RD_DEPOSIT_MAX,
    fieldForceScale = RD_DEFAULT_FIELD_FORCE,
    secretion = SECRETION_MAX, frames = CHEMOTAXIS_FRAMES): ChemotaxisRun =
  ## One full run from the trivial fixed point with a scattered population.
  ## Reports the WORST aggregation seen at any point in the run, not the final
  ## frame's: a collapse that forms and then scatters is still a collapse, and
  ## reading only the last frame would miss it.
  let seed = flatSeed()
  var fieldA = seed.a
  var fieldB = seed.b
  var scratchA, scratchB: HarnessField
  var particles = chemotaxisSeed(CHEMOTAXIS_PARTICLES)
  result.finite = true
  for _ in 0 ..< frames:
    advanceFrame(fieldA, fieldB, scratchA, scratchB,
      chemotaxisMask(particles, secretion), deposit,
      RD_DEFAULT_FEED, RD_DEFAULT_KILL)
    chemotaxisAdvanceParticles(particles, fieldB, fieldForceScale, tropism)
    let occupancy = chemotaxisPeakOccupancy(particles)
    if occupancy.tile > result.peakTile: result.peakTile = occupancy.tile
    if occupancy.cell > result.peakCell: result.peakCell = occupancy.cell
    for y in 0 ..< HARNESS_GRID:
      for x in 0 ..< HARNESS_GRID:
        let value = fieldB[y][x]
        # NaN fails both comparisons with itself; an infinity fails neither,
        # so both have to be named to catch a diverged field.
        if value != value or value > 1.0e30: result.finite = false
        if value > result.maxB: result.maxB = value
    # A diverged field has already answered the question, and every later
    # frame only propagates infinities. Stopping here is what keeps the
    # divergence-locating runs cheap enough to ship in the suite.
    if not result.finite: return


suite "Gray-Scott Fixed-Point Structure":
  # Why this suite exists: the whole one-world design rests on the claim that
  # the shipped climate CANNOT produce a pattern from the uniform state, so any
  # pattern the user sees was nucleated by particles. That claim is analytic,
  # and these tests make it executable rather than a paragraph in a design doc.

  test "the nontrivial fixed points exist exactly where F >= 4*(F+k)^2":
    # CONTRACT: substituting the second fixed-point equation U*V = F+k into the
    # first, F*(1-U) = U*V^2, yields (F+k)*V^2 - F*V + F*(F+k) = 0. Its
    # discriminant factors to F*(F - 4*(F+k)^2), so with F > 0 a real nontrivial
    # V exists exactly where F >= 4*(F+k)^2.
    #
    # The test asserts the EQUIVALENCE, not just the algebra: where the
    # condition holds it constructs the root and checks grayScottStep maps it to
    # itself, and where it fails it checks no real root exists to construct.
    # That ties the inequality to the function it is a claim about.
    for feedStep in 0 .. 14:
      for killStep in 0 .. 14:
        let feed = RD_FEED_MIN +
          (RD_FEED_MAX - RD_FEED_MIN) * feedStep.float / 14.0
        let kill = RD_KILL_MIN +
          (RD_KILL_MAX - RD_KILL_MIN) * killStep.float / 14.0
        let discriminant = grayScottDiscriminant(feed, kill)
        let conditionHolds = feed >= 4.0 * (feed + kill) * (feed + kill)
        check (discriminant >= 0.0) == conditionHolds

        if conditionHolds:
          # The larger root, and the activator that pairs with it.
          let inhibitor = (feed + sqrt(discriminant)) / (2.0 * (feed + kill))
          let activator = (feed + kill) / inhibitor
          let (nextA, nextB) = grayScottStep(
            activator = activator, inhibitor = inhibitor,
            laplacianA = 0.0, laplacianB = 0.0,
            diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
            feed = feed, kill = kill, deltaT = RD_DELTA_T)
          check abs(nextA - activator) < 1e-12
          check abs(nextB - inhibitor) < 1e-12

  test "the shipped defaults sit where only the trivial fixed point exists":
    # CONTRACT: this is why the field needs no automatic seed. At F = 0.030,
    # k = 0.062, 4*(F+k)^2 = 0.033856 > 0.030 — the trivial state is the only
    # homogeneous fixed point, and it is linearly stable. No pattern can arise
    # from the uniform field at all; one must be nucleated. That is the
    # guarantee that the field records life rather than decorating it.
    #
    # If a future default moves into the self-starting region this test goes
    # red, and it should: the field would then paint itself with no particles.
    check grayScottDiscriminant(RD_DEFAULT_FEED, RD_DEFAULT_KILL) < 0.0
    check 4.0 * (RD_DEFAULT_FEED + RD_DEFAULT_KILL) *
      (RD_DEFAULT_FEED + RD_DEFAULT_KILL) > RD_DEFAULT_FEED

  test "the self-starting region stays reachable from the shipped sliders":
    # CONTRACT: the default is deliberately outside the self-starting region,
    # but a user who wants spontaneous chemistry must still be able to choose
    # it. If no reachable (feed, kill) satisfies the condition, the sliders have
    # locked away a whole regime and the notch tables in group 8 would be
    # labelling a place the user cannot go.
    var anyReachable = false
    for feedStep in 0 .. 20:
      for killStep in 0 .. 20:
        let feed = RD_FEED_MIN +
          (RD_FEED_MAX - RD_FEED_MIN) * feedStep.float / 20.0
        let kill = RD_KILL_MIN +
          (RD_KILL_MAX - RD_KILL_MIN) * killStep.float / 20.0
        if grayScottDiscriminant(feed, kill) >= 0.0:
          anyReachable = true
    check anyReachable


suite "Field Grid Wrap":
  test "the wrap lands every cell in range at any span":
    # CONTRACT: the field is a torus, so every integer cell coordinate — however
    # far outside the grid — names exactly one in-range cell. The single-mod
    # spelling `(cell + dims) mod dims` survives only one span of negativity;
    # this oracle is the floor-mod every shader's fieldWrap mirrors.
    # Dims of 8 keep each expectation checkable on sight.
    check fieldWrap(3, 8) == 3
    check fieldWrap(0, 8) == 0
    check fieldWrap(7, 8) == 7
    check fieldWrap(8, 8) == 0
    check fieldWrap(-1, 8) == 7
    check fieldWrap(-8, 8) == 0
    # Beyond one span of negativity: single-mod yields -1 here.
    check fieldWrap(-9, 8) == 7
    check fieldWrap(-17, 8) == 7
    check fieldWrap(-16, 8) == 0
    check fieldWrap(17, 8) == 1


suite "9-Point Laplacian Stencil":
  test "the laplacian is zero on a constant field":
    # CONTRACT: a cell surrounded by eight neighbors at its own value has no
    # curvature to diffuse away — the weights sum to 0, so the stencil must
    # report exactly 0.
    for value in [0.0, 0.5, 1.0, -3.0]:
      check laplacian9(
        value, value, value, value, value, value, value, value, value) == 0.0

  test "the laplacian is linear: laplacian of a sum is the sum of laplacians":
    # CONTRACT: the stencil is a fixed linear combination of its nine inputs,
    # so superposition must hold exactly for any two neighborhoods.
    let neighborhoodA = [0.2, 0.5, 0.1, 0.4, 0.3, 0.6, 0.8, 0.7, 0.9]
    let neighborhoodB = [0.9, 0.1, 0.6, 0.2, 0.7, 0.3, 0.4, 0.5, 0.8]
    var summed: array[9, float]
    for i in 0 ..< 9:
      summed[i] = neighborhoodA[i] + neighborhoodB[i]
    let sumLaplacian = laplacian9(
      summed[0], summed[1], summed[2], summed[3], summed[4],
      summed[5], summed[6], summed[7], summed[8])
    let separateSum =
      laplacian9(
        neighborhoodA[0], neighborhoodA[1], neighborhoodA[2], neighborhoodA[3],
        neighborhoodA[4], neighborhoodA[5], neighborhoodA[6], neighborhoodA[7],
        neighborhoodA[8]) +
      laplacian9(
        neighborhoodB[0], neighborhoodB[1], neighborhoodB[2], neighborhoodB[3],
        neighborhoodB[4], neighborhoodB[5], neighborhoodB[6], neighborhoodB[7],
        neighborhoodB[8])
    check abs(sumLaplacian - separateSum) < EPSILON

  test "a single spike at the center produces -1 times the center value":
    # CONTRACT: with all neighbors at 0, the normalized stencil reduces to
    # -center — the isolated-peak case that drives the peak's own decay.
    check laplacian9(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) == -1.0
    check laplacian9(2.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) == -2.5

  test "a single spike in one axis neighbor contributes 0.2 times its value":
    # CONTRACT: with center and the other neighbors at 0, each axis neighbor
    # contributes exactly its own value times the 0.2 axis weight.
    check laplacian9(0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) == 0.2
    check laplacian9(0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0) == 0.2
    check laplacian9(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0) == 0.2
    check laplacian9(0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0) == 0.2

  test "a single spike in one diagonal neighbor contributes 0.05 times its value":
    # CONTRACT: with center and the other neighbors at 0, each diagonal
    # neighbor contributes exactly its own value times the 0.05 diagonal
    # weight.
    check laplacian9(0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0) == 0.05
    check laplacian9(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0) == 0.05
    check laplacian9(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0) == 0.05
    check laplacian9(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0) == 0.05


suite "Gray-Scott Reaction Fixed Point":
  test "the trivial steady state (A=1, B=0, no diffusion) maps to itself for any feed/kill":
    # CONTRACT: the analytic warrant that the reaction terms are wired
    # correctly. At A=1, B=0 the reaction term A*B^2 vanishes, so feed only
    # ever multiplies (1-A)=0 and kill only ever multiplies B=0 — the state
    # is a fixed point independent of feed, kill, or the timestep.
    for feed in [0.01, 0.03, 0.08]:
      for kill in [0.04, 0.062, 0.075]:
        for deltaT in [0.5, 1.0, 2.0]:
          let (nextA, nextB) = grayScottStep(
            activator = 1.0, inhibitor = 0.0,
            laplacianA = 0.0, laplacianB = 0.0,
            diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
            feed = feed, kill = kill, deltaT = deltaT)
          check abs(nextA - 1.0) < EPSILON
          check abs(nextB - 0.0) < EPSILON


suite "Gray-Scott Reaction Direction Properties":
  test "the inhibitor decays when feed+kill depletion outweighs the reaction gain":
    # CONCRETE REGIME: A=0.1, B=0.5 — a low-activator, high-inhibitor cell.
    # The reaction gain A*B^2 = 0.1*0.25 = 0.025 is smaller than the
    # depletion (feed+kill)*B = 0.092*0.5 = 0.046 at the Pearson defaults, so
    # the inhibitor must shrink this step.
    let (_, nextB) = grayScottStep(
      activator = 0.1, inhibitor = 0.5,
      laplacianA = 0.0, laplacianB = 0.0,
      diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
      feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL, deltaT = RD_DELTA_T)
    check nextB < 0.5

  test "the activator relaxes toward 1 via the feed term when the inhibitor is absent":
    # CONCRETE REGIME: B=0 kills the reaction term outright (A*0^2 = 0), so
    # the only force on the activator is feed*(1-A), which is strictly
    # positive whenever A < 1 — the activator must move up, but not overshoot
    # past the 1.0 it is being fed toward.
    let (nextA, _) = grayScottStep(
      activator = 0.5, inhibitor = 0.0,
      laplacianA = 0.0, laplacianB = 0.0,
      diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
      feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL, deltaT = RD_DELTA_T)
    check nextA > 0.5
    check nextA < 1.0


suite "Gray-Scott Step Stays Finite And Bounded":
  test "the step stays finite and within a sane bound over in-range grid inputs":
    # CONTRACT: sampled over A,B in [0, 1.2] and both laplacians in [-1, 1] at
    # the default constants, the step must never produce NaN/Inf. Bound
    # derivation (dt=1, Da=1.0, Db=0.5, feed/kill at Pearson defaults):
    #   newA = A + (Da*lapA - A*B^2 + feed*(1-A))
    #     worst case: A in [0,1.2], B^2 <= 1.44, Da*lapA in [-1,1]
    #     => newA in roughly [-2.8, 2.3], comfortably inside +/-10.
    #   newB = B + (Db*lapB + A*B^2 - (feed+kill)*B)
    #     => newB in roughly [-0.7, 3.5], comfortably inside +/-10.
    const BOUND = 10.0
    for activator in [0.0, 0.3, 0.6, 0.9, 1.2]:
      for inhibitor in [0.0, 0.3, 0.6, 0.9, 1.2]:
        for laplacianA in [-1.0, 0.0, 1.0]:
          for laplacianB in [-1.0, 0.0, 1.0]:
            let (nextA, nextB) = grayScottStep(
              activator = activator, inhibitor = inhibitor,
              laplacianA = laplacianA, laplacianB = laplacianB,
              diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
              feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL, deltaT = RD_DELTA_T)
            check nextA == nextA  # false for NaN under IEEE 754
            check nextB == nextB
            check abs(nextA) < BOUND
            check abs(nextB) < BOUND


suite "Reaction-Diffusion Ignition":
  test "the flat activator=1 inhibitor=0 seed plus particle deposits never leaves the trivial fixed point":
    # CONTRACT: the render-pass clear createFieldResources performs leaves
    # Gray-Scott's trivial fixed point, and RD_DEFAULT_DEPOSIT splatted into
    # isolated cells is far too weak to leave it. Nothing but a spatially
    # coherent seed ignites this system, so nothing may be "simplified" back to
    # the clear.
    # OBSERVED: mean 0.0015, maxB 0.0050, alive 0.0 — the deposit accumulates a
    # trace of inhibitor and diffusion strips it again; no cell ever reaches
    # ALIVE_THRESHOLD. Threshold set an order of magnitude above that maxB.
    let seed = flatSeed()
    let stats = evolve(seed.a, seed.b, HARNESS_FRAMES, RD_DEFAULT_DEPOSIT)
    check stats.maxB < 0.05
    check stats.aliveFraction == 0.0

  test "a spatially coherent blob seed develops structure that survives the deposit forcing":
    # CONTRACT: rdSeedCell's blobs must ignite Gray-Scott and the pattern must
    # still be pattern — not a uniform flood — after the particle deposit has
    # been folded in every frame. std/mean separates the two: real spots hold
    # a high ratio, a flood collapses toward 0.
    # OBSERVED: mean 0.102, std/mean 1.12, maxB 0.407, alive 0.292. Every
    # threshold below sits at roughly half its observation, so retuning a
    # constant has to move the physics substantially before this flakes.
    let seed = blobSeed(1'u32)
    let stats = evolve(seed.a, seed.b, HARNESS_FRAMES, RD_DEFAULT_DEPOSIT)
    check stats.aliveFraction > 0.15
    check stats.std / stats.mean > 0.55
    check stats.maxB > 0.20

  test "an isolated single-cell perturbation dies out":
    # CONTRACT: diffusion costs an isolated peak Db*(-B) per substep with no
    # neighbors to replenish it, so per-cell noise cannot seed this system —
    # only coherent structure can. This is the test that stops anyone
    # replacing rdSeedCell's blobs with a cheaper per-cell random field.
    # OBSERVED: maxB 1.2e-19 — decayed to nothing, not merely to something
    # small. The 0.01 threshold is far above that on purpose: what is being
    # pinned is "dies", not the exact rate.
    var seedA, seedB: HarnessField
    for y in 0 ..< HARNESS_GRID:
      for x in 0 ..< HARNESS_GRID:
        seedA[y][x] = 1.0
        seedB[y][x] = if (y * HARNESS_GRID + x) mod 50 == 0: 0.5 else: 0.0
    let stats = evolve(seedA, seedB, HARNESS_FRAMES, 0.0)
    check stats.maxB < 0.01

  test "the deposit range ceiling stays bounded at every feed/kill corner":
    # CONTRACT: this is the warrant for RD_DEPOSIT_MAX. A user dragging the
    # Deposit slider to its ceiling must not be able to drive the field to NaN
    # or wash it out, at any corner of the feed/kill sliders. The weakest
    # corner is (RD_FEED_MIN, RD_KILL_MIN), where the (feed+kill)*B depletion
    # that opposes the deposit is at its smallest.
    # If this fails, lower RD_DEPOSIT_MAX — never the assertion.
    # OBSERVED maxB per corner: (0.010, 0.040) 0.281, (0.010, 0.075) 0.052,
    # (0.080, 0.040) 0.545, (0.080, 0.075) 0.012. The worst corner sits at
    # roughly a third of the 1.5 bound. Note the high-feed/low-kill corner
    # floods (alive 1.0) rather than patterning — that is a user's own
    # choice of feed and kill, and it stays finite, which is what is asserted.
    for feed in [RD_FEED_MIN, RD_FEED_MAX]:
      for kill in [RD_KILL_MIN, RD_KILL_MAX]:
        let seed = blobSeed(1'u32)
        let stats = evolve(seed.a, seed.b, HARNESS_FRAMES, RD_DEPOSIT_MAX,
          feed = feed, kill = kill)
        check stats.maxB == stats.maxB  # false for NaN under IEEE 754
        check stats.maxB < 1.5


suite "Ignition From Coherent Deposits":
  # The measurement gate: RD_DEPOSIT_SPLAT_RADIUS is not a taste pick — it is
  # whatever this sweep says the floor is. The literature offers no closed-form
  # 2D critical radius (docs/research/ignition-threshold.md), so sweeping
  # top-hat and Gaussian seeds over radius and amplitude IS the field's own
  # method rather than a workaround for not having found the formula.
  #
  # Every run below starts from the flat trivial fixed point with no seed. That
  # is the state the app opens in.

  test "a clustered deposit ignites where a scattered deposit of equal coverage does not":
    # CONTRACT: same total deposit, different spatial arrangement, different
    # outcome. clusteredDepositMask normalizes to depositMask()'s total, so the
    # only variable is coherence.
    #
    # OBSERVED at the shipped defaults (frame of ignition, -1 for none):
    #   radius   1     2     3     5     8
    #   top-hat  -1    -1    -1    -1     9
    #   gaussian -1    -1    -1    12     4
    # and at amplitude 0.04 radius 3 top-hat ignites, at 0.08 radius 2 does.
    # The scattered baseline ignites at no amplitude in the range.
    for amplitude in [RD_DEFAULT_DEPOSIT, RD_DEPOSIT_MAX]:
      check framesToIgnite(depositMask(), amplitude) == -1

    var anyClusteredIgnited = false
    for radius in [1.0, 2.0, 3.0, 5.0, 8.0]:
      for profile in [dpTopHat, dpGaussian]:
        for amplitude in [RD_DEPOSIT_MIN, RD_DEFAULT_DEPOSIT, RD_DEPOSIT_MAX]:
          let ignitedOn = framesToIgnite(
            clusteredDepositMask(radius, profile), amplitude)
          if ignitedOn > 0:
            anyClusteredIgnited = true
            # Nothing ignites on zero deposit, whatever its shape — the field
            # is being asked to pattern with no input at all.
            check amplitude > 0.0
            # Nothing below the shipped radius may ignite at the shipped
            # deposit, or the radius is larger than the measurement warrants.
            if amplitude <= RD_DEFAULT_DEPOSIT:
              check radius >= RD_DEPOSIT_SPLAT_RADIUS
    check anyClusteredIgnited

  test "the shipped splat radius ignites at the shipped deposit":
    # CONTRACT: this is the warrant for RD_DEPOSIT_SPLAT_RADIUS's value, and
    # the test that goes red if a later change shrinks the kernel for cost or
    # weakens the deposit default. The pairing is what matters — neither
    # constant is meaningful alone.
    check framesToIgnite(
      clusteredDepositMask(RD_DEPOSIT_SPLAT_RADIUS, dpGaussian),
      RD_DEFAULT_DEPOSIT) > 0

  test "a clustered deposit below the critical radius relaxes to background":
    # The negative control: without it "clustering ignites" could be satisfied
    # by a kernel so wide that everything ignites, which would prove nothing
    # about coherence. Radius 1 is a splat in name only — it covers one cell —
    # and it must stay dead even at the deposit ceiling.
    #
    # Run to twice the budget, because "has not ignited yet" is a weaker claim
    # than "has relaxed to background". OBSERVED: no ignition at any amplitude
    # over 120 frames; the field decays to a trace.
    for profile in [dpTopHat, dpGaussian]:
      let mask = clusteredDepositMask(1.0, profile)
      check framesToIgnite(mask, RD_DEPOSIT_MAX,
        budget = IGNITION_FRAME_BUDGET * 2) == -1
      let seed = flatSeed()
      let stats = evolve(seed.a, seed.b, HARNESS_FRAMES, RD_DEPOSIT_MAX,
        mask = mask)
      check stats.aliveFraction == 0.0
      check stats.maxB < 0.05

  test "ignition completes within the cold-start budget at the shipped defaults":
    # Contract: the cold start must read as a dawn, not as a hang, and this is
    # the budget it must meet — the app opens dark and chemistry arrives
    # visibly. Observed: frame 12 against a budget of 30.
    let ignitedOn = framesToIgnite(
      clusteredDepositMask(RD_DEPOSIT_SPLAT_RADIUS, dpGaussian),
      RD_DEFAULT_DEPOSIT)
    check ignitedOn > 0
    check ignitedOn <= IGNITION_FRAME_BUDGET

  test "ignition survives the weakest climate corner the sliders offer":
    # CONTRACT: the shipped radius is measured at the Pearson defaults, but a
    # user may drag feed and kill anywhere. The corner where the (feed+kill)*B
    # depletion opposing the deposit is weakest must not be the corner that
    # breaks ignition. OBSERVED: frame 4 at radius 5.
    check framesToIgnite(
      clusteredDepositMask(RD_DEPOSIT_SPLAT_RADIUS, dpGaussian),
      RD_DEFAULT_DEPOSIT, feed = RD_FEED_MIN, kill = RD_KILL_MIN) > 0

  test "the splat kernel conserves a particle's total deposit at every radius":
    # CONTRACT: normalization is what keeps widening the kernel from becoming a
    # backdoor amplitude increase — which would flood the field past the
    # ceiling RD_DEPOSIT_MAX is measured against. The shader divides by
    # depositSplatNormalization, so the sum of normalized weights must be 1.
    for radius in [1.0, 2.0, 3.0, RD_DEPOSIT_SPLAT_RADIUS, 8.0]:
      let normalization = depositSplatNormalization(radius)
      check normalization > 0.0
      var summed = 0.0
      let extent = int(radius)
      for dy in -extent .. extent:
        for dx in -extent .. extent:
          summed += depositSplatWeight(
            sqrt((dx * dx + dy * dy).float), radius) / normalization
      check abs(summed - 1.0) < 1e-12

  test "the splat weight falls monotonically to zero at the radius":
    # CONTRACT: a falloff kernel that rose anywhere, or that cut off at a
    # nonzero weight, would put a visible ring or square edge on every colony's
    # deposit.
    var previous = depositSplatWeight(0.0, RD_DEPOSIT_SPLAT_RADIUS)
    check previous > 0.0
    for step in 1 .. 20:
      let distance = RD_DEPOSIT_SPLAT_RADIUS * step.float / 20.0
      let weight = depositSplatWeight(distance, RD_DEPOSIT_SPLAT_RADIUS)
      check weight <= previous
      previous = weight
    check depositSplatWeight(
      RD_DEPOSIT_SPLAT_RADIUS * 1.001, RD_DEPOSIT_SPLAT_RADIUS) == 0.0


suite "Species Chemistry Coupling":
  # The two shader expressions species chemistry adds, as pure functions. These
  # pin the sign convention, which is the part a later edit is most likely to
  # invert: config_ranges' asymmetric tropism range, the reasoning behind it,
  # and field-force.wgsl's direction all depend on positive meaning up-gradient.

  test "opposite secretion signs push the field in opposite directions":
    # SPEC SCENARIO "Builder and grazer diverge": two species carrying opposite
    # secretion signs must deposit with opposite signs at their own locations.
    let builder = speciesDeposit(RD_DEFAULT_DEPOSIT, SECRETION_MAX)
    let grazer = speciesDeposit(RD_DEFAULT_DEPOSIT, SECRETION_MIN)
    check builder > 0.0
    check grazer < 0.0
    check abs(builder + grazer) < EPSILON  # equal and opposite at equal magnitude

  test "zero secretion leaves no mark whatever the deposit amount":
    # SPEC SCENARIO "An inert species", the deposit half.
    for deposit in [RD_DEPOSIT_MIN, RD_DEFAULT_DEPOSIT, RD_DEPOSIT_MAX]:
      check speciesDeposit(deposit, 0.0) == 0.0

  test "negative tropism descends the gradient and positive climbs it":
    # SPEC SCENARIO "Tropism steers", and the convention the asymmetric range
    # is a claim about. With a positive inhibitor gradient (concentration
    # rising toward +x), a climbing species must be pushed toward +x and a
    # fleeing one toward -x.
    const RISING_GRADIENT = 0.05  # inhibitor gradients peak near this per cell
    let climbing = speciesTropismForce(
      RISING_GRADIENT, RD_DEFAULT_FIELD_FORCE, TROPISM_MAX)
    let fleeing = speciesTropismForce(
      RISING_GRADIENT, RD_DEFAULT_FIELD_FORCE, TROPISM_MIN)
    check climbing > 0.0
    check fleeing < 0.0
    # The shipped default is the fleeing sign at full strength: every species
    # descends the gradient unless the user says otherwise.
    check RD_DEFAULT_TROPISM < 0.0
    check speciesTropismForce(
      RISING_GRADIENT, RD_DEFAULT_FIELD_FORCE, RD_DEFAULT_TROPISM) < 0.0

  test "zero tropism leaves a species blind to any gradient":
    # SPEC SCENARIO "An inert species", the force half.
    for gradient in [-0.5, -0.05, 0.0, 0.05, 0.5]:
      check speciesTropismForce(gradient, RD_FIELD_FORCE_MAX, 0.0) == 0.0

  test "the chemistry stride names two distinct slots":
    # CONTRACT: config.nim lays the CPU-side array out at this stride and the
    # panel indexes it through the served slot numbers. Two fields sharing a
    # slot would silently alias secretion onto tropism.
    check SPECIES_CHEMISTRY_STRIDE == 2
    check SPECIES_SECRETION_SLOT != SPECIES_TROPISM_SLOT
    check SPECIES_SECRETION_SLOT >= 0
    check SPECIES_SECRETION_SLOT < SPECIES_CHEMISTRY_STRIDE
    check SPECIES_TROPISM_SLOT >= 0
    check SPECIES_TROPISM_SLOT < SPECIES_CHEMISTRY_STRIDE

  test "the tropism range grants less authority up-gradient than down":
    # Contract: the tropism range's asymmetry, as an executable claim rather
    # than a comment. A future tidy-up to a symmetric [-1, +1] fails here.
    check TROPISM_MAX < abs(TROPISM_MIN)
    check TROPISM_MIN < 0.0
    check TROPISM_MAX > 0.0
    # Secretion carries no such hazard, so its range stays symmetric.
    check SECRETION_MAX == abs(SECRETION_MIN)


suite "Chemotactic Collapse Bound":
  # The measurement gate for TROPISM_MAX: tropism is bounded asymmetrically
  # because Keller-Segel gives a chemotactic-collapse threshold (chi*M > 8*pi
  # in 2D) for positive chemosensitivity only — agents climbing their own
  # deposited gradient — while negative chemosensitivity is stabilizing
  # (docs/research/chemotaxis-stability.md).
  #
  # Where the collapse lives: in the product of tropism and deposit, so a scan
  # that holds one at its ceiling cannot find it — sweeping tropism alone at the
  # shipped deposit ceiling never diverges however far it is pushed. Widening
  # the deposit axis locates the boundary, and the control below proves the
  # divergence belongs to the chemotaxis rather than to the deposit.
  #
  # Every run starts from the trivial fixed point with a scattered population
  # and every species at SECRETION_MAX. The deposit is stated per test, in
  # multiples of RD_DEPOSIT_MAX — the most the slider can produce.

  const CHEMOTAXIS_CONCENTRATION_CEILING = 0.25
    ## Fraction of the population one field cell may hold before the
    ## aggregation reads as collapse rather than as a colony pooling in a spot.
    ## A colony spreads over a spot several cells across; a collapse drives
    ## this to 1.0 exactly, which is what the divergent runs below report.
    ## Inside the reachable range nothing exceeds 0.11, so this sits at
    ## roughly 2.5x the worst reachable measurement.

  # The shared runs, evaluated once for the suite rather than per test: each is
  # 120 frames of the field, the most expensive operation in the suite.
  let frozenRun = runChemotaxis(0.0, secretion = SECRETION_MAX)
  let boundRunDefault = runChemotaxis(TROPISM_MAX)
  let boundRunMaxForce = runChemotaxis(
    TROPISM_MAX, fieldForceScale = RD_FIELD_FORCE_MAX)
  let downRun = runChemotaxis(TROPISM_MIN, fieldForceScale = RD_FIELD_FORCE_MAX)
  let reachableExtremeRun = runChemotaxis(
    TROPISM_MAX * 1024.0, fieldForceScale = RD_FIELD_FORCE_MAX)
  const COLLAPSE_DEPOSIT_SAFE_MULTIPLE = 10.0
    ## Largest deposit, in multiples of RD_DEPOSIT_MAX, at which no tropism
    ## sampled diverges the field. The lower half of the bracket.
  const COLLAPSE_DEPOSIT_MULTIPLE = 15.0
    ## Smallest deposit sampled at which some tropism DOES diverge it, and low
    ## enough that the deposit alone still cannot — a frozen population stays
    ## finite here and through 30x, and only diverges by 40x. The upper half.
    ## Measured at the reference step count: if RD_STEPS_PER_FRAME moves, the
    ## demonstration needs field-time parity — nominal multiple scaled by the
    ## inverse of RD_DEPOSIT_FRAME_SCALE and demo frames scaled to the same
    ## total field steps (a substeps-3 recalibration measured 30x over doubled
    ## frames as the working coordinates).

  # The runs that bracket the collapse, all with the field force at its maximum.
  let boundAtSafeDeposit = runChemotaxis(
    TROPISM_MAX, deposit = RD_DEPOSIT_MAX * COLLAPSE_DEPOSIT_SAFE_MULTIPLE,
    fieldForceScale = RD_FIELD_FORCE_MAX)
  let extremeAtSafeDeposit = runChemotaxis(
    TROPISM_MAX * 128.0,
    deposit = RD_DEPOSIT_MAX * COLLAPSE_DEPOSIT_SAFE_MULTIPLE,
    fieldForceScale = RD_FIELD_FORCE_MAX)
  let frozenAtHighDeposit = runChemotaxis(
    0.0, deposit = RD_DEPOSIT_MAX * COLLAPSE_DEPOSIT_MULTIPLE,
    fieldForceScale = RD_FIELD_FORCE_MAX)
  let chemotaxisAtHighDeposit = runChemotaxis(
    TROPISM_MAX * 8.0, deposit = RD_DEPOSIT_MAX * COLLAPSE_DEPOSIT_MULTIPLE,
    fieldForceScale = RD_FIELD_FORCE_MAX)
  let collapsedRun = runChemotaxis(
    TROPISM_MAX, deposit = RD_DEPOSIT_MAX * COLLAPSE_DEPOSIT_MULTIPLE,
    fieldForceScale = RD_FIELD_FORCE_MAX)

  test "positive tropism at its bound does not produce unbounded aggregation over N steps":
    # Contract: the first half of the warrant for TROPISM_MAX. At the
    # positive bound with the maximum deposit, neither the population nor the
    # field may run away — at the default field force and at the strongest the
    # slider offers.
    # Observed over 120 frames (peak tile / peak cell / maxB):
    #   fieldForceScale 30:  0.102 / 0.051 / 0.786
    #   fieldForceScale 150: 0.211 / 0.039 / 0.793
    for run in [boundRunDefault, boundRunMaxForce]:
      check run.finite
      check run.maxB < 1.5
      check run.peakCell < CHEMOTAXIS_CONCENTRATION_CEILING

  test "collapse needs a deposit well outside the range the slider offers":
    # Contract: the second test restated on the axis the measurement
    # actually brackets. THE DEPOSIT CEILING IS WHAT PROTECTS THE WORLD, not the
    # tropism bound — the suite's own conclusion, now the thing asserted.
    #
    # MEASURED, fieldForceScale at its maximum, tropism 0 to 128x the bound
    # (DIVERGED marks the tropism multiples that ran away):
    #   deposit  5x ceiling: finite everywhere
    #   deposit 10x ceiling: finite everywhere
    #   deposit 15x ceiling: DIVERGED at 1x and 2x
    #   deposit 20x ceiling: DIVERGED at 1x, 2x and 4x
    #   deposit 30x ceiling: DIVERGED at 1x, 2x, 4x and 8x
    # So the deposit bracket is (10x, 15x] of a ceiling the slider already caps,
    # and the reachable range sits an order of magnitude below it.
    #
    # Collapse lives in a middle band of tropism, which is why no bound on
    # tropism alone would help: at zero there is no aggregation to run away, and
    # at 16x and above particles overshoot the well and scatter instead of
    # pooling. Only moderate chemotaxis dwells long enough to concentrate a
    # deposit, and the band widens downward from the top as the deposit rises.
    # A tropism bound cannot sit below a band whose floor it is already inside.
    check boundAtSafeDeposit.finite
    check boundAtSafeDeposit.peakCell < CHEMOTAXIS_CONCENTRATION_CEILING
    check extremeAtSafeDeposit.finite
    check not collapsedRun.finite

  test "the collapse belongs to the chemotaxis, not to the deposit alone":
    # The control that makes the previous test mean anything: fifteen times the
    # deposit ceiling is far outside the slider range, so a divergence there
    # could plausibly be the deposit flooding the field on its own — which
    # would say nothing about tropism. It is not: with the SAME deposit and no
    # chemotaxis at all, the field stays finite and saturates where it always
    # does. Only the up-gradient motion, concentrating that deposit into one
    # place, diverges it.
    #
    # OBSERVED, frozen population, fieldForceScale at maximum: maxB 0.908 at 15x
    # the deposit ceiling, still finite at 30x (maxB 1.008), divergent by 40x.
    # COLLAPSE_DEPOSIT_MULTIPLE carries the reasoning behind the gap.
    check frozenAtHighDeposit.finite
    check frozenAtHighDeposit.maxB < 1.5
    # Same deposit, same field, chemotaxis added -> divergence. The pair is the
    # claim; neither run alone supports it.
    check not collapsedRun.finite

  test "no tropism collapses the field at any deposit the sliders allow":
    # CONTRACT: the bound the user can actually reach. Inside the deposit
    # range, tropism has enormous margin — a thousandfold over the bound stays
    # finite and bounded. This is why RD_DEPOSIT_MAX carries more of the safety
    # than TROPISM_MAX does, and it is the honest scope of the tropism bound's
    # protection.
    # OBSERVED at RD_DEPOSIT_MAX, fieldForceScale at its maximum, tropism at
    # 1024x the bound: finite and bounded.
    check reachableExtremeRun.finite
    check reachableExtremeRun.maxB < 1.5
    check reachableExtremeRun.peakCell < CHEMOTAXIS_CONCENTRATION_CEILING

  test "the field saturates against deposit magnitude but not against concentration":
    # The mechanism, stated as a checkable relation rather than as prose: the
    # inhibitor's linear (feed+kill)*B sink grows with B while the deposit rate
    # per cell does not, so raising the deposit uniformly only moves the
    # saturation point a little: 1x and 10x the ceiling land within 0.1 of each
    # other. Concentrating the same deposit is a different matter — that raises
    # the rate PER CELL, and past a threshold the autocatalytic A*B^2 term
    # outruns the sink and the peak runs away.
    #
    # This is what corrects the tempting explanation that "Gray-Scott bounds
    # its own inhibitor, so no collapse is possible". Gray-Scott bounds it
    # against amplitude, not against concentration.
    # OBSERVED (frozen, uniform deposits): 1x -> maxB 0.015 (never ignites),
    # 15x -> maxB 0.908, 30x -> 1.008. Fifteen times the deposit ceiling under
    # 128x the tropism bound, which concentrates rather than spreads it,
    # diverges from that same band.
    check frozenAtHighDeposit.maxB < 1.5
    check chemotaxisAtHighDeposit.maxB < 1.5
    # A uniform deposit and the same deposit under bounded chemotaxis land in
    # the same saturated band; only unbounded concentration escapes it.
    # OBSERVED: 0.908 frozen against 0.966 under chemotaxis at 8x the bound.
    check abs(frozenAtHighDeposit.maxB - chemotaxisAtHighDeposit.maxB) < 0.3

  test "the down-gradient sign does not aggregate beyond the scattering floor":
    # CONTRACT: this is what makes the asymmetric bound mean something. If both
    # signs behaved alike, granting one full authority and the other half would
    # be arbitrary.
    #
    # Measured against the FROZEN control rather than against the uniform
    # ideal. 256 particles dropped into 64 tiles already put twice the uniform
    # share in the fullest tile purely by sampling, so a bare comparison
    # against 1/64 would read that noise as chemotaxis. The claim is that
    # down-gradient motion leaves the population no more clustered than never
    # moving it at all — and it holds exactly, to the particle.
    # OBSERVED: frozen 0.031 / 0.008, down-gradient 0.031 / 0.008.
    #
    # The sampling floor, asserted rather than asserted-about: the frozen
    # control really does sit above the uniform ideal, which is precisely why
    # the comparisons below are drawn against it and not against 1/64.
    check frozenRun.peakTile > CHEMOTAXIS_UNIFORM_OCCUPANCY
    check downRun.finite
    check downRun.peakTile <= frozenRun.peakTile
    check downRun.peakCell <= frozenRun.peakCell
    # And the up-gradient sign, at the very same magnitude, does aggregate —
    # which is the asymmetry the range encodes.
    check boundRunMaxForce.peakTile > frozenRun.peakTile * 2.0

  test "up-gradient motion nucleates the field where a scattered deposit cannot":
    # A REAL FINDING, not merely a safety property. A frozen population laying
    # down a uniform scatter never ignites the field — the group 1 result, in a
    # moving-particle harness — and neither does a down-gradient one, because
    # fleeing its own trail keeps the deposit scattered. Up-gradient motion
    # concentrates that same deposit into a coherent nucleus and ignites it.
    # Coherence is what crosses Gray-Scott's threshold, and chemotaxis is a way
    # of manufacturing coherence out of a uniform scatter.
    #
    # NOTE ON SCOPE: this harness runs no inter-particle forces, so a scattered
    # start stays scattered unless the field itself gathers it. In a world
    # coupling forces alongside the field, particle-life colonies supply the
    # coherence instead.
    # The shipped default tropism is negative, so the field ignites from
    # COLONIES, never from the chemistry alone.
    # OBSERVED: frozen maxB 0.015, down-gradient 0.013, up-gradient 0.793.
    check frozenRun.maxB < 0.05
    check downRun.maxB < 0.05
    check boundRunMaxForce.maxB > 0.5


suite "The Regime Deposit Floor Preserves The Regime":
  # Why this suite exists: two named regimes (Worms, Coral) do not ignite at the
  # default deposit, so the regime buttons raise it to
  # RD_REGIME_HIGH_FEED_DEPOSIT. That floor carries its own risk: more inhibitor
  # is not neutral, and a deposit large enough to ignite a regime could push it
  # into a NEIGHBOURING morphology. Replacing a dead button with a lying one
  # would be worse — a dead button says the feature is unfinished, a lying one
  # says the vocabulary is meaningless.
  #
  # The reference is the unforced attractor: the pattern Gray-Scott settles into
  # at a regime's own (F, k) from a supercritical nucleus with NO particle
  # deposit at all. That is what the regime's own coordinates name. Comparing two elevated
  # deposits against each other would show only that two high deposits resemble
  # each other, which is not the claim.
  #
  # Two controls make the comparison mean something, and without them it would
  # be vacuous:
  #   - A regime that gets NO floor (Labyrinth) run through the identical
  #     procedure, so a pass cannot come from the procedure itself.
  #   - A separation check: two DIFFERENT regimes must be further apart in this
  #     statistic than any regime is from its own floored self. A statistic that
  #     cannot tell Coral from Labyrinth would "prove" anything.
  #
  # Settling time is load-bearing: at 60 frames the shipped path has not settled
  # and Coral reads as a different morphology entirely — that measurement is an
  # artifact of stopping early, not a real divergence. Both sides run the same
  # number of frames for this reason.

  const SETTLE_FRAMES = 150
    ## Frames both sides settle for. Long enough that the shipped path has
    ## converged (at 60 it has not), short enough to stay affordable.
  const NUCLEUS_RADIUS = 16.0
  const NUCLEUS_INHIBITOR = 0.25
  const NUCLEUS_ACTIVATOR = 0.75
    ## A FLAT-TOPPED supercritical nucleus. rdSeedCell's blob tapers from half
    ## its radius and is too weak to ignite the high-feed regimes at all, and at
    ## activator 0.5 even a flat disc dies there — the basin at those
    ## coordinates is narrow. This seed exists to reach the attractor, not to
    ## model anything the app does.

  type Morphology = tuple[alive, structure: float]

  func morphologyOf(stats: FieldStats): Morphology =
    ## What fraction of the field is pattern, and how structured it is.
    ## std/mean separates real morphology from a flat flood — the same
    ## discriminator the ignition suite uses.
    (alive: stats.aliveFraction,
     structure: (if stats.mean > 1e-12: stats.std / stats.mean else: 0.0))

  func morphologyDistance(a, b: Morphology): float =
    abs(a.alive - b.alive) + abs(a.structure - b.structure)

  proc unforcedMorphology(feed, kill: float): Morphology =
    ## The regime's own attractor: nucleus, no deposit, nothing but the reaction.
    var seedA, seedB: HarnessField
    for y in 0 ..< HARNESS_GRID:
      for x in 0 ..< HARNESS_GRID:
        let dx = float(x - HARNESS_GRID div 2)
        let dy = float(y - HARNESS_GRID div 2)
        let inside = sqrt(dx * dx + dy * dy) <= NUCLEUS_RADIUS
        seedA[y][x] = if inside: NUCLEUS_ACTIVATOR else: 1.0
        seedB[y][x] = if inside: NUCLEUS_INHIBITOR else: 0.0
    morphologyOf(evolve(seedA, seedB, SETTLE_FRAMES, RD_DEPOSIT_MIN,
      feed = feed, kill = kill))

  proc shippedMorphology(feed, kill, deposit: float): Morphology =
    ## What a user actually gets after pressing the button: no seed, flat
    ## trivial start, colonies depositing through the splat kernel.
    let flat = flatSeed()
    morphologyOf(evolve(flat.a, flat.b, SETTLE_FRAMES, deposit,
      feed = feed, kill = kill,
      mask = clusteredDepositMask(RD_DEPOSIT_SPLAT_RADIUS, dpGaussian)))

  # Computed once for the suite; each is SETTLE_FRAMES of the field.
  let wormsUnforced = unforcedMorphology(0.078, 0.061)
  let coralUnforced = unforcedMorphology(0.082, 0.059)
  let labyrinthUnforced = unforcedMorphology(0.029, 0.057)
  let wormsFloored = shippedMorphology(0.078, 0.061, RD_REGIME_HIGH_FEED_DEPOSIT)
  let coralFloored = shippedMorphology(0.082, 0.059, RD_REGIME_HIGH_FEED_DEPOSIT)
  let labyrinthUnfloored = shippedMorphology(0.029, 0.057, RD_DEFAULT_DEPOSIT)

  test "the statistic separates different regimes from each other":
    # The vacuity guard, and it runs first on purpose. If this fails, every
    # agreement below is meaningless — a statistic that cannot tell two regimes
    # apart would report any two patterns as the same morphology.
    # OBSERVED separations: Worms/Coral 1.25, Worms/Labyrinth 1.65,
    # Coral/Labyrinth 0.40. The tightest pair is four times the largest
    # within-regime distance measured below.
    let separations = [
      morphologyDistance(wormsUnforced, coralUnforced),
      morphologyDistance(wormsUnforced, labyrinthUnforced),
      morphologyDistance(coralUnforced, labyrinthUnforced)]
    for separation in separations:
      check separation > 0.35

  test "a floored regime settles into its own unforced morphology":
    # CONTRACT: the button is honest. Each floored regime must land closer to
    # ITS OWN unforced attractor than to any other regime's.
    # OBSERVED (alive / std-over-mean), 150 frames:
    #   Worms unforced 0.188 / 1.90   floored 0.177 / 2.02   distance 0.13
    #   Coral unforced 0.497 / 0.96   floored 0.448 / 1.01   distance 0.10
    # Against nearest-other-regime distances of 0.40 and above.
    #
    # If this goes red the floor has moved a regime into a neighbouring
    # morphology: the button would be lying, and the fix is to find a deposit
    # that ignites without distorting — not to widen the tolerance here.
    for (floored, own, other) in [
        (wormsFloored, wormsUnforced, coralUnforced),
        (coralFloored, coralUnforced, labyrinthUnforced)]:
      check floored.alive > 0.05  # a dead field would "match" nothing
      check morphologyDistance(floored, own) < morphologyDistance(floored, other)
      check morphologyDistance(floored, own) <
        morphologyDistance(own, other) * 0.5

  test "a regime that gets no floor behaves the same way under the same procedure":
    # The negative control on the procedure: Labyrinth needs no deposit floor —
    # it ignites at the default — so running it through the identical comparison
    # shows what agreement looks like when nothing is raised. If the floored
    # regimes matched their attractors but this did not, the procedure would be
    # measuring the floor rather than the morphology.
    # OBSERVED: unforced 0.539 / 0.60, shipped at the default 0.535 / 0.62 —
    # distance 0.02, the tightest agreement in the suite, as it should be.
    # Labyrinth rather than Spots: Spots, Mitosis and Waves have no unforced
    # attractor to compare against in this harness. At their low feed a nucleus
    # cannot sustain itself without continuous deposit, so their pattern is
    # deposit-sustained by nature and "unforced Spots" does not exist.
    check morphologyDistance(labyrinthUnfloored, labyrinthUnforced) <
      morphologyDistance(labyrinthUnforced, coralUnforced)

  test "every regime the buttons can select settles into something alive":
    # The plainest statement of what a regime button promises, across all six —
    # each at whatever deposit its own entry says it needs.
    for regime in RD_REGIMES:
      let deposit =
        if regime.minDeposit > 0.0: regime.minDeposit else: RD_DEFAULT_DEPOSIT
      let settled = shippedMorphology(regime.feed, regime.kill, deposit)
      check settled.alive > 0.05
      check settled.structure > 0.3


suite "Reaction-Diffusion Tuning Constants":
  test "tuning constants hold their documented values":
    # Field dimensions and diffusion rates are pinned by the relations they
    # have to satisfy rather than by their literals — see "The Field Draws A
    # Small Pattern On Square Cells" below.
    check RD_DELTA_T == 1.0
    check RD_STEPS_PER_FRAME == 7
    check RD_DEFAULT_FEED == 0.030
    check RD_DEFAULT_KILL == 0.062
    check RD_DEPOSIT_STEP_REFERENCE == 8
    check RD_DEPOSIT_FRAME_SCALE ==
      float(1 + RD_STEPS_PER_FRAME) / float(RD_DEPOSIT_STEP_REFERENCE)

  test "the substep count keeps the field ping-pong chain closed":
    # CONTRACT: fieldResolve is itself one ping-pong stage (it reads the trail
    # texture and writes the front), so a frame performs 1 + RD_STEPS_PER_FRAME
    # texture swaps. That total must be even for the live field to land back on
    # the texture the next frame's resolve reads and the renderer samples. An
    # even RD_STEPS_PER_FRAME silently discards the last substep every frame.
    check RD_STEPS_PER_FRAME mod 2 == 1

  test "the deposit fold is invariant per field step under the substep knob":
    # CONTRACT: deposits fold once per frame while the reaction runs
    # 1 + RD_STEPS_PER_FRAME steps, so without the frame scale a lower substep
    # count delivers MORE deposit per unit of field time — measured unscaled
    # at 3 substeps as a scattered mask igniting on frame 6, the critical
    # radius falling from 5 to 3, and the single-cell negative control
    # lighting the field. Equal field steps at equal per-step deposit must
    # land near the same field, whatever the frame granularity; nearness is
    # bounded rather than exact because the fold arrives every 4 steps in one
    # variant and every 8 in the other.
    let mask = clusteredDepositMask(RD_DEPOSIT_SPLAT_RADIUS, dpGaussian)
    let seed = flatSeed()
    # 12 frames x 8 steps and 24 frames x 4 steps are the same 96 field steps.
    let reference = evolve(seed.a, seed.b, 12, RD_DEFAULT_DEPOSIT,
      mask = mask, substeps = 7, depositScale = 8.0 / 8.0)
    let halved = evolve(seed.a, seed.b, 24, RD_DEFAULT_DEPOSIT,
      mask = mask, substeps = 3, depositScale = 4.0 / 8.0)
    check (reference.aliveFraction > 0.0) == (halved.aliveFraction > 0.0)
    check abs(reference.maxB - halved.maxB) < 0.05
    check abs(reference.aliveFraction - halved.aliveFraction) < 0.05
    # The unscaled fold is the failure mode the scale removes, and it lives at
    # the ignition THRESHOLD, not in peak amplitude: without the scale a
    # SCATTERED deposit ignites at 3 substeps — the coherence requirement
    # dissolves — while the scaled fold keeps the scatter dead exactly as the
    # reference does.
    let scattered = evolve(seed.a, seed.b, 24, RD_DEPOSIT_MAX,
      mask = depositMask(), substeps = 3, depositScale = 1.0)
    let scatteredScaled = evolve(seed.a, seed.b, 24, RD_DEPOSIT_MAX,
      mask = depositMask(), substeps = 3, depositScale = 4.0 / 8.0)
    check scattered.aliveFraction > 0.0
    check scatteredScaled.aliveFraction == 0.0

  test "the Pearson defaults sit in the classic self-replicating-spots regime":
    # Pearson, J.E. (1993), "Complex Patterns in a Simple System", Science
    # 261(5118), 189-192 — the (F, k) parameter map's "spots that divide"
    # region sits roughly at F in [0.01, 0.04], k in [0.05, 0.065].
    check RD_DEFAULT_FEED > 0.01
    check RD_DEFAULT_FEED < 0.04
    check RD_DEFAULT_KILL > 0.05
    check RD_DEFAULT_KILL < 0.065

  test "particle-field coupling defaults sit inside their slider ranges":
    # RD_DEFAULT_DEPOSIT is the inhibitor concentration each particle folds
    # into its field cell per frame (field-deposit.wgsl) — a perturbation on an
    # already-ignited field, not the thing that ignites it.
    # RD_DEFAULT_FIELD_FORCE converts the sampled field gradient into a
    # velocity impulse (field-force.wgsl); zero decouples particles from the
    # field entirely. Both are live sliders, so both defaults must land
    # inside the range their slider offers.
    check RD_DEFAULT_DEPOSIT >= RD_DEPOSIT_MIN
    check RD_DEFAULT_DEPOSIT <= RD_DEPOSIT_MAX
    check RD_DEFAULT_FIELD_FORCE >= RD_FIELD_FORCE_MIN
    check RD_DEFAULT_FIELD_FORCE <= RD_FIELD_FORCE_MAX


# Two things set how big a spot looks. Gray-Scott's pattern wavelength scales as
# sqrt(diffusion) in CELLS, and a cell covers worldExtent/fieldExtent of the
# world. Their product is the only thing the eye sees, so either lever moves it
# and neither is meaningful alone.
#
# A 512x512 field over a 16:9 world also made cells 7.5 x 4.22 world units, so
# every spot — round in cells, because the Laplacian is isotropic there —
# rendered as an ellipse 1.78x wider than tall.

suite "The Field Draws A Small Pattern On Square Cells":
  const CONFIG_FILE = "src" / "config.nim"

  # The geometry before the shrink. The 10x claim is a comparison, so the
  # baseline has to be written down for the comparison to mean anything.
  const LEGACY_FIELD_W = 512.0
  const LEGACY_DIFFUSION_A = 1.0

  proc worldExtent(name: string): float =
    ## The world dimension config.nim declares, read from source. field_core is
    ## pure and cannot import config.nim (it carries FFI pragmas), so the link
    ## between the world's aspect and the field's is checked here instead of
    ## assumed. Precedent: tests/test_no_modes.nim reads real source the same way.
    result = -1.0
    if not fileExists(CONFIG_FILE): return
    for line in readFile(CONFIG_FILE).splitLines():
      if line.startsWith("let " & name & "*"):
        return parseFloat(line.rsplit('=', 1)[1].strip())

  test "the config source is where this suite says it is":
    # Without this the reads below return -1 from the wrong working directory
    # and every comparison against them passes vacuously.
    check fileExists(CONFIG_FILE)
    check worldExtent("WORLD_W") > 0.0
    check worldExtent("WORLD_H") > 0.0

  test "the field grid holds the aspect of the world it covers":
    # CONTRACT: field cells are square in world units. field-deposit.wgsl maps
    # the whole world rect onto FIELD_W x FIELD_H, so any aspect mismatch
    # stretches every pattern the field draws by exactly that mismatch.
    check abs(FIELD_W.float / FIELD_H.float - FIELD_WORLD_ASPECT) < 1e-9

  test "the world config still holds the aspect the field is sized against":
    # The other half of the link above. Changing WORLD_W or WORLD_H without
    # FIELD_WORLD_ASPECT would silently bring the stretch back.
    check abs(worldExtent("WORLD_W") / worldExtent("WORLD_H") -
      FIELD_WORLD_ASPECT) < 1e-9

  test "a field cell is square in world units":
    let cellW = worldExtent("WORLD_W") / FIELD_W.float
    let cellH = worldExtent("WORLD_H") / FIELD_H.float
    check abs(cellW - cellH) < 1e-9

  test "the pattern shrinks by exactly the factor the shrink knob names":
    # CONTRACT: FIELD_PATTERN_SHRINK is documented as a multiple of the 512-cell
    # square field this replaced, so it has to actually be that multiple. This
    # is what makes it a knob rather than a label — turn it and the pattern
    # follows, in both directions.
    let worldW = worldExtent("WORLD_W")
    let legacy = patternDiameterWorld(LEGACY_DIFFUSION_A, LEGACY_FIELD_W, worldW)
    let shipped = patternDiameterWorld(RD_DIFFUSION_A, FIELD_W.float, worldW)
    check abs(legacy / shipped - FIELD_PATTERN_SHRINK.float) < 1e-9

  test "the field force divides by the same knob the grid multiplies by":
    # The unit mismatch that makes this necessary lives on
    # RD_DEFAULT_FIELD_FORCE: the gradient is per CELL, the impulse lands in
    # WORLD units, so a finer grid strengthens a fixed number by exactly the
    # shrink. Deriving both from one constant is what keeps a particle's
    # response to the pattern fixed as the knob turns.
    check RD_DEFAULT_FIELD_FORCE * FIELD_PATTERN_SHRINK.float == 30.0
    check RD_FIELD_FORCE_MAX == RD_DEFAULT_FIELD_FORCE * 5.0
    check RD_SEED_BLOB_RADIUS / FIELD_PATTERN_SHRINK.float == 6.0

  test "the shrink comes from the cell size and not from the chemistry":
    # CONTRACT, and the reason the test above can be trusted: Gray-Scott's
    # dynamics live in CELL space, so every ignition threshold, regime
    # coordinate and collapse bound this file measures stays valid only while
    # the diffusion rates do. The whole shrink is the cell getting smaller.
    check RD_DIFFUSION_A == 1.0
    check RD_DIFFUSION_B == 0.5
    check patternDiameterCells(RD_DIFFUSION_A) ==
      RD_DIAMETER_CELLS_AT_UNIT_DIFFUSION

  test "the pattern stays wide enough for the grid to resolve it":
    # The floor the other lever would run into. MEASURED (128x128 torus,
    # Pearson defaults, 6000 steps): diameter tracks sqrt(diffusion) down to
    # scale 0.25 (4.47 cells) and holds at 0.16 (3.71), then collapses — at
    # 0.09 coverage falls from 0.22 to 0.03 and by 0.04 every surviving
    # component is a single cell.
    check patternDiameterCells(RD_DIFFUSION_A) >= RD_MIN_RESOLVED_DIAMETER_CELLS

  test "the inhibitor diffuses at half the activator's rate":
    # The ratio is what makes the system form Turing patterns rather than
    # smooth itself flat.
    check abs(RD_DIFFUSION_B / RD_DIFFUSION_A - 0.5) < 1e-12

  test "the activator channel sits on the explicit-Euler stability boundary":
    # The 9-point stencil carries center weight -1, so the worst-mode
    # amplification reaches the unit circle exactly at diffusionA * deltaT == 1.
    # The activator runs ON that line, which is why the field has no margin
    # against excess injection and why RD_DEPOSIT_CELL_MAX exists.
    check RD_DIFFUSION_A * RD_DELTA_T <= 1.0
    check RD_DIFFUSION_B * RD_DELTA_T < 1.0


suite "Reaction-Diffusion Seed Field":
  test "the seed hash places every blob center inside the field":
    # CONTRACT: field-seed.wgsl mirrors rdSeedBlobCenter with the same integer
    # hash. A center outside the texture would silently drop a blob on the GPU.
    for nonce in [0'u32, 1'u32, 7'u32, 4294967295'u32]:
      for blobIndex in 0 ..< RD_SEED_BLOB_COUNT:
        let center = rdSeedBlobCenter(blobIndex, nonce, FIELD_W, FIELD_H)
        check center.x >= 0
        check center.x < FIELD_W
        check center.y >= 0
        check center.y < FIELD_H

  test "the seed is deterministic in the nonce and moves the pattern when it changes":
    # CONTRACT: the same nonce must reproduce the same field (so the Nim
    # oracle and the WGSL mirror can be compared at all), and a different
    # nonce must produce a different one (so Reset gives a new pattern).
    let firstCell = rdSeedCell(10, 10, 3'u32, FIELD_W, FIELD_H,
      RD_SEED_BLOB_COUNT, RD_SEED_BLOB_RADIUS)
    let repeatCell = rdSeedCell(10, 10, 3'u32, FIELD_W, FIELD_H,
      RD_SEED_BLOB_COUNT, RD_SEED_BLOB_RADIUS)
    check firstCell == repeatCell
    var anyCenterMoved = false
    for blobIndex in 0 ..< RD_SEED_BLOB_COUNT:
      if rdSeedBlobCenter(blobIndex, 3'u32, FIELD_W, FIELD_H) !=
          rdSeedBlobCenter(blobIndex, 4'u32, FIELD_W, FIELD_H):
        anyCenterMoved = true
    check anyCenterMoved

  test "overlapping blobs never stack past the core values":
    # CONTRACT: rdSeedCell takes the max over blobs rather than the sum, so a
    # cell covered by several blobs saturates at the core rather than being
    # driven past it. Sampled over the whole shipped field at the shipped blob
    # count — the configuration most likely to overlap.
    var minActivator = 2.0
    var maxInhibitor = 0.0
    for y in countup(0, FIELD_H - 1, 4):
      for x in countup(0, FIELD_W - 1, 4):
        let cell = rdSeedCell(x, y, 1'u32, FIELD_W, FIELD_H,
          RD_SEED_BLOB_COUNT, RD_SEED_BLOB_RADIUS)
        if cell.activator < minActivator: minActivator = cell.activator
        if cell.inhibitor > maxInhibitor: maxInhibitor = cell.inhibitor
    check minActivator >= RD_SEED_CORE_ACTIVATOR - EPSILON
    check maxInhibitor <= RD_SEED_CORE_INHIBITOR + EPSILON

  test "a cell far from every blob keeps the untouched background state":
    # CONTRACT: outside the blobs the seed must leave the field at the
    # trivial (activator=1, inhibitor=0) background — the blobs are the only
    # perturbation, so a nonzero background would make the whole field react.
    var backgroundCells = 0
    for y in countup(0, FIELD_H - 1, 8):
      for x in countup(0, FIELD_W - 1, 8):
        let cell = rdSeedCell(x, y, 1'u32, FIELD_W, FIELD_H,
          RD_SEED_BLOB_COUNT, RD_SEED_BLOB_RADIUS)
        if cell.inhibitor == 0.0:
          inc backgroundCells
          check abs(cell.activator - 1.0) < EPSILON
    check backgroundCells > 0


# The defect this pins: RD_DEPOSIT_MAX bounds what one particle lays down per
# frame. The stability argument that cites it is about the value in a CELL, and
# those are the same number only while particles are spread out. Nothing bounds
# the sum, so any input that gathers a crowd into one place — a held mouse, most
# directly — drives a cell's inhibitor without limit, past the range explicit
# Euler integrates stably, into a grid-scale oscillation that fills the screen.
#
# resolveCellDeposit is the bound, applied where the unbounded external input
# enters the system. The dynamics themselves are left alone: they self-limit,
# and clamping their STATE would clip excursions a living pattern makes on its
# own. It is the injection that needs the ceiling, never the reaction.

suite "A Cell's Per-Frame Deposit Is Bounded":

  const UNBOUNDED_DEPOSIT = 1000.0
    ## What a crowd with no per-cell limit delivers: far past any ceiling.

  test "an ordinary deposit folds uncapped, at the frame scale":
    # The bound must be invisible in normal play. A spread-out population puts
    # a small fraction of one particle's deposit into any given cell, so the
    # ceiling sits orders of magnitude above what a cell normally receives.
    # The fold applies RD_DEPOSIT_FRAME_SCALE to everything that arrives —
    # deposit per FIELD STEP, not per frame, is the conserved quantity.
    check resolveCellDeposit(0.0, 0.001) == RD_DEPOSIT_FRAME_SCALE * 0.001
    check resolveCellDeposit(0.3, 0.01) == 0.3 + RD_DEPOSIT_FRAME_SCALE * 0.01
    # And at an explicit scale of one, the raw arithmetic is the identity the
    # pre-scale fold shipped.
    check resolveCellDeposit(0.0, 0.001, scale = 1.0) == 0.001
    check resolveCellDeposit(0.3, 0.01, scale = 1.0) == 0.31

  test "the ceiling exceeds what a dense legitimate crowd deposits":
    # Every particle in one cell at the deposit slider's ceiling still lands
    # under the bound until the crowd is far denser than play produces.
    let onePartcleAtMax = RD_DEPOSIT_MAX *
      depositSplatWeight(0.0, RD_DEPOSIT_SPLAT_RADIUS) /
      depositSplatNormalization(RD_DEPOSIT_SPLAT_RADIUS)
    check RD_DEPOSIT_CELL_MAX > onePartcleAtMax * 40.0

  test "an unbounded deposit saturates at the scaled ceiling":
    # The cap applies before the scale, so the effective per-frame injection
    # bound moves with the substep count and the measured stability margin
    # holds in field time.
    check resolveCellDeposit(0.0, 1000.0) ==
      RD_DEPOSIT_FRAME_SCALE * RD_DEPOSIT_CELL_MAX
    check resolveCellDeposit(0.2, 1000.0) ==
      0.2 + RD_DEPOSIT_FRAME_SCALE * RD_DEPOSIT_CELL_MAX

  test "the inhibitor never goes negative however many eroders stack on one cell":
    # RD_DEPOSIT_CELL_MAX bounds excess from above only (min() is a no-op on a
    # deposit already below it), so full-erosion secretion (SECRETION_MIN) has
    # no upper-bound counterpart holding the fold above zero. A crowd of
    # eroders sharing one empty cell (inhibitor 0.0) is the reachable case that
    # exposes it: each contributes its own-cell splat fraction of
    # RD_DEPOSIT_MAX at SECRETION_MIN.
    #
    # MEASURED (this construction, unfloored): 20 eroders reach B = -0.047,
    # 100 reach B = -0.23. The reaction term A*B^2 does not distinguish sign,
    # so a negative B erodes activator the same way a positive one would spend
    # it — erosion past zero acts on the field like the structure it was
    # supposed to remove.
    let onePartcleAtMax = RD_DEPOSIT_MAX * SECRETION_MIN *
      depositSplatWeight(0.0, RD_DEPOSIT_SPLAT_RADIUS) /
      depositSplatNormalization(RD_DEPOSIT_SPLAT_RADIUS)
    check resolveCellDeposit(0.0, onePartcleAtMax * 20.0) >= 0.0
    check resolveCellDeposit(0.0, onePartcleAtMax * 100.0) >= 0.0

  # A held mouse, as the field sees it: a block of cells receives an unbounded
  # deposit every frame, without end, while the substeps run. `bounded` selects
  # the shipped path against the raw addition, so the two tests below differ in
  # exactly the one thing under test.
  proc heldMouseWorst(bounded: bool, frames: int): float =
    const gridW = 32
    const gridH = 32
    var activator: array[gridH, array[gridW, float]]
    var inhibitor: array[gridH, array[gridW, float]]
    for y in 0 ..< gridH:
      for x in 0 ..< gridW:
        activator[y][x] = 1.0
        inhibitor[y][x] = 0.0
    for frame in 0 ..< frames:
      for dy in -3 .. 3:
        for dx in -3 .. 3:
          let yy = fieldWrap(gridH div 2 + dy, gridH)
          let xx = fieldWrap(gridW div 2 + dx, gridW)
          inhibitor[yy][xx] =
            if bounded: resolveCellDeposit(inhibitor[yy][xx], UNBOUNDED_DEPOSIT)
            else: inhibitor[yy][xx] + UNBOUNDED_DEPOSIT
      for substep in 0 ..< RD_STEPS_PER_FRAME:
        var nextA = activator
        var nextB = inhibitor
        for y in 0 ..< gridH:
          for x in 0 ..< gridW:
            let n = fieldWrap(y - 1, gridH)
            let s = fieldWrap(y + 1, gridH)
            let e = fieldWrap(x + 1, gridW)
            let w = fieldWrap(x - 1, gridW)
            let lapA = laplacian9(activator[y][x],
              activator[n][x], activator[s][x], activator[y][e], activator[y][w],
              activator[n][e], activator[n][w], activator[s][e], activator[s][w])
            let lapB = laplacian9(inhibitor[y][x],
              inhibitor[n][x], inhibitor[s][x], inhibitor[y][e], inhibitor[y][w],
              inhibitor[n][e], inhibitor[n][w], inhibitor[s][e], inhibitor[s][w])
            let stepped = grayScottStep(activator[y][x], inhibitor[y][x],
              lapA, lapB, RD_DIFFUSION_A, RD_DIFFUSION_B,
              RD_FEED_MIN, RD_KILL_MIN, RD_DELTA_T)
            nextA[y][x] = stepped.activator
            nextB[y][x] = stepped.inhibitor
        activator = nextA
        inhibitor = nextB
        for y in 0 ..< gridH:
          for x in 0 ..< gridW:
            result = max(result, max(abs(activator[y][x]), abs(inhibitor[y][x])))
        if result.classify in {fcNan, fcInf, fcNegInf} or result > 1.0e6:
          return result

  test "the ceiling holds the field finite under a mouse held forever":
    # The acceptance criterion, as the reported failure. Checked at the feed and
    # kill minimums, the corner that goes first because nothing there removes
    # what the deposit adds.
    let worst = heldMouseWorst(bounded = true, frames = 120)
    check worst.classify notin {fcNan, fcInf, fcNegInf}
    check worst < 2.0

  test "without the ceiling the same held mouse diverges":
    # What makes the test above non-vacuous: identical in every respect but the
    # bound, so a passing pair states that the bound is what holds the field
    # finite rather than the scenario being too gentle to break anything.
    let worst = heldMouseWorst(bounded = false, frames = 120)
    check worst > 1.0e6 or worst.classify in {fcNan, fcInf, fcNegInf}

suite "The Field Force Answers To The Frame":
  # field-force.wgsl reads a scale out of FieldParams and multiplies the
  # inhibitor gradient by it. Nothing in that chain carries dt, so Time Scale
  # never reached the field. Composing the frame into the scale on the CPU is
  # what gives it the same response the species force already has, and it keeps
  # FieldParams at the eight floats its binding declares.

  test "the scale is unchanged at the reference frame":
    check frameScaledFieldForce(RD_DEFAULT_FIELD_FORCE,
      frameFactor(FRAME_DT_REFERENCE)) == RD_DEFAULT_FIELD_FORCE

  test "the scale is proportional to the frame factor":
    for factor in [0.0, 0.25, 1.0, 2.5, 10.0]:
      check abs(frameScaledFieldForce(RD_DEFAULT_FIELD_FORCE, factor) -
        RD_DEFAULT_FIELD_FORCE * factor) < 1e-12

  test "a frame split into substeps delivers the same total":
    # The field force runs once per substep, so the substeps must sum to what
    # one whole frame delivers rather than multiplying it by the substep count.
    for substeps in [1, 2, 3]:
      let dt = 2.0 * FRAME_DT_REFERENCE
      check abs(frameScaledFieldForce(RD_DEFAULT_FIELD_FORCE,
          frameFactor(dt / substeps.float)) * substeps.float -
        frameScaledFieldForce(RD_DEFAULT_FIELD_FORCE, frameFactor(dt))) < 1e-12

  test "a silent field stays silent at every frame":
    for factor in [0.0, 1.0, 10.0]:
      check frameScaledFieldForce(0.0, factor) == 0.0

suite "Time Scale Sets How Fast The Pattern Runs":
  # The chemistry lives in field steps, not seconds, so the clock reaches it
  # only through how many steps a frame runs. Time Scale therefore buys pattern
  # speed by buying steps.

  test "the shipped Time Scale runs the shipped step count":
    check rdStepsForTimeScale(RD_REFERENCE_TIME_SCALE,
      RD_REFERENCE_TIME_SCALE) == RD_STEPS_PER_FRAME

  test "the step count is always odd":
    # The ping-pong chain closes on an even total of 1 + steps swaps, so an even
    # step count would leave the live field on the texture nothing reads.
    for hundredths in 1 .. 1000:
      let steps = rdStepsForTimeScale(hundredths.float / 100.0,
        RD_REFERENCE_TIME_SCALE)
      checkpoint("timeScale " & $(hundredths.float / 100.0))
      check steps mod 2 == 1

  test "the step count never falls below one":
    for timeScale in [0.0, 1e-9, 0.01, 0.1]:
      check rdStepsForTimeScale(timeScale, RD_REFERENCE_TIME_SCALE) >= 1

  test "the step count rises with the clock and never falls":
    var previous = 0
    for hundredths in 1 .. 1000:
      let steps = rdStepsForTimeScale(hundredths.float / 100.0,
        RD_REFERENCE_TIME_SCALE)
      check steps >= previous
      previous = steps

  test "the step count grows about linearly above the reference":
    # Cost is 1 + steps full-field passes, so this is the price of the speed.
    for multiple in [2.0, 4.0, 10.0]:
      let steps = rdStepsForTimeScale(multiple * RD_REFERENCE_TIME_SCALE,
        RD_REFERENCE_TIME_SCALE).float
      check abs(steps - multiple * RD_STEPS_PER_FRAME.float) <= 1.0

  test "the deposit rate per field step is held across the step count":
    # RD_DEPOSIT_STEP_REFERENCE is the step count every deposit constant in this
    # module was measured at. Buying pattern speed must not also change what it
    # takes to ignite, so the per-frame fold is renormalized by the step count.
    for steps in [1, 3, 7, 15, 71]:
      let perFieldStep = depositFrameScale(steps) / float(1 + steps)
      check abs(perFieldStep - 1.0 / float(RD_DEPOSIT_STEP_REFERENCE)) < 1e-12

  test "the shipped constant is the shipped step count's scale":
    check depositFrameScale(RD_STEPS_PER_FRAME) == RD_DEPOSIT_FRAME_SCALE
