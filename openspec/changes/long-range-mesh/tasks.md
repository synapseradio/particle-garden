These tasks build the fifth coupling by the fourteen steps of `docs/one-world.md:188-284`, in an order
that keeps every group's end state playable. The coupling ships at strength zero, so from group 2
onward the app runs exactly as it did before while the chain is assembled behind a slider nobody has
moved — that is what lets group 3 declare a frame whose shaders do not exist yet without breaking a
build or a run.

The proposal's measurement gate is already passed and belongs to another change: the spike measured
the solve at 0.417 to 0.450 ms against a 1.0 ms allotment, which is why 512 x 256 is the shipped size
(design D3, `openspec/changes/fft-mesh-spike/design.md`). One gate remains inside this change and it
sits in group 6: the spike excluded the deposit and gradient-force passes, so about 0.55 ms of the
allotment is unmeasured. That gate governs exactly one thing — which declared grid size the default
selector position names — and the fallback is a constant inside the same group, which is why it does
not precede groups 1 through 5.

Every decision the design opened is settled (design, Settled decisions). Four of them shape what
appears below: the strength range is `0.0 .. 1.0` with a working ceiling, the reach is `60 .. 4000`
logarithmic, the grid size is a visible selector, and the softening stays at 1.5 cells with the
overlap against the species force intended.

Every group ends green on both suites. Where a task says **red first**, run it and watch it fail for
the stated reason before writing the code — the observed failure is the proof the test can see the
defect (`docs/engineering-principles.md:84-90`). Run the narrow target while working
(`nim c -r tests/test_long_range_core.nim`) and the full suite at each group's end.

Four things hold for every test below. Name it `<subject> <verb> <behavior> [when <condition>]`, the
form the existing suites use. Let it fail for one reason and say which — a sweep reports the axis and
the value that broke it, not merely that something broke. Take the expected result from somewhere
other than the code under test: this suite is the oracle the five shaders are written against, so an
assertion that calls the function under test to compute its own expectation proves nothing. The
independent oracles available here are a naive O(N²) DFT written for the test and never shipped, the
closed-form Yukawa response, superposition, symmetry (a uniform source yielding zero), momentum
summing to zero under a symmetric matrix, and the closed-form CIC weights summing to one. Use
`unittest`'s own `check` and `require` throughout.

## 1. The pure long-range core

Everything in this group is native Nim. No shader, no buffer, no panel.

- [x] 1.1 **Red first.** Write `tests/test_long_range_core.nim` against a module that does not exist
      yet, covering the transform alone: the forward transform of a known line equals a naive DFT
      written in the test file to f32 tolerance; forward then inverse is the identity to f32
      tolerance; a delta function transforms to a constant magnitude across all bins. Register the
      module in `tests/test_all.nim` and in `tests/README.md`. Verify:
      `nim c -r tests/test_long_range_core.nim` fails to compile on the missing import
- [x] 1.2 Write `src/long_range_core.nim` with the reference transform of design D4, pure, no FFI, no
      import from GPU-facing code. Verify: the 1.1 assertions pass
- [x] 1.3 **Red first.** Extend the suite with the wavenumber mapping and the kernel of design D6 and
      D7: the kernel equals `exp(-k²σ²/2) / (k² + 1/λ²) / (W·H)` at every bin; it is exactly zero at
      `k = 0` at both a short and a long reach; the radius at which a point source's potential falls
      to a fixed fraction of its peak increases monotonically across the whole shipped reach range;
      the potential at equal world distances along x and along y agrees within one cell's
      interpolation error on a grid whose cells are not square; the kernel's magnitude at the grid's
      Nyquist wavenumber is below a recorded fraction of its magnitude at the reach's wavenumber.
      Verify: the new tests fail
- [x] 1.4 Add the wavenumber mapping, the kernel and the softening constant to
      `src/long_range_core.nim`, the softening recorded in cells at 1.5 with its condition beside it.
      Verify: 1.3 passes, including the isotropy test, which is the one that catches a kernel indexed
      by bin number instead of physical wavenumber
