# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies
nimble install

# Build (debug)
nimble build

# Build optimized release
nim c -d:release -d:danger --opt:speed src/emergent_garden.nim

# Run
./src/emergent_garden
```

## Architecture

This is a native desktop wrapper for a particle life simulation that enables SharedArrayBuffer in browsers.

**Two-server architecture:**
- **Nim asynchttpserver** (port 8089): Serves `web/index.html` with COOP/COEP headers required for SharedArrayBuffer
- **webui**: Opens the browser window pointing to localhost:8089

**Why this design:** Browsers require Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers to enable SharedArrayBuffer. The Nim server provides these headers; webui handles the native window lifecycle.

**Key files:**
- `src/emergent_garden.nim` - HTTP server with COOP/COEP headers + webui window management
- `web/index.html` - Self-contained particle simulation (~47KB) with embedded Web Workers

**The simulation** uses SharedArrayBuffer for zero-copy parallel physics across Web Workers. Workers read particle positions directly from shared memory instead of receiving copied buffers via postMessage.
