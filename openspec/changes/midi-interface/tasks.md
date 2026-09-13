These tasks start on `main` at `16a3d56` plus the uncommitted audio work (the capture chain in
`src/audio_input.nim`, the pure core in `src/ui/input/audio_core.nim`, the metering push in
`src/web_api.nim`, and `web-ui/src/components/AudioSection.tsx`). `redesign-control-panel` is a
proposal on the `panel-redesign` branch only, so this tree carries no control catalog, no
`Toggle`/`Selector`/`Action` widgets, no catalog reachability sweep and no `70-presets.md`; where the
design or the specs assume them, these tasks build on the idioms `main` carries — a boolean control is
a `toggle-label` checkbox given `role="switch"` so `aria-checked` reads, a help key naming no
descriptor group goes in `ReservedHelpKeys`, a help file names an id in bold when no descriptor
resolves it, and `tests/test_panel_reachability.nim` holds the descriptor sweep plus the
climate-derivation suite and nothing else. Source anchors are named by symbol.

Nine places the design's assumptions and the tree disagree, with what these tasks do:

1. **No boolean descriptor exists.** `ParamKind` is `pkInt | pkFloat`
   (`src/ui/api/param_descriptor.nim`), and `climateDrift` and `forceWeather` are `SimulationState`
   booleans reached through `setClimateDriftImpl` and `setForceWeatherImpl`. A `Tour` row's gate
   therefore names a **gate id** declared with the tour, validated against the declared gate set, and
   read at flush time from a boolean the boundary supplies. The speed half stays a descriptor
   (`climateSpeed`, `forceWeatherSpeed`), validated as D2 says.
2. **No served action ids exist.** Nothing on this tree enumerates actions. `control_matrix.nim`
   gains an `ActionKind` enum with a pure `actionOf(id)` resolver, so a `Fire` row's action id
   validates natively and the boundary's dispatch is a `case` over the enum the compiler checks
   exhaustively — the build-assertion the design assumed a catalog would give.
3. **The shipped mapping lives in its own pure module.** D8 puts the default `const` in
   `control_matrix.nim`; these tasks put it in a new `src/ui/input/shipped_mapping.nim`, because the
   static gate needs the descriptor table, the MIDI source declarations and the tour declarations
   visible at once, and the `control-matrix` spec's own purpose line requires `control_matrix.nim` to
   stay family-blind.
4. **The pure flush returns an outcome the boundary applies.** `control_matrix.nim` cannot reach
   CONFIG, and D13 asks for native tests over what one flush consumes and produces, so the pure entry
   point takes a context and returns writes, excursions, actions and at most one blast; `web_api`
   applies them through the paths it already owns.
5. **`flushMatrix` takes the frame's capped wall-clock delta.** The contract writes
   `web_api.flushMatrix()`, but D2a's tour advance and D4's envelopes both need `cappedDt`
   (`src/app.nim`), so the entry point is `flushMatrix(dtSeconds: float)`.
6. **The flush sits after `pollAudioFrame`, not where the weather branches stood.** D6 puts the call
   where the two `if config.CONFIG.*` branches sit; audio's delivery must precede the flush in the
   same frame, so the call goes directly after `audio_input.pollAudioFrame(cappedDt)` and before
   `await physics(dt)`. Camera drift stays a loop branch (design Open Question 2) and writes no
   parameter, so nothing observable moves.
7. **Per-axis step ceilings travel on the tour declaration and stay test-held.** D2a and Open
   Question 2 speak of clamping each axis against `maxStepPerAxis`; the shipped tours respect those
   ceilings by construction and `tests/test_climate_core.nim` sweeps them, so no runtime clamp is
   added — it would be a mechanism with no consumer (principle 6).
8. **`climateParamIds` stays served.** D10 retires the two enumerated loops inside `pushStats` alone;
   `web-ui/src/state.ts` reads `climateParamIds` to light regime buttons and
   `tests/test_panel_reachability.nim` holds that derivation, both unchanged.
