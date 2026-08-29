# midi-interface design

## Context

See proposal.md for motivation and scope. The mechanics this design builds on, each proven in the running code and its suites:

- One write path clamps every mutation against the descriptor table (`clampParamValue`, `src/ui/api/param_descriptor.nim:719`) and mirrors typed state into `CONFIG` synchronously (`src/web_api.nim:165-178`). The effect-time clamp lives at exactly one site: `applySimulationToConfig` mirrors `effectiveSimulation(storedState)` while `currentSimulation`, `getParam`, and presets keep the stored value (`src/web_api.nim:135-160`, `src/ui/api/param_descriptor.nim:303-320`).
- The weathers are the outside-writer precedent: the frame loop writes whole tour points through the clamped path, one batched `updateSimulation` per weather per frame (`src/app.nim:257-269`, `src/web_api.nim:713-736`), with descriptors resolved once at module scope (`src/web_api.nim:707-711`).
- `slider_curve.valueAt` and `positionOf` map travel in [0, 1] to lattice values and back, honoring curve, envelope, and any served ceiling (`src/ui/api/slider_curve.nim:25-74`, held inverse by `tests/test_slider_curve.nim`).
- The stats push runs on the loop's FPS-refresh cadence, roughly twice a second (`src/app.nim:284-317`). It sends the two weather id tables' current values on every push and the live ceilings beside them (`src/web_api.nim:805-848`), and the panel applies whatever ids arrive by comparison (`web-ui/src/state.ts:108-119`).
- The preset schema is the versioned-persistence precedent: pure module, validate-first decode, fall-through `migrate`, one rejection for a newer version (`src/preset.nim:49-68`, `src/preset.nim:567-673`), with the panel owning localStorage under keys Nim serves (`src/web_api.nim:1301-1311`).
- Input follows the pure-core-plus-wiring pattern: bindings declared as data (`src/ui/input/binding_table.nim:1-6`), pure handlers natively tested (`tests/test_input.nim`), JS listeners in `canvas_input`. A blast converts to world space at capture (`src/canvas_input.nim:152-153`), decays per frame (`src/canvas_input.nim:70`), and `withBlast` pins strength at 1.0 (`src/ui/state/input_state.nim:60`).
- `commitParamImpl` gives exactly two parameters a release side effect: `particleCount` resizes and `speciesCount` reinitializes (`src/web_api.nim:767-780`).

Everything below the Decisions heading is designed and unexercised until its tests and the transport spike run. The proposal's measurement gate (Web MIDI inside the webui-launched window) precedes transport work.

## Goals / Non-Goals

**Goals:**

- Define the control matrix precisely enough that the audio-interface designer builds against the Matrix interface contract section without reading the rest.
- Keep every matrix decision family-blind, so a second source family registers without touching matrix code.
- Reuse the proven mechanics above rather than adding parallel paths: one clamp authority, one mirror, one travel mapping, one push channel.

**Non-Goals:**

- Audio capture and feature derivation (the sibling change designs them).
- The outbound half of any mapping. Rows name no direction, and nothing here builds a sender.
- A mapping library with named saved matrices. One stored user matrix ships. The schema leaves room (a later version wraps the matrix in a named list), and building the library waits for a consumer.

## Decisions

### D1. Module layout

Four new homes, split on the tested pattern of pure core beside JS wiring:

- `src/ui/input/midi_core.nim`: pure. Parses raw MIDI byte triples into typed events (control change, note on, note off, program change), rejecting malformed input at the boundary. Natively tested.
- `src/ui/input/control_matrix.nim`: pure. The row model, validation, arbitration, takeover state, excursion computation, schema serialization. Compiles on both backends like `preset.nim`. Natively tested.
- `src/bindings/web_midi.nim`: FFI to `navigator.requestMIDIAccess`, input port enumeration, `onmidimessage`, `onstatechange`. Verified by the build, never mocked.
- `src/midi_input.nim`: JS wiring beside `canvas_input`. Subscribes ports, feeds `midi_core`, stages normalized values and events for the per-frame flush.

