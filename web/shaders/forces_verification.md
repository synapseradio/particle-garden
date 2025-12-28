# Force Computation Shader Verification

This document traces `forces.wgsl` against `src/physics_wasm.nim` to verify exact algorithm parity.

## Algorithm Flow Mapping

| Step | WASM (physics_wasm.nim) | WGSL (forces.wgsl) | Status |
|------|-------------------------|-------------------|--------|
| 1. Bounds check | Lines 96-97 | Lines 72-75 | ✓ Match |
| 2. Buffer selection | Lines 100-103 | Lines 77-88 | ✓ Match |
| 3. Constant precomputation | Lines 105-118 | Lines 90-98 | ✓ Match |
| 4. Force initialization | Lines 127-129 | Lines 100-102 | ✓ Match |
| 5. Grid cell lookup | Lines 131-136 | Lines 104-109 | ✓ Match |
| 6. 3x3 neighborhood iteration | Lines 138-161 | Lines 111-150 | ✓ Match |
| 7. Cell validation | Lines 164-171 | Lines 152-160 | ✓ Match |
| 8. Particle iteration | Lines 175-211 | Lines 163-213 | ✓ Match |
| 9. Mouse attraction | Lines 214-228 | Lines 216-237 | ✓ Match |
| 10. Output write | Lines 231-233 | Lines 240-242 | ✓ Match |

## Critical Constants Verification

| Constant | WASM Value | WGSL Value | Match |
|----------|-----------|-----------|-------|
| MAX_SPECIES | 6 | 6u | ✓ |
| MIN_DIST_SQ | 4.0 | 4.0 | ✓ |
| INV_03 | 1.0 / 0.3 | 3.333333333 | ✓ |
| INV_07 | 1.0 / 0.7 | 1.428571429 | ✓ |
| MD2_LIMIT | 90000.0 | 90000.0 | ✓ |

## Force Calculation Parity

### Repulsion Region (r < 0.3)
**WASM (line 202):**
```nim
f = r * inv03 - 1.0f
```

**WGSL (line 196):**
```wgsl
f = r * INV_03 - 1.0;
```
✓ Identical

### Attraction/Repulsion Region (r >= 0.3)
**WASM (lines 204-206):**
```nim
let t = 2.0f * r - 1.3f
let abs_t = if t < 0.0f: -t else: t
f = attr * (1.0f - abs_t * inv07)
```

**WGSL (lines 199-201):**
```wgsl
let t = 2.0 * r - 1.3;
let abs_t = abs(t);
f = attr * (1.0 - abs_t * INV_07);
```
✓ Identical (using built-in `abs()`)

### Force Application
**WASM (lines 209-211):**
```nim
f = f * fMul * invD
fx += dx_val * f
fy += dy_val * f
```

**WGSL (lines 204-206):**
```wgsl
f = f * params.fMul * invD;
fx += dx_val * f;
fy += dy_val * f;
```
✓ Identical

## Toroidal Wrapping Verification

### Cell-Level Wrapping
**WASM (lines 142-147):**
```nim
if ny < 0:
  ny += gridH
  wrapY = -H
elif ny >= gridH:
  ny -= gridH
  wrapY = H
```

**WGSL (lines 117-126):**
```wgsl
if (ny < 0) {
  ny += i32(params.gridH);
  wrapY = -params.H;
} else if (ny >= i32(params.gridH)) {
  ny -= i32(params.gridH);
  wrapY = params.H;
}
```
✓ Identical

### Mouse Distance Wrapping
**WASM (lines 218-221):**
```nim
if mdx > halfW: mdx -= W
elif mdx < -halfW: mdx += W
if mdy > halfH: mdy -= H
elif mdy < -halfH: mdy += H
```

**WGSL (lines 221-232):**
```wgsl
if (mdx > halfW) {
  mdx -= params.W;
} else if (mdx < -halfW) {
  mdx += params.W;
}
// [same for mdy]
```
✓ Identical