- [x] 1.5 **Red first.** Extend the suite with charge assignment and the fixed point of design D8: the
      CIC weights for any position sum to one; assignment wraps on the torus, so a particle one unit
      from a world edge deposits across the seam as it would anywhere; the whole particle budget in
      one cell encodes without saturating and decodes to the particle count; the scale is a power of
      two; the smallest non-zero CIC weight stays above the accumulator's resolution. Verify: the new
      tests fail
- [x] 1.6 Add the CIC weights, the toroidal wrap and the fixed-point scale to
      `src/long_range_core.nim` with the static assertion `MAX_PARTICLES * scale < high(int32)` beside
      the constant, and add `LR_GRID_MAX_W` and `LR_GRID_MAX_H` to `src/memory_layout.nim` beside
      `MAX_PARTICLES`, `MAX_SPECIES` and `MAX_GRID`, with static assertions that both are powers of
      two. Verify: 1.5 passes, and halving the scale's exponent past the bound turns the compile red
- [x] 1.7 **Red first.** Extend the suite with the species mix of design D5 and the properties the
      spec names: the potential of a sum of two species' densities equals the sum of their separately
      solved potentials; a uniform density produces zero gradient everywhere at every reach; the
      impulses over a population sum to zero under a symmetric attraction matrix and are not required
      to under an asymmetric one, with the same arrangement in both. Verify: the new tests fail
- [x] 1.8 Add the matrix-weighted k-space mix and the gradient sampler to `src/long_range_core.nim`.
      Verify: 1.7 passes
- [ ] 1.9 `just happen` builds and `just check` is green

## 2. The numbers, the panel surface, and the preset

The coupling becomes visible and storable here, and does nothing. At the end of this group the panel
carries three controls, a preset round-trips them, and the world is unchanged because the strength
defaults to zero.

- [ ] 2.1 **Red first.** Extend `tests/test_param_descriptor.nim` for the three descriptors:
      `longRangeStrength`, `longRangeReach` and `longRangeGridIndex` exist in a `long-range` group led
      by the strength; each clamps a write outside its range onto the range; the grid index clamps
      onto the declared table, so no index outside it is storable. Verify: the new tests fail on the
      missing descriptors
- [ ] 2.2 Add the ranges to `src/config_ranges.nim`: `LONG_RANGE_STRENGTH_MIN/MAX` at `0.0 .. 1.0`
      with the ceiling marked a working bound and its calibration conditions recorded beside it the
      way `CROWDING_STRENGTH_MAX` is (`:46-54`); `LONG_RANGE_REACH_MIN/MAX` at `60 .. 4000` with the
      strictly-positive floor's reason beside it; the `LR_GRID_SIZES` table of declared power-of-two
      sizes with `LONG_RANGE_GRID_INDEX_MAX` derived from its length. Extend the coupling-floor loop
      at `:451-457` with `LONG_RANGE_STRENGTH_MIN`, and add static assertions that every declared size
      is a power of two no larger than the `memory_layout` ceiling and that its longest line fits the
      256-invocation workgroup the transform compiles against. Verify: setting any floor non-zero or
      any declared size to a non-power-of-two turns the compile red
- [ ] 2.3 Add the three fields and their defaults to `src/ui/state/simulation_state.nim`
      (`SimulationState` and `initSimulationState`), strength at `0.0`, reach at `600`, grid index at
      the position naming 512 x 256. Verify: 2.1 passes for existence
- [ ] 2.4 Add the three descriptors to `src/ui/api/param_descriptor.nim` in a `long-range` group, the
      strength leading, the reach carrying `curve = cLog` — which the curve-floor gate at the bottom
      of that module permits only against the positive floor 2.2 set — and notches on the strength at
      zero and at one. Verify: 2.1 passes in full, and `tests/test_param_descriptor.nim`'s curve-floor
      case stays green
- [ ] 2.5 Add the `long-range` group to `groupParamIds` in `web-ui/src/components/Panel.tsx`. Verify:
      `tests/test_panel_reachability.nim` is green, and was red before this task
