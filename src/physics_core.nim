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


# ==============================================================================
# THE DENSITY CEILING
# ==============================================================================
#
# WHAT THE CEILING IS. A crowd tightens while attraction still beats the
# repulsion the crowd's own packing supplies. Attenuated attraction falls as the
# crowd densifies and packing repulsion rises, so the two cross at one density,
# and past it the crowd cannot tighten further. That crossing is what
# densityCeiling returns, in the units the density signal itself carries — the
# proximity-weighted neighbour sum forces.wgsl accumulates.
#
# WHAT THE CLAIM DOES NOT COVER. The spec requires this stated where the ceiling
# is defined, so it cannot be over-read:
#
#   - EQUILIBRIUM, NOT PER FRAME. The ceiling is where tightening stops, not a
#     bound the simulation holds every frame. Momentum carries particles past it
#     transiently; what the ceiling forbids is SETTLING tighter, never ARRIVING
#     tighter.
#   - THE SIGNAL IS SPECIES-BLIND (crowd density). forces.wgsl accumulates every
#     neighbour into the crowd channel the attenuation reads, so the per-cell
#     occupancy this bounds carries no species factor: a mixed blob and a
#     single-species blob of the same total density attenuate identically. The
#     COLONY channel beside it stays same-species and feeds the renderer; the
#     two are not interchangeable.
#   - IT BOUNDS WHAT ATTRACTION CONCENTRATES, AND NOTHING ELSE. The mouse, the
#     blast, and positive field tropism compress from outside the force law and
#     are outside its reach. The tropism side carries its own measured bound
#     (tests/test_field_core.nim, "Chemotactic Collapse Bound").
#   - IT BOUNDS A CELL, NOT A REGION. A region holds many cells, so global
#     clumping stays reachable; what is ruled out is the unbounded per-cell
#     concentration that degrades the neighbour sweep toward quadratic.
#
# Within that scope a finite ceiling bounds per-cell occupancy up to geometric
# constants, because grid cells are sized to the interaction radius
# (src/grid.nim) and the density weight spans that same radius.

const
  REPULSION_ZONE_END* = 1.0 / float(INV_03)
    ## Where repulsion ends and attraction begins, as a fraction of the
    ## interaction radius. Derived from INV_03 rather than written again, so the
    ## force law and this analysis cannot come to disagree about the boundary.
  CROWD_PACKING_CONSTANT* = 2.0 * PI / (3.0 * sqrt(3.0))
    ## Converts a nearest-neighbour separation into the density signal it
    ## produces: `density = CROWD_PACKING_CONSTANT / separation^2`, both in units
    ## of the interaction radius.
    ##
    ## DERIVED, NOT MEASURED. A crowd at areal number density `n` contributes
    ## `n * 2*PI * integral of u*(1-u) du over [0,1] = n*PI/3` to the signal,
    ## because accumulateDensity weights a neighbour by `1 - u`. Packing that
    ## crowd on a hexagonal lattice of spacing `s` gives `n = 2/(sqrt(3)*s^2)`,
    ## the tightest arrangement of equal disks in the plane. Composing the two
    ## gives this constant. A looser arrangement carries a smaller constant, so
    ## the separation this reports is the optimistic one and the occupancy bound
    ## it implies is the conservative one.
  DENSITY_CEILING_SEARCH_FLOOR = 1.0e-9
    ## The bisection's lower bracket. Packing repulsion diverges as density
    ## approaches zero (the separation grows without bound), so attraction wins
    ## here for every reachable parameter set.
  DENSITY_CEILING_SEARCH_ROOF = 1.0e12
    ## The bisection's upper bracket. A balance still positive here means no
    ## crossing exists and the ceiling is infinite — which happens only at
    ## crowding strength zero, the uncapped force law.
  DENSITY_CEILING_STEPS = 120
    ## Bisection steps. Halving the bracket 120 times takes it far below the
    ## precision a float64 can carry, so the result is converged rather than
    ## approximate.

