## 0. Orientation

- [ ] 0.1 Read `CLAUDE.md`, then `docs/research/README.md`, then this change's `design.md`. The
      design decisions D1–D10 are settled; you build and measure, you do not re-research them.
- [ ] 0.2 Confirm the toolchain: `just happen` and `just check` both green on a clean tree before
      changing anything. A pre-existing failure is the first task, not a thing to work around.
- [ ] 0.3 Check whether `legible-controls` has landed. It is independent of this change and either
      order works, but both add fields to `ParamDescriptor` and both touch `ParamSlider.tsx`. If it
      landed first, every descriptor added here needs a response probe or a written exemption and its
      slider travel is swept — see that change's design E1 and E4 before adding a control.

## 1. Ignition measurement gate (S0)

Leads with tests. Task 1.3 is expected to fail at radius 1 — that failure is the measurement.

- [ ] 1.1 `tests/test_field_core.nim`: add `the nontrivial fixed points exist exactly where
      F >= 4*(F+k)^2`, asserting the analytic condition across the feed/kill rectangle. Expected:
      passes immediately; it pins design D2 as an executable fact.
- [ ] 1.2 `tests/test_field_core.nim`: add `the shipped defaults sit where only the trivial fixed
      point exists`. Expected: passes; documents why deleting the seed is safe.
- [ ] 1.3 `tests/test_field_core.nim`: add `clusteredDepositMask(radius)` beside the existing
      `depositMask()` (line 81), placing the same total coverage as discs rather than a scatter.
      Add `a clustered deposit ignites where a scattered deposit of equal coverage does not`,
      sweeping radius in {1,2,3,5,8} and amplitude across `[RD_DEPOSIT_MIN, RD_DEPOSIT_MAX]`, at
      Pearson defaults and at `(RD_FEED_MIN, RD_KILL_MIN)`. Use both top-hat and Gaussian profiles.
      Judge with the existing `FieldStats` metrics against `ALIVE_THRESHOLD`.
- [ ] 1.4 Add `a clustered deposit below the critical radius relaxes to background` — the negative
      control.
- [ ] 1.5 Add `ignition completes within N frames at the shipped defaults`; N is the cold-start
      budget for D10.
- [ ] 1.6 Record the minimum igniting (radius, amplitude) in a comment beside the new constant. This
      is the declared input to task 4.1. If no radius in the sweep ignites, follow design D3's
      fallback ladder — do not restore automatic seeding, do not move the default climate.
- [ ] 1.7 `just happen` and `just check` green.

## 2. Composable frames (S1)

Tasks 2.1–2.3 must pass **before** any shader edit, and must still pass after — that equivalence is
the regression check for the whole restructure.

- [ ] 2.1 `tests/test_sim_registry.nim`: `forces-only couplings produce exactly today's
      particle-life pass list`.
- [ ] 2.2 Same file: `sph-only couplings produce exactly today's SPH pass list`.
- [ ] 2.3 Same file: `field-only couplings produce exactly today's reaction-diffusion pass list`.
- [ ] 2.4 Same file: `every frame clears velocityDelta and densityDelta before any pass that writes
      them`; `forces and field together dispatch the grid build exactly once`; `the field ping-pong
      parity holds for every couplings combination containing field`; `no couplings combination
      dispatches an unknown pipeline key`; `controlGroupsFor unions the groups of active couplings`;
      `couplings with nothing active dispatch only the clears and integrate`.
- [ ] 2.5 `src/sim_registry.nim`: add `sbVelocityDelta` to `SimBuffer`; add
      `WorldCouplings = object; forces, sph, field: bool`; change `buildFrame` to take it. Grid triad
      and scatter run iff `forces or sph`; field passes iff `field`; `integrate` always last. Open
      the frame with `clearBufferNode(sbVelocityDelta)` and `clearBufferNode(sbDensityDelta)`.
- [ ] 2.6 `src/sim_registry.nim`: delete the stale "would race those atomics" comments at :199-203
      and :237-239. Design D1 records why they are wrong about the mechanism.
- [ ] 2.7 `web/shaders/src/forces.wgsl` and `forces-sph.wgsl`: delete the `atomicStore` self-reset
      prologues (forces.wgsl:126-132, forces-sph.wgsl:144-148).
- [ ] 2.8 `web/shaders/src/field-force.wgsl`: binding 3 becomes `array<atomic<i32>>`; the plain store
      at :86-89 becomes `atomicAdd`. Update the binding manifest comment and the "sole writer" note.
