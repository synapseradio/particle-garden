# ==============================================================================
#
# Pure functions for particle physics calculations. These have no side effects
# and can be tested in isolation without buffer access.
#
# Used by:
#   - tests/test_physics.nim (native test compilation)
#
# This is a reference oracle, like grid_core: the forces the simulation
# actually applies live in forces.wgsl, which no native test can execute.
# These functions mirror that math in a form the native suite can check, so
# the shader has something to be wrong against.
#
# ==============================================================================

import std/complex
import std/math

const
  INV_03* = 1.0f / 0.3f  # Inverse of repulsion threshold
  INV_07* = 1.0f / 0.7f  # Inverse of attraction envelope width
  MIN_DIST_SQ* = 4.0f    # Minimum distance squared (2.0^2) to avoid division issues

  FRAME_DT_REFERENCE* = 1.0 / 120.0
    ## The dt a shipped frame carries: a 60 Hz frame at the default timeScale of
    ## 0.5. Every force constant in this codebase was measured against a frame
    ## worth this much, so it is the unit frameFactor reports multiples of.

  VELOCITY_FIXED_POINT_SCALE* = 65536.0
    ## The fine velocity word's quanta per unit of velocity, 2^16.

  MOUSE_FORCE_PEAK* = 300.0
    ## The held pointer's force at the pointer, per unit time.

  BLAST_FORCE_PEAK* = 3000.0
    ## The blast's force at strength 1 and distance 10, per unit time.

func frameFactor*(dt: float): float =
  ## A frame's dt as a multiple of the reference frame.
  ##
  ## Every velocity writer hands over its impulse per reference frame, and
  ## integrate.wgsl multiplies the decoded sum by this once, so it is the one
  ## place Time Scale reaches the particle velocity.
  dt / FRAME_DT_REFERENCE

func calculateForce*(normalizedDistance, attr, fMul, invD: float32): float32 =
  ## Calculate force magnitude between two particles.
  ##
  ## normalizedDistance - Normalized distance in [0, 1] range (d / rMax)
  ## attr - Attraction value from matrix (-1 to 1 typically)
  ## fMul - Force multiplier (scales overall force strength)
  ## invD - Inverse of actual distance (1 / d)
  ##
  ## Returns force magnitude. Positive = attraction, negative = repulsion.
  ## The returned value should be multiplied by the displacement vector.
  ##
  ## Physics:
  ##   - normalizedDistance < 0.3: Repulsion zone. Force = (r/0.3 - 1) * fMul / d
  ##   - normalizedDistance >= 0.3: Attraction zone. Force = attr * (1 - |2r - 1.3| / 0.7) * fMul / d
  ##
  var force: float32

  if normalizedDistance < 0.3f:
    # Repulsion: linear ramp from -1 at r=0 to 0 at r=0.3
    force = normalizedDistance * INV_03 - 1.0f
  else:
    # Attraction: triangular envelope centered at r=0.65
    let triangleOffset = 2.0f * normalizedDistance - 1.3f
    let absTriangleOffset = if triangleOffset < 0.0f: -triangleOffset else: triangleOffset
    force = attr * (1.0f - absTriangleOffset * INV_07)

  result = force * fMul * invD


func crowdingAttenuation*(density, strength: float32): float32 =
  ## The fraction of its attraction a particle keeps at this local density.
  ##
  ## `1 / (1 + strength * ln(1 + density))`. Logarithmic because the range that
  ## matters spans two orders of magnitude — a few neighbours against a
  ## collapsing blob — and a linear coefficient tuned for one end does nothing
  ## at the other.
  ##
  ## density - the receiving particle's smoothed local density, non-negative by
  ##           construction: it is a sum of non-negative proximity weights fed
  ##           through an exponential moving average of itself.
  ## strength - the crowding strength parameter. Zero returns 1.0 at every
  ##            density, leaving calculateForce's attraction unchanged.
  ##
  ## Three properties hold by construction rather than by tuning, and each is a
  ## test in tests/test_physics.nim: identity at zero density, monotone
  ## decreasing in density, and identity at strength zero.
  1.0f / (1.0f + strength * ln(1.0f + density))


