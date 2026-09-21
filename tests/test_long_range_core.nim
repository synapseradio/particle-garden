import std/unittest
import std/math
import std/random
import ../src/long_range_core
import ../src/memory_layout
from ../src/config_ranges import LR_GRID_SIZES, LONG_RANGE_REACH_MAX,
  CROWD_ONSET_RATIO, MATRIX_MAX_VALUE, FORCE_STRENGTH_MAX,
  INTERACTION_RADIUS_MIN, INTERACTION_RADIUS_MAX
from ../src/physics_core import FRAME_DT_REFERENCE
from ../src/balance_core import UnitConfig, longRangeFullEffectGain

const LONG_RANGE_CORE_TESTS_LOADED* = true

const F32_TOLERANCE = 1e-5
  ## The tolerance the shipped transform runs at. The oracle computes in f64, so
  ## it agrees with the naive transform far more tightly than this; the bound is
  ## written at f32 because that is what the WGSL mirror can reach, and every
  ## defect these tests exist to catch — a flipped twiddle sign, a stride read
  ## as its own transpose, a stage counted once too often — moves a bin by
  ## order one rather than by an ulp.

# ==============================================================================
# The independent oracle: a naive O(N^2) discrete transform.
#
# Written here and shipped nowhere. Every expectation about the fast transform
# below is taken from this sum, never from the fast transform itself, which is
# the whole reason the suite can see a defect in it.
# ==============================================================================

func naiveTransformLine(line: seq[LrComplex]; inverse: bool): seq[LrComplex] =
  let n = line.len
  let sign = if inverse: 1.0 else: -1.0
  result = newSeq[LrComplex](n)
  for k in 0 ..< n:
    var accRe = 0.0
    var accIm = 0.0
    for j in 0 ..< n:
      let ang = sign * 2.0 * PI * float(k) * float(j) / float(n)
      let c = cos(ang)
      let s = sin(ang)
      accRe += line[j].re * c - line[j].im * s
      accIm += line[j].re * s + line[j].im * c
    result[k] = LrComplex(re: accRe, im: accIm)

func maxDeviation(a, b: seq[LrComplex]): float =
  ## The largest single-bin departure between two spectra, so a failure reports
  ## how far off the worst bin is rather than merely that something differs.
  result = 0.0
  for i in 0 ..< a.len:
    result = max(result, abs(a[i].re - b[i].re))
    result = max(result, abs(a[i].im - b[i].im))

func worstBin(a, b: seq[LrComplex]): int =
  result = 0
  var worst = -1.0
  for i in 0 ..< a.len:
    let d = max(abs(a[i].re - b[i].re), abs(a[i].im - b[i].im))
    if d > worst:
      worst = d
      result = i

func rampLine(n: int): seq[LrComplex] =
  ## A line whose every bin is distinct and whose real and imaginary parts
  ## differ, so a transform that dropped the imaginary channel, or read one
  ## index for another, cannot pass by symmetry.
  result = newSeq[LrComplex](n)
  for j in 0 ..< n:
    result[j] = LrComplex(re: sin(0.7 * float(j)) + 0.25 * float(j),
                          im: cos(1.3 * float(j)) - 0.1 * float(j))

# The world the shipped ranges are written against, and the grid the tests
# solve on. 256 x 128 rather than the shipped 512 x 256 so a sweep of solves
# runs inside a suite; the cell ASPECT is what these tests turn on, and it is
# the same 1.125 at both sizes.
const
  TEST_WORLD_W = 3840.0
  TEST_WORLD_H = 2160.0
  TEST_GRID_W = 256
  TEST_GRID_H = 128
  TEST_REACH_MIN = 60.0
  TEST_REACH_MAX = 4000.0

func solveOneSpecies(density: seq[float]; gridW, gridH: int;
                     worldW, worldH, reach: float): seq[float] =
  ## The whole chain for one species, composed from the primitives the five
  ## shaders mirror: transform, per-bin kernel multiply, inverse transform.
  ## Written here rather than in the oracle because the oracle holds what one
  ## GPU invocation does, the way field_core holds one cell's Gray-Scott step.
  var grid = newSeq[LrComplex](gridW * gridH)
  for i in 0 ..< grid.len:
    grid[i] = LrComplex(re: density[i], im: 0.0)
  let spectrum = lrTransformGrid(grid, gridW, gridH, inverse = false)

  let softening = lrSofteningWorld(gridW, gridH, worldW, worldH)
  let invReachSq = lrInverseReachSq(reach)
  let invCells = lrInverseCells(gridW, gridH)

  var mixed = newSeq[LrComplex](gridW * gridH)
  for binY in 0 ..< gridH:
    for binX in 0 ..< gridW:
      let wave = lrWavenumber(binX, binY, gridW, gridH, worldW, worldH)
      let g = lrKernel(wave.kx, wave.ky, invReachSq, softening, invCells)
      let s = spectrum[binY * gridW + binX]
      mixed[binY * gridW + binX] = LrComplex(re: s.re * g, im: s.im * g)

  let back = lrTransformGrid(mixed, gridW, gridH, inverse = true)
  result = newSeq[float](gridW * gridH)
  for i in 0 ..< back.len:
    result[i] = back[i].re

func pointSourceAt(gridW, gridH, cellX, cellY: int): seq[float] =
  result = newSeq[float](gridW * gridH)
  for i in 0 ..< result.len:
    result[i] = 0.0
  result[cellY * gridW + cellX] = 1.0