- [ ] 2.6 Write `docs/help/35-long-range.md` with `group: long-range`, naming all three ids in its
      `` - `id` `` lines: what the strength does, that reach is a screening length and small is local,
      and that the grid size is the coupling's cost knob. Verify: `tests/test_help_content.nim` is
      green, and was red on the missing group file before this task
- [ ] 2.7 **Red first, then carry.** Extend `tests/test_preset.nim` with a round trip of the three
      settings and with a preset carrying none of the three keys decoding to their defaults through no
      migration branch. Then add the fields to `PresetSettings`, `defaultSettings`, `validateSettings`
      and `toJson` in `src/preset.nim`, adding no schema version and no `LEGACY_MODE_COUPLINGS` row.
      Verify: both cases pass and `CURRENT_SCHEMA_VERSION` is unchanged
- [ ] 2.8 `just happen` builds and `just check` is green

## 3. The frame: a fifth strength and a chain that skips as one

Pure Nim and native tests. The frame learns to dispatch a chain whose shaders arrive in group 5; the
default strength of zero means no frame dispatches it yet, so the app keeps running.

- [ ] 3.1 **Red first.** Add a fifth level to the nested loops in `tests/coupling_space.nim` and the
      `longRange` member to `FULLY_COUPLED` and `UNCOUPLED`, widening `ALL_COUPLINGS` from sixteen
      corner worlds to thirty-two. Verify: `tests/test_sim_registry.nim` and
      `tests/test_shader_manifest.nim` fail to compile on the missing `WorldCouplings` member
- [ ] 3.2 **Red first.** Extend `tests/test_sim_registry.nim`: add the seven long-range pipeline keys
      to the `KNOWN` list and to the strip list in "no world enumerates", so stripping them from any
      frame still leaves exactly `WORLD_INTRINSIC_SEQUENCE`; add a case to "A Strength At Zero Skips
      Its Own Pass And Nothing Else" asserting that zero long-range strength removes all seven
      dispatches and changes nothing else; assert the solve node's cadence is `fncOncePerFrame` and
      the force node's is `fncEverySubstep`, and that no compute pass mixes two; assert the density
      clear carries the solve's cadence; assert the new profiler slot is distinct from every other
      slot that indexes the query set. Verify: the new cases fail
- [ ] 3.3 Add to `src/sim_registry.nim`: the `longRange` member of `WorldCouplings`; the four
      `SimBuffer` values `sbLrDensity`, `sbLrSpectrumA`, `sbLrSpectrumB`, `sbLrPotential`; the
      three-dimensional `DispatchSize` values for the row, column, bin and particle shapes the chain
      needs; `PROFILER_SLOT_LONG_RANGE`; the `fncOncePerFrame` density clear; and the two guarded
      nodes of design D12's frame sketch — the solve after Physics, the force before Integrate.
      Verify: 3.1 and 3.2 pass
- [ ] 3.4 Add `passLongRange` to `src/gpu_profiler.nim` with `numPasses` raised to match, mirroring
      the slot constant 3.3 added. Verify: `just happen` builds, and the two values agree by reading
      both files — the pairing is unenforced and `src/sim_registry.nim:181-186` already records why
- [ ] 3.5 Read the strength in `couplingsOf` (`src/ui/state/sim_config.nim`) and add it to
      `sameFrameShape` (`src/webgpu_compute.nim:133-141`), so a strength crossing zero rebuilds the
      frame. Verify: a native test asserting `sameFrameShape` distinguishes a zero from a non-zero
      long-range strength, red before this task
- [ ] 3.6 **Red first, then carry.** Extend `tests/test_shader_manifest.nim` for the seven keys, then
      add `LONG_RANGE_SPECS` to `src/shader_manifest.nim` and append it in `allShaderSpecs`, two keys
      sharing `lr-fft-rows.wgsl` at different entry points and two sharing `lr-fft-cols.wgsl`. Verify:
      every key any frame dispatches is registered exactly once
- [ ] 3.7 `just happen` builds and `just check` is green

## 4. Layouts, buffers, and the executor's third dimension

