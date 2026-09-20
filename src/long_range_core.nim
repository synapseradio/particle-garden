# ==============================================================================
# THE LONG-RANGE MESH, AS PURE NIM
# ==============================================================================
#
# The analytic mirror of the five WGSL passes that carry the long-range
# coupling: lr-deposit.wgsl, lr-fft-rows.wgsl, lr-fft-cols.wgsl, lr-kernel.wgsl
# and lr-force.wgsl. No FFI, no side effects, no import from GPU-facing code —
# it compiles on both the native and the JS backend, the way field_core,
# sph_core and physics_core do for their shaders.
#
# What runs on the GPU is a grid the particles deposit charge onto, a spectral
# solve that turns that density into one potential per receiving species, and a
# gradient each particle reads as an impulse. This module holds the arithmetic
# of every step of that, at a size a native test can run: the transform, the
# wavenumber a bin stands for, the kernel, the charge assignment, the fixed
# point the accumulator encodes at, the species mix, and the gradient sampler.
#
# The mirror is held by review and nothing else. Change a shader and change the
# function here in the same diff, or the pair drifts silently — the standing
# condition of every reference oracle in this repository
# (docs/enforcement.md, "Reference oracles").
#
# Used by:
#   - tests/test_long_range_core.nim (the suites the specs cite)
#   - src/config_ranges.nim (the declared grid sizes assert against the ceiling)
#   - src/webgpu_compute.nim (the numbers written into LrParams each frame)
#
# ==============================================================================

import std/math
import memory_layout

type
  LrComplex* = object
    ## One complex value of a spectrum. The GPU holds these as `vec2<f32>`;
    ## this module computes in f64, so every disagreement between the two is
    ## the shader's precision and never the oracle's.
    re*: float
    im*: float

func lrIsPowerOfTwo*(n: int): bool =
  ## A line the radix-2 transform can run on at all.
  n > 0 and (n and (n - 1)) == 0

func lrLineStages*(n: int): int =
  ## The number of butterfly stages one line of length n takes, log2(n).
  doAssert lrIsPowerOfTwo(n), "a radix-2 line length must be a power of two"
  var stages = 0
  var size = n
  while size > 1:
    size = size shr 1
    stages += 1
  stages

func lrTransformLine*(line: seq[LrComplex]; inverse: bool): seq[LrComplex] =
  ## One line, transformed. Stockham autosort radix-2, written in the shape
  ## lr-fft-rows.wgsl and lr-fft-cols.wgsl run it: a ping-pong of 2N entries
  ## where each stage reads one half and writes the other, so the two halves
  ## never alias and one barrier per stage suffices on the GPU.
  ##
  ## NEITHER DIRECTION NORMALIZES. The 1/(W*H) a round trip owes is folded into
  ## the kernel instead, where a multiply is already happening. A normalization
  ## added here would be applied twice.
  let n = line.len
  doAssert lrIsPowerOfTwo(n), "a radix-2 line length must be a power of two"
  let stages = lrLineStages(n)
  let half = n div 2
  # The twiddle's sign is the only difference between the two directions, which
  # is why the two WGSL entry points share one file.
  let dirSign = if inverse: 1.0 else: -1.0

  var pingPong = newSeq[LrComplex](2 * n)
  for i in 0 ..< n:
    pingPong[i] = line[i]

  var ns = 1
  for stage in 0 ..< stages:
    let readBase = if (stage and 1) == 1: n else: 0
    let writeBase = n - readBase
    for j in 0 ..< half:
      let k = j and (ns - 1)
      let ang = dirSign * PI * float(k) / float(ns)
      let twRe = cos(ang)
      let twIm = sin(ang)
      let v0 = pingPong[readBase + j]
      let v1 = pingPong[readBase + j + half]
      let wRe = v1.re * twRe - v1.im * twIm
      let wIm = v1.re * twIm + v1.im * twRe
      let dst = (j - k) * 2 + k
      pingPong[writeBase + dst] = LrComplex(re: v0.re + wRe, im: v0.im + wIm)
      pingPong[writeBase + dst + ns] =
        LrComplex(re: v0.re - wRe, im: v0.im - wIm)
    ns = ns * 2

  let finalBase = if (stages and 1) == 1: n else: 0
  result = newSeq[LrComplex](n)
  for i in 0 ..< n:
    result[i] = pingPong[finalBase + i]