suite "The Reference Transform Agrees With A Direct Transform":
  test "the forward transform of a known line equals the naive transform":
    for n in [2, 4, 8, 16, 32, 64]:
      let line = rampLine(n)
      let fast = lrTransformLine(line, inverse = false)
      let slow = naiveTransformLine(line, inverse = false)
      require fast.len == n
      let dev = maxDeviation(fast, slow)
      check dev < F32_TOLERANCE * float(n)
      if dev >= F32_TOLERANCE * float(n):
        checkpoint "length " & $n & ", worst bin " & $worstBin(fast, slow) &
          ", deviation " & $dev

  test "the inverse transform of a known line equals the naive inverse":
    for n in [2, 4, 8, 16, 32, 64]:
      let line = rampLine(n)
      let fast = lrTransformLine(line, inverse = true)
      let slow = naiveTransformLine(line, inverse = true)
      let dev = maxDeviation(fast, slow)
      check dev < F32_TOLERANCE * float(n)
      if dev >= F32_TOLERANCE * float(n):
        checkpoint "length " & $n & ", worst bin " & $worstBin(fast, slow) &
          ", deviation " & $dev

  test "forward then inverse returns the line it started from":
    # CONTRACT: neither direction normalizes. The 1/(W*H) the round trip owes
    # is folded into the kernel (design D6), so the test applies it here and a
    # transform that normalized twice, or once on the wrong side, fails.
    for n in [2, 4, 8, 16, 32, 64]:
      let line = rampLine(n)
      var back = lrTransformLine(lrTransformLine(line, inverse = false),
                                 inverse = true)
      for j in 0 ..< n:
        back[j] = LrComplex(re: back[j].re / float(n),
                            im: back[j].im / float(n))
      let dev = maxDeviation(back, line)
      check dev < F32_TOLERANCE * float(n)
      if dev >= F32_TOLERANCE * float(n):
        checkpoint "length " & $n & ", worst bin " & $worstBin(back, line) &
          ", deviation " & $dev

  test "a grid round trip on an anisotropic grid returns what it started from":
    # CONTRACT: the row pass then the column pass, then both inverted, is the
    # identity up to the 1/(W*H) the kernel carries. The grid is deliberately
    # not square: a transform that transposed its two axes, or ran the column
    # pass over the row's length, returns the wrong shape or the wrong values
    # on a rectangle and cannot be caught on a square.
    const gridW = 16
    const gridH = 8
    var grid = newSeq[LrComplex](gridW * gridH)
    for y in 0 ..< gridH:
      for x in 0 ..< gridW:
        grid[y * gridW + x] = LrComplex(re: sin(0.3 * float(x) + 0.9 * float(y)),
                                        im: cos(1.1 * float(x) - 0.4 * float(y)))
    var back = lrTransformGrid(lrTransformGrid(grid, gridW, gridH,
                                               inverse = false),
                               gridW, gridH, inverse = true)
    require back.len == gridW * gridH
    for i in 0 ..< back.len:
      back[i] = LrComplex(re: back[i].re / float(gridW * gridH),
                          im: back[i].im / float(gridW * gridH))
    let dev = maxDeviation(back, grid)
    check dev < F32_TOLERANCE
    if dev >= F32_TOLERANCE:
      checkpoint "worst cell " & $worstBin(back, grid) & ", deviation " & $dev

  test "a delta function transforms to one magnitude at every bin":
    # CONTRACT: a unit impulse at offset p has spectrum exp(-2*pi*i*k*p/N),
    # whose modulus is one at every bin. An impulse placed away from the origin
    # also carries a linear phase, so a stage that permuted its output shows up
    # as a magnitude that is no longer flat.
    for n in [4, 8, 16, 32, 64]:
      for offset in [0, 1, n div 3, n - 1]:
        var line = newSeq[LrComplex](n)
        for j in 0 ..< n:
          line[j] = LrComplex(re: 0.0, im: 0.0)
        line[offset] = LrComplex(re: 1.0, im: 0.0)
        let spectrum = lrTransformLine(line, inverse = false)
        for k in 0 ..< n:
          let modulus = sqrt(spectrum[k].re * spectrum[k].re +
                             spectrum[k].im * spectrum[k].im)
          check abs(modulus - 1.0) < F32_TOLERANCE
          if abs(modulus - 1.0) >= F32_TOLERANCE:
            checkpoint "length " & $n & ", impulse at " & $offset & ", bin " &
              $k & " has modulus " & $modulus

suite "The Kernel Is The Closed-Form Yukawa":
  test "the kernel equals the closed form at every bin":
    # CONTRACT: G(k) = exp(-k^2 sigma^2 / 2) / (k^2 + 1/lambda^2) / (W*H).
    # The expectation is that expression, written out here; the function under
    # test is never asked what it thinks the answer is.
    const gridW = 32
    const gridH = 16
    let softening = lrSofteningWorld(gridW, gridH, TEST_WORLD_W, TEST_WORLD_H)
    let invCells = lrInverseCells(gridW, gridH)
    for reach in [TEST_REACH_MIN, 600.0, TEST_REACH_MAX]:
      let invReachSq = lrInverseReachSq(reach)
      for binY in 0 ..< gridH:
        for binX in 0 ..< gridW:
          let wave = lrWavenumber(binX, binY, gridW, gridH,
                                  TEST_WORLD_W, TEST_WORLD_H)
          let kSq = wave.kx * wave.kx + wave.ky * wave.ky
          let expected =
            if kSq == 0.0: 0.0
            else: exp(-kSq * softening * softening / 2.0) /
                  (kSq + 1.0 / (reach * reach)) / float(gridW * gridH)
          let actual = lrKernel(wave.kx, wave.ky, invReachSq, softening,
                                invCells)
          check abs(actual - expected) <= 1e-12 * max(1.0, abs(expected))
          if abs(actual - expected) > 1e-12 * max(1.0, abs(expected)):
            checkpoint "reach " & $reach & ", bin (" & $binX & ", " & $binY &
              "): closed form " & $expected & ", kernel " & $actual

  test "the kernel is exactly zero at the zero wavenumber at every reach":
    # CONTRACT: the uniform-background convention. Not small, not clamped —
    # exactly zero, so a uniform addition to the world moves nothing at all.
    let softening = lrSofteningWorld(TEST_GRID_W, TEST_GRID_H,
                                     TEST_WORLD_W, TEST_WORLD_H)
    let invCells = lrInverseCells(TEST_GRID_W, TEST_GRID_H)
    for reach in [TEST_REACH_MIN, TEST_REACH_MAX]:
      let wave = lrWavenumber(0, 0, TEST_GRID_W, TEST_GRID_H,
                              TEST_WORLD_W, TEST_WORLD_H)
      check wave.kx == 0.0
      check wave.ky == 0.0
      let g = lrKernel(wave.kx, wave.ky, lrInverseReachSq(reach), softening,
                       invCells)
      check g == 0.0
      if g != 0.0:
        checkpoint "reach " & $reach & " leaves G(0) at " & $g

