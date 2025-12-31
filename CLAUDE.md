# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**BUILD USING `nimble all` EVERY TIME YOU MAKE ANY CHANGE.**

```bash
# Install dependencies
nimble install

# Build everything (worker + wasm + main app)
nimble all

# Run
./main
```

For reference, `nimble all` runs these steps:
- `nimble worker` - Build the Web Worker (src/worker.nim -> web/worker.js)
- `nimble wasm` - Build the WASM physics module (src/physics_wasm.nim -> web/physics.js + web/physics.wasm)
- `nimble build` - Build the main app (embeds all web/ files)

For release builds:
```bash
nimble worker && nimble wasm && nim c -d:release -d:danger --opt:speed src/main.nim
```

## Architecture

This is a native desktop wrapper for a particle life simulation that enables SharedArrayBuffer in browsers.

**Two-server architecture:**
- **Nim asynchttpserver** (port 8089): Serves `web/index.html` with COOP/COEP headers required for SharedArrayBuffer
- **webui**: Opens the browser window pointing to localhost:8089

**Why this design:** Browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer. The Nim server provides these headers; webui handles the native window lifecycle.

**Key files:**
- `src/main.nim` - **HTTP server** with COOP/COEP headers + webui window management. **Contains the StaticFiles table that registers all servable assets.** When adding new shaders or web files, you MUST add them to the StaticFiles table or they won't be served.
- `src/physics_wasm.nim` - WASM physics module → `web/physics.js` + `web/physics.wasm` (via emscripten)
- `src/worker.nim` - Web Worker source → `web/worker.js` (via `nim js`)
- `web/` - Frontend modules (compiled from Nim via `nim js`)

## Data Flow Architecture

### Double Buffering & Parity

The simulation uses double-buffered particle state (A/B buffer sets) with `activeParity` tracking which buffer is current.

**Parity Invariant (universal):**
- `activeParity` (0 or 1) ALWAYS points to the buffer containing VALID, COMPLETE particle state
- After physics completes, `buffer[activeParity]` is ready for rendering
- This invariant holds for BOTH physics paths, despite different implementations

**Parity Behavior (path-specific):**
| Path | Parity Flip? | Why |
|------|--------------|-----|
| WebGPU | **Never** | In-place updates; same buffer read/written |
| WASM | **After scatter** | Double-buffering; scatter writes to opposite buffer |

See "Physics Paths" below for implementation details.

### State Ownership

| State | Owner | When Modified |
|-------|-------|---------------|
| pxA/pyA/vxA/vyA | Physics | WebGPU: always; WASM: when parity=0 |
| pxB/pyB/vxB/vyB | Physics | WebGPU: never; WASM: when parity=1 |
| species* | initParticles() | Only at init/reset |
| activeParity | grid.buildGrid() | WASM path only, after scatter |
| matrix[] | UI | On user input |

### Physics Paths

Two physics implementations exist with **different** parity disciplines:

1. **WebGPU path** (`webgpu_compute.nim`):
   - Does **in-place updates** on a single buffer set
   - Reads from buffer[parity], writes back to buffer[parity]
   - **Does NOT flip parity** - same buffer read by renderer
   - Parity stays constant (typically 0) throughout WebGPU execution

2. **WASM path** (`workers.nim` + `physics_wasm.nim`):
   - Uses **double-buffering** via grid scatter
   - `grid.buildGrid()` scatters particles from buffer[parity] to buffer[1-parity]
   - **Flips parity** after scatter completes
   - Renderer reads from the newly-written buffer

**Key difference**: WebGPU modifies buffers in-place; WASM copies between buffer sets.

## Language Policy

**All source code must be written in Nim.** No hand-written JavaScript.

- Frontend modules compile from `src/*.nim` to `web/*.js` using `nim js`
- WASM modules compile via emscripten
- WGSL shaders are the only non-Nim source (GPU shaders have no Nim backend)

When modifying frontend behavior, edit the corresponding `.nim` source file, not the generated `.js` file.

**The simulation** uses SharedArrayBuffer for zero-copy parallel physics. The WASM physics module operates directly on shared memory with no data transfer overhead between JS and WASM.