- [ ] 2.9 `src/webgpu_compute.nim`: `byteLengthFor` gains `sbVelocityDelta` — **two i32 per particle,
      not one**. `setActiveSimKind` becomes `setCouplings`.
- [ ] 2.10 `src/sim_registry.nim`: keep `SimKind`, `simKindId`, `parseSimKind` as the preset
      compatibility layer mapping legacy ids to couplings triples. Write no migration — design D8
      explains why none is needed.
- [ ] 2.11 `just happen` and `just check` green, with 2.1–2.3 still passing unchanged.

## 3. Reserved slots for a future reaction (S1b)

Done here because the bind groups are already open. Implements no second reaction.

- [ ] 3.1 `src/gpu_types.nim`: add `ReactionParamsLayout` — `reactionKind`, `kernelRadius`,
      `growthMu`, `growthSigma`, `growthDt`, padded to 32 bytes — with the same compile-time offset
      validation and generated WGSL struct module as every layout. Leave `FieldParamsLayout` at 32
      bytes.
- [ ] 3.2 Bind `ReactionParams` to the `rdStep` pipeline; bump its expected bind-group entry count in
      `src/webgpu_compute.nim`; write the buffer each frame with `reactionKind = 0`.
- [ ] 3.3 `web/shaders/src/rd-step.wgsl`: promote the `reactionKind` override (:57) to a named
      constant set with `REACTION_GRAY_SCOTT = 0u`, reading from the new uniform. Behaviour must be
      byte-identical for Gray-Scott.
- [ ] 3.4 `field-resolve.wgsl:77` and `field-seed.wgsl:101`: preserve the incoming `.b`/`.a` channels
      instead of writing literal `(0.0, 1.0)`. Document them as reserved state channels for a
      multi-channel reaction, noting they are free because the format is `rgba16float` by necessity.
- [ ] 3.5 `web/shaders/src/field-deposit.wgsl`: introduce `DEPOSIT_CHANNELS = 1` and index through
      it, so raising the count later is one constant rather than an index audit.
- [ ] 3.6 `just happen` and `just check` green; the field must look identical to before this group.

## 4. Ignition from life (S3)

- [ ] 4.1 `web/shaders/src/field-deposit.wgsl`: splat each particle's deposit over the radius
      measured in task 1.6, with a falloff kernel, replacing the single-cell `atomicAdd`.
- [ ] 4.2 `src/webgpu_compute.nim:156-157`: stop the automatic reseed on couplings entry. Keep
      `field-seed.wgsl` and the Reseed control, relabelled as a deliberate "scatter spores" action.
- [ ] 4.3 Run `./main`. The field must ignite from colonies alone within the task 1.5 budget, with no
      seed. If it does not, apply design D3's ladder in order.
- [ ] 4.4 `just happen` and `just check` green.

## 5. Species chemistry (S4)

- [ ] 5.1 `src/gpu_types.nim`: `SpeciesChemistryLayout` — `MAX_SPECIES` × (secretion, tropism) f32,
      padded to 64 bytes, standard compile-time offset validation.
- [ ] 5.2 Bind to `fieldDeposit` and `fieldForce`; bump `EXPECTED_BIND_GROUP_ENTRIES_FIELD_DEPOSIT`
      and `..._FIELD_FORCE` (`src/webgpu_compute.nim:69,72`).
- [ ] 5.3 `field-deposit.wgsl`: deposit `depositAmount * secretion[species]`, signed.
      `field-force.wgsl`: force becomes `-gradient * fieldForceScale * tropism[species]`.
- [ ] 5.4 `src/config_ranges.nim`: `SECRETION_MIN/MAX = -1.0/+1.0`, `TROPISM_MIN/MAX = -1.0/+0.5`
      per design D5, with the standard non-empty and default-in-range static assertions.
- [ ] 5.5 `tests/`: add `positive tropism at its bound does not produce unbounded aggregation over N
      steps` and `the configured tropism bound sits below the measured collapse point`. If either
      fails, halve `TROPISM_MAX` and record the measured collapse value beside the constant.
- [ ] 5.6 `web-ui/src/`: chemistry editor beside the attraction matrix, following
      `matrix_state.nim`'s patterns.
- [ ] 5.7 `just happen` and `just check` green.

## 6. Field as light (S5)

- [ ] 6.1 `tests/`: `field coverage is zero where field intensity is zero` and `field coverage rises
      monotonically with intensity and saturates at one`. The first fails today — that is the bug.
- [ ] 6.2 `web/shaders/src/render.wgsl`: bind the field texture, sample at the particle's world
      position, modulate `output.color` toward the colormapped field value.
