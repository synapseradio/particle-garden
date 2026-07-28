# CLAUDE.md

Native desktop wrapper for a particle simulator with WebGPU compute physics. The browser is a portability runtime reached through nim's webui bindings — this is a desktop app, not a website, so web conventions (page scroll and zoom, responsive-site layout, external resources) do not apply, and input handlers suppress them where they collide with app gestures. There is one world, and species forces, SPH fluid pressure and a Gray-Scott chemical field all run in it at once, each at a continuous strength the user sets. The simulation, WebGPU pipeline, and native server are Nim; the control panel is SolidJS/TypeScript (`web-ui/`); WGSL shaders are the only other non-Nim source.

## Golden rules

- **Read [`docs/engineering-principles.md`](docs/engineering-principles.md) before designing or reviewing anything.** Twelve articles, each with its rule, the scar that earned it, and the gate that enforces it. Work is reviewed against them.
- **Run `just happen` after every change.** It runs the shader bundle, the Nim frontend compile, the Bun/TS build (with the `tsc --noEmit` typecheck), and the native compile, in the order the staticReads require. Run `just check` (both test suites) before any release. `just be` = pull → build → run.
- **The language boundary is `window.gardenAPI`** (`src/web_api.nim`). Nim owns the simulation: CONFIG, defaults, ranges, clamping, color math, preset schema/validation/apply order. TypeScript owns only the control panel and never restates a number the Nim side serves — ranges, defaults, steps, ceilings, and storage keys all come through `gardenAPI`. Canvas mouse/touch input stays Nim (`canvas_input.nim`).
- **The CONFIG mirror is synchronous.** Every parameter write lands in the typed store AND the flat GPU-facing CONFIG in the same tick via `updateSimulation`/`updateRender` (`web_api.nim` documents the invariant). Never rebuild this on subscriptions or microtasks — the frame loop reads CONFIG fresh every frame.
- **Generated files are off-limits:** `web/app.js`, `web/ui-bundle.js`, `web/ui-bundle.css`, and `web/shaders/*.wgsl` are build output. Edit `src/*.nim` and `web-ui/src/*`, never the outputs.
- **`memory_layout.nim` is the single source of truth** for the Particle struct and all buffer offsets. Never hardcode offsets elsewhere.
- **Do not alphabetize imports in `app.nim`.** Nim's JS backend hoists variables, so misordered imports cause undefined-reference errors at runtime. Keep the dependency order below.

## Build and test

```bash
nimble install          # Install Nim dependencies
nimble setup            # Generate nimble.paths; run after install or on "cannot open file: webui"
just happen             # Build everything (shaders + app.js + ui-bundle + native binary)
just check              # Both test suites (native Nim + bun test)
just test               # Native Nim suite only
just test-ui            # TypeScript suite only
just release            # Optimized release build
just be                 # git pull + build + run
./main                  # Run
```

`just happen` runs four steps in order — the order matters because `main.nim` staticReads the earlier outputs:
1. `shaders` — bundle WGSL shaders (resolve `//! import`, substitute config) via `tools/wgsl_bundle.nim`.
2. `build-app` — `nim js` compiles `src/app.nim` → `web/app.js` (simulation frontend, creates `window.gardenAPI`).
3. `build-ui` — Bun installs pinned deps, typechecks with TypeScript 7, and bundles `web-ui/src/main.tsx` → `web/ui-bundle.js` + `web/ui-bundle.css` (via `web-ui/build.ts`; the `bun build` CLI cannot load the Solid JSX plugin).
4. `build-native` — `nim c` compiles `src/main.nim` → `./main` (native HTTP server; staticReads app.js and ui-bundle.*).

The just recipes invoke `nim` and `bun` directly instead of going through nimble tasks: nimble 0.22.x exits 0 even when a task's exec fails, which once left a stale `web/app.js` behind a "successful" build. The nimble tasks still exist for manual use, but only the just recipes are trusted to fail loudly. The flag constants in the justfile mirror `particle_garden.nimble` and must stay in sync.

