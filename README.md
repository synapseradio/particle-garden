# Emergent Garden 🦠 - nim-webui Edition

**SharedArrayBuffer-enabled particle life simulation** with zero-copy parallel physics.

## What This Is

A native desktop wrapper around the Emergent Garden particle simulator that:

1. **Enables SharedArrayBuffer** via Cross-Origin Isolation headers (COOP/COEP)
2. **Opens in your default browser** via nim-webui
3. **Eliminates ~7MB/frame of memory copies** in worker mode

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
│  └── Web Workers read shared memory directly │
└──────────────────────────────────────────────┘
```

## Requirements

- **Nim >= 2.0.0**
- **webui >= 2.4.0** (nimble will install this)
- A modern browser (Chrome, Firefox, Edge)

## Setup

```bash
# Clone/download this project
cd emergent-garden-webui

# Install dependencies
nimble install

# Build (debug)
nimble build

# Or build optimized release
nim c -d:release -d:danger --opt:speed src/emergent_garden.nim
```

## Run

```bash
./src/emergent_garden
# or on Windows:
# src\emergent_garden.exe
```

This will:
1. Start an HTTP server on `localhost:8089` with COOP/COEP headers
2. Open your default browser to that URL
3. The particle simulation runs with SharedArrayBuffer enabled

## Verifying SharedArrayBuffer Works

Open browser DevTools (F12) → Console. You should see:

```
🦠 Emergent Garden - SharedArrayBuffer Edition
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

The server isn't setting COOP/COEP headers. Check:
1. You're accessing via `http://localhost:8089`, not `file://`
2. The Nim server is running (check terminal output)

### Browser doesn't open

webui couldn't find a browser. Install Chrome, Firefox, or Edge.

### Port 8089 in use

Edit `src/emergent_garden.nim` and change `PORT = 8089` to another port.

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