func calculateAttenuatedForce*(normalizedDistance, attr, fMul, invD, density,
    crowdingStrength: float32): float32 =
  ## calculateForce with the crowding term applied to the ATTRACTIVE
  ## contribution alone.
  ##
  ## Attractive here means the attraction zone entered with a positive matrix
  ## entry. The repulsion zone keeps calculateForce's force at every density,
  ## and so does an attraction-zone pair whose matrix entry is negative — that
  ## contribution pushes the pair apart, and damping it would partly cancel the
  ## cap the term exists to serve.
  ##
  ## The attenuation multiplies the force AFTER `fMul`, so the result at force
  ## strength k is k times the result at force strength 1. That must hold:
  ## expressed as an absolute force instead, the term would mean something
  ## different at each end of the force-strength range and stop being a cap.
  let plain = calculateForce(normalizedDistance, attr, fMul, invD)
  if normalizedDistance >= 0.3f and attr > 0.0f:
    plain * crowdingAttenuation(density, crowdingStrength)
  else:
    plain


func calculateForceMagnitude*(normalizedDistance, attr: float32): float32 =
  ## Calculate raw force magnitude without scaling.
  ##
  ## Useful for testing the force curve shape independent of fMul and invD.
  ## Returns the unscaled force value.
  ##
  if normalizedDistance < 0.3f:
    result = normalizedDistance * INV_03 - 1.0f
  else:
    let triangleOffset = 2.0f * normalizedDistance - 1.3f
    let absTriangleOffset = if triangleOffset < 0.0f: -triangleOffset else: triangleOffset
    result = attr * (1.0f - absTriangleOffset * INV_07)


func normalizeDistance*(dx, dy, rMax: float32; minDistSq: float32 = MIN_DIST_SQ): tuple[
    normalizedDist: float32, invD: float32, valid: bool] =
  ## Normalize displacement vector to interaction range.
  ##
  ## dx, dy - Displacement vector components
  ## rMax - Maximum interaction radius
  ## minDistSq - Minimum distance squared (clamped to avoid division issues)
  ##
  ## Returns:
  ##   normalizedDist - Normalized distance in [0, 1] range
  ##   invD - Inverse of clamped distance (1 / dist)
  ##   valid - True if particles are within interaction range (0 < dist < rMax)
  ##
  let distSq = dx * dx + dy * dy
  let rMaxSq = rMax * rMax

  if distSq <= 0.0f or distSq >= rMaxSq:
    # Outside interaction range or same particle
    return (normalizedDist: 0.0f, invD: 0.0f, valid: false)

  # Clamp minimum distance to avoid extreme forces
  let distSqClamped = if distSq < minDistSq: minDistSq else: distSq
  let dist = sqrt(distSqClamped)
  let invD = 1.0f / dist
  let normalizedDistance = dist / rMax

  result = (normalizedDist: normalizedDistance, invD: invD, valid: true)


func accumulateDensity*(normalizedDistance: float32; sameSpecies: bool): float32 =
  ## Calculate density contribution from a neighbor particle.
  ##
  ## normalizedDistance - Normalized distance in [0, 1] range
  ## sameSpecies - True if both particles are the same species
  ##
  ## Returns density contribution. Only same-species particles contribute.
  ## Contribution falls off linearly: (1 - r) at distance 0, 0 at distance rMax.
  ##
  if sameSpecies:
    result = 1.0f - normalizedDistance
  else:
    result = 0.0f


func wrapDelta*(delta, size, halfSize: float32): float32 =
  ## Apply toroidal wrapping to a displacement component.
  ##
  ## delta - Displacement value (e.g., x2 - x1)
  ## size - Full domain size (e.g., canvas width)
  ## halfSize - Half the domain size (size / 2)
  ##
  ## Returns wrapped delta that takes the shortest path across the torus.
  ## If |delta| > halfSize, wrap around the opposite edge.
  ##
  if delta > halfSize:
    result = delta - size
  elif delta < -halfSize:
    result = delta + size
  else:
    result = delta


func wrapPosition*(pos, size: float32): float32 =
  ## Wrap a position to stay within [0, size) bounds.
  ##
  ## pos - Position value
  ## size - Domain size
  ##
  ## Returns wrapped position in [0, size) range.
  ##
  if pos < 0.0f:
    result = pos + size
  elif pos >= size:
    result = pos - size
  else:
    result = pos


