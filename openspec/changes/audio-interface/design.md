# audio-interface design

## Context

See proposal.md for motivation. The states of the world this design builds against, each verified in source:

- One write path mutates the world, and the effect-time clamp lives at exactly one site, where the mirror lands `effectiveSimulation(storedState)` into `CONFIG` while the stored record stays untouched (`src/web_api.nim:135-160`).
- The weathers already write through that path once per frame when on (`src/app.nim:244-269`), so per-frame work on the write path has a paid precedent.
- The stats push runs on the fps window, twice a second (`src/app.nim:284-317`). The camera is polled by the panel on its own cadence instead, because nothing pushes at the panel between those windows (`web-ui/src/components/Panel.tsx:23-38`).
- Pure cores compile on both backends and are exercised natively (`src/climate_core.nim:1-35`, `tests/test_climate_core.nim`).
- Help is one file per group with front matter of exactly `group: <key>`, and reserved keys exist for files naming no descriptor group (`src/ui/api/help_content.nim:39-51`).
- The control matrix this change consumes is described in openspec/changes/midi-interface/proposal.md: rows of five kinds, sources normalized per family, summed modulation, ranked writes. Its interface contract is written in the sibling design, and the interface needs list in decision 7 records what this design requires of it.

Web Audio facts relied on: `fftSize` is the FFT window size in samples, a power of two, default 2048 (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/fftSize). `frequencyBinCount` is half of `fftSize`, and `getFloatFrequencyData` fills a Float32Array with decibel values for bins spread linearly from 0 Hz to half the sample rate, with silent bins at negative infinity (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/getFloatFrequencyData). `smoothingTimeConstant` averages successive frequency frames in the browser, 0 meaning no averaging (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/smoothingTimeConstant). An AudioContext created outside a user gesture starts suspended, and `resume()` inside interaction unlocks it (https://developer.chrome.com/blog/web-audio-autoplay).

## Goals / Non-Goals

**Goals:**

- Every number from bins to features owned by Nim, natively provable: band edges, window constants, thresholds, normalization state.
- Features that stay in [0, 1] for any finite input and any microphone gain, with no NaN ever crossing the boundary.
- A capture chain whose lifecycle is legible from the panel: what the microphone state is, and that stopping truly stops it.
- Design that holds under either implementation order relative to midi-interface.

**Non-Goals:**

- No matrix mechanics: rows, arbitration, and flush belong to the sibling change.
- No perceptual loudness standard (LUFS or similar): the features serve expression, and a five-line RMS serves it as well as a gated integrator would.
- No descriptor parameters: audio ships sources and an affordance, and nothing here enters the descriptor table.

## Decisions

### 1. Capture chain and lifecycle

The listen control's click creates the AudioContext, calls `getUserMedia` for audio, and wires MediaStreamAudioSourceNode into an AnalyserNode connected to nothing further. Creating the context inside the gesture satisfies the activation policy in the same click that asks permission. Turning listening off stops the MediaStream tracks and closes the context, so the operating system's microphone indicator goes dark and the affordance's claim of silence is true at the OS level. Listening never starts on launch or on preset load: the click is the consent, every session (docs/engineering-principles.md, article 11).

Rejected: suspending the context while keeping the stream, which keeps the microphone indicator lit while the app claims not to listen. Rejected: one context created at startup, which arrives suspended and couples an unrelated lifecycle to the affordance.

### 2. Analyser configuration

`fftSize` 2048 and `smoothingTimeConstant` 0, both set explicitly from constants in the Nim binding, with the conditions beside them. At a 48000 Hz input, 2048 samples give a 23.4 Hz bin width and a 42.7 ms window. The zero smoothing constant is the decision that all conditioning lives in the feature core, where tests can hold it.

Rejected: the analyser's default 0.8 smoothing, which averages in the browser where no native test reaches it and which cannot express the asymmetric response a meter or an onset wants. Rejected: `fftSize` 4096, whose 85 ms window smears transients across five rendered frames. Rejected: 1024, whose 46.9 Hz bins leave the bass band about five bins wide.

### 3. What crosses into the feature core

Once per frame, the wiring copies two arrays and hands them to the core with the sample rate and the frame's wall-clock delta: the frequency array (1024 decibel values) and the time-domain array (2048 samples). The delta is what holds decision 4's refractory window and decision 5's adaptation in wall-clock terms at any frame rate, since the same constant counted in frames spans half the seconds at 120 fps that it spans at 60. The sibling design takes the same input for the same reason, computing row slew in the pure matrix from the frame's wall-clock delta (openspec/changes/midi-interface/design.md, D4). The core is the one implementation from arrays to features: it converts decibels to linear magnitude, treats negative infinity as zero, and owns every constant. The wiring in `src/canvas_input.nim` style does nothing but poll, copy, and call.

Rejected: deriving any feature in JavaScript or in the panel, which would put numbers outside Nim's ownership and outside native tests. Rejected: counting the refractory and the adaptation in frames, which ties every audio constant to the display's refresh rate and lets one drum hit double-trigger at 120 fps where it fired once at 60.

### 4. Feature definitions

Band edges at 250 Hz and 2000 Hz, with the bass band starting at 20 Hz and the high band ending at 8000 Hz. Below 20 Hz is rumble, above 8000 Hz is mostly consumer microphone hiss, and the two inner edges split roughly at the voice fundamental's top and the presence region's bottom.

- **loudness**: RMS of the time-domain frame, in decibels, normalized by the adaptive window of decision 5.
- **bass, mid, high**: mean linear magnitude over the band's bins, in decibels, each normalized by its own adaptive window, since spectral tilt makes one shared window read the high band as permanently quiet.
- **brightness**: the spectral centroid over linear magnitudes between 20 Hz and 8000 Hz, mapped through logarithmic frequency position between 200 Hz and 8000 Hz into [0, 1]. Below the energy floor the centroid is undefined, so the feature decays toward zero rather than jumping.
- **onset**: half-wave rectified spectral flux, the sum of per-bin magnitude increases since the previous frame, normalized by a running median. A flux crossing of the threshold fires one event carrying energy clamped to [0, 1], and a refractory window of 100 ms holds further firings.

### 5. Normalization against unknown gain

Each normalized feature tracks a floor and a ceiling in decibels. The floor rises slowly and falls instantly, tracking the noise floor. The ceiling rises instantly on a louder frame and decays slowly, holding recent peaks. The feature is the level's position inside that window, clamped, with a minimum window width so silence divides by nothing. The result adapts to any microphone gain within seconds and needs no configuration, which is the shipped pedagogy: plug in, play, see.

Rejected: a fixed dBFS mapping, which bakes one microphone's gain into every number. Rejected: a full automatic gain control on the samples themselves, which would alter what the other features measure. Rejected: a calibration control ("set loudest" pin or input gain slider), so adaptive normalization stands alone and a manual anchor waits on measured need.

### 6. Where smoothing lives

The core emits features conditioned only as their definitions require: the FFT window, the normalization tracking, the flux differencing. No fixed attack or release is layered on top. The matrix row's `slew` is the musical smoothing, applied where the user chose it, and meters show what the core emits so a transient is visible as itself.

Rejected: a core-side attack and release per feature, which would double-smooth under row slew and hide from the meter exactly what the onset detector needs visible.

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

One sum type serves the panel: `Disconnected` (never asked or turned off), `Requesting` (prompt open), `Connected` (stream live), `Denied` (permission refused), `Silent` (connected with loudness under the floor for three seconds, the state that answers "is it broken or is the room quiet"). The push of decision 8 carries the state's name in its payload, and the panel renders it without restating any threshold.

### 10. Shipped default rows

Six rows, each touching exactly one target so cause reads clearly (couplings verified at `src/ui/state/sim_config.nim:43-57`):

| Source | Row | Target | Depth | Why this pairing teaches |
|---|---|---|---|---|
| audio:loudness | Modulate | forceStrength | +0.25 | The room's energy animates the species dance, the first coupling a user meets |
| audio:bass | Modulate | fluidStrength | +0.30 | Bass is felt as pressure, and the fluid is pressure |
| audio:mid | Modulate | rdDeposit | +0.20 | The music's body feeds the substrate the chemistry grows on |
| audio:brightness | Modulate | rdFieldForce | +0.25 | Bright timbre makes particles heed the chemical field |
| audio:high | Modulate | glowIntensity | +0.25 | Sparkle brightens the halo the particles already wear |
| audio:onset | Touch | blast at the view's center, a one-cell grid with baseNote 0 | energy as strength | A drum hit visibly shoves the world where the eye rests |

`audio:high` lands on the render store rather than a fifth coupling, keeping the one-coupling-per-row teaching, and on `glowIntensity` over `bloomIntensity` because the bloom slider sits dormant while bloom is off (`src/ui/api/param_descriptor.nim:507-509`) where the glow is always in the picture. Steady hiss settles to zero under the adaptive floor, so only high-band content above it sparkles. Depths are starting values pinned by tests and refined against the running world (docs/engineering-principles.md, article 10). Every row's depth has zero in range, the house idiom.

Rejected for onset's target: a random cell, which reads as noise until the mapping is understood, and the loudest band's spatial position, which the substrate register would earn later but a blast cannot explain today.

### 11. Native test plan

The core is pure, so tests construct bin arrays directly:

- A single-bin spectrum at 440 Hz: brightness lands at 440's logarithmic position within tolerance, bass and high near zero.
- Energy confined to one band per case: that band's feature leads, the others stay low.
- A click train at a known period: onset events at the expected frames, none inside the refractory window.
- Silence, all bins negative infinity: every feature exactly zero, no NaN, and the state stays finite.
- A gain step of 20 dB up and down: every feature returns inside (0, 1) within a bounded frame count, proving the adaptive window.
- A fuzz sweep over random finite arrays: every feature in [0, 1], never NaN, the total function property.

The capture chain itself is browser territory, verified by the build and by the measurement gate spike, never mocked (openspec/config.yaml testing context).

### 12. Help

One new help file with the three-line front matter (`src/ui/api/help_content.nim:46-51`), keyed through `ReservedHelpKeys` (`src/ui/api/help_content.nim:38-40`), the mechanism the sibling design's help file uses as well. Content sketch: what the listen control does and that sound never leaves the app, the permission prompt and how to revisit a denial, the six sources described in room terms (loudness as the room's energy, bass as its weight, brightness as its sparkle, onset as its hits), what the meters show, and what the shipped rows do with an invitation to remap them.

