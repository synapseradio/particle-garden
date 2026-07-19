# Particle Garden Test Suite

Comprehensive behavioral test suite for the particle-garden simulation engine.

## Philosophy: Behavioral Testing

This test suite follows **behavioral testing principles** — we test *what code promises*, not *how it implements promises*.

### What This Means

**Good behavioral test:**
```nim
test "particle stride is exactly 32 bytes":
  # CONTRACT: GPU shaders expect 32-byte aligned particles
  check PARTICLE_STRIDE == 32
```

**Poor implementation test:**
```nim
test "computeMemoryOffsets adds padding correctly":
  # ❌ Tests internal mechanics, not external contract
  check someInternalVariable == expectedValue
```

### Why Behavioral Testing?

1. **Tests survive refactoring** — Change implementation without breaking tests
2. **Tests document contracts** — Clear what code promises to callers
3. **Tests catch real bugs** — Verify behavior users/systems depend on
4. **Tests guide design** — Forces thinking about APIs and invariants

## Test Organization

### Test Files

| File | Purpose | Compilation |
|------|---------|-------------|
| `test_all.nim` | Entry point that imports every test module | Native (`nim c`) |
| `test_memory_layout.nim` | Memory layout constants, alignment, AoS structure, `align4` | Native |
| `test_grid.nim` | Pure grid algorithms (cell indexing, prefix sums, offset validation) | Native |
| `test_physics.nim` | Pure physics math (forces, wrapping, density, neighbor cells) | Native |
| `test_config.nim` | Configuration constraint invariants derived from the layout limits | Native |
| `test_gpu_types.nim` | GPU struct layout helpers (type sizes, field offsets, accessors) | Native |
| `test_shader_config.nim` | Shader workgroup-size and tunable-constant accessors | Native |
| `test_observable.nim` | Observable reactive primitive (subscribe, set, dispose) | Native |
| `test_input.nim` | Input handling logic | Native |
| `test_slider.nim` | Slider component plus simulation and render state | Native |
| `test_matrix.nim` | Attraction matrix state plus cell and species colors | Native |
| `test_stats.nim` | Performance stats formatters and immutable updates | Native |
| `test_app_state.nim` | App runtime and profiling-average accumulators | Native |
| `test_palette.nim` | HSL-to-RGB conversion, palette generation schemes, flat encoding | Native |

Every test module compiles natively with `nim c`. There is no JS-backend test target: the browser-dependent modules (FFI bindings, WebGPU, DOM) are verified only by the application build itself.

### Test Architecture

```
test_all.nim (runner)
    │
    ├── test_memory_layout.nim  → memory_layout.nim (constants, offsets, align4)
    ├── test_config.nim         → memory_layout.nim (constraint invariants)
    ├── test_grid.nim           → grid_core.nim (grid math, offset validation)
    ├── test_physics.nim        → physics_core.nim (forces, wrapping, neighbors)
    ├── test_gpu_types.nim      → gpu_types.nim (struct layout helpers)
    ├── test_shader_config.nim  → shader_config.nim (workgroup/tuning accessors)
    ├── test_observable.nim     → ui/core/observable.nim
    ├── test_input.nim          → ui/input (input logic)
    ├── test_slider.nim         → ui/controls/slider.nim, ui/state (sim/render)
    ├── test_matrix.nim         → ui/state/matrix_state.nim (matrix, colors)
    ├── test_stats.nim          → ui/stats/stats_view.nim (formatters, updates)
    ├── test_app_state.nim      → ui/state/app_state.nim (profiling averages)
    └── test_palette.nim        → palette.nim (HSL conversion, palette generation)
```

## Running Tests

### All Tests (Native)
```bash
nimble test
```

This compiles `tests/test_all.nim` with the native backend and runs the whole suite. The same run also happens in CI before any release is built, so a failing test blocks the release.

## Test Categories

### 1. Memory Layout Tests (`test_memory_layout.nim`)

**What we test:**
- **AoS Particle Structure Contract** — 32-byte stride, field offsets, natural alignment
- **Buffer Alignment Invariants** — All buffers 4-byte aligned for TypedArray compatibility
- **Buffer Non-Overlap Invariant** — Buffers don't corrupt each other
- **Memory Size Constraints** — Fits within reasonable browser memory limits
- **Constant Exports Contract** — Named exports match computed offsets
- **Legacy SoA Compatibility** — Old offset names map correctly to AoS structure

**Key behaviors verified:**
- GPU shaders can safely read AoS particle data (32-byte alignment)
- TypedArray views won't throw alignment errors (4-byte boundaries)
- Buffers won't overwrite each other (non-overlap)
- Configuration fits in browser memory limits

**Compile-time assertions:**
```nim
static:
  doAssert PARTICLE_STRIDE == 32
  doAssert OFFSETS.totalSize < 64 * 1024 * 1024
```

### 2. Grid Core Tests (`test_grid_core.nim`)

