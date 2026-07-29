## MODIFIED Requirements

### Requirement: WGSL validity is established on the device, except where a source lint can reach it

The bundle step SHALL remain a text transformation — import inlining and placeholder substitution —
and MUST NOT be treated as a general check that the resulting WGSL compiles. No build stage invokes a
WGSL compiler, so a bundled shader that names an entry point that does not exist, or misuses a type,
still passes the build intact and fails on the device.

**Two narrow classes are caught at build time, and the bundler SHALL fail on them.** First, a
struct constructor written with named fields — `Camera(centerX: x, zoom: z)` — is a WGSL parse
error, since WGSL constructors are positional only. `src/wgsl_lint.nim` is a pure function over
shader source that detects it, `tools/wgsl_bundle.nim` calls it, and the build quits naming the
shader and the line. Second, each bundled shader's declared `@binding(N)` set SHALL match the
`ExpectedShaderBindings` manifest (`src/wgsl_lint.nim:149-173`): the bundler fails on a mismatch,
and on a shader absent from the table, because silence is not a pass
(`tools/wgsl_bundle.nim:229-243`). The manifest holds the declared set per shader; which resource
the pipeline places at each binding remains checkable only in a running app.

The constructor class earns build-time enforcement where the general case cannot, for two reasons. It is
detectable by inspection of the text alone, needing no compiler. And it is a mistake this codebase
invites specifically: the structs being constructed are GENERATED from Nim objects where that exact
syntax is correct, so the habit transfers and the result builds green.

The constructor lint SHALL stay narrow deliberately. It flags only a callee beginning with an uppercase letter,
because every struct type here is PascalCase and every WGSL builtin is lowerCamel — a false positive
would block every build, which is a worse failure than the one being prevented. Its known blind spot,
a constructor whose fields begin on the line after the callee, SHALL be recorded as a test rather
than left to be rediscovered.

Compute shaders SHALL continue to be checked on the device after module creation, and render shaders
SHALL continue to surface errors through the device's own reporting. Neither changes.

Enforced by: `src/wgsl_lint.nim` with `tests/test_wgsl_lint.nim` (build-time, these two classes only);
`src/webgpu_compute.nim` (runtime, compute path). For render shaders and for every other class of
build-time WGSL validity, there is still no enforcement point — review-enforced, with the working
application as the check.

#### Scenario: A named-field struct constructor fails the build

- **WHEN** any shader under `web/shaders/src/` or `web/shaders/modules/` constructs a struct with
  named fields and the shader step runs
- **THEN** the build fails, naming the shader and the offending line, and no bundled output is
  written for it

#### Scenario: A shader added later is covered without anyone remembering

- **WHEN** a new shader source file is added
- **THEN** the lint's own test reads the shader directories directly, so the new file is checked with
  no test edit, and a companion assertion fails if those directories cannot be found — so the check
  cannot pass vacuously from the wrong working directory

#### Scenario: A binding drift fails the bundle

- **WHEN** a shader's declared binding set disagrees with the `ExpectedShaderBindings` manifest, or
  a shader bundles with no manifest entry at all
- **THEN** the build quits naming the shader and both sets, and no bundled output ships for it

#### Scenario: Every other class of invalid WGSL still reaches the device

- **WHEN** a source shader names an entry point that does not exist
- **THEN** the build still succeeds and the failure appears on the device, exactly as before
