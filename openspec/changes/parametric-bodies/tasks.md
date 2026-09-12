These tasks build the fifth coupling by the fourteen steps of `docs/one-world.md:188-284`, in an
order that keeps every group's end state playable rather than half-wired. Group 2 is the measurement
gate the proposal names and it precedes group 6, the only group that writes feedback. Group 8, the
world's own generator, touches `src/app.nim`, one section of `src/body_core.nim` and one range, and
nothing in groups 1 through 7 depends on it — cut it to a follow-up change by deleting the group.

Every decision the design opened is settled (design, Settled decisions). Three of them shape what
appears below and what does not: bodies are not drawn, so no render work appears; a body's lifetime is
fixed at ignition, so no release-on-gesture write path appears; and the panel carries seven
descriptors, with anisotropy, envelope skew and sustain travelling on the ignition call under
Nim-owned bounds instead of drawing sliders.

Every group ends green on both suites. Where a task says "red first", run it and watch it fail for
the stated reason before writing the code — the observed failure is the proof the test can see the
defect (`docs/engineering-principles.md:84-90`). Run the narrow target while working
(`nim c -r tests/test_body_core.nim`) and the full suite at each group's end.

Four things hold for every test below. Name it `<subject> <verb> <behavior> [when <condition>]`, the
form the existing suites already use. Let it fail for one reason and say which — a sweep reports the
axis and the value that broke it, not merely that something did. Take the expected result from
somewhere other than the code under test: this suite is the oracle the two shaders are written
against, so an assertion that calls the function under test to compute its own expectation proves
nothing. The independent oracles available here are the isotropic circle (`length(p - c) - r` in
closed form), Newton's third law (action and reaction summing to zero), the lifetime argument itself,
and symmetry (a symmetric arrangement yielding zero). Use `unittest`'s own `check` and `require`
throughout.

## 1. The pure body core

Everything in this group is native Nim. No shader, no buffer, no panel.

- [x] 1.1 **Red first.** Write `tests/test_body_core.nim` against a module that does not exist yet,
      asserting properties rather than pinned scalars: the signed distance is negative strictly
      inside and positive strictly outside for isotropic and anisotropic bodies; it is zero on the
      surface within tolerance; rotating body and sample point together leaves it unchanged; the
      isotropic case equals `length(p - c) - r` exactly; displacement is toroidal minimum image, so a
      body one unit from a world edge acts on a particle one unit past it exactly as on a particle
      two units away inside. Register the module in `tests/test_all.nim` and in `tests/README.md`.
      Verify: `nim c -r tests/test_body_core.nim` fails to compile on the missing import
- [x] 1.2 Write `src/body_core.nim` with the SDF of design D3 and the toroidal helper, pure, no FFI,
      no import from GPU-facing code. Verify: the 1.1 assertions pass
- [x] 1.3 **Red first.** Extend `tests/test_body_core.nim` with the envelope: continuity at each of
      the four phase boundaries, zero before attack and zero after release, monotone within attack
      and within decay, realized lifetime equal to the `bodyLifetime` argument at every admissible
      envelope skew, and the sustain level reached at the end of decay. Verify: the new tests fail
- [x] 1.4 Add the envelope to `src/body_core.nim` per design D10: one lifetime, the four
      `ENVELOPE_PROPORTIONS` constants with the static assertion that they sum to one, and the skew
      that redistributes them without changing the total. Verify: 1.3 passes, and changing one
      proportion without changing another turns the compile red
- [x] 1.5 **Red first.** Extend the suite with the force laws: proximity is exactly zero at and
      beyond the band edge and its derivative is zero there; proximity points toward the surface from
      both sides; enclosure at zero strength is zero at every distance; negating enclosure negates the
      force and changes nothing else; both scale linearly in the envelope. Verify: the new tests fail
- [x] 1.6 Add the force laws to `src/body_core.nim` per design D4. Verify: 1.5 passes
- [x] 1.7 **Red first.** Extend the suite with the slot allocator and the rigid step: a slot is reused
      only after its full lifetime elapses; a full table refuses ignition and says so; free count is
      the ceiling minus live count at every clock value; the summed particle impulse plus the
      accumulated body impulse is zero to fixed-point resolution; a symmetrically surrounded body
      receives zero net force and zero net torque; exponential damping settles a body in the same
      wall-clock time at one substep and at eight. Verify: the new tests fail
