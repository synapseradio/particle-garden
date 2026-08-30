## Why

A worktree or clone that has never been built cannot build. `just happen` runs three stages
green and then dies on the fourth with `src/main.nim(16, 8) Error: cannot open file: webui`,
and the person at the keyboard has to know to run `nimble setup` first. The cause is on disk in
two tracked lines: `config.nims:3` passes `--noNimblePath` unconditionally, and `config.nims:4-5`
restores the search path only by including `nimble.paths`, which `.gitignore:50` keeps out of the
repository. A fresh tree therefore compiles with nimble's package search switched off and nothing
put back, so `import webui` (`src/main.nim:16`) resolves against nothing.

`README.md:112-113` already documents the manual `nimble install -d -y` and `nimble setup` for a
clone, and `just be` (`justfile:69-72`) already runs `deps` before `happen`. Neither reaches the
command CLAUDE.md tells everyone to run after every change, which is `just happen`. That is the
command a fresh tree meets first, and it is the one that fails.

The bootstrap that fixes it costs 0.154 s. Every fresh tree pays a failed build and a lookup
instead.

## What Changes

- A checkout that has never been built acquires `nimble.paths` before anything needs it, without a
  person typing a command. A `wt` project config committed to this repository carries the bootstrap.
  The user chose it over a hook private to their dotfiles and over a guard inside the `justfile`.
  `design.md` D1 prices all three on one scale and records what the choice gives up.
- A regression check that fails when the guarantee breaks: a fresh tree must reach a built binary
  through the project's own entry point alone.
- No behavior the app exposes changes. Nothing is removed.

## Capabilities

### New Capabilities

- `checkout-bootstrap`: what a checkout that has never been built must acquire before the build
  can run, which command supplies it, and what detects the guarantee breaking. It covers the
  entry conditions of a build. The name says checkout because a clone and a `git worktree add`
  land in the same state a `wt switch --create` does. Stage order, quality flags, and the nimble
  exit-code trap stay with `build-pipeline`. Which revisions the build resolves against stays with
  `dependency-pinning`.

### Modified Capabilities

None. `build-pipeline` states the four-stage order (`openspec/specs/build-pipeline/spec.md:15-46`)
and `dependency-pinning` already records `nimble.paths` as gitignored
(`openspec/specs/dependency-pinning/spec.md:157`). Neither claim changes. The chosen mechanism fires
at checkout creation, outside the build, so `build-pipeline`'s stage list stands as written.

## Impact

**Measured, in a throwaway worktree created and removed for this purpose**
(`scratchpad/worktree-bootstrap-hook/measurements__30-08-26-1700.md`):

- `just happen` on a fresh worktree: `shaders`, `build-app`, and `build-ui` all green,
  `build-native` red with `cannot open file: webui`, 2.590 s to the failure.
- `bun install --frozen-lockfile` inside `build-ui` (`justfile:30-31`) installs 73 packages in
  36 ms, so the missing `web-ui/node_modules` costs milliseconds and no failure. `nimble.paths` is
  the only absent artifact that stops the build.
- `nimble setup` alone: 0.301 s, then `just happen` green in 2.228 s.
- `just deps` (`justfile:64-66`) from the same state: 0.154 s, then `just check` green in 1:46.
- `just test` ran green with `nimble.paths` absent, because `tests/*.nim` reach `src/` by relative
  import (`import ../src/config_ranges`) and never through `--path`. The defect is confined to
  `build-native` and `release`, the two recipes that compile `src/main.nim`.

**Scope of who is affected.** Four worktrees of this repository sit under
`.claude/worktrees/agent-*`, created by the Claude Code harness at paths the `wt` worktree-path
template never produces, and all four lack `nimble.paths`. A `wt` hook reaches none of them,
whether it is committed to the repository or private to one developer, and it reaches neither a
plain `git clone` nor a plain `git worktree add`. Those routes keep the manual bootstrap, which is
what the chosen mechanism gives up and what D1 prices.

**Files this change touches**: `.config/wt.toml` (new), the Build from Source block in
`README.md:104-117`, and the "Build and test" bullet in `CLAUDE.md`, plus a regression check.

**Feasibility**: proven. Every number above comes from a run recorded in the measurement file, not
from a plan. No gate remains open on whether the fix works, and the delivery mechanism is chosen.
