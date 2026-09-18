Decision D1 in `design.md` is settled: a `wt` project config committed to this repository carries
the bootstrap. Group 3 builds it, and group 5 closes the change. Ids are stable and never
renumbered, so group 3 keeps the numbers it held in the list that carried a group per mechanism.

Throughout, a "throwaway checkout" means one created for a check and removed when the check ends,
named so it cannot be mistaken for work: `wt switch --create zz-check-<slug> -y --no-cd`, then
`wt remove zz-check-<slug> -y`. No check runs in a checkout holding work, because a build there
supplies the very artifact the check looks for.

## 1. Baseline and the one open measurement

- [x] 1.1 In a throwaway checkout, run `just happen` as the first command and record the output.
  Settled by: `shaders`, `build-app`, and `build-ui` green, then
  `src/main.nim(16, 8) Error: cannot open file: webui` and a non-zero exit. This is the red
  observation every group below closes.
- [x] 1.2 In the same throwaway checkout, run `just deps` and then `just happen` again. Settled by:
  both exit 0, `main` exists at the checkout root, and `nimble.paths` names that checkout's own
  `src`. Remove the throwaway.
- [x] 1.3 Measure whether `nimble install -d -y` succeeds with no network against a warm
  `~/.nimble/pkgs2`, in a throwaway checkout with the network disabled. Settled by: the exit code
  and, on failure, the message. Record the result in
  `scratchpad/worktree-bootstrap-hook/measurements__30-08-26-1700.md` under a new heading. The
  answer changes no requirement. It decides whether the Risks section of `design.md` keeps or drops
  the open clause on offline behavior, and that clause is updated either way.
- [x] 1.4 `just happen` and `just check` green in the change's own worktree.

## 3. The wt project config

- [x] 3.1 In a throwaway checkout, run `wt hook pre-start --dry-run` and confirm it lists only the
  five user hooks. Settled by: no project hook appears, which is the state the config below changes.
- [x] 3.2 Create `.config/wt.toml` at the repository root with a `[pre-start]` table holding one
  key named `bootstrap` whose value is `just deps`. Write no comment in the file. Settled by:
  `wt config show` reports the project config as found at that path, and
  `wt hook pre-start --dry-run` lists `project:bootstrap`.
- [x] 3.3 Extend the `bootstrap` command so it fails when `nimble.paths` is still absent after
  `just deps` returns, per the requirement "A bootstrap that produces no `nimble.paths` SHALL fail
  loudly" in `specs/checkout-bootstrap/spec.md`. Keep the whole command in `.config/wt.toml` and add
  no script file. Settled by: `wt hook pre-start --yes` in a throwaway checkout with a `nimble` stub
  earlier on `PATH` that exits 0 and writes nothing exits non-zero.
- [x] 3.4 In a throwaway checkout created with `wt switch --create zz-check-a -y --no-cd`, run
  `just happen` as the first command. Settled by: exit 0 and `main` present. Remove the throwaway.
  `wt` reads the project hook from the checkout it is invoked in, not from the new worktree: on
  18-09-26, `wt switch --create --base worktree-bootstrap-hook` run from `dev` (no
  `.config/wt.toml`) ran only the user hooks, and the same command run from this change's worktree
  ran `project:bootstrap`. That accounts for the earlier 2-of-8 firing. Created from this change's
  worktree, `zz-check-a3` ran the hook, and `just happen` exited 0 with `main` present. Once the
  config is merged, every checkout carries it.
- [x] 3.5 Record in `README.md`, in the Build from Source block at `README.md:104-117`, that a `wt`
  worktree bootstraps itself and a clone still runs the two commands already listed there. Settled
  by: the block names both routes.
- [x] 3.6 `just happen` and `just check` green in the change's own worktree.

## 5. Closing verification

- [x] 5.1 Run the procedure named in the requirement "A checkout that has never been built SHALL
  build through `just happen` alone" in `specs/checkout-bootstrap/spec.md`, against a fresh
  throwaway checkout made by each route in decision D1's table. Settled by: exit 0 and `main`
  present for `wt switch --create`, and `cannot open file: webui` recorded as the standing result
  for `git worktree add` and `git clone`, which is the coverage D1 gives up.
  `git worktree add` and `git clone`: both confirmed red with `cannot open file: webui`, as D1
  predicts. `wt switch --create`: exit 0 and `main` present when invoked from a checkout that
  carries `.config/wt.toml` (3.4, `zz-check-a3`).
- [x] 5.2 Time the bootstrap in a checkout that already holds `nimble.paths`, then run
  `git status --short`. Settled by: under one second, exit 0, and no reported change, per the
  requirement "The bootstrap SHALL stay out of the way of a checkout that already builds" in
  `specs/checkout-bootstrap/spec.md`. Measured: 0.209 s, exit 0, `git status --short` unchanged
  before and after (`wt hook pre-start bootstrap --yes`, isolated to the project hook alone).
- [x] 5.3 Update the "Build and test" bullet in `CLAUDE.md`, which names `just happen` after every
  change and `just be` as deps-build-run, to state what a checkout that has never been built now
  needs. Settled by: the bullet matches the behavior the selected option delivers.
  Wording states the mechanism as designed; it does not carry the reliability caveat from 3.4/5.1
  since that is a finding about `wt switch --create`'s firing, not about what `.config/wt.toml`
  states or what `just deps` does.
- [x] 5.4 Confirm no throwaway checkout or branch survives. Settled by: `git worktree list` and
  `git branch --list 'zz-*'` show none. Confirmed: neither lists any `zz-` entry.
- [x] 5.5 `just happen` and `just check` green in the change's own worktree.
