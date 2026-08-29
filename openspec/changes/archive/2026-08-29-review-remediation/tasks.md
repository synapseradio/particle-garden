## Task ids

Ids are stable and never renumbered. A dropped task keeps its id and is struck, so a later reference
never resolves to different work.

Every group ends with `just happen` and `just check` green. A group whose gate stays red is not done.

## Already closed

Eight commits between `e25bf90` and `e8c39de` closed part of this list. Each is struck below with the
commit that closed it, verified against the tree rather than taken from the commit subject.

| task | closed by | verified at |
|---|---|---|
| T1.1, T1.2 | `b5ed967` | `web_api.nim:113-116`, a build-time gate naming any `SimulationState` field with no `ConfigObject` counterpart |
| T1.3, T1.4 | `61e8c35` | `preset.nim:215-218`, `:230` now read `trails false`, `trailLength 0.0`, `glowIntensity 0.8`, `velocityGlowScale 1.0`, `fluidStrength 0.0` |
| T1.5 | `873e6a2` | `canvas_input.nim` split into six handlers under `src/ui/input/` |
| T0.4, T2.1, T2.2 | `fd53076` | `test_no_modes.nim:148` asserts `swept > 0` beside the sweep, with the reasoning stated |
| T3.1 | `bf17203` | `.gitignore:12-14` now covers `particle.wgsl`, `grid_params.wgsl`, `scan_params.wgsl` |
| T3.2 | `8aec4a7` | `web_api.nim:464-500` runs `readParamField` behind a `static:` read gate; the remaining `case` arms are declared `ReadElsewhere` exceptions |

**T3.4 is closed differently than written.** `cce354b` added a test holding `justfile:12` and
`particle_garden.nimble:16` to the same flags rather than giving the flags one home. The agreement is now
checked instead of remembered, which is what article 3 asks. The task as written asked for one home; the
mechanism that landed is a checked duplicate. Treat T3.4 as closed and record the duplicate as a row in
`docs/agreements.md` with its assertion named.

**T3.9 is partly closed.** `e8c39de` deleted `notchPosition` from the panel, dead since the boundary
served positions. Whether `bounds.ts:23` still computes travel is unverified here.

Everything below that is not struck was re-verified against the tree after those eight commits.

---

## Group 0 — the enforcement surface

Nothing here repairs a finding. This group builds what decides the other groups.

**Tests that must fail first.** `test_agreements.nim` does not exist. Write it first, pointed at a
`docs/agreements.md` that does not exist either, and watch it fail to compile before writing the doc.

- **T0.1** Write `docs/agreements.md`. One row per agreement: the two sides, the direction facts flow,
  and the assertion holding it. Seed it from three sources already in hand: CLAUDE.md's "Where authority
  lives" and "Reference oracles" sections, the twenty findings in `scratchpad/architectural-review.md`,
  and the thirteen verified pairs in `scratchpad/understand-enforcement-surface.md` § M6. A row whose
  assertion column is empty is a backlog entry, not an omission.
- **T0.2** Add `tests/test_agreements.nim`. Parse `docs/agreements.md`. Assert every named assertion
  resolves to a real test name, file, or compile-time gate that exists.
- **T0.3** Add the reverse direction to `tests/test_agreements.nim`: every assertion of the recognised
  forms found under `tests/` and `src/` appears as a row. This is the direction that catches a gate added
  without an inventory row, and it is the direction the truncation experiment showed carries the weight.
- **T0.4** Add the vacuity gate to `tests/test_agreements.nim`. For each loop over a collection sized
  outside the test, require either a reverse relation over the same subject or an explicit non-empty
  harvest guard. Files: `tests/test_no_modes.nim`, `tests/test_wgsl_lint.nim` are the four known
  offenders (`test_no_modes.nim:133`, `:144`; `test_wgsl_lint.nim:80`, `:137`) and must go red before
  Group 2 fixes them.
- **T0.5** Add the duplicate-constant gate. No identifier that a `*_core.nim` module exports as a
  constant may appear as a literal in `src/shader_config.nim`'s tuning record. Expected red on
  `shader_config.nim:113`, `:114`, `:120`.
- **T0.6** Derive the oracle inventory from both sides and assert them equal: CLAUDE.md's table, and the
  oracle each shader names in its own header comment. Expected red on three missing table rows
  (`physics_core` ↔ `integrate.wgsl`, `bloom_core` ↔ `tonemap_grade.wgsl`, `overlay_core` ↔
  `overlay.wgsl`).
- **T0.7** Register `test_agreements` wherever the native suite enumerates its tests, and confirm it runs
  under `just happen`.

