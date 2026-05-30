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
# Note: WebGPU compute shaders (forces.wgsl) use equivalent GPU implementations.
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

func calculateForce*(r, attr, fMul, invD: float32): float32 =
  ## Calculate force magnitude between two particles.
  ##
  ## r - Normalized distance in [0, 1] range (d / rMax)
  ## attr - Attraction value from matrix (-1 to 1 typically)
  ## fMul - Force multiplier (scales overall force strength)
  ## invD - Inverse of actual distance (1 / d)
  ##
  ## Returns force magnitude. Positive = attraction, negative = repulsion.
  ## The returned value should be multiplied by the displacement vector.
  ##
  ## Physics:
  ##   - r < 0.3: Repulsion zone. Force = (r/0.3 - 1) * fMul / d
  ##   - r >= 0.3: Attraction zone. Force = attr * (1 - |2r - 1.3| / 0.7) * fMul / d
  ##
  var f: float32

  if r < 0.3f:
    # Repulsion: linear ramp from -1 at r=0 to 0 at r=0.3
    f = r * INV_03 - 1.0f
  else:
    # Attraction: triangular envelope centered at r=0.65
    let t = 2.0f * r - 1.3f
    let absT = if t < 0.0f: -t else: t
    f = attr * (1.0f - absT * INV_07)

  result = f * fMul * invD


func calculateForceMagnitude*(r, attr: float32): float32 =
  ## Calculate raw force magnitude without scaling.
  ##
  ## Useful for testing the force curve shape independent of fMul and invD.
  ## Returns the unscaled force value.
  ##
  if r < 0.3f:
    result = r * INV_03 - 1.0f
  else:
    let t = 2.0f * r - 1.3f
    let absT = if t < 0.0f: -t else: t
    result = attr * (1.0f - absT * INV_07)


# ==============================================================================
# DISTANCE NORMALIZATION
# ==============================================================================

func normalizeDistance*(dx, dy, rMax: float32; minDistSq: float32 = MIN_DIST_SQ): tuple[
    r: float32, invD: float32, valid: bool] =
  ## Normalize displacement vector to interaction range.
  ##
  ## dx, dy - Displacement vector components
  ## rMax - Maximum interaction radius
  ## minDistSq - Minimum distance squared (clamped to avoid division issues)
  ##
  ## Returns:
  ##   r - Normalized distance in [0, 1] range
  ##   invD - Inverse of clamped distance (1 / d)
  ##   valid - True if particles are within interaction range (0 < d < rMax)
  ##
  let d2 = dx * dx + dy * dy
  let rMaxSq = rMax * rMax

  if d2 <= 0.0f or d2 >= rMaxSq:
    # Outside interaction range or same particle
    return (r: 0.0f, invD: 0.0f, valid: false)

  # Clamp minimum distance to avoid extreme forces
  let d2Clamped = if d2 < minDistSq: minDistSq else: d2
  let d = sqrt(d2Clamped)
  let invD = 1.0f / d
  let r = d / rMax

  result = (r: r, invD: invD, valid: true)


# ==============================================================================
# DENSITY ACCUMULATION
# ==============================================================================

func accumulateDensity*(r: float32; sameSpecies: bool): float32 =
  ## Calculate density contribution from a neighbor particle.
  ##
  ## r - Normalized distance in [0, 1] range
  ## sameSpecies - True if both particles are the same species
  ##
  ## Returns density contribution. Only same-species particles contribute.
  ## Contribution falls off linearly: (1 - r) at distance 0, 0 at distance rMax.
  ##
  if sameSpecies:
    result = 1.0f - r
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
