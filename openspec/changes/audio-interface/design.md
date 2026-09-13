# audio-interface design

## Context

See proposal.md for motivation. The states of the world this design builds against, each verified in source:

- One write path mutates the world, and the effect-time clamp lives at exactly one site, where the mirror lands `effectiveSimulation(storedState)` into `CONFIG` while the stored record stays untouched (`src/web_api.nim:135-160`). Correction, 2026-09-12: the READ side became true only with this change. Before it, `getParamImpl` read `CONFIG[]` for every id outside four arms, so `getParam` and the Modulate base both answered with the previous frame's modulated value; they read `currentSimulation`/`currentRender` through `storedParamValue`/`storedContext` from now on.
- The weathers already write through that path once per frame when on (`src/app.nim:244-269`), so per-frame work on the write path has a paid precedent.
- The stats push runs on the fps window, twice a second (`src/app.nim:284-317`). The camera is polled by the panel on its own cadence instead, because nothing pushes at the panel between those windows (`web-ui/src/components/Panel.tsx:23-38`).
- Pure cores compile on both backends and are exercised natively (`src/climate_core.nim:1-35`, `tests/test_climate_core.nim`).
- Help is one file per group with front matter of exactly `group: <key>`, and reserved keys exist for files naming no descriptor group (`src/ui/api/help_content.nim:39-51`).
- The control matrix this change consumes is described in openspec/changes/midi-interface/proposal.md: rows of five kinds, sources normalized per family, summed modulation, ranked writes. Its interface contract is written in the sibling design, and the interface needs list in decision 7 records what this design requires of it.
- A descriptor's store decides where a write lands and whether a preset carries it. `psCamera` is the precedent for a value outside CONFIG and outside the preset schema (`src/ui/api/param_descriptor.nim:53-59`, pinned by `tests/test_param_descriptor.nim:386-395`). A Modulate row reaches the simulation and render stores alone, while a Write row reaches any routed store (`targetRefusal`, `src/ui/input/control_matrix.nim:358-376`). Every case over `ParamStore` in `src/web_api.nim` (`storeName` :185-191, `getParamImpl` :446-457, the write arm :502-524, `setParamImpl` :548-564, `paramContextOf` :761-764, `applyMatrixWrites` :810-813, `mirrorModulated` :840-847) and in `src/ui/api/param_fields.nim:54-57` is exhaustive, so a new store member fails the build at each until it has an arm.
- Storage keys split by what they hold: presets under `pg.presets.` (`src/ui/presets/preset_store_core.nim:24-28`), and the one user mapping under `pg.mapping` (`MAPPING_STORAGE_KEY`, `src/ui/input/control_matrix.nim:561`), which the panel reads and writes through the key the boundary serves (`matrixKeys`, `src/web_api.nim:1641-1644`).