- [x] 1.8 Add the allocator and the semi-implicit step to `src/body_core.nim` per design D5, D9 and
      D11, with `MAX_BODIES` added to `src/memory_layout.nim` beside `MAX_PARTICLES` and
      `MAX_SPECIES`. Verify: 1.7 passes
- [ ] 1.9 `just happen` builds and `just check` is green

## 2. Measurement gate: a crowd cannot drive a body unstable

The proposal's gate. It runs entirely in the native suite over the group 1 mirror, needs no GPU and
no person, and it gates group 6 alone — groups 3, 4, 5 and 7 wait on nothing here.

- [x] 2.1 Write the sweep in `tests/test_body_core.nim` as its own suite, following the precomputed
      shape `tests/test_field_core.nim:970-1035` uses for the chemotactic-collapse bound: crowd size
      up to `MAX_PARTICLES`, `bodiesStrength` across its range, proximity and enclosure across
      theirs, band width, body area across its range, and substep count from one to the fluid's
      ceiling. Measure whether the body's speed and angular speed settle over a run long enough to
      show the trend. A failure SHALL name the axis, the value, and the settling figure that broke
      it, so a red reads as a coordinate rather than as "the sweep failed". Verify: the sweep runs and
      reports a boundary, whether or not the shipped range sits inside it
- [x] 2.2 Choose the mass, damping and per-substep impulse-cap constants from 2.1 so the whole shipped
      range is stable, in that order of preference, and write them into `src/body_core.nim` with the
      measured conditions beside each — including the four premises that re-run the sweep (particle
      budget, strength ceiling, force law, substep count). **Do not lower a user-facing ceiling to fit
      an implementation limit** (`docs/engineering-principles.md:75-82`). Verify: the 2.1 sweep passes
      at the shipped range
- [x] 2.3 Derive the band-width floor from the particle speed cap and the largest substep timestep,
      state the derivation beside the constant in `src/body_core.nim`, and add the test: a particle at
      the speed cap fired at an enclosing wall, with the band at its narrowest and the timestep at its
      largest, is turned rather than passing through. Verify: the test passes at the derived floor and
      fails at half of it
- [x] 2.4 Add the static assertions of design D7 to `src/body_core.nim`: the particle budget times the
      largest admissible per-particle force times `BODY_FIXED_POINT_SCALE` fits `int32`, and the same
      for torque with the world's half-diagonal as the lever arm. Verify: `just happen` is green, and
      temporarily raising a bodies range past the bound turns the compile red
- [x] 2.5 Record the sweep in `docs/perf-report.md` under the table shape that file already uses
      (`:86`, `:134`), with the conditions a stranger needs to re-run it. Verify: the entry names the
      machine, the ranges swept, and the four premises
- [ ] 2.6 `just happen` builds and `just check` is green

## 3. The numbers and the panel surface

- [x] 3.1 **Red first.** Add `bodiesStrength` to the coupling-floor loop at
      `src/config_ranges.nim:451-457` before the constant exists. Verify: `just happen` fails at the
      Nim compile on the unknown identifier
- [x] 3.2 Add the bodies bounds to `src/config_ranges.nim` following that file's `<NAME>_MIN` /
      `<NAME>_MAX` convention (`:35`, `:41`, `:55-56`). Seven back a descriptor: strength with a
      floor of zero, radius, band, proximity, enclosure, lifetime, and ignition rate with a floor of
      zero. Three back no descriptor and bound an ignition parameter instead: anisotropy, envelope
      skew, and sustain. Note beside the second group that they are clamped at the ignition entry
      rather than by a slider. Verify: `just happen` is green and the floor loop passes
- [x] 3.3 Add the fields and their defaults to `src/ui/state/simulation_state.nim` beside
      `forceStrength` (`:21`), `fluidStrength` (`:38`), `rdDeposit` (`:63`) and `rdFieldForce`
      (`:66`). Verify: `just happen` is green
- [x] 3.4 **Red first.** Add exactly seven `bodies` descriptors to
      `src/ui/api/param_descriptor.nim` as `floatParam` entries (`:358-374`) in one `bodies` group —
      `bodiesStrength` first, then `bodyRadius`, `bodyBand`, `bodyProximity`, `bodyEnclosure`,
      `bodyLifetime`, `bodyIgnitionRate` — modelled on the fluid group at `:556-610`, without
      touching `web-ui/src/components/Panel.tsx`. Add no descriptor for anisotropy, envelope skew or
      sustain. Verify: `tests/test_panel_reachability.nim` fails for every new descriptor
