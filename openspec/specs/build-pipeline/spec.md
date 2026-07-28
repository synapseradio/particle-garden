# build-pipeline

## Purpose

Orchestrates the four compilation stages — shader bundle, Nim JS frontend, Bun UI bundle, native
binary — into one ordered, fail-fast build that produces a self-contained executable. It is one
capability rather than four because the stages are not independent: `nim c` and `nim js` embed
earlier stages' output at compile time via `staticRead`, so the order is a correctness constraint,
not a convenience. This capability owns *how the build runs*; what it resolves dependencies against
belongs to `dependency-pinning`, and what the shader preprocessor does to a `.wgsl` file belongs to
`shader-pipeline`.

## Requirements

### Requirement: Stage order follows the compile-time embed graph

The build SHALL run four stages in the order `shaders` → `build-app` → `build-ui` → `build-native`
(`justfile:38`, and the same order restated by `justfile:60-61` for the release build). The order is
forced by two `staticRead` edges, each of which reads a file from disk at Nim-compile time:

- `src/webgpu_render.nim:148-159` embeds seven bundled render shaders (`render`, `glow`, `fade`,
  `composite`, `field-composite`, `blur`, `tonemap`) into `web/app.js`. `shaders` MUST therefore
  precede `build-app`.
- `src/main.nim:37-61` embeds `web/index.html`, `web/app.js`, `web/ui-bundle.js`,
  `web/ui-bundle.css`, and thirteen bundled compute shaders into the native binary. `shaders`,
  `build-app`, and `build-ui` MUST therefore all precede `build-native`.

Because `staticRead` resolves at compile time, a missing input fails the compile that reads it.
`web-ui/build.ts:1-5` records the same constraint at the producing end.

#### Scenario: Full build honors the order

- **WHEN** `just happen` runs
- **THEN** `shaders`, `build-app`, and `build-ui` all complete before `nim c --out:main src/main.nim`
  is invoked

#### Scenario: A missing embedded artifact fails the native compile

- **WHEN** `nim c --out:main src/main.nim` runs without `web/ui-bundle.js` on disk
- **THEN** the compile fails at the `staticRead` in `src/main.nim:43` rather than producing a binary

#### Scenario: Release build repeats the same order

- **WHEN** `just release` runs
- **THEN** it depends on `shaders build-app build-ui` before compiling `src/main.nim`
  (`justfile:60-61`)

### Requirement: Build stages invoke the compilers directly

Every build and test recipe SHALL invoke `nim` or `bun` directly and MUST NOT delegate to a nimble
task. nimble 0.22.x exits 0 even when a task's `exec` fails, so a nimble-driven recipe cannot fail
the build: a broken compile reports success and leaves the previous artifact in place, which the
next `staticRead` then embeds. Enforcement points: `justfile:23,27,31,35,43,61` are direct `nim` and
`bun` invocations, and `.github/workflows/release.yml:57-61` gates and builds through `just check`
and `just release` rather than through nimble.

The nimble tasks in `particle_garden.nimble:38-68` remain available for manual invocation, and
`nimble install --depsOnly` / `nimble setup` remain the dependency-resolution entry points
(`.github/workflows/release.yml:49-54`). Neither the `all` task nor the `release` task builds the UI
bundle, so neither reproduces the `build-ui` stage this capability requires; only the `just` recipes
are a complete build.

`just` aborts an invocation when any dependency recipe exits non-zero and propagates that exit code,
so a failed stage stops the build before a later stage can embed a stale artifact.

#### Scenario: A failing stage stops the build

- **WHEN** `nim js` exits non-zero during `just happen`
- **THEN** `just` aborts with that exit code and `build-ui` and `build-native` do not run

#### Scenario: CI never builds through nimble

- **WHEN** the release workflow builds a platform artifact
- **THEN** it runs `just release`, and the only nimble invocations in the workflow are
  `nimble install -y --depsOnly --useSystemNim` and `nimble setup`

### Requirement: Every stage regenerates its artifact unconditionally

Each build recipe SHALL rebuild its output on every invocation, with no timestamp comparison,
content hash, or other staleness guard (`justfile:22-35`). Artifact freshness is a consequence of
unconditional regeneration in a fixed order under fail-fast semantics, not of dependency tracking —
there is nothing in the build that would detect an artifact newer than its inputs and skip the work,
and nothing that would detect one older than its inputs and force the work.

The corollary is that freshness holds only for artifacts produced within a single `just happen` or
`just release` invocation. Compiling `src/main.nim` by any other route embeds whatever is on disk.

#### Scenario: An unchanged tree still rebuilds

- **WHEN** `just happen` runs twice with no source edit in between
- **THEN** all four stages execute both times

#### Scenario: Out-of-band native compile embeds whatever exists

