# ==============================================================================
# PARTICLE GARDEN - PHYSICS CORE (Pure Mathematical Functions)
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
# the shader has something to be wrong against. Nothing in src/ imports this
# module, and that is expected.
#
# ==============================================================================

import std/math

# ==============================================================================
# CONSTANTS
# ==============================================================================

const
  INV_03* = 1.0f / 0.3f  # Inverse of repulsion threshold
  INV_07* = 1.0f / 0.7f  # Inverse of attraction envelope width
  MIN_DIST_SQ* = 4.0f    # Minimum distance squared (2.0^2) to avoid division issues

# ==============================================================================
# FORCE CALCULATION
# ==============================================================================

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
  ## at the other (design C2).
  ##
  ## density - the receiving particle's smoothed local density, non-negative by
  ##           construction: it is a sum of non-negative proximity weights fed
  ##           through an exponential moving average of itself.
  ## strength - the crowding strength parameter. Zero returns 1.0 at every
  ##            density, which is exactly today's force law.
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
  ## entry. The repulsion zone keeps today's force at every density, and so does
  ## an attraction-zone pair whose matrix entry is negative — that contribution
  ## pushes the pair apart, and damping it would partly cancel the cap the term
  ## exists to serve (design C1).
  ##
  ## The attenuation multiplies the force AFTER `fMul`, so the result at force
  ## strength k is k times the result at force strength 1. Design C0 requires
  ## that: expressed as an absolute force instead, the term would mean something
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
# (src/grid.nim:61) and the density weight spans that same radius.

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
    ## crowding strength zero, today's uncapped force law.
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
  ## is a fraction of the attraction that survives `fMul` (design C0), which is
  ## exactly what keeps the crossing from drifting across the force-strength
  ## range.
  ##
  ## Strictly decreasing in density — the first term falls, the second rises —
  ## so the crossing is unique and bisection finds it.
  attraction / (1.0 + strength * ln(1.0 + density)) -
    (1.0 - packingSeparation(density) / REPULSION_ZONE_END)

func densityCeiling*(attr, fMul, strength: float): float =
  ## The density past which attenuated attraction can no longer tighten a
  ## crowd — read the scope block above before quoting this number.
  ##
  ## attr - the pair's attraction-matrix entry. A negative entry is repulsive
  ##        and the crowding term never touches it (design C1), so it enters
  ##        here as no attraction at all.
  ## fMul - the force strength. Zero removes every force
  ##        (`src/config_ranges.nim:36-40`), so attraction concentrates nothing
  ##        at any density and the ceiling degenerates to zero: vacuous rather
  ##        than wrong, exactly as design C0 describes.
  ## strength - the crowding strength. Zero is today's force law, where nothing
  ##            caps a strong enough attraction and the ceiling is infinite.
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


# ==============================================================================
# DISTANCE NORMALIZATION
# ==============================================================================

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


# ==============================================================================
# DENSITY ACCUMULATION
# ==============================================================================

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


# ==============================================================================
# TOROIDAL WRAPPING
# ==============================================================================

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


# ==============================================================================
# CELL INDEX COMPUTATION
# ==============================================================================

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

  # Clamp to valid range
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
  ## Convert cell coordinates to linear cell index.
  ##
  ## cx, cy - Cell coordinates
  ## gridW - Grid width
  ##
  ## Returns linear index: cy * gridW + cx
  ##
  result = cy * gridW + cx


# ==============================================================================
# NEIGHBOR CELL ITERATION
# ==============================================================================

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

  # Wrap X
  if nx < 0:
    nx += gridW
    wrapX = -canvasW
  elif nx >= gridW:
    nx -= gridW
    wrapX = canvasW

  # Wrap Y
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
# MODEL 1 branch in the neighbour loop). calculateForce above keeps the fixed
# 0.3/1.3/0.7 curve that predates the models. Neither model multiplies by the
# force multiplier or the inverse distance here — the shader applies
# `* params.forceMultiplier * invDistance` after the branch, and callers of
# these mirrors do the same.

func polynomialForce*(normalizedDist, attraction, repulsionEnd,
    attractionPeak, attenuation: float32): float32 =
  ## forces.wgsl MODEL 0. Repulsion over [0, repulsionEnd] is the Hermite ramp
  ## -1 + 3t² - 2t³ in the zone-normalized t, so contact costs -1 and the ramp
  ## lands at 0 with zero slope. Attraction over [repulsionEnd, 1] is a squared
  ## bump peaking at attractionPeak scaled by 4, and the crowding attenuation
  ## multiplies it only when the matrix entry attracts (a negative entry pushes
  ## apart, and damping it would fight the cap — design C1). Zone degeneracy
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

func postStepSpeed*(speed, friction, maxVelocity: float32): float32 =
  ## integrate.wgsl:120-137. Friction multiplies the post-delta velocity (it is
  ## a retention factor, not a drag), then speeds above half maxVelocity are
  ## compressed as threshold + ln(1 + excess) and hard-capped at maxVelocity.
  let damped = speed * friction
  let softCapThreshold = maxVelocity * 0.5'f32
  if damped > softCapThreshold and damped > 0.0'f32:
    min(softCapThreshold + ln(1.0'f32 + damped - softCapThreshold),
      maxVelocity)
  else:
    damped
