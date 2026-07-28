# ==============================================================================
# PARTICLE GARDEN - FIELD CORE TESTS
# ==============================================================================
#
# Analytic tests for src/field_core.nim: the pure 9-point Laplacian stencil and
# Gray-Scott reaction-diffusion step that the rd-step.wgsl compute shader will
# mirror (roadmap S8). Every function is a plain scalar-in/scalar-out math
# function — the field grid itself lives only on the GPU (a storage texture),
# so these tests exercise one cell's update in isolation.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import std/math
import ../src/field_core
import ../src/config_ranges

const FIELD_CORE_TESTS_LOADED* = true

const EPSILON = 1e-9

# ==============================================================================
# THE SHIPPED-FRAME HARNESS
# ==============================================================================
#
# evolve() mirrors one reaction-diffusion frame in the order webgpu_compute
# encodes it: fieldResolve folds every particle's deposit into the inhibitor
# channel once, then RD_STEPS_PER_FRAME Gray-Scott substeps run. Anything that
# claims a seed does or does not ignite has to be measured through this order —
# a per-substep deposit would forcing the field ~7x harder than the real frame.
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
    ## shipped 512x512 field; 6 keeps the same rough coverage fraction on a
    ## 64x64 grid instead of flooding it.
  HARNESS_BLOB_RADIUS = 6.0
  HARNESS_DEPOSIT_COVERAGE = 16
    ## One cell in HARNESS_DEPOSIT_COVERAGE receives a particle deposit,
    ## approximating the ~6% cell coverage 16000 particles give the shipped
    ## 512x512 field.
  ALIVE_THRESHOLD = 0.15
    ## Inhibitor concentration above which a cell reads as pattern rather than
    ## background. Gray-Scott's background sits at ~0 inhibitor.

type
  HarnessField = array[HARNESS_GRID, array[HARNESS_GRID, float]]
  FieldStats = object
    ## Summary of the inhibitor channel after a run. std/mean is the structure
    ## metric: a flat field (dead or flooded) has a low ratio, real spots a
    ## high one.
    mean: float
    std: float
    maxB: float
    aliveFraction: float

func harnessWrap(i: int): int = (i + HARNESS_GRID) mod HARNESS_GRID

func harnessStencil(field: HarnessField, x, y: int): float =
  laplacian9(
    center = field[y][x],
    north = field[harnessWrap(y - 1)][x], south = field[harnessWrap(y + 1)][x],
    east = field[y][harnessWrap(x + 1)], west = field[y][harnessWrap(x - 1)],
    ne = field[harnessWrap(y - 1)][harnessWrap(x + 1)],
    nw = field[harnessWrap(y - 1)][harnessWrap(x - 1)],
    se = field[harnessWrap(y + 1)][harnessWrap(x + 1)],
    sw = field[harnessWrap(y + 1)][harnessWrap(x - 1)])

func depositMask(): HarnessField =
  ## Static particle coverage: the cells a stationary particle population
  ## deposits into every frame. Deterministic (index-derived, not random) so a
  ## failing threshold means the physics moved, never the mask.
  for y in 0 ..< HARNESS_GRID:
    for x in 0 ..< HARNESS_GRID:
      result[y][x] =
        if (y * HARNESS_GRID + x) mod HARNESS_DEPOSIT_COVERAGE == 0: 1.0
        else: 0.0

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

func evolve(seedA, seedB: HarnessField, frames: int, deposit: float,
    feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL): FieldStats =
  ## Run `frames` shipped frames from a seed and summarize the inhibitor
  ## channel. One deposit fold per frame, RD_STEPS_PER_FRAME substeps after it.
  var fieldA = seedA
  var fieldB = seedB
  let mask = depositMask()

  for _ in 0 ..< frames:
    for y in 0 ..< HARNESS_GRID:
      for x in 0 ..< HARNESS_GRID:
        fieldB[y][x] = fieldB[y][x] + mask[y][x] * deposit
    for _ in 0 ..< RD_STEPS_PER_FRAME:
      var nextA, nextB: HarnessField
      for y in 0 ..< HARNESS_GRID:
        for x in 0 ..< HARNESS_GRID:
          let (a, b) = grayScottStep(
            activator = fieldA[y][x], inhibitor = fieldB[y][x],
            laplacianA = harnessStencil(fieldA, x, y),
            laplacianB = harnessStencil(fieldB, x, y),
            diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
            feed = feed, kill = kill, deltaT = RD_DELTA_T)
          nextA[y][x] = a
          nextB[y][x] = b
      fieldA = nextA
      fieldB = nextB

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
    # CHARACTERIZES THE SHIPPED BUG, and must keep passing after the fix: the
    # render-pass clear createFieldResources performs leaves Gray-Scott's
    # trivial fixed point, and RD_DEFAULT_DEPOSIT splatted into isolated cells
    # is far too weak to leave it. Nothing but a spatially coherent seed
    # ignites this system, so nothing may be "simplified" back to the clear.
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


suite "Reaction-Diffusion Tuning Constants":
  test "field dimensions and tuning constants hold their documented values":
    check FIELD_W == 512
    check FIELD_H == 512
    check RD_DIFFUSION_A == 1.0
    check RD_DIFFUSION_B == 0.5
    check RD_DELTA_T == 1.0
    check RD_STEPS_PER_FRAME == 7
    check RD_PARTICLE_CEILING == 32000
    check RD_DEFAULT_FEED == 0.030
    check RD_DEFAULT_KILL == 0.062

  test "the substep count keeps the field ping-pong chain closed":
    # CONTRACT: fieldResolve is itself one ping-pong stage (it reads the trail
    # texture and writes the front), so a frame performs 1 + RD_STEPS_PER_FRAME
    # texture swaps. That total must be even for the live field to land back on
    # the texture the next frame's resolve reads and the renderer samples. An
    # even RD_STEPS_PER_FRAME silently discards the last substep every frame.
    check RD_STEPS_PER_FRAME mod 2 == 1

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
    # field entirely. Both are live sliders now, so both defaults must land
    # inside the range their slider offers.
    check RD_DEFAULT_DEPOSIT >= RD_DEPOSIT_MIN
    check RD_DEFAULT_DEPOSIT <= RD_DEPOSIT_MAX
    check RD_DEFAULT_FIELD_FORCE >= RD_FIELD_FORCE_MIN
    check RD_DEFAULT_FIELD_FORCE <= RD_FIELD_FORCE_MAX


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