suite "Reach Sets The Decay Length":
  test "a point source's half-peak radius lengthens with every step of reach":
    # CONTRACT: reach is the screening length. The radius at which the
    # potential of a point source falls to half its peak must grow as reach
    # grows, over the whole shipped range — a kernel wired to the wrong power
    # of lambda, or one that ignores it, breaks the order.
    #
    # The crossing is interpolated between the two cells that bracket it, not
    # rounded to the nearer cell. MEASURED: the half-peak radius runs from 3.5
    # cells at the reach's floor to 9.6 at its ceiling, so the top of the range
    # moves it by a fifth of a cell per doubling — a whole-cell reading reports
    # the last two steps as a tie and hides the property this test is for.
    const source = 8
    const fraction = 0.5
    var radii: seq[float] = @[]
    var reaches: seq[float] = @[]
    var sweep: seq[float] = @[]
    var step2 = TEST_REACH_MIN
    while step2 < TEST_REACH_MAX:
      sweep.add(step2)
      step2 = step2 * 2.0
    sweep.add(TEST_REACH_MAX)
    for reach in sweep:
      let potential = solveOneSpecies(
        pointSourceAt(TEST_GRID_W, TEST_GRID_H, source, source),
        TEST_GRID_W, TEST_GRID_H, TEST_WORLD_W, TEST_WORLD_H, reach)
      let peak = potential[source * TEST_GRID_W + source]
      require peak > 0.0
      let cellW = TEST_WORLD_W / float(TEST_GRID_W)
      var radius = 0.0
      var previous = 1.0
      for step in 1 ..< TEST_GRID_W div 2:
        let value = potential[source * TEST_GRID_W + (source + step)] / peak
        if value < fraction:
          let across = (previous - fraction) / (previous - value)
          radius = (float(step - 1) + across) * cellW
          break
        previous = value
      require radius > 0.0
      radii.add(radius)
      reaches.add(reach)
    for i in 1 ..< radii.len:
      check radii[i] > radii[i - 1]
      if radii[i] <= radii[i - 1]:
        checkpoint "reach " & $reaches[i - 1] & " -> " & $reaches[i] &
          " moved the half-peak radius " & $radii[i - 1] & " -> " & $radii[i]

suite "The Potential Is Isotropic In World Units":
  test "equal world distances along x and along y carry equal potential":
    # CONTRACT: the wavenumber a bin stands for comes from the world's extent,
    # not from the bin's index. The grid's cells are 15 by 16.875 world units,
    # so a kernel indexed by bin number stretches the force along one axis by
    # exactly 1.125 with no other symptom. The sample offsets below are whole
    # numbers of cells on BOTH axes — 9 cells across is 8 cells down — so the
    # comparison needs no interpolation and reads the grid directly.
    #
    # RECORDED: with the wavenumber taken from the world's extent the two axes
    # disagree by 0.047%, 0.19% and 0.44% of the peak at the three distances
    # sampled — discretization of a point source, not anisotropy. Taking it
    # from the bin index instead moves the worst of those to 1.59%. The 1%
    # bound sits between the two.
    const source = 32
    const stepsX = 9
    const stepsY = 8
    let cellW = TEST_WORLD_W / float(TEST_GRID_W)
    let cellH = TEST_WORLD_H / float(TEST_GRID_H)
    require abs(float(stepsX) * cellW - float(stepsY) * cellH) < 1e-9
    let potential = solveOneSpecies(
      pointSourceAt(TEST_GRID_W, TEST_GRID_H, source, source),
      TEST_GRID_W, TEST_GRID_H, TEST_WORLD_W, TEST_WORLD_H, 600.0)
    let peak = potential[source * TEST_GRID_W + source]
    require peak > 0.0
    for multiple in 1 .. 3:
      let alongX = potential[source * TEST_GRID_W + (source + stepsX * multiple)]
      let alongY = potential[(source + stepsY * multiple) * TEST_GRID_W + source]
      let disagreement = abs(alongX - alongY) / peak
      check disagreement < 0.01
      if disagreement >= 0.01:
        checkpoint "at " & $(float(stepsX * multiple) * cellW) &
          " world units: along x " & $alongX & ", along y " & $alongY &
          ", disagreeing by " & $(disagreement * 100.0) & "% of the peak"

suite "Softening Attenuates The Cell Scale":
  test "the kernel at the grid's Nyquist wavenumber is a billionth of its value at the reach":
    # CONTRACT: the softening suppresses structure at and below the cell scale,
    # so the mesh carries no feature at its own grid's spacing.
    #
    # RECORDED, measured over the reaches swept below. At the shipped softening
    # of 1.5 cells the ratio runs 9.2e-14 at the reach's floor to 1.9e-17 at its
    # ceiling. Dropping the softening leaves 7.1e-3 to 1.6e-6; reading the 1.5
    # as WORLD UNITS where cells were meant leaves 6.5e-3 to 1.5e-6. The bound
    # sits at 1e-9, five orders above the worst shipped value and three orders
    # below the best defective one, so it separates all three arrangements at
    # every reach rather than only at the one it was read at.
    const attenuationBound = 1e-9
    let softening = lrSofteningWorld(TEST_GRID_W, TEST_GRID_H,
                                     TEST_WORLD_W, TEST_WORLD_H)
    let invCells = lrInverseCells(TEST_GRID_W, TEST_GRID_H)
    for reach in [TEST_REACH_MIN, 600.0, TEST_REACH_MAX]:
      let invReachSq = lrInverseReachSq(reach)
      # The reach's own wavenumber, 1/lambda, is the scale the coupling acts at.
      let atReach = lrKernel(1.0 / reach, 0.0, invReachSq, softening, invCells)
      # The corner of the spectrum: Nyquist on both axes at once.
      let nyquist = lrWavenumber(TEST_GRID_W div 2, TEST_GRID_H div 2,
                                 TEST_GRID_W, TEST_GRID_H,
                                 TEST_WORLD_W, TEST_WORLD_H)
      let atNyquist = lrKernel(nyquist.kx, nyquist.ky, invReachSq, softening,
                               invCells)
      require atReach > 0.0
      let ratio = abs(atNyquist) / atReach
      check ratio < attenuationBound
      if ratio >= attenuationBound:
        checkpoint "reach " & $reach & ": Nyquist carries " & $ratio &
          " of the kernel at the reach's wavenumber, bound " &
          $attenuationBound