**What we test:**
- **Grid Dimension Computation** — Canvas → grid cell mapping
- **Cell Index Calculations** — Position ↔ cell index conversions
- **Prefix Sum Algorithm** — Particle sorting offset computation
- **Grid Validation Invariants** — Bounds checking, consistency checks
- **Toroidal Wrapping** — Neighbor lookup across periodic boundaries

**Key behaviors verified:**
- All particles map to valid grid cells (no out-of-bounds access)
- Prefix sums correctly partition sorted particle buffer
- Toroidal topology wraps correctly (particles interact across edges)
- Grid computation handles edge cases (tiny canvases, huge canvases, non-divisible sizes)

**Pure function testing:**
All functions are pure (no side effects), making tests deterministic and fast.

### 3. Physics Core Tests (`test_physics_core.nim`)

**What we test:**
- **Force Calculation Contract** — Repulsion/attraction zones, force curves
- **Distance Normalization** — Range validation, clamping behavior
- **Density Accumulation** — Same-species density contribution
- **Toroidal Wrapping** — Position and delta wrapping for periodic boundaries
- **Cell Coordinate Mapping** — Physics position → grid cell conversion

**Key behaviors verified:**
- Force magnitude matches physics specification (repulsion at r<0.3, attraction peak at r≈0.65)
- Distance clamping prevents extreme forces (numerical stability)
- Toroidal wrapping takes shortest path (correct neighbor interactions)
- Same-species density accumulates, cross-species doesn't

**Test precision:**
```nim
const EPSILON_TIGHT = 1e-5f
```
Tight epsilon for float32 comparisons ensures accurate force calculations.

## What We Don't Test (And Why)

### Browser-Dependent Code

**Not tested natively:**
- `typed_arrays.nim` — Requires JavaScript runtime (TypedArray, ArrayBuffer APIs)
- `webgpu_*.nim` — Requires WebGPU implementation
- `ui.nim` — Requires DOM APIs

**Why:**
These modules are thin FFI bindings to browser APIs. Testing them requires:
1. Browser environment (not available in native compilation)
2. Integration tests (would be slow, brittle)
3. Mocking browser APIs (defeats the purpose)

**Mitigation:**
- The application build (`nimble app`) compiles the JS frontend, so a broken FFI binding fails the build
- Manual browser testing covers integration
- The pure-logic modules are thoroughly tested natively, and behavior is extracted into pure modules wherever it can be separated from the browser surface

### Implementation Details

We deliberately don't test:
- Internal helper functions (not part of public API)
- Private calculation intermediates (coupling to implementation)
- Performance characteristics (separate benchmarking needed)
- Rendering output (visual testing territory)

## Test Conventions

### Test Naming

Test names are **specification sentences**, not code descriptions:

**Good:**
```nim
test "particle stride is exactly 32 bytes"
test "wraps positive delta across boundary"
test "rejects distance beyond rMax"
```

**Bad:**
```nim
test "testParticleStride"
test "wrapDelta_positive"
test "normalizeDistance_outOfRange"
```

### Test Structure

```nim
suite "Feature Category":
  test "specific behavior being verified":
    # SETUP: Arrange inputs
    let input = createInput()

    # EXECUTE: Call function
    let result = functionUnderTest(input)

    # VERIFY: Assert behavior
    check result == expectedBehavior
```

### Comments in Tests

Comments explain **contracts and invariants**, not code mechanics:

**Good:**
```nim
check PARTICLE_STRIDE == 32
# CONTRACT: GPU shaders expect 32-byte aligned particles
# WHY: Two particles per 64-byte cache line
```

**Bad:**
```nim
# Check if particle stride equals 32
check PARTICLE_STRIDE == 32
```

## Compile-Time vs Runtime Tests

### Static Assertions (Compile-Time)

Defined in source modules, verified at build time:
```nim
static:
  assert PARTICLE_STRIDE == 32, "GPU expects 32-byte particles"
  assert OFFSETS.totalSize < 64 * 1024 * 1024
```

**Purpose:** Catch configuration errors before code runs

### Runtime Tests

Defined in test modules, executed via `nimble test`:
```nim
test "particle stride is exactly 32 bytes":
  check PARTICLE_STRIDE == 32
```

**Purpose:** Verify behavior with actual inputs, edge cases, and interactions

## Coverage Strategy

### What We Cover Thoroughly

1. **Pure algorithms** — Grid, physics, memory layout calculations
2. **Data structure invariants** — Alignment, non-overlap, bounds
3. **Edge cases** — Boundaries, wrapping, clamping, empty/full buffers
4. **Contracts** — Public API promises, GPU/CPU compatibility requirements

### What We Cover Lightly

1. **FFI bindings** — Compilation verification only
2. **Browser integration** — Manual testing
3. **UI interactions** — End-to-end testing

### What We Don't Cover

1. **Visual output** — Requires visual testing tools
2. **Performance** — Requires benchmarking suite
3. **Multi-threaded behavior** — Would require complex test harness

## Adding New Tests

### Checklist for New Test Modules

1. **Identify pure, testable code**
   - Look for functions with no FFI, no side effects
   - Extract pure logic if mixed with browser code

2. **Create test file in `tests/` directory**
   ```nim
   # tests/test_my_module.nim
   import std/unittest
   import ../src/my_module
   ```

