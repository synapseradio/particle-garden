# long-range-mesh

## Why

Nothing in the garden reaches past 150 units — `INTERACTION_RADIUS_MAX` (`src/config_ranges.nim:34`),
4% of the 3840-wide world — so every structure the instrument can play is local, and a colony on one
side of the screen cannot answer one on the other. The pass that would most naturally carry that
reach is also the one already spending the budget: the physics bucket measures 0.851–1.471 ms at 30
seconds and 6.529–7.929 ms at 150 seconds at 128 000 particles, still climbing when the window
closed, because the neighbour sweep's cost tracks clustering (`docs/perf-report.md:70`,
`docs/perf-report.md:140`). A settled 128k frame leaves 3.75 ms (`docs/perf-report.md:140`). A
long-range coupling built on pairs or a tree spends that headroom exactly when clustering makes it
scarcest; a particle-mesh solve on a fixed grid costs the same whatever the particles do, which is
why `docs/research/long-range-coupling.md` chose it over pyramid Barnes-Hut and FMM.

## What Changes

- **A fifth coupling, `longRange`.** A strength whose floor is zero, joining the four in
  `WorldCouplings` (`src/sim_registry.nim:67-81`) and the build-asserted floor loop
  (`src/config_ranges.nim:451-457`). It ships at zero, like `fluidStrength` did
  (`src/preset.nim:242-244`), so the shipped world is unchanged until a slider moves.
- **A `reach` control.** The k-space kernel is Yukawa, `1 / (|k|² + 1/λ²)`, so `reach` is the
  screening length λ in world units: small is local, large is 2D gravity, every value between is a
  continuous reach. No mode, no kernel selector — one number the user drags.
- **Five GPU passes, registered and dispatched like every other coupling.** Deposit (per-species
  charge assignment onto a coarse grid, the shape of `web/shaders/src/field-deposit.wgsl`), a row
  FFT, a column FFT, a per-bin kernel multiply, the two inverse transforms, and a force pass that
  samples the gradient and accumulates a velocity delta atomically (the shape of
  `web/shaders/src/field-force.wgsl:81-84`). No new abstraction over passes: new `ShaderSpec`
  entries, new `SimBuffer` values, new `acts(...)` guards in `buildFrame`.
- **Our own FFT in WGSL.** One row pass and one column pass per direction, each line transformed
  inside one workgroup, species batched through the dispatch's z dimension. No library dependency;
  no JavaScript FFT runs on the GPU (`docs/research/long-range-coupling.md:76-79`).
- **The frame gains a 3D dispatch and a second two-cadence chain.** The executor special-cases
  `dsFieldWorkgroups` as 2D today (`src/webgpu_compute.nim:920-924`); the species-batched passes add
  a 3D case. The solve runs once per rendered frame and the force pass once per substep, the split
  the chemistry already makes (`src/sim_registry.nim:332-343`).
- **The grid's live size is a uniform below an allocated ceiling.** Buffers are allocated at a Nim
  constant maximum power of two; the shader indexes by the live size the uniform carries. Because
  the allocation never changes, a resize needs no resource recreation and no bind-group rebuild —
  unlike the chemistry field, whose dimensions are compile-time constants
  (`web/shaders/modules/field_grid.wgsl:22-23`) baked from `FIELD_PATTERN_SHRINK`
  (`src/field_core.nim:32-45`). This change opens that seam for its own grid only; resizing the
  chemistry grid is a later change and carries its own landmines
  (`docs/research/long-range-coupling.md:242-247`).
- **Newton's third law does not hold for this term, and the change says so rather than hiding it.**
  The attraction matrix is asymmetric (`MATRIX_MIN_VALUE`/`MATRIX_MAX_VALUE`,
  `src/config_ranges.nim:63-64`), so no single shared potential exists. Linearity in k-space gives
  one potential per *receiving* species: the kernel times the matrix-weighted sum of the source
  species' spectra. Momentum is not conserved by the long-range term. The mesh tolerates that; an
  FMM would not.
- **The k = 0 mode is zeroed.** The uniform-background convention on a periodic domain: the force
  answers density contrast, not absolute density, so adding particles uniformly changes nothing.
