## Why

An architectural review of the whole tree (`scratchpad/architectural-review.md`) surveyed six
territories and found twenty faults. Repairing twenty faults leaves the tree able to grow the
twenty-first, so this change repairs the enforcement surface that let them in and treats the twenty as
instances that surface covers.

Every fault sits at an agreement between two artifacts where `docs/engineering-principles.md` names an
enforcement path, and the path turns out absent, vacuous, or aimed at the wrong subject. The review
ranks by whether an artifact asserts a state it is not in, which is why an empty lint sweep outranks a
simulation feature that never runs: a green check that cannot go red costs more than a broken feature,
because it also hides the next one.

Two experiments fix what the repair has to be. Truncating `buildParamDescriptors()` from sixty-odd
entries to three turned 33 tests red without any of them asserting a count, so **coverage running in
both directions over a relation is what protects it**, and a count assertion is neither necessary nor
sufficient. Reading all thirteen reference-oracle pairs expression by expression found twelve in
agreement, and every one of those twelve holds because its constants travel by `{{PLACEHOLDER}}`
substitution rather than because anyone stayed careful. **Substitution is the working mechanism, and
every divergence found sits where a number is spelled twice.**

So the deliverable is three things. An inventory naming every agreement in the tree, its two sides, and
the assertion holding it. Meta-gates that range over that inventory in both directions. Then the twenty
repairs, ordered by whether a gate now covers them, with the four that reach a user landing regardless.

Working notes and both experiments: `scratchpad/understand-enforcement-surface.md`.

**Part of this is already done.** Eight commits between `e25bf90` and `e8c39de` closed the fluid write
path, the preset defaults, the input interception, three generated struct modules, the read-path gate,
and the vacuity guards on the filesystem sweeps. `tasks.md` records which task each closed and where
that was verified. The evidence sections below are kept as written because they carry the citations the
inventory is seeded from, and a closed finding is still the row that says what now holds it. Where a
section describes a fault since repaired, `tasks.md` is the current word.

What remains live and verified after those commits: the `sph_core` divergence and its four duplicated
constants, the three oracle pairs missing from CLAUDE.md's table, `MATRIX_SIZE` at
`matrix_state.nim:23`, the hardcoded blast range at `forces.wgsl:366` against an emitted placeholder
nobody consumes, `grid.nim`'s copy of `computeGridDims`, `physics_core.calculateForce` with no caller in
`src/`, and all of groups 4 and 5.

### A value passes every check and never arrives

`CONFIG.fluidStrength` takes its value once, in `createConfig` (`src/config.nim:172`), from
`initSimulationState()` where it is `0.0` (`src/ui/state/simulation_state.nim:114`).
`applySimulationToConfig` (`src/web_api.nim:116-142`) mirrors 28 other simulation fields into `CONFIG`
and omits this one. `webgpu_compute.nim:798` feeds `SIM_FLUID_STRENGTH` from that field every frame,
so `forces-sph.wgsl` multiplies its entire pair contribution by zero and the fluid does nothing.

`couplingsOf` reads the typed store instead (`src/ui/state/sim_config.nim:54`), so `acts` still
dispatches the SPH pass and `runPhysicsFrame` still engages up to `SPH_MAX_SUBSTEPS` whole-frame
substeps. Every Gray-Scott step in the frame description re-encodes N times to compute nothing.

`getParamImpl` reads `CONFIG` (`src/web_api.nim:459`), and `web-ui/src/state.ts:74` re-reads after
every set, so the Fluid slider returns to zero under the user's hand. `snapshotPreset` saves
`CONFIG.fluidStrength` (`src/web_api.nim:898`), so every preset exported since this shipped records no
fluid. `git log -S "CONFIG.fluidStrength = "` returns nothing: the write site has never existed.

Article 1 says validate at the boundaries and let code inside trust what reaches it. Every clamp on
this value fires correctly. Nothing checks that a validated value reaches its consumer.

### Preset defaults disagree with the records that own them

`defaultSettings()` (`src/preset.nim:205-240`) states that it mirrors the shipped defaults. Five keys
do not:

| key | `preset.nim` | owner |
|---|---|---|
| `fluidStrength` | `1.0` (`:230`) | `0.0` (`simulation_state.nim:114`) |
| `trails` | `true` (`:215`) | `false` (`render_state.nim:78`) |
| `trailLength` | `50.0` (`:216`) | `0.0` (`render_state.nim:79`) |
| `glowIntensity` | `0.03` (`:217`) | `0.8` (`render_state.nim:80`) |
| `velocityGlowScale` | `0.0` (`:218`) | `1.0` (`render_state.nim:81`) |