const
  LR_SOFTENING_CELLS* = 1.5
    ## The kernel's Gaussian softening width, in CELLS of the live grid.
    ##
    ## It suppresses the grid's own scale and the aliasing cloud-in-cell
    ## assignment introduces, and it bounds the mesh there and nowhere wider.
    ## At the shipped 512 x 256 that is about 12.7 world units, while the
    ## neighbour sweep reaches 10 to 150 (INTERACTION_RADIUS_MIN/MAX), so the
    ## long-range force acts INSIDE the sweep's radius and adds to the species
    ## force there. That overlap is intended: the species force is an authored
    ## polynomial with no long-range tail to subtract, so no particle-particle
    ## particle-mesh split is available.
    ##
    ## Measured condition, held by "Softening Attenuates The Cell Scale": at
    ## this width the kernel at the grid's Nyquist wavenumber carries 9.2e-14
    ## to 1.9e-17 of its value at the reach's wavenumber, across the reach's
    ## whole range. Dropping the softening leaves 7.1e-3 to 1.6e-6; reading this
    ## number as WORLD UNITS rather than cells leaves 6.5e-3 to 1.5e-6. Both
    ## fail that suite's 1e-9 bound.

func lrInverseReachSq*(reach: float): float =
  ## 1/lambda^2, the form the uniform carries so no shader divides. The reach's
  ## range floor is strictly positive for exactly this reason.
  doAssert reach > 0.0, "a reach of zero has no inverse squared screening length"
  1.0 / (reach * reach)

func lrInverseCells*(gridW, gridH: int): float =
  ## 1/(W*H), the inverse transform's normalization. Folded into the kernel
  ## rather than given a pass of its own, where a multiply already happens.
  doAssert gridW > 0 and gridH > 0
  1.0 / (float(gridW) * float(gridH))

func lrSofteningWorld*(gridW, gridH: int; worldW, worldH: float): float =
  ## The softening width in WORLD units: LR_SOFTENING_CELLS of the larger cell
  ## dimension.
  ##
  ## One scalar rather than one per axis, because the kernel reads |k| and a
  ## per-axis width would make it anisotropic in world units — the defect the
  ## isotropy suite exists to catch. The LARGER dimension, because a
  ## power-of-two grid over a 16:9 world has cells 12.5% taller than they are
  ## wide, and it is the coarser axis whose aliasing needs suppressing.
  LR_SOFTENING_CELLS * max(worldW / float(gridW), worldH / float(gridH))

func lrCellArea*(gridW, gridH: int; worldW, worldH: float): float =
  ## World area one mesh cell covers.
  (worldW / float(gridW)) * (worldH / float(gridH))

func lrDiscPull*(strength, entry, cellArea, mass, distance: float): float =
  ## The pull the mesh hands a particle `distance` from the centre of a uniform
  ## disc of `mass` particles, outside the disc: `strength * entry * cellArea *
  ## mass / (2 pi distance)`. The field is the 2D Green's function of the
  ## disc's charge; the cellArea is there because lrKernel folds in 1/(W*H)
  ## against a density counted per cell. Unscreened and unsoftened: the
  ## limit of lr-force.wgsl's read at a reach far past `distance` and a
  ## distance far past the softening.
  strength * entry * cellArea * mass / (2.0 * PI * distance)

func lrFoldBin*(index, extent: int): int =
  ## A bin index folded into [-extent/2, extent/2), which is the signed
  ## wavenumber index the bin stands for. Bins above the half point are the
  ## negative frequencies, not high positive ones.
  if index >= extent div 2: index - extent else: index