Web Audio facts relied on: `fftSize` is the FFT window size in samples, a power of two, default 2048 (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/fftSize). `frequencyBinCount` is half of `fftSize`, and `getFloatFrequencyData` fills a Float32Array with decibel values for bins spread linearly from 0 Hz to half the sample rate, with silent bins at negative infinity (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/getFloatFrequencyData). `smoothingTimeConstant` averages successive frequency frames in the browser, 0 meaning no averaging (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/smoothingTimeConstant). An AudioContext created outside a user gesture starts suspended, and `resume()` inside interaction unlocks it (https://developer.chrome.com/blog/web-audio-autoplay).

## Goals / Non-Goals

**Goals:**

- Every number from bins to features owned by Nim, natively provable: band edges, window constants, gates, thresholds, normalization state.
- Features that stay in [0, 1] for any finite input, any microphone gain and any Room Gate setting, with no NaN ever crossing the boundary.
- A quiet room that reads as zero, so `Silent` is reachable and room noise drives no row.
- A capture chain whose lifecycle is legible from the panel: what the microphone state is, and that stopping truly stops it.
- Design that holds under either implementation order relative to midi-interface.

**Non-Goals:**

- No matrix mechanics: rows, arbitration, and flush belong to the sibling change.
- No perceptual loudness standard (LUFS or similar): the features serve expression, and a five-line RMS serves it as well as a gated integrator would.
- One descriptor parameter only, the Room Gate. Audio adds no other entry to the descriptor table: no input gain, no per-feature gate, no silence threshold.

## Decisions

### 1. Capture chain and lifecycle

The listen control's click creates the AudioContext, calls `getUserMedia` for audio with `echoCancellation`, `noiseSuppression`, and `autoGainControl` each requested `false`, and wires MediaStreamAudioSourceNode into an AnalyserNode connected to nothing further. The three are `MediaTrackConstraints` entries (https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackConstraints), each a preference the browser may decline, and their defaults are the browser's own and change across versions. The browser's gain control would move the level under decision 5's own window, and noise suppression removes the sustained tones a pad or a held note carries. The measurement gate reads the granted track's settings back through `getSettings()` (https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamTrack/getSettings) and reports which of the three the launched window honored, which is the only statement about defaults this design relies on. Creating the context inside the gesture satisfies the activation policy in the same click that asks permission. Turning listening off stops the MediaStream tracks and closes the context, so the operating system's microphone indicator goes dark and the affordance's claim of silence is true at the OS level. Listening never starts on launch or on preset load: the click is the consent, every session (docs/engineering-principles.md, article 11).

Rejected: the browser's default processing, which is tuned for a voice call and competes with the feature core for the signal's level and sustain. Rejected: suspending the context while keeping the stream, which keeps the microphone indicator lit while the app claims not to listen. Rejected: one context created at startup, which arrives suspended and couples an unrelated lifecycle to the affordance.

### 2. Analyser configuration

`fftSize` 2048 and `smoothingTimeConstant` 0, both set explicitly from constants in the Nim binding, with the conditions beside them. At a 48000 Hz input, 2048 samples give a 23.4 Hz bin width and a 42.7 ms window. The zero smoothing constant is the decision that all conditioning lives in the feature core, where tests can hold it.

Rejected: the analyser's default 0.8 smoothing, which averages in the browser where no native test reaches it and which cannot express the asymmetric response a meter or an onset wants. Rejected: `fftSize` 4096, whose 85 ms window smears transients across five rendered frames. Rejected: 1024, whose 46.9 Hz bins leave the bass band about five bins wide.

### 3. What crosses into the feature core

Once per frame, the wiring copies two arrays and hands them to the core with the sample rate, the frame's wall-clock delta, and the Room Gate offset in decibels: the frequency array (1024 decibel values) and the time-domain array (2048 samples). The delta is what holds decision 4's refractory window and decision 5's adaptation in wall-clock terms at any frame rate, since the same constant counted in frames spans half the seconds at 120 fps that it spans at 60. The sibling design takes the same input for the same reason, computing each row's attack and release in the pure matrix from the frame's wall-clock delta (openspec/changes/midi-interface/design.md, D4). The Room Gate arrives per frame rather than as core state, so the core stays a function of its inputs and a slider move lands on the next frame with no reset. The core is the one implementation from arrays to features: it converts decibels to linear magnitude, treats negative infinity as zero, and owns every constant. The wiring in `src/canvas_input.nim` style does nothing but poll, copy, read the gate, and call.

Rejected: deriving any feature in JavaScript or in the panel, which would put numbers outside Nim's ownership and outside native tests. Rejected: counting the refractory and the adaptation in frames, which ties every audio constant to the display's refresh rate and lets one drum hit double-trigger at 120 fps where it fired once at 60. Rejected: storing the Room Gate inside `AnalysisState`, which `stopListening` re-initializes (`src/audio_input.nim:127`), so a stop would silently reset the user's setting.

### 4. Feature definitions

Band edges at 250 Hz and 2000 Hz, with the bass band starting at 20 Hz and the high band ending at 8000 Hz. Below 20 Hz is rumble, above 8000 Hz is mostly consumer microphone hiss, and the two inner edges split roughly at the voice fundamental's top and the presence region's bottom.

- **loudness**: RMS of the time-domain frame, in decibels, normalized by the room-gated window of decision 5.
- **bass, mid, high**: mean linear magnitude over the band's bins, in decibels, each normalized by its own room-gated window, since spectral tilt makes one shared window read the high band as permanently quiet.
- **brightness**: the spectral centroid over linear magnitudes between 20 Hz and 8000 Hz, mapped through logarithmic frequency position between 200 Hz and 8000 Hz into [0, 1]. The centroid is defined only on a frame where at least one band reads above its room edge. Otherwise it is the room's own timbre, and the feature decays toward zero rather than jumping. The absolute energy floor stays only as the guard against a denormal spectrum.
- **onset**: half-wave rectified spectral flux, the sum of per-bin magnitude increases since the previous frame, normalized by a running median. A flux crossing of the threshold fires one event carrying energy clamped to [0, 1], only on a frame whose loudness reads above its room edge, and a refractory window of 100 ms holds further firings.

Gating brightness and onset on the room edge is what makes "the room reads as zero" hold for all six sources. Measured on the shipped core in a synthetic stationary room, brightness reads p50/p90 0.10/0.44 and two onsets fire in 25 s. The live room read brightness at about 35% [.?] (scratchpad/audio-interface/room-gate-design__13-09-26-1800.md; the live value is the lead's screenshot reading). Onset is the sharper half: the shipped onset row pulses `forceStrength` (decision 10), so a stray onset in a quiet room shoves the whole world, which is the defect itself rather than a side effect of it.

### 5. Normalization against unknown gain, with the room read as zero

Each normalized feature tracks three levels in decibels:

- **The window floor** falls instantly and rises with a 2 s time constant, holding the recent quiet.
- **The ceiling** rises instantly and decays with a 3 s time constant, holding recent peaks.
- **The noise floor** is a sign-following quantile tracker that steps down at `NOISE_FLOOR_FALL_DB_PER_SECOND` = 20 and up at `NOISE_FLOOR_RISE_DB_PER_SECOND` = 1. It never steps past the level. Seeded above any level, it is placed by the first analysed frame. It settles where 1/21 of frames sit below it (about p4.8).

The window's lower edge is `max(window floor, noise floor + gate + Room Gate offset)`, and the feature is the level's clamped position between that edge and the ceiling, over a span of at least `MIN_WINDOW_DB`. The gate is a per-feature constant. The window floor still carries the adaptation to any microphone gain. The noise floor with its gate is what separates the room from a sound, and while a sound's quietest frames stand more than the gate above the heard room, the lower edge is the window floor exactly as before.

Silence keeps its criterion, loudness at or under `SILENCE_LOUDNESS` for `SILENCE_SECONDS`. What changes is that the room now reads zero, so the criterion is reachable.

**The gate constants and their conditions.** Each gate is the p99.9 excursion of the level above the noise floor over two stationary synthetic rooms: 80 Hz rumble at -60 dBFS with hiss at -75 dBFS, and white hiss at -70 dBFS. They are measured through an emulated analyser at fftSize 2048 and 48 kHz, taking the larger value from 60 and 120 fps: loudness 6.2 dB, bass 10.4 dB, mid 4.6 dB, high 2.1 dB. Bass is widest because its band holds ten bins, and a mean over few bins flickers most. The loudness gate is set by rumble, whose few degrees of freedom in a 42.7 ms window make the RMS flicker.

**Measured (synthetic, scratchpad/audio-interface/room-gate-design__13-09-26-1800.md):**

- The shipped window reproduces the live finding: room loudness p50 0.19, bass 0.38, and Silent never reached.
- With the room gate, the stationary and hiss rooms read 0.00 at p90 on every feature, and a moving room (±3 dB slow drift) reads high p90 0.06.
- Music heard after a room keeps the shipped window's readings over 30 s (loudness p50 0.38 then 0.27).
- Silent is reached 2.98 s after the music stops.
- A tone 12 dB over the room clears Silent on its first 60 fps frame.

**Designed but unexercised:** the gates in a real room, a loud room, and the Room Gate below zero.

**The cost, measured.** The noise floor learns the room only from what it hears. Pressed with music already playing, or through an unbroken set longer than (the music's trough above the room, in dB) ÷ 1 dB/s, it takes the music's quietest twentieth as the room, and the bottom gate's worth of each feature reads zero until a pause. In the probe, Listen pressed mid-music read loudness p50 0.00 against the shipped 0.27, and mid 0.22 against 0.47. Bass was unharmed. Lowering the Room Gate returns that range. The user accepted this trade, so no "the room is quiet now" gesture ships.

Rejected for that cost: a `learnRoom` entry point with a panel button that places every noise floor at the current levels. It buys correct gating when Listen is pressed mid-music, and costs a second control whose misuse (pressed during a quiet passage) gates the music for the whole set.

Found at implementation (2026-09-12): because the floor falls instantly, a perfectly flat held level sits on its own floor and reads exactly zero, so "a held level returns inside (0, 1)" is unsatisfiable for a flat stimulus by construction. With the room gate, that extends to any level that holds within its gate of its own quietest twentieth: a sound is what rises above the room, and a stimulus that never lets the core hear a room reads as one. Nine of the fifteen existing core tests drive exactly such stimuli, and each gains a room ahead of its sound with its oracle unchanged (measured against a scratch copy of the core: scratchpad/audio-interface/probe/core_c_existing_tests_output.txt).

Rejected, each measured on the same probe:

- **Retuning `SILENCE_LOUDNESS` alone** (standing still on the mechanism). The threshold would have to exceed the room's p99 loudness reading (0.46 stationary), so a sound reading below half scale could never clear Silent, and the room would still drive every row at 0.19-0.64. Undo is free, and so is the cost it leaves with the user.
- **A silence criterion of its own** (short-term level range, or time since the last loud frame). It makes Silent reachable and leaves the room driving rows at the same readings, which misses half of the user's decision.
- **Widening `MIN_WINDOW_DB`.** The room's several-dB flicker still reads nonzero (about flicker ÷ width), Silent stays unreachable at 0.02, and a quiet instrument can no longer reach full scale.
- **A gate over the window floor (A).** The room reads 0.00, but music loses its bottom gate at once. Loudness p50 fell from 0.38 to 0.00 on music heard right after a room, because during music the window floor is the music's own trough.
- **A noise floor that falls instantly (B).** Seeded correctly, it tracks the same minimum the window floor does and reduces to A.
- **A gate scaled by how wide the window is (E).** No noise floor is needed, but dense music's loudness window is narrow, so loudness read 0.00 at p50, and Silent came 7.8 s after the music stopped.
- **A fixed dBFS mapping**, which bakes one microphone's gain into every number. **A full automatic gain control on the samples**, which alters what the other features measure.

### 6. Where smoothing lives

The core emits features conditioned only as their definitions require: the FFT window, the normalization tracking, the flux differencing. No fixed attack or release is layered on top. The matrix row's attack and release constants are the musical smoothing, applied where the user chose them, and meters show what the core emits so a transient is visible as itself. The shipped audio rows start at a zero attack and an 80 ms release, inside the 20 to 100 ms range audio-reactive practice reports (https://kferg.dev/posts/2020/audio-reactive-programming-envelope-followers), so a hit lands on its frame and the world eases off it. The noise floor is window state like the floor and ceiling, not smoothing of a feature: a feature's value still follows its level on the frame the level changes.

Rejected: a core-side attack and release per feature, which would double-smooth under the row's envelope and hide from the meter exactly what the onset detector needs visible.

### 7. Frame ordering and the matrix hand-off

Each frame, before the matrix flush the sibling change defines: poll the analyser, run the core, deliver continuous values and any onset event to the matrix. The audio work adds one poll, two array copies, and arithmetic over 1024 bins per frame, on the frame loop where the weathers already run per-frame writes (`src/app.nim:244-269`).

**Interface needs**, everything this change requires of the matrix contract, each met by the sibling design's Matrix interface contract:

1. Stable source identities registrable as a family: `audio:loudness`, `audio:bass`, `audio:mid`, `audio:high`, `audio:brightness` continuous, `audio:onset` event.
2. Continuous delivery: set the latest [0, 1] value per source, any number of times per frame, coalesced by the matrix.
3. Event delivery: enqueue an event with magnitude in [0, 1], consumed by Fire and Touch rows, with Touch able to resolve a target cell when the event itself carries no position.
4. A defined flush point in the frame loop that runs after source delivery, shared with MIDI sources.
5. Offline tolerance: rows naming sources of an absent family stay inert and visible, and validation accepts them, since audio sources exist only while listening.

The contract answers each in order: registration with lazy re-registration, `setSourceValue` latest-wins, `emitSourceEvent` carrying an ordinal that onset sends as zero so a one-cell Touch grid resolves to the view's center, `flushMatrix` running once per frame after delivery, and unresolved rows kept inert and visible.

### 8. Metering by a per-frame push

The frame loop pushes the affordance state and the six features once per frame while a subscriber is registered, which the audio section registers when it opens and drops when it closes. Meters then move on the clock that produces the values, so a level tracks the room at whatever rate the display runs.

The push is a plain function call inside the one JS context, built on the stats push's own shape: subscribers held in a sequence (`src/web_api.nim:1298-1299`), and an early return before any allocation when nobody listens (`src/web_api.nim:820-821`). While a subscriber is registered and no capture chain is live there is nothing to analyse, so the per-frame push stands down and one push on each affordance state change carries the settlement, which is how a denial reaches the panel without a poll. The stats push itself is untouched and stays on the fps window, twice a second (`src/app.nim:284`), since nothing riding it needs the frame rate.

Onset rides the push as the event it is: the push carries an onset in the frame it fires, with its energy, and the panel renders a decaying indicator as presentation, restating no number of its own. A sampled "current value" for an event source has no definition, and at any cadence below the frame rate most firings fall between the samples.

Rejected: a `gardenAPI` getter the panel polls at 100 ms, the camera's pattern for state nothing pushes (`web-ui/src/components/Panel.tsx:23-38`). At 120 fps one update spans about twelve rendered frames, so a level moving at syllable rate steps instead of moving, and a `setInterval` uncorrelated with the frame clock spaces successive samples unevenly on top of that. The camera precedent holds on "nothing pushes this" and not on how fast a value travels, since `cameraZoom` stands still between wheel gestures. Rejected: raising the whole stats push cadence, which taxes every stats consumer for one section's meters.

### 9. Affordance states

One sum type serves the panel: `Disconnected` (never asked or turned off), `Requesting` (prompt open), `Connected` (stream live), `Denied` (permission refused), `Silent` (connected with loudness at the bottom of its room-gated window for three seconds, the state that answers "is it broken or is the room quiet"). The push of decision 8 carries the state's name in its payload, and the panel renders it without restating any threshold.

A sound clears `Silent` on the first analysed frame whose loudness reads above the room edge. Natively that is the next frame. Live, the 42.7 ms analyser window must first fill with enough of the sound: at 120 fps a tone 12 dB over the room read 0.00-0.14 on its first frame under every mechanism probed, and 0.18 on the shipped window, so a return can take up to one analyser window.

### 10. Shipped default rows

Six rows, each touching exactly one target so cause reads clearly (couplings verified at `src/ui/state/sim_config.nim:43-57`). Three ship live and three ship authored at zero depth:

| Source | Row | Target | Depth | Why this pairing teaches |
|---|---|---|---|---|
| audio:onset | Touch | blast at the view's center, a one-cell grid with baseNote 0 | energy as strength | A drum hit visibly shoves the world where the eye rests |
| audio:bass | Modulate | fluidStrength | +0.30 | Bass is felt as pressure, and the fluid is pressure |
| audio:loudness | Modulate | forceStrength | +0.25 | The room's energy animates the species dance, the first coupling a user meets |
| audio:high | Modulate | glowIntensity | 0 | Sparkle brightens the halo the particles already wear |
| audio:mid | Modulate | rdDeposit | 0 | The music's body feeds the substrate the chemistry grows on |
| audio:brightness | Modulate | rdFieldForce | 0 | Bright timbre makes particles heed the chemical field |

> 2026-09-12: the audio:mid and audio:brightness rows above no longer ship; reaction-diffusion is
> decoupled from audio.

> 2026-09-12: the audio:onset row above ships as a Modulate impulse on forceStrength, depth +0.40
> with a 300 ms release, so a hit reaches every particle rather than the disc a blast covers; it
> shares loudness's target and the two sum. The blast stays available to Touch rows.

The three live rows are the ones whose cause and effect share a kind and a clock: an impulse to an impulse, pressure to pressure, energy to energy. A mapping reads without explanation when it "has a basis within the physical world" and stays inside one time scale, and a mapping into a structure that accumulates is "rarely perceived" at the scale of the event, showing instead in its cumulative effect (Callear, https://www.seeingsound.co.uk/docs/Audiovisual_Particles.pdf, sections 2.3 and 4.3). The two field rows push a syllable-rate feature into the Gray-Scott field, which accumulates deposit across every frame's substeps (docs/one-world.md, world-intrinsic passes), so they read as texture over a passage and would blur the first three if live from the start. They ship authored, at zero depth, with help inviting the user to raise them once the live three are heard, which is the row the matrix already treats as ordinary: a zero depth keeps its place and moves nothing. The high row joins them so the first listen changes the world and nothing else, and simple correspondences that all fire at once "rapidly cease to be interesting" (Dannenberg, via Callear section 2.2).

`audio:high` lands on the render store rather than a fifth coupling, keeping the one-coupling-per-row teaching, and on `glowIntensity` over `bloomIntensity` because the bloom slider sits dormant while bloom is off (`src/ui/api/param_descriptor.nim:507-509`) where the glow is always in the picture. Steady hiss settles to zero under the room gate, so only high-band content above it sparkles. Depths are starting values pinned by tests and refined against the running world (docs/engineering-principles.md, article 10). Every row's depth has zero in range, the house idiom.

Rejected: six live rows. The climate and force-weather tours keep running while listening, and they are the counterpoint that keeps a mapping from going predictable, which Callear's compositions needed "unmapped elements" to supply. Six audio rows plus two tours moving at once leaves nothing for the eye to attribute.

Rejected for onset's target: a random cell, which reads as noise until the mapping is understood, and the loudest band's spatial position, which the substrate register would earn later but a blast cannot explain today.

> 2026-09-12: onset's target is now the global forceStrength, taken because a blast at the view's
> centre reaches only the particles inside its radius while a hit should reach the whole world. The
> spatial targets above stay rejected.

### 11. Native test plan

The core is pure, so tests construct bin arrays directly:

- A single-bin spectrum at 440 Hz, heard over a room: brightness lands at 440's logarithmic position within tolerance, bass and high near zero.
- Energy confined to one band per case, over a room: that band's feature leads, the others stay low.
- A click train at a known period: onset events at the expected frames, none inside the refractory window.
- Silence, all bins negative infinity: every feature exactly zero, no NaN, and the state stays finite.
- A gain step of 20 dB up and down over a heard room: every feature returns inside (0, 1) within a bounded frame count, proving the adaptive window.
- A fuzz sweep over random finite arrays and Room Gate offsets across the descriptor range: every feature in [0, 1], never NaN, the total function property.
- A room flickering by several dB frame to frame, drawn from the distribution of a Gaussian-noise bin (Rayleigh magnitudes) and Gaussian samples, after a sounding passage: every feature reads zero at p99, Silent arrives within `SILENCE_SECONDS` plus a pinned margin, and a sound 12 dB over the room clears it on the next frame.
- A sound whose quietest frames stand more than the widest gate above a heard room reads identically at a Room Gate of zero and at the range minimum, which is the relation that catches a gate subtracting from music.
- Raising the Room Gate above a sound makes it read zero and reach Silent; lowering it below the sound brings it back.
- Every level shifted by the same dB, all staying above -100 dB, changes no level feature, which is why an input gain would be a dead control.
- In a gated room, brightness decays below 0.01 and no onset fires, even on a flux crossing.

The capture chain itself is browser territory, verified by the build and by the measurement gate spike, never mocked (openspec/config.yaml testing context).

### 12. Help

One help file with the three-line front matter (`src/ui/api/help_content.nim:46-51`), key `audio`. The key leaves `ReservedHelpKeys` (`src/ui/api/help_content.nim:42`), because the Room Gate makes `audio` a descriptor group, and the coverage relation "every descriptor is named by its group's file" then requires the file to name `audioRoomGate` on a code-span line. Content sketch: what the listen control does and that sound never leaves the app, the permission prompt and how to revisit a denial, the six sources described in room terms (loudness as the room's energy, bass as its weight, brightness as its sparkle, onset as its hits), what the meters show, what the Room Gate does (raise it in a loud room until the meters rest, lower it for a quiet instrument, why Silent may not come while it sits below zero, that it is remembered on this browser and untouched by presets, and that audio rows cannot write it), what the three live rows do, and that three more rows wait at zero depth with an invitation to raise and remap them.

### 13. The Room Gate control

**Reversal.** Decision 5 once rejected any calibration control and the audio-input spec promised "no numbers to tune". The live verification of 13-09-26 reversed it, and the user chose both an automatic fix and a user-facing attenuation control. The automatic gate is measured on stationary synthetic rooms. A live set runs in rooms whose noise is neither stationary nor quiet (a crowd, PA spill), and no automatic floor can tell the room from a steady sound the performer means, as decision 5's cost shows. The performer is the one who knows which is which, so the control gives them that call.

**What it changes.** One dB offset added to every feature's gate, which moves the lower edge of each room-gated window: how far above the room's own noise a sound must rise before it moves the world. It does not scale a level before the window (cancelled, see below) or a feature after it (a row's depth already does that).

- Raising it makes a louder room read as zero and reach Silent sooner, and a sound must clear the raised edge to return `Connected`. In the moving synthetic room, +6 dB took every feature to p90 0.00. Music heard after a room kept loudness p50 0.37 early and fell to 0.20 late.
- Lowering it below zero lets quieter sounds through and the room's flicker with them. At the range minimum, where the offset cancels the widest gate, Silent may not be reachable. Unmeasured for this mechanism: the rejected candidate B at -6 dB left Silent unreached.

**The descriptor.** Id `audioRoomGate`, label "Room Gate", group `audio`, float with precision 1. The range comes from `src/config_ranges.nim`: `AUDIO_ROOM_GATE_MIN_DB` is the negated widest gate (the bass gate), the offset below which nothing further opens, and `AUDIO_ROOM_GATE_MAX_DB` is 120 dB, derived from the level span the core can receive. `config_ranges` imports no core, so both are literals there, and `tests/test_audio_core.nim` holds each to the relation it rests on.

The derivation of the maximum:
- `getFloatFrequencyData` reports each bin as unclamped decibels, and `minDecibels` and `maxDecibels` clip and scale only the byte data (https://webaudio.github.io/web-audio-api/#dom-analysernode-mindecibels; `getByteFrequencyData` "clipped to lie between minDecibels and maxDecibels"). So the analyser's -100 dB default bounds nothing the core reads.
- The core clamps every level from below at `LEVEL_FLOOR_DB` = -120 (`src/ui/input/audio_core.nim:44`, `:168`).
- From above, a full-scale input bounds every level at 0 dBFS: an RMS over samples in [-1, 1] is at most 1. A bin's magnitude, the windowed transform divided by N, is at most the Blackman window's mean weight (0.42) times the peak sample, so a band's mean is at most about -7.5 dB.
- So every level lies in [-120, 0] dB, and every noise floor is at least -120. An offset of 0 − (−120) = 120 dB puts every lower edge at least the smallest gate above full scale, where every feature reads zero. A larger offset changes nothing further.

The full-scale bound is nominal, not guaranteed: Web Audio carries PCM "with a nominal range of [-1,1] but the values are not limited to this range" (https://webaudio.github.io/web-audio-api/, AudioBuffer). A stream whose samples exceed ±1 could read above zero at the maximum, and task 6.8's kill condition would show it.

The slider travels on `cPower` with exponent 2, so half the travel spans the minimum to +22.2 dB, twice the widest gate above the default, where every measured room's offset sits (the moving room needed +6). The upper half reaches the capability bound. The default sits at 28% of the travel. The default 0.0 (`ROOM_GATE_DEFAULT_DB`) lives in `src/ui/input/audio_core.nim` beside the gates, the way `CAMERA_DEFAULT_ZOOM` lives in `camera_core`, with a notch at the default. The hint names no numerals, and there are no other notches, since no other position has a measured claim behind it. The response probe is `audio.roomEdge`, a closed-form function of the offset over a fixed noise floor, the lower edge in dB.

**The store.** A new `ParamStore` member `psAudio`: the value lives in `src/web_api.nim` beside the audio hooks, `audio_input` reads it every poll into the frame, and it never reaches CONFIG. So, like `psCamera`, it is absent from the preset schema by construction, pinned by a test naming it the only `psAudio` id. The exhaustive cases listed in Context each gain an arm, and the build names every one it lacks.

- Rejected: `psRender` or `psSimulation`, which would put the room into every saved preset, so loading a friend's world mid-set would reset the gate.
- Rejected: a bespoke `gardenAPI` setter outside the descriptor table, which would restate range, default, step and help outside the one contract the panel and the matrix already read.
- Rejected: session-only. It buys no storage, and costs re-dragging the gate after every reload in a room the performer has already set for.

**Persistence.** The Room Gate is remembered on this browser, apart from presets.
- `AUDIO_ROOM_GATE_STORAGE_KEY = "pg.audio.roomGate"` lives in `src/ui/input/audio_core.nim` beside the default, and the boundary serves it as `audioKeys().roomGate` the way `matrixKeys().mapping` serves `pg.mapping` (`src/web_api.nim:1641-1644`).
- The panel owns localStorage under it, as `MidiSection.tsx` owns the mapping (`web-ui/src/components/MidiSection.tsx:5`). It restores the value through `setParam` once at mount, and `setParam` clamps it to the range. It writes whenever the synced value differs from the last written one, so a controller's move is remembered too.
- A stored string that parses to no finite number is ignored, and the default stands.
- The key sits outside the `pg.presets.` prefix, so no preset operation reads or clears it.

**Mapping.** A Write row reaches `psAudio` through the existing store confinement, so a controller knob maps it with no matrix edit. A Modulate row is refused by the same confinement, since the gate has no stored/effective split to modulate. An audio-family row writing the gate is refused. It would feed a feature back into its own edge a frame later, so a loud passage raises the gate that then silences it, which oscillates at frame rate. `targetRefusal` in `src/ui/input/control_matrix.nim` gains the row's source id and one arm: a source under the `audio:` prefix on a `psAudio` target is refused, naming the loop. The check is syntactic on the source id, so it holds at decode as well, and a stored row of that shape drops on load with its reason. This is the one exception to "the audio family joins the matrix without a matrix edit". Controller rows still write the gate.

- Rejected: allowing the loop and naming it in help. It costs nothing to build, and leaves a mapping that oscillates, which nobody can read as cause and effect.

**Rejected controls:**

- **Input gain before the window.** Every step of `track` commutes with adding a constant in dB (`src/ui/input/audio_core.nim:177-191`), so floor, ceiling and level shift together and no feature moves. That is proven by reading, and the dB-shift property test holds it. The slider would do nothing.
- **Scaling the features after the window.** It duplicates each row's depth, leaves the room nonzero, and leaves silence measuring unscaled values.
- **A minimum-window-width control.** It changes contrast (how far above the edge full scale sits), not what counts as room, so it would not answer the finding.
- **An absolute dBFS threshold.** It is device-coupled: every microphone and gain setting needs its own value, which decision 5 exists to avoid.
- **One gate per feature.** Four sliders would restate the probe's table to the user, where one offset over measured per-feature gates asks one question.

## Readiness

Guarantees this design rests on, each at its rung:

- Features finite and in [0, 1] for any finite frame: realizedUntested for the room-gated window. It rests on `tests/test_audio_core.nim`'s fuzz sweep on the shipped window, which the widened sweep re-holds.
- The room reads zero and Silent is reachable: specified. The measured evidence is synthetic only (probe). A real room is unmeasured until task 6.2.
- Music heard after a room keeps its range: specified. Measured synthetic over 30 s at 60 and 120 fps. Unmeasured for real music.
- An input gain moves no feature: asserted by reading `track`, then realizedUntested once the property test is written.
- The Room Gate stays out of presets: specified, by the `psCamera` precedent test-held at `tests/test_param_descriptor.nim:386-395`.
- An audio row cannot write the Room Gate: specified. The store confinement it extends is test-held (`tests/test_control_matrix.nim:296`).
- The Room Gate survives a reload: specified. It is realized in no code yet, and task 6.11 checks it live.
- A Write row can map a routed store and a Modulate row cannot: realizedUntested for `psAudio`. The confinement is test-held for `psPalette` and `psCamera` (`tests/test_control_matrix.nim:296`, `:608`).

Readiness is the lowest rung: specified.

## Risks / Trade-offs

- [Microphone permission inside the webui-launched window is unproven] → the proposal's measurement gate spike runs before capture work, and on refusal the affordance reports unavailability while the core stays fully testable.
- [The launched window may ignore a `false` on one of the three processing constraints] → the gate spike reads the granted track's settings back; a browser that keeps gain control on leaves decision 5's window adapting under a second adapter, which the 20 dB step test cannot see. The connected tab reported all three honored (scratchpad/audio-interface/live-verify__13-09-26-lead.md) [.?].
- [The gates are measured on synthetic rooms] → task 6.2 checks a real quiet room with the offset at zero; if a feature still reads above 0.05 at rest, the kill condition there records which, and the constant is re-derived from a live excursion log.
- [Listen pressed mid-music, or an unbroken set, gates the music's quiet detail until a pause] → measured and stated in decision 5, accepted by the user; the Room Gate lowered returns it, and the help file says so.
- [Adaptive normalization pumps on strongly dynamic music, quiet passages reading louder over time] → slow ceiling decay bounds the effect, and depths ship modest.
- [The 42.7 ms analysis window smears events shorter than a frame, and a returning sound can take one window to clear Silent at 120 fps] → the consumer runs at frame rate, the click-train test pins the detector's granularity, and the spec states the return within one analyser window.
- [Slider shading for audio modulation updates on channels owned by the sibling change, at cadences designed there] → the sibling design pins excursion shading to the stats push cadence, roughly 500 ms, and states the limit in its matrix contract, while this change's meters carry the fast view of audio itself.
- [Two Float32Array copies and 1024-bin arithmetic per frame on the main thread] → the weathers already spend a comparable per-frame budget on this loop (`src/app.nim:244-269`), and the gate spike doubles as the place to watch frame time. The noise floor adds one comparison and one step per window.

## Migration Plan

No deployment or data migration. `midi-interface` lands the matrix spine first, so every step here starts against a matrix that already exists. Implementation order within the change: gate spike, then the binding and capture chain behind the affordance, then the feature core with its tests, then the room gate in the core, then matrix registration, then meters and states, then the Room Gate descriptor and slider, then shipped rows and help. Rollback of the Room Gate is removal of the descriptor, the store member and its arms; the core's gate offset input then stays at zero. A stored mapping with a Write row on `audioRoomGate` then names an absent descriptor and is refused on load the way any unknown target is. The value under `pg.audio.roomGate` stays in localStorage, unread.

## Resolved Questions

- When Listen is pressed with music already playing, the quietest part of what it hears is taken as the room until a pause. The user accepted this, and no room-learning gesture ships (decision 5).
- The Room Gate survives a reload on this browser, under a Nim-owned key (decision 13, Persistence). The user chose this.
- An audio source's row may not write the Room Gate. Controller rows may. The user chose this (decision 13, Mapping).
- Brightness and onset belong inside the room fix, because a stray onset pulses `forceStrength` (decision 4). The lead settled this.
- `AUDIO_ROOM_GATE_MAX_DB` is derived from the level span the core receives, not measured (decision 13). Task 6.8 checks it. The lead settled this.
