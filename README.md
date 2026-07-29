# Particle Garden

<img width="1364" height="859" alt="Screenshot 2026-01-07 at 13 06 07" src="https://github.com/user-attachments/assets/9958c1e8-2152-40fb-b2e6-a18c7d3299cc" />

Thousands of particles attract and repel each other based on simple rules. Different species interact differently, creating emergent behaviors — swarms, orbits, symbiosis, predation.  Very zen.

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

## One World

Three kinds of physics run in the same world at once, each behind its own strength slider: species forces, fluid pressure, and a chemical field. Every strength reaches zero, so "just particle life" or "just fluid" is an ordinary place on the sliders rather than a mode — the panel never changes shape, and every control is always live.

**Species forces.** Six species attract and repel each other according to a 6x6 matrix you can edit directly. This is where swarms, orbits, and predation come from.

**Fluid.** Smoothed-particle pressure and viscosity over the same particles. It sloshes.

**Chemistry.** A Gray-Scott reaction-diffusion field lives behind the particles, growing the spots, stripes and coral patterns that show up on seashells and animal coats. Particles secrete into the field as they move — colonies are what ignite a pattern; nothing seeds it automatically — and the pattern's gradients steer them back. Feed and Kill choose the pattern; the regime buttons (Waves, Mitosis, Labyrinth, Spots, Worms, Coral) jump to known-good coordinates, and the Drift toggle lets the climate wander between them on its own.

Presets are named points in this parameter space. The starter presets, one per regime, are places to begin; save your own, and presets saved by earlier versions still load.

## What You Can Do

Particles form swarms, chase each other, or settle into stable orbits — all from simple attraction rules. Click the interaction matrix to change how species react to each other and watch the system reorganize.

Lonely particles grow bigger. Toggle trails to see where things have been.

Scroll or middle-drag to pan; pinch — or Ctrl/Cmd + scroll — to zoom at the cursor; arrow keys pan too, and `0` resets the view. Zoom in to follow a single creature; the world itself wraps like Pac-Man, so nothing ever hits a wall.

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
nimble setup
just happen
./main
```

Requires [Nim](https://nim-lang.org/) 2.0+, [Bun](https://bun.sh/) for the control panel bundle, and [just](https://github.com/casey/just).

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

- Read [`docs/engineering-principles.md`](docs/engineering-principles.md) first — twelve short articles; contributions are reviewed against them.
- The simulation, GPU pipeline, and server are Nim; the control panel is SolidJS/TypeScript under `web-ui/`; shaders are WGSL. Nim owns every simulation value, and the panel reads them through `window.gardenAPI` rather than restating any of them.
- Build with `just happen` and run `just check` before submitting — it covers both the Nim and TypeScript suites.
- Code style enforced by compiler flags (see nimble file)
- When adding a compute shader, register it in `shader_manifest.nim` and in the `StaticFiles` table in `main.nim`

See [Developer Guide](src/README.md) for architecture details.

</details>

---

## License

MIT
