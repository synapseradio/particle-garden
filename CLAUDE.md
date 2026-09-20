# Particle Garden

Particle Garden is an instrument to map expression into life. It runs one world in which several
systems of forces act visibly on the same matter at once in competition without the world
changing kind. User gestures and interaction alter what nature permits, and life answers by
igniting forms previously unmanifested. Particle Garden aims to be an instrument played visually,
in harmony with others, seeding the world and revealing life's answer in cadence and cascade.

Nim owns every number: ranges, defaults, steps, ceilings, storage keys, the preset schema, and
the notches a slider draws. The SolidJS panel under `web-ui/` reads them through
`window.gardenAPI` and restates none. Physics runs in WGSL compute shaders on the GPU. The
browser is a portability runtime reached through nim's webui bindings, and the binary serves
everything the page needs.

## Read first

- [docs/engineering-principles.md](docs/engineering-principles.md): twelve articles, each with
  its enforcement gate. Design and review every change against them.
- [docs/enforcement.md](docs/enforcement.md): where each fact lives, the tier each guarantee
  rests on, the landmines, and what would raise each. Credit no guarantee it does not record.
- [docs/one-world.md](docs/one-world.md) for the couplings model, [tests/README.md](tests/README.md)
  for the test layout, [web/shaders/README.md](web/shaders/README.md) for the GPU pipeline.

## Comments

Concise, local, relevant. A comment states only the constraint the code cannot show, such as a
measured condition, a landmine, or a why, in as few lines as it takes. No narrative, no design
history, no presumption about the reader or future work. Where article 8 asks for conditions
beside a constant, one or two lines satisfy it.

## Build and test

- `just happen` after every change; `just check` (both suites) before any release; `just be` = deps, build, run.
- A checkout that has never been built (a fresh clone, a `git worktree add`, or a `wt switch
  --create`) needs `just deps` before `just happen` can compile `src/main.nim`, which resolves
  `import webui` through `nimble.paths` — gitignored, absent until `nimble setup` writes it. A `wt`
  worktree runs `just deps` for itself via the committed `.config/wt.toml` pre-start hook, which
  `wt` reads from the checkout it is invoked in, so `wt switch --create` run from a checkout
  without that file skips it silently; a clone or a plain `git worktree add` still needs it typed
  by hand.
- Run the narrowest bats target that covers the change: `bats tests/shell/<file>.bats`, `bats -f '<name>' <file>`, or `bats --filter-tags unit tests/shell`. The whole shell suite runs once, at the end.
- A narrow `nim c -r tests/<module>.nim` sets none of the quality flags `just test` compiles `tests/test_all.nim` under, so `--styleCheck:error`, `--styleCheck:usages` and the `--warningAsError` list (`UnusedImport`, `Effect`, `ProveInit` and the rest) go unchecked there. A module can be green narrowly and fail `just check` on an import a deletion left behind. To run a narrow module under the real bar, copy `quality_flags` from the `justfile` onto the command.
- The shell suite needs `bats-support`, `bats-assert` and `bats-file` on the machine, or every assertion dies as `assert_output: command not found` and `just check` goes red on a clean tree. Install with `brew tap bats-core/bats-core`, then `brew trust --formula bats-core/bats-core/{bats-support,bats-assert,bats-file}` (homebrew refuses to load formulae from an untrusted tap, and the suite's own error message omits this step), then `brew install bats-support bats-assert bats-file`.
- When subagents carry the work, each may run the test subsets relevant to its task. No subagent runs a whole suite (`just test`, `just check`, `just happen`, or the full shell suite); the integrator runs those once, at the end.
- Generated outputs (`web/app.js`, `web/ui-bundle.*`, top-level `web/shaders/*.wgsl`) are never edited by hand.
- `./main` serves the page over plain HTTP at `http://127.0.0.1:8089` with COOP/COEP headers and
  opens a webui window at that URL. The page loads only `app.js` and `ui-bundle.js` and calls
  nothing over the webui bridge, so any WebGPU-capable Chromium tab at that address runs the same
  app. `./main --serve` (`just serve` builds first) runs the server alone with no window until
  killed, and exits 1 when the port is taken.
- For any work that interacts with the app in a browser, use `./main --serve`, never bare `./main`
  or `just be`. Bare `./main` exits with code 0 when no browser attaches within webui's startup
  wait, and it opens an extensionless Chromium profile that Browser MCP cannot reach.
- In-app verification runs in this order:
  1. Confirm the Browser MCP tools are present and connected without errors. If they are not, ask
     the user to start Chrome and connect Browser MCP, and start nothing until they confirm.
  2. Run `just happen`, then `./main --serve` as a persistent background shell (the Bash tool's
     `run_in_background`, not a trailing `&`), and poll the port for 200.
  3. Navigate the connected tab to `http://127.0.0.1:8089`. If navigation fails, ask the user to
     load the URL in that tab. Browser MCP refuses a new-tab page or `about:blank` ("This page
     cannot be automated"), and a Browser MCP call made before the server answers can return "No
     connection to browser extension" even with the tab ready.
  4. Drive the page through Browser MCP. Browser MCP has no script-eval tool, so drive
     `gardenAPI` through the panel's controls. `browser_get_console_logs` can return nothing while
     the page logs (`[gpu-profile]` lines every ~5 s); treat an empty read as no read, and ask the
     user to check the DevTools console before recording that no error occurred.
  5. Stop the server by killing the port's listener.
- Never install Playwright or another browser driver to work around a missing connection.

## Help

`docs/help/` documents features, one file per descriptor group, and the app serves the same
files as its in-app help (`ui/api/help_content.nim` compiles them in; `?` opens the panel).
Write the help line with the feature. Which controls a test holds to that rule is recorded in
[docs/enforcement.md](docs/enforcement.md).
