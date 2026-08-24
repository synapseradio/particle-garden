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
| `coupling_space.nim` | Shared fixture: `ALL_COUPLINGS`, every combination of the three coupling booleans. Declares no suite, so it needs no `test_all.nim` entry — the modules that sweep the space import it | Native |
| `test_memory_layout.nim` | Memory layout constants, alignment, AoS structure, `align4` | Native |
| `test_grid.nim` | Pure grid algorithms (cell indexing, prefix sums, offset validation) | Native |
| `test_physics.nim` | Pure physics math (forces, wrapping, density, neighbor cells) | Native |
| `test_config.nim` | Configuration constraint invariants derived from the layout limits | Native |
| `test_gpu_types.nim` | GPU struct layout helpers (type sizes, field offsets, accessors) and every generated layout's agreement with WGSL's own offset algorithm | Native |
| `test_shader_config.nim` | Shader workgroup-size and tunable-constant accessors, and the placeholders the bundler emits | Native |
| `test_shader_manifest.nim` | The compute shaders each coupling declares, and the union an active set composes | Native |
| `test_wgsl_lint.nim` | The WGSL constructor lint the bundler runs: named-field constructors flagged with their line, valid WGSL left alone, and a sweep proving no shipped shader source uses one | Native |
| `test_sim_registry.nim` | The frame each couplings set composes: which passes run, in what order, that the delta clears precede every contributor, and which worlds compute particle density | Native |
| `test_sim_config.nim` | Simulation-kind config and the active-kind observable | Native |
| `test_observable.nim` | Observable primitive (construct, read, set, subscribe) | Native |
| `test_input.nim` | Input handling logic | Native |
| `test_matrix.nim` | Attraction matrix state plus cell and species colors | Native |
| `test_app_state.nim` | App runtime and profiling-average accumulators | Native |
| `test_param_descriptor.nim` | The descriptor table: ranges, defaults, store routing, clamping, the per-species chemistry fields, that every routed id names a field of its store's record, and that every notch is a position its slider can reach | Native |
| `test_response_probe.nim` | Probe coverage over the whole descriptor table, the three track metrics at the calibrated thresholds (every probed control passes every declared slice; the feed/kill joint group is judged by its boundary-shift entry evidence and point liveness), and the measured table `docs/control-legibility-report.md` regenerates from | Native |
| `test_dormancy.nim` | Dormancy predicates walked against the state records (every named field exists, no control dormant under its own value, each predicate distinguishes dormant from awake), and response horizons executed through the stepped field harness where a mirror exists, review-labelled where none does | Native |
| `test_slider_curve.nim` | The slider travel curves: position and value as mutual inverses on each descriptor's step lattice, linear as the identity mapping, endpoints and monotonicity under every curve, and clamping at track and range | Native |
| `test_panel_reachability.nim` | Guard test: every descriptor is placed by `Panel.tsx` by id or by group loop, and the panel derives the climate's written parameters rather than listing them | Native |
| `test_overlay_core.nim` | The spatial drag overlay: the closed set held against the full descriptor table, and the ring/frame coverage math mirroring overlay.wgsl | Native |
| `test_help_content.nim` | Help coverage in both directions: docs/help matches the declared file list, every descriptor group has a file, every declared key exists, every descriptor is named by its group's file, no file names a non-descriptor | Native |
| `test_palette.nim` | HSL-to-RGB conversion, palette generation schemes, flat encoding | Native |
| `test_palette_state.nim` | Palette editor state and scheme selection | Native |
| `test_preset.nim` | Versioned preset schema: round-trip, version rejection, clamp/default degradation, migration hook | Native |
| `test_preset_store_core.nim` | Preset name normalization, storage keys, apply-order contract | Native |
| `test_sph_core.nim` | SPH math: 2D smoothing kernels, Tait equation, XSPH term | Native |
| `test_field_core.nim` | Gray-Scott step, the 9-point Laplacian, the field seed, what ignites the pattern, the species chemistry coupling, the chemotactic-collapse bound, and that a regime's deposit floor preserves its morphology | Native |
| `test_force_budget.nim` | How much velocity each of the three force layers hands the integrator, before friction and before the soft cap, swept across every axis that moves it; writes `docs/force-budget-report.md` | Native |
| `test_bloom_core.nim` | Separable Gaussian blur kernel and bloom/grade defaults | Native |
| `test_colormap_core.nim` | Reaction-diffusion field colormap ramps, and the coverage the field claims as light | Native |
| `test_glow_core.nim` | The particle halo: radius composition, Gaussian falloff, the warm shift, and the display-clamped alpha integral a response probe reads | Native |
| `test_trail_core.nim` | The trail: its per-frame geometric decay, and the frames of persistence the trail-length slider buys | Native |
| `test_camera_core.nim` | Toroidal camera: nearest-image seam hiding, clip mapping, seamless pan, zoom clamping and anchoring, the screen-UV/world reprojection pair, and the floor on the composed visible radius | Native |
| `test_camera_input.nim` | Wheel and key navigation: zoom-at-cursor anchoring, composable zoom steps, key bindings | Native |
| `test_climate_core.nim` | The drifting climate: that its path stays inside the feed/kill rectangle by construction, never steps further than the configured maximum, tours every named regime, and that every parameter it declares it writes has a descriptor to write through | Native |
| `test_no_modes.nim` | Guard test: no forbidden mode identifier or mode-id string literal survives anywhere in `src/` or `web-ui/src/`, except the one narrow, self-checking exemption for `preset.nim`'s versioned-schema legacy migration table | Native |