9. **Tour rows are ordinary rows whose source is `clock:frame`.** D2a's clock family delivers no
   value, since item 5 puts `cappedDt` in the flush context; `clock:frame` is declared so a `Tour`
   row resolves through the same declaration check as every other row. `DEFAULT_MAPPING` therefore
   carries thirteen rows: the eleven D8 lists plus the two weather `Tour` rows, ranked below the
   `Write` rows, and the `clock` family's one declaration ships beside the MIDI ones in
   `shipped_mapping.nim`. A `pkInt` tour axis writes the rounded point, as
   `setForceWeatherFromSimulation` rounds `interactionRadius` today. An enveloped value under
   `ENVELOPE_FLOOR` snaps to zero so a release ends. `positionStep` moves from `descriptorToJs` to
   `src/ui/api/slider_curve.nim` so the takeover math and the served handle granularity are one
   number.

The audio change's own registration is not here. Group 5 defines `registerSourceFamily`,
`setSourceValue`, `emitSourceEvent` and `flushMatrix` with the signatures audio-interface task 3.1
calls, so that task lands without a second matrix edit. The design's three Open Questions each state
they change nothing now, and no task below builds anything for them.

## 1. Prove the rig and gate Web MIDI

The proposal's measurement gate. Browser MCP drives the user's Chrome, not the webui-launched window,
and cannot press the browser's own permission prompt or type in a devtools console, so 1.2 and 1.3 are
the user's. They gate group 7 alone; groups 2 through 6 wait on nothing here.

- [ ] 1.1 Confirm the Browser MCP tools are present and connected. If they are not, ask the user to
      start Chrome and connect Browser MCP, and start nothing until they confirm. Touches no file
- [ ] 1.2 **Live gate.** Needs a person: the permission prompt and the webui window's console are
      both outside Browser MCP's reach. `just happen`, launch `./main` in the background, poll
      `http://127.0.0.1:8089` for 200, and navigate the connected tab there. Ask the user to run
      `typeof navigator.requestMIDIAccess` and then
      `navigator.requestMIDIAccess().then(a => console.log('[midi-gate] inputs=' + a.inputs.size)).catch(e => console.log('[midi-gate] refused ' + e.name))`
      in that tab's console, to answer the permission prompt, and to report what printed; read the
      same lines back through `browser_get_console_logs`. Then ask the user to run both lines in the
      webui-launched window and report, since that window is not the connected tab. Record both
      outcomes, and whether `http://127.0.0.1` counted as a secure context, in
      `scratchpad/midi-interface/midi-gate__<DD-MM-YY-HHmm>.md`. A refusal in the webui window lands
      the connect affordance in its unavailable state and changes no later task. Kill the port 8089
      listener
- [x] 1.3 Ask the user whether group 9 will have a MIDI source: hardware, or the macOS IAC driver plus
      a sender. Answered 2026-09-12: software only, the macOS IAC driver plus a sender page or
      sequencer, so every group 9 observation settles except the feel of a physical knob. Copy
      the answer into the gate file when 1.2 writes it. Blocks nothing
- [x] 1.4 `just happen` builds and `just check` is green

## 2. The row model, pure and natively tested

- [x] 2.1 **Red first.** Write `tests/test_control_matrix.nim` over a module that does not exist yet:
      registration by family id with whole-set replacement and one family's registration leaving
      another's alone; a row resolving against a declaration and an unresolved row keeping its place;
      the five validation relations of D2 against `buildParamDescriptors()` — continuous source for
      `Modulate`/`Write`, event source for `Fire`/`Touch`, `particleCount` and `speciesCount` refused
      as `Modulate` and `Write` targets, a `Modulate` target confined to `psSimulation`/`psRender`
      while a `Write` row accepts the same palette or camera id, and a `Tour` row naming a registered
      tour id, a declared gate id and a speed descriptor whose range excludes negative values; a
      `Fire` row naming an action id `actionOf` does not resolve is refused. Add the import and the
      `CONTROL_MATRIX_TESTS_LOADED` discard to `tests/test_all.nim`. Run
      `nim c -r tests/test_control_matrix.nim` and confirm it fails to compile for want of the module