`web_api.nim` gains the matrix surface (rows read, row edit, rank edit, learn), the flush entry the frame loop calls, and the widened push. `src/app.nim` adds one import in layer 3 and one call in the loop.

Rejected: a single MIDI module holding parse, matrix, and wiring together. The pure halves would then import FFI transitively and lose native testability, the property the `key_handler` pattern exists to keep.

Rejected: the matrix model inside `web_api.nim`. That file is the boundary, compiled only for JS. Arbitration and takeover need native tests.

### D2. The row model

Row-kind legality is typed. Source legality is validated against a registry.

```nim
type
  RowKind* = enum rkModulate, rkWrite, rkFire, rkTouch
  ControlRow* = object
    sourceId*: string          ## resolved against the source registry
    case kind*: RowKind
    of rkModulate:
      modParamId*: string
      depth*: float            ## [-1, 1]; 0 is ordinary and inert
      slewMs*: float
    of rkWrite:
      writeParamId*: string
      jump*: bool              ## false = soft takeover
      rank*: int               ## collision order among Write rows on one id
    of rkFire:
      actionId*: string        ## one of the served action ids
      ordinal*: int            ## which event in the source's ordinal space fires it
    of rkTouch:
      gridCols*, gridRows*: int  ## pad grid laid over the visible view
      baseNote*: int
```

A source id is an opaque string a family mints and prefixes with its family id, for example `midi:cc:1:74` or `midi:notes:1`. Each family registers its sources with a declared kind, continuous or event. Validation holds four relations: a Modulate or Write row names a continuous source and a served descriptor id, a Fire or Touch row names an event source, an action id is one the boundary serves, and `particleCount` and `speciesCount` are rejected as Modulate and Write targets because their effects ride the release side effect a matrix write never produces (`src/web_api.nim:767-780`). Modulate targets are further restricted to the two record stores, `psSimulation` and `psRender`, whose field walks the overlay in D4 reuses. Write targets may name anything `setParam` serves.

Validation separates malformed from unresolved. A structurally malformed row drops at decode (D8). A well-formed row whose source id matches no current declaration keeps its place, sits inert at flush, and shows as unresolved in the editor, since families may declare sources lazily and a stored mapping must survive a session where its device or sibling family is absent. For a continuous row this inertness equals its behavior before first delivery, so nothing downstream branches on it.

Rejected: a typed source variant enumerating families (`MidiCC(channel, cc) | Feature(id)`). It makes source legality compile-checked, and it makes the audio family a matrix edit, which the sibling proposal promises not to need. The registry is the smart constructor guarding what the type no longer can: rows only exist validated, and a source id no declaration covers surfaces as an unresolved row rather than a silent drop.

Rejected: separate row lists per kind (four arrays). The editor, persistence, rank, and learn all speak in one ordered list of rows. Four lists move the invariant into every consumer.

### D3. Source normalization

A family delivers continuous sources as the latest value in [0, 1] per source id, and event sources as (source id, magnitude in [0, 1], ordinal) in arrival order, where the ordinal locates the event inside the source's own space and a source with no such space sends zero. For MIDI: CC value divides by 127 on `midi:cc:<channel>:<number>`, note-on delivers on `midi:notes:<channel>` with the note number as ordinal and velocity over 127 as magnitude, note-off is dropped unless a future row kind consumes it, a note-on carrying velocity 0 is a note-off under the MIDI 1.0 specification (https://musicproductionwiki.com/bible/velocity) and drops with it, and program change delivers on `midi:pc:<channel>` with the program number as ordinal and magnitude 1.0. All channels are listened to, and the channel lives inside the source id, so channel filtering is a mapping choice rather than a device setting.

