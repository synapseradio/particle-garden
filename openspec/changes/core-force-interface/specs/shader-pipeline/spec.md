## MODIFIED Requirements

### Requirement: Placeholder substitution runs after inlining and fails the build on an unresolved placeholder

The bundler SHALL substitute `{{KEY}}` occurrences from the table returned by
`shader_config.getPlaceholderMap()` (`tools/wgsl_bundle.nim:136`, `src/shader_config.nim:185-266`),
and MUST do so **after** all modules are inlined — `bundle` builds the full concatenated output and
substitutes into it as its last step (`tools/wgsl_bundle.nim:212`). Placeholders therefore work
inside `modules/` exactly as they do in source shaders; `fixed_point.wgsl` and `sph_kernels.wgsl`
depend on this.

A source shader MAY write the shorthand `{{WORKGROUP_SIZE}}`, which resolves against the shader's own
filename: the bundler uppercases the filename and replaces hyphens with underscores to form the key
`WORKGROUP_SIZE_<NAME>` (`tools/wgsl_bundle.nim:143-145`). A shader needing two dimensions MUST name
the explicit keys instead, as the two-dimensional field passes do with `{{WORKGROUP_SIZE_FIELD_X}}`
and `{{WORKGROUP_SIZE_FIELD_Y}}` (`src/shader_config.nim:208-209`).

Any `{{...}}` pair surviving substitution MUST fail the build: the bundler quits with
`Error: Unreplaced placeholder in <shader>` (`tools/wgsl_bundle.nim:152-157`). A misspelled or
unregistered placeholder therefore cannot reach the GPU as literal text.

Every substituted value SHALL originate in Nim. Workgroup sizes and tuning constants come from
`activeConfig` (`src/shader_config.nim:84-126`); field dimensions and seed geometry from
`field_core`, and the blur kernel from `bloom_core` (`src/shader_config.nim:174-183`, `:210-265`). No WGSL file restates a number that
`getPlaceholderMap` serves.

Enforced by: `tools/wgsl_bundle.nim:152-157` (build-time `quit`) and `tests/test_shader_config.nim`,
which checks the accessors and the emitted literals natively — that workgroup sizes are positive
multiples of 32, that the emitted fixed-point reciprocal inverts the emitted scale, that the emitted
bloom weight list has exactly `BLOOM_WEIGHT_COUNT` entries, and that the 2D field tile divides
`FIELD_W x FIELD_H` exactly.

#### Scenario: A shader references an unregistered placeholder

- **WHEN** a source shader or module contains `{{TUNABLE_NOT_A_REAL_KEY}}` and the build runs
- **THEN** the bundler exits non-zero naming the shader and the unreplaced placeholder, and no
  bundled output is written for that shader

#### Scenario: A tuning constant is changed in Nim

- **WHEN** a value in `src/shader_config.nim` changes and the build runs
- **THEN** every bundled shader whose placeholders draw on it is regenerated with the new literal,
  with no WGSL file edited

#### Scenario: A placeholder appears inside an imported module

- **WHEN** a module under `web/shaders/modules/` contains `{{TUNABLE_FIXED_POINT_SCALE}}` and a
  shader imports that module
- **THEN** the bundled output carries the substituted literal, because substitution runs on the
  concatenated result rather than on each file before inlining

### Requirement: Render shaders are embedded by staticRead and stay out of StaticFiles

A render shader SHALL reach the GPU embedded in `web/app.js`. `src/webgpu_render.nim:239-251`
`staticRead`s the bundled `render`, `glow`, `fade`, `composite`, `blur`, `tonemap`, and `overlay`
shaders into string constants at Nim-compile time, so they travel inside the frontend and
are never fetched.

Those shaders MUST NOT appear in the `StaticFiles` table. Serving them would ship the same bytes a
second time, once inside `app.js` and once over HTTP.

A render shader that is absent or unbundled SHALL fail the frontend compile, because `staticRead`
resolves at Nim-compile time — a materially stronger check than the compute route's runtime fetch.

Enforced by: `src/webgpu_render.nim:239-251` (`staticRead`, Nim-compile time). That a render shader
stays absent from `StaticFiles` is **review-enforced**: nothing fails if it is added there, the bytes
are merely duplicated.

#### Scenario: A render shader source is deleted

- **WHEN** `web/shaders/src/glow.wgsl` is removed and the build runs
- **THEN** the bundler produces no `web/shaders/glow.wgsl` and the `nim js` frontend compile fails at
  the `staticRead`, before any runtime

#### Scenario: A new render shader is added

- **WHEN** a shader is authored for the render path and `staticRead` into `src/webgpu_render.nim`
- **THEN** it is not added to `src/shader_manifest.nim` and not added to `StaticFiles`, and it is
  delivered inside `app.js`

### Requirement: Rebundling is driven by modification times over declared inputs

The bundler SHALL rebundle a shader only when an input is newer than its output, and MUST treat
three classes of file as inputs: the source shader itself, every module it names in a `//! import`
directive, and the Nim modules whose constants feed placeholder substitution —
`src/shader_config.nim` and the pure modules it draws from, listed once as `PlaceholderSources`
(`tools/wgsl_bundle.nim:203-212`, read by `needsRebuild` at `:219-244`). A missing output always rebuilds (`:231-232`). Including the Nim
sources is what stops a tuning edit from shipping silently stale shaders: such an edit changes the
bundled bytes without touching any `.wgsl` file.

The check covers a source shader's **direct** imports only; a module reached solely through another
module is not consulted (`tools/wgsl_bundle.nim:242-246`). Every source shader that depends on a
nested module also names that module in its own `//! import` list, which keeps the check complete —
that property is **review-enforced**, with no test or assertion behind it. A source shader that drops
a redundant-looking direct import while still depending on the module transitively would be skipped
after an edit to that module until its output is deleted or another input changes.

Enforced by: `tools/wgsl_bundle.nim:230-254` (build step); the transitive-import property is
review-enforced.

#### Scenario: A tuning constant changes with no shader edit

- **WHEN** `src/shader_config.nim` is edited and the build runs
- **THEN** every bundled shader older than that edit is rebundled, so no shader carries a stale
  substituted literal

#### Scenario: Nothing has changed

- **WHEN** the build runs twice with no edit between
- **THEN** the second run bundles nothing and reports every shader unchanged

#### Scenario: A shared module is edited

- **WHEN** a module under `web/shaders/modules/` is edited
- **THEN** every source shader naming that module in its own `//! import` list is rebundled
