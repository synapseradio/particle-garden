Decision D1 in `design.md` is settled: a `wt` project config committed to this repository carries
the bootstrap. Group 3 builds it, and group 5 closes the change. Ids are stable and never
renumbered, so group 3 keeps the numbers it held in the list that carried a group per mechanism.

Throughout, a "throwaway checkout" means one created for a check and removed when the check ends,
named so it cannot be mistaken for work: `wt switch --create zz-check-<slug> -y --no-cd`, then
`wt remove zz-check-<slug> -y`. No check runs in a checkout holding work, because a build there
supplies the very artifact the check looks for.

## 1. Baseline and the one open measurement

- [ ] 1.1 In a throwaway checkout, run `just happen` as the first command and record the output.
  Settled by: `shaders`, `build-app`, and `build-ui` green, then
  `src/main.nim(16, 8) Error: cannot open file: webui` and a non-zero exit. This is the red
  observation every group below closes.
- [ ] 1.2 In the same throwaway checkout, run `just deps` and then `just happen` again. Settled by:
  both exit 0, `main` exists at the checkout root, and `nimble.paths` names that checkout's own
  `src`. Remove the throwaway.
- [ ] 1.3 Measure whether `nimble install -d -y` succeeds with no network against a warm
  `~/.nimble/pkgs2`, in a throwaway checkout with the network disabled. Settled by: the exit code
  and, on failure, the message. Record the result in
  `scratchpad/worktree-bootstrap-hook/measurements__30-08-26-1700.md` under a new heading. The
  answer changes no requirement. It decides whether the Risks section of `design.md` keeps or drops
  the open clause on offline behavior, and that clause is updated either way.
- [ ] 1.4 `just happen` and `just check` green in the change's own worktree.

## 3. The wt project config

- [ ] 3.1 In a throwaway checkout, run `wt hook pre-start --dry-run` and confirm it lists only the
  five user hooks. Settled by: no project hook appears, which is the state the config below changes.
- [ ] 3.2 Create `.config/wt.toml` at the repository root with a `[pre-start]` table holding one
  key named `bootstrap` whose value is `just deps`. Write no comment in the file. Settled by:
  `wt config show` reports the project config as found at that path, and
  `wt hook pre-start --dry-run` lists `project:bootstrap`.
- [ ] 3.3 Extend the `bootstrap` command so it fails when `nimble.paths` is still absent after
  `just deps` returns, per the requirement "A bootstrap that produces no `nimble.paths` SHALL fail
  loudly" in `specs/checkout-bootstrap/spec.md`. Keep the whole command in `.config/wt.toml` and add
  no script file. Settled by: `wt hook pre-start --yes` in a throwaway checkout with a `nimble` stub
  earlier on `PATH` that exits 0 and writes nothing exits non-zero.
- [ ] 3.4 In a throwaway checkout created with `wt switch --create zz-check-a -y --no-cd`, run
  `just happen` as the first command. Settled by: exit 0 and `main` present. Remove the throwaway.
- [ ] 3.5 Record in `README.md`, in the Build from Source block at `README.md:104-117`, that a `wt`
  worktree bootstraps itself and a clone still runs the two commands already listed there. Settled
  by: the block names both routes.
- [ ] 3.6 `just happen` and `just check` green in the change's own worktree.

## 5. Closing verification

- [ ] 5.1 Run the procedure named in the requirement "A checkout that has never been built SHALL
  build through `just happen` alone" in `specs/checkout-bootstrap/spec.md`, against a fresh
  throwaway checkout made by each route in decision D1's table. Settled by: exit 0 and `main`
  present for `wt switch --create`, and `cannot open file: webui` recorded as the standing result
  for `git worktree add` and `git clone`, which is the coverage D1 gives up.
- [ ] 5.2 Time the bootstrap in a checkout that already holds `nimble.paths`, then run
  `git status --short`. Settled by: under one second, exit 0, and no reported change, per the
  requirement "The bootstrap SHALL stay out of the way of a checkout that already builds" in
  `specs/checkout-bootstrap/spec.md`.
- [ ] 5.3 Update the "Build and test" bullet in `CLAUDE.md`, which names `just happen` after every
  change and `just be` as deps-build-run, to state what a checkout that has never been built now
  needs. Settled by: the bullet matches the behavior the selected option delivers.
- [ ] 5.4 Confirm no throwaway checkout or branch survives. Settled by: `git worktree list` and
  `git branch --list 'zz-*'` show none.
- [ ] 5.5 `just happen` and `just check` green in the change's own worktree.