- **WHEN** `just build-native` runs alone after an edit to `web-ui/src/`
- **THEN** the binary embeds the previously built `web/ui-bundle.js`, because no recipe rebuilds it

### Requirement: Nim compilations carry the quality flag set

Every `nim` invocation in the build and test recipes SHALL pass `--styleCheck:error
--styleCheck:usages`, warnings-as-errors for `Deprecated`, `BareExcept`, `CStringConv`, `EnumConv`,
`HoleEnumConv`, `SmallLshouldNotBeUsed`, `ProveInit`, `UnusedImport`, and `Effect`, and
`--hint:XDeclaredButNotUsed:on` (`justfile:12`, applied at `justfile:23,27,35,43,61`). An unused
import, an unused declaration, or a bare `except` fails the compile. The JS and native builds add
`-d:release` and `-d:release --opt:speed` respectively (`justfile:13-14`); the Windows release adds
static MinGW linking (`justfile:17`).

The same flag strings are declared a second time in `particle_garden.nimble:17-36` for the nimble
tasks. Keeping the two declarations identical is **review-enforced**: no test, hook, or build step
compares them, so a flag added to one file and not the other produces a nimble task that compiles
code the `just` recipes would reject, or the reverse.

#### Scenario: An unused import fails the build

- **WHEN** a module in `src/` imports a symbol it does not use
- **THEN** `just build-app` fails on `--warningAsError:UnusedImport`

#### Scenario: Flag drift is invisible to the build

- **WHEN** a warning-as-error flag is added to `justfile:12` but not to
  `particle_garden.nimble:19`
- **THEN** every recipe and every CI step still passes, and only review catches the divergence

### Requirement: The native binary embeds every asset it serves

The server SHALL serve web assets exclusively from the compile-time `StaticFiles` table
(`src/main.nim:37-61`, dispatched at `src/main.nim:78-85`) and MUST NOT read any file from disk at
run time. The shipped binary is therefore self-contained: release packaging moves the single
executable into an archive with no accompanying `web/` directory
(`.github/workflows/release.yml:66-121`).

The consequence for the build is that registration in `StaticFiles` is what makes a new web asset
reachable. An asset produced by an earlier stage but absent from the table is built and then never
served; a request for it falls through to the 404 branch at `src/main.nim:86-87`.

#### Scenario: An unregistered asset is unreachable

- **WHEN** the frontend fetches a path with no entry in `StaticFiles`
- **THEN** the server responds 404, regardless of whether the file exists in `web/`

#### Scenario: The packaged artifact carries no web directory

- **WHEN** the release workflow packages a platform artifact
- **THEN** it archives only the executable

### Requirement: Generated artifacts stay untracked

Every artifact a build stage writes SHALL be listed in `.gitignore` — `main`, `web/app.js`,
`web/ui-bundle.js`, `web/ui-bundle.css`, `tools/wgsl_bundle`, top-level `web/shaders/*.wgsl`, and the
six emitted `web/shaders/modules/*_params.wgsl` files (`.gitignore:2-17`). `git check-ignore`
confirms the state for any one of them. Sources that a build stage reads but never writes stay
tracked: `web/index.html`, `web/shaders/src/*.wgsl`, and the hand-written `web/shaders/modules/`
files are in the index.

Hand-editing a generated file is **review-enforced** — no hook or test rejects it. What the tracking
boundary does provide is that such an edit cannot be committed and does not survive: the next run of
the owning stage overwrites the file unconditionally, and `git status` never shows the change.

#### Scenario: A generated artifact cannot enter the index

- **WHEN** `git check-ignore -v web/app.js` runs
- **THEN** it reports the matching `.gitignore` rule and exits 0

#### Scenario: A hand edit is destroyed by the next build

- **WHEN** `web/app.js` is edited by hand and `just happen` runs
- **THEN** `build-app` overwrites the file and the edit is lost with no warning

### Requirement: Both test suites gate the release and need no build artifact

`just check` SHALL run the native Nim suite and the TypeScript suite (`justfile:50`, delegating to
`justfile:42-47`), and the release workflow SHALL run it before building the release
(`.github/workflows/release.yml:57-61`). A red suite therefore blocks a release on every platform in
the matrix.

The gate is independent of the build stages: `tests/test_all.nim` imports only pure modules and no
module containing a `staticRead`, so `just check` compiles and passes on a tree where `web/app.js`
and `web/ui-bundle.*` do not exist. This is why the workflow can order `just check` ahead of
`just release` rather than after it.

#### Scenario: Tests run before the release build

- **WHEN** the release workflow runs on any matrix platform
- **THEN** `just check` completes successfully before `just release` starts

#### Scenario: Tests pass on a tree with no build artifacts

- **WHEN** `just check` runs on a fresh checkout with no prior build
- **THEN** both suites compile and run, because no test module reaches a `staticRead`