- [ ] 4.1 **Red first.** Extend `tests/test_gpu_types.nim` with a "Generated LrParams Layout" suite
      pinning the field order, the written size and the allocated size. Verify: it fails on the
      missing layout
- [ ] 4.2 Add `LrParamsLayout` to `src/gpu_types.nim` carrying the live grid width and height, the
      live species count, the frame-scaled force strength, the inverse squared screening length, the
      softening width, the world extent, and the inverse-transform normalization — with the static
      offset and size assertions every layout carries — and add its `generateStructModule` call to
      `tools/wgsl_bundle.nim`. The attraction matrix is not a member; the kernel pass binds
      `SimParams` and reads the matrix already there. Verify: 4.1 passes and the generated
      `web/shaders/modules/lr_params.wgsl` appears
- [ ] 4.3 Create the four buffers at the `memory_layout` ceiling in `src/webgpu_init.nim` and add one
      exhaustive `case` entry each to `byteLengthFor` in `src/webgpu_compute.nim`. Verify: removing
      one entry turns the compile red, which is the whole point of that `case`
- [ ] 4.4 **Red first, then carry.** Assert in `tests/test_sim_registry.nim` that a three-dimensional
      dispatch size resolved through the one-integer path raises, the way `dsFieldWorkgroups` already
      does (`src/webgpu_compute.nim:866-869`). Then extend the frame walk in `src/webgpu_compute.nim`
      with the three-dimensional case, resolving the z extent against the live species count and the
      x extent against the live grid size. Verify: the raise fires and the walk dispatches `(x, y, z)`
- [ ] 4.5 Write `LrParams` once per frame in `src/webgpu_compute.nim` beside the other uniform writes,
      folding the substep's frame into the force scale the way `frameScaledFieldForce` does
      (`src/field_core.nim`), and mapping the reach to the inverse squared screening length so nothing
      in the shader divides. Verify: `just happen` builds
- [ ] 4.6 `just happen` builds and `just check` is green

## 5. The five passes

The chain reaches the GPU here. Each shader is written against the group 1 oracle, and the mirror is
held by review — change a shader and its oracle in the same diff or the pair drifts
(`docs/enforcement.md:58-64`).

- [ ] 5.1 Write `web/shaders/modules/lr_grid.wgsl`: the live-size indexing, the toroidal wrap, the
      row-major cell index over the live width, and the species stride, every one of them reading the
      uniform rather than a compile-time constant. Verify: `just shaders` bundles it with no
      unresolved placeholder
- [ ] 5.2 Write `web/shaders/src/lr-deposit.wgsl` — four CIC `atomicAdd`s of unit charge per particle
      in original index space, wrapped on the torus, mirroring the group 1 weights. Verify: the
      bundler resolves it, and a comment beside the charge states that the strength multiplies in the
      force pass alone
- [ ] 5.3 Write `web/shaders/src/lr-fft-rows.wgsl` and `web/shaders/src/lr-fft-cols.wgsl`, each with a
      forward and an inverse entry point, one line per workgroup of 256 invocations, `2N` complex
      values in workgroup storage, one barrier per stage, species on z. Verify: the bundler resolves
      both and the four entry points match the manifest keys from 3.6
- [ ] 5.4 Write `web/shaders/src/lr-kernel.wgsl` — one thread per bin holding the source spectra in
      registers while it writes every receiving species, out of place, with the kernel and the
      `1/(W·H)` normalization of design D6 folded into one multiply. Verify: the bundler resolves it
- [ ] 5.5 Write `web/shaders/src/lr-force.wgsl` — four bilinear samples one cell apart for the central
      difference, scaled by the species' potential and the frame-scaled strength, ending in two
      `atomicAdd`s into `velocityDeltaFixed`. Never a store: the frame cleared the buffer and three
      other passes write it. Verify: the bundler resolves it
- [ ] 5.6 Register all five in the binding manifest in `src/wgsl_lint.nim` and all five in the
      `StaticFiles` table in `src/main.nim` — unregistered means unserved means a failed fetch at
      pipeline init. Verify: `tests/test_wgsl_lint.nim` is green, the bundled set equalling the
      registered manifest
