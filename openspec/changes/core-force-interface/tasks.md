Conventions every task below uses:

- **In-app procedure (Claude in Chrome).**
  1. Load the Claude in Chrome tools in one ToolSearch call: `tabs_context_mcp`, `tabs_create_mcp`,
     `navigate`, `computer`, `read_page`, `find`, `javascript_tool` and `read_console_messages`. Call
     `tabs_context_mcp`. If the extension does not answer, ask the user to open Chrome and connect
     Claude in Chrome, and start nothing until they confirm.
  2. Run `just happen`, then `./main --serve` as a persistent background shell (the Bash tool's
     `run_in_background`), and confirm `http://127.0.0.1:8089` answers 200 before any browser call.
  3. Open a new tab at that URL with `tabs_create_mcp`. Never reuse a tab id from another session.
  4. Drive `window.gardenAPI` through `javascript_tool`, or through the panel's controls. Read
     `[gpu-profile]` lines with `read_console_messages` and the pattern `\[gpu-profile\]`, and GPU
     validation errors with the pattern `error|validation`. Trigger no alert, confirm or prompt dialog.
  5. Stop the server by killing the port's listener.

  Browser MCP (`mcp__browsermcp__*`) is not used. Never install Playwright or another browser driver.
  In-app runs use the user's display, which runs at about 143 Hz: frame factor ≈ 0.84 × time scale
  (0.42 at the shipped 0.5), and 30 only on frames held past the 0.05 s cap at time scale 5.
- **Gate seeds**: every constant derived from a run, and every behavioural gate, runs the three seeds
  42, 7 and 1001 at 128 000 particles, recorded in `scratchpad/core-force-interface/seeds.md`. A gate
  passes when the three-seed mean is at most its bound. A bound derived from a run is the run's mean
  plus the largest single seed's distance from it (`design.md` C5).
- **Records**: every measurement goes to `scratchpad/core-force-interface/`, and the constant it sets
  carries the value, conditions and margin beside it under the measured-bound rule.
- **Red first**: a new test fails on values against a stub or a today-convention oracle before its
  code lands, not on a missing symbol, unless the task says otherwise.
- **Checks**: `just happen` after every task. `just check` runs once, in 12.2.

## 1. Oracles, the unit, profiler slots and the declaration table (no behaviour change)

- [x] 1.1 **Red.** Create `tests/test_balance_core.nim` (new) with suite "Every Writer Answers In The Pair Unit", linked from `tests/test_all.nim`, and `src/balance_core.nim` (new) exporting `u0 = FRAME_DT_REFERENCE`, the `UnitFnId` enum (species, fluid, scent, long range, bodies, mouse, blast, deposit) and a stub `unitImpulse(id, cfg)` returning 0. The suite checks that one touching neighbour's repulsion at pair gain 1 over the reference frame is exactly `u0`, and, per id, sweeps that writer's oracle over a grid of configurations inside its ranges: no swept impulse exceeds `unitImpulse`, and the function's own configuration attains it within the oracle's tolerance. Verify it fails on values for every id against the stub.
- [x] 1.2 Fill every `unitImpulse` arm in `src/balance_core.nim` with an exhaustive `case` (design N1, C1 table): species from `src/physics_core.nim` with the ×4.0 recorded as the pair law's shape; fluid from `src/sph_core.nim` with `SPH_FORCE_SCALE` as its shape; scent at pattern scale `s` from `src/field_core.nim` through a new `worldUnitsPerCell()` there, which `patternDiameterWorld` also calls; long range in today's `cellArea` form from `src/long_range_core.nim` (group 6 replaces it); bodies from `src/body_core.nim` with `BODY_FORCE_CEILING` as its shape; mouse 300/120; blast `3000 · b / 120`; deposit in concentration per cell per field step. `src/balance_core.nim` imports the oracles and never `config_ranges`. Verify 1.1 passes, that `grep -n config_ranges src/balance_core.nim` is empty, and that evaluating the species arm with the attraction peak moved off the bump's maximum turns 1.1 red (mutation).
- [x] 1.3 **Red, then green.** Write the today-convention encode and decode oracles (design N3 step 1), each docstring naming the shader lines it mirrors: pair, mouse and blast encoded with `params.dt` and integrate's single-word decode, friction and soft cap in `src/physics_core.nim` (`web/shaders/src/forces.wgsl:297,377`, `web/shaders/src/integrate.wgsl:55-106`); SPH pressure × `dt` and blend × frame factor in `src/sph_core.nim` (`web/shaders/src/forces-sph.wgsl:266-280`); the long-range `frameFactor` multiply in `src/long_range_core.nim` (`src/webgpu_compute.nim:1125-1126`); the body `frames` multiply in `src/body_core.nim` (`web/shaders/src/body-force.wgsl:81`); `frameScaledFieldForce` stays in `src/field_core.nim`. First write suite "Today's Writers Each Scale By Their Own Time Factor" in `tests/test_physics.nim`: each oracle's integer at frame factor 2 and 30 is that factor times its integer at 1, within one quantum per conversion. Verify it fails against a stub oracle that omits the factor, then passes.
- [x] 1.4 **Red.** Extend suite "Profiler Slot Constants" in `tests/test_sim_registry.nim`. Walking every coupling mask, each of `forces`, `forcesSph`, `fieldForce`, `lrForce`, `bodyForce` and `fieldDeposit` must sit in a node whose slot is not `PROFILER_SLOT_NONE` and that holds no other coupling's writer. Verify it fails today and names the keys: `fieldForce` and `lrForce` carry `PROFILER_SLOT_NONE` (`src/sim_registry.nim:467-480`), `forcesSph` shares the Physics node (`:389-395`), and `fieldDeposit` shares the Field node (`:424-460`).
- [x] 1.5 Create `src/profiler_slots.nim` (new, pure) holding every slot constant, with FLUID 9, SCENT 10, LR_FORCE 11 and DEPOSIT 12 added. `src/gpu_profiler.nim` (`numPasses = 13`) and `src/sim_registry.nim` import it, and the mirrored constants at `src/sim_registry.nim:251-280` are deleted. In `src/sim_registry.nim`, `forcesSph` moves to its own per-substep "Fluid" node and `fieldDeposit` to its own once-per-frame "Deposit" node ahead of the Field node, and Field Force and Long Range Force get slots 10 and 11. `src/app.nim` names every slot in the `[gpu-profile]` line and adds `coupled=`, which is `physics=` plus every coupling slot, while `physics=` keeps its meaning of sweep plus integrate (`src/app.nim:298-310`). Verify 1.4 passes, "Delta Buffers Have One Reset Owner" and "The Field Chemistry Runs Once Per Rendered Frame" stay green, and `just happen` compiles `gpu_profiler` against the shared module.
- [x] 1.6 **Red.** In `tests/test_sim_registry.nim` add the suites "Every Writer Belongs To One Coupling" (walks the frame descriptions for every coupling mask; each velocity-delta or field writer maps to one declaration or is the neighbour sweep), "Bounds Read Only Declared Parameters" (each registered `ParamCeilingId`'s inputs equal the `boundsRead` of its coupling's declaration) and "Every Size Names Its Space" (every length-valued descriptor in a declaration or in `RENDER_SIZES` carries exactly one `SizeSpace`). In `tests/test_dormancy.nim`, check that each declaration's dormancy predicate is registered, reads only that coupling's strength, and is cited by every descriptor in its `ownParams`. Declare the `COUPLINGS` table in `src/sim_registry.nim` with empty `passes`. Verify the first suite fails naming each unmapped writer, and that the dormancy check fails on the unregistered `bodiesOff`.
- [x] 1.7 Fill `COUPLINGS` and `RENDER_SIZES` in `src/sim_registry.nim` per design N1 (strength, unit id, passes with cadence, slot and cost scaling, dormancy, bounds read, own params, sizes, raises-crowd). Add the `bodiesOff` predicate to `src/ui/api/dormancy.nim` and cite it from the body-only descriptors in `src/ui/api/param_descriptor.nim`. Say in `docs/help/35-bodies.md` that the body sliders dim with Bodies at zero. Verify 1.6 passes, `tests/test_help_content.nim` passes, and adding a member to `Coupling` without a table entry fails the build (mutation).
- [x] 1.8 **Baseline for 2.6.** Taken 2026-09-19 on a display running about 143 Hz, so shipped defaults ran at frame factor ≈ 0.42, not 1. The user chose to keep this baseline, and 2.6 repeats it on the same display at shipped defaults (`scratchpad/core-force-interface/baseline__19-09-26-2245.md`). Run the in-app procedure at shipped defaults on that display. Settle for 60 s, then record a screenshot and the last four `[gpu-profile]` lines' `physics=` and `coupled=` in `scratchpad/core-force-interface/baseline__<DD-MM-YY-HHmm>.md`. The settling observation is a screenshot and four readings on file.
- [x] 1.9 Group 1 closes with `just happen` and `just check` green.

