# native-test-strategy

## Purpose

This capability owns what the project tests, what it deliberately leaves untested, and which mechanism
carries each decision. It is one capability rather than two suites because a single command gates both
(`just check`, `justfile:49-50`) and both answer one question: for a given piece of code, is it
executable by a test runner, single-sourced so it cannot disagree with the code that runs, or verified
only by compiling?

## Requirements

### Requirement: The native suite is the sole executable test target for Nim code

`just test` SHALL compile and run `tests/test_all.nim` with the native backend under the shared quality
flags (`justfile:41-43`, flags at `justfile:12`). No JS-backend test target SHALL exist: every module the
suite reaches must compile natively, which is what forces browser-touching logic to be extracted into
pure modules before it can be tested at all (`tests/README.md`, "Browser-Dependent Code").

The suite SHALL be run through `just`, never through `nimble test`. nimble 0.22.x exits 0 even when the
task's exec fails, so a nimble-driven run reports a red suite as green; the `just` recipe invokes `nim`
directly and propagates the exit code (`justfile:6-10`).

Because the test binary imports the source modules, the compile-time assertions those modules declare
are enforced by the same run: `memory_layout.nim:209`, `gpu_types.nim:430,520,540,562`,
`config_ranges.nim:130`, `field_core.nim:108`, `preset.nim:155`. A violated `static:` block fails
compilation before any test executes.

#### Scenario: A failing assertion stops the suite
- **WHEN** a source module's `static:` block is violated
- **THEN** `just test` fails at compilation, before the first test runs

#### Scenario: A failing test fails the command
- **WHEN** any `check` in the suite fails
- **THEN** `just test` exits non-zero

### Requirement: Every test module is reachable from the aggregate module

`tests/test_all.nim` SHALL import every test module (`tests/test_all.nim:13-34`) and SHALL reference one
exported symbol per module inside a `static:` block (`tests/test_all.nim:38-60`). The reference exists
because `--warningAsError:UnusedImport` (`justfile:12`) would otherwise reject the import: unittest runs
its tests as an import side effect, so the import carries no other use.

A new test module SHALL export a marker constant (`<MODULE>_TESTS_LOADED`) and register both its import
and its `discard` line. `test_physics` and `test_grid` satisfy the reference with their epsilon
constants instead of a marker; either satisfies the mechanism.

The mechanism is asymmetric, and the spec states the gap rather than dressing it up: it guarantees an
imported module is genuinely linked, but nothing detects a test file that exists in `tests/` and was
never imported. Such a file compiles nowhere and runs never. Catching that omission is
**review-enforced**.

#### Scenario: A registered module runs
- **WHEN** a module is imported and its marker discarded in the aggregate
- **THEN** its suites execute in the `just test` run and its module compiles under the quality flags

#### Scenario: An unimported test file is silent
- **WHEN** a file is added to `tests/` but not imported by `tests/test_all.nim`
- **THEN** nothing turns red, and only review catches the omission

### Requirement: WGSL math is tested through pure Nim reference oracles

Math that runs in WGSL SHALL be held to account by a pure Nim mirror the native suite tests, because
physics runs entirely in compute shaders and no native test can execute one. Each oracle mirrors a named
shader: `physics_core.nim` mirrors `forces.wgsl`, `grid_core.nim` the bin-count / prefix-sum /
bin-scatter arithmetic, `sph_core.nim` mirrors `forces-sph.wgsl`, `field_core.nim` mirrors
`rd-step.wgsl` and the 9-point Laplacian plus the `field-seed.wgsl` seed, `bloom_core.nim` mirrors
`blur.wgsl`, `colormap_core.nim` mirrors `colormap.wgsl`, `camera_core.nim` mirrors
`camera_transform.wgsl`, `glow_core.nim` mirrors `glow.wgsl`, and `trail_core.nim` mirrors
`fade.wgsl`'s per-frame decay. Each has a test module (`tests/test_physics.nim`, `test_grid.nim`,
`test_sph_core.nim`, `test_field_core.nim`, `test_bloom_core.nim`, `test_colormap_core.nim`,
`test_camera_core.nim`, `test_glow_core.nim`, `test_trail_core.nim`), and every one of them is
exercised (`tests/README.md:79`).

