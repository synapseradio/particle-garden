# CLAUDE.md

Native desktop wrapper for a particle-life simulation with WebGPU compute physics. The simulation, WebGPU pipeline, and native server are Nim; the control panel is SolidJS/TypeScript (`web-ui/`); WGSL shaders are the only other non-Nim source.

## Golden rules

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

Run `just test` after changing any pure-logic Nim module (physics, grid, memory layout, gpu_types, UI state, param descriptor). The suite is native-only: it compiles `tests/test_all.nim` with `nim c` and exercises the pure modules. `just test-ui` covers the TypeScript pure logic (preset storage, formatting) with `bun test`. Browser, WebGPU, and FFI code is verified by the build itself — a broken FFI binding fails `build-app`, and a broken component fails the typecheck. CI runs `just check` before any release, so a red suite blocks the release. See `tests/README.md` for layout and conventions.

## Architecture

Two components, because browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer:

- **Nim asynchttpserver** (port 8089) serves `web/index.html` with the COOP/COEP headers.
- **webui** opens a native browser window pointing at localhost:8089 and manages its lifecycle.

### The gardenAPI boundary

`src/web_api.nim` installs a single `window.gardenAPI` object at `app.js` module-eval time — before the Solid bundle evaluates. The Solid panel (`web-ui/`) drives everything through it: descriptor-driven sliders (`descriptor()`/`setParam`/`commitParam`, clamped in Nim against `ui/api/param_descriptor.nim`), mode/palette/colormap catalogs, live `matrix()`/`colors()` Float32Array references gated behind `onReady` (buffers exist only after `init()`), a pushed stats stream (`onStats`, cadence set loop-side in `app.nim`), and hybrid presets (`exportPresetJson`/`applyPresetJson` keep schema, validation, and `presetApplySteps` order in Nim; the UI owns localStorage under `preset_store_core`'s `pg.presets.*` keys, so presets saved before the port keep loading). One JS-backend caveat lives at this boundary: `std/json.parseJson` delegates to `JSON.parse`, whose SyntaxError is a foreign exception Nim's `except ValueError` cannot catch — `applyPresetJson` pre-checks parseability instead.

### Particle buffer

All particle data lives in a SharedArrayBuffer with AoS (Array of Structures) layout. The Particle struct is 32 bytes, cache-aligned (two particles per 64-byte cache line):

| Offset | Field | Type | Meaning |
|--------|-------|------|---------|
| 0  | px | f32 | position x |
| 4  | py | f32 | position y |
| 8  | vx | f32 | velocity x |
| 12 | vy | f32 | velocity y |
| 16 | species | i32 | species index (0-5) |
| 20 | density | f32 | local density |
| 24 | padding | — | alignment to 32 bytes |

### GPU physics pipeline

All physics runs on WebGPU compute shaders — there is no CPU physics path. Five passes per frame:

1. **bin-count** — count particles per grid cell.
2. **prefix-sum** — compute cell offsets via parallel scan.
3. **bin-scatter** — scatter particles to a sorted buffer by cell.
4. **forces** — compute inter-particle forces from the sorted buffer.
5. **integrate** — apply velocity deltas, update positions.

Particles stay on the GPU from initialization through rendering. There is no CPU readback.

## Shaders

WGSL shaders use a module system with build-time preprocessing. Layout under `web/shaders/`:

- `modules/` — shared WGSL imported via `//! import` (particle, grid_params, cell_index, fixed_point, scan_params).
- `src/` — source shaders that declare `//! import particle, ...` directives.
- `*.wgsl` (top level) — generated bundled output. DO NOT EDIT.

`tools/wgsl_bundle.nim` reads `web/shaders/src/*.wgsl`, resolves the `//! import` directives from `modules/`, substitutes `{{PLACEHOLDER}}` values from `src/shader_config.nim`, and writes the bundled output.

**Add a shader:** create `web/shaders/src/my-shader.wgsl`, add `//! import particle` (and any other modules) at the top, run `nimble shaders`, then register it in the `StaticFiles` table in `main.nim`. New shaders or web assets not in `StaticFiles` are not served.

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
- **MINOR** — new features or significant improvements (new UI controls, new physics modes).
- **PATCH** — bug fixes, docs, refactoring (no user-visible functional change).

When versions diverge, examine commits since the last tag to pick the bump — `git log $(git describe --tags --abbrev=0)..HEAD --oneline`. Any breaking commit → major; otherwise any feature → minor; else patch. To release: bump the nimble version, commit, then `git tag vX.Y.Z && git push && git push origin vX.Y.Z`.

## Source map

Three build targets: `nim js` builds `src/app.nim` → `web/app.js` (simulation frontend, all modules merged); Bun builds `web-ui/src/main.tsx` → `web/ui-bundle.js` + `.css` (Solid control panel); `nim c` builds `src/main.nim` → `./main` (native HTTP server + webui window, staticReads the other two).

Import order in `app.nim` matters — each layer depends on the previous one, and the JS backend's hoisting makes misordering fatal at runtime:

```
Layer 1: config                                  (no dependencies)
Layer 2: buffers                                 (uses config)
Layer 3: renderer, grid, canvas_input, web_api   (use buffers)
Layer 4: webgpu_init, webgpu_compute, webgpu_render  (use all above)
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
| `gpu_types.nim` | Type-safe GPU struct layouts with compile-time validation, named buffer indices. |
| `webgpu_init.nim` | GPU device init, feature detection, buffer allocation. |
| `webgpu_compute.nim` | The 5-pass compute pipeline (bin-count, prefix-sum, bin-scatter, forces, integrate). |
| `webgpu_render.nim` | GPU rendering: instanced quads, trail effects, glow pipeline. |
| `web_api.nim` | The `window.gardenAPI` boundary: typed-state → CONFIG bridge (synchronous mirror), descriptor-clamped parameter writes, palette/matrix/mode logic, preset snapshot/apply. |
| `canvas_input.nim` | Canvas mouse/touch input → physics (currentInput observable), resize and particle-reinit callbacks. |
| `ui/api/param_descriptor.nim` | Pure descriptor table for every tunable (id, range, step, precision, default, store routing); natively tested; served to TS via `gardenAPI.descriptor()`. |
| `ui/` | Pure UI state modules (`state/`, `core/observable`, `input/` handlers, `presets/preset_store_core`); natively tested where pure. |
| `web-ui/` | The Solid control panel (TypeScript): components over gardenAPI, localStorage preset I/O, formatting; built by Bun via `build.ts`. |
| `renderer.nim` | Legacy WebGL renderer (fallback when WebGPU is unavailable). |
| `grid.nim` | Spatial grid dimensions from world size + interaction radius. |
| `grid_core.nim` | Pure grid arithmetic (cell calculations, neighbor iteration). |
| `physics_core.nim` | Pure force-math functions (used by tests). |
| `tools/wgsl_bundle.nim` | Shader preprocessor (resolves `//! import`, substitutes `{{PLACEHOLDER}}`). |

Bindings live in `src/bindings/`: `webgpu.nim` (adapters, devices, buffers, pipelines, bind groups), `typed_arrays.nim` (Float32Array, Uint32Array, Int32Array, ...), `dom_extensions.nim` (Canvas, HTMLElement, classList), `js_interop.nim` (console, random, object creation), `window.nim` (requestAnimationFrame, performance.now()), `webgl.nim` (WebGL for the fallback renderer).
