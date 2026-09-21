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
- Turning Listen off re-initializes the analysis state (`stopListening`, `src/audio_input.nim:118-127`), and a press while a listen is live does nothing (`startListening`, `src/audio_input.nim:110-112`). So a room learned at Listen start is relearned by turning Listen off and on.
- The listen state's names cross to the panel as a string union (`ListenState`, `web-ui/src/garden-api.ts:160-165`), and the switch reads checked for the states in `CHECKED_STATES` (`web-ui/src/lib/audio-section.ts:8-12`).

Web Audio facts relied on: `fftSize` is the FFT window size in samples, a power of two, default 2048 (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/fftSize). `frequencyBinCount` is half of `fftSize`, and `getFloatFrequencyData` fills a Float32Array with decibel values for bins spread linearly from 0 Hz to half the sample rate, with silent bins at negative infinity (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/getFloatFrequencyData). `smoothingTimeConstant` averages successive frequency frames in the browser, 0 meaning no averaging (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/smoothingTimeConstant). An AudioContext created outside a user gesture starts suspended, and `resume()` inside interaction unlocks it (https://developer.chrome.com/blog/web-audio-autoplay).

## Goals / Non-Goals

**Goals:**

- Every number from bins to features owned by Nim, natively provable: band edges, window constants, gates, thresholds, the learning window.
- Features that stay in [0, 1] for any finite input, any microphone gain and any Room Gate setting, with no NaN ever crossing the boundary.
- A quiet room that reads as zero, so `Silent` is reachable and room noise drives no row, while a held note or a soft legato passage keeps its reading for as long as it sounds.
- A capture chain whose lifecycle is legible from the panel: what the microphone state is, when the room is being learned, and that stopping truly stops it.
- Design that holds under either implementation order relative to midi-interface.

**Non-Goals:**

- No matrix mechanics: rows, arbitration, and flush belong to the sibling change.
- No perceptual loudness standard (LUFS or similar): the features serve expression, and a five-line RMS serves it as well as a gated integrator would.
- One descriptor parameter only, the Room Gate. Audio adds no other entry to the descriptor table: no input gain, no per-feature gate, no silence threshold.
- No tracking of the room after Listen starts. A room that changes mid-set is the performer's call, through the Room Gate or by turning Listen off and on (decision 5).

## Decisions

### 1. Capture chain and lifecycle

The listen control's click creates the AudioContext, calls `getUserMedia` for audio with `echoCancellation`, `noiseSuppression`, and `autoGainControl` each requested `false`, and wires MediaStreamAudioSourceNode into an AnalyserNode connected to nothing further. The three are `MediaTrackConstraints` entries (https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackConstraints), each a preference the browser may decline, and their defaults are the browser's own and change across versions. The browser's gain control would move the level under decision 5's learned room, and noise suppression removes the sustained tones a pad or a held note carries. The measurement gate reads the granted track's settings back through `getSettings()` (https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamTrack/getSettings) and reports which of the three the launched window honored, which is the only statement about defaults this design relies on. Creating the context inside the gesture satisfies the activation policy in the same click that asks permission. Turning listening off stops the MediaStream tracks and closes the context, so the operating system's microphone indicator goes dark and the affordance's claim of silence is true at the OS level. Listening never starts on launch or on preset load: the click is the consent, every session (docs/engineering-principles.md, article 11).

Rejected: the browser's default processing, which is tuned for a voice call and competes with the feature core for the signal's level and sustain. Rejected: suspending the context while keeping the stream, which keeps the microphone indicator lit while the app claims not to listen. Rejected: one context created at startup, which arrives suspended and couples an unrelated lifecycle to the affordance.

### 2. Analyser configuration

`fftSize` 2048 and `smoothingTimeConstant` 0, both set explicitly from constants in the Nim binding, with the conditions beside them. At a 48000 Hz input, 2048 samples give a 23.4 Hz bin width and a 42.7 ms window. The zero smoothing constant is the decision that all conditioning lives in the feature core, where tests can hold it.

Rejected: the analyser's default 0.8 smoothing, which averages in the browser where no native test reaches it and which cannot express the asymmetric response a meter or an onset wants. Rejected: `fftSize` 4096, whose 85 ms window smears transients across five rendered frames. Rejected: 1024, whose 46.9 Hz bins leave the bass band about five bins wide.

### 3. What crosses into the feature core

Once per frame, the wiring copies two arrays and hands them to the core with the sample rate, the frame's wall-clock delta, and the Room Gate offset in decibels: the frequency array (1024 decibel values) and the time-domain array (2048 samples). The delta is what holds decision 4's refractory window, decision 5's learning window, held level and ceiling decay in wall-clock terms at any frame rate, since the same constant counted in frames spans half the seconds at 120 fps that it spans at 60. The sibling design takes the same input for the same reason, computing each row's attack and release in the pure matrix from the frame's wall-clock delta (openspec/changes/midi-interface/design.md, D4). The Room Gate arrives per frame rather than as core state, so the core stays a function of its inputs and a slider move lands on the next frame with no reset. The core is the one implementation from arrays to features: it converts decibels to linear magnitude, treats negative infinity as zero, and owns every constant. The wiring in `src/canvas_input.nim` style does nothing but poll, copy, read the gate, and call.

Rejected: deriving any feature in JavaScript or in the panel, which would put numbers outside Nim's ownership and outside native tests. Rejected: counting the refractory and the learning window in frames, which ties every audio constant to the display's refresh rate and lets one drum hit double-trigger at 120 fps where it fired once at 60. Rejected: storing the Room Gate inside `AnalysisState`, which `stopListening` re-initializes (`src/audio_input.nim:127`), so a stop would silently reset the user's setting.

### 4. Feature definitions

Band edges at 250 Hz and 2000 Hz, with the bass band starting at 20 Hz and the high band ending at 8000 Hz. Below 20 Hz is rumble, above 8000 Hz is mostly consumer microphone hiss, and the two inner edges split roughly at the voice fundamental's top and the presence region's bottom.

- **loudness**: RMS of the time-domain frame, in decibels, read against decision 5's learned room.
- **bass, mid, high**: mean linear magnitude over the band's bins, in decibels, each read against its own learned room and gate, since spectral tilt makes one shared window read the high band as permanently quiet.
- **brightness**: the spectral centroid over linear magnitudes between 20 Hz and 8000 Hz, mapped through logarithmic frequency position between 200 Hz and 8000 Hz into [0, 1]. The centroid is defined only on a frame where at least one band's level stands above its room edge. Otherwise it is the room's own timbre, and the feature decays toward zero rather than jumping. The absolute energy floor stays only as the guard against a denormal spectrum.
- **onset**: half-wave rectified spectral flux, the sum of per-bin magnitude increases since the previous frame, normalized by a running median. A flux crossing of the threshold fires one event carrying energy clamped to [0, 1], only on a frame whose loudness level stands above its room edge, and a refractory window of 100 ms holds further firings. The flux median keeps tracking while the room is learned, so the first frame after learning has a baseline.

Both gates read the level against the room edge, not the feature against zero, so the 24 dB range under the held level (decision 5) never opens them.

Gating brightness and onset on the room edge is what makes "the room reads as zero" hold for all six sources. Measured on the shipped core in a synthetic stationary room, brightness reads p50/p90 0.10/0.44 and two onsets fire in 25 s. The live room read brightness at about 35% [.?] (scratchpad/audio-interface/room-gate-design__13-09-26-1800.md; the live value is the lead's screenshot reading). Onset is the sharper half: the shipped onset row pulses `forceStrength` (decision 10), so a stray onset in a quiet room shoves the whole world, which is the defect itself rather than a side effect of it.

### 5. The room, learned at Listen start and then frozen

**The problem, and what would show it sits elsewhere.** A quiet room observed live read loudness 8-35% and never reached `Silent` (scratchpad/audio-interface/live-verify__13-09-26-lead.md) [.?]. The previous revision answered with a noise floor that kept learning while Listen ran, and the critique measured it zeroing a held 12 dB drone by 6.1 s and reporting `Silent` 5.4-11.8 s into a soft legato passage (scratchpad/audio-interface/critique__13-09-26-room-gate.md, findings 1 and 2) [.?]. Anything that keeps learning what it hears learns a held note as room. The user decided that the room is learned only in the first seconds after Listen connects, then frozen. The falsifier is task 6.2: in a live room with no appliance changing state, if a meter holds above 0.05 at rest or `Silent` never arrives, then the fault sits in the gate calibration and not in the room estimate moving.

**The room's states.** One `RoomEstimate` per `AnalysisState`, covering loudness and the three bands together:

| State | Constructor | Holds | Unreachable by construction |
|---|---|---|---|
| Learning | `learning(heard, heardSeconds)` | each level heard so far, and the heard seconds | an edge read before any frame exists (so there is no seed value and no first step to rate-limit), and `Silent` judged against a partial room |
| Learned | `learned(roomDb)` | one room level per feature | a room level that moves while a sound holds, and a buffer that keeps growing after learning |

This is a Nim object variant with `case learned: bool`. Two runtime checks stay. `max(ceiling - lower, MIN_WINDOW_DB)` keeps the division finite: the Room Gate arrives per frame and can lift the edge above the ceiling, so no type can remove it. The clamp to [0, 1] stays because a level may sit below its edge.

Each feature also keeps `recent: seq[HeardFrame]`, a level with its heard seconds, trimmed to `HELD_SECONDS` of heard seconds while keeping at least one frame. A frame with zero heard seconds is not stored. So the buffer holds at most `HELD_SECONDS` over the shortest frame delta that arrives, and at display rates that is one frame per refresh [?]. No type bounds it. The empty case, before any frame with a nonzero delta, reads the frame's own level as held, so the median is always defined.

The core's report becomes `RoomReading`, replacing `AudioFeatures.silent: bool`:
- `rrLearning`: the room is not yet learned.
- `rrSounding`: loudness stood above its edge within the last `SILENCE_SECONDS`.
- `rrSilent`: loudness has sat at or under its edge for `SILENCE_SECONDS`.

This removes "silent while learning", which a bool plus a separate learning flag would allow. `ListenState` gains `lsLearning = "Learning"` (decision 9), and `pollAudioFrame` maps the three readings one to one onto `Learning`, `Connected` and `Silent`.

**The mechanism.**

- **Learning.** After a fresh `AnalysisState`, each frame adds each normalized feature's level to the buffer, and every feature reads zero. No onset fires, and the reading is `rrLearning`. The frame adds `min(dtSeconds, ANALYSER_FFT_SIZE / sampleRate)` to the heard seconds, since a frame's arrays describe at most one analyser window of audio. So a long first frame, such as a tab returning from the background, cannot end learning on a handful of frames. When the heard seconds reach `ROOM_LEARN_SECONDS`, each feature's room level becomes the median of its buffer, and the buffer is dropped.
- **Frozen.** The room level never rises and never falls for the rest of the listen. Turning Listen off and on re-initializes the state and learns again.
- **The reading.** Each feature keeps two recent levels.
  - The *held level* is the time-weighted median of the last `HELD_SECONDS = 1.0` of heard audio. Each frame is weighted by the heard seconds learning counts, `min(dtSeconds, ANALYSER_FFT_SIZE / sampleRate)`.
  - The *ceiling* rises instantly to any level above it. Otherwise it decays toward the larger of the held level and the level, at `CEILING_DECAY_SECONDS = 1.0`, the user's choice under "The range reads under a held level".
  - The lower edge is `max(room + gate + frame.roomGateDb, held - RANGE_DB)`, with `RANGE_DB = 24.0` (below). The feature is `clamp((level - lower) / max(ceiling - lower, MIN_WINDOW_DB), 0, 1)`.
  - The window floor and `FLOOR_RISE_SECONDS` are deleted, because the window floor rising under a held level is the fade.
- **Silent.** `Silent` is loudness's level at or under its lower edge for `SILENCE_SECONDS`. It is judged on the level, not on the feature, so no second threshold exists. `SILENCE_LOUDNESS` is deleted.

**The constants and their conditions.** All are measured through the emulated analyser (fftSize 2048, 48 kHz) over two stationary synthetic rooms: 80 Hz rumble at -60 dBFS with hiss at -75 dBFS, and white hiss at -70 dBFS. Each takes the larger value from 60 and 120 fps (scratchpad/audio-interface/frozen-room-design__13-09-26-2032.md, `scratchpad/audio-interface/probe/frozen_room_probe_v5.nim`).

- `ROOM_LEARN_SECONDS = 3.0`.
  - The median gates stop moving by 2 s: at 2, 3 and 10 s they agree within 0.15 dB on every feature at both rates.
  - The learned median's spread from seed to seed (p95-p5) is widest in the bass: 2.16/1.59 dB at 0.5 s, 0.95/0.61 at 2 s, 0.78/0.71 at 3 s.
  - A median disregards any burst covering less than half its window, so 3 s absorbs a disturbance shorter than 1.5 s at Listen start, such as a chair or the click itself (the native test uses a 1.2 s burst).
  - A longer window buys under 0.3 dB of spread and costs the performer a longer hold at every press.
- **The median, not a higher quantile.** A 0.2 s cough 30 dB over the room at 1.5 s moved the learned loudness edge +0.15 dB (+0.19 at 120 fps) under the median and +1.18 dB under p90. The maximum takes the cough itself.
- `ROOM_GATE_BASS_DB = 6.0`, `ROOM_GATE_MID_DB = 2.6`, `ROOM_GATE_HIGH_DB = 1.4`. Each is the p99.9 of level minus learned median over the calibration rooms at a 3 s window (bass 5.92/5.86, mid 2.54/2.52, high 1.31/1.33), rounded up to 0.1 dB. Bass is widest because its band holds ten bins, and a mean over few bins flickers most.
- `ROOM_GATE_LOUDNESS_DB = 5.4`. This is the p99.9 excess (3.62/3.66) plus the largest excess of any calibration frame over that p99.9 edge (1.74/1.71 across 128640 frames). `Silent` reads this edge directly, so no calibration room frame resets the silence clock, and no hysteresis constant exists.

**Whether the room may fall after learning: no.** A floor allowed to follow the room down ratchets to the quietest moment a cycling source makes. The measured cost of learning at the trough is the whole case: an HVAC swinging ±8 dB over 30 s, learned at its trough, reads loudness p50/p90 0.24/0.80 and is `Silent` 20% of the time. The same HVAC learned at its peak reads 0.00/0.00 and is `Silent` 100%. A room that truly gets quieter costs nothing under a frozen room: its noise sits further under the edge.

**The range under the peak: 24 dB, the user's choice.** While music plays, the lower edge also rises to 24 dB under what the meter recently heard, so a meter spreads over the top 24 dB of it rather than over everything from the room up. How the music's dynamics spread across a meter is the user's call, and the user chose 24 dB from these measurements, taken on synthetic music heard 10-40 s after a room, as p10/p50/p90, with the shipped window beside for scale. This table was measured with the range hung from frame peaks, which the next paragraph replaces, and `RANGE_DB = 24.0` carries its 24 dB row as its condition:

| Lower edge | loudness | bass | high | a soft pad after loud music reads zero for |
|---|---|---|---|---|
| shipped window (for scale) | 0.01/0.29/0.66 | 0.02/0.73/0.92 | 0.00/0.02/0.56 | reads Silent |
| room edge only | 0.80/0.87/0.97 | 0.12/0.76/0.93 | 0.00/0.00/0.53 | 1.18 s (the pad's own 2 s attack) |
| `RANGE_DB` 24 | 0.66/0.78/0.95 | 0.00/0.59/0.88 | 0.00/0.00/0.43 | 1.33 s |
| `RANGE_DB` 12 | 0.33/0.57/0.90 | 0.00/0.18/0.76 | 0.00/0.00/0.00 | 2.98 s |

The drone, legato and quiet-room behaviors are identical under all three. A range adds no fade, because the held level follows a held sound and `held - RANGE_DB` stays under it.

What 24 dB buys: loudness moves across 0.66-0.95 through dense music rather than sitting at 0.80-0.97, while bass (median 0.59) and high (up to 0.43) keep most of the shipped spread. What it gives up: a soft sound more than 24 dB under a loud one just heard reads zero for a moment, which a pad after loud music measured as 1.33 s under frame peaks and 1.18 s under the held level (the pad's own attack), and 12 dB would have spread loudness wider (0.33-0.90) at the cost of the high band. Undoing it is one constant: removing `RANGE_DB` gives the edge-only readings, and changing it moves every test that pins a reading under music, which today is none.

**The range reads under a held level, not a frame peak.**

*The problem, and what would show it sits elsewhere.* The previous revision hung the range from the ceiling, which rises to any single frame. The critique measured a drone 12 dB over a learned room reading 0.551, then 0.0 from +0.1 s to +2.0 s after one full-scale frame, 0.26 at +3 s and 0.42 at +5 s. Hits 10-30 dB over the drone did the same (scratchpad/audio-interface/critique__14-09-26-frozen-room.md, finding 1) [.?]. The scratch test of task 2.5 reproduces it: 124 frames at zero after one analyser window at full scale (`scratchpad/audio-interface/probe/core_frozen/held_red_output.txt`). The shipped onset and loudness rows both drive `forceStrength`, so every drum hit over a pad removed the pad's pull for seconds. The ceiling did two jobs: it was the top a reading divides by, and the reference the range hangs from. Only the second job can zero a sound, so the mechanism gives that job to the held level. The falsifier is the same test on the held-level core. If a held sound still reads zero through a hit shorter than half a second, the zeroing comes from somewhere other than the range reference.

*`HELD_SECONDS = 1.0`, and its condition.* A median disregards whatever covers less than half its window, so a sound must hold for half a second to move the range. The measurements run through the emulated analyser, against a drone 12 dB over the room, with one sound at 20 s (`scratchpad/audio-interface/probe/frozen_room_probe_v7.nim`; outputs `v7_sweep_800hop_output.txt`, `v7_fine_800hop_output.txt`, `v7_fine_400hop_output.txt` and `v7_half_800hop_output.txt` beside it). Six sounds:
- a 1 ms and a 20 ms full-scale click;
- a 60 Hz kick 20 and 30 dB over the drone, decaying at 80 ms;
- a noise snare 30 dB over, decaying at 150 ms;
- a 250 ms tone 24 dB over.

Under a 1.0 s window, none of the six zeroes the drone at any ceiling decay measured, at 60 or 120 fps. Under a 0.5 s window, the 250 ms tone (half the window) drops the drone to 0.06, where under 0.75 s and 1.0 s windows it reads 0.23-0.25, which is the ceiling's shrink alone. A 1.0 s window also leaves the snare's body under half the window: the snare stays within 24 dB of its peak for 2.76 × 150 ms, 0.41 s, and about 0.45 s with the analyser window added. A longer window lengthens how long a loud sustained sound keeps the range after it stops: half the window, measured below as 0.50 s.

*What the held level moves, and the ceiling decay the user chose.* Every option moves the table the user chose. The frame-peak row is not among them, since it is the defect. The ceiling decay still sets how long one hit shrinks a held sound's reading, because the reading divides by the ceiling. That duration trades directly against how far the meters spread through music, and the user chose 1 s from the table below. `CEILING_DECAY_SECONDS = 1.0` carries its 1 s row as its condition.

The measurements, on synthetic music 10-40 s after a room (p10/p50/p90, 60 fps). A 120 fps run moves every figure by at most 0.06, where the frame-peak row itself moved by up to 0.07. The click columns come from the scratch core (`scratchpad/audio-interface/probe/held_collision_probe_output.txt`), and the kick and pattern columns from the analyser probe.

| Range reference, ceiling decay | loudness | bass | high | pad after music reads zero (+8/+15 dB) | one full-scale click: held drone under half its reading / back within 10% | kick 30 dB over: drone min / under 90% | kicks every 500 ms, 20 dB over a pad: pad median (0.81 alone) |
|---|---|---|---|---|---|---|---|
| frame peak, 3 s (the user's table, the defect) | 0.66/0.78/0.95 | 0.00/0.59/0.88 | 0.00/0.00/0.43 | 1.33/1.02 s | reads zero 2.07 s | 0.00 / 4.32 s | 0.38 |
| held level, 3 s | 0.72/0.82/0.96 | 0.00/0.70/0.90 | 0.00/0.00/0.53 | 1.18/0.52 s | 3.03 s / 5.88 s | 0.23 / 4.37 s | 0.41 |
| held level, 1 s | 0.74/0.84/0.97 | 0.00/0.74/0.93 | 0.00/0.00/0.60 | 1.18/0.52 s | 1.00 s / 1.95 s | 0.26 / 1.37 s | 0.45 |
| held level, 0.25 s | 0.80/0.89/0.99 | 0.00/0.81/0.96 | 0.00/0.00/0.63 | 1.18/0.52 s | 0.25 s / 0.48 s | 0.40 / 0.22 s | 0.62 |

The question put to the user was how long one loud hit may shrink a held sound's reading. The largest move from the user's table, per option:
- **3 s**, the shipped value. The table moves least: bass median +0.11, high p90 +0.10, loudness +0.06 at most. A full-scale click holds a held pad under half its reading for 3 s, never at zero. Rejected by the user: a hit shrinks a held sound for 3 s.
- **1 s, chosen.** High p90 +0.17, bass median +0.15, loudness +0.08. A click holds a pad under half its reading for 1.00 s, and the pad is back within 10% by 1.95 s. Undoing it is one constant, and the table row above names what each alternative gives.
- **0.25 s.** Bass median +0.22, high p90 +0.20, loudness p10 +0.14. A click barely registers on a held pad, and a drum pattern shrinks a pad least (0.62). Loudness through dense music then sits across 0.80-0.99 rather than 0.74-0.97. Rejected by the user: the meters spread least through music.

Under every answer, the red test of task 2.5 and the full scratch suite pass (23 of 23 at 3, 1 and 0.25 s: `scratchpad/audio-interface/probe/core_held/suite_top3000_output.txt`, `suite_top1000_output.txt`, `suite_top250_output.txt`). The test reads the constant rather than a number. The help's meters sentence gains how briefly a hit shrinks a held sound: about a second.

*What the held level gives up, beside what it buys.* It buys a held sound that never reads zero through a hit shorter than half a second. It gives up a range that answers within a frame: a loud sustained sound keeps the range for half a second after it stops. Undoing it is one line of `track` and one constant. The price is the collapse measured above.

*Rejected ceilings, each measured at 24 dB through the same probe:*
- **An attack time on the ceiling** (50-500 ms). At 50 ms a 20 ms click still holds the drone under 90% for 4.5 s. At 500 ms clicks pass, but a 250 ms tone drops the drone to 0.41 and the snare to 0.44, and the table moves to loudness 0.79/0.91/1.00. Any attack slow enough to reject a hit misses the music's own peaks.
- **A ceiling taken from a smoothed level** (a 50-250 ms decibel average). On every hit its lowest drone reading matches the attack of the same time constant within 0.01, and it moves the table further: loudness 0.84/0.96/1.00 at 250 ms.
- **A sustained-level ceiling doing both jobs** (the lowest level of the last 75-250 ms). Clicks pass. A 30 dB kick drops the drone to 0.11 at 75 ms, the snare to 0.07-0.32, and the 250 ms tone to 0.00-0.08. The music's peaks clip, so p90 reads 1.00 on every feature.
- **A percentile ceiling doing both jobs** (p75 or p90 of 1-3 s). Peaks above the percentile clip: music loudness p90 reads 1.00, and figures move by up to 0.57. Over a 3 s window a pad after music reads zero for 1.9-2.7 s.
- **A sustained minimum as the range reference, with a separate ceiling** (75-250 ms). A decaying hit holds its level longer than a short minimum's window. The snare still drops the drone to 0.07-0.08 at 100 ms and 0.21-0.32 at 250 ms.
- **The p75 of the last second as the held level.** The 250 ms tone drops the drone to 0.05.
- **A 0.5 s held window.** The 250 ms tone drops the drone to 0.06.
- **A time-weighted mean as the held level.** Every sound moves it in proportion to its share of the second, so 0.4 s at +20 dB lifts the edge 8 dB, and a sound 20 dB under the drone reads zero. It passes the single-hit test, so task 2.5 gives it a test of its own.
- **The mean of the middle half of the second as the held level** (the levels between its quarter and three-quarter marks). Rejected by the user. It removes the zero frames of a 30 dB gate at 40% and 50% ±10% shares (flicker 0.067 at 40%), but still zeroes 14-20% at 60%. In the pump probe's steady 40% gate, loudness p10 falls from 0.45 to 0.29. The 0.55 s tone 24 dB over the drone no longer zeroes it (minimum 0.22), but a 1 s one zeroes it for 0.25 s. A full-scale sound of 0.35 or 0.45 s holds the drone under half for 1.18 or 1.32 s, back within 10% by 2.27 s at 0.45 s, against 1.00 s and 1.95 s under the median. The table moves by at most 0.01. It would have narrowed the spec's half second to a quarter, retuned the mean test to a 0.2 s full-scale sound, and needed a bound on the wall-clock test, which differs across deltas by 0.001 (`scratchpad/audio-interface/probe/v7_pump_800hop_output.txt`, `iqm_collision_probe_output.txt`, `iqm_duty_jitter_probe_output.txt`, `core_iqm/suite_bare_output.txt`, `quarter_runs/`).
- **A held window counted in frames.** Sixty frames span 1 s at 60 fps and 0.5 s at 120 fps, so a 0.3 s sound becomes the median at 120 fps. It passes the single-hit test at 60 fps, so task 2.5 gives it a test at 8.33 ms deltas.

**Measured, synthetic (same record):**
- Stationary and hiss rooms reach `Silent` 3.00 s after learning ends, and hold it 99.1% of 5-120 s over 8 seeds, the remainder being learning and that first 3 s. Every level feature reads 0.00 at p99.
- A room drifting ±3 dB holds `Silent` 98.8% of the time (worst seed 96.5%). At 120 fps it holds 98.5% (worst 93.9%), with high at 0.03 at p99.
- A drone held 60 s after the room reads loudness 0.18/0.19/0.23 at 12/30/69 s at +7 dB, 0.57/0.58/0.60 at +12 dB, and 0.95-0.97 at +20 dB. The shipped window floor over the same edge read 0.41/0.03/0.05 at +12 dB. No `Silent` frame falls after the drone's first 0.5 s.
- Soft pads 8 and 15 dB over the room, after music, give no `Silent` frame.
- `Silent` arrives 3.03 s after music stops. A tone 12 dB over the room clears it on the next frame, reading 0.49 at 60 fps and 0.29 at 120.
- The native tests of task 2.5 run against a scratch copy of the core with this mechanism: red on the shipped core, green at 24 dB and at the two rejected ranges (`scratchpad/audio-interface/probe/core_shipped/new_reds_output.txt`, `scratchpad/audio-interface/probe/core_frozen/new_reds_ranges_output.txt`). The hit test is red on the frame-peak core and green on the held-level core (`scratchpad/audio-interface/probe/core_frozen/held_red_output.txt`, `scratchpad/audio-interface/probe/core_held/`).
- The drone, pad and room figures above were measured under frame peaks. Under the held level at each ceiling decay, the +7 and +12 dB drones, the HVAC room and the drifting room read the same to 0.01, with the same `Silent` shares (`scratchpad/audio-interface/probe/v7_drones_800hop_output.txt`). Pads after music read zero for less time (the table above). Rerun under the held level, a 20 dB gain step up and back on music leaves no `Silent` frame. In the 10 s after the step back, loudness p10 is 0.61 at the chosen 1 s decay (0.52 at 3 s, 0.76 at 0.25 s), against 0.26 under frame peaks. A 10 dB drop gives no `Silent` frame, and loudness p50 falls from 0.84 to 0.82 at 1 s (`scratchpad/audio-interface/probe/v7_gain_800hop_output.txt`).

**Designed but unexercised:** the gates in a real room, a loud room, a real cycling appliance, the Room Gate below zero, and real drums over a held sound.

**The costs, measured, and who carries them.** Each is carried by the performer and answered by turning Listen off and on, or by the Room Gate.

- **Listen pressed mid-music.** The music is learned as room. Loudness reads p50/p90 0.00/0.00 and mid 0.00/0.24 until Listen is turned off and on, and `Silent` came 2.53 s after the music stopped. The user accepted this, and it is why no "the room is quiet now" button ships.
- **An appliance that cycles after learning.** A compressor that starts after learning, 12 dB over the room, drives loudness to p90 0.53 and leaves `Silent` 66% of the time. Learned while running, it reads 0.00/0.00 and is `Silent` 100% of the time. So the help advises pressing Listen with the room as it will be, or raising the Room Gate.
- **Input gain moved after learning.** This is arithmetic on the frozen edge. Lowering the gain by X dB moves every sound X dB toward the edge, and a sound within X dB of it reads zero. Raising it lifts the room over its edge, so the room reads as sound and `Silent` stops coming. Measured against the shipped core (`src/ui/input/audio_core.nim`, which carries no learned room or frozen edge yet, so this reads the continuously-adapting window's own response to the same step): a 20 dB up-step on music moved loudness p50 from 0.27 to 0.39, with no `Silent` frame. A 10 dB drop gave no `Silent` frame, with loudness p50 0.27 falling to 0.26 (`scratchpad/audio-interface/probe/gain_step_shipped_core_output.txt`).
- **A loud sound held half a second or more, 24 dB or more over a held one.** This is the range the user chose, now applied only to sustained sound. On the scratch core, a tone 24 dB over the drone for 0.55 s or 1 s zeroes the drone for 0.50 s after the tone stops, while the held level drains, at every ceiling decay. The same tone for 0.45 s never zeroes it (minimum 0.22), and 18 dB over for 1 s never zeroes it (minimum 0.25) (`scratchpad/audio-interface/probe/held_collision_probe_output.txt`).
- **A steady drum pattern sets the scale.** A pattern is recent loud sound, so a pad under it reads lower. With kicks every 500 ms 20 dB over a pad, the pad's median falls from 0.81 to 0.45 at the chosen 1 s decay (`scratchpad/audio-interface/probe/v7_sweep_800hop_output.txt`, last column).
- **A loud sound covering half the last second or more, over 24 dB above a quieter one.** The median of the second then sits on the loud sound, the edge 24 dB under it, and the quieter sound reads zero between its bursts. On a pad under a two-level interloper, the pad's own frames read 0.40 at every share when the interloper is 10 dB over, and 0.26 under half, 0.17 from 53%, when it is 20 dB over. At 30 dB over they read 0.19 under half and 0.00 from 53% (`scratchpad/audio-interface/probe/duty_split_probe_output.txt`). The critique's pooled median reads 1.00 from 50% because the interloper's own frames read 1.00 at their median (they set the ceiling) and become the majority of the frames pooled, not because the pad reads 1.00. With the share jittered ±10% per beat around 45-50%, the pad's frames read zero on 30 of 263 and 133 of 237 frames, flickering between 0 and 0.19 (`scratchpad/audio-interface/probe/duty_jitter_probe_output.txt`). Music measured no zero frame: a pad sidechain-ducked 6, 12 or 24 dB under a kick reads loudness p10 0.67 or more, and a kick 20 dB over with 16th hats 10 or 20 dB over reads p10 0.46 or more (`scratchpad/audio-interface/probe/v7_pump_800hop_output.txt`). The user accepted this step over the middle-half mean (Resolved Questions).
- **A capture silent at connect** (a muted interface). The room is learned at the level floor, so every later sound reads, including the room once unmuted. This is arithmetic, and the same off-and-on answers it.

**Rejected, with their costs:**

- **Learning only in pauses** (updating the room while `Silent`, or while every level sits under its edge). A pause is judged against the edge it moves. Each learned pause can lift the edge by up to a gate, so a run of soft passages, each within a gate of the last, ratchets the edge upward without bound. That brings back the held note learned as room, now in steps. It would also need a second clock deciding how long a pause must last. The cost is the drone and legato failures again, on a slower schedule.
- **Very slow learning** (a room that rises at r dB/s). A note held h dB over the room reads zero after (h − gate) ÷ r seconds. At the previous 1 dB/s the critique measured 6.1 s for 12 dB [.?], consistent with (12 − 6.2) ÷ 1 = 5.8 s. Holding a 12 dB drone for 60 s needs r ≤ (12 − 5.4) ÷ 60 = 0.11 dB/s. At that rate a room 10 dB louder takes 90 s to learn, slower than a slider drag. It holds neither the note nor the room, and costs a rate constant with no measured condition.
- **Accepting the fade.** It costs nothing to build. It leaves a held 12 dB drone reading zero by 6.1 s and a legato passage reporting `Silent` [.?], against the purpose the proposal states, and the user declined it.
- **A room that may fall after learning.** Measured above: learned at an HVAC trough, `Silent` 20%. Undo is free, and the cost is carried by every room with a cycling source.
- **The window floor kept over the frozen edge** (the shipped floor with the learned edge beneath it). The +12 dB drone reads 0.03 at 30 s: the floor's 2 s rise is the fade.
- **The p90 or maximum statistic.** The p90 edge moved +1.18 dB for a 0.2 s cough; the maximum takes the cough itself. The p90's smaller gates (2.03/3.25/1.46/0.75) buy nothing the median's larger ones lose, since median plus gate lands on nearly the same edge in a quiet room.
- **The earlier noise floor that kept learning** (p4.8 tracker, 20 dB/s down, 1 dB/s up). It needed a seed value and a first-step rule the text never fixed (critique finding 5), and it fades held notes (findings 1 and 2).
- **Retuning `SILENCE_LOUDNESS` alone** (standing still on the mechanism). The threshold would have to exceed the room's p99 loudness reading (0.46 stationary), so a sound reading below half scale could never clear `Silent`, and the room would still drive every row at 0.19-0.64. Undo is free, and so is the cost it leaves with the user.
- **A silence criterion of its own** (short-term level range, or time since the last loud frame). It makes `Silent` reachable and leaves the room driving rows at the same readings.
- **Widening `MIN_WINDOW_DB`.** The room's several-dB flicker still reads nonzero, and a quiet instrument can no longer reach full scale.
- **A gate scaled by how wide the window is.** Dense music's loudness window is narrow, so loudness read 0.00 at p50, and `Silent` came 7.8 s after the music stopped.
- **A fixed dBFS mapping**, which bakes one microphone's gain into every number. **A full automatic gain control on the samples**, which alters what the other features measure.

### 6. Where smoothing lives

The core emits features conditioned only as their definitions require: the FFT window, the ceiling's decay, the flux differencing. No fixed attack or release is layered on top. The matrix row's attack and release constants are the musical smoothing, applied where the user chose them, and meters show what the core emits so a transient is visible as itself. The shipped audio rows start at a zero attack and an 80 ms release, inside the 20 to 100 ms range audio-reactive practice reports (https://kferg.dev/posts/2020/audio-reactive-programming-envelope-followers), so a hit lands on its frame and the world eases off it. The learned room is fixed state, not smoothing of a feature: a feature's value still follows its level on the frame the level changes.

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

One sum type serves the panel, six states:
- `Disconnected`: never asked, or turned off.
- `Requesting`: the prompt is open.
- `Learning`: the stream is live and the room is being learned, for `ROOM_LEARN_SECONDS` of heard audio.
- `Connected`: the stream is live and the room is learned.
- `Denied`: permission refused.
- `Silent`: connected, with loudness's level at or under its room edge for three seconds, the state that answers "is it broken or is the room quiet".

The push of decision 8 carries the state's name in its payload, and the panel renders it without restating any threshold. The switch reads checked in `Requesting`, `Learning`, `Connected` and `Silent`.

`Learning` is the state that tells the performer to let the room be as it will be. Without it, the first three seconds read `Connected` with every meter at zero, which looks like a broken capture at exactly the moment the room is being learned.

A sound clears `Silent` on the first analysed frame whose loudness level stands above the room edge. Natively that is the next frame. Live, the 42.7 ms analyser window must first fill with enough of the sound: at 120 fps a tone 12 dB over the room read 0.29 on its first frame and 0.49 at 60 fps, so a return can take up to one analyser window.

Rejected: reporting `Connected` through learning. It costs no panel change, and leaves a zeroed, unexplained meter row at every press.

### 10. Shipped default rows

Four audio rows ship (`DEFAULT_MAPPING`, `src/ui/input/shipped_mapping.nim:170-181`), pinned by "the four audio rows ship pinned by source, kind, target and depth" (`tests/test_control_matrix.nim:1413`). All six source declarations still register, so every source stays mappable. Couplings are verified at `src/ui/state/sim_config.nim:43-57`.

| Source | Row | Target | Depth | Envelope | Why this pairing teaches |
|---|---|---|---|---|---|
| audio:onset | Modulate | forceStrength | +0.40 | attack 0, release 300 ms | A hit lifts the force every particle reads, so it reaches the whole world |
| audio:bass | Modulate | fluidStrength | +0.30 | attack 0, release 80 ms | Bass is felt as pressure, and the fluid is pressure |
| audio:loudness | Modulate | forceStrength | +0.25 | attack 0, release 80 ms | The room's energy animates the species dance, the first coupling a user meets |
| audio:high | Modulate | glowIntensity | 0 | attack 0, release 80 ms | Sparkle brightens the halo the particles already wear |

Three rows are live, on two targets: onset and loudness share `forceStrength` and sum there, a transient riding a level on one parameter. One row, `audio:high`, ships at zero depth, which the matrix treats as an ordinary row that keeps its place and moves nothing. Help invites raising it once the live rows are heard. The live rows are the ones whose cause and effect share a kind and a clock: an impulse to an impulse, pressure to pressure, energy to energy. A mapping reads without explanation when it "has a basis within the physical world" and stays inside one time scale (Callear, https://www.seeingsound.co.uk/docs/Audiovisual_Particles.pdf, sections 2.3 and 4.3), and simple correspondences that all fire at once "rapidly cease to be interesting" (Dannenberg, via Callear section 2.2).

`audio:high` lands on the render store rather than a fifth coupling, keeping the one-coupling-per-row teaching, and on `glowIntensity` over `bloomIntensity` because the bloom slider sits dormant while bloom is off (`src/ui/api/param_descriptor.nim:507-509`) where the glow is always in the picture. Steady hiss sits under its room edge, so only high-band content above it sparkles. Depths are starting values pinned by tests and refined against the running world (docs/engineering-principles.md, article 10). Every row's depth has zero in range, the house idiom.

History, kept as recorded:

> 2026-09-12: the audio:mid → rdDeposit and audio:brightness → rdFieldForce rows, which once
> shipped at zero depth, no longer ship; reaction-diffusion is decoupled from audio.

> 2026-09-12: the audio:onset row, first designed as a Touch blast at the view's center, ships as
> a Modulate impulse on forceStrength, depth +0.40 with a 300 ms release, so a hit reaches every
> particle rather than the disc a blast covers; it shares loudness's target and the two sum. The
> blast stays available to Touch rows.

Rejected: every row live. The climate and force-weather tours keep running while listening, and they are the counterpoint that keeps a mapping from going predictable, which Callear's compositions needed "unmapped elements" to supply.

Rejected for onset's target: a blast at the view's center, which reaches only the particles inside its radius while a hit should reach the whole world. Also rejected: a random cell, which reads as noise until the mapping is understood, and the loudest band's spatial position, which the substrate register would earn later.

### 11. Native test plan

The core is pure, so tests construct bin arrays directly. Every test that expects a sound to read first gives the core a learned room: the room helper for `ROOM_LEARN_SECONDS` or more.

- **A held sound keeps its reading.** A drone 12 dB over a learned room: loudness at 60 s within 0.01 of its reading at 1 s, and above 0.1. A soft flat passage 8 dB over the room, after music, never reads silent past its first 0.5 s. The same drone through one analyser window at full scale never reads zero, and returns within 10% of its reading within 2.5 ceiling-decay time constants. A probe 20 dB under a drone 40 dB over the room still reads after a tone 20 dB over the drone covered 0.4 s of the last second, which kills a mean held level. The same shape at 8.33 ms deltas, a tone 12 dB over for 0.3 s and the probe 16 dB under, kills a held window counted in frames. Each goes red on its mutant and on the shipped core, and green on the median (`scratchpad/audio-interface/probe/mutant_runs/`, `scratchpad/audio-interface/probe/core_held/suite_bare_output.txt`).
- **A quiet room reaches Silent.** A room flickering by several dB frame to frame (Rayleigh bin magnitudes, Gaussian samples), after a sounding passage: every level feature reads zero on 99 frames in 100, silent arrives within `SILENCE_SECONDS` plus 0.5 s, and a tone 12 dB over the room clears it on the next frame.
- **Learning.** Every feature reads zero and no onset fires while the room is learned. The first nonzero reading lands one frame after `ROOM_LEARN_SECONDS` at both 8.33 ms and 16.7 ms deltas. A 1.2 s burst inside the learning window is not learned as room. A fresh state learns a louder room as zero.
- **Features.** A single-bin spectrum at 440 Hz over a learned room: brightness lands at 440's logarithmic position within tolerance, bass and high near zero. Energy confined to one band per case: that band's feature leads, the others stay low. A click train at a known period: onset events at the expected frames, none inside the refractory window.
- **Totality.** Silence, all bins negative infinity: every feature exactly zero, no NaN, and the state stays finite. A fuzz sweep over random finite arrays and Room Gate offsets across the descriptor range: every feature in [0, 1], never NaN.
- **Relations.** Lowering the Room Gate never lowers a reading. Every level shifted by the same dB, learning included, changes no feature. Raising the Room Gate above a sound makes it read zero and reach silent, and lowering it brings the sound back.
- **Gating.** In a learned room, brightness decays below 0.01 and no onset fires, even on a flux crossing.
- A gain step of 20 dB up and back over a learned room returns every feature inside (0, 1).

The capture chain itself is browser territory, verified by the build and by the measurement gate spike, never mocked (openspec/config.yaml testing context).

### 12. Help

One help file with the three-line front matter (`src/ui/api/help_content.nim:46-51`), key `audio`. The key leaves `ReservedHelpKeys` (`src/ui/api/help_content.nim:42`), because the Room Gate makes `audio` a descriptor group, and the coverage relation "every descriptor is named by its group's file" then requires the file to name `audioRoomGate` on a code-span line. Content sketch:
- What the listen control does, and that sound never leaves the app.
- The permission prompt, and how to revisit a denial.
- What `Learning` means: the first few seconds after Listen connects learn the room, so press Listen with the room as it will be. Any fan or fridge should already be running, and the music not yet playing. To relearn, turn Listen off and on.
- The six sources in room terms: loudness as the room's energy, bass as its weight, brightness as its sparkle, onset as its hits.
- What the meters show.
- What the Room Gate does. Raise it when the room gets louder mid-set, or when an appliance switches on, until the meters rest. Lower it for a quiet instrument. `Silent` may not come while it sits below zero. It is remembered on this browser, untouched by presets, and audio rows cannot write it.
- What the four shipped rows do: bass into `fluidStrength`, loudness and onset together into `forceStrength`, and `audio:high` into `glowIntensity` waiting at zero depth, with an invitation to raise and remap it.

### 13. The Room Gate control

**Reversal.** Decision 5 once rejected any calibration control and the audio-input spec promised "no numbers to tune". The live verification of 13-09-26 reversed it, and the user chose both an automatic fix and a user-facing attenuation control. The automatic room is learned once, on stationary synthetic rooms' terms. A live set runs in rooms whose noise changes after Listen starts (a crowd arriving, PA spill, an appliance switching on), and a frozen room does not follow them by design. The performer is the one who knows when the room changed, so the control gives them that call.

**What it changes.** One dB offset added to every feature's gate, which moves the lower edge of each reading: how far above the learned room a sound must rise before it moves the world. It does not scale a level before the reading (see Rejected controls) or a feature after it (a row's depth already does that).

- Raising it makes a louder room read as zero and reach `Silent`, and a sound must clear the raised edge to return `Connected`. In the synthetic rooms the default already rests every meter. How far a live loud room needs it raised is task 6.8's check.
- Lowering it below zero lets quieter sounds through and the room's flicker with them. At the range minimum, where the offset cancels the widest gate, loudness's edge sits 0.6 dB under its learned median, so more than half the room's frames stand above it and `Silent` is unreachable. That is arithmetic on the median, unmeasured live.

**The descriptor.** Id `audioRoomGate`, label "Room Gate", group `audio`, float with precision 1. The range comes from `src/config_ranges.nim`. `AUDIO_ROOM_GATE_MIN_DB = -6.0` is the negated widest gate (the bass gate), the offset below which nothing further opens. `AUDIO_ROOM_GATE_MAX_DB = 120.0` is derived from the level span the core can receive. `config_ranges` imports no core, so both are literals there, and `tests/test_audio_core.nim` holds each to the relation it rests on.

The derivation of the maximum:
- `getFloatFrequencyData` reports each bin as unclamped decibels, and `minDecibels` and `maxDecibels` clip and scale only the byte data (https://webaudio.github.io/web-audio-api/#dom-analysernode-mindecibels; `getByteFrequencyData` "clipped to lie between minDecibels and maxDecibels"). So the analyser's -100 dB default bounds nothing the core reads.
- The core clamps every level from below at `LEVEL_FLOOR_DB` = -120 (`src/ui/input/audio_core.nim:44`, `:168`).
- From above, a full-scale input bounds every level at 0 dBFS: an RMS over samples in [-1, 1] is at most 1. A bin's magnitude, the windowed transform divided by N, is at most the Blackman window's mean weight (0.42) times the peak sample, so a band's mean is at most about -7.5 dB.
- So every level lies in [-120, 0] dB, and every learned room level is at least -120. An offset of 0 − (−120) = 120 dB puts every lower edge at least the smallest gate above full scale, where every feature reads zero. A larger offset changes nothing further.

The full-scale bound is nominal, not guaranteed: Web Audio carries PCM "with a nominal range of [-1,1] but the values are not limited to this range" (https://webaudio.github.io/web-audio-api/, AudioBuffer). A stream whose samples exceed ±1 could read above zero at the maximum, and task 6.8's kill condition would show it.

**The curve.** The slider travels on `cPower` with exponent 2.5. Over -6..120 dB, of the exponents 1 to 6 in half steps, 2.5 gives the widest share of travel to 0..+6 dB, the first widest-gate's worth above the default: 9.5%, against 9.0% at 2 and 9.4% at 3 (scratchpad/audio-interface/probe/room_gate_curve_output.txt). The default sits at 29.6% of the travel, +6 dB at 39.0%, +12 dB at 45.9%, and half the travel reaches +16.3 dB. A 127-step Write row from a 7-bit controller lands 12 steps inside 0..+6 dB. Travel below the default is the discouraged region, where `Silent` stops coming, and it gets under a third of the throw. The upper half reaches the capability bound. The default 0.0 (`ROOM_GATE_DEFAULT_DB`) lives in `src/ui/input/audio_core.nim` beside the gates, the way `CAMERA_DEFAULT_ZOOM` lives in `camera_core`, with a notch at the default. The hint names no numerals, and there are no other notches, since no other position has a measured claim behind it. The response probe is `audio.roomEdge`, a closed-form function of the offset over a fixed learned room, the lower edge in dB.

**The store.** A new `ParamStore` member `psAudio`: the value lives in `src/web_api.nim` beside the audio hooks, `audio_input` reads it every poll into the frame, and it never reaches CONFIG. So, like `psCamera`, it is absent from the preset schema by construction, pinned by a test naming it the only `psAudio` id. The exhaustive cases listed in Context each gain an arm, and the build names every one it lacks.

- Rejected: `psRender` or `psSimulation`, which would put the room into every saved preset, so loading a friend's world mid-set would reset the gate.
- Rejected: a bespoke `gardenAPI` setter outside the descriptor table, which would restate range, default, step and help outside the one contract the panel and the matrix already read.
- Rejected: session-only. It buys no storage, and costs re-dragging the gate after every reload in a room the performer has already set for.

**Persistence.** The Room Gate is remembered on this browser, apart from presets.
- `AUDIO_ROOM_GATE_STORAGE_KEY = "pg.audio.roomGate"` lives in `src/ui/input/audio_core.nim` beside the default, and the boundary serves it as `audioKeys().roomGate` the way `matrixKeys().mapping` serves `pg.mapping` (`src/web_api.nim:1641-1644`).
- The panel owns localStorage under it, as `MidiSection.tsx` owns the mapping (`web-ui/src/components/MidiSection.tsx:5`). It restores the value through `setParam` once at mount, and `setParam` clamps it to the range. It writes whenever the synced value differs from the last written one, so a controller's move is remembered too.
- A stored string that parses to no finite number is ignored, and the default stands.
- The key sits outside the `pg.presets.` prefix, so no preset operation reads or clears it.
- localStorage over IndexedDB: one float restored synchronously at mount matches every other persisted value in the panel (`pg.mapping` at `web-ui/src/components/MidiSection.tsx:33-36`, the presets in `web-ui/src/components/PresetsSection.tsx`), where IndexedDB would make this the one asynchronous restore for a value that needs none of its size, structure or queries.

**Mapping.** A Write row reaches `psAudio` through the existing store confinement, so a controller knob maps it with no matrix edit. A Modulate row is refused by the same confinement, since the gate has no stored/effective split to modulate. An audio-family row writing the gate is refused. It would feed a feature back into its own edge a frame later, so a loud passage raises the gate that then silences it, which oscillates at frame rate. `targetRefusal` in `src/ui/input/control_matrix.nim` gains the row's source id and one arm: a source under the `audio:` prefix on a `psAudio` target is refused, naming the loop. The check is syntactic on the source id, so it holds at decode as well, and a stored row of that shape drops on load with its reason. This is the one exception to "the audio family joins the matrix without a matrix edit". Controller rows still write the gate.

- Rejected: allowing the loop and naming it in help. It costs nothing to build, and leaves a mapping that oscillates, which nobody can read as cause and effect.

**Rejected controls:**

- **Input gain.** Before learning, a gain shifts the learned room, the held level, the ceiling and every level together, so no feature moves; the dB-shift property test holds it. After learning, a gain moves levels against the frozen edge, which is the Room Gate with its sign reversed. Either way it is a second slider for one question.
- **Scaling the features after the reading.** It duplicates each row's depth, leaves the room nonzero, and leaves silence measuring unscaled values.
- **A minimum-window-width control.** It changes contrast (how far above the edge full scale sits), not what counts as room, so it would not answer the finding.
- **An absolute dBFS threshold.** It is device-coupled: every microphone and gain setting needs its own value, which decision 5 exists to avoid.
- **One gate per feature.** Four sliders would restate the probe's table to the user, where one offset over measured per-feature gates asks one question.
- **A "relearn the room" button.** Turning Listen off and on already relearns, and the user declined a room-is-quiet gesture.

## Readiness

Guarantees this design rests on, each at its rung:

- Features finite and in [0, 1] for any finite frame: realizedUntested. The shipped fuzz sweep holds the shipped window, and under the frozen room the same sweep passed on a scratch copy of the core at 24 dB (`scratchpad/audio-interface/probe/core_frozen/frozen_suite_output.txt`).
- A held sound keeps its reading, and a legato passage never reads `Silent`: specified. The probe measures it synthetically, the native tests went red on the shipped core and green on a scratch copy of the core, and nothing has been measured live until task 6.2.
- A hit shorter than half a second never zeroes a held sound: specified. Synthetic clicks, kicks, a snare and a tone held it through the emulated analyser, and the red test went red on the frame-peak scratch core and green on the held-level one. Real drums are unmeasured until the hit check in task 6.2. The mean and frame-count substitutions each have a test that goes red on them.
- The room reads zero and `Silent` is reachable: specified. The evidence is synthetic only. A real room is unmeasured until task 6.2, and a real cycling appliance is untested anywhere.
- An input gain applied before learning moves no feature: asserted by the arithmetic of a median and a ceiling under a constant shift. It becomes realizedUntested once the property test is written.
- The Room Gate stays out of presets: specified, by the `psCamera` precedent test-held at `tests/test_param_descriptor.nim:386-395`.
- An audio row cannot write the Room Gate: specified. The store confinement it extends is test-held (`tests/test_control_matrix.nim:296`).
- The Room Gate survives a reload: specified. It is realized in no code yet, and task 6.11 checks it live.
- A Write row can map a routed store and a Modulate row cannot: realizedUntested for `psAudio`. The confinement is test-held for `psPalette` and `psCamera` (`tests/test_control_matrix.nim:296`, `:608`).

Readiness is the lowest rung: asserted. The design is buildable at that rung, since the one asserted guarantee gains its test in task 2.7 before the mechanism lands. Nothing waits on an answer from the user or the lead.

## Risks / Trade-offs

- [Microphone permission inside the webui-launched window is unproven] → the proposal's measurement gate spike runs before capture work, and on refusal the affordance reports unavailability while the core stays fully testable.
- [The launched window may ignore a `false` on one of the three processing constraints] → the gate spike reads the granted track's settings back. A browser that keeps gain control on moves levels against the frozen room, the input-gain cost of decision 5. The connected tab reported all three honored (scratchpad/audio-interface/live-verify__13-09-26-lead.md) [.?].
- [The gates are measured on synthetic rooms] → task 6.2 checks a real room for five minutes with the offset at zero. If a meter holds above 0.05 at rest with no appliance changing state, its kill condition records which, and the constant is re-derived from a live excursion log.
- [The room is learned once, so a room that changes after Listen starts reads as sound] → measured and stated in decision 5. The Room Gate or turning Listen off and on answers it, and the help file says so.
- [Listen pressed mid-music learns the music as room] → accepted by the user. `Learning` on the state line makes the moment visible, and off-and-on relearns.
- [Adaptive ceilings pump on strongly dynamic music, quiet passages reading louder over time] → the ceiling decays toward the held level, so the pumping lasts about the 1 s ceiling decay, and depths ship modest.
- [A steady drum pattern sets the scale, so a pad under it reads lower] → accepted with the 1 s decay: kicks every 500 ms 20 dB over a pad move its median from 0.81 to 0.45 (decision 5, costs).
- [A sound over 24 dB louder, covering half the last second or more, zeroes a quieter sound between its bursts] → accepted by the user with the median: a 30 dB two-level gate zeroes the pad's frames from a 53% share (`scratchpad/audio-interface/probe/duty_split_probe_output.txt`). Sidechain ducking and kick-and-hat patterns zero none (`scratchpad/audio-interface/probe/v7_pump_800hop_output.txt`).
- [A share wandering around half flickers the quieter sound between its reading and zero] → accepted by the user with the median: a 30 dB gate at a 50% ±10% share zeroes loudness on 37% of frames, and at 40% ±10% on 6% with flicker 0.116 (`scratchpad/audio-interface/probe/v7_pump_800hop_output.txt`).
- [One loud hit over a held sound shrinks its reading while the ceiling decays] → the range hangs from the held level, so the sound never reads zero through a hit under half a second. It shrinks for about the 1 s ceiling decay: under half its reading for 1.00 s after a full-scale click, and back within 10% by 1.95 s.
- [The 42.7 ms analysis window smears events shorter than a frame, and a returning sound can take one window to clear `Silent` at 120 fps] → the consumer runs at frame rate, the click-train test pins the detector's granularity, and the spec states the return within one analyser window.
- [Slider shading for audio modulation updates on channels owned by the sibling change, at cadences designed there] → the sibling design pins excursion shading to the stats push cadence, roughly 500 ms, and states the limit in its matrix contract, while this change's meters carry the fast view of audio itself.
- [Two Float32Array copies and 1024-bin arithmetic per frame on the main thread] → the weathers already spend a comparable per-frame budget on this loop (`src/app.nim:244-269`), and the gate spike doubles as the place to watch frame time. The learned room costs four buffers of at most one level per frame for three seconds, and one sort each at the end. The held level costs four buffers of one second of frames, sorted once per frame each, which at 240 fps is 240 levels per feature [?].

## Migration Plan

No deployment or data migration. `midi-interface` lands the matrix spine first, so every step here starts against a matrix that already exists. Implementation order within the change:
1. The gate spike.
2. The binding and capture chain behind the affordance.
3. The feature core with its tests.
4. The frozen room in the core, with the `Learning` state.
5. Matrix registration.
6. Meters and states.
7. The Room Gate descriptor and slider.
8. Shipped rows and help.

Rollback of the Room Gate is removal of the descriptor, the store member and its arms; the core's gate offset input then stays at zero. A stored mapping with a Write row on `audioRoomGate` then names an absent descriptor and is refused on load the way any unknown target is. The value under `pg.audio.roomGate` stays in localStorage, unread. Rollback of the frozen room restores `track`'s window floor and `SILENCE_LOUDNESS`, and brings the live finding back with them.

## Resolved Questions

- The room is learned only at Listen start, then frozen. Room changes mid-set go to the Room Gate, and turning Listen off and on relearns. Listen pressed mid-music learns the music as room until then. The user chose this, and no room-learning gesture ships (decision 5).
- The Room Gate survives a reload on this browser, under a Nim-owned key (decision 13, Persistence). The user chose this.
- An audio source's row may not write the Room Gate. Controller rows may. The user chose this (decision 13, Mapping).
- Each meter spreads over the 24 dB under what it recently heard, never lower than the room edge (decision 5, `RANGE_DB`). The user chose this over the room edge alone and over 12 dB. Its reference is the held level rather than a frame peak, because one hit must not erase a held sound. That is a mechanism repair, and the lead settled it.
- The held level is the median of the last second (decision 5, `HELD_SECONDS`). A quieter sound keeps its reading under a louder one covering less than half the second, reads zero when the louder one covers more and stands over 24 dB above it, and flickers when the share wanders around half (37% zero frames at 50% ±10%). The user chose this over the middle-half mean (Rejected ceilings).
- The ceiling decays at 1 s (decision 5, `CEILING_DECAY_SECONDS`). A loud hit shrinks a held sound for about a second, and the meters spread through music at loudness 0.74/0.84/0.97. The user chose this over 3 s, where a hit shrinks a held sound for 3 s, and over 0.25 s, where the meters spread least.
- The affordance reports a sixth state, `Learning`, while the room is learned (decisions 5 and 9). It tells a performer what is acting, the way the dormancy lines do. The lead settled this.
- Task 6.2's quiet-room check runs five minutes, since a shorter run cannot see a 180 s appliance cycle. The lead settled this.
- Brightness and onset belong inside the room fix, because a stray onset pulses `forceStrength` (decision 4). The lead settled this.
- `AUDIO_ROOM_GATE_MAX_DB` is derived from the level span the core receives, not measured (decision 13). Task 6.8 checks it. The lead settled this.