No `src/` module SHALL recompute a mirrored expression a second time. Three mirrors also own a
number the running app writes into a uniform, and there the app reads the mirror as the source:
`camera_core`, `colormap_core`, and `trail_core` are imported by `webgpu_render.nim`, and the camera
additionally by `app.nim`, `canvas_input.nim`, `web_api.nim`, and the `ui/input/` handlers
(`tests/README.md:79`). `camera_core.nearestImageDelta` calls `physics_core.wrapDelta` for the same
reason, one wrap correction with one home (`src/camera_core.nim:22, 89`). Every other `src/` import
of an oracle SHALL be for the module's constants, never for the mirrored math: `sph_core`,
`field_core`, and `bloom_core` reach `config_ranges.nim`, `shader_config.nim`, `sim_registry.nim`,
`webgpu_compute.nim`, `web_api.nim`, and the `ui/state/` modules that way. `grid_core` has no `src/`
importer at all, and that absence of a caller is the designed state, not evidence of dead code
(`src/grid_core.nim:9-13`).

Enforcement: `tests/test_all.nim:13-38, 42-80` links every oracle's test module, and
`tests/README.md:79` records which mirrors the app reads as its source. That no `src/` module
re-derives a mirrored expression beside its mirror is **agent-checkable**: search `src/` for calls
to each oracle's exported functions and confirm every hit reads the mirror as the source.

#### Scenario: An oracle has no importer
- **WHEN** `src/` is searched for importers of `grid_core`
- **THEN** none is found, and this satisfies the requirement rather than violating it

#### Scenario: An oracle's math is exercised
- **WHEN** `just test` runs
- **THEN** each named oracle module is linked by its test module and its functions are evaluated

### Requirement: A shader value the bundler can substitute MUST NOT be duplicated in WGSL

Where a constant can be computed in Nim and substituted into the shader at bundle time, it SHALL be
single-sourced that way rather than mirrored. `shader_config.getPlaceholderMap`
(`src/shader_config.nim:235`) emits the substitutions, and `tools/wgsl_bundle.nim` inlines them; an
unresolved `{{...}}` aborts the bundle rather than reaching the GPU (`tools/wgsl_bundle.nim:122-127`).
`PlaceholderSources` (`tools/wgsl_bundle.nim:203-216`) lists the Nim modules whose edits must trigger a
shader rebuild, so a tuning change cannot ship stale bundled output.

This is the strongest rung of the strategy: for a substituted value there is no second copy to diverge.
It covers the bloom kernel weights and their count, the colormap ramp coefficients, the field dimensions
and RD seed geometry, the glow curve constants, the SPH XSPH epsilon and density ceiling, the fixed-point
scale and its derived reciprocal, and every workgroup size.

Where a value has two homes by necessity, a native test SHALL relate them: `tests/test_shader_config.nim`
checks the emitted reciprocal inverts the emitted scale (lines 54-62), the glow placeholders against
their appearance-preserving defaults (70-98), `SPH_XSPH_EPSILON` against `sph_core`'s constant (101-130),
the emitted bloom weight list against `bloomWeightCount()` (133-149), and the emitted `FIELD_W`/`FIELD_H`
against `field_core`'s (152-178). Each also checks the emitted text is a WGSL float literal, because a
bare integer where `f32` is expected fails shader type-checking.

#### Scenario: An unresolved placeholder stops the build
- **WHEN** a shader references a `{{PLACEHOLDER}}` the map does not emit
- **THEN** `just happen` fails at the shader step with the shader name and the placeholder

#### Scenario: A duplicated constant is related by test
- **WHEN** a constant necessarily exists in both a pure module and the placeholder map
- **THEN** a test in `tests/test_shader_config.nim` asserts the two are equal

### Requirement: Divergence between a mirrored expression and its shader is review-enforced

Divergence between a mirrored expression and its shader SHALL be labelled **review-enforced**, because no
test in the suite reads, parses, or executes WGSL. Shader files appear in `tests/` only inside comments
naming the shader an oracle mirrors. Nothing compares the mirrored expression to the shader text, and
nothing executes the shader.