MIDI declares in two moments. The shipped mapping's source ids are compile-time constants declared at wiring time, which is the declaration set D8's static gate validates the shipped rows against, and which keeps a shipped row resolved before any hardware has spoken. Every other control declares the first time it sends, re-registering the family with the grown set under the contract's replace-on-re-registration rule. The editor's source list therefore carries the shipped ids plus the vocabulary the connected hardware has actually used, and a stored row naming neither stays unresolved and visible.

Rejected: normalization inside the matrix. The matrix would then know each family's wire format, and a second family would touch matrix code.

Rejected: one source id per note. A Touch grid would then span a range of opaque ids the matrix cannot enumerate without learning the family's id grammar, and the ordinal keeps ids opaque while giving Fire and Touch rows a number to select on.

### D4. The Modulate arm

An excursion moves the handle, in travel space, through the same curve a hand moves it.

Per mapped parameter each frame: base travel = `positionOf(descriptor, storedValue)`, offset = sum over that parameter's Modulate rows of `depth * slewedSourceValue`, effective value = `valueAt(descriptor, clamp(base + offset, 0, 1), boundMax = live ceiling where derived)`. Summing in travel space makes collisions add like hands on one handle, and `valueAt` lands the result on the lattice and under the ceiling with no second clamp path (`src/ui/api/slider_curve.nim:42-58`).

Application reuses the one clamp site. The flush builds a modulated copy of the stored state, assigns each effective value through the same compile-checked field walk `setParam` uses, and hands the copy to the existing mirror: `mirrorInto(effectiveSimulation(modulatedCopy), CONFIG[])` for simulation targets, the render mirror for render targets. `currentSimulation` is never written, so `getParam`, presets, and the slider base stay the user's own, the property the ceiling machinery already proves at this site (`src/web_api.nim:135-160`).

The preset snapshot reads the stored record for every modulated field. `snapshotPreset` reads CONFIG for all of them but `sphStiffness`, which already reads `currentSimulation` for the stored-versus-effective reason its own comment gives (`src/web_api.nim:868-907`, comment at `src/web_api.nim:904-906`). A modulated copy in CONFIG would otherwise export as though the user had written it, so keeping presets the user's own obliges that exception to generalize to every field a Modulate row can reach.

Refresh cadence: the flush recomputes and re-mirrors only when some excursion is live or was live the frame before (the return to base must land). Idle cost is one boolean check per frame. Active cost is the weathers' proven cost, one state copy and mirror per frame (`src/app.nim:257-269`).

Slew: an exponential approach toward the latest source value with time constant `slewMs`, computed in the pure matrix from the frame's wall-clock delta. Zero means the raw value.

Rejected: excursions in value space (offset = depth times span). On the log and power curves the same knob motion would move the world by wildly different amounts across the track, and the panel's shading could no longer reuse travel arithmetic.

Rejected: a second CONFIG overlay pass after the mirror. It would be a new effect-time site, and the comment at the existing one says why there is exactly one (`src/web_api.nim:136`).

### D5. Write rows and takeover

A Write row turns its source value into a value via `valueAt(descriptor, sourceValue)`, no bound argument, which is exactly the call the panel's slider makes through the served travel pair (`src/web_api.nim:1155-1162`). The stored record therefore takes the envelope value the handle names, and the effect-time clamp keeps the world under the live ceiling, so a knob resting above a ceiling means what a slider resting in the shaded region means and above-ceiling intent survives in the stored value (`web-ui/src/components/ParamSlider.tsx:55-68`). Takeover then compares travel in the slider's own coordinates. Writes batch like the climate: all simulation-store targets land in one `updateSimulation` per frame, render-store targets in one `updateRender`, and the rare palette or camera target routes through the ordinary `setParam` arm (`src/web_api.nim:605-633`).

Soft takeover engages per row. The row tracks its previous source travel against the parameter's current travel, `positionOf(descriptor, storedValue)`. It engages when the incoming travel crosses the current travel or lands within one `positionStep` of it, and it disengages when the parameter moves by more than one `positionStep` from the row's last written travel, which covers the slider, a preset, and another row. `jump: true` is permanently engaged.