func lrWavenumber*(binX, binY, gridW, gridH: int;
                   worldW, worldH: float): tuple[kx, ky: float] =
  ## The physical wavenumber a bin stands for, in radians per world unit.
  ##
  ## THIS IS THE LANDMINE, not a detail. A power-of-two grid over a 16:9 world
  ## cannot have square cells — square would be 512 x 288, and 288 is not a
  ## power of two — so taking the wavenumber from the bin index instead of the
  ## world's extent stretches the force along one axis by the ratio of the
  ## cell's sides, with no other symptom and nothing else to catch it.
  let m = float(lrFoldBin(binX, gridW))
  let n = float(lrFoldBin(binY, gridH))
  (kx: 2.0 * PI * m / worldW, ky: 2.0 * PI * n / worldH)

func lrKernel*(kx, ky, invReachSq, softening, invCells: float): float =
  ## G(k) = exp(-|k|^2 sigma^2 / 2) / (|k|^2 + 1/lambda^2) / (W*H), G(0) = 0.
  ##
  ## G(0) is exactly zero at every reach. In the unscreened limit that is
  ## forced, since the kernel has no finite value there; at a finite reach it
  ## is the choice that keeps the force answering density CONTRAST rather than
  ## absolute density, so adding particles uniformly moves nothing.
  let kSq = kx * kx + ky * ky
  if kSq == 0.0:
    return 0.0
  exp(-kSq * softening * softening / 2.0) * invCells / (kSq + invReachSq)

func lrTransformGrid*(grid: seq[LrComplex]; gridW, gridH: int;
                      inverse: bool): seq[LrComplex] =
  ## One species' whole grid, row-major, transformed on both axes: the row pass
  ## then the column pass, which is the order the frame dispatches them in.
  ## Unnormalized in both directions, like the line transform it is built from.
  doAssert grid.len == gridW * gridH, "a grid is gridW * gridH values"
  result = newSeq[LrComplex](gridW * gridH)

  var line = newSeq[LrComplex](gridW)
  for y in 0 ..< gridH:
    for x in 0 ..< gridW:
      line[x] = grid[y * gridW + x]
    let transformed = lrTransformLine(line, inverse)
    for x in 0 ..< gridW:
      result[y * gridW + x] = transformed[x]

  var column = newSeq[LrComplex](gridH)
  for x in 0 ..< gridW:
    for y in 0 ..< gridH:
      column[y] = result[y * gridW + x]
    let transformed = lrTransformLine(column, inverse)
    for y in 0 ..< gridH:
      result[y * gridW + x] = transformed[y]

# ==============================================================================
# CHARGE ASSIGNMENT AND THE ACCUMULATOR'S FIXED POINT
# ==============================================================================

const
  LR_DENSITY_SCALE* = 1024
    ## The fixed point the density accumulator encodes at — ITS OWN, not the
    ## velocity deltas' 65536.
    ##
    ## The worst case is exactly MAX_PARTICLES: a particle deposits unit charge
    ## spread across four cells with weights summing to one, so the accumulated
    ## value counts particles and nothing bounds how many occupy one cell.
    ## Sharing the velocity scale would cap the accumulator at 32768 particles
    ## per cell, which the particle ceiling passes, and an i32 past its maximum
    ## wraps NEGATIVE — a density the kernel reads as a hole exactly where the
    ## world holds its densest clump, with the force reversed there and nowhere
    ## else. Headroom carries this in place of a check, because the total is
    ## formed by atomicAdd across threads and no contribution sees the running
    ## total.
    ##
    ## At 1024 the accumulator holds 2.1M particle-equivalents per cell and
    ## resolves a thousandth of a particle. The strength does NOT multiply the
    ## deposit — it multiplies in the force pass alone — which is what keeps
    ## this bound a function of the particle ceiling and not of a slider's
    ## maximum.
  LR_FFT_WORKGROUP_SIZE* = 256
    ## Invocations per workgroup in the two transform shaders. One line runs in
    ## one workgroup whatever its length; a line longer than this loops each
    ## thread over several butterflies.
  LR_FFT_MAX_LINE* = max(LR_GRID_MAX_W, LR_GRID_MAX_H)
    ## The longest line the transform's workgroup array is compiled to hold,
    ## which is the allocation ceiling's longer side. The array holds 2N
    ## complex values, so it costs 2 * N * 8 bytes of workgroup storage.
  LR_WORKGROUP_STORAGE_GUARANTEE* = 16384
    ## WebGPU's default guaranteed maxComputeWorkgroupStorageSize, in bytes.
    ## The bound the transform's line length is derived from: this machine's
    ## adapter grants twice it, so a grid sized against the adapter rather than
    ## against the guarantee would run here and fail to compile elsewhere.