Two failure modes therefore stay outside the suite's reach: a mirror that agrees with a shader which is
itself wrong, and a shader edit whose mirror is not updated.
Either leaves `just check` green. The mitigations that exist are structural, not executable — the
substitution rule above removes values from the divergence surface entirely, and each oracle's header
comment names the shader it answers to.

#### Scenario: An unmirrored shader edit stays green
- **WHEN** a force curve changes in `forces.wgsl` and `physics_core.nim` is not updated
- **THEN** `just check` passes, and only review catches the divergence

#### Scenario: A mirrored value is removed from the divergence surface
- **WHEN** a constant is moved from a WGSL literal into the placeholder map
- **THEN** the shader has no independent copy left to diverge from

### Requirement: Oracle tests assert properties of the math, not only pinned outputs

Because a pinned scalar can be transcribed wrong in both the mirror and the shader, oracle tests SHALL
assert properties that a wrong implementation cannot satisfy by coincidence. The suite demonstrates the
form: linearity and the zero-on-a-constant-field property of the Laplacian, and the per-tap stencil
weights (`tests/test_field_core.nim:158-211`); the Gray-Scott trivial fixed point mapping to itself for
every feed/kill, reaction direction, and finite bounds over in-range inputs (213-283); ignition — that a
flat seed plus deposits never leaves the fixed point while a coherent blob develops structure (284-349);
kernel normalization, symmetry, monotone falloff, and the separable half-kernel brightness invariant
(`tests/test_bloom_core.nim:19-74`); 2D kernel normalization, monotone repulsion, and the XSPH bound
(`tests/test_sph_core.nim:45-175`); ramp endpoints, dispatch fallback, and range membership
(`tests/test_colormap_core.nim:22-114`); seed determinism in the nonce and blob non-stacking
(`tests/test_field_core.nim:393-450`).

Whether a newly added oracle test takes this form is **review-enforced**; no mechanism rejects a test
that merely pins a number.

#### Scenario: A property test rejects a plausible wrong implementation
- **WHEN** an oracle's expression is changed in a way that preserves a pinned sample point but breaks
  linearity, normalization, symmetry, or a fixed point
- **THEN** the corresponding property assertion fails

### Requirement: Browser, WebGPU, and DOM code is verified by compilation, never mocked

Modules that bind browser APIs — `bindings/*`, `webgpu_*`, `web_api.nim`, `canvas_input.nim` — SHALL
have no test target and SHALL NOT be tested against mocked browser APIs. Their enforcement point is the
application build: `just happen` compiles `src/app.nim` with `nim js` under the quality flags
(`justfile:25-27`), and `just happen` typechecks the control panel with `tsc --noEmit` before bundling it
(`justfile:29-31`, `web-ui/package.json` `typecheck`). A broken FFI binding, a wrong arity, an unused
import, or a mistyped component fails the build.

The claim's limit is stated rather than assumed: compilation checks Nim and TypeScript types, names,
arities, and unused symbols. It does not check the runtime behavior of a JavaScript expression inside an
`importjs` pragma, nor any WebGPU call sequence. A binding whose embedded JS is wrong compiles cleanly.
Coverage of that gap is **review-enforced** and manual browser testing.

Pure logic SHALL be extracted out of these modules so it can be tested: the descriptor table
(`ui/api/param_descriptor.nim`), preset schema (`preset.nim`), preset storage keys and apply order
(`ui/presets/preset_store_core.nim`), input handling (`ui/input/`), and the UI state models
(`ui/state/`) are all native-tested while their browser wiring is not.

#### Scenario: A broken binding fails the build
- **WHEN** an FFI binding's Nim signature or a Solid component's types are wrong
- **THEN** `just happen` fails at `build-app` or at the `build-ui` typecheck

#### Scenario: A wrong importjs body compiles
- **WHEN** the JavaScript inside an `importjs` pragma is semantically wrong but syntactically valid
- **THEN** the build passes, and only running the application reveals it

### Requirement: Both suites gate the release