- [x] 2.2 Write `src/ui/input/control_matrix.nim`, pure on both backends in the style of
      `src/ui/input/audio_core.nim` and `src/preset.nim`: `SourceKind` (`skContinuous`, `skEvent`),
      `SourceDeclaration(id, label: string; kind: SourceKind)`, `RowKind` and the `ControlRow` object
      variant exactly as D2 declares it (`tourRank` on the tour branch, `rank` on the write branch,
      for the reason D2 states), `TourDeclaration(tourId, axisParamIds, gateId, pointAt,
      maxStepPerAxis)`, `ActionKind` with `actionOf(id): tuple[found: bool, kind: ActionKind, payload:
      string]` resolving the six `RD_REGIMES` ids under a `regime:` prefix plus the momentary and
      toggle actions the boundary serves (`src/web_api.nim:1164-1295`), `MatrixState`, family
      registration, tour registration, and `validateRow`. The module imports no family module and no
      FFI. Run `nim c -r tests/test_control_matrix.nim` green
- [x] 2.3 **Red first.** Extend `tests/test_control_matrix.nim` with delivery: a sweep collapsing to
      its latest value per source id, a value outside [0, 1] clamped at the entry point, events
      draining in arrival order, and ordinal zero from a source with no ordinal space. Confirm red,
      then add `setSourceValue`, `emitSourceEvent` and the staging tables to
      `src/ui/input/control_matrix.nim` and run green
- [x] 2.4 Add the `test_control_matrix.nim` row to the file table and the architecture tree in
      `tests/README.md`. Verify by reading the table
- [x] 2.5 `just happen` builds and `just check` is green

## 3. Arbitration, envelopes, takeover and the pure flush

- [x] 3.1 **Red first.** Extend `tests/test_control_matrix.nim` over a `flushMatrix(state, ctx)` that
      does not exist yet, where `ctx` carries the frame's wall-clock delta, each targeted parameter's
      descriptor, stored value and live ceiling, and each registered tour's gate boolean and speed
      value, and the outcome carries writes by parameter id, signed travel excursions by parameter id,
      resolved actions, and at most one blast: two `Modulate` rows on one parameter summing in travel
      space against real descriptors; an offset carrying travel past either end landing on the end
      value under the live ceiling; zero depth inert; the frame after the last excursion re-mirroring
      the base and the frame after that writing nothing; attack and release convergence on a rising
      and a falling source, and the same signal at 8.33 ms and 16.7 ms deltas spanning the same
      wall-clock constant; `Write` travel-to-value against real descriptors with no ceiling bound.
      Run and confirm it fails for want of the entry point
- [x] 3.2 Add the modulate and write arms to `src/ui/input/control_matrix.nim`: base travel from
      `positionOf`, the summed depth-times-enveloped-value offset, the effective value from `valueAt`
      with the live ceiling as `boundMax` where the bound is derived (`src/ui/api/slider_curve.nim`),
      and the exponential envelope per row with a zero constant passing the raw value on its side.
      Run `nim c -r tests/test_control_matrix.nim` green
- [x] 3.3 **Red first.** Extend the suite with takeover and rank: a resting soft-takeover row moving
      nothing, engagement by crossing and by landing within one `positionStep`
      (`src/ui/api/slider_curve.nim`), disengagement across a
      slider move, a preset apply and another row's write, an engaged row's own writes not releasing
      it, `jump` writing immediately, two engaged `Write` rows applying in ascending rank, a `Tour`
      row yielding to a higher-ranked `Write` row on one axis while its other axes take the tour's,
      and a quiet frame carrying no ownership forward. Confirm red, then add per-row takeover state
      and the ascending-rank apply order to `control_matrix.nim` and run green
- [x] 3.4 **Red first.** Extend the suite with tours, fires and touches: a running `Tour` row
      advancing its own phase on the context's wall-clock delta scaled by its speed and writing every
      axis of `pointAt(phase)` in one batch, a `pkInt` axis rounded to the nearest integer; a false
      gate freezing the phase and writing nothing; two
      rows keeping separate phases; a `Fire` row running on its ordinal and not on another, two
      different actions in one frame both running, several regime selections in one frame collapsing
      to the last; `Touch` cell indexing row-major from the bottom left, an ordinal outside the grid
      discarded, magnitude scaling strength, the later of two touches in one frame winning; and an
      idle frame producing an empty outcome. Confirm red, then add the tour, fire and touch arms and
      run green
- [x] 3.5 `just happen` builds and `just check` is green

## 4. The mapping document, its schema and the shipped default