An engaged Write row suspends the weather on its parameter. While any Write row holds engagement on an id a weather tours, that weather's per-frame write skips the id and its other axes continue, and disengagement restores the axis, which snaps to the tour's current point on the next frame. The suspension lives in `web_api` beside the flush, which already serves both writers, so neither pure core learns of the other.

Rank: within a frame, engaged Write rows with fresh values apply in ascending rank, so the highest rank lands last and owns the frame. No winner state is kept.

Rejected: mapping the row's travel with the live ceiling as `boundMax`. A knob at full travel would then store the ceiling value, so raising the ceiling input later would leave the parameter low where a slider at full travel rises with it, and takeover would compare travel in a coordinate the panel never uses.

Rejected: takeover in value units. An epsilon in value units means a different fraction of the track per curve, and travel is already the shared coordinate.

Rejected: electing a single winning row and masking the rest. It adds an ownership state machine whose only observable difference from apply-in-rank-order is which value a lower row would have written in a frame both moved, and last-write-wins per frame is the ordering the loop already gives the weathers.

### D6. Flush order and coalescing

`midi_input` stages between frames: a latest-value table for continuous sources, an ordered queue for events. `web_api.flushMatrix()` drains both, once per frame, called from the loop after the weather writes and before `physics` (`src/app.nim:257-271`), so within a frame a hand on hardware lands after ambient drift.

Continuous coalescing is the staging table itself: a sweep collapses to the latest value per source. Events preserve arrival order, with one exception: multiple program changes for the same regime target in one frame collapse to the latest. Touch events funnel into the one blast slot `InputState` holds, latest wins, matching a second tap replacing the first.

### D7. Touch rows and the pad grid

A Touch row lays `gridCols x gridRows` cells over the visible view. The event's ordinal minus `baseNote` indexes the cell, row-major from the bottom left, and an event landing outside the grid is discarded. The cell center converts to world coordinates through the live camera at capture, the same conversion and the same reason as the pointer blast (`src/canvas_input.nim:152-153`, `src/app.nim:196-200`). Magnitude scales strength: `withBlast` gains a strength argument, callers passing 1.0 keep today's behavior (`src/ui/state/input_state.nim:60`), and the blast then decays on the existing path (`src/canvas_input.nim:70`).

Rejected: world-fixed pad cells. A pad you cannot see landing a blast you cannot see fails the legibility contract, and the tap precedent is view-relative.

### D8. Matrix schema and persistence

`control_matrix.nim` owns a versioned JSON schema in `preset.nim`'s image: its own `MATRIX_SCHEMA_VERSION` starting at 1, validate-first decode where every malformed row is dropped and every out-of-range field clamps, one rejection for a newer version, and a fall-through `migrate` awaiting its first branch (`src/preset.nim:567-673` is the precedent). One user matrix persists. The boundary serves `matrixKeys()` with the storage key, the panel does localStorage I/O, exactly the preset split (`src/web_api.nim:1301-1311`).

The shipped default matrix is a `const` in `control_matrix.nim`, loaded when storage is empty or invalid. Its contents: four Write rows with soft takeover put the coupling strengths on channel 1's hardware-common knobs, `midi:cc:1:1` (mod wheel) to `forceStrength`, `midi:cc:1:7` (volume) to `fluidStrength`, `midi:cc:1:74` (cutoff) to `rdFieldForce`, and `midi:cc:1:71` (resonance) to `rdDeposit`, since stock controllers emit these without configuration and the garden's silence leaves their audio meanings colliding with nothing, while the cutoff pairing matches the audio family's brightness row, so filter brightness means field-heed in both families. Six Fire rows put the regimes on `midi:pc:1`, ordinals 0 through 5. One Touch row lays a 4 x 4 grid on `midi:notes:1` from `baseNote` 36, the range common pad controllers start at. Toggles ship unmapped and arrive through learn, so a stray note never flips the picture. A static gate asserts every shipped row survives validation against the live descriptor table and the compile-time source declarations D3 gives the shipped ids, in the style of the descriptor table's own compile-time gates.

