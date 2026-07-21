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
import ../src/field_core

const FIELD_CORE_TESTS_LOADED* = true

const EPSILON = 1e-9


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


suite "Gray-Scott Scheme Stability":
  test "200 steps on a seeded toroidal grid stay finite and bounded at the module constants":
    # CONTRACT: the explicit-Euler scheme with the module's stencil, diffusion
    # rates, and dt must be numerically stable — a seeded field must never
    # diverge. 24x24 toroidal grid, A=1 everywhere, B=0 except a central 4x4
    # block at 0.5, stepped 200 times with the module constants. Every cell
    # must stay finite and inside (-0.1, 1.5) — Gray-Scott concentrations
    # live in [0, 1]; the margin allows transient over/undershoot only.
    const GRID = 24
    var fieldA, fieldB: array[GRID, array[GRID, float]]
    for y in 0 ..< GRID:
      for x in 0 ..< GRID:
        fieldA[y][x] = 1.0
        fieldB[y][x] = 0.0
    for y in 10 ..< 14:
      for x in 10 ..< 14:
        fieldB[y][x] = 0.5

    proc wrap(i: int): int = (i + GRID) mod GRID
    proc stencil(field: array[GRID, array[GRID, float]], x, y: int): float =
      laplacian9(
        center = field[y][x],
        north = field[wrap(y - 1)][x], south = field[wrap(y + 1)][x],
        east = field[y][wrap(x + 1)], west = field[y][wrap(x - 1)],
        ne = field[wrap(y - 1)][wrap(x + 1)], nw = field[wrap(y - 1)][wrap(x - 1)],
        se = field[wrap(y + 1)][wrap(x + 1)], sw = field[wrap(y + 1)][wrap(x - 1)])

    for step in 0 ..< 200:
      var nextA, nextB: array[GRID, array[GRID, float]]
      for y in 0 ..< GRID:
        for x in 0 ..< GRID:
          let (a, b) = grayScottStep(
            activator = fieldA[y][x], inhibitor = fieldB[y][x],
            laplacianA = stencil(fieldA, x, y),
            laplacianB = stencil(fieldB, x, y),
            diffusionA = RD_DIFFUSION_A, diffusionB = RD_DIFFUSION_B,
            feed = RD_DEFAULT_FEED, kill = RD_DEFAULT_KILL,
            deltaT = RD_DELTA_T)
          nextA[y][x] = a
          nextB[y][x] = b
      fieldA = nextA
      fieldB = nextB

    var allBounded = true
    for y in 0 ..< GRID:
      for x in 0 ..< GRID:
        for value in [fieldA[y][x], fieldB[y][x]]:
          if value != value or value <= -0.1 or value >= 1.5:
            allBounded = false
    check allBounded


suite "Reaction-Diffusion Tuning Constants":
  test "field dimensions and tuning constants hold their documented values":
    check FIELD_W == 512
    check FIELD_H == 512
    check RD_DIFFUSION_A == 1.0
    check RD_DIFFUSION_B == 0.5
    check RD_DELTA_T == 1.0
    check RD_STEPS_PER_FRAME == 8
    check RD_PARTICLE_CEILING == 32000
    check RD_DEFAULT_FEED == 0.030
    check RD_DEFAULT_KILL == 0.062

  test "the Pearson defaults sit in the classic self-replicating-spots regime":
    # Pearson, J.E. (1993), "Complex Patterns in a Simple System", Science
    # 261(5118), 189-192 — the (F, k) parameter map's "spots that divide"
    # region sits roughly at F in [0.01, 0.04], k in [0.05, 0.065].
    check RD_DEFAULT_FEED > 0.01
    check RD_DEFAULT_FEED < 0.04
    check RD_DEFAULT_KILL > 0.05
    check RD_DEFAULT_KILL < 0.065

  test "particle-field coupling constants are positive":
    # RD_DEPOSIT_AMOUNT is the inhibitor concentration each particle folds into
    # its field cell per frame (field-deposit.wgsl); a non-positive value would
    # never seed the reaction from a uniform-zero inhibitor field. RD_FIELD_FORCE_SCALE
    # converts the sampled field gradient into a velocity impulse (field-force.wgsl);
    # zero would decouple particles from the field entirely. Both are the S8b GPU
    # coupling knobs; S10 calibrates their magnitudes.
    check RD_DEPOSIT_AMOUNT > 0.0
    check RD_FIELD_FORCE_SCALE > 0.0
