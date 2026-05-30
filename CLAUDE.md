# CLAUDE.md

Native desktop wrapper for a particle-life simulation with WebGPU compute physics. All source is Nim; WGSL shaders are the only non-Nim source.

## Golden rules

- **Run `nimble all --verbose` after every change.** Always pass `--verbose` to nimble.
- **All source is Nim.** No hand-written JavaScript. The frontend compiles from `src/*.nim` to `web/app.js`. Edit the `.nim` source, never the generated `.js`.
- **Generated files are off-limits:** `web/app.js` and `web/shaders/*.wgsl` are build output. Do not edit them.
- **`memory_layout.nim` is the single source of truth** for the Particle struct and all buffer offsets. Never hardcode offsets elsewhere.
- **Do not alphabetize imports in `app.nim`.** Nim's JS backend hoists variables, so misordered imports cause undefined-reference errors at runtime. Keep the dependency order below.

## Build and test

```bash
nimble install          # Install dependencies
nimble setup            # Generate nimble.paths; run after install or on "cannot open file: webui"
nimble all --verbose    # Build everything (shaders + frontend JS + native binary)
nimble test             # Run the native test suite (pure-logic modules)
nimble release          # Optimized release build
./main                  # Run
```

`nimble all` runs three steps in order:
1. `nimble shaders` — bundle WGSL shaders (resolve `//! import`, substitute config) via `tools/wgsl_bundle.nim`.
2. `nimble app` — `nim js` compiles `src/app.nim` → `web/app.js` (browser frontend).
3. `nim c` compiles `src/main.nim` → `./main` (native HTTP server).

Run `nimble test` after changing any pure-logic module (physics, grid, memory layout, gpu_types, UI state). The suite is native-only: it compiles `tests/test_all.nim` with `nim c` and exercises the pure modules. Browser, WebGPU, and FFI code is verified by the build itself, not by tests — a broken FFI binding fails `nimble app`. CI runs `nimble test` before any release, so a red suite blocks the release. See `tests/README.md` for layout and conventions.

## Architecture

Two components, because browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer:

- **Nim asynchttpserver** (port 8089) serves `web/index.html` with the COOP/COEP headers.
- **webui** opens a native browser window pointing at localhost:8089 and manages its lifecycle.

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

**Library dependencies are pinned exactly.** Use exact version pins or commit hashes (for example, `webui#552a3e3`, the 2.4.2 tag). `nimble.lock` is committed and updated deliberately. Floating references — `#head`, `>=`, `*`, or anything pointing at `head`/`main`/`master`/`latest` — are forbidden for libraries. A missing or uncommitted lock file is a red flag.

**The nim compiler is the deliberate exception, and must NOT be pinned in the lock.** It is system-provided, bounded only by `requires "nim >= 2.0.0 & < 3.0.0"` in `particle_garden.nimble`. Builds use whatever toolchain is installed: `--useSystemNim` locally, and `iffy/install-nim` with `version: binary:stable` in the release workflow. The `< 3.0.0` upper bound is the guardrail that keeps "track the installed stable toolchain" safe across a future nim major release. Do not add a nim entry back into the lock.

Two failures motivate this split:

- **Floating library ref.** A `requires "webui#head"` pulled unreleased upstream code; the foundation shifted underneath both old releases and new builds, breaking them the same way. Pinning the commit fixed it.
- **Stale pinned compiler.** A pinned nim 2.2.6 in the lock went stale across a gap in work. That version's JS backend emits `system module needs: nimAddStrStr` and cannot compile `web/app.js`, while its native backend stays green — so `nimble test` passed while `nimble all` was silently broken. CI never hit this, because CI ignores the lock's nim and builds on the stable system toolchain, so releases stayed green. Removing the stale pin and matching CI's strategy locally fixed the frontend.

The lesson: pin libraries exactly, but let the compiler track the installed toolchain within the supported range, the way CI always has.

## Releasing

GitHub Actions (`.github/workflows/release.yml`) builds and publishes releases for macOS, Windows, and Linux. It triggers on tags matching `v*`: builds `nimble release` on all three platforms, packages platform artifacts (macOS .app bundle, Windows .exe, Linux binary), and creates a GitHub Release with auto-generated notes. Use `workflow_dispatch` in the Actions UI for draft releases without pushing tags.

The version in `particle_garden.nimble` must match the git tag (without the `v` prefix). Semantic versioning:
- **MAJOR** — breaking changes (user-visible behavior change, config format change, removed features).
- **MINOR** — new features or significant improvements (new UI controls, new physics modes).
- **PATCH** — bug fixes, docs, refactoring (no user-visible functional change).

When versions diverge, examine commits since the last tag to pick the bump — `git log $(git describe --tags --abbrev=0)..HEAD --oneline`. Any breaking commit → major; otherwise any feature → minor; else patch. To release: bump the nimble version, commit, then `git tag vX.Y.Z && git push && git push origin vX.Y.Z`.

## Source map

Two compilation targets: `nim js` builds `src/app.nim` → `web/app.js` (frontend, all modules merged); `nim c` builds `src/main.nim` → `./main` (native HTTP server + webui window).

Import order in `app.nim` matters — each layer depends on the previous one, and the JS backend's hoisting makes misordering fatal at runtime:

```
Layer 1: config                                  (no dependencies)
Layer 2: buffers                                 (uses config)
Layer 3: renderer, grid, ui                      (use buffers)
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
| `ui/` and `ui.nim` | DOM bindings, sliders, mouse/touch events, attraction-matrix editing. `src/ui/` holds the state, controls, input, matrix, and stats submodules. |
| `renderer.nim` | Legacy WebGL renderer (fallback when WebGPU is unavailable). |
| `grid.nim` | Spatial grid dimensions from world size + interaction radius. |
| `grid_core.nim` | Pure grid arithmetic (cell calculations, neighbor iteration). |
| `physics_core.nim` | Pure force-math functions (used by tests). |
| `tools/wgsl_bundle.nim` | Shader preprocessor (resolves `//! import`, substitutes `{{PLACEHOLDER}}`). |

Bindings live in `src/bindings/`: `webgpu.nim` (adapters, devices, buffers, pipelines, bind groups), `typed_arrays.nim` (Float32Array, Uint32Array, Int32Array, ...), `dom_extensions.nim` (Canvas, HTMLElement, classList), `js_interop.nim` (console, random, object creation), `window.nim` (requestAnimationFrame, performance.now()), `webgl.nim` (WebGL for the fallback renderer).
