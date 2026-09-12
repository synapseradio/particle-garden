# Enforcement status

What each guarantee in this repository rests on. Every entry names its tier, and an entry below
test-held names what would raise it. Read this before crediting any "cannot" in a comment, a
commit message, or a spec.

## Tiers

| Tier | Meaning |
|---|---|
| Derived | One side is computed from the other, so nothing can disagree |
| Build-asserted | A static check fails the compile on disagreement |
| Test-held | A native test fails on disagreement, and `just check` runs it |
| Agent-checkable | An agent launches the app, drives it, and observes; nothing automated |
| Unenforced | Nothing detects a violation |

## Where authority lives

One home per fact.

| Fact | Home |
|---|---|
| Ranges and measured bounds | `src/config_ranges.nim` |
| Particle buffer layout | `src/memory_layout.nim` |
| Parameter contract | `src/ui/api/param_descriptor.nim` |
| Preset schema | `src/preset.nim` |
| What a frame dispatches | `src/sim_registry.nim` |
| Shader binding manifest | `src/wgsl_lint.nim` |
| Probe registry and context slices | `src/ui/api/response_probe.nim` |
| Slider travel mapping (the panel computes none) | `src/ui/api/slider_curve.nim` |
| Every mouse, touch, and key binding, as data | `src/ui/input/binding_table.nim` |
| Weather tours and their step ceilings | `src/climate_core.nim` |
| The self-moving view | `src/camera_drift.nim` |
| Per-capability requirements, each citing its gate | `openspec/specs/` |
| The inventory of facts stated at two sites, each with its tier | `src/agreements.nim`, explained in [agreements.md](agreements.md) |
| Shader sources and shared modules | `web/shaders/src/`, `web/shaders/modules/`, bundled by `tools/wgsl_bundle.nim` |
| Audio feature definitions, thresholds and windows | `src/ui/input/audio_core.nim` |

## Guarantees

| Guarantee | Tier | Held by | Raised by |
|---|---|---|---|
| A descriptor id names a field of its store's record, on the write path and the read path | Build-asserted | `fieldPairs` unrolling and static gates in `src/web_api.nim` | |
| Every routed id maps to one field | Test-held | `tests/test_param_descriptor.nim` | |
| Every slider is documented: group has a file, group id exists, descriptor named by its file, no file names a missing id | Test-held | `tests/test_help_content.nim`, ranging over the descriptor table | |
| Every toggle, selector, and button is documented | Unenforced | Convention; these are `gardenAPI` functions outside the descriptor table | The four relations ranging over served action and toggle ids too |
| The bundled shader set equals the registered binding manifest, and is non-empty | Test-held | `tests/test_wgsl_lint.nim`; `just check` bundles first so the sweep has a subject | |
| The compiler flag list in `justfile` equals the one in `particle_garden.nimble` | Test-held | `tests/test_build_flags.nim` | One file reading the other |
| Every coupling strength's range reaches zero, so each coupling turns off through its own slider | Build-asserted | A static loop over the five floors at the bottom of `src/config_ranges.nim`; crowding, which shapes the force law instead of gating a pass, is asserted beside it | |
| A body's GPU record and its params match the Nim layouts field for field | Build-asserted | `BodyLayout` and `BodyParamsLayout` ride the static offset sweep in `src/gpu_types.nim`, and both the shader structs and the Nim write indices are generated from them | |
| One workgroup covers the whole body table | Build-asserted | `static: assert MAX_BODIES <= PRODUCTION_WORKGROUPS.bodyIntegrate` in `src/shader_config.nim`, which is what makes `bodyIntegrate`'s `dsOne` dispatch correct | |
| A full crowd cannot overflow a body's force or torque accumulator | Build-asserted | Static assertions in `src/body_core.nim` relating `MAX_PARTICLES`, the largest contribution the ranges admit, the world's half-diagonal and the two fixed-point scales | |
| No reachable crowd drives a body unstable | Test-held | The sweep in `tests/test_body_core.nim` over the corners of the expressible space, against the ceiling the change caps and damping set | |
| The fastest particle cannot tunnel through an enclosing body | Test-held | `tests/test_body_core.nim` derives the band floor from the particle speed ceiling and the longest substep, and `config_ranges` takes `BODY_BAND_MIN` from it | |
| The bodies group is documented, like every other slider group | Test-held | `tests/test_help_content.nim` over `docs/help/35-bodies.md` and the seven descriptors | |
| A gesture cannot exist without appearing in the help reference | Derived | `help_content.bindingReferenceBody` renders the same `InputBindings` rows the handlers read | |
| `LrParamsLayout`'s field offsets and its written and allocated sizes | Build-asserted | Static offset and size assertions in `src/gpu_types.nim`, the same set every layout carries; `tools/wgsl_bundle.nim` generates `lr_params.wgsl` from that table | |
| The whole particle budget deposits into one mesh cell without wrapping an `i32` negative | Build-asserted | `static: doAssert MAX_PARTICLES * LR_DENSITY_SCALE < high(int32)` beside the constant in `src/long_range_core.nim`; exact because the deposit is unit charge and the strength multiplies in the force pass alone | |
| Every declared long-range grid size fits the allocation ceiling, and one of its lines fits WebGPU's guaranteed workgroup storage | Build-asserted | Static assertions in `src/config_ranges.nim` against `LR_GRID_MAX_W`/`LR_GRID_MAX_H`, and in `src/long_range_core.nim` against `LR_WORKGROUP_STORAGE_GUARANTEE` — the guarantee rather than this adapter's limit, which is twice it | |
| The long-range transform equals a discrete Fourier transform, and its round trip is the identity | Test-held | `tests/test_long_range_core.nim` against a naive O(N²) DFT written in the test file | |
| The mesh kernel answers to physical wavenumbers, so equal world distances along x and along y give equal potential on a grid whose cells are not square | Test-held | The isotropy test in `tests/test_long_range_core.nim`, the one that catches a kernel indexed by bin number | |
| WGSL struct modules match the Nim layout tables | Derived | `tools/wgsl_bundle.nim` generates every module from `src/gpu_types.nim`, whose offsets are static-asserted | |
| A shader constant equals its config value | Derived where it travels by `{{PLACEHOLDER}}` from `src/shader_config.nim` | The bundler fails on an unresolved placeholder | |
| The blast radius in `forces.wgsl` equals `shader_config.blastRangeSq` | Derived | The shader reads `{{TUNABLE_BLAST_RANGE_SQ}}` and `{{TUNABLE_BLAST_RANGE}}`, both emitted from the one field | |
| Every key `getPlaceholderMap` emits is read by a shader source | Test-held | `tests/test_agreements.nim`, enumerating the map against `web/shaders/src/` and `web/shaders/modules/` | |
| `GardenAPI` in `web-ui/src/garden-api.ts` declares every method `buildGardenApi` installs | Unenforced | Nothing relates the two: `tsc` only reddens for a method the panel actually calls, so a declaration for a boundary method no component calls — `igniteBody`, whose caller is the Nim-side canvas gesture — is documentation | A test relating the installed key set to the declared members, in both directions |
| Every audio feature is finite and in [0, 1], with silence reading zero | Test-held | `tests/test_audio_core.nim` | |
| The capture chain is created inside the listen gesture and released on stop | Unenforced | Review against `src/audio_input.nim` and the gate record under `scratchpad/audio-interface/` | |
| Audio is analysed before the frame's physics | Unenforced | Review of the loop in `src/app.nim` | |