func computeCellCoords*(px, py: float32; gridW, gridH: int;
    invCellW, invCellH: float32): tuple[cx: int, cy: int] =
  ## Compute grid cell coordinates from particle position.
  ##
  ## px, py - Particle position
  ## gridW, gridH - Grid dimensions
  ## invCellW, invCellH - Inverse cell dimensions (gridW/canvasW, gridH/canvasH)
  ##
  ## Returns (cx, cy) cell coordinates, clamped to valid range [0, gridW-1] x [0, gridH-1].
  ##
  var cx = int(px * invCellW)
  var cy = int(py * invCellH)

  if cx < 0:
    cx = 0
  elif cx >= gridW:
    cx = gridW - 1

  if cy < 0:
    cy = 0
  elif cy >= gridH:
    cy = gridH - 1

  result = (cx: cx, cy: cy)


func cellCoordsToIndex*(cx, cy, gridW: int): int =
  result = cy * gridW + cx


func getNeighborCell*(cx, cy, dx, dy, gridW, gridH: int;
    canvasW, canvasH: float32): tuple[nx: int, ny: int, cell: int,
        wrapX: float32, wrapY: float32] =
  ## Get neighbor cell with toroidal wrapping.
  ##
  ## cx, cy - Current cell coordinates
  ## dx, dy - Offset to neighbor (-1, 0, or 1)
  ## gridW, gridH - Grid dimensions
  ## canvasW, canvasH - Canvas dimensions (for wrap offset calculation)
  ##
  ## Returns:
  ##   nx, ny - Wrapped neighbor cell coordinates
  ##   cell - Linear cell index
  ##   wrapX, wrapY - Position offsets to apply when computing distances
  ##
  var nx = cx + dx
  var ny = cy + dy
  var wrapX = 0.0f
  var wrapY = 0.0f

  if nx < 0:
    nx += gridW
    wrapX = -canvasW
  elif nx >= gridW:
    nx -= gridW
    wrapX = canvasW

  if ny < 0:
    ny += gridH
    wrapY = -canvasH
  elif ny >= gridH:
    ny -= gridH
    wrapY = canvasH

  let cell = ny * gridW + nx
  result = (nx: nx, ny: ny, cell: cell, wrapX: wrapX, wrapY: wrapY)

# ==============================================================================
# THE CONFIGURABLE FORCE CURVES
# ==============================================================================
# forces.wgsl dispatches between two force models by params.forceModel, both
# parameterized from SimParams; these mirror that shipped block (the MODEL 0 /
# MODEL 1 branch in the neighbour loop). calculateForce above implements a
# third, fixed 0.3/1.3/0.7 curve, independent of the two selectable models
# below. Neither model multiplies by the force multiplier or the inverse
# distance here — the shader applies
# `* params.forceMultiplier * invDistance` after the branch, and callers of
# these mirrors do the same.

func polynomialForce*(normalizedDist, attraction, repulsionEnd,
    attractionPeak, attenuation: float32): float32 =
  ## forces.wgsl MODEL 0. Repulsion over [0, repulsionEnd] is the Hermite ramp
  ## -1 + 3t² - 2t³ in the zone-normalized t, so contact costs -1 and the ramp
  ## lands at 0 with zero slope. Attraction over [repulsionEnd, 1] is a squared
  ## bump peaking at attractionPeak scaled by 4, and the crowding attenuation
  ## multiplies it only when the matrix entry attracts (a negative entry pushes
  ## apart, and damping it would fight the cap). Zone degeneracy
  ## (attractionPeak at or outside [repulsionEnd, 1]) is unguarded exactly as
  ## the shader leaves it unguarded; the ranges keep it unreachable.
  if normalizedDist < repulsionEnd:
    let t = normalizedDist / repulsionEnd
    let t2 = t * t
    -1.0'f32 + 3.0'f32 * t2 - 2.0'f32 * t2 * t
  else:
    let zoneWidth = 1.0'f32 - repulsionEnd
    let peakPos = (attractionPeak - repulsionEnd) / zoneWidth
    let t = (normalizedDist - repulsionEnd) / zoneWidth
    let leftDist = t / peakPos
    let rightDist = (1.0'f32 - t) / (1.0'f32 - peakPos)
    let bump = min(leftDist, 1.0'f32) * min(leftDist, 1.0'f32) *
      min(rightDist, 1.0'f32) * min(rightDist, 1.0'f32)
    let crowding = (if attraction > 0.0'f32: attenuation else: 1.0'f32)
    attraction * bump * 4.0'f32 * crowding