## Risks / Trade-offs

- [Microphone permission inside the webui-launched window is unproven] → the proposal's measurement gate spike runs before capture work, and on refusal the affordance reports unavailability while the core stays fully testable.
- [Adaptive normalization pumps on strongly dynamic music, quiet passages reading louder over time] → slow ceiling decay bounds the effect, depths ship modest, and a manual pin arrives as a follow-up if the pumping proves audible.
- [The 42.7 ms analysis window smears events shorter than a frame] → the consumer runs at frame rate, and the click-train test pins what granularity the detector actually achieves.
- [Slider shading for audio modulation updates on channels owned by the sibling change, at cadences designed there] → the sibling design pins excursion shading to the stats push cadence, roughly 500 ms, and states the limit in its matrix contract, while this change's meters carry the fast view of audio itself.
- [Two Float32Array copies and 1024-bin arithmetic per frame on the main thread] → the weathers already spend a comparable per-frame budget on this loop (`src/app.nim:244-269`), and the gate spike doubles as the place to watch frame time.

## Migration Plan

No deployment or data migration. `midi-interface` lands the matrix spine first, so every step here starts against a matrix that already exists. Implementation order within the change: gate spike, then the binding and capture chain behind the affordance, then the feature core with its tests, then matrix registration, then meters and states, then shipped rows and help. Rollback is removal of the affordance and the family registration, leaving any user rows naming audio sources inert and visible per interface need 5.