- [x] 3.5 Add the `groupIds("bodies")` loop to `web-ui/src/components/Panel.tsx`. Verify:
      `tests/test_panel_reachability.nim` passes
- [x] 3.6 **Red first.** Write `docs/help/35-bodies.md` with the frontmatter and flat bullet shape of
      `docs/help/30-fluid.md`, one bullet per descriptor, deliberately omitting one. Verify:
      `tests/test_help_content.nim` fails naming the missing id. Then add the line, and a closing
      paragraph naming **anisotropy**, **envelope skew** and **sustain** in bold as the three a body
      is born with, the convention a help file uses for an id no descriptor resolves. Verify: the
      suite passes and does not treat the bold names as missing descriptors
- [x] 3.7 Carry the seven descriptor-backed settings through `src/preset.nim`: the record
      (`:104-155`), `defaultSettings` (`:214-288`), `validateSettings` (`:367` onward) and `toJson`
      (`:728-776`). Serialize none of the three ignition parameters — they have no stored value — and
      add no `LEGACY_MODE_COUPLINGS` row. Extend `tests/test_preset.nim` with the round trip and with
      the assertion that neither a body nor an ignition parameter appears in the serialized form.
      Verify: `tests/test_preset.nim` passes
- [x] 3.8 Read the strength in `couplingsOf` (`src/ui/state/sim_config.nim:43-57`) and add `bodies`
      to `WorldCouplings` (`src/sim_registry.nim:67-82`). Verify: `just happen` is green
- [ ] 3.9 `just happen` builds and `just check` is green

## 4. Layouts, buffers, and the generated WGSL structs

- [x] 4.1 **Red first.** Add `BodyLayout` and `BodyParamsLayout` to `src/gpu_types.nim` with one
      offset deliberately wrong, and add both to the static offset sweep at `:684-703`. Verify:
      `just happen` fails at the Nim compile naming the field. Then correct the offset. Verify: green
- [x] 4.2 Add the static assertion that `MAX_BODIES` does not exceed the `bodyIntegrate` workgroup
      size, with the `bodyIntegrate` entry added to `WorkgroupConfig` and `PRODUCTION_WORKGROUPS`
      (`src/shader_config.nim:19-34`, `:83-95`). Verify: `just happen` is green, and temporarily
      raising `MAX_BODIES` above that width turns the compile red
- [x] 4.3 Generate the WGSL struct modules from both layout tables through
      `generateStructModule` (`tools/wgsl_bundle.nim:245`), the way `SpeciesChemistryLayout` is
      generated. Verify: `just shaders` emits the modules and `just happen` is green with no
      hand-written struct in `web/shaders/modules/`
- [x] 4.4 **Red first.** Add `sbBodies`, `sbBodyEnvelope` and `sbBodyAccum` to `SimBuffer`
      (`src/sim_registry.nim:90-127`) without touching `byteLengthFor`. Verify: `just happen` fails
      on the non-exhaustive `case` at `src/webgpu_compute.nim:841-851`. Then add the three arms and
      the buffer creation. Verify: green
- [ ] 4.5 `just happen` builds and `just check` is green

## 5. The particle-side pass, end to end

At the end of this group a body ignited from the console pulls particles. Bodies do not yet move.

- [ ] 5.1 **Red first.** Extend `tests/coupling_space.nim` with a fifth level over
      `COUPLING_OFF` / `COUPLING_ON` (`:20-33`) and update the world-count assertion in
      `tests/test_shader_manifest.nim:40-42` from 16 to 32. Verify: the suites fail on the
      unregistered `bodyForce` key
- [ ] 5.2 Write `web/shaders/src/body-force.wgsl` as one thread per particle, in the shape of
      `web/shaders/src/field-force.wgsl`: read `particles[]` in original index space, loop over
      `MAX_BODIES` with an early-out on zero envelope, evaluate the SDF of design D3, apply the two
      forces of design D4 scaled by envelope and `bodiesStrength`, and `atomicAdd` into
      `velocityDeltaFixed`. Accumulate, never store. Verify: `just shaders` bundles it and
      `tests/test_wgsl_lint.nim` passes
- [ ] 5.3 Register the shader in `src/shader_manifest.nim` (`ShaderSpec` at `:21-30`, appended in
      `allShaderSpecs` at `:97-117`) and serve it from the `StaticFiles` table in `src/main.nim`
      (`:30-54`). Verify: `tests/test_shader_manifest.nim` passes — every dispatched key registered
      exactly once