- [x] 4.1 **Red first.** Extend `tests/test_control_matrix.nim` with the schema relations, in
      `tests/test_preset.nim`'s image: round-trip stability, one structurally malformed row dropped
      while the rest load, a depth outside [-1, 1] clamped, a document declaring a newer version
      refused whole, a row naming an undeclared source loading and reporting unresolved, an exported
      document applying back to an equal mapping row for row, and the mapping storage key differing
      from every key `presetKeys` serves (`src/ui/presets/preset_store_core.nim`, pinned the way
      `tests/test_preset_store_core.nim:71-73` pins its own). Confirm red
- [x] 4.2 Add the versioned schema to `src/ui/input/control_matrix.nim` following
      `src/preset.nim:49-68` and `src/preset.nim:567-673`: `MATRIX_SCHEMA_VERSION = 1`, validate-first
      decode that drops malformed rows and clamps out-of-range fields, one rejection for a newer
      version, a fall-through `migrate` awaiting its first branch, `toDocumentText` /
      `parseDocument`, and `MAPPING_STORAGE_KEY`. Run `nim c -r tests/test_control_matrix.nim` green
- [x] 4.3 Write `src/ui/input/shipped_mapping.nim`, pure, importing `control_matrix`,
      `param_descriptor`, `climate_core` and `config_ranges`: `SHIPPED_MIDI_SOURCES` declaring
      `midi:cc:1:7`, `midi:cc:1:1`, `midi:cc:1:74`, `midi:cc:1:71`, `midi:pc:1`, `midi:notes:1` and
      `midi:clock` with their kinds and labels; `SHIPPED_CLOCK_SOURCES` declaring `clock:frame`
      continuous; `DEFAULT_MAPPING` holding the four soft-takeover
      `Write` rows onto `forceStrength`, `fluidStrength`, `rdFieldForce` and `rdDeposit`, six `Fire`
      rows on `midi:pc:1` ordinals 0 through 5 selecting the `RD_REGIMES` ids in table order, one
      `Touch` row laying a 4 by 4 grid on `midi:notes:1` from base note 36, and two `Tour` rows on
      `clock:frame` for the climate and the force weather, gated by `climateDrift` and `forceWeather`
      with speeds `climateSpeed` and `forceWeatherSpeed`, their `tourRank` below every write row's
      `rank` and no toggle mapped; and the tour declarations for the two weathers built from
      `CLIMATE_PARAM_IDS`, `FORCE_WEATHER_PARAM_IDS`, `RD_CLIMATE_TOUR`, `FORCE_WEATHER_TOUR`,
      `CLIMATE_MAX_STEPS` and `FORCE_WEATHER_MAX_STEPS`. Verify `nim c -r tests/test_all.nim`
- [x] 4.4 Add the static gate to `src/ui/input/shipped_mapping.nim`: a `static:` block asserting every
      `DEFAULT_MAPPING` row validates against `buildParamDescriptors()`, `SHIPPED_MIDI_SOURCES` and
      the two tour declarations, in the style of the descriptor table's own compile-time gates.
      **Watch it fail:** point one shipped row at a parameter id nothing serves, confirm `just test`
      stops at the Nim compile step naming that row, then restore. Record the observed message in the
      task notes. Observed 2026-09-12 with row 1's `writeParamId` set to `nothingServesThisId`:
      `Error: unhandled exception: src/ui/input/shipped_mapping.nim(169, 5) `verdict.ok` shipped
      mapping row 1 (rkWrite on midi:cc:1:1 -> nothingServesThisId) fails validation: no descriptor
      serves the parameter id nothingServesThisId [AssertionDefect]`; restored, `nim c
      tests/test_all.nim` ends `[SuccessX]`
- [x] 4.5 **Red first.** Extend `tests/test_control_matrix.nim`: the default mapping validates, an
      empty store loads it, a refused document loads it, and a document that decodes keeps it out.
      Confirm red against a matrix with no default loading, then add the fall-back load to
      `control_matrix.nim` and run green
- [x] 4.6 `just happen` builds and `just check` is green

## 5. The boundary: registration, delivery, flush and the widened push

The four entry points this group adds are the ones `openspec/changes/audio-interface/tasks.md` task
3.1 calls. Their names and signatures are fixed here and change in no later task.