suite "Charge Assignment Spreads One Particle Over Four Cells":
  test "the cloud-in-cell weights of any position sum to one":
    # CONTRACT: a particle deposits UNIT charge, spread bilinearly. The weights
    # are a partition of that one unit, which is what makes the accumulator
    # count particles and what makes its overflow bound MAX_PARTICLES exactly.
    # Swept across the cell rather than sampled at its centre, because a
    # normalization that held only on the lattice would pass a centre test.
    for stepX in 0 .. 40:
      for stepY in 0 .. 40:
        let px = TEST_WORLD_W * float(stepX) / 40.0 * 0.999
        let py = TEST_WORLD_H * float(stepY) / 40.0 * 0.999
        let assignment = lrAssign(px, py, TEST_GRID_W, TEST_GRID_H,
                                  TEST_WORLD_W, TEST_WORLD_H)
        var total = 0.0
        for w in assignment.weights:
          check w >= 0.0
          total += w
        check abs(total - 1.0) < 1e-12
        if abs(total - 1.0) >= 1e-12:
          checkpoint "at (" & $px & ", " & $py & ") the weights sum to " & $total

  test "a particle beside the world's edge deposits across the seam":
    # CONTRACT: the world is a torus, which is what a discrete spectral solve
    # assumes. A particle one unit from the left edge must reach the cells on
    # the right edge, and must do it with exactly the weights it would carry
    # anywhere else in the world.
    const nearEdge = 1.0
    let cellW = TEST_WORLD_W / float(TEST_GRID_W)
    let midWorld = nearEdge + cellW * float(TEST_GRID_W div 2)
    let atEdge = lrAssign(nearEdge, 500.0, TEST_GRID_W, TEST_GRID_H,
                          TEST_WORLD_W, TEST_WORLD_H)
    let inland = lrAssign(midWorld, 500.0, TEST_GRID_W, TEST_GRID_H,
                          TEST_WORLD_W, TEST_WORLD_H)
    # The same offset inside a cell, so the two carry the same weights.
    for i in 0 .. 3:
      check abs(atEdge.weights[i] - inland.weights[i]) < 1e-12
      if abs(atEdge.weights[i] - inland.weights[i]) >= 1e-12:
        checkpoint "weight " & $i & " at the seam is " & $atEdge.weights[i] &
          " against " & $inland.weights[i] & " inland"
    # And the seam is actually crossed: one of the four cells sits in the last
    # column, which is only reachable by wrapping.
    var wrapped = false
    for cell in atEdge.cells:
      if cell mod TEST_GRID_W == TEST_GRID_W - 1:
        wrapped = true
    check wrapped
    if not wrapped:
      checkpoint "a particle " & $nearEdge & " units from the left edge " &
        "touched cells " & $atEdge.cells & " and none of them wrapped"

  test "every cell index the assignment names lies inside the live grid":
    for stepX in 0 .. 30:
      for stepY in 0 .. 30:
        let px = TEST_WORLD_W * float(stepX) / 30.0
        let py = TEST_WORLD_H * float(stepY) / 30.0
        let assignment = lrAssign(px, py, TEST_GRID_W, TEST_GRID_H,
                                  TEST_WORLD_W, TEST_WORLD_H)
        for cell in assignment.cells:
          check cell >= 0 and cell < TEST_GRID_W * TEST_GRID_H
          if cell < 0 or cell >= TEST_GRID_W * TEST_GRID_H:
            checkpoint "at (" & $px & ", " & $py & ") the assignment names " &
              "cell " & $cell & ", outside a grid of " &
              $(TEST_GRID_W * TEST_GRID_H)