`fluidStrength: 1.0` sits directly under a comment reading "the shipped world runs no fluid, so a
preset that never mentions one restores none." `regimeStarter` (`src/web_api.nim:1087`) builds from
`defaultPreset()` and overrides only four reaction-diffusion fields, so all six regime buttons carry
these five values, and `defaultPreset()` is also what a failed load returns. The drift test at
`tests/test_preset.nim:29-42` covers seven keys and none of these five; the test touching the glow
defaults (`:58-61`) pins `preset.nim` to a third copy of the literals, so it cannot go red on a
`render_state` change.

The two faults mask each other. Repairing the fluid write path alone hands six starter presets a
full-strength fluid nobody has tuned. They land together.

### Six gates are green because they inspect nothing

Article 4 says prove a gate can go red before crediting its green. These cannot.

`test_wgsl_lint.nim:145` sweeps `walkFiles("web/shaders" / "*.wgsl")`. Those files are generated and
gitignored (`.gitignore:12-13`). CI runs `just check` at `.github/workflows/release.yml:58` and
`just release` at `:61`, and `just release` is the first thing that bundles shaders, so in CI the
sweep iterates an empty set and passes over nothing. The guard written to prevent exactly this,
`check dirExists("web/shaders")` at `:161-164`, passes anyway, because `README.md`, `modules/` and
`src/` are tracked under that path. It checks the directory and not the harvest.

`PlaceholderSources` (`tools/wgsl_bundle.nim:217-223`) lists five Nim modules. `shader_config.nim:186-212`
draws placeholder values from those plus `sph_core`, `overlay_core`, `trail_core`, `memory_layout`,
`gpu_types` and `wgsl_lint`, none of them listed. Editing `trail_core`'s taper or `overlay_core`'s line
constants and running `just happen` reports the shader unchanged and ships the old value with a green
build. `SPH_DENSITY_FIXED_POINT_SCALE` is the dangerous one: it is an encode and decode pair, so a
stale bundle yields densities wrong by a factor rather than visibly broken. `needsRebuild` also walks
direct imports only, so a change to `CameraLayout` regenerates `camera.wgsl` while `render.wgsl`,
which imports it transitively through `camera_transform`, does not rebundle.

`memory_layout.nim:241` asserts `MAX_SPECIES == 6` and its message points at `particle.wgsl`, a file it
never reads; `particle.wgsl:41` carries the mirror-image comment. Editing either side alone passes.

`tests/test_config.nim:14-15` re-declares the constants locally because `config.nim` is JS-only, and
roughly 25 assertions read only those local copies. Changing a default in `config.nim` leaves the suite
green.

`tests/test_shader_manifest.nim:91-104` looks up two specs in a loop and leaves `found` at its zero
value on a miss, so renaming both `rdStepToFront` and `rdStepToTrail` compares `"" == ""` and passes.
`tools/wgsl_bundle.nim:312-318` returns success when the source directory is absent, so `just shaders`
succeeds having bundled nothing.

Underneath all six sits the recipe wiring. `just happen`, which `CLAUDE.md` prescribes after every
change, runs no tests. `just check` runs both suites and never invokes the bundler. CI is the only
place both run, in the order that makes the manifest sweep vacuous.

### One reference-oracle pair has drifted, and a split constant home is why

All thirteen pairs were read expression by expression against their shaders before this was written
(verdicts in `scratchpad/understand-enforcement-surface.md` § M6). Twelve agree. `sph_core` ↔
`forces-sph.wgsl` diverges three ways.

`forces-sph.wgsl:145` clamps the density fed to Tait pressure into
`[restDensity, restDensity * SPH_MAX_DENSITY_RATIO]`. `sph_core.flooredTaitPressure`
(`src/sph_core.nim:126`) applies only `max(density, restDensity)`, and its docstring asserts the shader
applies exactly that. Commit `ff44e57` changed `forces-sph.wgsl`, `shader_config.nim` and
`test_shader_config.nim`; `git log -- src/sph_core.nim` does not contain it. The consequence stays
latent, because current call sites hold below the ratio by construction. The oracle is wrong and its
docstring tells the next reader they are right.