`just check` SHALL run the shader bundle, the native suite, the TypeScript suite, the shell suite,
and the shell linter, in that order (`justfile:60`), and the release workflow SHALL run `just check`
before `just release` (`.github/workflows/release.yml:58, 61`). A red suite in any of them blocks
the release.

The TypeScript suite (`just test-ui`, `bun test` over `web-ui/test/`) SHALL cover only panel-side
pure logic that has no Nim owner: value formatting, preset storage, descriptor group arithmetic,
notch geometry and snapping, the dormant-share and response-horizon helpers, the matrix cell edit
machine, the help renderer's markdown subset, and the panel controller's handling of what the
simulation pushes at it (`tests/README.md:77`). It SHALL NOT restate a number the Nim side serves.

Where a panel-side test needs a table Nim owns, it SHALL mirror that table in a fixture and state
the limit, and the relation itself SHALL be asserted natively where both tables are in reach.
`web-ui/test/param-groups.test.ts:9-11` says so of the group taxonomy, proving the grouping
arithmetic and not the fixture's agreement with the descriptor table; `tests/test_panel_reachability.nim:41-72`
holds that agreement, checking every descriptor is placed by `Panel.tsx` by id or by group loop.
`web-ui/test/state.test.ts:9-17` goes further and invents ids the shipped table does not carry, so a
controller holding its own copy of the real ids fails rather than passing on a coincidence.

#### Scenario: A red TypeScript suite blocks a release
- **WHEN** a `bun test` assertion fails
- **THEN** `just check` exits non-zero and the workflow stops before `just release`

#### Scenario: A drifted fixture is not caught by the panel suite
- **WHEN** the descriptor table's group ids change and the TypeScript fixture is not updated
- **THEN** `bun test` still passes, and the native reachability test is what holds the real relation

### Requirement: The reference-oracle family covers the render-side sliders

Pure mirrors of the glow and trail shader math SHALL sit in the reference-oracle family, so the glow
and trail sliders carry measured response probes and take no exemption. `glow_core.nim` mirrors the
halo radius composition, the density and velocity factors, the Gaussian falloff, and the warm shift
(`src/glow_core.nim:5`); `trail_core.nim` mirrors the per-frame decay and the trail-length mapping
that drives it (`src/trail_core.nim:5`). Six render descriptors name probes that read those mirrors:
`glow.clampedIntegral`, `glow.velocityIntegral`, `glow.radiusIntegral`, `glow.falloffIntegral`,
`glow.warmth`, and `render.trailPersistence` (`src/ui/api/param_descriptor.nim:484-502`, probe
functions at `src/ui/api/response_probe.nim:447-491`, both mirrors imported at `:32-33`).

Enforcement: `tests/test_response_probe.nim:42-83` holds the exempt set to exactly `particleCount`,
`speciesCount`, and `sphSubsteps`, so no glow or trail parameter can carry an exemption at all, and
`tests/test_glow_core.nim` and `tests/test_trail_core.nim` run under `just test`, registered at
`tests/test_all.nim:23-24, 65-66`. Divergence between either mirror and its shader falls under the
divergence requirement above.

#### Scenario: The glow oracle mirrors its shader
- **WHEN** the glow falloff, radius, alpha, or warmth expression changes in the shader
- **THEN** the mirror is updated alongside it, as for every other oracle in the family

#### Scenario: No render slider is exempt for want of an oracle
- **WHEN** the exempt set is read
- **THEN** it holds the three structural counts and names no glow or trail parameter

### Requirement: Probe coverage over the descriptor table is total

A native test SHALL assert that every descriptor carries either a response probe or a written
exemption, and that no descriptor carries both, so the coverage relation cannot develop a hole
silently. It SHALL assert the registry in both directions as well: every carried probe id resolves
to a registered function, and every registered probe is carried by some descriptor
(`tests/test_response_probe.nim:38-71`). The exempt set is asserted by name (`:72-83`), so a fourth
exemption is a decision the suite makes loud.

This is the shape the descriptor suite already uses everywhere: two tables and one asserted
correspondence, so a test holds the relation and no reviewer has to.

Enforcement: `tests/test_response_probe.nim`, under `just test`. The declaration lives on the
descriptor itself, whose `probe` field is empty only where `exemption` says why
(`src/ui/api/param_descriptor.nim:193-201`).