- [x] 5.1 In `src/web_api.nim` hold the live `MatrixState` and add the contract's entry points:
      `registerSourceFamily(familyId: string; declarations: openArray[SourceDeclaration])` replacing
      that family's set whole and leaving every other family's alone, `setSourceValue(sourceId:
      string; value: float)` clamping into [0, 1], and `emitSourceEvent(sourceId: string; magnitude:
      float; ordinal: int)` queueing in arrival order. Register the two tour declarations and the
      `clock` family from `shipped_mapping` at module scope and load `DEFAULT_MAPPING` there. The
      targeted descriptors resolve through `paramsById` at flush time rather than once at module
      scope as `climateDescriptors` did: the mapping is edited at runtime, so the targeted set is
      not fixed at init, and the set of written ids (`writtenParamIds`) is rebuilt on every mapping
      change. Verify `just build-app`
- [x] 5.2 In `src/web_api.nim` add `flushMatrix(dtSeconds: float)`: build the context from
      `currentSimulation`, `currentRender`, `paramsById`, `ceilingInputs`/`evaluateCeiling` and the two
      gate booleans (`CONFIG.climateDrift`, `CONFIG.forceWeather`) with their speeds, call the pure
      flush, then apply the outcome — simulation-store writes in one `updateSimulation`, render-store
      writes in one `updateRender`, any palette or camera target through `setParamImpl`, and the
      modulated copy mirrored through `applySimulationToConfig`'s one effect-time clamp site so
      `currentSimulation` is never written (`src/web_api.nim:136-161`). Verify `just build-app` and,
      by reading, that no second effect-time clamp site appears
      - 2026-09-12: as implemented, the context read its base through `getParamImpl`, which fell
        through to `CONFIG[]` for every id outside four arms and so carried the previous frame's
        modulated value, ratcheting every Modulate row to its ceiling. Corrected: `paramContextOf`
        builds the two record stores through `storedContext(descriptor, currentSimulation,
        currentRender)`, and `getParamImpl` itself reads `storedParamValue`.
- [x] 5.3 In `src/web_api.nim` add the action and gesture arms of the flush: a `case` over
      `ActionKind` dispatching to `applyRegimeImpl`, `randomizeMatrix`, `triggerParticleReinit`,
      `triggerFieldReseed`, `setTrailsImpl`, `setBloomImpl`, `setClimateDriftImpl`,
      `setForceWeatherImpl` and `setCameraDriftImpl`, exhaustive by the enum so a kind without an arm
      fails the compile; and the blast, placed through a new
      `canvas_input.placeBlastAtViewFraction(u, v, strength)` that converts the cell centre through
      the live camera at capture exactly as `pointerWorld` does (`src/canvas_input.nim:152-153`).
      Widen `withBlast` in `src/ui/state/input_state.nim` with a strength argument, callers passing
      1.0. Verify `nim c -r tests/test_input.nim` green and `just build-app`
- [x] 5.4 In `src/web_api.nim` serve the mapping surface on `gardenAPI`: the active mapping's rows
      each carrying kind, source id, the fields of that kind, target, rank where the kind has one and
      whether the source resolves; the declared sources of every registered family with kind and
      label; `DEFAULT_MAPPING`; a row edit and a rank edit that validate and answer a refusal without
      changing the mapping; `armLearn(rowSpec)`, `cancelLearn()` and a synchronous learn-state read;
      `matrixKeys()` serving the storage key; and `exportMappingJson()` / `applyMappingJson(text)`
      answering the `{ok, error}` shape `applyPresetJson` answers (`src/web_api.nim:1390-1403`).
      Declare every one of them in `web-ui/src/garden-api.ts`. Verify `just build-app` and
      `just build-ui`
- [x] 5.5 In `src/ui/input/control_matrix.nim` add learn: arming captures the set of continuous
      sources that delivered in the frame before the arm and excludes them from that arming, the next
      qualifying delivery per slot kind completes the row, the binding delivery is suppressed from
      ordinary effect, and there is no timeout. Cover it in `tests/test_control_matrix.nim` — one test
      per scenario of the spec's learn requirement — watching each fail first. Run green
- [x] 5.6 In `src/web_api.nim` add the `excursions` record to `pushStats` beside `ceilings`: the
      signed travel offset of every parameter a live excursion moves, empty when none. Declare it on
      `StatsSample` in `web-ui/src/garden-api.ts` and apply it by comparison into a new store in
      `web-ui/src/state.ts` beside `ceilings` (`web-ui/src/state.ts:118-124`). The `params` record
      keeps its two enumerated loops until task 6.4 replaces them, so no push loses an id between
      groups. Verify `just build-app`, `just build-ui`