`xsphVelocityCorrection` bounds by `clamp(w, 0, 1)` where the shader divides by
`max(max(rhoI, rhoJ), 1.0)` and fuses viscosity into the coefficient (`forces-sph.wgsl:264-265`), so the
oracle mirrors a decomposition the shader does not have. Pressure assembly has no oracle function and
exists a third time inside `tests/test_sph_core.nim:455-530`, where that copy is the only one.

**Editing the docstring would leave the cause in place.** `SPH_MAX_DENSITY_RATIO` lives in
`shader_config.nim`'s tuning record (`:121`), downstream of `sph_core`, so the oracle cannot express
that clamp without inverting the import direction. Three further SPH constants are spelled in both
modules and carry a comment claiming they agree: `sphXsphEpsilon` (`:113`), `sphForceScale` (`:114`),
`sphMaxPressureAccel` (`:120`). Grepping `tests/` for any of the four field names returns nothing. The
values match today, so all four are latent rather than live, and each is one edit away from live.

Every SPH constant homed in `sph_core` and substituted outward held. Every constant spelled twice
carries a comment where a mechanism should be. Article 3 asks that agreement be checked rather than
remembered, and these are four agreements remembered.

Article 5 names "a shader change without its oracle change in the same diff" as a review flag. A review
flag is a person remembering. So is a comment reading `# Mirrors sph_core.SPH_FORCE_SCALE`.

The declared inventory is also short by three. `physics_core` ↔ `integrate.wgsl`, `bloom_core` ↔
`tonemap_grade.wgsl` and `overlay_core` ↔ `overlay.wgsl` all agree and none appears in CLAUDE.md's
table, so a gate keyed on that table would report full coverage while leaving them unguarded. Shaders
name their own oracle in their headers, which yields a second derivation of the inventory to assert the
table against.

### The panel eats the user's keystrokes

`src/ui/input/canvas_input.nim:246-258` listens on `window`, resolves `cameraKeyFor($event.key)` on the
key alone, and calls `preventDefault` on any match. Bindings include `0`, `-`, `_`, `+`, `=` and the four
arrows (`src/ui/input/binding_table.nim:55-81`). There is no modifier check and no `event.target` check.

Typing `-0.5` into a matrix or chemistry cell loses the `-` and the `0`. Typing `0` in the preset JSON
textarea is blocked. Arrow-key adjustment of a focused slider is dead. Ctrl or Cmd with `-`, `+` or `0`
fires a camera zoom or reset instead of browser zoom, and none of those chords appear in the table. The
comment at `:252-253` claims "ordinary typing elsewhere in the panel is untouched"; the panel side
already implements the guard the Nim side lacks (`web-ui/src/components/Panel.tsx:48-50`).

Article 11 asks that a page gesture be suppressed deliberately. These three are suppressed by accident.

### Facts with two homes

Article 2 asks for one owning module per fact. The review found these, and the list is the dedupe work:

The bundler generates ten WGSL struct modules (`tools/wgsl_bundle.nim:275-303`) and `.gitignore:14-24`
lists exactly those ten. `particle.wgsl`, `grid_params.wgsl` and `scan_params.wgsl` are tracked instead,
hand-written twins of `ParticleLayout`, `GridParamsLayout` and `ScanParamsLayout`. `Particle` is the
32-byte record every compute and render shader reads out of an untyped storage buffer; reordering two
fields reinterprets velocity as species with no build failure, no test failure and no WebGPU validation
error.

`getParamImpl` (`src/web_api.nim:429-482`) is a hand-written 40-arm string `case` whose `else` warns and
returns `0.0`, while the write path for the same ids is compile-time verified by `assignParamField` and
its `static:` gate (`:484-560`). Adding a descriptor whose id is a real field and forgetting the getter
arm gives a green build, a correct write, and a slider that shows zero forever. The read-side
`fieldPairs` walk already exists in the same file (`dormantParams`, `:1203-1219`).