Run `just test` after changing any pure-logic Nim module (physics, grid, SPH, reaction-diffusion field, bloom, colormap, memory layout, gpu_types, sim registry, shader manifest, UI state, param descriptor). The suite is native-only: it compiles `tests/test_all.nim` with `nim c` and exercises the pure modules. `just test-ui` covers the TypeScript pure logic (preset storage, formatting) with `bun test`. Browser, WebGPU, and FFI code is verified by the build itself — a broken FFI binding fails `build-app`, and a broken component fails the typecheck.

Two native tests read TypeScript source from disk rather than importing a Nim module, so `just test` covers them even though nothing Nim changed: `test_no_modes.nim` sweeps `src/` and `web-ui/src/` for the vocabulary of the deleted mode model, and `test_panel_reachability.nim` fails when `Panel.tsx` places no control for a descriptor. Run `just test` after editing `web-ui/src/components/Panel.tsx` for that reason. CI runs `just check` before any release, so a red suite blocks the release. See `tests/README.md` for layout and conventions.

## Architecture

Two components, because browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer:

- **Nim asynchttpserver** (port 8089) serves `web/index.html` with the COOP/COEP headers.
- **webui** opens a native browser window pointing at localhost:8089 and manages its lifecycle.

### The gardenAPI boundary