The matrix stays out of world presets: a preset is a point in the world's parameter space, and the matrix configures the instrument, the reasoning that keeps the camera out (`src/ui/api/param_descriptor.nim:53`).

### D9. Learn

The boundary serves `armLearn(rowSpec)`, `cancelLearn()`, and a learn-state read the panel renders. While armed, the next qualifying delivery binds: a continuous source movement for a Modulate or Write slot, an event for a Fire or Touch slot, where a Fire slot takes the event's source id and ordinal and a Touch slot takes the source id and offers the delivered ordinal as `baseNote`. The binding gesture itself is suppressed from normal matrix effect, so learning a knob does not also drive whatever it was mapped to. The panel then receives the completed row, and persistence follows the ordinary edit path. No timeout: learn stays armed until a source arrives or the user cancels.

Identifiers avoid the word mode (`learnArmed`, `armLearn`). The forbidden-vocabulary sweep names only the SimKind family (`tests/test_no_modes.nim:17-20`), so no gate trips either way, and the vocabulary stays clean by choice.

### D10. The widened push

The push keeps its semantics, current values on every push so the panel never tracks which feature writes which id (`src/web_api.nim:817-819`), and widens its id set: `params` carries the two weather tables union every Write row target in the active matrix, rebuilt on matrix edit. The panel side already applies arbitrary ids by comparison (`web-ui/src/state.ts:108-113`).

A new `excursions` record rides beside `ceilings`: signed travel offset per parameter id under a live excursion, empty when none. The panel shades the span from the handle's base by the offset, through the pattern the derived ceilings use (`web-ui/src/components/ParamSlider.tsx:55-68`, `web-ui/src/state.ts:118-119`).

The push cadence is the loop's FPS-refresh gate, roughly 500 ms (`src/app.nim:284`). MIDI excursions are quasi-static under a held knob, so the shading lag is acceptable here. The world itself modulates at frame rate regardless: the cadence bounds the meter, never the sound of the instrument. The audio designer inherits this as a stated limit: feature-rate breathing aliases in the shading at this cadence, and raising the push rate or adding a faster excursion channel is a measured decision deferred to that change (principle 10).

Rejected: pushing excursions per frame on a channel of their own. No consumer needs frame-rate shading yet, and the panel keeps one subscription for everything the frame loop reports (`src/web_api.nim:813-815`).

### D11. User-facing vocabulary

User-facing copy says **mapping**: the panel section is "MIDI mappings", a row is a mapping, learn is "map this control". The word matrix stays exclusively the species force matrix everywhere a user reads, and the `control-matrix` capability name lives only in the spec namespace.

Rejected: "mod matrix". Synth-familiar, and it collides with the species matrix in help, panel, and the `randomizeMatrix` action the same screen exposes.

Rejected: "routing". Accurate but colder than the learn gesture it labels, and "map this knob" is the sentence users already say.

### D12. Help

A MIDI help file joins `docs/help/` in the numbered sequence (for example `70-midi.md`), its front-matter key added to `ReservedHelpKeys`, the existing home for keys naming no descriptor group (`src/ui/api/help_content.nim:38-40`), covering the connect affordance, mappings, learn, takeover, and the pad grid. The shipped default mapping is served through the boundary so help and panel render it from the one home, the binding-table relation extended (`src/ui/input/binding_table.nim:1-6`). `tests/test_help_content.nim` gains the relation: every shipped mapping row's target appears in the MIDI help file, and the file exists.

### D13. Test plan