`MAX_SPECIES` has three copies: `memory_layout.nim:241`, `particle.wgsl:41`, and `MATRIX_SIZE = 6` at
`src/ui/state/matrix_state.nim:23`, which is served across the boundary as `matrixStride` with neither
prose nor test. `justfile:16` and `particle_garden.nimble:20` carry the same warning-flag list under a
comment saying they must stay in sync. `ExpectedShaderBindings` (`src/wgsl_lint.nim:149-173`) and
`EXPECTED_BIND_GROUP_ENTRIES_*` (`webgpu_render.nim:226-240`, `webgpu_compute.nim:52-65`) restate one
fact three times and no file reads both. `forces.wgsl:366` hardcodes `40000.0` while
`{{TUNABLE_BLAST_RANGE_SQ}}` is emitted and consumed by nobody, and `test_shader_config.nim:42-44`
asserts the unread value is non-negative. Force model codes and labels are hardcoded in
`Panel.tsx:169-183` while three sibling enumerations get served catalogs. The panel computes slider
travel at `web-ui/src/bounds.ts:23` and `notches.ts:31-34`, correct only while every descriptor is
linear. Two epsilons answer "the handle is on the notch": `1e-9` in `ParamSlider.tsx:158`, `1e-6` in
`web_api.nim:673`. `grid.nim:56-60` re-implements `grid_core.computeGridDims` in the shipping path while
`tests/test_grid.nim` exercises the copy the app never calls.

### Machinery with no reader, and one reader waiting

Article 6 says ship a mechanism only alongside the code that uses it, and delete what is proven dead in
the change that proves it.

`forceWeatherParamIds` is served (`web_api.nim:1190`), typed (`garden-api.ts:222`), faked in a test
(`state.test.ts:111`), and read nowhere. `slider_curve`'s `cLog` and `cPower` arms are unreachable
because no descriptor passes `curve`, so the curve-floor static gate at `param_descriptor.nim:721-736`
has a loop body that never enters; its `boundMin`/`boundMax` contract, the module header's headline
feature, has no caller. `observable.nim` does not export `subscribe` and has no `unsubscribe`, so
`SubscriptionId`, the cleanup signature and the cleanup loop are unreachable, and two globals with one
subscriber cost 151 lines. `js_interop.nim` and `window.nim` carry roughly 40% unreferenced exports
while `web_api.nim:71-76` hand-writes an `importjs` JSON pre-check beside unused `parseJsonJs` and
`stringifyJs`. `runtimeState.isRunning` is only ever set true. `gridTimeMs` ships a literal zero to the
panel. `webgpu_init.cleanup` has no caller and would not reset the state a re-init needs.

One item on that list is not dead but unshipped. `physics_core.calculateForce` (`:34-60`) is a complete
third force law with a fixed 0.3 / 1.3 / 0.7 curve that no shader runs. It gets promoted to a selectable
force model rather than deleted, parameterized by the `repulsionEnd` and `attractionPeak` knobs that
already steer models 0 and 1 so no model leaves a control inert. `REPULSION_ZONE_END`'s comment claims
it tracks the force law "so they cannot come to disagree", and the law it tracks is this one; promotion
makes that claim true.

### Where the frame loop and the panel lose the user quietly

`webgpu_init.nim:387-393` handles `device.lost` by setting `isWebGPUAvailable = false`. The frame's
readiness guard reads `useWebGPU` and `isPipelineReady`, both only ever set true, and `isWebGPUAvailable`
is read once during init. After a device loss the loop keeps submitting against a dead device forever.
`loop` reschedules itself after `await physics(dt)`, nothing catches, and the caller does
`discard loop(...)`, so one throw halts the simulation with an unhandled rejection in a console the user
does not have open. `readFieldAlive` and `gpu_profiler.readback` each clear their busy flag only on the
success path, so one failed buffer map freezes the alive-cell census or every GPU timing for the process
lifetime.

`frictionProbe` (`src/ui/api/response_probe.nim:188-192`) passes the descriptor's value into
`postStepSpeed`'s retention parameter, but that value is damping: `app.nim:209` writes
`1.0 - CONFIG.friction` to the uniform. The sibling `maxVelocityProbe` passes a literal `1.0` for
"damping held at identity". The probe sweeps retention across 0.0 to 0.5 while the world runs it across
0.5 to 1.0, and the soft-cap knee sits in the half the probe never visits. The `friction` row of
`docs/control-legibility-report.md` describes a track the user cannot reach, and that report supplies
the calibration anchors. `test_response_probe.nim:257-258` writes the report and then asserts the file
exists, comparing the artifact to nothing and dirtying a tracked file on every run. `measureSlice`
(`:815-817`) samples value-space and never calls `valueAt`, so the remedy built for a failing legibility
metric is invisible to that metric.

