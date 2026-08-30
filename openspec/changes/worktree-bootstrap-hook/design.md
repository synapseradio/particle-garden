## Context

See the Why section of `proposal.md` for the motivation and `specs/checkout-bootstrap/spec.md` for
the requirements. This section carries only what shapes the choice of mechanism.

**What the environment offers.** `wt` is worktrunk, installed here at version 0.67.0
(`wt --version`). It fires ten hook types, five blocking `pre-*` and five background `post-*`, and
reads them from two places: a project config at `.config/wt.toml`, committed and shared, and a user
config at `~/.config/worktrunk/config.toml`, private, which also carries a `[projects."<id>"]`
table for per-repository settings. Project hooks need approval on first run, saved to
`~/.config/worktrunk/approvals.toml`, and a changed command needs approval again. User hooks need
none. User hooks run first, project hooks after. Sources: `wt hook --help` and `wt config --help`
from the installed 0.67.0 binary, and https://worktrunk.dev/hook/ and https://worktrunk.dev/config/.

The published releases reach 0.69.2 (https://github.com/max-sixty/worktrunk/releases), so the site
documents a version ahead of the installed binary. On every fact this design uses the two agree
verbatim. They differ on two points nothing here touches: the site lists a `{{ remote_repo }}`
template variable and a `wt hook show --expanded` flag that 0.67.0's help does not mention.

**What this repository already has.** No `.config/wt.toml`. The `wt` project identifier is
`github.com/synapseradio/particle-garden` (`wt config show`). The user's private config carries
five `pre-start` hooks named `stack`, `nest`, `openspec`, `openspec-skills`, and `scratchpad`,
three of which call scripts under `~/.dotfiles/.config/worktrunk/`, plus three matching
`pre-remove` hooks. All five fire at `pre-start`.

**Which routes make a checkout.** Four routes reach this repository, and a `wt` hook serves them
unequally:

| Route | Reached by a `wt` hook |
|---|---|
| `wt switch --create` | yes |
| `git worktree add`, which the Claude Code harness uses | no |
| `git clone` | no |
| The release workflow | not applicable, since it bootstraps explicitly at `.github/workflows/release.yml:49-54` |

The second row is measured. Four worktrees of this repository sit under `.claude/worktrees/agent-*`,
created by the harness at paths the `wt` worktree-path template never produces, and all four lack
`nimble.paths`.

## Goals / Non-Goals

**Goals:**

- One mechanism that makes `just happen` succeed as the first command in a checkout that has never
  been built.
- A failure that names the bootstrap when the bootstrap is what failed, given that nimble 0.22.x
  reports success on a failed task.
- The dependency commands stated once, in `just deps`.

**Non-Goals:**

- Reproducing what `.github/workflows/release.yml:49-54` already does. CI bootstraps explicitly and
  keeps doing so.
- Warming a build cache, sharing `nimcache/`, or shortening a cold build. The subject here is a
  build that cannot run at all.
- Pinning or vendoring anything. `dependency-pinning` owns that and is untouched.
- Changing what `just deps` does.

## Decisions

### D1. A `wt` project config committed to this repository carries the bootstrap

Three mechanisms deliver the guarantee. They are priced below on one scale.

**Option A, a `wt` project config committed to this repository.** A new `.config/wt.toml` at the
repository root carrying `[pre-start] bootstrap = "just deps"`.

**Option B, a `wt` hook in the user's private dotfiles.** An entry under
`[projects."github.com/synapseradio/particle-garden"]` in `~/.config/worktrunk/config.toml`,
beside the five hooks already there, or a sixth key in the existing `[[pre-start]]` block.

**Option C, a guard inside the `justfile`.** A private `bootstrap` recipe that runs `just deps`
when `nimble.paths` is absent and then fails when the file still is not there, added to the
dependency list of `build-native` (`justfile:34`) and `release` (`justfile:76`).

| | A: project `wt` config | B: private `wt` config | C: `justfile` guard |
|---|---|---|---|
| Routes served | `wt switch --create` | `wt switch --create` | every route that runs `just` |
| The four harness worktrees | not served | not served | served |
| A fresh `git clone` | not served | not served | served |
| Under this repo's version control | yes | no | yes |
| Serves a second contributor | yes, after they approve | no | yes |
| Approval friction | one prompt per person, again on every edit to the command | none | none |
| Cost on the build path | none | none | one `test -f` per invocation of `build-native` |
| Cost at checkout creation | 0.154 s, blocking | 0.154 s, blocking | none |
| Cost on first build of a checkout | none | none | 0.154 s, once |
| Spec deltas | `checkout-bootstrap` only | `checkout-bootstrap` only | `checkout-bootstrap` plus a `build-pipeline` delta for the stage list |
| Silently stops working when | worktrunk changes its hook format, or the person declines approval once | the user's dotfiles move to a machine without them | nothing found |

The timings are measured. `just deps` runs in 0.154 s and `nimble setup` in 0.301 s against a
satisfied `~/.nimble/pkgs2`, recorded in
`scratchpad/worktree-bootstrap-hook/measurements__30-08-26-1700.md`.

**Chosen: option A.** It buys a bootstrap that lives under this repository's version control, fires
for anyone who creates a `wt` worktree, and adds nothing to the build path. The recommendation on
this page was option C, and the user chose A over it.

**What A gives up.** Four worktrees under `.claude/worktrees/agent-*`, a plain `git worktree add`,
and a `git clone` all reach this repository by routes no `wt` hook fires on. Those routes keep the
manual bootstrap `README.md:112-113` already documents, and a build there still opens with
`cannot open file: webui`. Option C was the only column serving them. That coverage is the price of
A, and task 5.1 records the unclaimed routes as still failing so the gap stays visible in the record
of what shipped.

A person approves the hook on first run, and again after any edit to its command. The command stays
the string `just deps`, and the authority it delegates to lives in the `justfile`, which approval
does not gate.

C stays available on top of A later and the two compose without conflict, since a checkout created
by `wt` reaches `just happen` the same way every other checkout does.

Rejected outright:

- **Do nothing.** `README.md:112-113` documents the manual step for a clone and `just be`
  (`justfile:69-72`) runs `deps` before `happen`. Neither reaches `just happen`, which CLAUDE.md
  names for use after every change, so every fresh checkout still pays a failed build first.
- **Commit `nimble.paths`.** It holds absolute paths generated for the checkout that ran
  `nimble setup`, so a committed copy names one developer's directory. `.gitignore:50` and
  `openspec/specs/dependency-pinning/spec.md:157` both keep it out.
- **`wt step copy-ignored` in a hook,** which worktrunk documents as its own recipe for this class
  of problem (https://worktrunk.dev/hook/, "Copying untracked files"). Measured here: it copied 4002
  files and 130.2 MiB, and the `nimble.paths` it produced named
  `/Users/nick/projects/ai/particle-garden/src`, the source tree of a different checkout. The build
  still went green, because modules under `src/` import siblings the compiler finds in the
  importing file's own directory and `tests/*.nim` use relative imports, so nothing resolves through
  that entry. It is a wrong path that happens to be unread, and it becomes live the first time a
  module outside `src/` is imported by bare name.

### D2. The hook fires at `pre-start`, over `post-start`

The bootstrap blocks worktree creation and aborts it on failure.

worktrunk's own guidance points the other way: "Prefer `post-start` over `pre-start` unless a later
step needs the work completed first" (https://worktrunk.dev/hook/ and `wt hook --help`). A later
step does need it here. `wt switch --create -x claude` replaces the `wt` process with an agent as
soon as the worktree exists, and `pre-start` is documented as blocking `--execute` until it
completes while `post-start` runs in the background. A `post-start` bootstrap therefore races an
agent that opens with `just happen`, and the race window is the 0.154 s the bootstrap takes.
Blocking for 0.154 s closes it.

The five hooks already in the user's config all fire at `pre-start`, so this matches what is there.

This reasoning rests on the documented semantics of the two hook points. No hook has been fired for
this change.

### D3. The bootstrap calls `just deps`, and checks the artifact afterward

`just deps` (`justfile:64-66`) is the one home for what bootstrapping this repository means. The
hook invokes it and restates nothing.

`nimble setup` alone is measurably sufficient, at 0.301 s followed by a green `just happen`, and it
is still not what to call. `nimble install -d -y` covers the case where `nimble.lock` names a
package absent from `~/.nimble/pkgs2`, and on a satisfied cache it contributes nothing measurable to
the 0.154 s. Calling `nimble setup` directly would put a second copy of the dependency procedure
wherever the mechanism lives.

The artifact check is a separate step from the call, because nimble 0.22.x exits 0 on a failed task
exec. A file-existence test on `nimble.paths` after `just deps` returns holds whatever nimble
reported. Rejected: trusting `just deps`'s exit code alone, which is the failure mode
`build-pipeline` (`openspec/specs/build-pipeline/spec.md:48-55`) exists to keep out of this build.

## Risks / Trade-offs

**`nimble install -d -y` may reach the network on a checkout whose cache is cold** → the bootstrap
runs once per checkout. What is unmeasured is whether `nimble install -d -y` succeeds offline
against a warm `~/.nimble/pkgs2`. Task 1.3 measures it, and the finding changes no requirement
either way.

**The approval prompt fires again on every edit to the hook command** → the command is `just deps`
and stays that string. The authority it delegates to lives in the `justfile`, which approval does
not gate.

**A route no `wt` hook fires on still fails** → this is D1's stated price, not a surprise. Task 5.1
records which routes stay red, so the record of what shipped names them.

**A `nimble.paths` copied from another checkout names a foreign `src`** → measured inert today, with
the reason for its inertness stated in `specs/checkout-bootstrap/spec.md`. The bootstrap generates
the file instead of copying it, so no option introduces one. The exposure is that someone reaches
for `wt step copy-ignored` later.

**The mechanism here is designed and unexercised** → the failure, its cause, the sufficiency of
`nimble setup`, the cost of `just deps`, and the behavior of `wt step copy-ignored` are all proven
by runs recorded in `scratchpad/worktree-bootstrap-hook/measurements__30-08-26-1700.md`. No hook has
fired and no guard has run. The task groups therefore open with the failing observation and close
with the fresh-checkout check.
