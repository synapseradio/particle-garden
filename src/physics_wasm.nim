# =============================================================================
# PARTICLE PHYSICS - WASM MODULE (Zero-Copy Architecture)
# =============================================================================
#
# Spatial grid-accelerated O(n×k) particle simulation compiled to WebAssembly.
# Uses unified shared memory - WASM accesses particle data directly at known offsets.
#
# ZERO-COPY: No data transfers between JS and WASM. Both access the same memory.
#
# Memory layout (must match config.js MEMORY_LAYOUT):
#   Offset 1MB (0x100000): Particle data starts
#   - pxA, pyA, vxA, vyA, denA, speciesA (buffer set A)
#   - pxB, pyB, vxB, vyB, denB, speciesB (buffer set B)
#   - vxDelta, vyDelta (velocity deltas)
#   - gridCounts, gridOffsets (spatial grid)
#   - matrix (6x6 attraction matrix)
#
# Compile:
#   nim c --backend:c --nimcache:./nimcache_wasm --compileOnly -d:emscripten -d:release src/physics_wasm.nim
#   nimble wasm
# =============================================================================

import std/math

const
  MAX_SPECIES* = 6
  MAX_PARTICLES* = 64000
  MAX_GRID* = 256

  # Memory layout offsets (must match config.js MEMORY_LAYOUT)
  WASM_DATA_OFFSET = 1024 * 1024  # 1MB
  FLOAT_SIZE = MAX_PARTICLES * 4
  UINT8_SIZE = MAX_PARTICLES
  GRID_CELLS = MAX_GRID * MAX_GRID

# Compute offsets at compile time
const
  PX_A_OFFSET = WASM_DATA_OFFSET
  PY_A_OFFSET = PX_A_OFFSET + FLOAT_SIZE
  VX_A_OFFSET = PY_A_OFFSET + FLOAT_SIZE
  VY_A_OFFSET = VX_A_OFFSET + FLOAT_SIZE
  DEN_A_OFFSET = VY_A_OFFSET + FLOAT_SIZE
  SPECIES_A_OFFSET = DEN_A_OFFSET + FLOAT_SIZE

  PX_B_OFFSET = ((SPECIES_A_OFFSET + UINT8_SIZE + 3) and not 3)
  PY_B_OFFSET = PX_B_OFFSET + FLOAT_SIZE
  VX_B_OFFSET = PY_B_OFFSET + FLOAT_SIZE
  VY_B_OFFSET = VX_B_OFFSET + FLOAT_SIZE
  DEN_B_OFFSET = VY_B_OFFSET + FLOAT_SIZE
  SPECIES_B_OFFSET = DEN_B_OFFSET + FLOAT_SIZE

  VX_DELTA_OFFSET = ((SPECIES_B_OFFSET + UINT8_SIZE + 3) and not 3)
  VY_DELTA_OFFSET = VX_DELTA_OFFSET + FLOAT_SIZE

  GRID_COUNTS_OFFSET = VY_DELTA_OFFSET + FLOAT_SIZE
  GRID_OFFSETS_OFFSET = ((GRID_COUNTS_OFFSET + GRID_CELLS * 2 + 3) and not 3)

  MATRIX_OFFSET = GRID_OFFSETS_OFFSET + GRID_CELLS * 4

# -----------------------------------------------------------------------------
# Memory access helpers
# -----------------------------------------------------------------------------

template pxA(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](PX_A_OFFSET)
template pyA(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](PY_A_OFFSET)
template denA(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](DEN_A_OFFSET)
template speciesA(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](SPECIES_A_OFFSET)

template pxB(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](PX_B_OFFSET)
template pyB(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](PY_B_OFFSET)
template denB(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](DEN_B_OFFSET)
template speciesB(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](SPECIES_B_OFFSET)

template vxDelta(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](VX_DELTA_OFFSET)
template vyDelta(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](VY_DELTA_OFFSET)

template gridCounts(): ptr UncheckedArray[uint16] = cast[ptr UncheckedArray[uint16]](GRID_COUNTS_OFFSET)
template gridOffsets(): ptr UncheckedArray[uint32] = cast[ptr UncheckedArray[uint32]](GRID_OFFSETS_OFFSET)

template matrix(): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](MATRIX_OFFSET)