## 2. One time site and the two velocity words

- [x] 2.1 **Red.** Add suite "Only Integrate Reads The Frame Factor" to `tests/test_sim_registry.nim`. It reads the writer shader sources (`forces`, `forces-sph`, `field-force`, `lr-force`, `body-force`) for `dt`, `frameFactor` and `frames`, and checks the CPU parameter writes, holding that the frame factor reaches only the particle integrate and `bodyIntegrate` (exempt by name, design N3). Verify it fails today and names each coupling: `forces` reads `params.dt`, `forcesSph` its blend factor, `fieldForce` and `lrForce` the CPU `frameFactor` (`src/webgpu_compute.nim:1064-1066,1125-1126`), and `bodyForce` `frames`.
- [x] 2.2 **Guard.** Write suite "Today's Low Bits Move By Less Than The Frame Factor" in `tests/test_physics.nim` (design C10 test 4b). At frame factors 1, 2 and 30, each writer's per-reference-frame encode followed by the integrate decode differs from today's convention by fewer than `max(1, ff)` quanta, so it is bit-identical at ff 1. The suite compares against a copy of the 1.3 today-convention oracles kept test-local. Verify it passes before the switch and turns red when one writer's new-convention oracle keeps its frame-factor multiply (mutation).
- [x] 2.3 **The switch, in one commit** (design N3 step 2):
  - `web/shaders/src/integrate.wgsl` multiplies the decoded delta by `frameFactor` once. `INTEG_PAD1` becomes `frameFactor` and `SIM_DT` becomes a pad (`src/gpu_types.nim:780-788`, written at `src/webgpu_compute.nim:1036-1041`).
  - `web/shaders/src/forces.wgsl` uses `FRAME_DT_REFERENCE` for the pair, mouse and blast, through a `src/shader_config.nim` placeholder.
  - `web/shaders/src/forces-sph.wgsl` multiplies pressure by `FRAME_DT_REFERENCE`, and its blend drops the frame factor.
  - `src/webgpu_compute.nim` drops `frameScaledFieldForce` and the long-range `frameFactor`, and `frameScaledFieldForce` leaves `src/field_core.nim`.
  - `web/shaders/src/body-force.wgsl` drops `frames`, and `web/shaders/src/body-integrate.wgsl` multiplies the decoded reaction by `frames` at the decode.
  - The body accumulator's assertion at `src/body_core.nim:195-199` drops `BODY_LARGEST_FRAME_FACTOR`, with `BODY_MAX_FORCE_PER_PARTICLE = 2 · BODY_FORCE_CEILING · BODY_STRENGTH_CEILING`. The constant stays until 3.3, because the body stability sweep still steps body-integrate at the largest frame through it (`tests/test_body_core.nim:916`).
  - The oracles move to the new convention, and 1.3's suite is deleted.
  - `tests/test_field_core.nim` "The Field Force Answers To The Frame" (`:1688`) and `tests/test_sph_core.nim` "XSPH Smoothing Answers To The Frame" (`:818`) are rewritten to hold that no writer carries a time factor.

  Verify that 2.1 passes, 2.2 stays green, and `just happen` builds.
- [x] 2.4 **Red, then the coarse word** (design C8, N3 step 3):
  - **Red.** Write suite "A Full Crowd Decodes To Its Impulse" in `tests/test_physics.nim` (C10 test 11): a full crowd at each writer's maxima is encoded through its oracle and decoded through the integrate oracle at frame factors 1, 2 and 30. Add the fine-word and coarse-word full-crowd static assertions at the bottom of `src/config_ranges.nim`, each term naming its constants. Extend "Delta Buffers Have One Reset Owner" in `tests/test_sim_registry.nim` so both velocity words are cleared before all five writer keys. Verify each goes red: the single-word assertion fails the build because SPH is 1 335× the span, the suite fails on SPH's wrapped per-pair adds, and the registry suite fails because nothing clears a coarse word.
  - **Green.** Add the coarse velocity buffer to `src/sim_registry.nim`'s buffers and its per-substep clear, allocate it in `src/webgpu_compute.nim`, and bind it in `web/shaders/src/forces.wgsl` (the eighth storage binding), `web/shaders/src/forces-sph.wgsl` and `web/shaders/src/integrate.wgsl`. `forces-sph` splits each integer into `q >> k` and `q & (2^k − 1)`. Integrate decodes both words. `k` reaches `web/shaders/modules/fixed_point.wgsl` by placeholder, and `src/wgsl_lint.nim`'s `ExpectedShaderBindings` gains the entries. Record in `src/config_ranges.nim`: `k = 12`, SPH's 5 467 coarse units, `q_max = 11 310` and the static assertion `g_fluid ≤ 1`. Scent and long range are budgeted at their live range maxima until 7.5 re-budgets them at `F_c`. If either exceeds the 7 251 velocity per reference frame left in the fine word, `k` becomes 11.
  - Verify the three go green, and that replacing the split's `>>` by a division (mutation) turns the suite red. No range is narrowed.
- [x] 2.5 Correct the header of `web/shaders/modules/fixed_point.wgsl`: its "far more range than a per-frame impulse ever needs" becomes the per-reference-frame convention, the two words and the assertions that hold them (N9.17). Correct the header of `web/shaders/src/forces-sph.wgsl`, whose claim of integrate's 0.7 smoothing of the fluid density `web/shaders/src/integrate.wgsl:76-85` contradicts. The `sbVelocityDelta` doc at `src/sim_registry.nim:124-130` lists five writers and both words (N9.3). In `docs/one-world.md:166-169`, "Four passes" becomes the five writers into two words (N9.2). Verify `just happen` green, and read the `sbVelocityDelta` doc against the writer keys in "Delta Buffers Have One Reset Owner" (the gpu-frame-registry agent check).
- [x] 2.6 **In-app comparison at shipped defaults.** On the user's display this runs at about 143 Hz, frame factor ≈ 0.42, matching 1.8's baseline. There the switch moves the low bits by less than one quantum; it is not the frame-factor-1 identity. Run the in-app procedure at shipped defaults on that display, settle 60 s, and read the same four `[gpu-profile]` lines as 1.8. The observation that settles it is no visible change in the settled look against 1.8's screenshot, and a `physics=` difference no larger than the coarse word's added cost. Record it in `scratchpad/core-force-interface/in-app-ff1__<DD-MM-YY-HHmm>.md`. A difference in look returns the switch to the oracles before group 3 starts. Run seeded at `?seed=1` (`src/app.nim:357-364`), which fixes the attraction matrix and the initial particle state, so both sides settle the same world: `scratchpad/core-force-interface/in-app-ff1-seeded__20-09-26-1241.md`, with the two frames beside it. The look matches and `physics=` differs by 0.017 ms per frame over 18 matched samples, an order of magnitude below the within-run spread. The DevTools console check is the user's and blocks nothing.
- [x] 2.7 Group 2 closes with `just happen` and `just check` green.