Every test module compiles natively with `nim c`. There is no JS-backend test target: the browser-dependent modules (FFI bindings, WebGPU, DOM) are verified only by the application build itself. The TypeScript control panel has its own suite — `just test-ui` runs `bun test` over `web-ui/test/`, covering preset storage, formatting, descriptor group arithmetic, notch geometry and snapping, and the panel controller's handling of what the simulation pushes at it; `just check` runs both.

Several suites test a **reference oracle** rather than code the simulation calls. `test_physics`, `test_grid`, `test_sph_core`, `test_field_core`, `test_force_budget`, `test_bloom_core`, `test_colormap_core`, `test_camera_core`, `test_glow_core`, and `test_trail_core` exercise pure Nim mirrors of math that really runs in WGSL, where no native test can reach it. Most of those subject modules have no importer in `src/`; the exceptions are the ones that also own a number the app writes into a uniform — `camera_core`, `colormap_core` and `trail_core` — where the mirror is the source rather than a second copy. See the reference-oracle table in the root `CLAUDE.md`.

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
    ├── test_shader_manifest.nim→ shader_manifest.nim (per-coupling shader sets)
    ├── test_wgsl_lint.nim      → wgsl_lint.nim (WGSL constructor lint, shader-source sweep)
    ├── test_sim_registry.nim   → sim_registry.nim (composed frame description)
    ├── test_sim_config.nim     → ui/state/sim_config.nim (active kind)
    ├── test_observable.nim     → ui/core/observable.nim
    ├── test_input.nim          → ui/input (input logic)
    ├── test_matrix.nim         → ui/state/matrix_state.nim (matrix, colors)
    ├── test_app_state.nim      → ui/state/app_state.nim (profiling averages)
    ├── test_param_descriptor.nim → ui/api/param_descriptor.nim (ranges, routing)
    ├── test_response_probe.nim → ui/api/response_probe.nim (probe coverage, track metrics, report table)
    ├── test_dormancy.nim       → ui/api/dormancy.nim (predicates, response horizons)
    ├── test_slider_curve.nim   → ui/api/slider_curve.nim (travel curves as mutual inverses)
    ├── test_overlay_core.nim   → overlay_core.nim (drag overlay set, ring/frame coverage)
    ├── test_help_content.nim   → ui/api/help_content.nim (help coverage relations)
    ├── test_palette.nim        → palette.nim (HSL conversion, palette generation)
    ├── test_palette_state.nim  → ui/state/palette_state.nim (editor state)
    ├── test_preset.nim         → preset.nim (versioned schema, validate/migrate)
    ├── test_preset_store_core.nim → ui/presets/preset_store_core.nim (keys, order)
    ├── test_sph_core.nim       → sph_core.nim (kernels, Tait, XSPH)
    ├── test_field_core.nim     → field_core.nim (Gray-Scott, Laplacian, seeding)
    ├── test_force_budget.nim   → physics_core + sph_core + field_core (per-layer velocity budget)
    ├── test_bloom_core.nim     → bloom_core.nim (blur kernel, grade defaults)
    ├── test_colormap_core.nim  → colormap_core.nim (field colormap ramps, coverage)
    ├── test_glow_core.nim      → glow_core.nim (halo radius, falloff, warmth, alpha integral)
    ├── test_trail_core.nim     → trail_core.nim (trail decay, persistence in frames)
    ├── test_camera_core.nim    → camera_core.nim (toroidal camera, reprojection, visible-radius floor)
    ├── test_camera_input.nim   → ui/input/wheel_handler.nim, key_handler.nim
    ├── test_climate_core.nim   → climate_core.nim (drifting climate path)
    ├── test_no_modes.nim       → src/, web-ui/src/ (guards against a mode concept in source)
    └── test_panel_reachability.nim → Panel.tsx, state.ts (guards that every descriptor
                                      reaches a control, and that the panel derives the
                                      climate's written parameters rather than listing them)
```

## Running Tests

### All Tests (Native)
```bash
just test        # native Nim suite
just check       # native Nim suite + the TypeScript suite
```

This compiles `tests/test_all.nim` with the native backend and runs the whole suite. The same run also happens in CI before any release is built, so a failing test blocks the release.

Run the suite through `just`, not `nimble test`: nimble 0.22.x exits 0 even when the task it ran failed, so a red suite reports green. The `just` recipes call `nim` directly and fail loudly.

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

### 2. Grid Core Tests (`test_grid.nim`)

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

### 3. Physics Core Tests (`test_physics.nim`)

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
- `web_api.nim`, `canvas_input.nim` — Require DOM APIs (the pure logic they wire — descriptors, input state, preset schema — is tested natively)

**Why:**
These modules are thin FFI bindings to browser APIs. Testing them requires:
1. Browser environment (not available in native compilation)
2. Integration tests (would be slow, brittle)
3. Mocking browser APIs (defeats the purpose)

**Mitigation:**
- The application build (`just happen`) compiles the JS frontend, so a broken FFI binding fails the build
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

Defined in test modules, executed via `just test`:
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
   just test
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

### What `just test` Does

1. Compiles `tests/test_all.nim` with native backend (`nim c`)
2. Links against pure Nim modules (no browser dependencies)
3. Runs compiled test binary
4. Reports pass/fail for each test

**Compiler flags (from particle_garden.nimble):**
- `--styleCheck:error` — Enforces snake_case
- `--warningAsError:*` — Treats warnings as errors (an unused import or variable fails the build)
- `--hint:XDeclaredButNotUsed:on` — Catches unused variables

The browser-dependent modules have no separate test target. Their correctness is exercised by the application build (`just happen`, which compiles the JS frontend) and by manual testing in the browser.

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

The native suite covers the pure-logic core: memory layout and 4-byte alignment, spatial-grid math and bin-offset validation, physics force/wrapping/density math and neighbor-cell indexing, the SPH kernels and Tait equation, the Gray-Scott reaction-diffusion step and Laplacian, the bloom blur kernel and field colormap ramps, the particle halo's radius, falloff, warmth and display-clamped alpha integral, the trail's per-frame decay and the frames of persistence its slider buys, GPU struct layouts and field accessors, shader workgroup and tuning configuration and the placeholders the bundler emits, the frame description and shader set each couplings combination composes, the drifting climate's path, the `Observable` primitive, the UI state models (simulation, render, matrix and its colors, palette editor, and profiling averages), the parameter descriptor table (ranges, defaults, store routing, clamping), palette generation (HSL conversion, scheme distinctness, flat encoding), and the versioned preset schema (round-trip serialization, schema-version rejection, clamp/default degradation of malformed input, and the migration hook) alongside preset name normalization and apply order. Run `just test` for the current pass count rather than relying on a number recorded here, which would drift the moment a test is added.

Browser integration (WebGPU, DOM, the FFI bindings) is not covered by this suite. It is exercised by the application build and by manual testing in the browser.