#### Scenario: Coverage is exact
- **WHEN** the probe registry and the exemption set are compared against the descriptor table
- **THEN** their union is the whole table and their intersection is empty

#### Scenario: A fourth exemption goes red
- **WHEN** a descriptor is given an exemption instead of a probe
- **THEN** `just test` fails on the named exempt set

### Requirement: The legibility sweep is a native test

The span, live-fraction, and cliff sweep, over every declared context slice, SHALL run inside the
native suite, so a regression turns `just check` red and nothing waits on somebody remembering to
run a tool. `slicesFor` declares each descriptor's slices and `allSliceMeasurements()` measures
every probed descriptor on every one of them (`src/ui/api/response_probe.nim:726-760, 864-877`).
`tests/test_response_probe.nim:96-119` asserts finite metrics in range, the must-pass anchors, and
every probed descriptor outside the joint group passing every slice, each assertion carrying a
`checkpoint` that names the control, the slice, and the three metrics.

Runtime is bounded by the declared per-probe sample budgets, `ProbeBudgetClosedForm` and
`ProbeBudgetStepped` (`src/ui/api/response_probe.nim:60-62`), and a parameter's own step lattice
caps the sample count below the budget wherever the lattice is coarser (`:799-806`). Where the suite
slows materially, the stepped budget is lowered before any parameter or slice leaves coverage.

#### Scenario: A regression in a shipped control goes red
- **WHEN** a change makes a previously passing control's track dead over most of its length
- **THEN** `just check` fails naming the control, the slice, and the three metrics

### Requirement: Joint-group guarantees adopt the suites that already prove them

Where a joint group's guarantee is already proven by an existing suite, the group SHALL adopt that
suite as its acceptance test and keep no parallel copy of it: named-point reachability by the
notch-lattice assertions (`tests/test_param_descriptor.nim:511-609`), attractor fidelity by the
suite `The Regime Deposit Floor Preserves The Regime` (`tests/test_field_core.nim:1177`), and
continuity of travel between named points by the climate tour's continuity and easing tests
(`tests/test_climate_core.nim:202-216`). The adoptions are recorded beside the group's own
assertions (`tests/test_response_probe.nim:121-128`).

A guarantee proven twice is two tests free to drift apart; adoption keeps one proof with one owner.

Enforcement: the adopted suites run under `just test`. That the record names suites which really do
prove those guarantees is **agent-checkable**: read each named suite and confirm it asserts the
guarantee claimed for it, since nothing links the record to a suite mechanically.

#### Scenario: An adopted guarantee names its proving suite
- **WHEN** the joint group's guarantees are traced to tests
- **THEN** each adopted guarantee names the existing suite that proves it, and the group's own
  tests hold no copy of that suite

### Requirement: Pure modules register in the suite and its documentation

Every pure module the native suite tests SHALL be registered in `tests/test_all.nim` with both its
import and its marker constant (`tests/test_all.nim:13-38, 42-80`), and SHALL be named in
`tests/README.md`'s per-file table and its architecture tree (`tests/README.md:55-121`).

A module absent from the aggregate compiles but never runs. A module absent from the documentation
runs but stays invisible to whoever is deciding where a new test belongs.

Enforcement: the aggregate half rides on `--warningAsError:UnusedImport` (`justfile:12`), which
rejects an import whose marker is never discarded. The documentation half is **agent-checkable**:
list `tests/*.nim`, then confirm each file has a row in the per-file table and a line in the
architecture tree. A native test walking the `tests/` directory against the README would close it,
the shape `tests/test_help_content.nim:29-35` already uses for `docs/help/`.

#### Scenario: An imported module without its marker fails the build
- **WHEN** a test module is imported by `tests/test_all.nim` and its marker is never discarded
- **THEN** `just test` fails at compilation on `--warningAsError:UnusedImport`

#### Scenario: A test file nobody imported is found only by the sweep
- **WHEN** a file is added to `tests/` and is neither imported by the aggregate nor named in
  `tests/README.md`
- **THEN** nothing turns red, and the agent procedure above is what finds it