## Reference oracles

GPU math the native suite cannot execute keeps a pure Nim mirror. Constants that reach the shader
by placeholder agree by construction. The expressions are held by review, which is unenforced:
change a shader and its mirror in the same diff, or the pair drifts. Each module's header names
the shader it mirrors, and this table restates those headers by hand. Raised by a test that
derives the table from the headers and compares.

| Mirror | Shader it is written against |
|---|---|
| `physics_core.nim` | `forces.wgsl` (force curve, toroidal wrapping, density) and `integrate.wgsl` (friction, speed cap) |
| `grid_core.nim` | `bin-count` / `prefix-sum-*` / `bin-scatter.wgsl` |
| `sph_core.nim` | `forces-sph.wgsl` (kernels, Tait pressure, XSPH) |
| `field_core.nim` | `rd-step.wgsl`, `field-seed.wgsl`, `field-deposit.wgsl`, and the frame-scaled force `field-force.wgsl` reads |
| `bloom_core.nim` | `blur.wgsl` (kernel weights substituted from here) and `tonemap_grade.wgsl` (ACES and grade steps, run by `tonemap.wgsl` and `field-composite.wgsl`) |
| `colormap_core.nim` | `colormap.wgsl`, and `fade.wgsl`'s field drift scale |
| `camera_core.nim` | `camera_transform.wgsl`, mirrored by `render`, `glow` and `fade` |
| `glow_core.nim` | `glow.wgsl` (halo radius, falloff, warmth, alpha integral) |
| `trail_core.nim` | `fade.wgsl` (per-frame decay), `render.wgsl`'s motion-blur taper, plus the trail-length mapping the renderer writes |
| `overlay_core.nim` | `overlay.wgsl` (ring and frame coverage) |
| `body_core.nim` | `body-force.wgsl` (the anisotropic signed distance, proximity, enclosure, and the reaction it accumulates) and `body-integrate.wgsl` (the semi-implicit rigid step, its change caps, the exponential damping and the torus wrap) |
| `long_range_core.nim` | all five mesh passes: `lr-deposit.wgsl` (cloud-in-cell weights, toroidal wrap, the density fixed point), `lr-fft-rows.wgsl` and `lr-fft-cols.wgsl` (the transform, measured against a naive DFT in the suite), `lr-kernel.wgsl` (wavenumbers, the Yukawa kernel, the matrix mix), `lr-force.wgsl` (bilinear sampling and the one-cell central difference) |

