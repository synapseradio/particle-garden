# checkout-bootstrap

## Purpose

Governs the entry conditions of a build: what a checkout that has never been built must acquire
before any compile can succeed, which command supplies it, and what detects the supply breaking. A
clone, a `git worktree add`, and a `wt switch --create` all land in the same state, so this
capability speaks of a checkout, which every one of those tools produces. How the build runs once
those conditions hold belongs to `build-pipeline`. Which revisions it resolves against belongs to
`dependency-pinning`.

## Requirements

### Requirement: A checkout that has never been built SHALL build through `just happen` alone

`just happen` SHALL succeed on a checkout carrying no build state, with no dependency command typed
first, when that checkout was created by `wt switch --create`. This is the command CLAUDE.md names
for use after every change, and it is the first command a fresh checkout meets. The bootstrap is the
`[pre-start]` hook in `.config/wt.toml`, which `wt` runs before handing the worktree back. `wt` reads
that hook from the checkout the command is invoked in, so the invoking checkout must carry
`.config/wt.toml`.

The state that makes this fail is `nimble.paths`, absent from every fresh checkout because
`.gitignore:54` keeps it out of the repository. `config.nims:3` passes `--noNimblePath`
unconditionally and `config.nims:4-5` restores the search path only by including that file, so
without it `import webui` (`src/main.nim:17`) resolves against nothing and `build-native`
(`justfile:37-38`) fails with `cannot open file: webui`. `release` (`justfile:98-99`) compiles the
same module and fails the same way.

The other artifacts a fresh checkout lacks do not need this guarantee inside `just happen`, which
supplies them itself: `build-ui` (`justfile:33-34`) runs `bun install --frozen-lockfile`, and
`build-app` (`justfile:28`) and `build-ui` write every file they consume as `happen`'s own steps
run. `shaders` (`justfile:22-23`) is the exception: a compile narrower than `happen`, such as a
bare `nim js` invocation against `src/app.nim` run to type-check without building the rest, skips
the `shaders` step and needs the bundle already in place. The next requirement covers that case.

For a checkout created by `wt switch --create`, this requirement is **agent-checkable**. The
procedure: from a checkout carrying `.config/wt.toml`, create a throwaway with
`wt switch --create zz-check-<slug> -y --no-cd`, run `just happen` in it as the first command, and
read the exit code and whether `main` exists at the checkout root. A non-zero exit or a missing
binary is the violation. The check runs in a throwaway checkout, never in one holding work.

For a `git clone` or a plain `git worktree add`, this requirement is **unenforced**: no hook fires on
those routes, and `just happen` fails there with `cannot open file: webui` until `just deps` runs. A
guard in the `justfile` that runs `deps` when `nimble.paths` is absent would close that.

#### Scenario: A fresh wt checkout builds on the first command

- **WHEN** `just happen` runs as the first command in a checkout that `wt switch --create` made from
  a checkout carrying `.config/wt.toml`
- **THEN** it SHALL exit 0 and leave an executable `main` at the checkout root

#### Scenario: The absent artifact is named by the failure it causes

- **WHEN** `src/main.nim` is compiled in a checkout where `nimble.paths` does not exist
- **THEN** the compile SHALL fail at `src/main.nim:17` with `cannot open file: webui`, and no
  earlier build stage SHALL fail

### Requirement: A fresh checkout SHALL carry the bundled shaders before any compile

The bootstrap SHALL leave `web/shaders/*.wgsl` in place, so a compile narrower than `just happen` —
a bare `nim js` invocation against `src/app.nim`, the form a type-check without a full build takes —
gets past the shader includes with no prior `just shaders`. `web/shaders/*.wgsl` is gitignored
output, produced only by `just shaders` (`justfile:22-23`). Without it, `src/webgpu_render.nim:206`'s
`staticRead("../web/shaders/render.wgsl")` fails with `cannot open file: ../web/shaders/render.wgsl`.

`just happen` already supplies this bundle as its own first step and needs no further guarantee. The
gap this requirement closes is the bare compile that skips `happen` entirely, which two delegates
met in a `wt`-created worktree that carried `nimble.paths` but not the bundle.

The `[pre-start]` hook in `.config/wt.toml` runs `just shaders` after `just deps`, and SHALL verify
that `web/shaders/render.wgsl` exists afterward, exiting non-zero and saying that the bundle was not
produced when it does not. `tools/wgsl_bundle.nim` imports only the standard library and sibling
modules under `src/` (no nimble package), so running it before `nimble.paths` exists is safe.

This requirement is **agent-checkable**. The procedure: from a checkout carrying `.config/wt.toml`,
create a throwaway with `wt switch --create zz-check-<slug> -y --no-cd`, and in it compile
`src/app.nim` directly with `nim js`, with no `just shaders` run first. A "cannot open file" error
naming `web/shaders` is the violation.

#### Scenario: A fresh wt checkout compiles a bare nim js target without a prior `just shaders`

