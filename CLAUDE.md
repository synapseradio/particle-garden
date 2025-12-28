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

## Language Policy

**All source code must be written in Nim.** No hand-written JavaScript.

- Frontend modules compile from `src/*.nim` to `web/*.js` using `nim js`
- WASM modules compile via emscripten
- WGSL shaders are the only non-Nim source (GPU shaders have no Nim backend)

When modifying frontend behavior, edit the corresponding `.nim` source file, not the generated `.js` file.

**The simulation** uses SharedArrayBuffer for zero-copy parallel physics. The WASM physics module operates directly on shared memory with no data transfer overhead between JS and WASM.
