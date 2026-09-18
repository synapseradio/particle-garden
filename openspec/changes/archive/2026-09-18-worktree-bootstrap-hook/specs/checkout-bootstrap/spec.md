## Purpose

Governs the entry conditions of a build: what a checkout that has never been built must acquire
before any compile can succeed, which command supplies it, and what detects the supply breaking. A
clone, a `git worktree add`, and a `wt switch --create` all land in the same state, so this
capability speaks of a checkout, which every one of those tools produces. How the build runs once
those conditions hold belongs to `build-pipeline`. Which revisions it resolves against belongs to
`dependency-pinning`.

## ADDED Requirements

### Requirement: A checkout that has never been built SHALL build through `just happen` alone

`just happen` SHALL succeed on a checkout carrying no build state, with no dependency command typed
first. This is the command CLAUDE.md names for use after every change, and it is the first command a
fresh checkout meets.

The state that makes this fail is `nimble.paths`, absent from every fresh checkout because
`.gitignore:50` keeps it out of the repository. `config.nims:3` passes `--noNimblePath`
unconditionally and `config.nims:4-5` restores the search path only by including that file, so
without it `import webui` (`src/main.nim:16`) resolves against nothing and `build-native`
(`justfile:34-35`) fails with `cannot open file: webui`. `release` (`justfile:76-77`) compiles the
same module and fails the same way.

The other artifacts a fresh checkout lacks do not need this guarantee. `build-ui`
(`justfile:30-31`) runs `bun install --frozen-lockfile` itself, and `shaders` (`justfile:22-23`),
`build-app` (`justfile:26-27`) and `build-ui` write every file they consume.

This requirement is **agent-checkable**. The procedure: create a checkout of this repository
carrying no build state, run `just happen` in it as the first command, and read the exit code and
whether `main` exists at the checkout root. A non-zero exit or a missing binary is the violation.
The check runs in a throwaway checkout, never in one holding work.

#### Scenario: A fresh checkout builds on the first command

- **WHEN** `just happen` runs as the first command in a checkout that has never been built
- **THEN** it SHALL exit 0 and leave an executable `main` at the checkout root

#### Scenario: The absent artifact is named by the failure it causes

- **WHEN** `src/main.nim` is compiled in a checkout where `nimble.paths` does not exist
- **THEN** the compile SHALL fail at `src/main.nim:16` with `cannot open file: webui`, and no
  earlier build stage SHALL fail

### Requirement: The bootstrap SHALL run the repository's own `deps` recipe

Whatever supplies `nimble.paths` SHALL invoke `just deps` (`justfile:64-66`) and MUST NOT restate
the dependency commands it runs. `deps` is the one home for the fact that bootstrapping this
repository means `nimble install -d -y` followed by `nimble setup`. A hook, config file, or recipe
that spells those out separately is a second home for that fact, and the two drift when the lock
changes.

A checkout is bootstrapped exactly when `nimble.paths` exists at its root and names that same
checkout's `src` directory. `nimble setup` generates absolute paths for the tree it runs in, so a
`nimble.paths` copied from another checkout names that other checkout's `src`. Nothing resolves
through that entry today. Modules under `src/` import siblings, which the compiler finds in the
importing file's own directory, and `tests/*.nim` reach `src/` by relative import
(`import ../src/config_ranges`). The entry becomes live the moment any module outside `src/` is
imported by bare name. Copying `nimble.paths` between checkouts SHALL NOT be used as the bootstrap.

This requirement is **agent-checkable**. The procedure: read whatever mechanism the design selects
and confirm the only dependency command it names is `just deps`. Then bootstrap a fresh checkout
and read `nimble.paths`, confirming its `--path` entry for `src` names that checkout's own root.

#### Scenario: The bootstrap names one command

- **WHEN** the mechanism that bootstraps a fresh checkout is read
- **THEN** it SHALL invoke `just deps` and SHALL NOT contain `nimble install` or `nimble setup`

#### Scenario: A bootstrapped checkout points at itself

- **WHEN** `nimble.paths` is read in a checkout the bootstrap has just run in
- **THEN** its `--path` entry for the project source SHALL name that checkout's own `src` directory

### Requirement: A bootstrap that produces no `nimble.paths` SHALL fail loudly

The bootstrap SHALL verify that `nimble.paths` exists at the checkout root after it runs, and SHALL
exit non-zero when it does not. nimble 0.22.x exits 0 even when a task's `exec` fails, a trap
`build-pipeline` already records (`openspec/specs/build-pipeline/spec.md:48-55`) and CLAUDE.md
repeats. Without the check, a bootstrap whose nimble invocation failed reports success and hands
back a checkout that dies later at `build-native` with a message naming `webui`, which sends the
reader looking at the dependency instead of at the step that failed to supply it.

The check is a file-existence test on a known path, so it holds whatever nimble reports.

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

Running the bootstrap in a checkout that already holds `nimble.paths` SHALL change no build output
and SHALL cost under one second. `just deps` completes in 0.154 s against a satisfied machine-global
package cache, and `nimble setup` alone in 0.301 s. The budget is stated so that a bootstrap moved
onto a per-build path stays cheap enough to sit there.

The artifact the bootstrap writes SHALL remain untracked. `.gitignore:50` already matches
`nimble.paths`, and `dependency-pinning` records it there
(`openspec/specs/dependency-pinning/spec.md:157`). A bootstrap that committed it would carry one
developer's absolute paths into every other checkout.

This requirement is **agent-checkable**. The procedure: time the bootstrap in an already-built
checkout, then run `git status --short` and confirm it reports nothing.

#### Scenario: A second run costs nearly nothing

- **WHEN** the bootstrap runs in a checkout that already holds `nimble.paths`
- **THEN** it SHALL complete in under one second and SHALL exit 0

#### Scenario: The bootstrap dirties no tracked file

- **WHEN** the bootstrap runs in a clean checkout
- **THEN** `git status --short` SHALL report no change
