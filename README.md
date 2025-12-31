# Particle Garden

Thousands of particles attract and repel each other based on simple rules. Different species interact differently, creating emergent behaviors — swarms, orbits, symbiosis, predation. You define the rules; the physics creates the patterns.

## Download

Pre-built binaries on [Releases](https://github.com/synapseradio/particle-garden/releases):

| Platform | File | Notes |
|----------|------|-------|
| **macOS** | `particle-garden-macos.zip` | [See Gatekeeper note](#macos-gatekeeper) |
| **Windows** | `particle-garden-windows.zip` | Extract and run `particle_garden.exe` |
| **Linux** | `particle-garden-linux.tar.gz` | Extract, `chmod +x`, run |

### macOS Gatekeeper

macOS may warn that the app is "damaged" — this is a Gatekeeper warning for unsigned apps, not actual corruption.

To fix, open Terminal and run:
```bash
xattr -dr com.apple.quarantine ~/Downloads/Particle\ Garden.app
```

---

<!-- TODO: Add screenshot or GIF demonstrating the simulation here -->
<!-- Recommended: 600-800px wide GIF showing particles forming patterns -->

## What You Can Do

Particles form swarms, chase each other, or settle into stable orbits — all from simple attraction rules. Click the interaction matrix to change how species react to each other and watch the system reorganize.

Lonely particles grow bigger. Toggle trails to see where things have been.

---

<details>
<summary><strong>How It Works</strong></summary>

All physics runs on your GPU via WebGPU compute shaders. Particles never transfer back to the CPU — they're initialized on the GPU and stay there through simulation and rendering.

The simulation world wraps around like Pac-Man. Particles leaving one edge reappear on the opposite side, so there are no boundary artifacts.

**Why a local server?** Browsers require special security headers (COOP/COEP) to enable SharedArrayBuffer, which GPU memory sharing needs. The app bundles a tiny HTTP server that provides these headers, then opens a browser window pointing to localhost.

For GPU shader implementation details, see [`web/shaders/README.md`](web/shaders/README.md).

</details>

<details>
<summary><strong>Build from Source</strong></summary>

For building and modifying the code, see the [Developer Guide](src/README.md).

Quick version:
```bash
git clone https://github.com/synapseradio/particle-garden
cd particle-garden
nimble install -y
nimble all
./main
```

Requires [Nim](https://nim-lang.org/) 2.0+.

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>

**SharedArrayBuffer unavailable**
Ensure you're running the binary, not opening the HTML file directly. The binary serves the required security headers.

**WebGPU unavailable**
Requires Chrome 113+, Edge 113+, or Firefox (behind a flag).

**Port 8089 in use**
Edit `src/main.nim` and change the port constant.

**Browser doesn't open**
webui (the library that opens the native window) couldn't find a browser. Install Chrome, Firefox, or Edge.

</details>

<details>
<summary><strong>Contributing</strong></summary>

- All source is Nim — no hand-written JavaScript
- Run `nimble test` before submitting
- Code style enforced by compiler flags (see nimble file)
- When adding shaders, register them in the `StaticFiles` table in `main.nim`

See [Developer Guide](src/README.md) for architecture details.

</details>

---

## License

MIT