static:
  doAssert MAX_PARTICLES * LR_DENSITY_SCALE < high(int32).int,
    "the whole particle budget in one cell must encode inside a signed 32-bit " &
    "integer; past its maximum an i32 wraps negative and the kernel reads the " &
    "densest cell in the world as a hole"
  doAssert 2 * LR_FFT_MAX_LINE * 8 <= LR_WORKGROUP_STORAGE_GUARANTEE,
    "one line of the long-range grid must fit the workgroup storage WebGPU " &
    "guarantees, or the transform compiles on this adapter and nowhere else"

type
  LrCellAssignment* = object
    ## One particle's cloud-in-cell deposit: the four cells it touches and the
    ## share of its unit charge each receives.
    cells*: array[4, int]
      ## Flat row-major indices into the LIVE grid, already wrapped on the
      ## torus. Order: (x0,y0), (x1,y0), (x0,y1), (x1,y1).
    weights*: array[4, float]
      ## Bilinear weights in the same order, summing to one.

func lrWrapCell*(cell, extent: int): int =
  ## A cell index brought back onto the torus. Nim's `mod` keeps the sign of
  ## its left operand, so a negative index needs the second fold.
  ((cell mod extent) + extent) mod extent

func lrAssign*(px, py: float; gridW, gridH: int;
               worldW, worldH: float): LrCellAssignment =
  ## Cloud-in-cell assignment of one particle's unit charge.
  ##
  ## CIC rather than nearest-cell because the force is a GRADIENT of this
  ## field, and nearest-cell assignment puts a step at every cell boundary —
  ## which in an instrument reads as particles falling into lanes spaced at the
  ## cell size. Four atomics per particle against one is not a cost worth
  ## trading that artifact for.
  ##
  ## The depositing species' chemistry secretion is NOT read here. The species
  ## relationship lives in the attraction matrix the kernel pass applies, and
  ## applying a sign twice would mean two controls for one relationship.
  let cellW = worldW / float(gridW)
  let cellH = worldH / float(gridH)
  # Cell centres sit at (i + 0.5) cells, so the four cells whose centres
  # bracket a position are found by shifting half a cell before the floor.
  let u = px / cellW - 0.5
  let v = py / cellH - 0.5
  let baseX = int(floor(u))
  let baseY = int(floor(v))
  let fx = u - float(baseX)
  let fy = v - float(baseY)
  let x0 = lrWrapCell(baseX, gridW)
  let x1 = lrWrapCell(baseX + 1, gridW)
  let y0 = lrWrapCell(baseY, gridH)
  let y1 = lrWrapCell(baseY + 1, gridH)
  result.cells = [y0 * gridW + x0, y0 * gridW + x1,
                  y1 * gridW + x0, y1 * gridW + x1]
  result.weights = [(1.0 - fx) * (1.0 - fy), fx * (1.0 - fy),
                    (1.0 - fx) * fy, fx * fy]

func lrEncodeDensity*(charge: float): int32 =
  ## One contribution, as the accumulator holds it. Truncating rather than
  ## rounding, which is what `i32(x)` does in WGSL.
  int32(charge * float(LR_DENSITY_SCALE))