- [x] 5.7 In `src/app.nim` call `web_api.flushMatrix(cappedDt)` directly after
      `audio_input.pollAudioFrame(cappedDt)` and before `await physics(dt)`. Verify `just build-app`,
      and by reading the loop that audio's delivery precedes the flush and the flush precedes physics
- [x] 5.8 `just happen` builds and `just check` is green

## 6. The weathers become tours

- [x] 6.1 **Red first.** Add a suite to `tests/test_control_matrix.nim` that reads `src/app.nim` from
      disk, following `tests/test_no_modes.nim:34`'s shape including its own vacuity guard (the file
      exists and is non-empty, and the predicate finds a string that is there and misses one that is
      not, so `tests/test_meta_vacuity.nim` is satisfied): the frame loop names no parameter writer
      but `flushMatrix`. Run `nim c -r tests/test_control_matrix.nim` and confirm it fails naming
      `setClimateFromSimulation` and `setForceWeatherFromSimulation`
- [x] 6.2 In `src/app.nim` delete the two `if config.CONFIG.climateDrift` / `forceWeather` branches
      and the `climatePhase` and `forceWeatherPhase` variables with their doc comments, leaving the
      camera-drift branch and its comment untouched. Run the 6.1 suite green and
      `nim c -r tests/test_climate_core.nim` green, unchanged in what it asserts
- [x] 6.3 In `src/web_api.nim` delete `setClimateFromSimulation`, `setForceWeatherFromSimulation` and
      the two module-scope descriptor arrays they resolved, now that the flush clamps and batches
      every tour axis. Verify `just build-app` and that nothing else in the tree references either
      name (`grep -rn`)
- [x] 6.4 In `src/web_api.nim` replace the two enumerated loops in `pushStats`
      (`src/web_api.nim:866-871`) with the derived set: every `Write` row target plus every axis of
      every `Tour` row's registered tour, rebuilt on mapping edit, sent on every push whatever moved
      them. Leave `climateParamIds` and `forceWeatherParamIds` served, since `web-ui/src/state.ts`
      lights regime buttons off the first. Verify `nim c -r tests/test_panel_reachability.nim` green
      and `just build-app`
- [x] 6.5 In `docs/enforcement.md` change the "Weather tours and their step ceilings" home row to name
      `src/climate_core.nim` for the tables and `src/ui/input/shipped_mapping.nim` for their
      registration. Verify by reading the table
- [x] 6.6 `just happen` builds and `just check` is green

## 7. The MIDI family: transport, core and wiring

Gated by task 1.2. If the gate recorded a refusal, 7.4's affordance reports MIDI unavailable and the
rest of this group is unchanged.

- [x] 7.1 **Red first.** Write `tests/test_midi_core.nim`: a control-change triple parsing to channel,
      number and value; a one-byte 0xF8 parsing as clock; a status naming none of the eight consumed
      messages rejected with no delivery; a control change normalizing to value over 127 on
      `midi:cc:<channel>:<number>`; a note on delivering an event on `midi:notes:<channel>` with the
      note as ordinal and velocity over 127 as magnitude; a note off and a note on at velocity 0 both
      delivering nothing; a program change delivering ordinal and magnitude 1.0 on
      `midi:pc:<channel>`; the same control number on two channels holding two source ids; and the
      clock count across start, continue and stop, where a start then 25 pulses gives ordinals 0, 1
      through 23, 0, pulses after a stop deliver nothing, and a stream with no start counts from its
      first pulse. Add the import and the `MIDI_CORE_TESTS_LOADED` discard to `tests/test_all.nim`.
      Run `nim c -r tests/test_midi_core.nim` and confirm it fails to compile for want of the module
- [x] 7.2 Write `src/ui/input/midi_core.nim`, pure on both backends and importing no transport:
      the typed message enum, `parseMessage(bytes)` over three-byte and one-byte inputs, the clock
      counter state, and normalization into the deliveries D3 fixes. Run
      `nim c -r tests/test_midi_core.nim` green, then add the `test_midi_core.nim` row to
      `tests/README.md`'s file table and architecture tree
