# Emergent Garden 🦠 - nim-webui Edition

**SharedArrayBuffer-enabled particle life simulation** with zero-copy parallel physics.

## What This Is

A native desktop wrapper around the [Emergent Garden](https://github.com/gyanantaran/emergent-garden) particle simulator that has a few extra goodies.

## Key Features

- **Zero-Copy Physics**: Physics engine runs in a Nim-compiled Web Worker, accessing shared memory directly. No serialization overhead.
- **Density-Based Sizing**: Particles grow larger when isolated from their own species, highlighting outliers.
- **Editable Rules**: Click any cell in the interaction matrix to manually tune attraction/repulsion forces in real-time.
- **Configurable Trails**: Toggle motion trails and adjust their length/persistence.

## Architecture

```
┌──────────────────────────────────────────────┐
│  Nim Binary                                  │
│  ├── asynchttpserver (port 8089)             │
│  │   └── Serves HTML with COOP/COEP headers  │
│  └── webui                                   │
│      └── Opens browser to localhost:8089    │
└──────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────┐
│  Browser (Chrome/Firefox/Edge)               │
│  ├── window.crossOriginIsolated = true       │
│  ├── SharedArrayBuffer available             │
│  └── Web Workers (Nim -> JS) run physics     │
└──────────────────────────────────────────────┘
```

## Requirements

- **Nim >= 2.0.0**
- **webui >= 2.4.0** (nimble will install this)
- **Emscripten** (for WASM physics build)
- A modern browser (Chrome, Firefox, Edge)

## Setup

```bash
# Clone/download this project
cd emergent-garden-webui

# Install dependencies
nimble install

# Compile the Web Worker (src/worker.nim -> web/worker.js)
nimble worker

# Build the WASM physics module (src/physics_wasm.nim -> web/physics.js + web/physics.wasm)
nimble wasm

# Build (debug)
nimble build

# Or build optimized release
nim c -d:release -d:danger --opt:speed src/emergent_garden.nim
```

## Run

```bash
# Ensure worker and WASM are compiled
nimble worker
nimble wasm

# Run
./emergent_garden
# or on Windows:
# emergent_garden.exe
```

This will:
1. Start an HTTP server on `localhost:8089` with COOP/COEP headers
2. Open your default browser to that URL
3. The particle simulation runs with SharedArrayBuffer enabled

## Verifying SharedArrayBuffer Works

Open browser DevTools (F12) → Console. You should see:

```
🦠 Goober Garden - SharedArrayBuffer Edition
   SharedArrayBuffer: ✅ Available
```

The UI will also show a green "SharedArrayBuffer" badge instead of yellow "Copy Mode".

## Performance Comparison

| Mode | Memory Overhead | Description |
|------|----------------|-------------|
| **SharedArrayBuffer** | ~0 bytes/frame | Workers read directly from shared memory |
| Copy (fallback) | ~7 MB/frame | Full buffer copies per worker per frame |

At 60fps with 16K particles and 7 workers, SAB mode saves **~420 MB/s** of memory bandwidth.

## Troubleshooting

### "SharedArrayBuffer is not defined"

The app isn't serving COOP/COEP headers. Ensure you are running the binary (which starts the internal server), not just opening the HTML file directly. The binary serves the embedded content with the correct security headers.

### Browser doesn't open

webui couldn't find a browser. Install Chrome, Firefox, or Edge.

### Port 8089 in use

Edit `src/emergent_garden.nim` and change `PORT = 8089` to another port.

## Packaging

### macOS

Run the included script to create a standalone `.app` bundle:

```bash
./package_mac.sh
```

This will create `Goober Garden.app` which can be moved to `/Applications`.

### Windows

1. Build the worker, WASM, and optimized binary:
   ```bash
   nimble worker
   nimble wasm
   nim c -d:release -d:danger --opt:speed src/emergent_garden.nim
   ```
2. The resulting `src/emergent_garden.exe` is a standalone executable (it embeds the web assets).
3. You can distribute this single file.

## Next Steps → Native Physics (Option 2)

This project validates the SharedArrayBuffer approach. The next evolution would be:

```nim
# Option 2: Native Nim physics, browser just renders
import std/threads

# Nim threads compute forces (way faster than JS)
proc physicsThread(data: ptr ParticleData) {.thread.} =
  while running:
    computeForces(data)  # Native speed
    fence()              # Memory barrier

# Browser polls shared memory via webui bindings
window.bind("getPositions") do (e: Event):
  return toJS(sharedPositions)
```

This would push physics into native code while keeping the WebGL renderer.

## License

MIT