func lrDecodeDensity*(fixed: int32): float =
  ## The accumulated density a cell holds, in particles.
  float(fixed) / float(LR_DENSITY_SCALE)

# ==============================================================================
# THE SPECIES MIX, AND THE GRADIENT A PARTICLE READS
# ==============================================================================

func lrMixBin*(sources: openArray[LrComplex]; matrix: openArray[float];
               stride, receiver, speciesCount: int; kernel: float): LrComplex =
  ## One bin of the kernel pass:
  ##
  ##   Phi_r(k) = G(k) * sum over s of A[r][s] * rho_s(k)
  ##
  ## The receiving species indexes the ROW, the source the column, which is the
  ## convention forces.wgsl already reads (thisSpecies * MAX_SPECIES +
  ## otherSpecies), so one matrix entry names one relationship acting at two
  ## ranges. Reading the column instead swaps who is pulled toward whom.
  ##
  ## The kernel multiplies the mixed sum, not each source before it. Both
  ## orders give the same answer because the kernel is a scalar and the mix is
  ## linear; the shader does it this way because one thread owns one bin, holds
  ## the S source values in registers, and writes the S receivers from them.
  ##
  ## Because the matrix is asymmetric, no single potential every species reads
  ## exists, and the long-range term therefore does NOT conserve momentum. That
  ## is a stated property of this coupling rather than a defect to patch.
  var accRe = 0.0
  var accIm = 0.0
  for source in 0 ..< speciesCount:
    let entry = matrix[receiver * stride + source]
    accRe += entry * sources[source].re
    accIm += entry * sources[source].im
  LrComplex(re: accRe * kernel, im: accIm * kernel)

func lrSamplePotential*(potential: openArray[float]; gridW, gridH: int;
                        worldW, worldH, px, py: float): float =
  ## The potential at a world position, bilinearly interpolated.
  ##
  ## It reads the SAME four cells and the SAME four weights the deposit wrote
  ## with. That pairing is not tidiness: it is what makes the population's
  ## impulses sum to the grid's own quantity, and so what makes momentum cancel
  ## exactly under a symmetric matrix.
  let assignment = lrAssign(px, py, gridW, gridH, worldW, worldH)
  result = 0.0
  for i in 0 .. 3:
    result += assignment.weights[i] * potential[assignment.cells[i]]

func lrGradient*(potential: openArray[float]; gridW, gridH: int;
                 worldW, worldH, px, py: float): tuple[gx, gy: float] =
  ## The impulse direction a particle reads, before the strength scales it:
  ## a central difference of the bilinearly interpolated potential, ONE CELL
  ## apart on each axis. Four bilinear samples, sixteen loads.
  ##
  ## The step is exactly one cell, and that exactness carries weight. Shifting
  ## the sample point by one whole cell is the same as shifting the cell index
  ## by one, so summed over a population the sampled gradients equal the grid's
  ## own central difference contracted with the deposited density — which is
  ## the step in the momentum argument. A step of half a cell, or of a fixed
  ## number of world units, loses that.
  ##
  ## The sign is positive: the kernel is positive, so a positive matrix entry
  ## raises the potential where the source species is dense, and a receiver
  ## following +grad(Phi) accelerates TOWARD it. Attraction is a positive entry
  ## at both ranges.
  let cellW = worldW / float(gridW)
  let cellH = worldH / float(gridH)
  let right = lrSamplePotential(potential, gridW, gridH, worldW, worldH,
                                px + cellW, py)
  let left = lrSamplePotential(potential, gridW, gridH, worldW, worldH,
                               px - cellW, py)
  let above = lrSamplePotential(potential, gridW, gridH, worldW, worldH,
                                px, py + cellH)
  let below = lrSamplePotential(potential, gridW, gridH, worldW, worldH,
                                px, py - cellH)
  (gx: (right - left) / (2.0 * cellW), gy: (above - below) / (2.0 * cellH))
