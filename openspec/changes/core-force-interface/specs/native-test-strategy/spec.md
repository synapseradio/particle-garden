## MODIFIED Requirements

### Requirement: WGSL math is tested through pure Nim reference oracles

Math that runs in WGSL SHALL be held to account by a pure Nim mirror the native suite tests, because
physics runs entirely in compute shaders and no native test can execute one. Each oracle mirrors a named
shader: `physics_core.nim` mirrors `forces.wgsl`, `grid_core.nim` the bin-count / prefix-sum /
bin-scatter arithmetic, `sph_core.nim` mirrors `forces-sph.wgsl`, `field_core.nim` mirrors
`rd-step.wgsl` and the 9-point Laplacian plus the `field-seed.wgsl` seed, `bloom_core.nim` mirrors
`blur.wgsl`, `camera_core.nim` mirrors
`camera_transform.wgsl`, `glow_core.nim` mirrors `glow.wgsl`, and `trail_core.nim` mirrors
`fade.wgsl`'s per-frame decay. Each has a test module (`tests/test_physics.nim`, `test_grid.nim`,
`test_sph_core.nim`, `test_field_core.nim`, `test_bloom_core.nim`, `test_camera_core.nim`, `test_glow_core.nim`, `test_trail_core.nim`), and every one of them is
exercised (`tests/README.md:79`).

No `src/` module SHALL recompute a mirrored expression a second time. Two mirrors also own a
number the running app writes into a uniform, and there the app reads the mirror as the source:
`camera_core` and `trail_core` are imported by `webgpu_render.nim`, and the camera
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
It covers the bloom kernel weights and their count, the field dimensions
and RD seed geometry, the glow curve constants, the SPH XSPH epsilon and density ceiling, the fixed-point
scale and its derived reciprocal, the blast radius and its derived square, and every workgroup size.

Coverage runs in both directions. Every key the map emits SHALL be consumed by a shader source
under `web/shaders/src/` or `web/shaders/modules/`, so a placeholder cannot be emitted against a
shader that spells the value by hand instead. A key of the workgroup family counts as consumed when
the shader it names exists under `web/shaders/src/` and contains `{{WORKGROUP_SIZE}}`, which is the
per-shader rewrite at `tools/wgsl_bundle.nim:114-117`. Every other key is consumed by a literal
`{{KEY}}` occurrence. `tests/test_agreements.nim` enumerates both sets and fails on a key no shader
reads. The check needs no inventory entry, because it derives its subject from the map and the
shader sources.

The key-naming rule that pairs a shader with its workgroup key SHALL have one home,
`shader_config.workgroupKeyFor`, called by both `tools/wgsl_bundle.nim` and the consumption check,
so the check cannot model a rewrite the bundler no longer performs.

Where a value has two homes by necessity, a native test SHALL relate them: `tests/test_shader_config.nim`
checks the emitted reciprocal inverts the emitted scale (lines 54-62), the glow placeholders against
their appearance-preserving defaults (70-98), `SPH_XSPH_EPSILON` against `sph_core`'s constant (101-130),
the emitted bloom weight list against `bloomWeightCount()` (133-149), and the emitted `FIELD_W`/`FIELD_H`
against `field_core`'s (152-178). Each also checks the emitted text is a WGSL float literal, because a
bare integer where `f32` is expected fails shader type-checking.

#### Scenario: An unresolved placeholder stops the build
- **WHEN** a shader references a `{{PLACEHOLDER}}` the map does not emit
- **THEN** `just happen` fails at the shader step with the shader name and the placeholder

#### Scenario: An emitted placeholder no shader consumes fails the suite
- **WHEN** `getPlaceholderMap` emits a key and no shader source under `web/shaders/src/` or
  `web/shaders/modules/` reads it, literally or through the workgroup rewrite
- **THEN** `just test` fails, naming the key

#### Scenario: A duplicated constant is related by test
- **WHEN** a constant necessarily exists in both a pure module and the placeholder map
- **THEN** a test in `tests/test_shader_config.nim` asserts the two are equal

### Requirement: Oracle tests assert properties of the math, not only pinned outputs

Because a pinned scalar can be transcribed wrong in both the mirror and the shader, oracle tests SHALL
assert properties that a wrong implementation cannot satisfy by coincidence. The suite demonstrates the
form: linearity and the zero-on-a-constant-field property of the Laplacian, and the per-tap stencil
weights (`tests/test_field_core.nim:158-211`); the Gray-Scott trivial fixed point mapping to itself for
every feed/kill, reaction direction, and finite bounds over in-range inputs (213-283); ignition — that a
flat seed plus deposits never leaves the fixed point while a coherent blob develops structure (284-349);
kernel normalization, symmetry, monotone falloff, and the separable half-kernel brightness invariant
(`tests/test_bloom_core.nim:19-74`); 2D kernel normalization, monotone repulsion, and the XSPH bound
(`tests/test_sph_core.nim:45-175`); seed determinism in the nonce and blob non-stacking
(`tests/test_field_core.nim:393-450`).

Whether a newly added oracle test takes this form is **review-enforced**; no mechanism rejects a test
that merely pins a number.

#### Scenario: A property test rejects a plausible wrong implementation
- **WHEN** an oracle's expression is changed in a way that preserves a pinned sample point but breaks
  linearity, normalization, symmetry, or a fixed point
- **THEN** the corresponding property assertion fails