- [ ] 6.3 `tonemap.wgsl:60-66,77`: `fieldCoverage` follows field luminance instead of `1.0`.
      `field-composite.wgsl:56`: alpha follows intensity. Keep both paths in tonal parity — that
      parity is the file's stated reason for existing.
- [ ] 6.4 `fade.wgsl`: displace the trail sample by the field gradient, small scale, one new uniform.
- [ ] 6.5 Revisit `fieldOpacity`'s 0.85 default (`colormap_core.nim:53`) now the field is light.
- [ ] 6.6 Verify in the app; `just happen` and `just check` green.

## 7. Camera, zoom, navigation (S6)

Extract the maths into a pure module first — none of it needs a GPU, and that is where the tests go.

- [ ] 7.1 `src/camera_core.nim` (new, pure) + `tests/test_camera_core.nim`: `the nearest toroidal
      image of a point across the seam is the short way round`; `zoom 1.0 centred on the world middle
      reproduces today's clip mapping exactly`; **`panning by exactly one world width returns an
      identical view`**; `particle size, trail length, and glow radius scale by the same factor at
      every zoom`; `zoom clamps to its configured range`; `the size floor keeps particles visible at
      minimum zoom`. Register the module in `tests/test_all.nim` with its marker constant and add it
      to `tests/README.md`'s table and tree.
- [ ] 7.2 `src/gpu_types.nim`: `CameraLayout` — `centerX`, `centerY`, `zoom`, pad — standard
      validation, written every frame.
- [ ] 7.3 `render.wgsl:134-140` and `glow.wgsl`: transform through the camera; draw each particle at
      its nearest toroidal image relative to the camera centre, reusing the `wrapDelta` logic
      `physics_core.nim:133-251` defines and `forces.wgsl:353-357` mirrors.
- [ ] 7.4 Scale particle size, trail length, and glow radius by the world scale with a floor, per
      design D9. All three move together or none does.
- [ ] 7.5 `src/webgpu_render.nim:390-394` and the field sampler at `src/webgpu_init.nim:204`: set
      `addressModeU/V = "repeat"`.
- [ ] 7.6 `fade.wgsl`: reproject the trail by the frame's camera delta in UV. `tonemap.wgsl` and
      `field-composite.wgsl`: map screen UV through the camera into field space.
- [ ] 7.7 `src/ui/input/wheel_handler.nim` and `key_handler.nim` (new, pure) with native tests, plus
      listeners in `src/canvas_input.nim`. Reuse the unused `KeyboardEvent` `addEventListener`
      overload at `bindings/dom_extensions.nim:89`. Bindings: wheel zooms at the cursor, arrows pan,
      `+`/`-` zoom, `0` resets.
- [ ] 7.8 Close the touch gaps: two-finger tap fires a blast; register the `handleTouchCancel`
      listener (`touch_handler.nim:59-62`) that currently has none.
- [ ] 7.9 `src/config_ranges.nim`: `CAMERA_ZOOM_MIN = 0.25`, `CAMERA_ZOOM_MAX = 8.0`, with static
      assertions. Add a "Drift" toggle for slow autonomous camera motion, off by default.
- [ ] 7.10 Verify: pan and zoom through a full wrap in each axis — no seam, no trail smear, no
      popping. Park a bright cluster on the boundary and confirm glow and trail continue across.
- [ ] 7.11 `just happen` and `just check` green.

## 8. Notched sliders, regimes, and weather (S7)

Notches mark values worth reaching. Whether the track between them is worth moving through is the
`legible-controls` change's question, and its travel curves are the remedy where it is not — the two
compose on the same descriptor without conflicting.

- [ ] 8.1 `src/ui/api/param_descriptor.nim`: add an optional `notches: seq[(value: float, label:
      string)]` to the descriptor, served through `gardenAPI.descriptor()`. Nim owns the notches like
      every other number.
- [ ] 8.2 `tests/test_param_descriptor.nim`: `every notch value lies inside its parameter's range`.
      **This fails for Coral (feed 0.082) until task 8.3.**
- [ ] 8.3 `src/config_ranges.nim`: raise `RD_FEED_MAX` from 0.080 to 0.085 so Coral is reachable
      (design D4).
- [ ] 8.4 Populate notches: feed and kill at the six regime coordinates in design D4; `rdDeposit` at
      0 ("inert") and its default; `rdFieldForce` at 0 ("blind") and its default; camera zoom at 0.25
      ("tiled"), 1.0 ("world"), 8.0 ("creature"); particle count at the coupling ceilings.
