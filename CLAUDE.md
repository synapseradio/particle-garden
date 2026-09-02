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
- Run the narrowest bats target that covers the change: `bats tests/shell/<file>.bats`, `bats -f '<name>' <file>`, or `bats --filter-tags unit tests/shell`. The whole shell suite runs once, at the end.
- The shell suite needs `bats-support`, `bats-assert` and `bats-file` on the machine, or every assertion dies as `assert_output: command not found` and `just check` goes red on a clean tree. Install with `brew tap bats-core/bats-core`, then `brew trust --formula bats-core/bats-core/{bats-support,bats-assert,bats-file}` (homebrew refuses to load formulae from an untrusted tap, and the suite's own error message omits this step), then `brew install bats-support bats-assert bats-file`.
- When subagents carry the work, tests run once at the end by the integrator, and never per subagent.
- Generated outputs (`web/app.js`, `web/ui-bundle.*`, top-level `web/shaders/*.wgsl`) are never edited by hand.
- `./main` serves the page over plain HTTP at `http://127.0.0.1:8089` with COOP/COEP headers and
  opens a webui window at that URL. The page loads only `app.js` and `ui-bundle.js` and calls
  nothing over the webui bridge, so any WebGPU-capable Chromium tab at that address runs the same
  app. To drive it from an agent, launch `./main` in the background, poll the port, and point a
  browser tool (Browser MCP, Playwright) at the URL. Stop it by killing the port's listener.

## Help

`docs/help/` documents features, one file per descriptor group, and the app serves the same
files as its in-app help (`ui/api/help_content.nim` compiles them in; `?` opens the panel).
Write the help line with the feature. Which controls a test holds to that rule is recorded in
[docs/enforcement.md](docs/enforcement.md).