- [x] 7.3 Write `src/bindings/web_midi.nim` in the style of `src/bindings/web_audio.nim`:
      `navigator.requestMIDIAccess`, input port enumeration and iteration, each port's id and name,
      `onmidimessage` with its `data` array, and `onstatechange`. Verified by the build, never mocked.
      Verify `just build-app` compiles
- [x] 7.4 Write `src/midi_input.nim` (layer 3, imported in `src/app.nim` after `audio_input`) beside
      `src/audio_input.nim`: a connect affordance that requests access only when called, states for
      disconnected, requesting, connected and unavailable, subscription of every input port, hot-plug
      followed through `onstatechange` with removal leaving the mapping alone, raw messages fed to
      `midi_core` and delivered through `web_api.setSourceValue` and `web_api.emitSourceEvent` alone,
      and registration of `shipped_mapping.SHIPPED_MIDI_SOURCES` with re-registration
      of the grown set the first time an undeclared control sends. Register the declarations and the
      connect hooks with `web_api` from an exported `wireMidiControl()` that `src/app.nim` calls
      first in `init`, not at module init as `registerAudioControl` does: an import used only for
      its module-init effect fails the build's `UnusedImport` gate, and `audio_input` escapes it
      only because the loop calls its poll. Expose connect, disconnect and
      the state read on `gardenAPI`, typed in `web-ui/src/garden-api.ts`. Verify `just build-app` and
      `just build-ui`
- [x] 7.5 In `docs/enforcement.md` add `src/ui/input/control_matrix.nim` and
      `src/ui/input/shipped_mapping.nim` to "Where authority lives", and guarantee rows for: every
      shipped mapping row validating against the descriptor table and the declared sources
      (Build-asserted, the static gate in `shipped_mapping.nim`); arbitration, takeover and envelopes
      (Test-held, `tests/test_control_matrix.nim`); the flush being the frame's only parameter writer
      (Test-held for the source sweep, `tests/test_control_matrix.nim`); MIDI transport acquisition
      and hot-plug (Unenforced, review against `src/midi_input.nim` and the gate record from 1.2);
      the preset snapshot reading stored state for every modulated field (Unenforced, review at
      `snapshotPreset`, raised by a round-trip test over a modulated field). Verify by reading the
      tables
- [x] 7.6 `just happen` builds and `just check` is green

## 8. The panel's mapping editor, shading and help

- [x] 8.1 **Red first.** Write `web-ui/test/mapping-editor.test.ts` over a pure helper
      `web-ui/src/lib/mapping-editor.ts`: which served rows collide on one target so the editor
      exposes rank exactly there, a one-line summary per row kind built from served fields alone, and
      an unresolved row marked from its served resolution flag. Run `just test-ui`, confirm it fails,
      then write the helper and run green
- [x] 8.2 **Red first.** Add an excursion case to `web-ui/test/bounds.test.ts` over a helper in
      `web-ui/src/lib/bounds.ts`: a signed travel offset becomes the shaded span from the handle's
      base, clamped to the track at both ends, and a zero offset shades nothing. Run `just test-ui`,
      confirm it fails, then write the helper and run green
- [x] 8.3 In `web-ui/src/components/ParamSlider.tsx` shade the live excursion from
      `ctrl.excursions[props.id]` through the 8.2 helper, beside the derived-ceiling shading it
      already draws (`ParamSlider.tsx:55-68`), with its own class in `web-ui/src/ui.css` whose
      transition the existing `prefers-reduced-motion` block disables. Verify `just build-ui` and
      `nim c -r tests/test_panel_reachability.nim` green
- [x] 8.4 Write `web-ui/src/components/MidiSection.tsx`: a connect control as a `toggle-label`
      checkbox with `role="switch"` reporting the served state, the served rows rendered through the
      8.1 helper with rank shown where rows collide, "map this control" arming learn and a cancel,
      row edits routed through the boundary with its refusal shown, and export and import of the
      mapping document text, persisted in localStorage under `matrixKeys()`'s served key with no key
      composed on this side. Every string a user reads calls a row a **mapping**; the word matrix
      stays the species force matrix (D11). Place `<Section title="MIDI">` in
      `web-ui/src/components/Panel.tsx` after Palette and before Audio. Verify `just build-ui` and
      `nim c -r tests/test_panel_reachability.nim` green