- **Help ships with the feature.** A `long-range` group under `docs/help/`, named by the same
  test-held coverage relations every other group answers to
  (`tests/test_help_content.nim`, `docs/enforcement.md:45`).

Out of scope, named as follow-ups rather than designed here: a tunable kernel family (the kernel is
one k-space multiply, so a second kernel is a formula, not a pass); per-body or per-particle charges
distinct from unit charge; the chemistry-grid resize; long-range links between chosen pairs
(`docs/research/long-range-coupling.md:158-170`); a real-input transform halving the spectrum
buffers.

## Capabilities

### New Capabilities

- `long-range-coupling`: the fifth strength and its `reach`, the deposit-solve-force chain and the
  order it composes in, the Yukawa kernel with its k = 0 convention and cell-scale softening, the
  asymmetric-matrix mixing in k-space and the momentum it does not conserve, the fixed-point density
  and the overflow bound that sizes it, and the grid's live-size-under-a-ceiling seam.

### Modified Capabilities

- `gpu-frame-registry`: the coupling space widens from four strengths to five (sixteen corner worlds
  to thirty-two, `tests/coupling_space.nim`); a coupling becomes a *chain* of passes that the frame
  skips together, which the "a strength may skip a pass only when it multiplies everything that pass
  produces" rule has to be restated to cover; the executor gains a 3D dispatch size.
- `gpu-buffer-layout`: four new GPU buffers and one new uniform layout table (`LrParamsLayout`),
  each with the offset assertions every layout carries.
- `parameter-range-authority`: ranges, defaults, notches and the clamp for the strength, the reach,
  and the grid-size selector.

`in-app-help` is deliberately absent: its coverage requirement already ranges over the whole
descriptor table, so a `long-range` group file is work this change owes and not a requirement that
changes.

## Impact

- **Nim.** `src/config_ranges.nim` (three ranges, the floor loop), `src/field_core.nim`'s sibling —
  a new pure oracle `src/long_range_core.nim` mirroring the kernel, the CIC weights, the k mapping
  and the fixed-point scale, natively tested (`docs/engineering-principles.md:48-53`);
  `src/sim_registry.nim` (the strength, two frame nodes, a profiler slot, four `SimBuffer` values);
  `src/shader_manifest.nim`; `src/gpu_types.nim` (`LrParamsLayout`); `tools/wgsl_bundle.nim` (one
  `generateStructModule` call); `src/webgpu_compute.nim` (`sameFrameShape`, `byteLengthFor`,
  bind groups and their entry counts, the 3D dispatch case, the per-frame uniform write);
  `src/webgpu_init.nim` (buffer creation); `src/wgsl_lint.nim` (the binding manifest);
  `src/main.nim` (`StaticFiles` entries, or the compute shaders are unserved);
  `src/ui/api/param_descriptor.nim`, `src/ui/state/simulation_state.nim`,
  `src/ui/state/sim_config.nim`, `src/preset.nim`.
- **Shaders.** Five new sources under `web/shaders/src/` and one new module
  (`web/shaders/modules/lr_grid.wgsl`), which is where the live-size indexing lives.
- **Panel.** A `long-range` group in `web-ui/src/components/Panel.tsx`, or its sliders never reach
  the screen and `tests/test_panel_reachability.nim` goes red.
- **Dependencies.** None added.
- **Memory.** About 38 MB of GPU buffers at a 512 x 256 x 12 allocation ceiling: density 6.3 MB,
  two complex spectra at 12.6 MB each, potential 6.3 MB.
- **Measurement gate — passed for the solve.** The sibling change
  `openspec/changes/fft-mesh-spike/` measured one batched round trip with the 12 x 12 asymmetric
  species mix at 512 x 256 x 12: **0.417 to 0.450 ms of GPU time**, against the 1.0 ms this change
  allots itself out of the settled 128k headroom of 3.75 ms (`docs/perf-report.md:140`). 512 x 256
  therefore ships, and `design.md` D3 carries the figure, its conditions, and the rule it was read
  against. Two things the gate does not cover: the deposit and gradient-force passes, which the spike
  excluded and which are the two per-particle passes in the chain, and the browser build boundary —
  the spike ran Chromium 152 where the perf record ran Chromium 150.