# -----------------------------------------------------------------------------
# Range-based physics step for parallel workers (ZERO-COPY VERSION)
# -----------------------------------------------------------------------------
# Each worker processes particles [startIdx, endIdx) and writes force deltas.
# All data is accessed directly from shared memory - no uploads/downloads.
#
proc physicsStepRange*(
  startIdx, endIdx, n: int32,
  bufferParity: int32,  # 0 = read from A, 1 = read from B
  dt, W, H, rMax, fMul: float32,
  gridW, gridH: int32,
  mouseX, mouseY, mouseDown, mouseRightDown: float32
) {.exportc, cdecl.} =

  if startIdx >= endIdx or n <= 0 or gridW <= 0 or gridH <= 0:
    return

  # Select source buffer based on parity
  let px = if bufferParity == 0: pxA() else: pxB()
  let py = if bufferParity == 0: pyA() else: pyB()
  let species = if bufferParity == 0: speciesA() else: speciesB()
  let density = if bufferParity == 0: denA() else: denB()

  let rMaxSq = rMax * rMax
  let invR = 1.0f / rMax
  let halfW = W * 0.5f
  let halfH = H * 0.5f
  let md2Limit = 90000.0f

  # Precomputed constants for inner loop optimization
  let inv03 = 1.0f / 0.3f      # For force calculation
  let inv07 = 1.0f / 0.7f      # For force calculation
  let minDistSq = 4.0f         # Minimum distance squared (2.0²)

  let invCellW = float32(gridW) / W
  let invCellH = float32(gridH) / H
  let numCells = gridW * gridH

  # Process only particles in assigned range
  for i in startIdx ..< endIdx:
    let xi = px[i]
    let yi = py[i]
    let si = int32(species[i])
    let rowOffset = si * MAX_SPECIES

    var fx = 0.0f
    var fy = 0.0f
    var dens = 0.0f

    var cx = int32(xi * invCellW)
    var cy = int32(yi * invCellH)
    if cx < 0: cx = 0
    elif cx >= gridW: cx = gridW - 1
    if cy < 0: cy = 0
    elif cy >= gridH: cy = gridH - 1

    for dy in -1 .. 1:
      var ny = cy + dy
      var wrapY = 0.0f

      if ny < 0:
        ny += gridH
        wrapY = -H
      elif ny >= gridH:
        ny -= gridH
        wrapY = H

      let nyIdx = ny * gridW

      for dx in -1 .. 1:
        var nx = cx + dx
        var wrapX = 0.0f

        if nx < 0:
          nx += gridW
          wrapX = -W
        elif nx >= gridW:
          nx -= gridW
          wrapX = W

        let cell = nyIdx + nx

        if cell < 0 or cell >= numCells:
          continue

        let start = int32(gridOffsets()[cell])
        let count = int32(gridCounts()[cell])

        if start < 0 or start + count > n:
          continue

        let fin = start + count

        for j in start ..< fin:
          let xj = px[j]
          let yj = py[j]

          let dx_val = (xj + wrapX) - xi
          let dy_val = (yj + wrapY) - yi

          let d2 = dx_val * dx_val + dy_val * dy_val

          if d2 > 0.0f and d2 < rMaxSq:
            # Clamp minimum distance squared to avoid division issues
            let d2Clamped = if d2 < minDistSq: minDistSq else: d2
            let d = sqrt(d2Clamped)
            let invD = 1.0f / d
            let r = d * invR

            let sj = int32(species[j])

            # Density accumulation (same species only)
            if sj == si:
              dens += 1.0f - r

            let attr = matrix()[rowOffset + sj]

            # Force calculation with precomputed constants
            var f: float32
            if r < 0.3f:
              f = r * inv03 - 1.0f
            else:
              let t = 2.0f * r - 1.3f
              let abs_t = if t < 0.0f: -t else: t
              f = attr * (1.0f - abs_t * inv07)

            # Use precomputed inverse distance
            f = f * fMul * invD
            fx += dx_val * f
            fy += dy_val * f

    # Mouse attraction/repulsion
    if mouseDown > 0.5f or mouseRightDown > 0.5f:
      var mdx = mouseX - xi
      var mdy = mouseY - yi

      if mdx > halfW: mdx -= W
      elif mdx < -halfW: mdx += W
      if mdy > halfH: mdy -= H
      elif mdy < -halfH: mdy += H

      let md2 = mdx * mdx + mdy * mdy
      if md2 > 0.0f and md2 < md2Limit:
        let md = sqrt(md2)
        let mf = 50.0f * (1.0f - md / 300.0f) / md

        # Combine left (attraction) and right (repulsion)
        var sign = 0.0f
        if mouseDown > 0.5f: sign += 1.0f
        if mouseRightDown > 0.5f: sign -= 1.0f

        fx += mdx * mf * sign
        fy += mdy * mf * sign

    # Write velocity DELTAS directly to shared memory
    vxDelta()[i] = fx * dt
    vyDelta()[i] = fy * dt
    density[i] = dens