- [ ] 8.5 `web-ui/src/`: render notches as labelled tick marks on every slider that declares them,
      snapping when dragged near. Every factor stays a slider.
- [ ] 8.6 `web-ui/src/`: a named-regime selector row (Waves, Mitosis, Labyrinth, Spots, Worms, Coral)
      setting feed and kill together, because a notch on one axis alone does not locate a regime.
- [ ] 8.7 `climateDrift` bool and `climateSpeed` in sim config; the frame loop advances feed and kill
      along a smooth path inside the rectangle through the ordinary `setParam` path, so the sliders
      visibly move. Off by default.
- [ ] 8.8 `tests/`: `climate drift stays inside the feed/kill rectangle for every phase`; `climate
      drift is continuous — no step exceeds the configured maximum delta`.
- [ ] 8.9 `src/ui/api/param_descriptor.nim`: rename the field group's display labels to sensory names
      (Secretion, Scent-following, Drift, Breath). **Labels only** — descriptor ids are preset
      storage keys and must not move.
- [ ] 8.10 `just happen` and `just check` green.

## 9. One world (S2)

Sequenced last among the user-visible groups because it is the breaking change; everything before it
can ship as 1.7.x.

- [ ] 9.1 `tests/`: `a preset saved with a legacy mode id loads into the equivalent couplings`;
      `lowering the particle count preserves the surviving particles' positions`.
- [ ] 9.2 `web-ui/src/components/Panel.tsx`: replace the mode selector with a preset row — Particle
      Life, Fluid, Chemistry, Fluid Chemistry — setting couplings. The panel is already entirely
      `shows(group)`-driven off `controlGroupsFor` (`Panel.tsx:35`), so this is contained.
- [ ] 9.3 `src/web_api.nim:270-281`: clamp the particle count in place when a preset lowers the
      ceiling. Remove the `triggerParticleReinit()` call on that path — no re-randomizing survivors.
- [ ] 9.4 Retire `RD_GLOW_DENSITY_FLOOR` (`src/field_core.nim:99-106`) and its use at
      `src/webgpu_render.nim:1294-1300`. Real density returns once forces run in the chemical world.
- [ ] 9.5 Run `./main`: dragging must move particles in the chemical world; a preset saved before
      this change must still load.
- [ ] 9.6 Bump `particle_garden.nimble` to `2.0.0` — this group removes a user-visible feature.
- [ ] 9.7 `just happen` and `just check` green.

## 10. Performance budget (S8)

- [ ] 10.1 Measure with `gpu_profiler` timestamps: forces+field at 32000, and forces+sph+field at
      32000 as worst case, on ≥90 s settled runs, against the A0 baseline (physics 5.7–7.2 ms,
      ~9.3 ms total GPU at 128k settled; physics roughly quadruples as clusters form).
- [ ] 10.2 If the deposit splat dominates, shrink the kernel or lower the field substep count before
      touching particle count. Note the known gap: bloom passes carry no timestamps
      (`webgpu_render.nim beginBloomPass`).
- [ ] 10.3 If Fluid Chemistry is over budget, lower that preset's default particle count. Do not
      remove the coupling combination (design D7).
- [ ] 10.4 Record the numbers in `docs/perf-report.md` beside the existing baseline.

## 11. Calibration and documentation (S9)

- [ ] 11.1 One deliberate pass over the blind constants under the new couplings: `SPH_FORCE_SCALE`,
      the field deposit and force couplings, `fieldOpacity`, colormap gains, the two-tone ramp, plus
      the new splat radius, field-light strength, gradient-displacement scale, tropism bound, and
      drift speed. Every constant touched gets a doc comment naming what was traded against what.
- [ ] 11.2 `docs/one-world.md` (new): the couplings model — what a coupling is, why delta-buffer
      ownership moved, how to add a fourth coupling, and the frame for each preset. Write it so
      someone can add a coupling from this document and the source alone.
- [ ] 11.3 Update `CLAUDE.md`: the three-mode model, the RD pass list, the reference-oracle table,
      and the module inventory are all changed by this work. Grep for `skReactionDiffusion`,
      `buildFrame`, `RD_GLOW_DENSITY_FLOOR`, and `setActiveSimKind` and confirm no stale reference
      survives.
- [ ] 11.4 Update `tests/README.md`'s per-file table and architecture tree with every test module
      added by this change.
- [ ] 11.5 `openspec validate one-world`, then `openspec archive one-world`.
- [ ] 11.6 `just happen` and `just check` green.
