## Why

`docs/research/long-range-coupling.md` chooses a particle-mesh FFT solve (rung 1 of its
ladder) for long-range coupling, and records as a landmine that "the mesh cost is unmeasured.
No figure for a batched 512 x 256 x 12 transform on the perf record's machine exists."
`docs/perf-report.md` leaves 3.75 ms of a 16.7 ms frame at n=128000 after 150 seconds, and
its physics trace was still climbing when the window closed. Every budget claim in a
long-range mesh design therefore rests on a number nobody has taken. A wrong number sends the
design down the wrong grid size.

## What Changes

- A standalone measurement page under `scratchpad/fft-spike/` runs a forward 2D complex FFT,
  a per-bin k-space multiply, and an inverse 2D complex FFT over a W x H grid batched B deep,
  as the coupling would run it every frame.
- The FFT is a Stockham radix-2 in WGSL, one workgroup per line, batched through the
  dispatch's z dimension. Nothing under `src/`, `web/`, `web-ui/` or `tests/` changes, so
  `just happen` and `just check` are untouched by this change.
- The transform is verified before it is timed: an impulse and a single sine round-trip to
  themselves within f32 tolerance, and the impulse's forward spectrum and the sine's peak bins
  are checked against their analytic values.
- `design.md` records the measurement: machine, browser build, WGSL approach, the six sizes
  (256x128, 512x256, 1024x512, each at batch 12 and batch 1) plus the 12x12 k-space mix, and
  each figure as a min-max over the settled tail of its window, matching the convention in
  `docs/perf-report.md`, which never averages.
- No feature ships. The deliverable is a number with its conditions.

## Capabilities

### New Capabilities

None. The spike adds no runtime behaviour: the app's frame composition
(`src/sim_registry.nim:222-351`) is unchanged and no shader under `web/shaders/src/` is added
or edited. `.openspec.yaml` therefore sets `skip_specs: true`.

### Modified Capabilities

None.

## Impact

- New files under `scratchpad/fft-spike/`: `index.html`, `main.js`, `fft_line.wgsl`,
  `kernel.wgsl`, `mix_kernel.wgsl`, `run_fft.ts`, and the run records under `runs/`.
- Reuses `scratchpad/main/perf-harness/coop_server.py` unchanged, on port 8893 so it does not
  collide with the app's own 8089 or the perf harness's 8891.
- Reuses the perf harness's Chromium launch shape and its CDP client structure
  (`scratchpad/main/perf-harness/run.ts`); no browser driver or package is installed.
- Settles the "the mesh cost is unmeasured" landmine in
  `docs/research/long-range-coupling.md`. Whether the figure is affordable is a decision for
  the long-range mesh design, not for this change.