**Known drift in `sph_core` against `forces-sph.wgsl`.** The shader clamps the Tait density to
`restDensity * SPH_MAX_DENSITY_RATIO`; `flooredTaitPressure` applies only the floor, and its
docstring says the shader does the same. The shader fuses viscosity into the XSPH coefficient and
divides by the larger density; `xsphVelocityCorrection` bounds a coefficient of its own. The
pressure assembly has no oracle function and exists only inside `tests/test_sph_core.nim`. The
cause is structural: `SPH_MAX_DENSITY_RATIO` lives in `src/shader_config.nim`, downstream of
`sph_core`, so the oracle cannot import it. Raised by moving the constant home to `sph_core` and
mirroring the clamp.

## Two-sided agreements

A fact stated at two sites.

| Fact | Sites | Tier | Raised by |
|---|---|---|---|
| Species ceiling, preset copy | `memory_layout.MAX_SPECIES`, `preset.MAX_SPECIES` | Build-asserted (`doAssert` in `src/preset.nim`) | Stays: `preset` is a leaf that imports no other `src/` module |
| Chemistry stride | `field_core.SPECIES_CHEMISTRY_STRIDE`, `preset.CHEMISTRY_STRIDE` | Unenforced | A native test relating the two |
| Bind-group entry counts | `wgsl_lint.ExpectedShaderBindings`, `EXPECTED_BIND_GROUP_ENTRIES_*` in `webgpu_compute.nim` and `webgpu_render.nim` | Unenforced across the pair | One side derived from the other |
| State record field lists | `snapshotPreset`, `applyPresetImpl`, `createConfig`, and the three walkers in `preset.nim` | Unenforced for the three in JS-only modules; one round-trip test covers `preset.nim` | A pure module compiled on both backends, held by the round-trip |

## Landmines

Each is unenforced. Verify in a running app until its raising step lands.

| Landmine | What happens | Raised by |
|---|---|---|
| Render bind group resources | Entry counts and shader-side binding sets are checked; which resource lands at each binding is not. In `src/webgpu_render.nim` a binding's layout and its resource sit hundreds of lines apart inside one procedure | A table of binding index to resource kind that generates both layout and group |
| The bodies skip at zero is exact only while bodies are invisible | `acts(couplings.bodies)` drops both bodies passes at zero, including the body's own integrate, and that is exact because everything a body does reaches the world through forces the strength scales. Give a body any observable route the strength does not scale — draw it, let it deposit into the field, report its pose — and a frozen body stops being indistinguishable from a drifting one, which makes the integrate world-intrinsic and this guard wrong | Making the integrate intrinsic at the same time as making a body observable, or scaling the new route by the same strength |
| The long-range skip at zero | Skipping the six-dispatch chain at zero strength is exact only while nothing outside it reads its buffers. Give the mesh density, either spectrum, or the potential a reader elsewhere — a renderer, a probe, a second coupling — and the deposit and the solve become world-intrinsic: the strength stops multiplying everything the chain produces, and the world jumps as the slider leaves zero | A test that fails when any pass outside the chain binds `sbLrDensity`, `sbLrSpectrumA`, `sbLrSpectrumB` or `sbLrPotential` |
| Import order in `src/app.nim` | The JS backend hoists variables, so a misordered import fails at runtime. Never alphabetize it | |
| nimble exit codes | nimble exits 0 on task failure. Build through `just`, whose recipes call `nim` directly | |
| Silent stop | Device loss clears `isWebGPUAvailable`, which the frame guard in `src/app.nim` never reads, and no handler wraps the loop, so one throw or one lost device stops the world with nothing visible | A guard that reads the loss flag, and a handler that reinitializes or reports |
| Incremental shader rebuild | `PlaceholderSources` in `tools/wgsl_bundle.nim` omits `sph_core`, `overlay_core`, `trail_core`, and `glow_core`, all of which `shader_config.nim` imports, and the walk is direct-import only, so editing an unlisted constant ships the old value under a green build | Deriving the list from the import closure; `just shaders` on a clean tree meanwhile |

## Gates that cannot fail

| Gate | Why it passes vacuously | Raised by |
|---|---|---|
| `tests/test_config.nim` | Asserts against local copies of the defaults, so a change in `config.nim` leaves it green | Parsing the source, as `test_field_core` does for the world size |
| `tests/test_shader_manifest.nim`, the rd-step pair test | Leaves a looked-up spec at its zero value on a miss, so renaming both keys compares empty to empty | A found flag |
| `tools/wgsl_bundle.nim` | Prints a note and exits without bundling when the source directory is absent | Treating absence as failure |
| `tests/test_meta_vacuity.nim` | Guards filesystem-reading tests only; zero-value lookups, local-copy tests, and success on absent input have no detector | One detector per signature |

## Related

[engineering-principles.md](engineering-principles.md) holds the twelve articles this status
answers to. [one-world.md](one-world.md) holds the couplings model, [tests/README.md](../tests/README.md)
the test layout, and [web/shaders/README.md](../web/shaders/README.md) the GPU pipeline.