func exponentialForce*(normalizedDist, attraction, alpha, beta,
    attenuation: float32): float32 =
  ## forces.wgsl MODEL 1: -exp(-alpha r) repulsion plus attr * exp(-beta r) * 2
  ## attraction, the attraction attenuated under the same positive-entry gate
  ## as the polynomial bump.
  let repulsion = exp(-alpha * normalizedDist)
  let attract = exp(-beta * normalizedDist)
  let crowding = (if attraction > 0.0'f32: attenuation else: 1.0'f32)
  -repulsion + attraction * attract * 2.0'f32 * crowding

func polynomialRestoringSlope*(normalizedDist, attraction, repulsionEnd,
    attractionPeak, attenuation, forceMultiplier, invRadius: float32): float32 =
  ## The positive part of polynomialForce's radial derivative, over one
  ## reference frame: forceMultiplier * FRAME_DT_REFERENCE * invRadius *
  ## max(0, dF/d(normalizedDist)).
  let slope =
    if normalizedDist < repulsionEnd:
      let t = normalizedDist / repulsionEnd
      (6.0'f32 * t - 6.0'f32 * t * t) / repulsionEnd
    else:
      let zoneWidth = 1.0'f32 - repulsionEnd
      let peakPos = (attractionPeak - repulsionEnd) / zoneWidth
      let t = (normalizedDist - repulsionEnd) / zoneWidth
      let leftDist = t / peakPos
      let rightDist = (1.0'f32 - t) / (1.0'f32 - peakPos)
      let left = min(leftDist, 1.0'f32)
      let right = min(rightDist, 1.0'f32)
      let leftSlope = if leftDist < 1.0'f32: 1.0'f32 / peakPos else: 0.0'f32
      let rightSlope =
        if rightDist < 1.0'f32: -1.0'f32 / (1.0'f32 - peakPos) else: 0.0'f32
      let crowding = (if attraction > 0.0'f32: attenuation else: 1.0'f32)
      let bumpSlope = 2.0'f32 * left * leftSlope * right * right +
        2.0'f32 * right * rightSlope * left * left
      attraction * 4.0'f32 * crowding * bumpSlope / zoneWidth
  max(0.0'f32, forceMultiplier * FRAME_DT_REFERENCE.float32 * invRadius * slope)

func exponentialRestoringSlope*(normalizedDist, attraction, alpha, beta,
    attenuation, forceMultiplier, invRadius: float32): float32 =
  ## The positive part of exponentialForce's radial derivative, over one
  ## reference frame.
  let crowding = (if attraction > 0.0'f32: attenuation else: 1.0'f32)
  let slope = alpha * exp(-alpha * normalizedDist) -
    attraction * 2.0'f32 * crowding * beta * exp(-beta * normalizedDist)
  max(0.0'f32, forceMultiplier * FRAME_DT_REFERENCE.float32 * invRadius * slope)

func mouseForce*(offsetX, offsetY, mouseRange, buttonSign: float32):
    tuple[x, y: float32] =
  ## forces.wgsl's held-pointer term. `offset` runs from the particle to the
  ## pointer, already minimum-imaged; `buttonSign` is +1 for the left button,
  ## -1 for the right and 0 for both. The magnitude is 300 at the pointer
  ## easing to zero at `mouseRange`, per unit of time before the reference
  ## frame multiplies it.
  let distSq = offsetX * offsetX + offsetY * offsetY
  if distSq > 0.0'f32 and distSq < mouseRange * mouseRange:
    let dist = sqrt(distSq)
    let force = MOUSE_FORCE_PEAK.float32 * (1.0'f32 - dist / mouseRange) / dist
    (x: offsetX * force * buttonSign, y: offsetY * force * buttonSign)
  else:
    (x: 0.0'f32, y: 0.0'f32)

func blastForce*(offsetX, offsetY, blastStrength, blastRange: float32):
    tuple[x, y: float32] =
  ## forces.wgsl's blast term. `offset` runs from the blast centre to the
  ## particle, already minimum-imaged. The divisor is floored at 10, so the
  ## magnitude peaks at distance 10 rather than at the centre.
  let distSq = offsetX * offsetX + offsetY * offsetY
  if blastStrength > 0.01'f32 and distSq > 0.0'f32 and
      distSq < blastRange * blastRange:
    let dist = sqrt(distSq)
    let force = blastStrength * BLAST_FORCE_PEAK.float32 *
      (1.0'f32 - dist / blastRange) /
      max(dist, 10.0'f32)
    (x: offsetX * force, y: offsetY * force)
  else:
    (x: 0.0'f32, y: 0.0'f32)

func encodeVelocityDelta*(value, fixedPointScale: float32): int32 =
  ## The word a velocity-delta writer adds, WGSL's truncating
  ## `i32(value * FIXED_POINT_SCALE)`. Search that form to find the writers:
  ## forces.wgsl, forces-sph.wgsl, field-force.wgsl, lr-force.wgsl,
  ## body-force.wgsl.
  int32(value * fixedPointScale)

func forcesVelocityDeltaFixed*(force, fixedPointScale: float32): int32 =
  ## forces.wgsl: the pair force, or a particle's summed pair, mouse and blast
  ## force, over one reference frame, encoded.
  encodeVelocityDelta(force * FRAME_DT_REFERENCE.float32, fixedPointScale)

func decodeVelocityDelta*(deltaFixed: int32;
    invFixedPointScale, frameFactor: float32): float32 =
  ## integrate.wgsl: the word decoded and multiplied by the substep's frame
  ## factor, the one time factor a particle's velocity receives.
  float32(deltaFixed) * invFixedPointScale * frameFactor

type VelocityWords* = tuple[fine, coarse: int32]
  ## A particle's velocity delta on one axis: fine quanta plus coarse units of
  ## 2^coarseShift fine quanta each.

func splitVelocityWord*(deltaFixed: int32; coarseShift: int): VelocityWords =
  ## forces-sph.wgsl's per-pair split. The arithmetic shift rounds toward
  ## negative infinity, so the fine remainder is never negative and the two
  ## words sum back to `deltaFixed` exactly.
  (fine: deltaFixed and int32((1 shl coarseShift) - 1),
   coarse: ashr(deltaFixed, coarseShift))

func splitVelocitySum*(value, fixedPointScale: float32;
    coarseShift: int): VelocityWords =
  ## forces-sph.wgsl's split of a particle's own register, which a full crowd
  ## takes past any i32. Every step is exact in f32: the truncated value is an
  ## integer, dividing by a power of two is exact, and the remainder lies in
  ## [0, 2^coarseShift).
  let scaled = trunc(value * fixedPointScale)
  let unit = float32(1 shl coarseShift)
  let coarse = floor(scaled / unit)
  (fine: int32(scaled - coarse * unit), coarse: int32(coarse))

func addVelocityWords*(sum, words: VelocityWords): VelocityWords =
  ## Two atomicAdds, one per word, wrapping as WGSL's i32 atomics do.
  (fine: cast[int32](cast[uint32](sum.fine) + cast[uint32](words.fine)),
   coarse: cast[int32](cast[uint32](sum.coarse) + cast[uint32](words.coarse)))

func decodeVelocityWords*(words: VelocityWords;
    invFixedPointScale, frameFactor: float32; coarseShift: int): float32 =
  ## integrate.wgsl: both words decoded, then the substep's frame factor.
  (float32(words.fine) + float32(words.coarse) * float32(1 shl coarseShift)) *
    invFixedPointScale * frameFactor

func postStepSpeed*(speed, friction, maxVelocity: float32): float32 =
  ## integrate.wgsl. Friction multiplies the post-delta velocity (it is
  ## a retention factor, not a drag), then speeds above half maxVelocity are
  ## compressed as threshold + ln(1 + excess) and hard-capped at maxVelocity.
  let damped = speed * friction
  let softCapThreshold = maxVelocity * 0.5'f32
  if damped > softCapThreshold and damped > 0.0'f32:
    min(softCapThreshold + ln(1.0'f32 + damped - softCapThreshold),
      maxVelocity)
  else:
    damped

type
  StepClock* = object
    ## The reference-frame clock: how far a substep travels (`ff`), how much
    ## of the carried velocity survives the substep (`retention`), and how
    ## much of one reference frame's force gain lands (`forceGain`). `r`
    ## carries the substep's own retention input, unexposed by an accessor,
    ## for the long-step bound's `1 - rho/r` term (D4), which `rho` and `ff`
    ## alone cannot reconstruct.
    ff, rho, h, r: float32

func stopped(retention: float32): StepClock =
  StepClock(ff: 0.0'f32, rho: 1.0'f32, h: 0.0'f32, r: retention)

func frictionless(ff: float32): StepClock =
  StepClock(ff: ff, rho: 1.0'f32, h: ff, r: 1.0'f32)

func damped(ff, retention: float32): StepClock =
  let rho = pow(retention, ff)
  StepClock(ff: ff, rho: rho,
    h: retention * (1.0'f32 - rho) / (1.0'f32 - retention), r: retention)

func stepClock*(ff, retention: float32): StepClock =
  ## D1's clock: rho = r^ff over the whole substep, h its force gain, with
  ## h = ff at retention 1 and h = ff at ff 0 alike, so a stopped or
  ## frictionless clock never divides by a vanishing (1 - retention).
  assert retention >= 0.5'f32 and retention <= 1.0'f32,
    "stepClock retention " & $retention & " outside [0.5, 1]"
  if ff == 0.0'f32:
    stopped(retention)
  elif retention >= 1.0'f32:
    frictionless(ff)
  else:
    damped(ff, retention)

func travel*(clock: StepClock): float32 = clock.ff
func retention*(clock: StepClock): float32 = clock.rho
func forceGain*(clock: StepClock): float32 = clock.h

func densityCarry*(clock: StepClock; factor: float32): float32 =
  ## The fraction of a smoothed density carried across the whole substep:
  ## `factor` raised to the substep's own frame factor, so N substeps
  ## summing to ff compose to the same carry as one substep of ff.
  pow(factor, clock.ff)

func integrateVelocityFromDelta*(velocity, delta: tuple[x, y: float32];
    clock: StepClock; stepLimit, maxVelocity: float32): tuple[x, y: float32] =
  ## integrate.wgsl, given `delta` already decoded for one reference frame:
  ## u' = stepLimit * (rho*v + h*delta), capped on the speed itself, since
  ## the cap bounds travel per reference frame regardless of how many of
  ## them the substep spans.
  let newVelX = stepLimit * (clock.retention * velocity.x +
    clock.forceGain * delta.x)
  let newVelY = stepLimit * (clock.retention * velocity.y +
    clock.forceGain * delta.y)
  let speed = sqrt(newVelX * newVelX + newVelY * newVelY)
  if speed <= 0.0'f32:
    return (x: newVelX, y: newVelY)
  let scale = postStepSpeed(speed, 1.0'f32, maxVelocity) / speed
  (x: newVelX * scale, y: newVelY * scale)

func integrateVelocity*(velocity: tuple[x, y: float32];
    deltaFixed: tuple[x, y: int32]; invFixedPointScale: float32;
    clock: StepClock; stepLimit, maxVelocity: float32): tuple[x, y: float32] =
  ## integrate.wgsl: the fixed-point delta decoded for one reference frame,
  ## then folded through `clock` by `integrateVelocityFromDelta`.
  let delta = (x: decodeVelocityDelta(deltaFixed.x, invFixedPointScale, 1.0'f32),
    y: decodeVelocityDelta(deltaFixed.y, invFixedPointScale, 1.0'f32))
  integrateVelocityFromDelta(velocity, delta, clock, stepLimit, maxVelocity)

# ==============================================================================
# THE WORLD PRESSURE
# ==============================================================================
# The world's resistance to compression: a repulsive impulse a pair exchanges
# once its own crowd density passes the onset. It is part of the pair law, so
# no coupling strength scales it and no slider reaches it.

func crowdPressure*(density, onset: float32): float32 =
  ## The pressure a particle at this smoothed crowd density carries:
  ## `(max(density - onset, 0) / onset)^2`.
  ##
  ## The square is what keeps the onset from being a step. Its local stiffness,
  ## `2 K (x - x_on)/x_on^2`, starts at zero and rises with the excess, where a
  ## Tait law's jump at the onset boiled the settle it is meant to hold: mean
  ## speed 4.02 against the square law's 1.47 on the same world.
  let excess = max(density - onset, 0.0'f32) / onset
  excess * excess

func worldPressureSum*(pressureThis, pressureOther, stiffness,
    impulseMax: float32): float32 =
  ## A pair's pressure over one reference frame before the proximity weight,
  ## saturated here so the pair's radial slope stays bounded by
  ## `impulseMax / R` at every distance.
  min(stiffness * (pressureThis + pressureOther) *
    FRAME_DT_REFERENCE.float32, impulseMax)

func worldPressureMagnitude*(pressureThis, pressureOther, normalizedDistance,
    stiffness, impulseMax: float32): float32 =
  ## The repulsive impulse a pair exchanges over one reference frame: the
  ## saturated sum times the proximity weight `1 - r/R`.
  worldPressureSum(pressureThis, pressureOther, stiffness, impulseMax) *
    (1.0'f32 - normalizedDistance)

func pairStiffnessSlope*(pressureThis, pressureOther, stiffness, impulseMax,
    invRadius: float32): float32 =
  ## The pair's contribution to a particle's summed stiffness `D`: the
  ## saturated pressure sum's radial slope, `d/dr[sum * (1 - r/R)]` at fixed
  ## sum, which is `-sum / R`.
  worldPressureSum(pressureThis, pressureOther, stiffness, impulseMax) *
    invRadius

func stepLimit*(frameFactor, stiffness, bound: float32): float32 =
  ## The factor integrate applies to a particle's whole delta: 1 unless one
  ## step would carry `frameFactor * 2 * stiffness` past `bound`.
  let reach = 2.0'f32 * frameFactor * stiffness
  if reach > bound: bound / reach else: 1.0'f32

func longStepB(clock: StepClock; bound, longStepBound: float32): float32 =
  ## D4's `B`: `bound * rho`, loosened toward `longStepBound` as the
  ## substep's retention falls (`B = bound` frictionless, where `rho` is 1
  ## and `rho / r` is 1).
  bound * clock.rho + longStepBound * (1.0'f32 - clock.rho / clock.r)

func stepLimit*(clock: StepClock; stiffness, bound, longStepBound: float32):
    float32 =
  ## D4's s_D, over the clock's own substep: 1 unless the substep would
  ## carry `2 * ff * h * stiffness` past `B`.
  let b = longStepB(clock, bound, longStepBound)
  let reach = 2.0'f32 * clock.ff * clock.h * stiffness
  if reach > b: b / reach else: 1.0'f32

func smoothingGain*(clock: StepClock; nuMax, bound, longStepBound: float32):
    float32 =
  ## D9's `g`: whole at or below a substep of ff 1, clamped past it so the
  ## smoothing's own reach per step never outgrows ff 1's, and clamped by
  ## `r/h` so `h*g` never passes the substep's own retention `r`.
  let b = longStepB(clock, bound, longStepBound)
  min(1.0'f32, min(
    (b / bound) / (clock.h * min(1.0'f32, 2.0'f32 * nuMax)),
    clock.r / clock.h))

const
  LOOP_GAIN_SEARCH_CEILING* = 10.0'f32
    ## kappa: caps theta_c at 5 from ff 19 at retention 0.88. Lifting it moved
    ## K 540 ff 30 motion under 1% (q2_k540_ff30_thetatrue.log).

func loopSpectralRadius(kc, alpha, rho: float64): float64 =
  ## D5's three-state density-lag map on (x, v, psi), direct stiffness 0:
  ## `psi' = alpha*psi + (1-alpha)*x; v' = rho*(v - kc*psi); x' = x + v'`.
  ## The largest root modulus of its characteristic cubic, via Durand-Kerner
  ## seeded at (0.4+0.9i)^k for k in 0..2.
  let m = [
    [1.0, rho, -rho * kc],
    [0.0, rho, -rho * kc],
    [1.0 - alpha, 0.0, alpha]]
  let tr = m[0][0] + m[1][1] + m[2][2]
  let c1 = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) +
    (m[0][0] * m[2][2] - m[0][2] * m[2][0]) +
    (m[1][1] * m[2][2] - m[1][2] * m[2][1])
  let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
  let c2 = -tr
  let c0 = -det
  let seed = complex64(0.4, 0.9)
  var z = [complex64(1.0, 0.0), seed, seed * seed]
  for _ in 0 ..< 500:
    var nz: array[3, Complex64]
    for i in 0 ..< 3:
      let f = z[i] * z[i] * z[i] + c2 * z[i] * z[i] + c1 * z[i] + c0
      var denom = complex64(1.0, 0.0)
      for j in 0 ..< 3:
        if j != i:
          denom = denom * (z[i] - z[j])
      nz[i] = z[i] - f / denom
    z = nz
  result = 0.0
  for zi in z:
    result = max(result, abs(zi))

func loopGainBound*(rho, alpha: float32): float32 =
  ## D5's theta_c: half the largest loop gain kappa at which the density-lag
  ## map's spectral radius holds at or under 1, bisected over kappa in
  ## [0, LOOP_GAIN_SEARCH_CEILING].
  let r = rho.float64
  let a = alpha.float64
  let ceiling = LOOP_GAIN_SEARCH_CEILING.float64
  if loopSpectralRadius(ceiling, a, r) <= 1.0 + 1e-9:
    return (ceiling / 2.0).float32
  var lo = 0.0
  var hi = ceiling
  for _ in 0 ..< 60:
    let mid = (lo + hi) / 2.0
    if loopSpectralRadius(mid, a, r) <= 1.0 + 1e-9:
      lo = mid
    else:
      hi = mid
  (lo / 2.0).float32

func loopLimit*(clock: StepClock; densityFactor, c, loopLimitFloor: float32):
    float32 =
  ## D5's s_C: 1 unless the loop's reach per substep, `ff*h*C/rho`, would
  ## carry the density-lag loop past its stable gain theta_c, where it falls
  ## to theta_c/reach or the floor, whichever holds more.
  let alpha = densityCarry(clock, densityFactor)
  let thetaC = loopGainBound(clock.retention, alpha)
  let reach = clock.ff * clock.forceGain * c / clock.retention
  if reach <= thetaC:
    1.0'f32
  else:
    max(thetaC / reach, loopLimitFloor * min(1.0'f32, 1.0'f32 / clock.ff))

func encodeStiffness*(slope, fixedPointScale: float32): int32 =
  int32(round(slope * fixedPointScale))

func decodeStiffness*(words: VelocityWords; invFixedPointScale: float32;
    coarseShift: int): float32 =
  ## The stiffness words decoded, as decodeVelocityWords decodes a velocity
  ## delta, minus the frame-factor multiply: `D` is a per-reference-frame
  ## quantity integrate itself multiplies by the frame factor inside
  ## `stepLimit`.
  (float32(words.fine) + float32(words.coarse) * float32(1 shl coarseShift)) *
    invFixedPointScale

type
  PairImpulseParams* = object
    ## What forces.wgsl's pair block reads past the force model's own shape.
    forceMultiplier*: float32
    pressureOnset*: float32
      ## rho_on, the crowd density the pressure starts at.
    pressureStiffness*: float32
    pressureImpulseMax*: float32
      ## q_max, the largest impulse one pair may exchange.
    fixedPointScale*: float32

  PairImpulse* = object
    ## One pair's contribution over one reference frame. The species force
    ## lands in each particle's own float register; the world pressure is
    ## quantized once for the pair, added to this particle and subtracted from
    ## the other, so the two sides cannot disagree.
    speciesOnThis*, speciesOnOther*: tuple[x, y: float32]
    pressureOnThis*: tuple[x, y: int32]

func pairImpulse*(params: PairImpulseParams;
    separationX, separationY, invDistance, normalizedDistance: float32;
    speciesMagnitudeOnThis, speciesMagnitudeOnOther: float32;
    crowdDensityThis, crowdDensityOther: float32): PairImpulse =
  ## forces.wgsl's pair block. `separation` runs from this particle to the
  ## other, minimum-imaged; each species magnitude is its force model's output
  ## with the receiving particle's crowding attenuation already applied.
  ##
  ## The species magnitude keeps forces.wgsl:289-290's grouping,
  ## `magnitude *= params.forceMultiplier * invDistance`, and the pressure is
  ## formed apart from that product: below the onset the species integers are
  ## the ones today's code writes, at every force multiplier.
  let forceOnThis = speciesMagnitudeOnThis * (params.forceMultiplier * invDistance)
  let forceOnOther = speciesMagnitudeOnOther * (params.forceMultiplier * invDistance)
  let magnitude = worldPressureMagnitude(
    crowdPressure(crowdDensityThis, params.pressureOnset),
    crowdPressure(crowdDensityOther, params.pressureOnset),
    normalizedDistance, params.pressureStiffness, params.pressureImpulseMax)
  PairImpulse(
    speciesOnThis: (x: separationX * forceOnThis, y: separationY * forceOnThis),
    speciesOnOther: (x: -separationX * forceOnOther,
      y: -separationY * forceOnOther),
    pressureOnThis: (
      x: encodeVelocityDelta(-magnitude * separationX * invDistance,
        params.fixedPointScale),
      y: encodeVelocityDelta(-magnitude * separationY * invDistance,
        params.fixedPointScale)))

func pressureOnOther*(impulse: PairImpulse): tuple[x, y: int32] =
  ## The other particle receives the integer this one received, negated.
  (x: -impulse.pressureOnThis.x, y: -impulse.pressureOnThis.y)
