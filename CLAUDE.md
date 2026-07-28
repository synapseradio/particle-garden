# Particle Garden

An emergent-life engine: one world where species forces, fluid pressure, and a Gray-Scott
chemical field run together, each behind a continuous strength whose range includes zero.
Nim owns the simulation and every number; the SolidJS panel (`web-ui/`) reads them through
`window.gardenAPI` and restates none. All physics runs in WGSL compute shaders on the GPU.
The browser is a portability runtime reached through nim's webui bindings — a desktop app,
not a website.

Read [docs/engineering-principles.md](docs/engineering-principles.md) before designing or
reviewing anything. Twelve articles, each with its enforcement gate; work is reviewed against them.

## Build and test
- `just happen` after every change; `just check` (both suites) before any release; `just be` = pull, build, run.
- When subagents carry the work, tests run once at the end by the integrator — never per subagent.
- Generated outputs (`web/app.js`, `web/ui-bundle.*`, top-level `web/shaders/*.wgsl`) are never edited by hand.

## Where authority lives

One home per fact: `config_ranges.nim` (ranges), `memory_layout.nim` (particle buffer),
`ui/api/param_descriptor.nim` (parameter contract), `preset.nim` (preset schema),
`sim_registry.nim` (what a frame dispatches), `wgsl_lint.nim` (shader binding manifest).
Shader sources live in `web/shaders/src/` and share code from `modules/`, bundled by `tools/wgsl_bundle.nim`.

## Landmines
- Render bind groups: counts and shader declarations are build-checked, but which resource lands at each binding is not — verify in a running app.
- Import order in `src/app.nim` is load-bearing on the JS backend; never alphabetize it.
- nimble exits 0 on task failure; only the just recipes fail loudly.
- Deeper maps: [docs/one-world.md](docs/one-world.md) (couplings model), [tests/README.md](tests/README.md) (test layout), [web/shaders/README.md](web/shaders/README.md) (GPU pipeline).