- [x] 8.5 **Red first.** Add the D12 relation to `tests/test_help_content.nim`: the MIDI help file
      exists, and its body contains every `DEFAULT_MAPPING` row's target — descriptor ids for the four
      `Write` rows, action ids for the six `Fire` rows, the source id for the `Touch` row, the tour
      ids for the two `Tour` rows. Add `"midi"`
      to `ReservedHelpKeys` in `src/ui/api/help_content.nim` and `"70-midi.md"` to `HelpFileNames`
      between `65-audio.md` and `90-glossary.md`; run `nim c -r tests/test_help_content.nim` and
      confirm it fails naming the missing file
- [x] 8.6 Write `docs/help/70-midi.md` with the front matter `group: midi`: what connecting does and
      that the browser asks once, what a mapping is, the four knobs the app ships mapped and what each
      moves, the program buttons and the pad grid, learn, soft takeover and why a knob waits, and how
      to hand a mapping to another player. Write every action id and source id in **bold**, the form
      `bindingReferenceBody` uses, since `namedControlIds` reads only code-span lines and those ids
      resolve to no descriptor. Run `nim c -r tests/test_help_content.nim` green
- [x] 8.7 `just happen` builds and `just check` is green

## 9. Live verification

Each task names the agent procedure and the observation that settles it: Browser MCP against the
user's Chrome, `./main` in the background, the port killed at the end. The permission click is the
user's, for the reason group 1 states, and 9.3 through 9.7 need the MIDI source task 1.3 asked about.

- [ ] 9.1 `just happen`, launch `./main` in the background, poll the port, navigate the connected tab
      and snapshot the MIDI section: a switch with `aria-checked` false, the state reading
      disconnected, the thirteen shipped rows listed with their targets, every one resolved before any
      hardware has spoken, and no row marked unresolved
- [ ] 9.2 Press connect and ask the user to allow the prompt. Snapshot: the state reads connected and
      the section lists the input ports. Ask the user to unplug and replug the device, or to toggle the
      IAC port, and confirm through a snapshot that the rows keep their place across both
- [ ] 9.3 Move the controller's volume knob: Force Strength stays put until the incoming travel
      crosses the slider's current travel, then follows it. Drag the slider away by more than one
      position step and confirm the knob stops writing until it crosses again. Apply a preset
      mid-engagement and confirm the same release. Record in
      `scratchpad/midi-interface/live-takeover__<DD-MM-YY-HHmm>.md`
- [ ] 9.4 Send program changes 0 through 5: the regime buttons light in `RD_REGIMES` order and feed and
      kill move to each point. Press pads from base note 36 upward: a blast lands at each cell of the
      4 by 4 grid over the visible view, a hard hit is visibly stronger than a soft one, and an ordinal
      outside the grid places nothing. Pan and zoom the camera and confirm the same pad lands at that
      cell's new place
- [ ] 9.5 Arm learn on a `Write` slot, move an unmapped knob: the row binds to that knob and the
      parameter does not move from the binding delivery. Cancel an arming and confirm no row changed.
      With Listen on from the Audio section, arm learn again and confirm the streaming audio sources do
      not bind
- [ ] 9.6 Through the editor, add a `Modulate` row on `fluidStrength` at depth 0.4 from a knob. Hold
      the knob up: the slider shades its excursion from the handle's base on successive pushes while
      the handle itself does not move, and an exported preset carries the stored value. Release: the
      world returns to the base on the next frame and `excursions` arrives empty
- [ ] 9.7 Switch Weather and Force Weather on: the toured sliders move at their shipped speeds, each
      weather holds its own position when the other is switched on, and the world looks as it did
      before this change. With a `Write` row engaged on `forceStrength`, confirm the hand wins that
      axis while the tour keeps moving its others, and that releasing the row returns the axis to the
      tour's phase
- [ ] 9.8 Edit a row, reload the page, and confirm the edited mapping loads from storage. Export the
      document, apply the text back, and confirm the mapping is unchanged row for row. Save a preset
      and confirm nothing under the mapping key changed. Open help on the MIDI section and confirm
      `70-midi.md` is served
- [ ] 9.9 Kill the port 8089 listener; `just happen` builds and `just check` is green on a clean tree