suite "The Full Particle Budget Encodes Without Saturating":
  test "the whole particle budget in one cell decodes to the particle count":
    # CONTRACT: the worst case is exactly MAX_PARTICLES, because a particle
    # deposits unit charge and nothing bounds how many occupy one cell. An i32
    # past its maximum wraps NEGATIVE, which the kernel reads as a hole where
    # the world holds its densest clump.
    let encoded = lrEncodeDensity(float(MAX_PARTICLES))
    check encoded > 0
    check encoded <= high(int32)
    check abs(lrDecodeDensity(encoded) - float(MAX_PARTICLES)) < 1.0
    if abs(lrDecodeDensity(encoded) - float(MAX_PARTICLES)) >= 1.0:
      checkpoint $MAX_PARTICLES & " particles encode to " & $encoded &
        " and decode to " & $lrDecodeDensity(encoded)

  test "the density scale is a power of two":
    # CONTRACT: a power of two makes the encode and decode exact shifts of the
    # mantissa, so the round trip above loses nothing the scale did not intend.
    check lrIsPowerOfTwo(LR_DENSITY_SCALE)

  test "the density scale is not the velocity deltas' scale":
    # CONTRACT: sharing 65536 would cap the accumulator at 32768 particles in a
    # cell, which the particle ceiling passes. This is the one test that fails
    # if a later change collapses the two scales onto one constant.
    check LR_DENSITY_SCALE * MAX_PARTICLES < high(int32).int
    check 65536 * MAX_PARTICLES > high(int32).int

  test "a particle's largest assignment weight clears the accumulator's quantum":
    # CONTRACT: no particle vanishes from the density. The four bilinear
    # weights are a partition of one unit, so the largest of them is never
    # below a quarter wherever the particle sits, and a quarter of the scale is
    # 256 quanta.
    #
    # DEVIATION from the task's wording, which asks that the SMALLEST non-zero
    # weight clear the quantum. That does not hold and cannot: a particle
    # approaching a cell corner drives three of its four weights continuously
    # to zero, so the smallest non-zero weight has no floor above zero. What
    # carries the intent — that quantization never loses a particle — is the
    # bound on the LARGEST weight, asserted here, plus the resolution check
    # below.
    for stepX in 0 .. 40:
      for stepY in 0 .. 40:
        let px = TEST_WORLD_W * float(stepX) / 40.0 * 0.999
        let py = TEST_WORLD_H * float(stepY) / 40.0 * 0.999
        let assignment = lrAssign(px, py, TEST_GRID_W, TEST_GRID_H,
                                  TEST_WORLD_W, TEST_WORLD_H)
        var largest = 0.0
        for w in assignment.weights:
          largest = max(largest, w)
        check largest >= 0.25 - 1e-12
        check lrEncodeDensity(largest) >= int32(LR_DENSITY_SCALE div 4)
        if largest < 0.25 - 1e-12:
          checkpoint "at (" & $px & ", " & $py & ") the largest of the four " &
            "weights is " & $largest

  test "the accumulator resolves one part in the density scale":
    # CONTRACT: a weight at the scale's own quantum still encodes as one, so
    # the resolution the scale claims is the resolution it delivers.
    check lrEncodeDensity(1.0 / float(LR_DENSITY_SCALE)) == 1'i32
    check lrDecodeDensity(1'i32) == 1.0 / float(LR_DENSITY_SCALE)

suite "The Allocation Ceiling Is A Power Of Two":
  test "both ceiling dimensions are powers of two":
    # CONTRACT: the radix-2 transform cannot run on a line that is not a power
    # of two, and the ceiling is what every declared live size is measured
    # against.
    check lrIsPowerOfTwo(LR_GRID_MAX_W)
    check lrIsPowerOfTwo(LR_GRID_MAX_H)

  test "the ceiling's longest line fits the workgroup storage WebGPU guarantees":
    # CONTRACT: one line is transformed inside one workgroup, in an array of 2N
    # complex values. The bound is WebGPU's GUARANTEED workgroup storage, not
    # this adapter's, which grants twice it — a ceiling sized against the
    # adapter would compile here and fail on a device at the default limit.
    #
    # This is not a restatement of LR_FFT_MAX_LINE's definition: at the shipped
    # 512 the array costs 8192 of the 16384 bytes, and raising either ceiling
    # dimension to 2048 fails this line.
    check LR_FFT_MAX_LINE == max(LR_GRID_MAX_W, LR_GRID_MAX_H)
    check 2 * LR_FFT_MAX_LINE * 8 <= LR_WORKGROUP_STORAGE_GUARANTEE
    # And the workgroup covers its line either one butterfly per thread or by
    # looping, never by leaving butterflies undone.
    check LR_FFT_WORKGROUP_SIZE > 0
    check LR_FFT_MAX_LINE div 2 mod LR_FFT_WORKGROUP_SIZE == 0 or
      LR_FFT_MAX_LINE div 2 < LR_FFT_WORKGROUP_SIZE

# ==============================================================================
# The multi-species chain, composed from the oracle's per-invocation pieces.
# ==============================================================================

const
  MIX_GRID_W = 32
  MIX_GRID_H = 16

func solveSpecies(densities: seq[seq[float]]; matrix: seq[float];
                  stride, speciesCount, gridW, gridH: int;
                  worldW, worldH, reach: float): seq[seq[float]] =
  ## One potential per RECEIVING species: deposit, transform, mix in k-space,
  ## transform back. The mix happens after the kernel is applied to the
  ## matrix-weighted sum, never per species before it.
  var spectra: seq[seq[LrComplex]] = @[]
  for s in 0 ..< speciesCount:
    var grid = newSeq[LrComplex](gridW * gridH)
    for i in 0 ..< grid.len:
      grid[i] = LrComplex(re: densities[s][i], im: 0.0)
    spectra.add(lrTransformGrid(grid, gridW, gridH, inverse = false))

  let softening = lrSofteningWorld(gridW, gridH, worldW, worldH)
  let invReachSq = lrInverseReachSq(reach)
  let invCells = lrInverseCells(gridW, gridH)

  var mixed: seq[seq[LrComplex]] = @[]
  for r in 0 ..< speciesCount:
    mixed.add(newSeq[LrComplex](gridW * gridH))
  var atBin = newSeq[LrComplex](speciesCount)

  for binY in 0 ..< gridH:
    for binX in 0 ..< gridW:
      let idx = binY * gridW + binX
      let wave = lrWavenumber(binX, binY, gridW, gridH, worldW, worldH)
      let g = lrKernel(wave.kx, wave.ky, invReachSq, softening, invCells)
      for s in 0 ..< speciesCount:
        atBin[s] = spectra[s][idx]
      for r in 0 ..< speciesCount:
        mixed[r][idx] = lrMixBin(atBin, matrix, stride, r, speciesCount, g)

  result = @[]
  for r in 0 ..< speciesCount:
    let back = lrTransformGrid(mixed[r], gridW, gridH, inverse = true)
    var potential = newSeq[float](gridW * gridH)
    for i in 0 ..< back.len:
      potential[i] = back[i].re
    result.add(potential)

func emptyGrid(gridW, gridH: int): seq[float] =
  result = newSeq[float](gridW * gridH)
  for i in 0 ..< result.len:
    result[i] = 0.0

func depositPopulation(positions: seq[tuple[x, y: float; species: int]];
                       speciesCount, gridW, gridH: int;
                       worldW, worldH: float): seq[seq[float]] =
  ## The deposit pass, at oracle scale: every particle's unit charge spread
  ## over the four cells its assignment names.
  result = @[]
  for s in 0 ..< speciesCount:
    result.add(emptyGrid(gridW, gridH))
  for p in positions:
    let assignment = lrAssign(p.x, p.y, gridW, gridH, worldW, worldH)
    for i in 0 .. 3:
      result[p.species][assignment.cells[i]] += assignment.weights[i]

func testPopulation(speciesCount: int): seq[tuple[x, y: float; species: int]] =
  ## A fixed, clumped, deliberately asymmetric arrangement. Clumped because a
  ## uniform one would make the momentum sum zero for a reason that has
  ## nothing to do with the matrix.
  result = @[]
  var seed = 12345'u32
  for i in 0 ..< 240:
    seed = seed * 1664525'u32 + 1013904223'u32
    let a = float(seed shr 8 and 0xFFFF'u32) / 65536.0
    seed = seed * 1664525'u32 + 1013904223'u32
    let b = float(seed shr 8 and 0xFFFF'u32) / 65536.0
    let clump = i mod 3
    let cx = [0.2, 0.75, 0.5][clump] * TEST_WORLD_W
    let cy = [0.3, 0.6, 0.8][clump] * TEST_WORLD_H
    result.add((x: cx + (a - 0.5) * 300.0,
                y: cy + (b - 0.5) * 300.0,
                species: i mod speciesCount))

const
  SYMMETRIC_MATRIX = @[0.20, -0.10, 0.05,
                       -0.10, 0.30, 0.15,
                       0.05, 0.15, -0.20]
  ASYMMETRIC_MATRIX = @[0.20, -0.10, 0.05,
                        0.25, 0.30, 0.15,
                        0.05, 0.15, -0.20]

suite "The Solve Is Linear In The Source Densities":
  test "the potential of two species together is the sum of their separate solves":
    # CONTRACT: the kernel is applied to the matrix-weighted SUM of the source
    # spectra, and the transform is linear, so superposition holds exactly.
    # A kernel applied per species BEFORE the mix, or a matrix row read as a
    # column, breaks it.
    const speciesCount = 3
    let population = testPopulation(speciesCount)
    let densities = depositPopulation(population, speciesCount,
                                      MIX_GRID_W, MIX_GRID_H,
                                      TEST_WORLD_W, TEST_WORLD_H)
    let together = solveSpecies(densities, SYMMETRIC_MATRIX, speciesCount,
                                speciesCount, MIX_GRID_W, MIX_GRID_H,
                                TEST_WORLD_W, TEST_WORLD_H, 600.0)

    # The same solve run once per source species, with the other sources empty.
    var apart: seq[seq[float]] = @[]
    for r in 0 ..< speciesCount:
      apart.add(emptyGrid(MIX_GRID_W, MIX_GRID_H))
    for source in 0 ..< speciesCount:
      var isolated: seq[seq[float]] = @[]
      for s in 0 ..< speciesCount:
        isolated.add(if s == source: densities[s]
                     else: emptyGrid(MIX_GRID_W, MIX_GRID_H))
      let one = solveSpecies(isolated, SYMMETRIC_MATRIX, speciesCount,
                             speciesCount, MIX_GRID_W, MIX_GRID_H,
                             TEST_WORLD_W, TEST_WORLD_H, 600.0)
      for r in 0 ..< speciesCount:
        for i in 0 ..< apart[r].len:
          apart[r][i] += one[r][i]

    var scale = 0.0
    for r in 0 ..< speciesCount:
      for value in together[r]:
        scale = max(scale, abs(value))
    require scale > 0.0
    for r in 0 ..< speciesCount:
      for i in 0 ..< together[r].len:
        let gap = abs(together[r][i] - apart[r][i]) / scale
        check gap < 1e-10
        if gap >= 1e-10:
          checkpoint "receiver " & $r & ", cell " & $i & ": together " &
            $together[r][i] & ", summed apart " & $apart[r][i]

  test "a receiving species reads its own row of the matrix":
    # CONTRACT: A[r][s] is what species r feels toward species s, the same
    # convention forces.wgsl reads (thisSpecies * MAX_SPECIES + otherSpecies).
    # Reading the column instead would swap who is pulled toward whom, which a
    # symmetric matrix could never show.
    const speciesCount = 2
    const stride = 2
    # Species 1 is clumped; species 0 is empty. Row 0 gives species 1 a
    # positive entry, row 1 gives species 0 nothing.
    let matrix = @[0.0, 0.40,
                   0.0, 0.0]
    var densities: seq[seq[float]] = @[emptyGrid(MIX_GRID_W, MIX_GRID_H),
                                       emptyGrid(MIX_GRID_W, MIX_GRID_H)]
    let clumpX = TEST_WORLD_W * 0.5
    let clumpY = TEST_WORLD_H * 0.5
    let assignment = lrAssign(clumpX, clumpY, MIX_GRID_W, MIX_GRID_H,
                              TEST_WORLD_W, TEST_WORLD_H)
    for i in 0 .. 3:
      densities[1][assignment.cells[i]] += assignment.weights[i] * 1000.0
    let potentials = solveSpecies(densities, matrix, stride, speciesCount,
                                  MIX_GRID_W, MIX_GRID_H,
                                  TEST_WORLD_W, TEST_WORLD_H, 1200.0)

    # Species 0, placed to the left of the clump, is pulled toward it: the
    # gradient it reads points in +x.
    let probeX = clumpX - TEST_WORLD_W * 0.15
    let gradient = lrGradient(potentials[0], MIX_GRID_W, MIX_GRID_H,
                              TEST_WORLD_W, TEST_WORLD_H, probeX, clumpY)
    check gradient.gx > 0.0
    if gradient.gx <= 0.0:
      checkpoint "a positive matrix entry left species 0 with gradient " &
        $gradient.gx & " in x, which points away from the clump"
    # Species 1 has no entry for species 0 and feels nothing at all.
    let none = lrGradient(potentials[1], MIX_GRID_W, MIX_GRID_H,
                          TEST_WORLD_W, TEST_WORLD_H, probeX, clumpY)
    check abs(none.gx) < 1e-12
    check abs(none.gy) < 1e-12

suite "A Uniform World Pushes Nothing":
  test "a constant density leaves every gradient zero at every reach":
    # CONTRACT: G(0) = 0, so the force answers density CONTRAST and not
    # absolute density. A uniform world has only the zero-wavenumber bin, and
    # the kernel zeroes it, so the potential is identically zero.
    const speciesCount = 3
    var densities: seq[seq[float]] = @[]
    for s in 0 ..< speciesCount:
      var uniform = emptyGrid(MIX_GRID_W, MIX_GRID_H)
      for i in 0 ..< uniform.len:
        uniform[i] = 7.0 + float(s)
      densities.add(uniform)
    for reach in [TEST_REACH_MIN, 600.0, TEST_REACH_MAX]:
      let potentials = solveSpecies(densities, ASYMMETRIC_MATRIX, speciesCount,
                                    speciesCount, MIX_GRID_W, MIX_GRID_H,
                                    TEST_WORLD_W, TEST_WORLD_H, reach)
      for r in 0 ..< speciesCount:
        for stepX in 0 .. 7:
          for stepY in 0 .. 7:
            let px = TEST_WORLD_W * float(stepX) / 8.0
            let py = TEST_WORLD_H * float(stepY) / 8.0
            let gradient = lrGradient(potentials[r], MIX_GRID_W, MIX_GRID_H,
                                      TEST_WORLD_W, TEST_WORLD_H, px, py)
            check abs(gradient.gx) < 1e-12
            check abs(gradient.gy) < 1e-12
            if abs(gradient.gx) >= 1e-12 or abs(gradient.gy) >= 1e-12:
              checkpoint "reach " & $reach & ", receiver " & $r & " at (" &
                $px & ", " & $py & ") reads gradient (" & $gradient.gx & ", " &
                $gradient.gy & ") from a uniform world"

  test "adding a uniform population changes no original particle's impulse":
    # CONTRACT: the same property from the other side. A uniform addition moves
    # only the zero-wavenumber bin, which the kernel discards.
    const speciesCount = 3
    let population = testPopulation(speciesCount)
    let densities = depositPopulation(population, speciesCount,
                                      MIX_GRID_W, MIX_GRID_H,
                                      TEST_WORLD_W, TEST_WORLD_H)
    var thickened: seq[seq[float]] = @[]
    for s in 0 ..< speciesCount:
      var grid = densities[s]
      for i in 0 ..< grid.len:
        grid[i] += 13.0
      thickened.add(grid)

    let before = solveSpecies(densities, ASYMMETRIC_MATRIX, speciesCount,
                              speciesCount, MIX_GRID_W, MIX_GRID_H,
                              TEST_WORLD_W, TEST_WORLD_H, 600.0)
    let after = solveSpecies(thickened, ASYMMETRIC_MATRIX, speciesCount,
                             speciesCount, MIX_GRID_W, MIX_GRID_H,
                             TEST_WORLD_W, TEST_WORLD_H, 600.0)
    var scale = 0.0
    for p in population:
      let g = lrGradient(before[p.species], MIX_GRID_W, MIX_GRID_H,
                         TEST_WORLD_W, TEST_WORLD_H, p.x, p.y)
      scale = max(scale, max(abs(g.gx), abs(g.gy)))
    require scale > 0.0
    for p in population:
      let was = lrGradient(before[p.species], MIX_GRID_W, MIX_GRID_H,
                           TEST_WORLD_W, TEST_WORLD_H, p.x, p.y)
      let now = lrGradient(after[p.species], MIX_GRID_W, MIX_GRID_H,
                           TEST_WORLD_W, TEST_WORLD_H, p.x, p.y)
      check abs(now.gx - was.gx) / scale < 1e-10
      check abs(now.gy - was.gy) / scale < 1e-10

suite "Momentum Is Conserved Only Under A Symmetric Matrix":
  test "the impulses sum to zero under a symmetric matrix and need not under an asymmetric one":
    # CONTRACT: no single potential both species read exists when the matrix is
    # asymmetric, so the long-range term does not conserve momentum. Both
    # halves are asserted so a later change cannot quietly restore a symmetry
    # the physics never had — symmetrizing the matrix in k-space would make the
    # second half fail.
    #
    # The cancellation under a symmetric matrix is EXACT, and the arrangement
    # is what makes it so: the deposit and the force sampler share one set of
    # bilinear weights, and the central difference is taken exactly one cell
    # apart, so the sampled gradient sums over the population to the grid's own
    # central difference contracted with the deposited density.
    const speciesCount = 3
    let population = testPopulation(speciesCount)
    let densities = depositPopulation(population, speciesCount,
                                      MIX_GRID_W, MIX_GRID_H,
                                      TEST_WORLD_W, TEST_WORLD_H)

    var totals: array[2, tuple[sx, sy, magnitude: float]]
    for which, matrix in [SYMMETRIC_MATRIX, ASYMMETRIC_MATRIX].pairs:
      let potentials = solveSpecies(densities, matrix, speciesCount,
                                    speciesCount, MIX_GRID_W, MIX_GRID_H,
                                    TEST_WORLD_W, TEST_WORLD_H, 600.0)
      var sumX = 0.0
      var sumY = 0.0
      var magnitude = 0.0
      for p in population:
        let g = lrGradient(potentials[p.species], MIX_GRID_W, MIX_GRID_H,
                           TEST_WORLD_W, TEST_WORLD_H, p.x, p.y)
        sumX += g.gx
        sumY += g.gy
        magnitude += abs(g.gx) + abs(g.gy)
      totals[which] = (sx: sumX, sy: sumY, magnitude: magnitude)

    require totals[0].magnitude > 0.0
    let symmetricDrift =
      (abs(totals[0].sx) + abs(totals[0].sy)) / totals[0].magnitude
    check symmetricDrift < 1e-12
    if symmetricDrift >= 1e-12:
      checkpoint "a symmetric matrix left a net impulse of (" &
        $totals[0].sx & ", " & $totals[0].sy & ") against a total magnitude " &
        $totals[0].magnitude

    require totals[1].magnitude > 0.0
    let asymmetricDrift =
      (abs(totals[1].sx) + abs(totals[1].sy)) / totals[1].magnitude
    check asymmetricDrift > 1e-6
    if asymmetricDrift <= 1e-6:
      checkpoint "an asymmetric matrix left a net impulse of (" &
        $totals[1].sx & ", " & $totals[1].sy & "), relatively " &
        $asymmetricDrift & " — the world is not supposed to be still here"

# ==============================================================================
# The pull in the pair unit: one disc clump placed by each gate seed.
# ==============================================================================

const
  GATE_SEEDS = [42, 7, 1001]
  CLUMP_PARTICLES = 1000
  CLUMP_RADIUS = 40.0

func designPairUnit(radius: float): float =
  ## U(R) = u0 R^2 (a + R) / a^2, a = sqrt(A_world / (pi x_on)), written from
  ## the design so the suites never ask the oracle what the unit is.
  let a = sqrt(TEST_WORLD_W * TEST_WORLD_H / (PI * CROWD_ONSET_RATIO))
  FRAME_DT_REFERENCE * radius * radius * (a + radius) / (a * a)

proc seededClump(seed: int): tuple[cx, cy: float; density: seq[seq[float]]] =
  ## A sunflower disc of CLUMP_PARTICLES at a centre the seed draws, deposited
  ## on every declared grid size, in LR_GRID_SIZES order.
  var rng = initRand(seed)
  result.cx = rng.rand(TEST_WORLD_W)
  result.cy = rng.rand(TEST_WORLD_H)
  for size in LR_GRID_SIZES:
    var grid = emptyGrid(size.w, size.h)
    for i in 0 ..< CLUMP_PARTICLES:
      let r = CLUMP_RADIUS * sqrt((i.float + 0.5) / CLUMP_PARTICLES.float)
      let theta = i.float * 2.399963229728653
      let assignment = lrAssign(result.cx + r * cos(theta),
        result.cy + r * sin(theta), size.w, size.h, TEST_WORLD_W, TEST_WORLD_H)
      for k in 0 .. 3:
        grid[assignment.cells[k]] += assignment.weights[k]
    result.density.add grid

func impulseAt(potential: seq[float]; size: tuple[w, h: int];
               radius, px, py: float): float =
  ## The impulse lr-force.wgsl hands a particle at strength 1 under the
  ## largest self-attraction, from the scale written to LR_FORCE_SCALE.
  let g = lrGradient(potential, size.w, size.h, TEST_WORLD_W, TEST_WORLD_H,
    px, py)
  lrForceScale(1.0, radius, CROWD_ONSET_RATIO, size.w, size.h,
    TEST_WORLD_W, TEST_WORLD_H) * MATRIX_MAX_VALUE * hypot(g.gx, g.gy)

suite "The Pull Does Not Depend On Mesh Size":
  test "every declared mesh size hands the same impulse 240 and 600 from a clump's centre":
    # MEASURED: the static solve at reach 600, seeds 42/7/1001, sampled along
    # +x and +y. The gap reads 0.153-0.261% at 240 (mean 0.212%) and
    # 0.098-0.126% at 600 (mean 0.106%); each bound is the mean plus the
    # largest reading's distance from it. Closer in the gap grows (3.19x the
    # cell-area ratio at 60), since the clump spans few cells.
    const radius = 50.0
    const reach = 600.0
    const samples = [(offset: 240.0, bound: 0.00271),
                     (offset: 600.0, bound: 0.00126)]
    for seed in GATE_SEEDS:
      let clump = seededClump(seed)
      var potentials: seq[seq[float]]
      for s, size in LR_GRID_SIZES:
        potentials.add solveOneSpecies(clump.density[s], size.w, size.h,
          TEST_WORLD_W, TEST_WORLD_H, reach)
      for sample in samples:
        for (dx, dy) in [(1.0, 0.0), (0.0, 1.0)]:
          let px = clump.cx + dx * sample.offset
          let py = clump.cy + dy * sample.offset
          let reference = impulseAt(potentials[0], LR_GRID_SIZES[0], radius,
            px, py)
          require reference > 0.0
          for s in 1 ..< LR_GRID_SIZES.len:
            let other = impulseAt(potentials[s], LR_GRID_SIZES[s], radius,
              px, py)
            let gap = abs(reference / other - 1.0)
            check gap <= sample.bound
            if gap > sample.bound:
              checkpoint "seed " & $seed & ", " & $sample.offset &
                " along (" & $dx & ", " & $dy & "): " & $LR_GRID_SIZES[0] &
                " hands " & $reference & ", " & $LR_GRID_SIZES[s] & " hands " &
                $other & ", a gap of " & $(gap * 100.0) & "% against " &
                $(sample.bound * 100.0) & "%"

suite "The Pull Is The Pair Unit Spread By The Green's Function":
  test "at the longest reach the impulse 240 from a clump is A U(R) M / (2 pi r) at every radius":
    # MEASURED: the static solve at reach 4000, 240 from the centre, seeds
    # 42/7/1001, +x and +y, both mesh sizes. The miss reads 0.60-0.72% along
    # +x and 4.13-4.31% along +y (mean 2.449%); the bound is the mean plus the
    # largest reading's distance from it. Under the cell-area convention the
    # miss is about 1825x at radius 50.
    const offset = 240.0
    const bound = 0.0431
    for seed in GATE_SEEDS:
      let clump = seededClump(seed)
      for s, size in LR_GRID_SIZES:
        let potential = solveOneSpecies(clump.density[s], size.w, size.h,
          TEST_WORLD_W, TEST_WORLD_H, LONG_RANGE_REACH_MAX)
        for radius in [INTERACTION_RADIUS_MIN.float, 50.0,
            INTERACTION_RADIUS_MAX.float]:
          let expected = MATRIX_MAX_VALUE * designPairUnit(radius) *
            CLUMP_PARTICLES.float / (2.0 * PI * offset)
          for (dx, dy) in [(1.0, 0.0), (0.0, 1.0)]:
            let actual = impulseAt(potential, size, radius,
              clump.cx + dx * offset, clump.cy + dy * offset)
            let miss = abs(actual / expected - 1.0)
            check miss <= bound
            if miss > bound:
              checkpoint "seed " & $seed & ", " & $size & ", radius " &
                $radius & " along (" & $dx & ", " & $dy & "): solved " &
                $actual & " against " & $expected & ", a miss of " &
                $(miss * 100.0) & "% against " & $(bound * 100.0) & "%"

suite "One Long-Range Full Effect Holds At Every Radius":
  test "the gain at which strength 1 matches the pair's edge impulse is one value at radii 10, 50 and 150":
    # CONTRACT: MAX_PARTICLES in one disc at the onset density pulls a particle
    # one interaction radius past its edge as hard as the pair force at gain 5
    # holds that edge. Both grow as R^2 under U(R), so the gain loses R; the
    # bound is float rounding.
    const bound = 1e-9
    const radii = [INTERACTION_RADIUS_MIN.float, 50.0,
                   INTERACTION_RADIUS_MAX.float]
    var gains: seq[float]
    for radius in radii:
      gains.add longRangeFullEffectGain(UnitConfig(
        particleCount: MAX_PARTICLES, interactionRadius: radius,
        worldWidth: TEST_WORLD_W, worldHeight: TEST_WORLD_H,
        onsetRatio: CROWD_ONSET_RATIO, attraction: MATRIX_MAX_VALUE,
        pairGain: FORCE_STRENGTH_MAX, repulsionEnd: 0.5, attractionPeak: 0.75,
        longRangeGrid: LR_GRID_SIZES[^1]))
    require gains[0] > 0.0
    for i in 1 ..< gains.len:
      let spread = abs(gains[i] / gains[0] - 1.0)
      check spread <= bound
      if spread > bound:
        checkpoint "radius " & $radii[0] & " derives gain " & $gains[0] &
          ", radius " & $radii[i] & " derives " & $gains[i] & ", apart by " &
          $(spread * 100.0) & "%"