- [ ] 5.4 Add the bind group: an `EXPECTED_BIND_GROUP_ENTRIES_BODY_FORCE` constant
      (`src/webgpu_compute.nim:45-58`), its arm in `getExpectedEntryCount` (`:60-76`), creation in
      `createBindGroups` (`:260` onward) ending in `validateBindGroupEntryCount` (`:204-211`), and
      the binding declaration in `src/wgsl_lint.nim`'s `ExpectedShaderBindings`. Verify:
      `tests/test_wgsl_lint.nim` passes and `getExpectedEntryCount` no longer returns -1 for the key
- [ ] 5.5 **Red first.** Add the `acts(couplings.bodies)` guard and the `Bodies` node with the
      `bodyForce` dispatch to `buildFrame` (`src/sim_registry.nim:341-352`), plus `sbBodyAccum`'s
      clear among the per-substep clears (`:258-266`), and add `bodies` to the strip list and the
      skip suite in `tests/test_sim_registry.nim` (`:100-168`). Verify: the registry suite passes and
      stripping the coupling-owned keys from all 32 worlds still leaves the intrinsic sequence
- [ ] 5.6 Add `bodies` to `sameFrameShape` (`src/webgpu_compute.nim:133-141`). Verify: writing the
      strength from zero to non-zero rebuilds the frame description; the native suite covers the
      zero-crossing relation
- [ ] 5.7 Wire the executor: create the three buffers, write `BodyParams` per frame beside the other
      uniform writes in `runPhysicsFrame` (`src/webgpu_compute.nim:723-764`), and upload the envelope
      array every frame regardless of strength (design D5). Verify: `just happen` is green
- [ ] 5.8 **Red first.** Extend `tests/test_body_core.nim`: an ignition carrying an anisotropy,
      envelope skew or sustain outside its `config_ranges` bound produces a body holding the nearest
      admissible value, and the clamp lives in the entry point so no caller repeats it. Verify: the
      tests fail. Then add `igniteBody` — the single Nim entry of design D11 in `src/body_core.nim`
      taking a world point and a `BodyShaping`, the method on `gardenAPI` (`src/web_api.nim:1167`,
      installed `:1405`), the declaration in `web-ui/src/garden-api.ts`, and the slot write into
      `sbBodies`. Verify: the tests pass, `just build-ui` typechecks, and removing the declaration
      from `garden-api.ts` turns `tsc --noEmit` red
- [ ] 5.9 `just happen` builds and `just check` is green

## 6. Feedback: the body is pushed and moves

Gated on group 2.

- [ ] 6.1 **Red first.** Extend `tests/test_sim_registry.nim` to assert the `Bodies` node carries two
      dispatches, `bodyForce` then `bodyIntegrate` at `dsOne`, and that `sbBodyAccum` is cleared by a
      frame node ahead of the pass that writes it and never cleared twice (suite at `:171-215`).
      Verify: the tests fail
- [ ] 6.2 Extend `web/shaders/src/body-force.wgsl` to accumulate the equal and opposite impulse and
      its torque, about the body's center over the toroidal minimum-image displacement, into
      `sbBodyAccum` with `atomicAdd` at the body scales of design D7. Verify: `just shaders` bundles
      and `tests/test_wgsl_lint.nim` passes
- [ ] 6.3 Write `web/shaders/src/body-integrate.wgsl` as one thread per body, applying the
      semi-implicit step of design D9 with the group 2 constants, the per-substep impulse cap, and
      the torus wrap. It reads and does not reset the accumulator. Verify: `just shaders` bundles it
- [ ] 6.4 Register and bind `bodyIntegrate` by the same four steps as 5.3 and 5.4, and add its
      dispatch to the `Bodies` node. Verify: 6.1 passes and `tests/test_shader_manifest.nim` still
      finds every dispatched key registered exactly once
- [ ] 6.5 `just happen` builds and `just check` is green

## 7. The canvas gesture

- [ ] 7.1 **Red first.** Add the modifier-held primary press to `src/ui/input/binding_table.nim` and
      its pure handler beside the existing ones in `src/ui/input/mouse_handler.nim`, with tests in
      `tests/test_input.nim`: the gesture resolves to an ignition at the converted world point, an
      unmodified press still reaches the live cursor, and the existing double-click and
      two-finger-tap blast bindings are untouched. Verify: the new tests fail, then pass
