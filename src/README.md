# Developer Guide

This guide is for building and modifying the source code. If you just want to run Particle Garden, grab a binary from [Releases](https://github.com/synapseradio/particle-garden/releases).

## Prerequisites

You'll need [Nim](https://nim-lang.org/) 2.0+ installed:

```bash
# macOS
brew install nim

# Linux
curl https://nim-lang.org/choosenim/init.sh -sSf | sh

# Windows — download from https://nim-lang.org/install.html
# Run finish.exe after extraction to configure PATH
```

Verify: `nim --version`

## Build & Run

```bash
# Install dependencies (first time only)
nimble install -d -y
nimble setup

# Build and run
just happen
./main
```

A browser window opens showing the simulation. Drag sliders to adjust forces between particle species.

| Command | Purpose |
|---------|---------|
| `just happen` | Build everything: shaders, frontend, UI bundle, native binary |
| `just check` | Both test suites (native Nim + bun) |
| `just test` | Native Nim suite only |
| `just release` | Optimized production build |

Build through `just`, not through the `nimble` tasks. Two reasons: the nimble tasks never invoke Bun, so they leave `web/ui-bundle.js` unbuilt — and `main.nim` `staticRead`s it, so a fresh clone fails the native compile and a stale bundle silently ships an old UI. And nimble 0.22.x exits 0 even when a task's exec fails, so a broken build reports success.

---

<details>
<summary><strong>Architecture Guide</strong></summary>

## Why Two Compilation Targets?

This codebase compiles two ways:
1. **Native binary** (`nim c → ./main`) — HTTP server that provides security headers browsers need for GPU memory sharing
2. **JavaScript app** (`nim js → web/app.js`) — the actual simulation running in the browser

You can't just open an HTML file. Browsers require COOP/COEP headers to enable SharedArrayBuffer, which the GPU physics engine needs. The native binary serves those headers, then opens a browser window pointing to localhost:8089.

```
┌─────────────────────────────────────┐
│  You run: ./main                    │
│                                     │
│  Native binary (nim c)              │
│  └─ Starts HTTP server on :8089     │
│  └─ Opens browser via webui         │
│           │                         │
│           ▼                         │
│  Browser loads app.js (nim js)      │
│  └─ Initializes WebGPU              │
│  └─ Creates particle buffers        │
│  └─ Runs frame loop                 │
└─────────────────────────────────────┘
```

## Data Flow

Particles live in a SharedArrayBuffer — memory shared between JavaScript and GPU. No data transfer between CPU/GPU after initialization.

**GPU frame.** `sim_registry.buildFrame` composes the frame as data from the four coupling
strengths, and `webgpu_compute.nim` walks it. The world-intrinsic sequence runs at every setting:
grid build (bin count, three prefix-sum stages, bin scatter), the species force sweep, field
resolve and the Gray-Scott substeps, then integrate. A coupling-owned pass (`forces-sph`,
`field-deposit`, `field-force`) joins the sequence when its strength is above zero. Rendering
follows in `webgpu_render.nim`. [`docs/one-world.md`](../docs/one-world.md) holds the full order
and the rule for adding a coupling.

```
SharedArrayBuffer
├── Particle data (positions, velocities, species, density)
├── Grid buffers (spatial indexing for neighbor queries)
├── Velocity deltas (force accumulation)
└── Interaction matrix (species attraction/repulsion rules)
```

For GPU shader implementation details, see [`web/shaders/README.md`](../web/shaders/README.md).

## Code Organization

```
Runs as Native Binary (nim c → ./main):
┌────────────────────────────────────────────────┐
│  main.nim                                      │
│  └─ HTTP server with COOP/COEP headers         │
│  └─ Opens browser window via webui             │
│  └─ Embeds all web/ files at compile time      │
└────────────────────────────────────────────────┘

Runs in Browser (nim js → web/app.js):
┌────────────────────────────────────────────────┐
│  Foundation                                    │
│  ├─ config.nim        Runtime settings         │
│  ├─ memory_layout.nim Buffer structure         │
│  └─ buffers.nim       SharedArrayBuffer views  │
└────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────┐
│  GPU Pipeline                                  │
│  ├─ webgpu_init.nim    Device + buffer setup   │
│  ├─ webgpu_compute.nim walks the frame data    │
│  └─ webgpu_render.nim  Particle rendering      │
└────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────┐
│  Browser Integration                           │
│  ├─ web_api.nim     window.gardenAPI boundary  │
│  ├─ canvas_input.nim Mouse and touch input     │
│  └─ grid.nim        Spatial grid dimensions    │
└────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────┐
│  Control panel (TypeScript, not Nim)           │
│  └─ web-ui/src/     Solid components driving   │
│                     window.gardenAPI           │
└────────────────────────────────────────────────┘

World composition and pure cores (compile on both backends, tested natively):
├─ sim_registry.nim     The frame as data: which passes run, in what order
├─ shader_manifest.nim  Every compute shader, registered once at init
├─ config_ranges.nim    Every range, with measured bounds beside their conditions
├─ climate_core.nim     Weather tours over the named regimes
├─ camera_drift.nim     The self-moving view
└─ *_core.nim           Reference oracles mirroring shader math (see docs/enforcement.md)

bindings/           Nim wrappers for browser APIs
├─ webgpu.nim       WebGPU types and functions
├─ typed_arrays.nim Float32Array, Uint32Array, etc.
├─ dom_extensions.nim Canvas, element utilities
├─ js_interop.nim   Console, random, JS helpers
└─ window.nim       requestAnimationFrame, timing
```

## Where to Start

| Task | File |
|------|------|
| Understand structure | `app.nim` (imports in dependency order) |
| Change shader math | the shader in `web/shaders/src/` and its mirror `*_core.nim`, same diff |
| Change what a frame dispatches | `sim_registry.nim` (`docs/one-world.md` lists every step) |
| Add a coupling | `docs/one-world.md`, "Adding a fifth coupling" |
| Change the control panel | `web-ui/src/` (Solid/TypeScript) |
| Change what the panel can reach | `web_api.nim` + `ui/api/param_descriptor.nim` |
| Adjust particles | `config.nim` (runtime) or `memory_layout.nim` (structure) |
| Add browser API | new file in `bindings/` |

## Gotchas

**Import order matters.** The import order in `app.nim` is intentional. Nim's JS backend hoists variables, so misordering causes undefined errors at runtime. Don't alphabetize it.

**Register new compute shaders.** A new compute shader needs an entry in `shader_manifest.nim` and in `StaticFiles` (in `main.nim`), or the fetch at pipeline-init fails. Render shaders take the other route — `webgpu_render.nim` `staticRead`s them into `app.js`, and they stay out of `StaticFiles`.

**Buffer offsets live in one place.** All buffer offsets live in `memory_layout.nim` — hardcoding byte offsets elsewhere leads to silent corruption when the layout changes.

**Use just happen.** Running `nim c` or `nim js` alone misses dependencies, and the nimble tasks skip the Bun bundle that the native compile embeds.

</details>