## 3. The integrator owns the substep count

- [x] 3.1 **Red.** Write suite "Substeps Follow The Tightest Coupling" in `tests/test_sim_registry.nim` over a stub `substepPlan` that returns count 1. It holds design N4's worked values:
  - shipped settings (band 120, Max Velocity 50, ff 1, fluid off) give `n = 1`
  - stiffness 40 at `h` 50 and ff 1 gives 3
  - ff 10 with a live body gives `n_T = 5`, so the frame runs 3 at `effMaxVelocity` 36
  - ff 30 gives 3
  - the band floor 25 at ff 1 and Max Velocity 50 gives 2
  - Bodies above 0 with no live body declares no length
  - a fluid request past `SUBSTEPS_MAX` runs 3 at `effStiffness` with the stored value unchanged

  Verify it fails on values against the stub.
- [x] 3.2 **Red.** Four more failing tests:
  - Extend "Post-Step Speed Mirror" in `tests/test_physics.nim`: the cap is per reference frame (today's curve applied to `speed / ff_sub`, rescaled by `ff_sub`), per-step travel is at most `maxVelocity · ff_sub`, and the result is bit-identical at `ff_sub = 1`. It fails today because the per-step cap clips travel at `maxVelocity`.
  - Rewrite "An Enclosing Body Cannot Be Tunnelled" (`tests/test_body_core.nim:951`) to step at `substepPlan`'s count with the per-step travel model. It fails against the stub, because at band 25, Max Velocity 50 and ff 1 one step carries a particle 50.
  - Add suite "The Fluid Declares The Substeps Its Stiffness Needs" to `tests/test_sph_core.nim`: at every corner of the input box the declared count is the smallest whose ceiling holds the stiffness, and the harness comes to rest there.
  - In `tests/test_param_descriptor.nim`, "Descriptor Table Covers The Full Tunable Inventory" drops `sphSubsteps` from the id set, and "A Derived Bound Cites A Registered Ceiling" uses a box with no substep axis. Both fail while the descriptor and `CeilingInputs.sphSubsteps` exist.
- [x] 3.3 Implement `func substepPlan*(ff: float; live: LiveValues): SubstepPlan` in `src/sim_registry.nim` (N1, N4). `SubstepNeedId` and the `substepNeed` field already sit on every declaration, landed by 1.7 in `f483b5d` (`src/sim_registry.nim:529-534,551`), so 3.3 reads them rather than adding them. In `src/config_ranges.nim`, `SUBSTEPS_MAX = 3` replaces `SPH_MAX_SUBSTEPS` (`src/sph_core.nim:34`), with the per-extra-substep cost at 128k beside it: 1.56 ms from the 30 s run and 7.95 ms from the 150 s run, a lower bound (`docs/perf-report.md:83-84`). `FF_STABLE = 12` goes in marked provisional until 4.5. `src/webgpu_compute.nim:984-988` becomes the plan, writing `frameFactor = ff / count`, the effective Max Velocity into the integrate params and the effective stiffness into the SPH params, with `bodyLive` from `liveSlots` (`src/body_core.nim:494`). The per-reference-frame cap goes in `web/shaders/src/integrate.wgsl` and its oracle in `src/physics_core.nim`. `BODY_BAND_MIN = 25.0` becomes a stated literal in `src/config_ranges.nim`, and `BODY_BAND_FLOOR`, `BODY_LARGEST_SUBSTEP_DT`, `BODY_LARGEST_FRAME_FACTOR` and the tests pinning them leave `src/body_core.nim` and `tests/test_body_core.nim`. Verify 3.1 and the first three parts of 3.2 pass.
- [x] 3.4 Remove the Substeps slider:
  - the descriptor (`src/ui/api/param_descriptor.nim:598-599`)
  - `CeilingInputs.sphSubsteps` (`:141`), where `ceilingInputs` fills it (`:239`), where `evaluateCeiling` reads it (`:252`), the `ceilingInputBox` axis (`:278,283`) and `minimumCeiling`'s corner (`:300`); the reason text (`:263-269`) and the Stiffness hint name the interaction radius, fluid radius and time scale. The ceiling is then evaluated at `SUBSTEPS_MAX` throughout, which is the count the plan serves (`src/sim_registry.nim:763`), so `minimumCeiling` rises — that rise is what 3.2's three red tests in `tests/test_param_descriptor.nim` expect.
  - the state field in `src/ui/state/simulation_state.nim:58,160` and `src/config.nim:64,189`
  - the preset field and its read and write (`src/preset.nim:135,268,462-463,821`); an old file's key is then left unread
  - `SPH_SUBSTEPS_MIN/MAX` and their assertion (`src/config_ranges.nim:277-278,705`). `SPH_SUBSTEPS_MAX` is already an alias of `SUBSTEPS_MAX`, landed by 3.3, so every remaining reader takes `SUBSTEPS_MAX` directly.
  - `sphSubsteps` in the exemption list at `tests/test_response_probe.nim:84`. Its `PreCalibrationTable` (`:189-249`) is a frozen measurement record, so principle 12 has it annotated rather than rewritten: the `sphSubsteps` FAIL row and the prose naming its exemption both stay, under a note saying the slider is gone. Then every reference in `tests/test_sph_core.nim` (`:27-28,609`), `tests/test_sim_config.nim` (`:57`), `tests/test_preset.nim` (`:194,731-747,1020-1042`), `tests/test_config.nim` (`:34,107`), `tests/test_sim_registry.nim` (`:749,772-773`) and `tests/test_param_descriptor.nim` (`:214,259,321,833-882`)

  Then fix the docs. `docs/help/30-fluid.md` loses the Substeps line and each Interacts line naming Substeps (`:15`, `:29`, `:36`), and its stiffness line names Interaction Radius, fluid radius and time scale (N9.7). `docs/slider-interactions.md` edges 38, 39 and 40 (`:154-156`) and the Body Reach floor edge 10 (`:126`) are rewired to the integrator's count, and so is every other place that file makes the count a fluid setting: the `sphSubsteps` row in the slider table (`:40`), `fluidStrength`'s "turns substeps on" (`:35`), the substep-loop line `clamp(sphSubsteps,1,3)` only when `fluidStrength ≠ 0` (`:90-92`), the edge index row (`:238`), the `fluid -->|substep count|` arrow in the diagram (`:273`), the open-problem entries naming Substeps and `ceilingReason` (`:454`, `:476-477`), and the two forward-looking lines that name this removal as pending (`:490`, `:495`). Verify 3.2's last part passes, `tests/test_help_content.nim` passes, and a read of the three strings finds the ceiling's three inputs and no substep control (the sph-scale agent check).
- [x] 3.5 Amend the other changes' artifacts that name the removed floor and slider:
  - `openspec/changes/parametric-bodies/design.md:585-588` (D13): the band floor is the stated 25.0, and the integrator's travel count holds a particle inside it (N4, N10).
  - `openspec/changes/calibrate-shipped-defaults/design.md:173`: fixture F's `sphSubsteps` is dropped, because the slider no longer exists.

  Verify `openspec validate parametric-bodies --strict` and `openspec validate calibrate-shipped-defaults --strict` pass.
- [x] 3.6 Group 3 closes with `just happen` and `just check` green.

## 4. World pressure and gates G1.1–G1.5

- [x] 4.1 **Red.** Add three suites to `tests/test_physics.nim`, each over a stub pressure oracle in `src/physics_core.nim` that returns zero:
  - "Pressure Past The Onset" (world-pressure: zero at and below the onset, strictly increasing to `q_max`, constant past it; per-component integers non-decreasing; the two particles' integers exactly opposite, so each sum over a sweep is zero; unchanged by Force Strength, matrix entry, crowding, friction and relative velocity)
  - "The Species Term Is Zero At Strength Zero"
  - "The Species Term Is Untouched Below The Onset", at pair gain × strength 0.7, 1, 2.5 and 5 (new Force Strength 0.14, 0.2, 0.5 and 1, C10 test 4) and frame factor 1

  Verify each goes red. The first two fail on values against the stub. "Pressure Past The Onset" also turns red under each of a per-component saturation, a `fMul` factor and a Tait law (mutations). The third turns red when the term is folded into `forceMultiplier * invDistance` (mutation).
- [x] 4.2 Write the pressure oracle in `src/physics_core.nim` (C4). In `src/balance_core.nim` add:
  - the uniform crowd density `N·π·R²/(3A)` — already there as `meanCrowdDensity` (`src/balance_core.nim:78`), so this bullet is read rather than written
  - the contact floor from the pair-law shape, reading `CROWD_PACKING_CONSTANT` moved as it stands from `src/physics_core.nim:157-162`
  - the onset `max(x_on·ρ̄, ρ_floor)`
  - the `ufWorldPressure` arm `min(K·2φ/120, q_max)`

  The binned stepped oracle world with `parametric-bodies` D16 bodies moves to 4.3, which holds its
  only readers. 4.1 writes no red against it, and 4.3's two suites state the bodies, particle counts
  and frame holds it has to support, so building it here would fix an interface before the tests
  that use it exist.

  Delete the density-ceiling block at `src/physics_core.nim:116-231` (header at `:116-118`, `densityCeiling` at `:203`, ending before `calculateForceMagnitude` at `:233`) and suite "The Density Ceiling" at `tests/test_physics.nim:198-249`. Rewrite the crowding-ceiling comments at `src/config_ranges.nim:41-45` (under `FORCE_STRENGTH_MIN`, `:40`) and `:48-55` (under `CROWDING_STRENGTH_MIN`, `:47`, and `CROWDING_STRENGTH_MAX`, `:51`) (N9.9, C9) to say that crowding shapes texture and bounds no compression. Verify 4.1 passes, and that 1.1 sweeps the pressure arm.
- [x] 4.3 **Simplify the calibration suites.** The binned oracle world and its suites exist (`src/balance_core.nim`, `tests/test_balance_core.nim:472-860`). In `tests/test_balance_core.nim`:
  - replace `CALIBRATION_SEEDS` and `HELD_OUT_SEEDS` with `GATE_SEEDS = [42, 7, 1001]`, delete `boundMargin`, and have every gate compare its three-seed mean with its bound
  - run every arm at 128 000 particles under `calibrateBalance`; the 16 000-particle arms and the `calibrateBalance128k` define go
  - "Compression Is Not Remembered" holds the mean ratio at most 1, and `RELAXATION_BOUND_16K` goes

  In `justfile`, delete `calibrate-balance-128k` and restate the comment above `calibrate-balance` for three seeds at 128 000. Rewrite `scratchpad/core-force-interface/seeds.md` to the three seeds. Verify `nim c {{native_flags}} -d:calibrateBalance tests/test_balance_core.nim` compiles, `just test`'s output names none of the calibration suites, and `grep -rn 'calibrateBalance128k\|HELD_OUT_SEEDS\|CALIBRATION_SEEDS\|boundMargin\|RELAXATION_BOUND_16K' tests justfile` is empty.
- [x] 4.4 **Gate G1.1, the onset; it gates 4.7.** Add one reporting arm under `calibrateBalance` that asserts nothing. On the gate seeds at 128 000 particles and radius 50, polynomial model, one and four species, no coupling but the species force, it prints the p99.9 of `x` at the end of the window, the floor at the preset `repulsionEnd`, and the band's lower edge. Record them in `scratchpad/core-force-interface/g1-onset__<DD-MM-YY-HHmm>.md`, stating that other counts, radii, species counts and the exponential model are unmeasured. `x_on = 6.3` is the user's placement and is not derived from this run: the record states which settles it lies between (below every one-species settle, above every four-species diagonal-only settle).
- [ ] 4.5 **Gates G1.2 and G1.5, stiffness and `ff_stable`; they gate 4.7.** On the gate seeds at 128 000 particles, radius 50, one self-attracting species, `FRICTION_MIN` and no viscosity:
  - measure `L` at `K = 540` and record `B_L`; record that `K = 1728`'s `L` exceeds it
  - at 540 and shipped friction, re-bisect `ff_stable` with 3.3's per-reference-frame cap (design Risks), then run the jittered arms through the substep rule at that `ff_stable`

  A jittered arm warmer than frame factor 1 returns the trigger's hysteresis to the design, and 4.7 waits. Record in `scratchpad/core-force-interface/g1-stiffness__<DD-MM-YY-HHmm>.md`.
- [x] 4.6 **Gate G1.3, the stacked hold; it gates 4.7.** At the recorded `x_on`, `K` and `q_max`, run the 128 000-particle stacked hold on the gate seeds, with its stiffness-zero control bounded to 100 held frames. Record the after-release neighbour ratios, and the margin the spec's far-world scenario names: the far crowd's mean speed under the hold over the same seed's no-body run. A held peak that reaches the control's returns the design, and 4.7 waits.
- [ ] 4.7 Record `X_ON` (6.3, the user's placement, with the settles G1.1 records on either side of it), `K = 540`, `B_L` and `FF_STABLE` (replacing 3.3's provisional value) in `src/config_ranges.nim`, each with one or two lines of conditions. Beside `FF_STABLE`, record that friction acts per step, the condition it was measured under. Replace the provisional `FAR_SPEED_MARGIN` and `SETTLE_BOUND` (`B_L`) in `tests/test_balance_core.nim` with the measured values, each reading the owner in `src/config_ranges.nim` where one holds it. Verify `just happen` green.
- [ ] 4.8 **Red, then wire the pressure** (design N3 step 5, C3):
  - **Red.** Add a uniform-producer check to `tests/test_sim_registry.nim`: the onset the frame writes is `max(x_on · ρ̄, ρ_floor)`, composed from `src/balance_core.nim`'s two density functions. It fails first. The producer sits on `src/sim_registry.nim`, not in `src/webgpu_compute.nim`, which opens on `std/jsffi` and so no native test can import.
  - **Green.** `src/webgpu_compute.nim` composes the onset once per frame from the live count, radius, world area and pair-law shape, and writes it into the sim params as one uniform (`src/gpu_types.nim`), the shape `physics_core.pairImpulse` reads an onset in, so `x_on` never crosses the bridge. `K`, `q_max` and the word constants reach `web/shaders/src/forces.wgsl` by placeholders in `src/shader_config.nim`, and any module those placeholders draw on joins `PlaceholderSources` in `tools/wgsl_bundle.nim`. The term is hoisted beside `attenuationOnThis`, formed apart from the species expression, and split across the two words.
  - The red and green landed in `ed2f265`: `pressureOnset` at `src/sim_registry.nim:793`, written at `src/webgpu_compute.nim:1055`. What remains runs after 4.7: verify the check passes and `just calibrate-balance` is green at the recorded constants.
- [ ] 4.9 **Gate G1.4, the pressure's in-app cost; the group cannot close before it.** Run the in-app procedure at `MAX_PARTICLES` and the shipped radius. Read `physics=` and `coupled=` on:
  - a settled world with the coarse word bound and unbound
  - the term at `K = 0` (a local build) and at 540
  - a uniform world at two radii
  - a world settled with the term, over a window long enough that its last four readings stop rising

  From these, record the per-neighbour cost, the word's cost, the term's added cost, the settled headroom and the allotment it gives. The working figure until then is 10.57 ms (`docs/perf-report.md:132-147`). Then read `physics=` and the frame time at time scale 0.5 and 5 on the 143 Hz display (frame factor ≈ 0.42 and 4.2), and with frames held past the 0.05 s cap at time scale 5 (frame factor 30, 3 substeps). Record the added cost per substep against the allotment, and whether a capped frame recovers when its load goes.
  - Record in `scratchpad/core-force-interface/g1-cost__<DD-MM-YY-HHmm>.md` and `docs/perf-report.md`.
  - Correct `src/config_ranges.nim:110-125`'s "settled 128k headroom of 3.75 ms" to cite `w1-128k`'s 11.65 ms as the working figure and a lower bound, with 3.75 ms as the 150 s run still climbing (N9.15).
  - A cost past the allotment goes back to the user without narrowing the time-scale range.
- [ ] 4.10 Help and docs for the pressure:
  - `docs/help/12-species.md:11-12`: "particles drift through each other" becomes that below the onset they still pass through each other, while crowds above it push apart (N9.8).
  - The crowding line becomes "Crowding shapes clump texture, and the pressure is what bounds collapse".
  - `docs/one-world.md`: the pressure is part of the pair law, fixed and local.
  - `docs/slider-interactions.md`: edges 27 and 30 are rewired.

  Verify `tests/test_help_content.nim` passes.
- [x] 4.12 Amend the other changes' artifacts that waited on `coupling-balance`'s pressure:
  - `openspec/changes/parametric-bodies/tasks.md:384,396`: 9.2 and 9.3 wait on `core-force-interface` 12.1, not on `coupling-balance`.
  - `openspec/changes/parametric-bodies/design.md` gains the findings from design C6 (held-world heat) and design Risks (a body's own motion is not in the travel count).
  - `openspec/changes/calibrate-shipped-defaults/design.md:110-133` and `tasks.md:35-41,51-83`: fixture C becomes a world whose crowd rises past the onset at crowding 0, with its validity gate and red step 2.5 to match. `c_hold` is removed, so crowding is calibrated by `c_soften` alone, and group 3 waits on `core-force-interface` (C12).

  Verify `openspec validate parametric-bodies --strict` and `openspec validate calibrate-shipped-defaults --strict` pass.

## 5. The field reaches particles only as force

- [x] 5.1 **Red.** Four failing checks:
  - Suite "No Render Shader Reads The Field" in `tests/test_wgsl_lint.nim`. It reads the shader names `src/webgpu_render.nim` embeds from its `staticRead` lines, and holds that none of those sources imports `field_grid` or `colormap` or names `fieldTexture`, and that `src/webgpu_render.nim` names neither `activeFieldView` nor `fieldSampledView`. It fails today on `render`, `fade`, `tonemap` and `field-composite`, and on the view names.
  - `tests/test_param_descriptor.nim`'s id set drops `fieldOpacity`.
  - `tests/test_response_probe.nim`'s `MustPass` swaps `fieldOpacity` for `rdFieldForce`, per control-legibility.
  - `tests/test_preset.nim`: a previous-version preset carrying `colormapIndex` and `fieldOpacity` applies without error, and neither value reaches the decoded preset.

  Verify each fails for its stated reason.
- [x] 5.2 Remove every visual path from the field (design N6):
  - **Delete** `web/shaders/src/field-composite.wgsl`, `web/shaders/modules/colormap.wgsl`, `src/colormap_core.nim`, `tests/test_colormap_core.nim` (and its import in `tests/test_all.nim`) and `docs/help/41-rd-field.md`.
  - **Shaders.** Remove the field reads in `web/shaders/src/render.wgsl:188-194`, `web/shaders/src/fade.wgsl:84-96` and `web/shaders/src/tonemap.wgsl:74-86`, and the field bindings from the render, fade and tonemap layouts. Glow keeps its camera at binding 4.
  - **Struct members become pads** in `src/gpu_types.nim`: `RenderParams.fieldOpacity` and `colormapIndex`, `FadeParams.fieldDriftScale`, and `TonemapParams.colormapIndex` and `fieldOpacity`.
  - **Nim.** Remove:
    - `FIELD_LIGHT_STRENGTH` and `FIELD_DRIFT_SCALE` from `src/shader_config.nim`
    - the field-composite pipeline, layout, bind group and present step, and every field view, from `src/webgpu_render.nim`
    - the field entries from `src/wgsl_lint.nim`'s `ExpectedShaderBindings`
    - `setColormapImpl`, the preset capture and apply, the colormap catalog and the `colormaps`/`getColormap` accessors from `src/web_api.nim`
    - the `rd-field` group, the `fieldOpacity` descriptor and `fieldUnlit` from `src/ui/api/param_descriptor.nim` and `src/ui/api/dormancy.nim`
    - `fieldOpacityProbe` from `src/ui/api/response_probe.nim`
    - the `colormap_core` entry from `tools/wgsl_bundle.nim:207`
    - the fields in `src/config.nim` and `src/ui/state/render_state.nim`
    - the preset fields at `src/preset.nim:170-171,320,323,536-539,850-851`
  - **Panel.** Remove the colormap and `rd-field` uses in `web-ui/src/components/Panel.tsx:274-289`, `web-ui/src/state.ts`, `web-ui/src/garden-api.ts:116,363-365`, `web-ui/test/state.test.ts:117-119` and `web-ui/test/param-groups.test.ts`.
  - **Comment.** Drop the field-composite remark at `src/main.nim:48-49`.

  Verify 5.1 passes, "The Bundled Shaders Declare Their Registered Bindings" and `tests/test_gpu_types.nim` pass, `just test-ui` passes, and `just happen` fails while any importer of `colormap_core` remains.
- [x] 5.3 Update the docs for the removal:
  - `docs/help/52-bloom.md:18,21,24`: the Field Opacity mentions go, and the bloom-off dimming is now true (N9.4).
  - `docs/slider-interactions.md`: edges 53–58 and the Field Opacity and Colormap nodes go.
  - `docs/one-world.md`, `docs/enforcement.md` (the `colormap_core` oracle row, and `field-composite` in the `bloom_core` row), `tests/README.md` (the `test_colormap_core` rows and oracle lists) and `web/shaders/README.md` lose their field-composite and colormap lines.
  - Regenerate `docs/control-legibility-report.md` through suite "The Measured Table Is The Deliverable".

  Verify `tests/test_help_content.nim` and `tests/test_response_probe.nim` pass.

## 6. The long-range pull in the pair unit

- [x] 6.1 **Red.** Add three suites to `tests/test_long_range_core.nim`, each with its tolerance and measured source beside it:
  - "The Pull Does Not Depend On Mesh Size": every size in `LR_GRID_SIZES`, sampled 240 and 600 from the clump's centre along +x and +y, clump placed by seeds 42/7/1001, within the gate bounds per direction, 0.1977% (+x) and 0.2607% (+y) at 240 and 0.1063% and 0.1258% at 600 (design C2)
  - "The Pull Is The Pair Unit Spread By The Green's Function": reach `LONG_RANGE_REACH_MAX`, sampled 240 from the centre along +x and +y on every size, same seeds, radii 10, 50 and 150, within the gate bounds per direction, 0.7466% (+x) and 4.320% (+y) (design C1)
  - "One Long-Range Full Effect Holds At Every Radius": `F_LR`'s derivation in `src/balance_core.nim` returns one value at radii 10, 50 and 150

  Verify all three fail on today's code: the 4.006–4.010 mesh ratio, the `cellArea` factor, and a full effect moving with the radius.
- [x] 6.2 Add a `long_range_core` force-scale function to `src/long_range_core.nim`: `U(R) = u0 · R² · (a + R) / a²` with `a = √(A_world / (π · x_on))`, reading `X_ON` from 4.7. `src/webgpu_compute.nim:1125-1126` writes it to `LR_FORCE_SCALE`. The long-range arm of `unitImpulse` and the `F_LR` reference-colony derivation go in `src/balance_core.nim`. Verify 6.1 passes and "The Solve Is Linear In The Source Densities" stays green. Until 7.6's conversion lands, a saved non-zero long-range world loads unconverted. No shipped preset carries one (`src/preset.nim:276`).
- [x] 6.3 Update the long-range help. The `longRangeStrength` line in `docs/help/35-long-range.md` says that at a fixed strength a larger interaction radius strengthens the pull about as its square, and `docs/slider-interactions.md` edge 46 is rewired to mesh-independent. Verify `tests/test_help_content.nim` passes.

## 7. Gate G2, the calibrated strengths and schema version 5

- [ ] 7.1 **Red.** Write suite "Strength Is A Fraction Of The Full Effect" in `tests/test_balance_core.nim`. Per coupling, the stepped oracle's impulse at strengths 0.25, 0.5 and 1 is that fraction of `F_c · u0` within the oracle's tolerance, at the reference configuration (N2). For fluid and scent, the ratio of today's impulse at the old maximum to `F_c` is above 1. Verify it fails on values against today's gains. If the fluid or scent ratio is not above 1, stop and return the numbers to the user without choosing another constant (N2).
- [ ] 7.2 **Red.** The coupling loop in the static block of `src/config_ranges.nim` (`:569-576`) also holds each of the six ceilings at exactly 1. A per-coupling static assertion holds `g_c` equal to `F_c / unitImpulse(unit_c, referenceConfig)`. The waypoint assertion holds every `FORCE_WEATHER_WAYPOINTS` strength inside the new range. `tests/test_param_descriptor.nim` "Descriptors Agree With The Range Authority" holds each strength descriptor to `[0, 1]`. Verify the build fails on today's 5, 37.5 and 0.08 maxima and on the waypoints above 1.
- [ ] 7.3 **Red.** Write the version-5 suite in `tests/test_preset.nim` (C10 test 8, N7). It converts every coupling strength at each size in `LR_GRID_SIZES` and at radii 10, 50 and 150 by the N7 table, and holds:
  - zero stays exactly zero
  - the clamp applies once, last
  - a version-4 preset with Force Strength 2.5 decodes to 0.5
  - a version-1 fixture carrying Force Strength converts through both branches
  - `V1_FIELD_FORCE_SCALE` composes with the scent factor (the extension of `tests/test_preset.nim:597-605`)
  - `sphSubsteps`, `colormapIndex` and `fieldOpacity` are dropped without error

  Add the check `V1_FIELD_FORCE_SCALE == 1 / FIELD_PATTERN_SHRINK` that `src/preset.nim:641-644` claims exists (N9.11). Verify the suite fails at `CURRENT_SCHEMA_VERSION` 4. The `V1` check passes on first run, because the relation holds today.
- [ ] 7.4 **Gate G2, each coupling's full effect; it gates 7.5 and 7.6.** Run the in-app procedure with the pressure acting, at the shipped 32 000 particles (11.9) and radius 50 over a settled world. For each of fluid, scent, long range and deposit, set that coupling alone to the old-scale slider value that `src/balance_core.nim` reports for new strength 1 at the provisional `F_c`. Species is read at old 5 and bodies at 1. Record the slider-step error.
  - The observation that settles each: the motion shows the effect named beside `F_c`. At strength 1, no field or mesh coupling pushes a clump's edge harder than the species force holds it (N2).
  - Record each reading, and whether it confirms or replaces the provisional `F_c`, in `scratchpad/core-force-interface/g2__<DD-MM-YY-HHmm>.md`.
  - A replaced `F_c` is recomputed through `src/balance_core.nim` before 7.5.
- [ ] 7.5 Set the gains, ranges and defaults (N2, N7):
  - **Constants in `src/config_ranges.nim`.** Each `F_c` and `g_c` is recorded with its G2 record, or with a provisional note, as `LONG_RANGE_STRENGTH_MAX` carries one.
  - **Ranges.** The six strength ranges run 0–1.
  - **Gain sites.** `g_pair` 5 in `forceMultiplier`, `g_fluid`, `g_scent`, `g_LR · U(R)` and the deposit × 0.08 each reach their one site, through `src/webgpu_compute.nim` or `src/shader_config.nim`. `rdDeposit`'s concentration full effect becomes its own constant, and every reading of `RD_DEPOSIT_MAX` as a concentration reads that constant: `tests/test_field_core.nim:477,781,808,814,848,851,923,1019-1032,1358-1360,1591,1618`, the static assertions and regime floors at `src/config_ranges.nim:661-686`, and the comments at `src/field_core.nim:154,287,302,330,335,428`, `src/config_ranges.nim:315,424-464`, `web/shaders/src/field-deposit.wgsl:62` and `web/shaders/src/field-resolve.wgsl:67`. The strength range reaches `src/ui/api/param_descriptor.nim:681`, `src/preset.nim:481` and `tests/test_param_descriptor.nim:262`, and `tests/test_preset.nim:759` is checked against the one it means.
  - **Restated constants.** Force Weather waypoints become 0.16, 0.32, 0.48, 0.24 and 0.10 (`src/config_ranges.nim:140-146`). `FORCE_WEATHER_MAX_STEPS[fxStrength]` becomes 0.002 (`src/climate_core.nim:183-196`). `RD_REGIME_HIGH_FEED_DEPOSIT` becomes 0.5, and every `RD_REGIMES` `minDeposit` is restated on the strength scale.
  - **Defaults.** Force Strength 0.2, `rdDeposit` 0.25, and the scent default converted, in `src/ui/state/simulation_state.nim` and `src/preset.nim`.
  - **Precision.** `forceStrength` precision goes from 1 to 2 at `src/ui/api/param_descriptor.nim:443`, with the before (a 0.1 step against the 0.2 default) and the after recorded beside it (N9.12).
  - **Word budget.** The scent and long-range word budgets from 2.4 are re-budgeted at `F_c`. Scent's 2.4 budget (18.75 fine-word units) assumes the inhibitor stays in [0, 1], which no code holds: `web/shaders/src/field-resolve.wgsl:94` floors the fold at 0 with no ceiling, and `web/shaders/src/rd-step.wgsl:101-104` clamps nothing. The re-budget either adds a ceiling or a test that holds one, or budgets scent from the measured gradient peak (`src/field_core.nim:182`) with its conditions.

  Verify 7.1 and 7.2 pass, the `src/ui/input/shipped_mapping.nim` static gate is green with MIDI and audio rows unchanged, and "The Sweep At Calibrated Thresholds" in `tests/test_response_probe.nim` stays green with `rdFieldForce` in `MustPass`.
- [ ] 7.6 Land schema version 5 in `src/preset.nim` (C7, N7):
  - `CURRENT_SCHEMA_VERSION` becomes 5, with a `fromVersion < 5` branch after the version-1 and 3/4 branches (`:681-732`).
  - The branch records the `x_on` and the `F_c`/`g_c` set version 5 converts against, each held equal to its live constant by a static assertion.

  Verify 7.3 passes.
- [ ] 7.7 **Red, then green.** Write suite "Couplings Are Compared On One Scale" in `tests/test_response_probe.nim` (C10 test 9). Each strength probe's impulse, in `u0` at the reference configuration, must match a one-frame stepped measurement of its coupling in `src/balance_core.nim`'s binned world. The suite reports each coupling's `x*` and asserts no bound on it. Then make `src/ui/api/response_probe.nim` report every strength probe in `u0`, `longRange.impulseShare` included. Verify red then green.
- [ ] 7.8 Update the help and docs for the 0–1 scale:
  - `docs/help/12-species.md`, `docs/help/30-fluid.md`, `docs/help/35-long-range.md`, `docs/help/35-bodies.md`, `docs/help/40-rd.md` and `docs/help/42-chemistry.md`: each strength line says what 1 means under the contract, and every Interacts line naming a rescaled strength is updated.
  - `docs/slider-interactions.md`: edges 11–18 and section 7's unit mismatch are rewired.
  - Amend `openspec/changes/long-range-mesh/specs/long-range-coupling/spec.md:300,309`: "no schema version and no migration branch" becomes the version-5 conversion.
  - Amend `openspec/changes/long-range-mesh/specs/parameter-range-authority/spec.md`'s working-bound scenario (`:66-70`): the range is 0–1 with `F_LR` derived.
  - Amend `openspec/changes/long-range-mesh/tasks.md:224`: 6.2 waits on `core-force-interface`.

  Verify `tests/test_help_content.nim` passes and `openspec validate long-range-mesh --strict` passes.

## 8. Pattern Scale and gate G3

- [x] 8.1 **Red.**
  - **Diffusion rates.** Extend "The Field Draws A Small Pattern On Square Cells" in `tests/test_field_core.nim` over a stub `rdDiffusionRates(scale)` in `src/field_core.nim` that returns the base rates. At each band step, the rate ratio is exactly 0.5 and the diameter is `patternDiameterCells(RD_DIFFUSION_A · s)`. It fails on values at every step below 1.
  - **Harness geometry.** The chemotaxis harness (`tests/test_field_core.nim:325-345`) must derive its world units per cell from `WORLD_W` and `FIELD_W`, 1.875, and take the pattern scale (N9.10). It fails at today's 0.94 per cell, which comes from the 1920 reference width. The comment there states 3.75 per cell and a 240-unit world, and is rewritten.
- [x] 8.2 **Gate G3, the band; it gates 8.3 and 8.4.** Parameterize over the steps 1, 0.5, 0.25 and candidate floors below 0.25, down to the first step that fails:
  - the `tests/test_field_core.nim` suites "The Regime Deposit Floor Preserves The Regime", "Ignition From Coherent Deposits", "A Cell's Per-Frame Deposit Is Bounded" and "Chemotactic Collapse Bound"
  - the splat-radius check

  Record, per step:
  - each regime's distance to its own attractor
  - Worms/Coral dark at the default deposit and ignition at their floor
  - that the splat ignites at the default deposit, and at scale 1 that a single cell never does
  - the cell cap at most half the largest measured stable cap
  - the scent's strength-1 stepped impulse
  - the collapse bracket

  If a bracket's lower deposit edge falls to or below the deposit full effect, the suite fails naming the step. The remedy is a re-measured floor, scent gain or deposit ceiling, never a skipped step. Record the floor as the smallest step that passes every criterion, in `scratchpad/core-force-interface/g3__<DD-MM-YY-HHmm>.md`.
- [x] 8.3 Record the band's constants in `src/config_ranges.nim`:
  - `RD_PATTERN_SCALE_MIN` at G3's floor, with `RD_PATTERN_SCALE_DEFAULT = RD_PATTERN_SCALE_MIN` tied by assertion
  - ceiling 1
  - the static assertions: `RD_DIFFUSION_A · ceiling · RD_DELTA_T ≤ 1`, `patternDiameterCells(RD_DIFFUSION_A · floor) ≥ RD_MIN_RESOLVED_DIAMETER_CELLS`, and default in range
  - `RD_REGIME_SCALE_ROWS` for each step where G3 finds a regime drifting, with `regimeRow(id, scale)`; the regime assertions in `src/config_ranges.nim` extend over it
  - the per-step stepped scent impulse, `RD_SCENT_STEPPED_IMPULSE`, beside the band constants for 8.4
  - the splat radius and cell cap as one constant where one value passes, and per-frame values otherwise
  - the per-step collapse bracket beside `TROPISM_MAX` (species-chemistry)

  Implement `rdDiffusionRates`. Verify 8.1 passes.
- [ ] 8.4 **Red, then green.**
  - **Red.** `tests/test_preset.nim`: a preset with no `rdPatternScale` decodes at 1. Probe coverage in `tests/test_response_probe.nim` and help coverage in `tests/test_help_content.nim` fail for the new id.
  - **Green.**
    - The `rdPatternScale` descriptor in `src/ui/api/param_descriptor.nim`: group `rd`, linear, step 0.01, precision 2, no dormancy.
    - A closed-form probe over `patternDiameterWorld` in `src/ui/api/response_probe.nim`.
    - The state field in `src/ui/state/simulation_state.nim`, and the preset field in `src/preset.nim`, which decodes absent as 1.
    - `src/webgpu_compute.nim:1053-1054` writes `rdDiffusionRates` and `g_scent(s) = F_scent · √s / scentUnit(1)` each frame, or the recorded per-step gain where √s misses G3's stepped impulse beyond the oracle's tolerance.
    - `applyRegimeImpl` and the regime catalog in `src/web_api.nim:596-654` read `regimeRow` at the live scale, and the served rows reach `web-ui/src/garden-api.ts`'s catalog type.
    - `rdClimateTour` in `src/climate_core.nim:107-112` takes the scale.
    - The help line in `docs/help/40-rd.md`, and a Pattern Scale node in `docs/slider-interactions.md`.

  Verify red then green, and that "Every Writer Answers In The Pair Unit" sweeps the scent arm over the band steps.
## 9. Gate G4 reads in the final in-app pass (12.1)

## 10. The fluid's three one-term arms

- [x] 10.1 **Red.** Extend `src/balance_core.nim`'s binned oracle world with a mirror of `sph_core`'s pair loop (`web/shaders/src/forces-sph.wgsl:240-280`). Add suite "The Fluid Mirror Steps As The Oracle Does" to `tests/test_balance_core.nim`, holding one mirrored step equal to `src/sph_core.nim`'s oracle within its tolerance. Add suite "Each Effect Is Read Alone", holding that each arm's two sides differ in exactly one term (sph-scale). Verify both fail against a stub mirror that drops the blend.
- [ ] 10.2 **Measurement for the arms; it gates 10.3.** Add recipe `calibrate-fluid` to `justfile`, outside `just check`. The conditions: the gate seeds at 128 000 particles, radius 50, Force Strength 0.2, the pressure acting, crowding 0, fluid 1, 900 steps, window 749–899. Run the three arms (N8), each reading σ and E against fluid 0:
  - blend at `SPH_XSPH_EPSILON` against 0, at Viscosity 0
  - the pressure gain at `SPH_FORCE_SCALE` against 0
  - radius fraction 1 against 0.75, 0.5, 0.25 and 0.1

  Record in `scratchpad/core-force-interface/fluid-arms__<DD-MM-YY-HHmm>.md`, including whether fraction 0.1 still computes a fluid. If no step of an arm passes, its numbers go back to the user with the proposal's "delete the fluid" case. The task does not choose.
- [ ] 10.3 Set the fluid defaults from the arms, each with its arm, conditions and reading beside it:
  - `SPH_XSPH_EPSILON` in `src/sph_core.nim`, 0 if σ is lower with the blend
  - the reading beside `SPH_FORCE_SCALE`, and the `sphStiffness` default stepped down by halves from 8 to the largest value whose σ is not lower than fluid-without-pressure's
  - the `sphRadiusFraction` default, the largest step whose σ is not lower than fraction 1's
  - the record at `SPH_RADIUS_FRACTION_MIN` (`src/config_ranges.nim:215-245`)

  The Viscosity line in `docs/help/30-fluid.md` says whether smoothing acts at Viscosity 0. Verify `just happen` green, "Preset Clamp Behavior Contract" and "A Legacy Preset Loads As The World It Described" green, and that every changed constant carries its arm record (the measured-bound agent check).

## 11. Remaining folded defects and the interaction docs

- [x] 11.1 **Red.** In `tests/test_dormancy.nim`, walk a new `paletteFixed` predicate's `paletteFields` against `PaletteEditorState`: true under `psOpenColor` and the default scheme (`src/palette.nim:27-29,141-164`, `src/ui/state/palette_state.nim:40-44`), false otherwise. Verify it fails while the predicate is unregistered. Then implement:
  - `DormancyPredicate.paletteFields` and `paletteFixed` in `src/ui/api/dormancy.nim`
  - `dormantParams` reading `paletteEditorState` in `src/web_api.nim:1442-1455`
  - `dormantWhen` on `paletteSaturation` and `paletteLightness` in `src/ui/api/param_descriptor.nim`
  - the inertness stated in `docs/help/53-palette.md`

  Verify green (N9.5).
- [x] 11.2 Help-text defects:
  - `docs/help/10-simulation.md:9-10`: "rebuilds" becomes "resizes", as the code does (`src/web_api.nim:893-901`, N9.1).
  - `docs/help/51-glow.md:10-11`: the Velocity Sweep line gains halo growth (`web/shaders/src/glow.wgsl:94-99`, N9.6).

  Verify `tests/test_help_content.nim` passes.
- [ ] 11.3 Update `docs/slider-interactions.md` to the finished graph:
  - Replace the "Planned rewiring" section (`:489-504`) with the edges as built.
  - Check that the edge table, per-slider adjacency, diagram, cost layer (every coupling slot and `coupled=`) and calibration inventory (each `F_c`, `x_on`, `K`, `B_L`, `ff_stable`, the band floor and the fluid arms) match the code.
  - Check that every `Interacts with:` line in `docs/help/*.md` names no removed control (Substeps, Field Opacity, Field Colormap) and no rewired edge in its old form.

  Verify `tests/test_help_content.nim` passes, and that `grep -n 'Substeps\|Field Opacity\|Colormap' docs/help/*.md` is empty.
- [ ] 11.4 Update `docs/enforcement.md` to the specs:
  - **Guarantees rows.**
    - the six coupling ceilings at exactly 1
    - gains derived from `F_c` (build-asserted)
    - the two velocity words (build-asserted)
    - the `x_on` and `F_c` records in `src/preset.nim` (build-asserted)
    - the profiler-slot pairing through `src/profiler_slots.nim` (derived)
    - "No Render Shader Reads The Field" (test-held, reading names only)
  - **Rewritten rows.** The tunnelling guarantee (`:56`) now names the stated floor and `substepPlan`. The coupling-floor row (`:51`) also holds the ceilings.
  - **Recipe tier.** The tier of `just calibrate-balance` and `just calibrate-fluid`: suites run at change time on the three gate seeds at 128 000 particles and not by `just check`, with the rerun conditions (`K`, the pressure law, the onset, `k`/`q_max`, the crowd density's dependence on particle count). That the recipes rerun is itself unenforced. The scent and body coupled costs are unmeasured.
  - **Reference oracles.** Add `balance_core`, the pressure oracle and the two-word integrate decode in `physics_core`, and the `field_core` row without the frame-scaled force.
  - **Unenforced, with their raisers.** Each shader carries its oracle's convention; the `U(R)` factor in `lr-force.wgsl`; the range-constant lint; the size-conversion grep gate; GPU bit identity under relaxed math (C4); the hold with long range, scent and the mouse at 1 (C6).

  Update `docs/one-world.md` to the couplings model: the contract, world pressure, the integrator's substeps and the field as force only. Update `tests/README.md`'s rows and oracle lists for `test_balance_core`. Verify by reading each spec's "Enforced by" against the entries.
- [x] 11.5 Rewrite the fresh-state test at `openspec/changes/audio-interface/tasks.md:196-198`. As written, it holds one state across both rooms, so it cannot catch a room level that survives reinitialisation. The rewrite learns a quiet room, re-initialises the state, then feeds a louder room and asserts it reads exactly zero with silent reported. Verify `openspec validate audio-interface --strict` passes.
- [x] 11.6 Correct `openspec/changes/audio-interface/specs/audio-input/spec.md:158-160`. "the same wall-clock time at any frame rate" holds only down to 20 fps, because the audio poll receives the delta capped at 0.05 s (`src/app.nim:240,259`). The spec states that bound. Verify `openspec validate audio-interface --strict` passes.
- [x] 11.7 Rerun the gain-step arm of `scratchpad/audio-interface/probe/frozen_room_probe_v7.nim` on the chosen candidate: the held level at the chosen 1 s ceiling decay ("held 1 s, 1 s"), the frozen learned-room edge design.md:188 describes. Replace the figures at `openspec/changes/audio-interface/design.md:188` (a 20 dB up-step, and a 10 dB drop moving p50 from 0.57 to 0.49) with the rerun's, citing its output file in `scratchpad/audio-interface/probe/`. Verify `openspec validate audio-interface --strict` passes.
- [x] 11.9 **The shipped particle count is 32 000.** Set `particleCount` to 32 000 in `src/ui/state/simulation_state.nim:125` and `src/preset.nim:232`. Update every test and help line that reads 16 000 as the shipped default (`grep -rn '16000\|16 000' tests docs/help src/ui src/preset.nim`), leaving the measurement records that name 16 000 as their condition. Verify `tests/test_preset.nim`, `tests/test_config.nim` and `tests/test_help_content.nim` pass. 7.4 and 12.1 run at this default.

## 12. The final in-app pass and the check

- [ ] 12.1 **In-app, once.** Run the in-app procedure and record each part in `scratchpad/core-force-interface/in-app-final__<DD-MM-YY-HHmm>.md`:
  - **Hold.** At 128 000 particles and 12 species: Long Range at its maximum for 10 s; bodies at Hold 10 for 10 s, then removed; friction 0 over a settled self-attracting world. Read whether far colonies keep their motion while the bodies hold, the held `physics=` (recorded, not gated: held crowds may exceed the allotment by the user's decision, C6), whether the population spreads back within 15 s, whether dense crowds shimmer or collapse at friction 0, and whether the simmer shows at shipped friction. `parametric-bodies` 9.2 and 9.3 take their measurements after this part.
  - **Field.** Field ignited, scent 0, bloom on then off: the space between particles is background and every particle draws its species colour; at scent 1 the pattern shows only as motion; bloom off dims the grade controls in the same tick, with no stats push between (gardenapi-boundary). A coloured layer under the particles, particles lit off their species colour, or trails bending where no particle moves fails the part.
  - **Strengths.** At the shipped count, each of the six couplings alone at 1: the effect named beside its `F_c` (the coupling-contract agent check). Long Range 1 at Force Strength 0 over 128 000: the busiest clump stays finite.
  - **Long-range cost, gate G4.** At 128 000, Long Range 1 in the four Long Range × Force Strength corners, one run each: `coupled=` against 4.9's allotment, into `docs/perf-report.md` with each row cited from its declaration in `src/sim_registry.nim`. A corner past the allotment goes back to the user with the numbers.
  - **Pattern Scale.** Field ignited, scent 1, Pattern Scale dragged from 1 to the floor: the spacing of the clusters scent gathers shrinks over the following seconds, and nothing diverges or blanks.
  - **Fluid.** Fluid 1 over a settled world at shipped species defaults, each arm's control stepped across its values: the species structure against fluid 0 reads as the arm's σ predicted.
- [ ] 12.2 `just happen` and `just check` green.

Note, outside the checkboxes, for the spec lifecycle that runs outside this change: a delta cannot change a
Purpose, so after archive the Purpose paragraphs of `openspec/specs/bounded-crowding/spec.md` (it still
owns "the density ceiling that factor implies") and `openspec/specs/field-scale/spec.md` (it still owns
"the single shrink knob" and how the field "reaches the eye") need hand edits to match the merged
requirements.
