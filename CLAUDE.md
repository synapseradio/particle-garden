# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**All three build steps are required** - the main app embeds the compiled worker and WASM files.

```bash
# Install dependencies
nimble install

# Build the Web Worker (src/worker.nim -> web/worker.js)
nimble worker

# Build the WASM physics module (src/physics_wasm.nim -> web/physics.js + web/physics.wasm)
nimble wasm

# Build the main app (embeds all web/ files)
nimble build

# Run
./emergent_garden
```

For release builds:
```bash
nimble worker && nimble wasm && nim c -d:release -d:danger --opt:speed src/emergent_garden.nim
```

## Architecture

This is a native desktop wrapper for a particle life simulation that enables SharedArrayBuffer in browsers.

**Two-server architecture:**
- **Nim asynchttpserver** (port 8089): Serves `web/index.html` with COOP/COEP headers required for SharedArrayBuffer
- **webui**: Opens the browser window pointing to localhost:8089

**Why this design:** Browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer. The Nim server provides these headers; webui handles the native window lifecycle.

**Key files:**
- `src/emergent_garden.nim` - HTTP server with COOP/COEP headers + webui window management
- `src/physics_wasm.nim` - WASM physics module → `web/physics.js` + `web/physics.wasm` (via emscripten)
- `src/worker.nim` - Web Worker source → `web/worker.js` (via `nim js`)
- `web/` - Frontend modules (compiled from Nim via `nim js`)

## Data Flow Architecture

### Double Buffering & Parity

The simulation uses double-buffered particle state (A/B buffer sets) with `activeParity` tracking which buffer is current.

**Parity Contract:**
- `activeParity` (0 or 1) points to the buffer containing VALID, COMPLETE particle state
- Parity flips ONCE per frame, AFTER physics writes complete, BEFORE render reads

| Phase | Buffer Read | Buffer Write | Parity Flip |
|-------|-------------|--------------|-------------|
| Physics | `buffer[parity]` | `buffer[parity]` | After completion |
| Render | `buffer[parity]` | — | Never |

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