- **WHEN** `nim js ... src/app.nim` is compiled directly, with no `just shaders` run first, in a
  checkout that `wt switch --create` made from a checkout carrying `.config/wt.toml`
- **THEN** it SHALL get past the shader includes, with no "cannot open file" error naming
  `web/shaders`

#### Scenario: Shader bundling that produces nothing is named by the failure it causes

- **WHEN** the bootstrap's `just shaders` step exits 0 but leaves `web/shaders/render.wgsl` absent
- **THEN** the bootstrap SHALL exit non-zero and SHALL say that the shader bundle was not produced

### Requirement: The bootstrap SHALL run the repository's own `deps` recipe

Whatever supplies `nimble.paths` SHALL invoke `just deps` (`justfile:82-84`) and MUST NOT restate
the dependency commands it runs. `deps` is the one home for the fact that bootstrapping this
repository means `nimble install -d -y` followed by `nimble setup`. A hook, config file, or recipe
that spells those out separately is a second home for that fact, and the two drift when the lock
changes.

A checkout is bootstrapped exactly when `nimble.paths` exists at its root and names that same
checkout's `src` directory. `nimble setup` generates absolute paths for the tree it runs in, so a
`nimble.paths` copied from another checkout names that other checkout's `src`. Nothing resolves
through that entry while modules under `src/` import siblings, which the compiler finds in the
importing file's own directory, and `tests/*.nim` reach `src/` by relative import
(`import ../src/config_ranges`). The entry becomes live the moment any module outside `src/` is
imported by bare name. Copying `nimble.paths` between checkouts SHALL NOT be used as the bootstrap.

This requirement is **agent-checkable**. The procedure: read `.config/wt.toml` and confirm the only
dependency command it names is `just deps`. Then bootstrap a fresh checkout and read `nimble.paths`,
confirming its `--path` entry for `src` names that checkout's own root.

#### Scenario: The bootstrap names one command

- **WHEN** the mechanism that bootstraps a fresh checkout is read
- **THEN** it SHALL invoke `just deps` and SHALL NOT contain `nimble install` or `nimble setup`

#### Scenario: A bootstrapped checkout points at itself

- **WHEN** `nimble.paths` is read in a checkout the bootstrap has just run in
- **THEN** its `--path` entry for the project source SHALL name that checkout's own `src` directory

### Requirement: A bootstrap that produces no `nimble.paths` SHALL fail loudly

The bootstrap SHALL verify that `nimble.paths` exists at the checkout root after it runs, and SHALL
exit non-zero when it does not. nimble 0.22.x exits 0 even when a task's `exec` fails, a trap
`build-pipeline` already records (`openspec/specs/build-pipeline/spec.md:51`) and CLAUDE.md
repeats. Without the check, a bootstrap whose nimble invocation failed reports success and hands
back a checkout that dies later at `build-native` with a message naming `webui`, which sends the
reader looking at the dependency instead of at the step that failed to supply it.

The check is a file-existence test on a known path in `.config/wt.toml`, so it holds whatever
nimble reports.

This requirement is **agent-checkable**. The procedure: run the bootstrap in a throwaway checkout
with a `nimble` stub earlier on `PATH` that exits 0 and writes nothing, then read the bootstrap's
exit code. A zero exit is the violation.

#### Scenario: nimble reports success and writes nothing

- **WHEN** the bootstrap runs against a `nimble` that exits 0 without generating `nimble.paths`
- **THEN** the bootstrap SHALL exit non-zero and SHALL say that `nimble.paths` was not produced

#### Scenario: A successful bootstrap leaves the artifact behind

- **WHEN** the bootstrap exits 0
- **THEN** `nimble.paths` SHALL exist at the checkout root

### Requirement: The bootstrap SHALL stay out of the way of a checkout that already builds

Running the bootstrap in a checkout that already holds `nimble.paths` and the shader bundle SHALL
change no build output and SHALL cost under one second. `just deps` completes in 0.154 s against a
satisfied machine-global package cache, and `nimble setup` alone in 0.301 s. `just shaders` against
an unchanged bundle completes in 0.111 s, since `tools/wgsl_bundle.nim` skips writing a file whose
content has not changed (`tools/wgsl_bundle.nim:343`). The budget is stated so that a bootstrap
moved onto a per-build path stays cheap enough to sit there.

The artifact the bootstrap writes SHALL remain untracked. `.gitignore:54` matches `nimble.paths`,
and `dependency-pinning` records it there (`openspec/specs/dependency-pinning/spec.md:157`). A
bootstrap that committed it would carry one developer's absolute paths into every other checkout.

This requirement is **agent-checkable**. The procedure: time the bootstrap in an already-built
checkout, then run `git status --short` and confirm it reports nothing.

#### Scenario: A second run costs nearly nothing

- **WHEN** the bootstrap runs in a checkout that already holds `nimble.paths` and the shader bundle
- **THEN** it SHALL complete in under one second and SHALL exit 0

#### Scenario: The bootstrap dirties no tracked file

- **WHEN** the bootstrap runs in a clean checkout
- **THEN** `git status --short` SHALL report no change