- `tests/test_midi_core.nim`: byte-triple parsing, malformed input rejected at the boundary, normalization to [0, 1], channel extraction into source ids.
- `tests/test_control_matrix.nim`: the four validation relations of D2, arbitration summing and clamping in travel space against real descriptors, rank ordering, takeover engagement and disengagement across crossing, preset apply, and weather movement, slew convergence, schema round-trip, the drop-and-clamp decode stance, and the shipped defaults surviving validation.
- Static gates: the shipped matrix validates at compile time against the descriptor table and the MIDI source declarations, alongside the existing curve-floor and mirror gates.
- `tests/test_help_content.nim`: the D12 relation.
- The suite watches each new gate fail once before its green counts (principle 4).
- Browser-side transport and wiring are verified by the build and the proposal's measurement gate, never mocked.

## Matrix interface contract

What a source family provides to exist. This section is self-standing for the audio-interface design.

**Registration.** At wiring time the family calls `web_api.registerSourceFamily(familyId, declarations)` once, where `familyId` is a unique prefix (`midi`, `audio`) and each declaration is `(sourceId, kind, label)` with `kind` one of `continuous | event`. Source ids are opaque strings the family mints and prefixes with its `familyId` and a colon. Declarations feed row validation, the mapping editor, and help. Registering twice replaces the family's declarations, which covers hot-plug growth and lazy declaration. A stored row naming a source no current declaration covers stays inert and visible rather than dropping, so a family's absence never destroys a mapping.

**Continuous delivery.** The family writes `setSourceValue(sourceId, value)` with `value` in [0, 1], as often as it likes. The matrix keeps only the latest value per source id. Values outside [0, 1] are clamped at this boundary.

**Event delivery.** The family calls `emitSourceEvent(sourceId, magnitude, ordinal)` with `magnitude` in [0, 1] and `ordinal` locating the event inside the source's own space, zero where the source has no such space. Events queue in arrival order and drain at the next flush. Fire rows select on the ordinal, and Touch rows index their grid with it.

**Flush.** `web_api.flushMatrix()` runs once per frame from the frame loop, after the weather writes and before physics. Families never call it and never observe it. Everything downstream of delivery, arbitration, takeover, excursions, writes, gestures, shading, and the widened push, is matrix-side.

**Learn.** Armed learn binds on the first qualifying delivery through the same two entry points. A family needs no learn awareness.

**Cadence limit.** Excursion shading refreshes on the stats push cadence, roughly 500 ms. A family whose sources move faster than that sees faithful world response at frame rate and a coarsely sampled meter.

## Risks / Trade-offs

- [Web MIDI absent or denied in the launched window] → the proposal's measurement gate runs before transport work, and the affordance reports unavailability while the core stays buildable and tested.
- [Registry-validated sources are checked later than a typed variant would be] → the static gate on the shipped matrix and the validation tests hold the seam, and an id no declaration covers shows as an unresolved row in the editor rather than failing silently at dispatch.
- [Per-frame modulated mirror cost] → bounded by the weathers' proven per-frame write, and zero when no excursion is live.
- [Shading lag at the push cadence] → informational only, stated in the contract, revisited with a measurement when audio arrives.
- [A Write row and a weather sharing an id would fight across frames] → an engaged Write row suspends the weather on that id (D5), so the hand holds the parameter alone while engaged and the weather resumes on disengage.

## Migration Plan

Either change may land first: this design introduces the matrix, and if audio-interface proceeds first it carries these matrix pieces as its prerequisite, per both proposals. Deployment is additive behind the connect affordance. No stored format changes: presets are untouched, and the matrix storage key is new. Rollback is removal of the new modules and surface, orphaning at most the localStorage key, which the next build ignores.

## Open Questions

1. **Multiple MIDI inputs.** All connected inputs merge into one stream, distinguished only by channel. Whether a device filter or per-device source ids matter is deferrable: source ids are opaque strings, so a later `midi:<device>:cc:1:74` grammar extends without schema change.
