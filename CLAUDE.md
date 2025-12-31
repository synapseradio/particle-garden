# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**BUILD USING `nimble all` EVERY TIME YOU MAKE ANY CHANGE.**

```bash
# Install dependencies
nimble install

# Build everything (frontend JS + native binary)
nimble all

# Run
./main
```

For reference, `nimble all` runs:
- `nimble app` — Compile `src/app.nim` → `web/app.js` (browser frontend)
- `nim c` — Compile `src/main.nim` → `./main` (native HTTP server)

For release builds:
```bash
nimble release
```

## Releasing

GitHub Actions builds and publishes releases for macOS, Windows, and Linux.

**To release:**
```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow (`.github/workflows/release.yml`) triggers on tags matching `v*`. It:
1. Builds `nimble release` on all three platforms
2. Packages platform-specific artifacts (macOS .app bundle, Windows .exe, Linux binary)
3. Creates a GitHub Release with auto-generated notes

**Test releases:** Use `workflow_dispatch` in GitHub Actions UI to create draft releases without pushing tags.

### Versioning

Version in `particle_garden.nimble` must match the git tag (without `v` prefix).

**Semantic versioning (MAJOR.MINOR.PATCH):**
- **MAJOR** — Breaking changes (user-visible behavior change, config format change, removed features)
- **MINOR** — New features, significant improvements (new UI controls, new physics modes)
- **PATCH** — Bug fixes, docs, refactoring (no user-visible change in functionality)

**When versions diverge**, examine commits since the last tag to determine bump:
```bash
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```
If any commit is breaking → major. If any adds features → minor. Otherwise → patch.

**Release workflow:**
```bash
# 1. Determine new version from commit history
# 2. Update nimble
sed -i '' 's/version.*=.*/version       = "X.Y.Z"/' particle_garden.nimble

# 3. Commit, tag, push
git add particle_garden.nimble && git commit -m "chore: bump version to X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

## Architecture

Native desktop wrapper for a particle life simulation with WebGPU compute physics.

**Two-component design:**
- **Nim asynchttpserver** (port 8089): Serves `web/index.html` with COOP/COEP headers required for SharedArrayBuffer
- **webui**: Opens browser window pointing to localhost:8089

**Why this design:** Browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer. The Nim server provides these headers; webui handles the native window lifecycle.

## Data Flow

### Buffer Architecture

All particle data lives in SharedArrayBuffer with AoS (Array of Structures) layout:

```
Particle struct (32 bytes, cache-aligned):
  offset 0:  px (f32)      position x
  offset 4:  py (f32)      position y
  offset 8:  vx (f32)      velocity x
  offset 12: vy (f32)      velocity y
  offset 16: species (i32) species index (0-5)
  offset 20: density (f32) local density
  offset 24: padding       alignment to 32 bytes
```

### GPU Physics Pipeline

All physics runs on WebGPU compute shaders (no CPU physics path):

1. **bin-count** — Count particles per grid cell
2. **prefix-sum** — Compute cell offsets via parallel scan
3. **bin-scatter** — Scatter particles to sorted buffer by cell
4. **forces** — Compute inter-particle forces from sorted buffer
5. **integrate** — Apply velocity deltas, update positions

Particles stay on GPU from initialization through rendering. No CPU readback.

### Parity Invariant

`activeParity` (0 or 1) points to the buffer containing valid particle state. WebGPU path does in-place updates — parity stays constant (typically 0).

## Language Policy

**All source code must be written in Nim.** No hand-written JavaScript.

- Frontend compiles from `src/*.nim` to `web/app.js` via `nim js`
- WGSL shaders are the only non-Nim source (GPU shaders have no Nim backend)

When modifying frontend behavior, edit the `.nim` source file, not generated `.js`.

---

## Source Code Reference

### Compilation Targets

| Source | Compiler | Output | Purpose |
|--------|----------|--------|---------|
| `app.nim` | `nim js` | `web/app.js` | Browser frontend (all modules merged) |
| `main.nim` | `nim c` | `./main` | Native HTTP server + webui window |

### Module Inventory

#### Core Application

| Module | Purpose |
|--------|---------|
| **main.nim** | HTTP server (port 8089) with COOP/COEP headers, webui window management, static file serving. Contains `StaticFiles` table — new web assets must be registered here. |
| **app.nim** | Frontend entry point, imports all modules in dependency order, runs frame loop |

#### Configuration & Memory

| Module | Purpose |
|--------|---------|
| **config.nim** | Runtime CONFIG object (particle count, physics params), re-exports memory layout constants |
| **memory_layout.nim** | Single source of truth for AoS Particle struct (32 bytes), buffer offsets, limits |
| **buffers.nim** | Creates typed array views (Float32Array, Uint32Array) on SharedArrayBuffer |

#### WebGPU Pipeline

| Module | Purpose |
|--------|---------|
| **webgpu_init.nim** | GPU device initialization, feature detection, buffer allocation |
| **webgpu_compute.nim** | 5-pass compute pipeline: bin-count, prefix-sum, bin-scatter, forces, integrate |
| **webgpu_render.nim** | GPU rendering: instanced quads, trail effects, glow pipeline |

#### Browser Integration

| Module | Purpose |
|--------|---------|
| **ui.nim** | DOM bindings, sliders, mouse/touch events, attraction matrix editing |
| **renderer.nim** | Legacy WebGL renderer (fallback if WebGPU unavailable) |
| **grid.nim** | Computes spatial grid dimensions from world size + interaction radius |
| **grid_core.nim** | Pure grid arithmetic (cell calculations, neighbor iteration) |
| **physics_core.nim** | Pure mathematical force functions (used by tests) |

#### Bindings (`bindings/`)

| Module | Purpose |
|--------|---------|
| **webgpu.nim** | Type-safe WebGPU: adapters, devices, buffers, pipelines, bind groups |
| **typed_arrays.nim** | Float32Array, Uint32Array, Int32Array, etc. |
| **dom_extensions.nim** | Canvas, HTMLElement extensions, classList |
| **js_interop.nim** | Console, random, object creation, general JS utilities |
| **window.nim** | requestAnimationFrame, performance.now() |
| **webgl.nim** | WebGL API (for fallback renderer) |

### Dependency Order

Import order in `app.nim` matters. Each layer depends on previous layers:

```
Layer 1: config (no dependencies)
    │
Layer 2: buffers (uses config)
    │
Layer 3: renderer, grid, ui (use buffers)
    │
Layer 4: webgpu_init, webgpu_compute, webgpu_render (use all above)
    │
    └── app.nim imports in this exact order
```

**Do not alphabetize imports** — Nim's JS backend hoists variables; misordering causes undefined errors at runtime.

### Code Conventions

**Compiler flags (enforced via nimble):**
- `--styleCheck:error` — snake_case enforcement
- Warnings as errors: `Deprecated`, `BareExcept`, `CStringConv`, `EnumConv`, `ProveInit`, `UnusedImport`

**Memory layout:**
All buffer offsets defined in `memory_layout.nim`. Never hardcode offsets elsewhere.

**Static file registration:**
New shaders or web assets must be added to `StaticFiles` table in `main.nim` or they won't be served.
