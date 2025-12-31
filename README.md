# Particle Garden 🦠

**SharedArrayBuffer-enabled particle life simulation** with zero-copy parallel physics.

## What This Is

A native desktop particle life simulation with WebGPU compute shaders.

## Download

Pre-built binaries available on [Releases](../../releases):

| Platform | File | Install |
|----------|------|---------|
| **macOS** | `particle-garden-macos.zip` | Extract, [see note below](#macos-installation) |
| **Windows** | `particle-garden-windows.zip` | Extract, run `particle_garden.exe` |
| **Linux** | `particle-garden-linux.tar.gz` | Extract, `chmod +x`, run |

### macOS Installation

macOS may show **"Particle Garden.app is damaged"** — this is a Gatekeeper warning for unsigned apps, not actual corruption.

**To fix**, open Terminal and run:
```bash
xattr -dr com.apple.quarantine ~/Downloads/Particle\ Garden.app
```

Then move to Applications and launch normally.

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

**All three build steps are required.** The main app binary embeds the compiled worker and WASM files at compile time.

```bash
# Clone/download this project
cd particle-garden

# Install dependencies
nimble install

# Build all (required order):
nimble worker  # src/worker.nim -> web/worker.js
nimble wasm    # src/physics_wasm.nim -> web/physics.js + web/physics.wasm
nimble build   # embeds web/* into the binary

# Or build optimized release
nimble worker && nimble wasm && nim c -d:release -d:danger --opt:speed src/main.nim
```

## Run

```bash
# Run
./main
# or on Windows:
# main.exe
```

This will:
1. Start an HTTP server on `localhost:8089` with COOP/COEP headers
2. Open your default browser to that URL
3. The particle simulation runs with SharedArrayBuffer enabled

## Verifying SharedArrayBuffer Works

Open browser DevTools (F12) → Console. You should see:

```
🦠 Particle Garden - SharedArrayBuffer Edition
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

Edit `src/main.nim` and change `PORT = 8089` to another port.

## Packaging

### macOS

Run the included script to create a standalone `.app` bundle:

```bash
./package_mac.sh
```

This will create `Particle Garden.app` which can be moved to `/Applications`.

### Windows

Run the included script:

```cmd
package_win.bat
```

This creates `particle_garden.exe` which can be distributed as a single file.

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