`src/web_api.nim` installs a single `window.gardenAPI` object at `app.js` module-eval time — before the Solid bundle evaluates. The Solid panel (`web-ui/`) drives everything through it: descriptor-driven sliders (`descriptor()`/`setParam`/`commitParam`, clamped in Nim against `ui/api/param_descriptor.nim`), palette and colormap catalogs, the named reaction-diffusion regimes (`rdRegimes`/`applyRdRegime`), live `matrix()` and `chemistry()` Float32Array references gated behind `onReady` (buffers exist only after `init()`), a pushed stats stream (`onStats`, cadence set loop-side in `app.nim`), and hybrid presets (`exportPresetJson`/`applyPresetJson` keep schema, validation, and `presetApplySteps` order in Nim; the UI owns localStorage under `preset_store_core`'s `pg.presets.*` keys, so a preset saved by any earlier build keeps loading). One JS-backend caveat lives at this boundary: `std/json.parseJson` delegates to `JSON.parse`, whose SyntaxError is a foreign exception Nim's `except ValueError` cannot catch — `applyPresetJson` pre-checks parseability instead.

### Particle buffer

All particle data lives in a SharedArrayBuffer with AoS (Array of Structures) layout. The Particle struct is 32 bytes, cache-aligned (two particles per 64-byte cache line):

| Offset | Field | Type | Meaning |
|--------|-------|------|---------|
| 0  | px | f32 | position x |
| 4  | py | f32 | position y |
| 8  | vx | f32 | velocity x |
| 12 | vy | f32 | velocity y |
| 16 | species | i32 | species index (0-5) |
| 20 | density | f32 | colony density: same-species neighbours, proximity-weighted. Written by the world-intrinsic sweep; read by dot size, brightness and glow radius |
| 24 | sphDensity | f32 | the fluid's kernel-weighted, species-blind density, private to its equation of state |
| 28 | padding | — | alignment to 32 bytes |

### GPU physics pipeline

All physics runs on WebGPU compute shaders — there is no CPU physics path. Particles stay on the GPU from initialization through rendering; there is no CPU readback.

**Couplings are continuous strengths, not modes.** `WorldCouplings` in `sim_registry.nim` holds four floats — `forces` (the species force term), `fluid` (smoothed-particle pressure and viscosity), `deposit` (what particles secrete into the chemical field), and `fieldForce` (how hard the field's gradient steers them). Each is a live simulation parameter (`forceStrength`, `fluidStrength`, `rdDeposit`, `rdFieldForce`), derived on demand by `couplingsOf` in `ui/state/sim_config.nim` rather than stored twice, and every one of their ranges reaches zero. Zero is an ordinary value of a strength, never a state of the world.

**The frame asks exactly one question of a strength: is it zero.** `sim_registry.acts` is the only comparison site — nothing reads a magnitude or tests a threshold. `webgpu_compute.sameFrameShape` compares only the zeros, so a slider moving within its range rebuilds nothing, and `setCouplings` rebuilds the pure frame description when a strength crosses zero. `shader_manifest.allShaderSpecs()` registers every compute shader at init with no per-world subset, which is what makes that crossing synchronous instead of waiting on a shader fetch and compile.

**A strength may skip a pass only when it multiplies everything that pass produces.** Otherwise skipping removes an output the strength never scaled and the world jumps at zero. Passes therefore divide two ways. World-intrinsic, never skipped: the grid triad with bin-scatter, the neighbour sweep in `forces.wgsl`, `field-resolve`, the `RD_STEPS_PER_FRAME` Gray-Scott substeps, and `integrate`. Coupling-owned, skipped at exactly zero: `forces-sph` (`fluid`), `field-deposit` (`deposit`), `field-force` (`fieldForce`).

Forces are the asymmetric case. `forces.wgsl` applies the species force, accumulates the per-particle colony density the renderer reads, and carries the mouse and blast input. Only the first is coupling-owned, so the pass stays world-intrinsic and no force strength may skip it — the neighbour sweep runs in a world where no forces act, which is the honest price of one world. The field is intrinsic for the same reason and for the ping-pong parity below.

**Delta-buffer ownership belongs to the frame, and this is the invariant that makes composition work.** `buildFrame` clears `velocityDelta` and `densityDelta` once at the top of every frame, and every contributing pass — `forces`, `forces-sph`, `field-force` — accumulates into them with `atomicAdd` and never stores. A pass that self-resets in its own prologue works while one contributor runs and breaks the moment two do, because whichever runs second erases the first. Any new pass that writes a delta buffer must accumulate. `field-deposit` is the exception and stays self-resetting, because `field-resolve` zeroes each cell as it consumes it.

A frame composes in this order:

1. Clear `velocityDelta`, `densityDelta` and `gridCounts`.
2. **Grid Build** — **bin-count**, then the three **prefix-sum** stages (local, blocks, final).
3. Copy `gridOffsets` into `fillPointers`, which bin-scatter consumes as its write cursors.
4. **Physics** — **bin-scatter**, then **forces**, then **forces-sph** where `fluid` acts.
5. **Field (RD)** — **field-deposit** where `deposit` acts, then **field-resolve**, `RD_STEPS_PER_FRAME` alternating **rd-step** substeps, then **field-force** where `fieldForce` acts.
6. **integrate**, always last — the one pass that reads the summed deltas and moves particles, so every contributor must already have run.

`field-seed` writes a pattern into the field and is a one-shot the executor encodes on reset and on the deliberate "scatter spores" action, never a frame node. Nothing seeds the field automatically: it clears to Gray-Scott's trivial fixed point and is lifted off it by particle deposits alone, which is what makes the pattern a record of where colonies lived. Ignition depends on coherence rather than magnitude — a single-cell deposit fails at any amplitude the slider offers, so `field-deposit` splats each particle's deposit over a normalized kernel.

`field-resolve` is itself one stage of the field ping-pong, so `1 + RD_STEPS_PER_FRAME` must be even for the live field to end each frame on the texture the renderer samples. `field_core.nim` asserts that parity statically, which is also why no strength may skip `field-resolve`.

Presets are schema v2: a point in this parameter space, carrying the four strengths and no `mode` field. `LEGACY_MODE_COUPLINGS` in `preset.nim` is the only table naming a mode, reachable only from the v1 branch of `migrate`, which translates a pre-2.0 preset's mode into the strengths that mode meant.

`docs/one-world.md` is the guide to adding a fifth coupling.

## Shaders

WGSL shaders use a module system with build-time preprocessing. Layout under `web/shaders/`:

- `modules/` — shared WGSL imported via `//! import`. Fourteen of them, covering the particle struct, grid and cell indexing, fixed-point encoding, scan parameters, and the render-side parameter/colormap/tonemap blocks.
- `src/` — source shaders that declare `//! import particle, ...` directives.
- `*.wgsl` (top level) — generated bundled output. DO NOT EDIT.

`tools/wgsl_bundle.nim` reads `web/shaders/src/*.wgsl`, resolves the `//! import` directives from `modules/`, substitutes `{{PLACEHOLDER}}` values from `src/shader_config.nim`, and writes the bundled output. Substitution runs after imports are inlined, so placeholders work inside `modules/` too, and an unresolved `{{...}}` fails the bundle rather than reaching the GPU. The bundle step also runs `src/wgsl_lint.nim` over every bundled shader: a WGSL struct constructor written with Nim-style named fields (`Camera(centerX: ...)` — WGSL constructors are positional only) quits the build naming the shader and line, because the browser is the only WGSL compiler and would otherwise report it at runtime as a black window.

**Shaders reach the GPU by two different routes**, and which one a new shader takes decides whether it belongs in `StaticFiles`:

- **Compute shaders** are listed in `shader_manifest.nim`, fetched over HTTP at pipeline-init time, and therefore must be registered in the `StaticFiles` table in `main.nim`. Unregistered means unserved means a failed fetch.
- **Render shaders** (`render`, `glow`, `fade`, `composite`, `field-composite`, `blur`, `tonemap`) are `staticRead` into `app.js` by `webgpu_render.nim` at Nim-compile time. They are deliberately absent from `StaticFiles` — serving them would ship the same bytes twice.

**The render path's bind groups are guarded by entry counts and a binding manifest, and what remains unguarded is still the sharpest edge in the codebase.** `render.wgsl` and `glow.wgsl` share ONE explicit bind group layout. Two guards hold the shader side: `webgpu_render.nim` validates each bind group's entry count against its `EXPECTED_BIND_GROUP_ENTRIES_*` constant at creation time, and the bundler fails the build when any shader's declared `@binding` set disagrees with `ExpectedShaderBindings` in `src/wgsl_lint.nim` — a shader absent from that table fails too. What no guard sees is which RESOURCE the Nim code places at each binding: entries swapped between two bindings keep both the counts and the declarations green while the app fails GPU validation in the browser and draws nothing.

So when you touch a render binding, change all four together and verify in a running app: the layout in `webgpu_render.nim`, every bind group built from it, and the `@binding` numbers in BOTH shaders that share it. A binding added to one shader and not the other is not a compile error — it is a blank canvas.

**Add a compute shader:** create `web/shaders/src/my-shader.wgsl`, add `//! import particle` (and any other modules) at the top, register its `@binding` set in `ExpectedShaderBindings` (`src/wgsl_lint.nim` — the bundle refuses to build until you do), run `just happen`, add a `ShaderSpec` for it in `shader_manifest.nim` (appended in `allShaderSpecs`, which registers everything at init), and register it in `StaticFiles`. Add an `EXPECTED_BIND_GROUP_ENTRIES_*` constant and a case in `getExpectedEntryCount` — a bind group whose entry count disagrees with its shader's bindings fails validation at runtime, and that constant is what turns it into a loud failure instead.

**Modify a shared struct:** edit the WGSL side in `web/shaders/modules/particle.wgsl` and the Nim side in `src/gpu_types.nim` to match. Compile-time validation in `gpu_types.nim` catches mismatches.

## Code conventions

Quality flags are enforced via nimble for every build:
- `--styleCheck:error --styleCheck:usages` — snake_case enforcement.
- Warnings as errors: `Deprecated`, `BareExcept`, `CStringConv`, `EnumConv`, `HoleEnumConv`, `SmallLshouldNotBeUsed`, `ProveInit`, `UnusedImport`, `Effect`, plus `--hint:XDeclaredButNotUsed:on`. An unused import or variable fails the build.

## Dependency discipline

Can this build be reproduced on a fresh machine in six months? That is the test every dependency decision must pass.

**Library dependencies are pinned exactly.** Use exact version pins or commit hashes (for example, `webui#552a3e3`, the 2.4.2 tag). `nimble.lock` is committed and updated deliberately. Floating references — `#head`, `>=`, `*`, or anything pointing at `head`/`main`/`master`/`latest` — are forbidden for libraries. A missing or uncommitted lock file is a red flag. The same discipline covers `web-ui/`: Bun is pinned via `packageManager` in `web-ui/package.json`, every npm dependency is exact-pinned, `web-ui/bun.lock` is committed, and CI installs with `--frozen-lockfile`.

**The UI bundle is a build artifact staticRead at Nim-compile time.** `web/ui-bundle.js`/`.css` are gitignored; `main.nim` embeds them during `nim c`. A missing bundle fails the native compile (good); a stale one silently ships an old UI (bad) — which is why `just happen` always rebuilds the bundle before the native step, and why builds must go through just rather than nimble (see Build and test).

**The nim compiler is the deliberate exception, and must NOT be pinned in the lock.** It is system-provided, bounded only by `requires "nim >= 2.0.0 & < 3.0.0"` in `particle_garden.nimble`. Builds use whatever toolchain is installed: `--useSystemNim` locally, and `iffy/install-nim` with `version: binary:stable` in the release workflow. The `< 3.0.0` upper bound is the guardrail that keeps "track the installed stable toolchain" safe across a future nim major release. Do not add a nim entry back into the lock.

Two failures motivate this split:

- **Floating library ref.** A `requires "webui#head"` pulled unreleased upstream code; the foundation shifted underneath both old releases and new builds, breaking them the same way. Pinning the commit fixed it.
- **Stale pinned compiler.** A pinned nim 2.2.6 in the lock went stale across a gap in work. That version's JS backend emits `system module needs: nimAddStrStr` and cannot compile `web/app.js`, while its native backend stays green — so `nimble test` passed while `nimble all` was silently broken. CI never hit this, because CI ignores the lock's nim and builds on the stable system toolchain, so releases stayed green. Removing the stale pin and matching CI's strategy locally fixed the frontend.

The lesson: pin libraries exactly, but let the compiler track the installed toolchain within the supported range, the way CI always has.

## Releasing

GitHub Actions (`.github/workflows/release.yml`) builds and publishes releases for macOS, Windows, and Linux. It triggers on tags matching `v*`: installs Nim (system stable), Bun 1.3.14, and just, runs `just check`, builds `just release` on all three platforms, packages platform artifacts (macOS .app bundle, Windows .exe, Linux binary), and creates a GitHub Release with auto-generated notes. Use `workflow_dispatch` in the Actions UI for draft releases without pushing tags.

The version in `particle_garden.nimble` must match the git tag (without the `v` prefix). Semantic versioning:
- **MAJOR** — breaking changes (user-visible behavior change, config format change, removed features).
- **MINOR** — new features or significant improvements (new UI controls, a new coupling).
- **PATCH** — bug fixes, docs, refactoring (no user-visible functional change).

When versions diverge, examine commits since the last tag to pick the bump — `git log $(git describe --tags --abbrev=0)..HEAD --oneline`. Any breaking commit → major; otherwise any feature → minor; else patch. To release: bump the nimble version, commit, then `git tag vX.Y.Z && git push && git push origin vX.Y.Z`.

## Source map

Three build targets: `nim js` builds `src/app.nim` → `web/app.js` (simulation frontend, all modules merged); Bun builds `web-ui/src/main.tsx` → `web/ui-bundle.js` + `.css` (Solid control panel); `nim c` builds `src/main.nim` → `./main` (native HTTP server + webui window, staticReads the other two).

Import order in `app.nim` matters — each layer depends on the previous one, and the JS backend's hoisting makes misordering fatal at runtime:

```
Layer 1: config                                       (no dependencies)
Layer 2: buffers                                      (uses config)
Layer 3: grid, canvas_input, web_api                  (use buffers)
Layer 4: webgpu_init, gpu_profiler, webgpu_compute,
         webgpu_render                                (use all above)
Layer 5: ui/state/app_state, ui/state/sim_config      (frame-loop state)
```

Module inventory:

| Module | Purpose |
|--------|---------|
| `main.nim` | HTTP server (port 8089) with COOP/COEP headers, webui window management, static file serving. Holds the `StaticFiles` table — register new web assets here. |
| `app.nim` | Frontend entry point; imports all modules in dependency order, runs the frame loop. |
| `config.nim` | Runtime CONFIG object (particle count, physics params); re-exports memory-layout constants. |
| `memory_layout.nim` | Single source of truth for the AoS Particle struct (32 bytes), buffer offsets, limits. |
| `buffers.nim` | Typed-array views (Float32Array, Uint32Array) over the SharedArrayBuffer. |
| `shader_config.nim` | Workgroup sizes and tuning constants for shader placeholders. |
| `config_ranges.nim` | Single source of truth for every user-facing tunable's range. |
| `gpu_types.nim` | Type-safe GPU struct layouts with compile-time validation, named buffer indices. |
| `webgpu_init.nim` | GPU device init, feature detection, buffer allocation. |
| `webgpu_compute.nim` | Builds the world's frame from `sim_registry` (rebuilt only when a strength crosses zero) and dispatches the compute passes. |
| `webgpu_render.nim` | GPU rendering: instanced quads, trail effects, glow, HDR bloom and tonemap. |
| `gpu_profiler.nim` | Per-pass GPU timing via timestamp queries; inert when the adapter lacks the feature. |
| `sim_registry.nim` | The frame as data: `WorldCouplings` (the four coupling strengths), `acts`, and `buildFrame`. |
| `shader_manifest.nim` | Every compute shader the world can dispatch, as data; `allShaderSpecs()` registers them all at init. Companion to `sim_registry`. |
| `climate_core.nim` | Pure drifting-climate path: the closed tour of named regimes feed and kill follow. |
| `camera_core.nim` | Pure toroidal camera: nearest-image offset, clip mapping, zoom anchoring, apparent scale. |
| `web_api.nim` | The `window.gardenAPI` boundary: typed-state → CONFIG bridge (synchronous mirror), descriptor-clamped parameter writes, palette and matrix logic, starter presets, preset snapshot/apply. |
| `canvas_input.nim` | Canvas mouse/touch input → physics (currentInput observable), resize and particle-reinit callbacks. |
| `ui/api/param_descriptor.nim` | Pure descriptor table for every tunable (id, range, step, precision, default, store routing); natively tested; served to TS via `gardenAPI.descriptor()`. |
| `ui/` | Pure UI state modules (`state/`, `core/observable`, `input/` handlers, `presets/preset_store_core`); natively tested where pure. |
| `web-ui/` | The Solid control panel (TypeScript): components over gardenAPI, localStorage preset I/O, formatting; built by Bun via `build.ts`. |
| `grid.nim` | Spatial grid dimensions from world size + interaction radius. |
| `palette.nim` | Pure species color-palette generation. |
| `preset.nim` | Pure versioned preset schema (v2): serialization, validation, apply order, and the v1 mode-to-strengths migration. |
| `wgsl_lint.nim` | Pure WGSL source checks the bundler runs; rejects named-field constructor calls (WGSL constructors are positional only) as a build failure. |
| `tools/wgsl_bundle.nim` | Shader preprocessor (resolves `//! import`, substitutes `{{PLACEHOLDER}}`, runs `wgsl_lint`). |

Bindings live in `src/bindings/`: `webgpu.nim` (adapters, devices, buffers, pipelines, bind groups), `typed_arrays.nim` (Float32Array, Uint32Array, Int32Array, ...), `dom_extensions.nim` (Canvas, HTMLElement, classList), `js_interop.nim` (console, random, object creation), `window.nim` (requestAnimationFrame, performance.now()).

### Reference oracles

Physics that runs in WGSL cannot be executed by the native test suite, so several pure modules mirror the shader math in Nim and the suite checks those instead. They are imported by `tests/` and, in some cases, by `shader_config.nim` for the constants it substitutes into shaders — but the simulation never calls them. Having no caller in `src/` is their normal state, not evidence they are dead:

| Module | Mirrors |
|--------|---------|
| `physics_core.nim` | `forces.wgsl` force curves, density accumulation, wrapping |
| `grid_core.nim` | the bin-count / prefix-sum / bin-scatter grid arithmetic |
| `sph_core.nim` | `forces-sph.wgsl` smoothing kernels, Tait equation, XSPH term |
| `field_core.nim` | `rd-step.wgsl` Gray-Scott reaction-diffusion and the 9-point Laplacian |
| `bloom_core.nim` | `blur.wgsl` separable Gaussian kernel and bloom/grade defaults |
| `colormap_core.nim` | `colormap.wgsl` field colormap ramps |
| `camera_core.nim` | `camera_transform.wgsl` toroidal camera, clip mapping, apparent scale |

`climate_core.nim` sits beside these without belonging to the table: it is pure and natively tested the same way, but it mirrors no shader. It owns the drifting climate's path — a closed tour of the named regimes that the frame loop walks, writing feed and kill through the ordinary `setParam` path so the sliders visibly move.