`webgpu_compute.nim:873` rebuilds bind groups when `gridW` or `gridH` change, and
`createBindGroups(gridW, gridH)` at `:271` reads neither parameter. Fourteen
`createBindGroupWithValidation` calls each await `device.popErrorScope()` before any command encoding,
and the next frame is scheduled only after the await resolves. `grid.nim:56` sets
`cellSize = max(CONFIG.interactionRadius, 16)`, so with `WORLD_W = 3840` every one-unit radius step
changes `gridW`. The force weather walks that axis at up to 0.30 units per frame, so a rebuild fires
roughly every third or fourth frame while it is enabled.

### Help coverage reaches sliders only

All four relations in `tests/test_help_content.nim` range over `buildParamDescriptors()`, and
`namedControlIds` reads only lines shaped `` - `id` — ``. Every toggle, selector and command button sits
outside them: both weather switches, trails, bloom, force model, colormap, palette scheme, regime, New
Rules, Reset, Scatter Spores, the preset controls and both grid editors. Scatter Spores, the preset
system and the editors are documented nowhere. `CLAUDE.md`'s "a control therefore cannot ship
undocumented" holds for sliders and overstates for everything else.

### `webgpu_render.nim` at 2237 lines

`initWebGPURender` alone is 1058 lines, 47% of the file, holding nine pipelines' descriptor construction
in one scope. The layout for render binding 3 is declared at `:410` and the resource for binding 3 is
chosen at `:1388`. The one contract with no automated gate is the one whose two halves sit furthest
apart. Four seams already exist as comment banners. Compute bind-group creation wraps in an error scope
that names the pass and dumps every binding while render-side `createBindGroup` calls are bare, so the
side with hand-built layouts carries the weaker diagnostic; render shader modules also skip
`validateShaderCompilation`, which the compute path uses.

## What Changes

Six stages, gated. Each group ends with `just happen` and `just check` green.

**Stage 0, the enforcement surface itself.** This is what makes the next review find less than this
one, and the other five stages are its instances.

- `docs/agreements.md` names every agreement in the tree: its two sides, the direction facts flow, and
  the assertion holding it. It sits beside `engineering-principles.md`, which names twelve articles and
  their enforcement paths without naming where each path applies. An agreement whose assertion column is
  empty is an entry in the backlog, so the twenty findings enter as rows rather than as a work order,
  and a reviewer checks the inventory against the tree instead of re-deriving the agreements by reading.
- A native meta-gate ranges over that inventory in both directions, in the form `test_no_modes` already
  uses: every listed agreement resolves to a real assertion, and every assertion of the recognised forms
  appears in the inventory. Bidirectional coverage is what caught a truncated descriptor list in 33
  tests with no count assertion anywhere, and one direction alone is what leaves a sweep green over an
  empty harvest.
- A vacuity gate holds every relation assertion to establishing its subject was non-empty. The subject
  is any loop over a collection sized outside the test; `scratchpad/vacuity_sweep.py` is the prototype
  and the gate belongs in Nim inside the native suite. Where a subject has a registry to range over,
  the gate demands the reverse relation instead, because a count assertion is neither necessary nor
  sufficient for what the reverse relation gives free.
- A duplicate-constant gate holds the result that mattered most: twelve of thirteen oracle pairs agree
  because their constants travel by `{{PLACEHOLDER}}`, and every divergence found sits where a number is
  spelled twice. No constant an oracle owns may be spelled again in `shader_config.nim`'s tuning record.
- The oracle inventory derives from two sides and the two are asserted equal: CLAUDE.md's table, and the
  oracle each shader names in its own header. Three agreeing pairs are missing from the table today.

**Stage 1, faults that reach a user.**

- `applySimulationToConfig` mirrors `fluidStrength`, and a native test holds every `SimulationState`
  field to a mirrored counterpart so the next omission fails the build rather than the fluid.
- `defaultSettings()` moves to its owners for all five drifted keys. **BREAKING**: the six regime
  starter presets change appearance. They lose trails, gain `glowIntensity 0.8` and full
  `velocityGlowScale`, and run no fluid until the user asks for one. A fresh boot is unchanged.
- The drift test covers every key `defaultSettings()` declares, reading owners rather than literals.
- Key handling gains a modifier check and an `event.target` check, and the binding table declares which
  surface each binding claims.