3. **Export a marker constant for test_all.nim**
   ```nim
   const MY_MODULE_TESTS_LOADED* = true
   ```

4. **Add to test_all.nim**
   ```nim
   import test_my_module
   static:
     discard test_my_module.MY_MODULE_TESTS_LOADED
   ```

5. **Write behavioral tests**
   - Name tests as specification sentences
   - Comment with contracts and invariants
   - Test behaviors, not implementation

6. **Verify tests pass**
   ```bash
   nimble test
   ```

### Example: Testing a New Module

**Module:** `src/collision_detector.nim`

**Pure functions to test:**
```nim
proc detectCollision*(p1, p2: Particle, threshold: float): bool
proc calculateOverlap*(p1, p2: Particle): float
```

**Test file:** `tests/test_collision_detector.nim`

```nim
import std/unittest
import ../src/collision_detector
import ../src/memory_layout  # For Particle type

const COLLISION_DETECTOR_TESTS_LOADED* = true

suite "Collision Detection Contract":
  test "detects collision when particles overlap":
    # CONTRACT: Returns true when distance < threshold
    let p1 = Particle(px: 0.0, py: 0.0, ...)
    let p2 = Particle(px: 5.0, py: 0.0, ...)
    check detectCollision(p1, p2, threshold = 10.0)

  test "no collision when particles far apart":
    let p1 = Particle(px: 0.0, py: 0.0, ...)
    let p2 = Particle(px: 100.0, py: 0.0, ...)
    check not detectCollision(p1, p2, threshold = 10.0)
```

## Test Quality Indicators

### Good Test Indicators

- ✅ Test name reads like a specification
- ✅ One behavior verified per test
- ✅ Comments explain contract, not code
- ✅ Tests pure functions (deterministic, fast)
- ✅ Edge cases covered (boundaries, empty, full)
- ✅ Tests survive refactoring (behavior unchanged)

### Warning Signs

- ⚠️ Test name describes code structure ("testCalculateOffsets")
- ⚠️ Multiple unrelated checks in one test
- ⚠️ Testing internal implementation details
- ⚠️ Tests depend on execution order
- ⚠️ Mocking browser APIs
- ⚠️ Tests break when refactoring behavior-preserving changes

## Nim Testing Framework Reference

### unittest Module

**Suite definition:**
```nim
suite "Category Name":
  test "specific behavior":
    check condition
```

**Assertion macros:**
```nim
check expr           # Continues on failure, reports error
require expr         # Stops test suite on failure
expect ExceptionType:  # Verifies exception is raised
  riskyCode()
```

**Setup/teardown:**
```nim
suite "Tests with shared setup":
  setup:
    # Run before each test
    let resource = allocate()

  teardown:
    # Run after each test
    deallocate(resource)

  test "uses resource": ...
```

### Static Assertions

**Compile-time checks:**
```nim
static:
  doAssert condition, "error message"
```

**Conditional compilation:**
```nim
when sizeof(int) == 4:
  # 32-bit specific tests
else:
  # 64-bit specific tests
```

## Test Execution Details

### What `nimble test` Does

1. Compiles `tests/test_all.nim` with native backend (`nim c`)
2. Links against pure Nim modules (no browser dependencies)
3. Runs compiled test binary
4. Reports pass/fail for each test

**Compiler flags (from particle_garden.nimble):**
- `--styleCheck:error` — Enforces snake_case
- `--warningAsError:*` — Treats warnings as errors (an unused import or variable fails the build)
- `--hint:XDeclaredButNotUsed:on` — Catches unused variables

The browser-dependent modules have no separate test target. Their correctness is exercised by the application build (`nimble app`, which compiles the JS frontend) and by manual testing in the browser.

## Future Test Improvements

### Potential Additions

1. **Property-based testing** — Generate random inputs, verify invariants hold
2. **GPU shader tests** — Compile WGSL, verify output via compute shader execution
3. **Integration tests** — Headless browser testing (Playwright/Puppeteer)
4. **Performance regression tests** — Benchmark suite with historical comparison
5. **Visual regression tests** — Screenshot comparison for rendering

### Known Limitations

1. **No browser integration tests** — Pure algorithms only
2. **No multi-threaded tests** — Single-threaded execution
3. **No performance benchmarks** — Correctness focus only
4. **No WGSL shader validation** — GPU code untested in CI

---

## Coverage Summary

The native suite covers the pure-logic core: memory layout and 4-byte alignment, spatial-grid math and bin-offset validation, physics force/wrapping/density math and neighbor-cell indexing, GPU struct layouts and field accessors, shader workgroup and tuning configuration, the reactive `Observable` primitive, the UI state models (simulation, render, matrix and its colors, slider, stats formatting, and profiling averages), and palette generation (HSL conversion, scheme distinctness, flat encoding). Run `nimble test` for the current pass count rather than relying on a number recorded here, which would drift the moment a test is added.

Browser integration (WebGPU, DOM, the FFI bindings) is not covered by this suite. It is exercised by the application build and by manual testing in the browser.