Gate: `just happen` and `just check` green, with T0.4, T0.5 and T0.6 red only against the specific
offenders named above. Those reds are Group 2's work and are recorded here as the measurement, not
suppressed.

---

## Group 1 — faults that reach a user

**Tests that must fail first.** A test holding every `SimulationState` field to a mirrored counterpart
in `applySimulationToConfig`. A test reading `defaultSettings()` against its owning records. A test that
a bound key with a modifier or a text-input target is not consumed.

- **T1.1** `src/web_api.nim`: `applySimulationToConfig` mirrors `fluidStrength`.
- **T1.2** Add the field-completeness test over `SimulationState` so the next omission fails the build.
  Files: `tests/`, `src/web_api.nim`, `src/ui/state/simulation_state.nim`.
- **T1.3** `src/preset.nim`: `defaultSettings()` reads its owners for `fluidStrength`, `trails`,
  `trailLength`, `glowIntensity`, `velocityGlowScale`. **BREAKING**, six regime presets change look.
- **T1.4** Extend the drift test to every key `defaultSettings()` declares, reading owners rather than
  literals. Files: `tests/`, `src/preset.nim`.
- **T1.5** `src/ui/input/canvas_input.nim:246-258`: add the modifier check and the `event.target` check.
  `src/ui/input/binding_table.nim`: each binding declares which surface it claims.
- **T1.6** `src/webgpu_render.nim` / frame loop: device loss stands the loop down, the loop catches its
  own throws, both busy flags clear on failure.
- **T1.7** `src/ui/api/response_probe.nim`: `frictionProbe` passes `1.0 - value`. Regenerate the
  legibility report and make it a build product compared against rather than a tracked file the suite
  rewrites.

Gate: `just happen` and `just check` green. Confirm the Fluid slider holds a nonzero value in a running
app, because no native test reaches the running frame.

---

## Group 2 — gates that can go red

**Tests that must fail first.** T0.4, T0.5 and T0.6 are already red from Group 0. This group turns them
green by fixing what they found, never by weakening them.

- **T2.1** `src/wgsl_lint.nim` / `tests/test_wgsl_lint.nim`: the binding-manifest sweep asserts a
  non-empty harvest; CI bundles before it checks. Files also `.github/workflows/release.yml`, `justfile`.
- **T2.2** `tests/test_no_modes.nim:133`, `:144`: give both sweeps a reverse relation or a harvest guard.
- **T2.3** `src/shader_config.nim`: `PlaceholderSources` derives from the actual import set rather than
  restating it. `needsRebuild` walks the transitive import graph. Files also `tools/wgsl_bundle.nim`.
- **T2.4** Move `SPH_MAX_DENSITY_RATIO` into `src/sph_core.nim` and substitute it outward through
  `src/shader_config.nim`. This is what makes T2.5 expressible at all.
- **T2.5** `src/sph_core.nim`: `flooredTaitPressure` gains the ratio clamp and its docstring is
  corrected; `xsphVelocityCorrection` gains the shader's mechanism (`forces-sph.wgsl:264-265`); pressure
  assembly moves out of `tests/test_sph_core.nim:455-530` into the oracle so the tested copy and the
  mirrored copy are one.
- **T2.6** `src/shader_config.nim:113`, `:114`, `:120`: read `sph_core`'s constants rather than restating
  them. Turns T0.5 green.
- **T2.7** Add the three missing rows to CLAUDE.md's oracle table. Turns T0.6 green.
- **T2.8** `MAX_SPECIES` reaches `particle.wgsl` as a substituted placeholder. Files:
  `src/memory_layout.nim`, `src/shader_config.nim`, `web/shaders/modules/particle.wgsl`.
- **T2.9** `tests/test_config.nim` reads `src/config.nim` rather than local copies, using the
  source-parsing technique at `tests/test_field_core.nim:1412-1428`.
- **T2.10** `tests/test_shader_manifest.nim`'s loop fails on a miss. `tools/wgsl_bundle.nim` fails on an
  absent source directory.
- **T2.11** `justfile`: `just happen` runs the native suite; `just check` runs the bundler.

Gate: `just happen` and `just check` green, with T0.4, T0.5 and T0.6 now green rather than excepted.

---

## Group 3 — one home per fact

**Tests that must fail first.** A test that no WGSL struct crossing the boundary is hand-written. A test
that every routed descriptor id reads back the value it was written.

- **T3.1** Generate `particle.wgsl`, `grid_params.wgsl`, `scan_params.wgsl` from their layouts and
  gitignore them with the other ten. Files: `tools/wgsl_bundle.nim:275-303`, `.gitignore:14-24`,
  `src/gpu_types.nim`, `src/memory_layout.nim`.