- Device loss makes the frame loop stand down; the loop catches its own throws; both busy flags clear
  on failure.
- `frictionProbe` passes `1.0 - value` and the legibility report regenerates. The report becomes a
  build product compared against, not a tracked file rewritten by the suite.

**Stage 2, gates that can go red.**

- The binding-manifest sweep asserts a non-empty harvest and CI bundles before it checks.
- `PlaceholderSources` derives from `shader_config`'s actual import set rather than restating it, and
  `needsRebuild` walks the transitive import graph.
- `SPH_MAX_DENSITY_RATIO` moves into `sph_core` and reaches the shader by substitution, which is what
  makes the clamp expressible in the oracle at all. `sphXsphEpsilon`, `sphForceScale` and
  `sphMaxPressureAccel` stop being spelled in `shader_config.nim` and read their `sph_core` owners, so
  the three comments claiming agreement are replaced by the agreement.
- `sph_core.flooredTaitPressure` gains the ratio clamp and its docstring is corrected;
  `xsphVelocityCorrection` gains the shader's mechanism; the pressure assembly moves out of
  `test_sph_core.nim` into the oracle so the tested copy and the mirrored copy are one.
- The three undeclared oracle pairs join CLAUDE.md's table, which stage 0's two-sided derivation then
  holds.
- `MAX_SPECIES` reaches `particle.wgsl` as a substituted placeholder.
- `test_config` reads `config.nim` rather than local copies, using the source-parsing technique already at
  `test_field_core.nim:1412-1428`.
- `test_shader_manifest`'s loop fails on a miss; `wgsl_bundle` fails on an absent source directory.
- `just happen` runs the native suite; `just check` runs the bundler.

**Stage 3, one home per fact.**

- `particle.wgsl`, `grid_params.wgsl` and `scan_params.wgsl` are generated from their layouts and
  gitignored with the other ten.
- `getParamImpl` becomes a `fieldPairs` walk with the same compile-time gate the write path has.
- `MATRIX_SIZE` references `MAX_SPECIES`. The warning-flag list gets one home. `ExpectedShaderBindings`
  becomes the one source the bind-group entry counts derive from. The blast range is substituted or the
  placeholder and its assertion go. Notch epsilon gets one home and is served. Force model codes and
  labels are served as a catalog. Slider travel is served rather than recomputed in the panel.
- `grid.nim` calls `grid_core.computeGridDims`.

**Stage 4, dead machinery and the third force law.**

- Everything named under article 6 above is deleted with its proof.
- `physics_core.calculateForce` becomes MODEL 2, parameterized: repulsion is `r / repulsionEnd - 1` over
  `[0, repulsionEnd]`, attraction is an asymmetric triangle over `[repulsionEnd, 1]` peaking at
  `attractionPeak`, and at `0.3 / 0.65` it reproduces the fixed curve exactly. `FORCE_MODEL_MAX` rises to
  2, the shader gains a third branch, the panel reads the served catalog, and `docs/help/` gains its line.

**Stage 5, structure.**

- Bind groups rebuild on what they depend on, and the error scopes leave the frame's critical path.
- `webgpu_render.nim` splits at its four existing seams; render bind-group creation gains the compute
  side's diagnostic and its shader modules gain `validateShaderCompilation`.
- Help coverage ranges over every control, not only descriptors, so a toggle or command cannot ship
  undocumented either.

## Capabilities

### New Capabilities

- **agreement-enforcement** — what counts as an agreement between two artifacts, where the inventory of
  them lives, and what assertion forms are allowed to hold one. Owns the meta-gate, the vacuity gate and
  the duplicate-constant gate. `native-test-strategy` keeps how a test is written; this owns what must
  have one.
- **input-dispatch** — which surface receives a key or pointer event, and what a binding claims. Owns the
  modifier and target discrimination the camera bindings need. Camera behaviour itself stays where it is
  and gets no spec here.
- **control-legibility** — the friction probe, the response report, and the report's status as a build
  product compared against rather than a tracked file the suite rewrites. No spec exists for this today.
- **in-app-help** — the four coverage relations between `docs/help/` and the controls, ranging over every
  control rather than descriptors alone. No spec exists for this today.

### Modified Capabilities

- **gardenapi-boundary** — the read path gains the write path's compile-time gate; every simulation field
  is held to a mirrored counterpart; force model codes, labels, notch epsilon and slider travel are served
  rather than restated.