## Density Accumulation

**WASM (lines 193-195):**
```nim
if sj == si:
  dens += 1.0f - r
```

**WGSL (lines 189-191):**
```wgsl
if (sj == si) {
  dens += 1.0 - r;
}
```
✓ Identical

## Distance Clamping

**WASM (line 186):**
```nim
let d2Clamped = if d2 < minDistSq: minDistSq else: d2
```

**WGSL (line 181):**
```wgsl
let d2Clamped = max(d2, MIN_DIST_SQ);
```
✓ Equivalent (using built-in `max()`)

## Mouse Attraction Formula

**WASM (lines 224-228):**
```nim
let md2 = mdx * mdx + mdy * mdy
if md2 > 0.0f and md2 < md2Limit:
  let md = sqrt(md2)
  let mf = 0.5f * (1.0f - md / 300.0f) / md
  fx += mdx * mf
  fy += mdy * mf
```

**WGSL (lines 234-239):**
```wgsl
let md2 = mdx * mdx + mdy * mdy;
if (md2 > 0.0 && md2 < MD2_LIMIT) {
  let md = sqrt(md2);
  let mf = 0.5 * (1.0 - md / 300.0) / md;
  fx += mdx * mf;
  fy += mdy * mf;
}
```
✓ Identical

## Buffer Layout Compatibility

The shader assumes the following buffer bindings:

| Binding | Buffer | Type | WASM Equivalent |
|---------|--------|------|-----------------|
| @binding(1) | particlesA | storage, read | pxA, pyA, species_A arrays |
| @binding(2) | particlesB | storage, read | pxB, pyB, species_B arrays |
| @binding(3) | sortedIndices | storage, read | Grid-sorted particle indices |
| @binding(4) | cellOffsets | storage, read | gridOffsets array |
| @binding(5) | cellCounts | storage, read | gridCounts array |
| @binding(6) | matrix | storage, read | matrix array (6x6 flat) |
| @binding(7) | vxDelta | storage, read_write | vxDelta array |
| @binding(8) | vyDelta | storage, read_write | vyDelta array |
| @binding(9) | densityOut | storage, read_write | density array |

**Note:** The WASM implementation uses flat parallel arrays (px[], py[], species[]) while the shader uses a struct-of-arrays approach via the `Particle` struct. Both are functionally equivalent - the shader simply groups the arrays conceptually.

## Performance Considerations

### Thread Mapping
- **Workgroup size:** 64 threads (optimal for most GPUs)
- **Dispatch:** `ceil(particleCount / 64)` workgroups
- **Memory access:** Coalesced reads from sorted indices

### Expected Bottlenecks
1. **Random access to sorted indices** - scattered reads from neighbor cells
2. **Matrix lookups** - 6x6 matrix fits in cache, minimal overhead
3. **Write contention** - none (one particle writes to unique output indices)

### Optimization Opportunities
1. **Shared memory for grid cells** - load cell particles into workgroup shared memory
2. **Early exit** - skip empty cells without iterating
3. **Distance culling** - bounding box check before sqrt()

## Numerical Precision Notes

- All floats use `f32` (32-bit) matching WASM `float32`
- Constants use sufficient precision (e.g., INV_03 = 3.333333333)
- No precision loss expected vs WASM implementation

## Testing Checklist

- [ ] Shader compiles without errors
- [ ] Buffer bindings match CPU-side layout
- [ ] Uniform buffer size matches struct
- [ ] Force output matches WASM for identical inputs
- [ ] Toroidal wrap produces continuous force field
- [ ] Mouse attraction works at world edges
- [ ] Density values match WASM output
- [ ] Performance meets or exceeds WASM (expected 2-10x speedup)

## Known Differences

**None** - This is a faithful 1:1 port of the WASM algorithm to WGSL.

The only architectural difference is that the WASM version processes particle ranges (for multi-threading), while the GPU shader processes one particle per thread. The core physics computation is identical.