- **T3.2** `src/web_api.nim:429-482`: `getParamImpl` becomes a `fieldPairs` walk with the same
  compile-time gate the write path has at `:484-560`. The read-side walk already exists at `:1203-1219`.
- **T3.3** `src/ui/state/matrix_state.nim:23`: `MATRIX_SIZE` references `MAX_SPECIES`.
- **T3.4** The warning-flag list gets one home. Files: `justfile:16`, `particle_garden.nimble:20`.
- **T3.5** `src/wgsl_lint.nim:149-173`: `ExpectedShaderBindings` becomes the one source the bind-group
  entry counts derive from. Files also `src/webgpu_render.nim:226-240`,
  `src/webgpu_compute.nim:52-65`.
- **T3.6** `web/shaders/src/forces.wgsl:366`: the blast range is substituted, or the placeholder and
  `tests/test_shader_config.nim:42-44`'s assertion on the unread value both go.
- **T3.7** Notch epsilon gets one home and is served. Files: `src/web_api.nim:673`,
  `web-ui/src/components/ParamSlider.tsx:158`.
- **T3.8** Force model codes and labels are served as a catalog. Files: `src/web_api.nim`,
  `web-ui/src/components/Panel.tsx:169-183`.
- **T3.9** Slider travel is served from `src/ui/api/slider_curve.nim` rather than recomputed. Files:
  `web-ui/src/bounds.ts:23`, `web-ui/src/notches.ts:31-34`.
- **T3.10** `src/grid.nim:56-60` calls `grid_core.computeGridDims`, so `tests/test_grid.nim` exercises
  the shipping path.
- **T3.11** Add a row to `docs/agreements.md` for each fact this group gave one home, naming the
  assertion that now holds it.

Gate: `just happen` and `just check` green. Verify render bind groups in a running app, since which
resource lands at each binding is not build-checked.

---

## Group 4 — dead machinery and the third force law

**Tests that must fail first.** A test selecting MODEL 2 and asserting `repulsionEnd` and
`attractionPeak` both move the curve. A test that MODEL 2 at `0.3 / 0.65` reproduces the existing fixed
curve exactly.

- **T4.1** Delete each item named under article 6 in the proposal, with its proof of no reader in the
  same diff.
- **T4.2** `src/physics_core.nim`: `calculateForce` becomes MODEL 2, parameterized. Repulsion
  `r / repulsionEnd - 1` over `[0, repulsionEnd]`; attraction an asymmetric triangle over
  `[repulsionEnd, 1]` peaking at `attractionPeak`.
- **T4.3** `FORCE_MODEL_MAX` rises to 2. Files: `src/config_ranges.nim`.
- **T4.4** `web/shaders/src/forces.wgsl` gains the third branch, matching T4.2 expression for
  expression.
- **T4.5** The panel reads the served catalog from T3.8 rather than its hardcoded list.
- **T4.6** `docs/help/` gains MODEL 2's line, which the help coverage relations require before it can
  ship.

Gate: `just happen` and `just check` green. Select MODEL 2 in a running app and confirm both sliders
move the world.

---

## Group 5 — structure

**Tests that must fail first.** A test that every render shader module passes
`validateShaderCompilation`. Help coverage relations ranging over every control rather than descriptors
alone, which go red against the undocumented controls listed in the proposal.

- **T5.1** Bind groups rebuild on what they depend on; error scopes leave the frame's critical path.
  Files: `src/webgpu_render.nim`.
- **T5.2** Split `src/webgpu_render.nim` at its four existing comment banners.
- **T5.3** Render bind-group creation gains the compute side's error scope and diagnostic; render shader
  modules gain `validateShaderCompilation`.
- **T5.4** `tests/test_help_content.nim`: all four coverage relations range over every control, not only
  `buildParamDescriptors()`. `namedControlIds` reads more than lines shaped `` - `id` — ``.
- **T5.5** Document the controls those relations now find undocumented: both weather switches, trails,
  bloom, force model, colormap, palette scheme, regime, New Rules, Reset, Scatter Spores, the preset
  controls, both grid editors. Files: `docs/help/`.
- **T5.6** `CLAUDE.md`: correct "a control therefore cannot ship undocumented" to state what T5.4 now
  holds.

Gate: `just happen` and `just check` green. Verify every render pass in a running app, since T5.2 moves
bind-group construction and binding placement is not build-checked.

---

## Closing

- **T6.1** `docs/agreements.md` has no row with an empty assertion column that this change was meant to
  fill. Rows left empty on purpose name why.
- **T6.2** Re-run the truncation experiment from `scratchpad/understand-enforcement-surface.md` § M3a
  against the tree as it then stands, and confirm it still turns the suite red.