func packingSeparation*(density: float): float =
  ## The nearest-neighbour separation a crowd holds at this density signal, as a
  ## fraction of the interaction radius. The inverse of CROWD_PACKING_CONSTANT's
  ## relation.
  sqrt(CROWD_PACKING_CONSTANT / density)

func crowdingBalance*(density, attraction, strength: float): float =
  ## Attenuated attraction minus the repulsion a crowd at this density supplies,
  ## both as force-law envelope magnitudes. Positive means the crowd still
  ## tightens; negative means repulsion has taken over.
  ##
  ## Force strength scales both terms and so appears in neither: the attenuation
  ## is a fraction of the attraction that survives `fMul`, which is exactly what
  ## keeps the crossing from drifting across the force-strength range.
  ##
  ## Strictly decreasing in density — the first term falls, the second rises —
  ## so the crossing is unique and bisection finds it.
  attraction / (1.0 + strength * ln(1.0 + density)) -
    (1.0 - packingSeparation(density) / REPULSION_ZONE_END)

func densityCeiling*(attr, fMul, strength: float): float =
  ## The density past which attenuated attraction cannot further tighten a
  ## crowd — read the scope block above before quoting this number.
  ##
  ## attr - the pair's attraction-matrix entry. A negative entry is repulsive
  ##        and the crowding term never touches it, so it enters here as no
  ##        attraction at all.
  ## fMul - the force strength. Zero removes every force
  ##        (`src/config_ranges.nim`), so attraction concentrates nothing
  ##        at any density and the ceiling degenerates to zero: vacuous rather
  ##        than wrong, exactly as described above.
  ## strength - the crowding strength. Zero reproduces calculateForce's
  ##            attraction unmodified, where nothing caps a strong enough
  ##            attraction and the ceiling is infinite.
  if fMul == 0.0:
    return 0.0
  let attraction = max(attr, 0.0)
  if crowdingBalance(DENSITY_CEILING_SEARCH_ROOF, attraction, strength) > 0.0:
    return Inf
  var tightening = DENSITY_CEILING_SEARCH_FLOOR
  var resisting = DENSITY_CEILING_SEARCH_ROOF
  for _ in 0 ..< DENSITY_CEILING_STEPS:
    let middle = 0.5 * (tightening + resisting)
    if crowdingBalance(middle, attraction, strength) > 0.0:
      tightening = middle
    else:
      resisting = middle
  0.5 * (tightening + resisting)


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
  ## The word a velocity-delta writer adds, WGSL's truncating `i32(value *
  ## FIXED_POINT_SCALE)`: forces.wgsl:297-298,377-378,
  ## forces-sph.wgsl:302-303, field-force.wgsl:81-84, lr-force.wgsl:88-91,
  ## body-force.wgsl:162-165.
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

func integrateVelocity*(velocity: tuple[x, y: float32];
    deltaFixed: tuple[x, y: int32];
    invFixedPointScale, frameFactor, friction, maxVelocity: float32):
    tuple[x, y: float32] =
  ## integrate.wgsl: the decoded delta added to the velocity, friction
  ## applied, then the soft cap postStepSpeed states for the speed.
  var newVelX = (velocity.x + decodeVelocityDelta(deltaFixed.x,
    invFixedPointScale, frameFactor)) * friction
  var newVelY = (velocity.y + decodeVelocityDelta(deltaFixed.y,
    invFixedPointScale, frameFactor)) * friction
  let speed = sqrt(newVelX * newVelX + newVelY * newVelY)
  let softCapThreshold = maxVelocity * 0.5'f32
  if speed > softCapThreshold and speed > 0.0'f32:
    let excess = speed - softCapThreshold
    let cappedSpeed = min(softCapThreshold + ln(1.0'f32 + excess), maxVelocity)
    let scale = cappedSpeed / speed
    newVelX *= scale
    newVelY *= scale
  (x: newVelX, y: newVelY)

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