- [ ] 5.7 Add an `EXPECTED_BIND_GROUP_ENTRIES_*` constant per pipeline, a case per key in
      `getExpectedEntryCount`, and bind-group creation ending in `validateBindGroupEntryCount` in
      `src/webgpu_compute.nim`. Verify: `just happen` builds, and a deliberately wrong count in one
      constant is caught by that call rather than by the browser
- [ ] 5.8 `just happen` builds and `just check` is green

## 6. In-app verification, the remaining budget, and the records

6.1 needs a person only for the browser connection; every observation after it is the agent's.

- [ ] 6.1 Confirm the Browser MCP tools are present and connected. If they are not, ask the user to
      start Chrome and connect Browser MCP, and start nothing until they confirm — `./main` exits with
      code 0 when no browser attaches (CLAUDE.md, Build and test). Touches no file
- [ ] 6.2 **Agent procedure.** `just happen`, launch `./main` in the background, poll
      `http://127.0.0.1:8089` for 200, navigate the connected tab there, and settle a population at
      128 000 particles. Then: raise the long-range strength from zero and observe distant groups
      answering each other; sweep the reach from floor to ceiling and observe the influence widening
      with no jump; set a symmetric attraction matrix and observe no net drift, then an asymmetric one
      and observe drift; hold a short reach at full strength over a settled population and read the
      motion for lanes or steps spaced at the cell size, which is the grid-aligned artifact the
      softening exists to prevent. The observation that settles each is a screenshot pair before and
      after. A GPU validation error in the console from any of the five bind groups fails this task —
      that pair is unenforced across the two sides (`docs/enforcement.md:96`). Record the run in
      `scratchpad/long-range-mesh/in-app__<DD-MM-YY-HHmm>.md`. Kill the port 8089 listener
- [ ] 6.3 **The gate the spike left open.** During 6.2, read the long-range profiler slot at 128 000
      particles and at twelve species, and compare against the 1.0 ms allotment. The spike's 0.417 to
      0.450 ms covered the solve alone, so the figure here includes the deposit and force passes for
      the first time. Record it in `docs/perf-report.md` beside the settled 128k row (`:140`), stating
      the particle count, the species count, the live grid size, and the browser build — the spike's
      figure was taken on Chromium 152 against the record's Chromium 150, and this entry closes that
      boundary by measuring both in one build. Verify: the entry states every one of those conditions
- [ ] 6.4 If 6.3 exceeds the allotment, move the default grid index in `src/config_ranges.nim` to the
      declared 256 x 128 position and re-run 6.3, recording both figures. The selector already offers
      both sizes, so this is one constant and no structural change. Verify: the recorded entry names
      which size shipped and why
- [ ] 6.5 Update `docs/one-world.md`: `longRange` in the strengths table (`:19-24`, now five), the
      long-range density accumulator and its once-per-frame cadence in the delta-buffer section
      (`:158-186`), and a paragraph in "Adding a fifth coupling" (`:188`) restating it as a sixth and
      naming the chain rule — a coupling may own a chain of passes, and the chain is skippable when
      nothing outside it reads any intermediate product. Verify: the document names five strengths and
      the chain rule appears beside the single-pass one
- [ ] 6.6 Update `docs/enforcement.md`: the coupling-floor row from four floors to five (`:49`);
      `long_range_core.nim` in the reference-oracle table (`:58-77`) naming all five shaders; the new
      build-asserted guarantees (the `LrParams` offsets, the declared-size assertions, the density
      accumulator's overflow bound); the new test-held ones (the transform against a naive DFT, the
      isotropy bound, help coverage over the new group); and one landmine — **the long-range skip at
      zero is exact only while nothing outside the chain reads its buffers**, because a reader outside
      it would make the deposit and the solve world-intrinsic and the strength would no longer
      multiply everything the chain produces. Verify: every new guarantee names its tier and every
      tier below test-held names what would raise it
- [ ] 6.7 `just happen` builds and `just check` is green