- **parameter-range-authority** — preset defaults reference their owning records; `FORCE_MODEL_MAX` covers
  three models.
- **gpu-buffer-layout** — every WGSL struct crossing the boundary is generated; `MAX_SPECIES` reaches the
  shader as a substituted value.
- **shader-pipeline** — the binding-manifest sweep proves its harvest; the rebuild gate covers its inputs
  transitively; the bundler fails on an absent source tree; MODEL 2 joins the force-model branch.
- **build-pipeline** — the per-change recipe runs the tests, and the test recipe runs the bundler.
- **native-test-strategy** — every reference oracle owns its constants and substitutes them outward, so
  agreement on numbers holds by construction; a test that pins a constant reads the owner rather than a
  local copy; the oracle inventory derives from two sides.
- **gpu-frame-registry** — a lost device stops the loop; a throwing frame is caught; a failed readback
  releases its flag.

## Impact

**Behaviour a user sees.** The six regime presets change appearance (stage 1). The Fluid slider starts
working (stage 1). Typing in panel fields and browser zoom stop being intercepted (stage 1). A third
force model appears in the panel (stage 4). Everything else is invisible from the outside and visible in
the build.

**Presets already on disk.** A saved preset that names `fluidStrength` restores what it names, and the
value it recorded is whatever `CONFIG` held, which was `0.0` for every export since the fluid shipped.
Those presets restore no fluid, which is what they did before this change. A preset that omits the key
takes the corrected default, also `0.0`. No preset changes meaning; the schema version does not move.

**New documentation.** `docs/agreements.md` joins `docs/engineering-principles.md` as the second file a
reviewer reads. The principles name twelve articles and their enforcement paths; the inventory names
where each path applies and what holds it there.

**Files with the widest reach.** `src/web_api.nim` (read path, mirror completeness, served catalogs),
`tools/wgsl_bundle.nim` and `src/shader_config.nim` (rebuild inputs, generated structs, substituted
constants), `src/webgpu_render.nim` (the split), `justfile` and `.github/workflows/release.yml` (recipe
wiring).

## Non-Goals

- A general WGSL validator. The lint catches classes detectable in the text; a bundled shader declaring a
  binding the pipeline does not provide still fails on the device.
- Executing shader code in the native suite. Nothing here runs WGSL.
- Pinning a digest of each oracle pair as the primary instrument. Reading all thirteen pairs showed
  substitution doing the work: every pair whose constants travel by placeholder agreed, and every
  divergence sat on a number spelled twice. A digest over the pair would go red on a comment edit and
  stay green on a constant edited in both places to two different values, which inverts what matters.
  Single-sourcing the constants is the gate. Structure, which substitution cannot carry, is left to the
  expression correspondence and to reading.
- Retuning the six regime presets. They move to their owners' values and are not re-authored. Whether the
  resulting look wants tuning is a separate question with its own measurements.
- A pause control. `isRunning` is deleted rather than given the mechanism it implies.
- Reworking the force-model selector into a continuous quantity. Three named curves stay three named
  curves; article 7's continuity applies to the couplings, and a curve family is not a coupling.
- Recovering from device loss by rebuilding the device. Stage 1 makes loss stop the loop and say so; a
  re-init path is its own change with its own state-reset audit.

## Sequencing

Stage 0 precedes everything because it decides what the other stages are. The inventory is what says
which of the twenty findings already has a gate covering it and which needs one built, and repairing an
instance before its class has a gate spends the repair without closing the class. Its own work needs
nothing from the other five: the two experiments behind it are done, and thirteen oracle pairs are read.

Stage 1 precedes stages 2 through 5 because the fluid write path and the preset defaults mask each other, and
because a suite that stays green through a broken fluid should not be the suite validating stages 2
through 5.

Stage 2 precedes stage 3 for one reason: three of the dedupes in stage 3 are held by gates that cannot
currently fail. Generating `particle.wgsl` before the binding-manifest sweep proves its harvest means the
generation lands unverified in CI.

Stage 4's deletions wait on stage 3 because two dead items are dead only until the dedupe reaches them:
`slider_curve`'s bounds contract acquires a caller if travel is served from Nim, and the curve arms
acquire one if any descriptor takes a curve. Whether they survive is decided by what stage 3 builds, not
assumed here.

Stage 5 sits last because the render split is the largest mechanical change in the program and rebases
badly against everything before it.