- [ ] 7.2 Wire the listener in `src/canvas_input.nim` beside the double-click handler (`:172-179`),
      converting to world space at capture through `pointerWorld`. Verify: `just happen` is green and
      the binding appears in the generated gesture reference the help panel serves
      (`openspec/specs/in-app-help/spec.md`, "The gesture and key reference is generated from the
      binding table")
- [ ] 7.3 `just happen` builds and `just check` is green

## 8. The world's own generator

Cuttable. Delete this group and groups 1 through 7 stand unchanged; the boundary and the gesture
remain the only ignition sources, `bodyIgnitionRate` leaves `src/config_ranges.nim`,
`src/ui/api/param_descriptor.nim`, `src/preset.nim` and the help file with it, leaving six
descriptors, and `igniteBody`'s callers supply their own shaping.

- [ ] 8.1 **Red first.** Extend `tests/test_body_core.nim` with the cadence and the draw: a rate of
      zero ignites nothing however long the clock runs; a non-zero rate ignites on schedule regardless
      of the `bodies` strength; a player's ignition restarts the phase rather than letting the next
      one fire immediately; and one seed replays the same sequence of positions and shapings twice,
      while two seeds differ. Verify: the tests fail
- [ ] 8.2 Add the cadence and the seeded sequence to `src/body_core.nim` per design D11 — one pure
      `uint64` state advanced per ignition, mapped onto the world rectangle and onto the shaping
      bounds, reading only its own rate and never the coupling strength. Verify: 8.1 passes, and
      `tests/test_no_modes.nim` stays green
- [ ] 8.3 Advance the phase from the frame loop in `src/app.nim` on capped wall-clock delta, beside
      the climate branch at `:266-269`, honoring that file's import-order landmine
      (`docs/enforcement.md`, Landmines). Verify: `just happen` is green
- [ ] 8.4 `just happen` builds and `just check` is green

## 9. In-app verification and the records

9.1 needs a person only for the browser connection; every observation after it is the agent's.

- [ ] 9.1 Confirm the Browser MCP tools are present and connected. If they are not, ask the user to
      start Chrome and connect Browser MCP, and start nothing until they confirm — `./main` exits
      with code 0 when no browser attaches (CLAUDE.md, Build and test). Touches no file
- [ ] 9.2 **Agent procedure.** `just happen`, launch `./main` in the background, poll
      `http://127.0.0.1:8089` for 200, navigate the connected tab there, and settle a population.
      Then: call `gardenAPI.igniteBody` at a point inside the crowd and observe particles gathering
      along a surface that is itself never drawn; raise enclosure and observe a crowd held; drive the
      gesture from group 7 and observe the same; watch one body fade in and out over its envelope.
      The observation that settles each is a screenshot pair before and after. A GPU validation error
      in the console from either new bind group fails this task — that pair is unenforced across the
      two sides (`docs/enforcement.md`, Two-sided agreements). Record the run in
      `scratchpad/parametric-bodies/in-app__<DD-MM-YY-HHmm>.md`. Kill the port 8089 listener
- [ ] 9.3 Read the bodies pass's cost from the stats panel during 9.2 at the full particle budget and
      record it in `docs/perf-report.md` beside the group 2 entry, against the 16.7 ms budget that
      file uses (`:134`). Verify: the entry states the particle count, the live body count, and the
      measured per-frame cost
- [ ] 9.4 Update `docs/one-world.md`: `bodies` in the four-strengths table (`:19-24`, now five), the
      body accumulator in the delta-buffer section (`:158-186`), and the generator beside the climate
      (`:305-318`). Correct the sentence at `:288` naming schema v2 — `CURRENT_SCHEMA_VERSION` is 4
      (`src/preset.nim:49`). Verify: the document names five strengths and no stale schema version
- [ ] 9.5 Update `docs/enforcement.md`: the coupling-floor row from four floors to five (`:49`),
      `body_core.nim` in the reference-oracle table (`:58-79`) naming both shaders, the new
      build-asserted guarantees (offsets, the workgroup ceiling, the accumulator's overflow bound),
      the test-held ones (the stability sweep, the tunnelling bound, help coverage), and one landmine:
      **the bodies skip at zero is exact only while bodies are invisible** — making a body observable
      by any route the strength does not scale makes the body-side integrate world-intrinsic. Verify:
      every new guarantee names its tier and every tier below test-held names what would raise it
- [ ] 9.6 `just happen` builds and `just check` is green
