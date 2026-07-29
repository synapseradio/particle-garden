# Particle Garden

An emergent-life engine: one world where species forces, fluid pressure, and a Gray-Scott
chemical field run together, each behind a continuous strength whose range includes zero.
Nim owns the simulation and every number; the SolidJS panel (`web-ui/`) reads them through
`window.gardenAPI` and restates none. All physics runs in WGSL compute shaders on the GPU.
The browser is a portability runtime reached through nim's webui bindings — a desktop app,
not a website.

Read [docs/engineering-principles.md](docs/engineering-principles.md) before designing or
reviewing anything. Twelve articles, each with its enforcement gate; work is reviewed against them.

## Comments
Concise, local, relevant. A comment states only the constraint the code cannot show — a
measured condition, a landmine, a why — in as few lines as it takes. No narrative, no
design history, no presumption about the reader or future work. Where article 8 asks for
conditions beside a constant, one or two lines of conditions satisfy it.

## Build and test
- `just happen` after every change; `just check` (both suites) before any release; `just be` = pull, build, run.
- When subagents carry the work, tests run once at the end by the integrator — never per subagent.
- Generated outputs (`web/app.js`, `web/ui-bundle.*`, top-level `web/shaders/*.wgsl`) are never edited by hand.

## Where authority lives

One home per fact: `config_ranges.nim` (ranges), `memory_layout.nim` (particle buffer),
`ui/api/param_descriptor.nim` (parameter contract), `preset.nim` (preset schema),
`sim_registry.nim` (what a frame dispatches), `wgsl_lint.nim` (shader binding manifest),
`ui/api/response_probe.nim` (probe registry and context slices), `ui/api/slider_curve.nim`
(slider travel mapping — the panel computes none), `ui/input/binding_table.nim` (every mouse,
touch, and key binding as data).
Shader sources live in `web/shaders/src/` and share code from `modules/`, bundled by `tools/wgsl_bundle.nim`.

Parameter dispatch is generated: `web_api.nim` unrolls the state records with `fieldPairs` at
compile time, so a descriptor id must name a field of its store's record —
`test_param_descriptor` holds every routed id to one.

## Help

`docs/help/` documents features, one file per descriptor group, and the app serves the same
files as its in-app help (`ui/api/help_content.nim` compiles them in; `?` opens the panel).
Four coverage relations are test-held: every group has a file, every declared group id exists,
every descriptor is named by its group's file, no file names a non-existent id. A control
therefore cannot ship undocumented — write the help line with the feature.

## Reference oracles

GPU math the native suite cannot execute keeps a pure Nim mirror. Change a shader and its mirror in
the same diff, or the pair silently drifts.

| Mirror | Shader it is written against |
|---|---|
| `physics_core.nim` | `forces.wgsl` (force curve, toroidal wrapping, density) |
| `grid_core.nim` | `bin-count` / `prefix-sum-*` / `bin-scatter.wgsl` |
| `sph_core.nim` | `forces-sph.wgsl` (kernels, Tait pressure, XSPH) |
| `field_core.nim` | `rd-step.wgsl`, `field-seed.wgsl`, `field-deposit.wgsl` |
| `bloom_core.nim` | `blur.wgsl` (kernel weights substituted from here) |
| `colormap_core.nim` | `colormap.wgsl`, and `fade.wgsl`'s field drift scale |
| `camera_core.nim` | `camera_transform.wgsl`, mirrored by `render`, `glow` and `fade` |
| `glow_core.nim` | `glow.wgsl` (halo radius, falloff, warmth, alpha integral) |
| `trail_core.nim` | `fade.wgsl` (per-frame decay), plus the trail-length mapping the renderer writes |

## Landmines
- Render bind groups: counts and shader declarations are build-checked, but which resource lands at each binding is not — verify in a running app.
- Import order in `src/app.nim` is load-bearing on the JS backend; never alphabetize it.
- nimble exits 0 on task failure; only the just recipes fail loudly.
- Deeper maps: [docs/one-world.md](docs/one-world.md) (couplings model), [tests/README.md](tests/README.md) (test layout), [web/shaders/README.md](web/shaders/README.md) (GPU pipeline).
