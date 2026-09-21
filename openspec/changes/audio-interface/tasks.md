These tasks were written assuming `midi-interface` (the matrix spine) and
`redesign-control-panel` (the control catalog, the Toggle widget, the help key list, the
reachability sweeps) had both landed. On 2026-09-12 implementation started on `main` at
`16a3d56`, where neither has: `midi-interface` holds a proposal, design and specs with no tasks
and no code, and `redesign-control-panel` is a proposal on the `panel-redesign` branch only.
Implementation therefore builds on the idioms `main` carries: a boolean control is a
`toggle-label` checkbox (given `role="switch"` so `aria-checked` reads), help keys are
`ReservedHelpKeys`, the help file names `listen` and the sources in bold since no catalog
resolves them, and the reachability suite holds only the descriptor sweep. Group 3 and the
matrix halves of 1.3, 3.1, 6.3 and 6.6 wait on the matrix spine; the six shipped rows and the
source-family registration land when it does. Source anchors are named by symbol.

The live verification of 13-09-26 found a quiet room reading loudness 8-35% and never reaching
`Silent`, and the user chose both an automatic fix (the room reads as zero) and one Room Gate
control. The user then chose to accept the mid-music cost, to remember the gate on this browser, and
to refuse audio rows on it. A critique then measured the noise floor designed for it fading held
notes, and the user chose to learn the room only at Listen start and freeze it. A second critique
measured one loud frame zeroing a held drone, and the range now hangs from a held level. Tasks 2.5-2.12,
4.8-4.17 and 5.4-5.6 carry these decisions, and group 6 gains their live checks. The numbers behind
them come from `scratchpad/audio-interface/frozen-room-design__13-09-26-2032.md` and
`scratchpad/audio-interface/held-level-design__14-09-26-1623.md`.

## 1. Prove the rig and gate the microphone

The proposal's measurement gate. Browser MCP cannot press the browser's own permission prompt
and does not drive the webui-launched window, so the two clicks in 1.6 are the user's; the
feature core in group 2 waits on nothing here.

- [x] 1.1 Confirm the Browser MCP tools are present and connected. If not, ask the user to
      start Chrome and connect Browser MCP, and start nothing until they confirm. Touches no file
- [x] 1.2 Write `src/bindings/web_audio.nim` in the style of `src/bindings/web_midi.nim`:
      `getUserMedia` with the three processing constraints, `AudioContext` create, resume,
      close and `sampleRate`, `createMediaStreamSource`, `createAnalyser`, `fftSize`,
      `smoothingTimeConstant`, `frequencyBinCount`, `getFloatFrequencyData`,
      `getFloatTimeDomainData`, `MediaStreamTrack.stop` and `getSettings`. The analyser
      constants come from `src/ui/input/audio_core.nim` (task 2.2 fixes their values; this task
      declares `ANALYSER_FFT_SIZE = 2048` and `ANALYSER_SMOOTHING = 0.0` there with their
      conditions beside them). Verify `just build-app` compiles
- [x] 1.3 Write `src/audio_input.nim` (layer 3, imported in `src/app.nim` after `web_api`): the
      `ListenState` enum from `audio_core` with its five states; `startListening` creates the
      context, requests the microphone with `echoCancellation`, `noiseSuppression` and
      `autoGainControl` each `false`, wires source to analyser and nothing further, and logs one
      `[audio]` console line naming which of the three the granted track's `getSettings()`
      honored, the precedent being the adapter lines in `src/webgpu_init.nim`; `stopListening`
      stops every track and closes the context. Both leave the state set before they return:
      `Requesting` on start, `Disconnected` on stop, `Denied` when the request rejects. Register
      the pair with `src/web_api.nim` at wiring time, the way `registerSourceFamily` registers a
      family, and expose `startListening()` and `stopListening()` on `gardenAPI`, typed as
      `void` returns in `web-ui/src/garden-api.ts`. Verify `just build-app` and `just build-ui`
- [x] 1.4 **Red first.** Add `"audio"` to `ReservedHelpKeys` in `src/ui/api/help_content.nim`
      and `toggle("listen", "Listen", "audio", <hint>)` to `buildControlCatalog` in
      `src/ui/api/control_catalog.nim`; run `nim c -r tests/test_help_content.nim` and confirm
      it fails naming the missing `audio` help entry. Then write `docs/help/65-audio.md` with
      the front matter `group: audio` and one `` - `listen` `` line, and insert it in
      `HelpFileNames` directly before `70-presets.md`; run `tests/test_help_content.nim` and
      `tests/test_control_catalog.nim` green
> 2026-09-13: `src/ui/api/control_catalog.nim` and `tests/test_control_catalog.nim` do not exist on
> `main` (the catalog is `redesign-control-panel`'s, as the note above says). What landed is
> `"audio"` in `ReservedHelpKeys` and `65-audio.md` naming Listen in bold; the Listen hint lives in
> `web-ui/src/components/AudioSection.tsx`. Task 5.4 moves `audio` out of `ReservedHelpKeys`.

- [x] 1.5 **Red first.** Run `nim c -r tests/test_panel_reachability.nim` and confirm "every
      catalog entry is placed by some component" fails naming `listen`. Write
      `web-ui/src/components/AudioSection.tsx` rendering `<Toggle ctrl={ctrl} id="listen" ...>`
      whose `checked` is true in `Requesting`, `Connected` and `Silent`, calling
      `ctrl.api.startListening()` or `stopListening()` on change, with the state's name on a
      line under it; place `<Section title="Audio">` in `web-ui/src/components/Panel.tsx` after
      the mappings section `midi-interface` adds and before Presets. Run the reachability suite
      green
- [ ] 1.6 **Live gate.** `just happen`, run `./main --serve` as a persistent background shell, poll
      `http://127.0.0.1:8089` for 200, navigate the connected tab there, press Listen, and ask
      the user to allow the prompt; read the `[audio]` line through the console log and record
      which constraints the tab honored. Press Listen again and ask the user whether the OS
      microphone indicator went dark. Then kill the port 8089 listener, ask the user to launch bare
      `./main`, press Listen in the webui-launched window, and report whether it prompted and connected, since that window is not the
      connected tab. Write both outcomes to
      `scratchpad/audio-interface/mic-gate__<DD-MM-YY-HHmm>.md`. A refusal in the webui window
      lands the affordance in `Denied` and changes no later task. Kill the port 8089 listener
- [x] 1.7 `just happen` builds and `just check` is green

## 2. The feature core, natively tested

- [x] 2.1 **Red first.** Write `tests/test_audio_core.nim` over a `analyse(state, frame)` call
      taking the 1024 decibel bins, the 2048 samples, the sample rate and the frame's wall-clock
      delta: a single bin at 440 Hz lands brightness at its logarithmic position within
      tolerance with bass and high near zero; energy confined to one band leads that band's
      feature; a click train at a known period fires one onset per click at the expected frames
      and none inside 100 ms; a loud steady spectrum fires nothing; all bins at negative
      infinity give exactly zero on every feature, no onset, finite state, and finite values on
      the next sounding frame; a 20 dB step up and down returns every feature inside (0, 1)
      within a frame count the test pins; random finite arrays keep every feature finite and in
      [0, 1]; a loud frame then a silent frame reads the silent values on that next frame; the
      same signal at 8.33 ms and 16.7 ms deltas spans the same wall-clock refractory and
      adaptation; loudness at the floor for three seconds reports silent and sound clears it on
      the next frame; a level inside a window narrower than the minimum stays finite. Add the
      import and the `AUDIO_CORE_TESTS_LOADED` discard to `tests/test_all.nim`. Run
      `nim c -r tests/test_audio_core.nim` and confirm it fails to compile for want of the module
- [x] 2.2 Write `src/ui/input/audio_core.nim`, pure on both backends in the style of
      `src/ui/input/midi_core.nim`: `AudioFrame`, `AudioFeatures` with onset as an object
      variant (fired with its energy, or not fired), `AnalysisState` holding the previous
      spectrum, one floor-and-ceiling window per normalized feature, the flux median, the
      refractory clock, the silence clock and the decaying brightness; `ListenState` with its
      five states; every constant with its condition in one or two lines: band edges 20, 250,
      2000, 8000 Hz, brightness range 200 to 8000 Hz, refractory 100 ms, silence 3 s, the floor
      and ceiling rates, the minimum window width, the flux threshold. Negative infinity reads as
      zero magnitude. Run `tests/test_audio_core.nim` green, one suite at a time
- [x] 2.3 Add the `test_audio_core.nim` row to the file table in `tests/README.md`. Verify by
      reading the table
- [x] 2.4 `just happen` builds and `just check` is green

Tasks 2.5-2.8 write red tests, 2.9 moves the existing tests onto a learned room, 2.10 changes the
mechanism, and 2.11 carries the new `Learning` state to the panel. Two shared test helpers:
- `roomFrame(rng, dt)`: bins drawn as Rayleigh magnitudes around an 80 Hz rumble at
  `ROOM_RUMBLE_DB = -60` dBFS and white hiss at -75 dBFS, and samples as Gaussian noise at the rumble's RMS, from a fixed seed, so
  every red reads the same on every run.
- `learnRoom(state, dt)`: `roomFrame` for 5 s, which is longer than `ROOM_LEARN_SECONDS` and runs
  on the shipped core too, where the constant does not exist yet.

Every test below was run against a scratch copy of the core carrying 2.10's mechanism, and against
an unmodified copy: `scratchpad/audio-interface/probe/core_frozen/` and `core_shipped/`, with their
outputs beside them.

- [ ] 2.5 **Red first.** In `tests/test_audio_core.nim` add the suite "Audio Core Holds A Learned
      Room" with six tests. The first three and the last two compile against the shipped core. Each names the wrong code it
      catches.
      - "a drone held 60 s after a learned room keeps its reading". `learnRoom`, then a flat tone
        (one bin near 300 Hz and the sample RMS both at -48 dB, 12 dB over the room's rumble) for
        60 s at 60 fps. Assert the loudness reading at 1 s is above 0.1, and the reading at 60 s is
        within 0.01 of it. The oracle is the definition: a steady level against a fixed edge and a
        ceiling that has closed on it reads one constant value. Red on the shipped core, which
        catches `track`'s window floor climbing toward a held level at `FLOOR_RISE_SECONDS`, and
        any room estimate that keeps learning while a sound holds.
      - "a soft legato passage never reads silent after music". `learnRoom`, then 10 s of
        music: 100 ms of `soundingFrame(QUIET_DB)` every 250 ms, `roomFrame` between, then a flat tone 8 dB over
        the room for 35 s. Assert no frame reports silent after the passage's first 0.5 s. Red on
        the shipped core, which catches silence judged on the feature
        (`result.loudness <= SILENCE_LOUDNESS` in `analyse`): the floor closes on a held level,
        and the level then reads zero.
      - "the core reports silent in a flickering room when a sounding passage stops". `learnRoom`,
        then five seconds of `holdDithered` at `QUIET_DB`, then `roomFrame` for 10 s from a new
        seed. Assert loudness, bass, mid and high each read exactly zero on at least 99 frames in
        100 of the room. Assert silent first arrives within `SILENCE_SECONDS + 0.5` s, and that a
        tone 12 dB over the room clears it on its next frame. Red on the shipped core at the
        zero-frame and silent assertions, which catches a lower edge on the quietest recent frame:
        the room's flicker reads above `SILENCE_LOUDNESS` and resets the silence clock.
      - "a held drone keeps its reading through a single loud hit". `learnRoom`, then the flat tone
        12 dB over the room for 2 s, then `toneFrame(0.0)` for `ANALYSER_FFT_SIZE / sampleRate`
        seconds (the span one click covers in the analyser), then the tone again for three
        `CEILING_DECAY_SECONDS` (export it). Assert no loudness reading after the hit is zero, and
        the last reading more than 10% from the pre-hit reading falls within 2.5
        `CEILING_DECAY_SECONDS`. The oracle is decision 5's arithmetic. A hit under half of
        `HELD_SECONDS` leaves the held level and so the lower edge, and the ceiling's gap over the
        tone, 48 dB, must close to 6.7 dB, which takes ln(48 / 6.7) = 1.97 time constants. It
        catches a range hung from a frame peak (`ceiling - RANGE_DB`): red on the frame-peak
        scratch core with 124 zero frames (`scratchpad/audio-interface/probe/core_frozen/held_red_output.txt`).
        It compiles against the shipped core only once 2.10 exports `CEILING_DECAY_SECONDS`, so
        write it with 2.6's compile-red set.
      - "a sound 20 dB under a held drone still reads when a sound 20 dB over it covered 40% of
        the last second". `learnRoom`, then a flat tone 40 dB over the room's rumble for 2 s, the
        tone 20 dB louder for 0.4 s, then one frame 20 dB under the drone. Assert its loudness is
        above zero. The oracle is decision 5's arithmetic: a sound covering under half of
        `HELD_SECONDS` leaves the median on the drone, so the lower edge sits 24 dB under the
        drone and the probe 4 dB over it. It catches a held level taken as a time-weighted mean,
        which the 0.4 s at +20 dB pulls 8 dB up, putting the probe 4 dB under the edge. The hit
        test above stays green under a mean. Red on a mean mutant and on the shipped core, green
        on the median (`scratchpad/audio-interface/probe/mutant_runs/mean/suite_top1000_output.txt`,
        `scratchpad/audio-interface/probe/mutant_runs/core_shipped/`,
        `scratchpad/audio-interface/probe/core_held/suite_bare_output.txt`).
      - "a sound 16 dB under a held drone still reads at 8.33 ms deltas when a sound 12 dB over it
        covered 30% of the last second". The same shape at `FRAME_120`, with the louder tone 12 dB
        over the drone for 0.3 s and the probe 16 dB under it. Assert its loudness is above zero.
        The oracle is the same arithmetic: under a wall-clock second the median stays on the drone
        and the probe sits 8 dB over the edge. It catches a held window counted in frames: 60
        frames span 0.5 s at 120 fps, the 0.3 s tone is their majority, and the edge rises to 12 dB
        under the drone, 4 dB over the probe. A mean moves the edge 3.6 dB and leaves the probe
        4.4 dB over it, so this test goes red for the window alone. Red on a frame-count mutant and
        on the shipped core, green on the median
        (`scratchpad/audio-interface/probe/mutant_runs/framecount/suite_top1000_output.txt`). Both
        mutants also fail the existing wall-clock test by 0.0013 and 0.026, which names no held
        level; these two name it.
- [ ] 2.6 **Red first.** Write four learning tests. The file fails to compile for want of
      `ROOM_LEARN_SECONDS`. The burst and fresh-state tests pass on the shipped core by its own
      window; they hold the mechanism after 2.10.
      - "every feature reads zero and nothing fires while the room is learned". From a fresh state,
        loud frames every 15 frames over silence, for `ROOM_LEARN_SECONDS` less one and a half
        frames. Assert every frame reads loudness, bass and brightness at exactly zero, with no
        onset and no silent. It catches a feature published before the room exists.
      - "the room learns over the same wall-clock seconds at 8.33 ms and 16.7 ms deltas". At each
        delta: silence to 2 s, `QUIET_DB` to 6 s, `QUIET_DB - 6` to 7 s. Assert the first nonzero
        loudness lands at `ROOM_LEARN_SECONDS + dt` within half a frame. Assert the final
        readings, inside (0, 1), agree within 1e-6. This replaces "the gain window adapts the same
        amount at 8.33 ms and 16.7 ms deltas", whose window floor 2.10 deletes. It catches
        learning counted in frames.
      - "a burst shorter than half the learning window is not learned as room". Silence with
        `QUIET_DB` from 0.5 s to 1.7 s, 5 s in all. Assert a `QUIET_DB` frame then reads loudness
        above 0.5. It catches a p90 or maximum statistic in place of the median.
      - "a fresh state learns a louder room as zero". Hold `QUIET_DB` for 5 s, then 2 s more.
        Assert loudness is exactly zero and silent is reported. It catches a room carried across
        re-initialization, which is how turning Listen off and on relearns.
- [ ] 2.7 **Red first.** Write the relations and the Room Gate tests.
      - "no reading falls when the room gate falls". The dithered passage after `learnRoom`,
        analysed at offsets 0 and `AUDIO_ROOM_GATE_MIN_DB`. Assert every level feature at the
        minimum is at least its reading at 0, frame by frame. The oracle is that a lower edge
        which falls, over a span that grows by no more than the edge falls, never lowers a clamped
        position. It catches an offset applied with the wrong sign, or to the ceiling.
      - "no feature moves when every level, learning included, shifts by one decibel offset". The
        same run with bins +12 dB and samples ×10^(12/20), compared within 1e-9. It catches a room
        or gate computed in linear magnitude.
      - "every level feature reads zero and the core reports silent when the room gate rises above
        a steady sound". A tone 3 dB over the room after `learnRoom`, with the gate raised to
        `ROOM_GATE_BASS_DB`.
      - "the sound returns when the room gate falls back below it".
      - Widen "every feature stays finite and in range when the arrays are random" to draw
        `roomGateDb` uniformly over `AUDIO_ROOM_GATE_MIN_DB..AUDIO_ROOM_GATE_MAX_DB`.
      - "the room gate minimum cancels the widest per-feature gate": `AUDIO_ROOM_GATE_MIN_DB ==
        -max(ROOM_GATE_LOUDNESS_DB, ROOM_GATE_BASS_DB, ROOM_GATE_MID_DB, ROOM_GATE_HIGH_DB)`.
      - "the room gate maximum spans the level floor to full scale": `AUDIO_ROOM_GATE_MAX_DB ==
        0.0 - LEVEL_FLOOR_DB` (export `LEVEL_FLOOR_DB`). Also assert that a full-scale square wave
        (samples at ±1, bins from its analysed spectrum) reads zero on every feature at the maximum.
      - "a sound reads zero once it stands more than the range under a held level": after
        `learnRoom`, `QUIET_DB` held for `HELD_SECONDS`, then one frame at `QUIET_DB - RANGE_DB - 6`
        reads loudness exactly zero, and a fresh run with `QUIET_DB - RANGE_DB + 6` second reads
        above zero. The oracle is the definition of the lower edge. It catches a missing or
        misplaced `RANGE_DB`: on the frame-peak scratch core, with one `QUIET_DB` frame, it passed
        at 24 dB and failed with no range
        (`scratchpad/audio-interface/probe/core_frozen/range24_test_output.txt`). With the 1 s hold
        it passes on the held-level core (`scratchpad/audio-interface/probe/core_held/`).
      - "the room gate storage key sits apart from the preset and mapping keys":
        `AUDIO_ROOM_GATE_STORAGE_KEY` does not start with `pg.presets.` and differs from
        `MAPPING_STORAGE_KEY`.

      They fail to compile for want of `AudioFrame.roomGateDb` and the constants. The wrong code
      they catch after 2.10 is:
      - an offset read once into `AnalysisState` instead of from each frame;
      - a range minimum or maximum restated apart from the quantities it is derived from;
      - a storage key that a preset clear would delete.
- [ ] 2.8 **Red first.** Write two tests.
      - "brightness settles below 0.01 when only a learned room sounds": `learnRoom`, then
        `roomFrame` for 5 s.
      - "onset fires nothing when a learned room flickers under its edge": `learnRoom`, then
        `roomFrame` for 25 s, counting fired onsets.

      Run them and confirm both fail. On the shipped core through the analyser emulation,
      brightness read p90 0.44 and two onsets fired in 25 s. The wrong code is the centroid gated
      only by `BRIGHTNESS_FLOOR_MAGNITUDE`, and the onset gated only by flux in `analyse`.
- [ ] 2.9 With 2.10, give every existing test in `tests/test_audio_core.nim` a `learnRoom` ahead
      of its stimulus. Unchanged but for the preamble, all fifteen fail against the mechanism,
      because the first `ROOM_LEARN_SECONDS` read zero (`scratchpad/audio-interface/probe/core_frozen/existing_tests_range0_output.txt`).
      With the preamble, ten pass with oracles unchanged. Five change their stimulus, each for a
      reason the mechanism states (`scratchpad/audio-interface/probe/core_frozen/learned_preamble_output.txt`):
      - "onset fires nothing when a loud steady spectrum stops increasing": count firings only
        after the first loud frame, since the step in from the room is itself an onset.
      - "a feature stays finite when its window closes narrower than the minimum": hold the level
        at `ROOM_RUMBLE_DB + ROOM_GATE_LOUDNESS_DB + MIN_WINDOW_DB / 2` (export `MIN_WINDOW_DB`).
        A flat level at its own ceiling, more than `MIN_WINDOW_DB` above the edge, reads 1.0 by
        construction.
      - "onset spans the same refractory window at 8.33 ms and 16.7 ms deltas": learn at the
        loop's own delta, and start the clicks at -40 dB, above the room edge. At -110 dB the first
        clicks sit under the edge and are gated.
      - "the gain window adapts the same amount at 8.33 ms and 16.7 ms deltas": replaced by 2.6's
        learning test.
      - "the core reports silent when loudness sits at its floor for three seconds": rename to
        "... sits at or under its room edge for three seconds", and put one `QUIET_DB` frame after
        `learnRoom`, so the silence clock starts from sound.

      "every feature returns inside its open range when the level steps 20 dB up and back down"
      keeps `DITHER_DB` 6 and 120 settle frames: at `RANGE_DB` 24 it passed unchanged on the
      scratch core. The full 21-test set ran green on
      the frame-peak scratch core at 0 and 24 dB, and at 12 dB with that one exception
      (`scratchpad/audio-interface/probe/core_frozen/frozen_suite_output.txt`). With 2.5's hit test
      and 2.7's range test, 23 tests ran green on the held-level scratch core at
      `CEILING_DECAY_SECONDS` 3, 1 and 0.25 s
      (`scratchpad/audio-interface/probe/core_held/suite_top3000_output.txt`, `suite_top1000_output.txt`,
      `suite_top250_output.txt`).
- [ ] 2.10 Change the mechanism in `src/ui/input/audio_core.nim`.
      - Add `roomGateDb*: float` to `AudioFrame`.
      - Replace `LevelWindow`'s floor with a `RoomEstimate` object variant over the four normalized
        features: `learning` holding each feature's heard levels and the heard seconds, and
        `learned` holding one room level per feature. Delete `FLOOR_RISE_SECONDS`.
      - While learning, append each level and add `min(dtSeconds, ANALYSER_FFT_SIZE / sampleRate)`
        to the heard seconds. Every feature reads zero and no onset fires. The flux median keeps
        tracking. When the heard seconds reach `ROOM_LEARN_SECONDS`, set each room level to the
        median of its levels and drop them.
      - Give each feature's window `recent: seq[HeardFrame]` (level, heard seconds). Each frame with
        nonzero heard seconds appends, and the oldest drop while the rest still cover
        `HELD_SECONDS`, keeping at least one. The held level is the time-weighted median of
        `recent`, or the frame's level while `recent` is empty.
      - The ceiling rises instantly to a level above it. Otherwise it decays toward
        `max(held, level)` at `CEILING_DECAY_SECONDS`.
      - Read each feature as `clamp((level - lower) / max(ceiling - lower, MIN_WINDOW_DB), 0, 1)`,
        with `lower = max(room + gate + frame.roomGateDb, held - RANGE_DB)`.
      - Add `HELD_SECONDS = 1.0`. The condition: a median disregards what covers under half its
        window. Through the emulated analyser, 1 and 20 ms clicks, 80 ms kicks 20 and 30 dB over, a
        150 ms snare 30 dB over and a 250 ms tone 24 dB over never zero a drone 12 dB over the
        room at 60 or 120 fps, and at 0.5 s the 250 ms tone drops it to 0.06.
      - Set `CEILING_DECAY_SECONDS = 1.0`, exported. The condition: the user's choice among
        measured decays. At 1 s, synthetic music after a room reads loudness 0.74/0.84/0.97, bass
        0.00/0.74/0.93 and high 0.00/0.00/0.60 (p10/p50/p90). A full-scale click holds a drone
        under half its reading for 1.00 s, and the drone is back within 10% by 1.95 s.
      - Add `RANGE_DB = 24.0`. The condition: the user's choice among measured spreads on synthetic
        music after a room. At 24 dB under frame peaks, loudness read p10-p90 0.66-0.95, bass median
        0.59, high up to 0.43, and a soft pad after loud music read zero for 1.33 s. Under the held
        level at the 1 s ceiling decay, loudness reads 0.74-0.97 and bass median 0.74.
      - Add the constants with their conditions.
        - `ROOM_LEARN_SECONDS = 3.0`: median gates agree within 0.15 dB from 2 s to 10 s, the
          bass median's seed spread is 0.78 dB at 3 s, and a median ignores a burst under half the
          window.
        - `ROOM_GATE_LOUDNESS_DB = 5.4`: p99.9 excess over the learned median plus the largest
          calibration excess over that edge, so no room frame resets the silence clock.
        - `ROOM_GATE_BASS_DB = 6.0`, `ROOM_GATE_MID_DB = 2.6`, `ROOM_GATE_HIGH_DB = 1.4`: p99.9
          excess over the median at a 3 s window, rounded up to 0.1 dB.
        - All from stationary rumble-plus-hiss and white-hiss rooms, fftSize 2048, 48 kHz, the
          larger of 60 and 120 fps.
        - `ROOM_GATE_DEFAULT_DB = 0.0`.
      - Replace `AudioFeatures.silent: bool` with `reading: RoomReading`
        (`rrLearning`, `rrSounding`, `rrSilent`). Silent is loudness's level at or under its lower
        edge for `SILENCE_SECONDS`. Delete `SILENCE_LOUDNESS`. The tests' `features.silent` reads
        become `features.reading == rrSilent`.
      - Define the centroid only while some band's level stands above its edge, and fire onset
        only while loudness's level stands above its edge.
      - Add `lsLearning = "Learning"` to `ListenState`, and update its doc comment to six states.

      Add `AUDIO_ROOM_GATE_STORAGE_KEY* = "pg.audio.roomGate"` beside the default. In
      `src/config_ranges.nim` add the range with its conditions, the non-emptiness assertion, and
      zero inside:
      - `AUDIO_ROOM_GATE_MIN_DB = -6.0`: cancels the widest gate, the bass gate.
      - `AUDIO_ROOM_GATE_MAX_DB = 120.0`: 0 dBFS minus the core's -120 dB level floor. The float
        frequency data is unclipped, since `minDecibels` bounds only byte data, so at this offset
        every lower edge stands above full scale.

      In `src/audio_input.nim`, `pollAudioFrame` maps `rrLearning`, `rrSounding` and `rrSilent`
      to `lsLearning`, `lsConnected` and `lsSilent`. Its live-chain guard and `startListening`'s
      guard include `lsLearning`, and `onMicrophoneGranted` settles to `lsLearning`. It sets
      `roomGateDb` to `ROOM_GATE_DEFAULT_DB` until 4.13. Run `nim c -r tests/test_audio_core.nim`
      green, all of 2.5-2.9 included, and `just build-app`
- [ ] 2.11 **Red first.** In `web-ui/test/audio-section.test.ts`, assert that `listenChecked("Learning")`
      is true. Run `just test-ui` and confirm it fails to type-check for want of the name. Add
      `"Learning"` to `ListenState` in `web-ui/src/garden-api.ts` and to `CHECKED_STATES` in
      `web-ui/src/lib/audio-section.ts`, and run green. The wrong code it catches is a switch that
      reads unchecked for three seconds after every connect
- [ ] 2.12 `just happen` builds and `just check` is green

## 3. The per-frame poll and the matrix hand-off

- [x] 3.1 In `src/audio_input.nim` register the `audio` family at wiring time through
      `web_api.registerSourceFamily` with five continuous declarations and one event
      declaration, each carrying the label the meters and the mapping editor show. Add
      `pollAudioFrame(dtSeconds)`: with a live chain, copy the two arrays, call `analyse`, set
      each continuous source through `setSourceValue`, emit `audio:onset` through
      `emitSourceEvent` with the energy as magnitude and ordinal zero, and move the state between
      `Connected` and `Silent` on the core's silence report. In `src/app.nim` call it in the
      frame loop directly before `web_api.flushMatrix(cappedDt)`. Verify `just build-app`, and by
      reading the loop that the call precedes the flush
- [x] 3.2 **Red first.** In the shipped-mapping suite of `tests/test_control_matrix.nim` (the
      shipped default lives in `src/ui/input/shipped_mapping.nim`, not in `control_matrix.nim`, as
      `midi-interface` built it), pin four audio rows by source, kind, target, depth and envelope:
      `audio:onset` Modulate `forceStrength` +0.40, attack 0, release 300 ms; `audio:bass` Modulate
      `fluidStrength` +0.30; `audio:loudness` Modulate `forceStrength` +0.25; `audio:high`
      Modulate `glowIntensity` 0; the last three at a zero attack and an 80 ms release. Onset and
      loudness share `forceStrength`; every other target is held by one audio row. Run it and
      confirm it fails. Add the six declarations as `SHIPPED_AUDIO_SOURCES` in
      `src/ui/input/shipped_mapping.nim`, registered by `shippedMatrixState()` beside the MIDI
      family so the static gate sees the audio rows resolved, and add the four rows to
      `DEFAULT_MAPPING` there; `src/audio_input.nim` registers the same constant, so the labels
      have one home. Run green ("the four audio rows ship pinned by source, kind, target and
      depth"); `just build-app` passes the static gate on the shipped rows. Widen the help relation
      in `tests/test_help_content.nim` so a shipped row's target may be named by any help file,
      since the audio rows are documented in `65-audio.md` rather than `70-midi.md`
> 2026-09-13: the body of 3.2 above now states the rows that shipped. It first read six rows with
> distinct targets, the onset row a Touch blast; the two notes below record why that changed.
> 2026-09-12: the `audio:onset` pin in 3.2 now reads a Modulate impulse on `forceStrength`, depth
> +0.40 and a 300 ms release, sharing loudness's target; the shipped audio targets are no longer
> all distinct.
> 2026-09-12: the `audio:mid` → `rdDeposit` and `audio:brightness` → `rdFieldForce` rows no
> longer ship (reaction-diffusion is decoupled from audio), so 3.2 pins four rows; all six
> declarations still register.

- [x] 3.3 `just happen` builds and `just check` is green

## 4. Metering push, the affordance, and the Room Gate

- [x] 4.1 In `src/web_api.nim` add an audio subscriber sequence beside the stats subscribers,
      `onAudio(callback)` returning an unsubscribe function, and `pushAudio(sample)` that
      returns before allocating when nobody listens, the guard `pushStats` holds. A subscribe
      pushes the current state once; `src/audio_input.nim` pushes once per frame from
      `pollAudioFrame` while a chain is live, carrying the state's name, the five continuous
      values and the onset with its energy in the frame it fires, and pushes once on each state
      change otherwise. `pushStats` and its payload stay untouched. Type `AudioSample` and
      `onAudio` in `web-ui/src/garden-api.ts`. Verify `just build-app` and `just build-ui`
- [x] 4.2 **Red first.** Write `web-ui/test/audio-section.test.ts` over a pure helper in
      `web-ui/src/lib/audio-section.ts`: which states check the toggle, and that a sample
      carrying an onset lights the indicator at its energy. Run `just test-ui` and confirm it
      fails, then write the helper and run green
- [x] 4.3 Give `web-ui/src/components/Section.tsx` an optional `onOpenChange` prop. In
      `AudioSection.tsx` subscribe through `onAudio` inside a `createEffect` while the section
      is open and the panel is not collapsed (Panel passes both), and call the unsubscribe
      otherwise; render five native `<meter>` elements from 0 to 1, each labelled with the
      served declaration's label, and an onset indicator that lights at the onset's energy and
      fades by a CSS transition in `web-ui/src/ui.css`, which the `prefers-reduced-motion`
      block already disables with every other transition. No slider, no threshold, no number
      restated. Verify `just happen` and `nim c -r tests/test_panel_reachability.nim` green,
      whose interval sweep reads the new component
> 2026-09-13: "No slider" in 4.3 is reversed by the Room Gate (4.14); the section still restates no
> number.

- [x] 4.4 `just happen` builds and `just check` is green
- [ ] 4.5 **Red first.** The mapping editor offers every declared source before any signal
      arrives, so an audio row can be added having never listened. In
      `web-ui/test/mapping-editor.test.ts`, over a pure helper in the editor's lib module: given
      `mappingSources()` entries, the offered choices list each id with its label and kind in
      registration order; a continuous source yields a Modulate row spec at depth 0 on the chosen
      descriptor, and an event source a Fire row spec on a chosen `mappingActions()` entry. Run
      `just test-ui` and confirm it fails, then write the helper and run green
- [ ] 4.6 In `web-ui/src/components/MidiSection.tsx` render the source select from the helper
      beside "Map this control", adding the row through `gardenAPI.addMappingRow` and reporting a
      refusal as the other edits do. The panel restates no source id, label or kind. Verify
      `just happen` and `nim c -r tests/test_panel_reachability.nim` green
- [ ] 4.7 **Red first.** A dormancy line describes the world as it acts, not only the stored value:
      while a modulation lifts a parameter out of its dormant range, the dependants read awake.
      Found live 13-09-26: audio lifted Fluid from 0 and every SPH sub-control still read "the
      world has no fluid", because `dormantParams` reads `currentSimulation` and `currentRender`
      while `mirrorModulated` writes the effective values into copies only. Pull the value lookup
      behind `dormantParams` into a pure helper that takes the stored stores and the flush's
      effective table, and test that an effective Fluid above zero wakes the fluid dependants and
      that no effective entry leaves the stored reading. Run it red, then have `dormantParams` feed
      it the last flush's effective values. The stored stores and preset export stay the user's own.
      Verify `just happen`, then check live: Listen on with sound and Fluid at 0, and the SPH
      lines stop reading "no fluid"
- [ ] 4.8 `just happen` builds and `just check` is green
- [ ] 4.9 **Red first.** Write the audio-store tests in `tests/test_param_descriptor.nim`.
      - Suite "Store Routing Sends Each Parameter To Its Mutation Path": add
        "the room gate is the only parameter routed through the audio store", modeled on
        "the camera is the only parameter that never reaches CONFIG" (the set equals
        `@["audioRoomGate"]`). Add an `audioRoomGate` arm checking `psAudio` to
        "palette knobs route to the palette store, everything else to CONFIG".
      - Add "the room gate descriptor takes its range from config_ranges and its default from
        audio_core": group `audio`, min `AUDIO_ROOM_GATE_MIN_DB`, max `AUDIO_ROOM_GATE_MAX_DB`,
        default `ROOM_GATE_DEFAULT_DB`, a notch at the default, and curve `cPower` with exponent
        2.5.

      It fails to compile for want of `psAudio`. The wrong code it catches is a Room Gate routed
      through `psRender` or `psSimulation`, which would put it into every preset, and a second
      `psAudio` descriptor
- [ ] 4.10 **Red first.** In `tests/test_control_matrix.nim`, extend "a Modulate row outside the
      simulation and render stores is refused while a Write row takes it" to `audioRoomGate`. The
      Modulate refusal must name the audio store, and the Write row must validate. Add `psAudio` to
      the routed-store set of "the envelope floor sits under half the finest position step a row
      can target". Run it and confirm the Write half fails with "no descriptor serves the
      parameter id audioRoomGate". The wrong code it catches after 4.11 is a Room Gate descriptor
      on `psSimulation` or `psRender`, which the confinement would let a Modulate row displace.

      Add two tests in the same file:
      - "a Write row from an audio source is refused on the room gate while a controller's Write row
        takes it": an `audio:loudness` Write row on `audioRoomGate` refuses with a reason naming the
        feedback loop, and a `KNOB_A` Write row on it validates.
      - "a stored row writing the room gate from an audio source drops on decode": `parseDocument` over
        a mapping JSON carrying that row returns the document without it, since decode calls
        `validateTarget`.

      Both fail after 4.11 because the store confinement consults the target alone. That is the
      wrong code they catch
- [ ] 4.11 Add the store and the descriptor.
      - `src/ui/api/param_descriptor.nim`: add `psAudio` to `ParamStore`, with a doc comment that
        the room is not the world, so the value never reaches CONFIG or a preset. Add
        `floatParam("audioRoomGate", "Room Gate", "audio", AUDIO_ROOM_GATE_MIN_DB,
        AUDIO_ROOM_GATE_MAX_DB, ROOM_GATE_DEFAULT_DB, 1, psAudio, probe = "audio.roomEdge",
        curve = cPower, curveExponent = 2.5, hint = ...)` with `.withDefaultNotch(0)`. The exponent's
        condition: over -6..120 dB it gives 0..+6 dB, the first widest gate above the default, its
        widest share of travel among exponents 1 to 6 (9.5%), with the default at 29.6%. The hint
        names no numerals, since the
        reachability test reads a numeral as a slider position.
      - `web-ui/src/garden-api.ts`: add `"audio"` to `ParamStore`.
      - `src/web_api.nim`: add a `roomGateDb` var beside the audio hooks. Give `"audioRoomGate"` a
        `ReadElsewhere` entry and a `getParamImpl` arm. Add arms to `storeName`, the read and write
        static gates, `setParamImpl` (clamping to the descriptor range), `paramContextOf`,
        `applyMatrixWrites` and `mirrorModulated`. The build names each case lacking one.
      - `src/ui/api/param_fields.nim`: add `psAudio` to the `false` arm.
      - `tests/test_dormancy.nim`: add `psAudio` to "every render-store parameter answers
        instantly".
      - `src/ui/api/response_probe.nim`: register `"audio.roomEdge"` as a `pbClosedForm` probe
        returning the lower edge in dB over a fixed learned room.

      Run `tests/test_param_descriptor.nim`, `tests/test_response_probe.nim` and
      `tests/test_dormancy.nim` green, one at a time, and confirm the Modulate half of
      `tests/test_control_matrix.nim` passes while the two audio-source tests from 4.10 still fail
- [ ] 4.12 In `src/ui/input/control_matrix.nim` give `targetRefusal` the row's source id, passed from
      both arms of `validateTarget`. Add one arm: a source id starting with `audio:` on a `psAudio`
      target returns a reason naming the loop, where an audio feature writing its own room edge
      silences itself a frame later. Run `nim c -r tests/test_control_matrix.nim` green
- [ ] 4.13 In `src/audio_input.nim`, `pollAudioFrame` reads the boundary's Room Gate into
      `AudioFrame.roomGateDb` on every frame, and `stopListening` leaves it untouched. Verify
      `just build-app`, and by reading that no `AnalysisState` field holds the offset
- [ ] 4.14 **Red first.** Run `nim c -r tests/test_panel_reachability.nim` and confirm "every
      descriptor is placed by its id or by its group" fails naming `audioRoomGate (group audio)`.
      In `web-ui/src/components/Panel.tsx` place `<ParamSlider ctrl={ctrl} id="audioRoomGate" />`
      inside the Audio section under `AudioSection`. In `AudioSection.tsx`, call
      `ctrl.syncParam("audioRoomGate")` on each audio push, so a Write row's move shows on the
      slider. Run the reachability suite green and verify `just build-ui`
- [ ] 4.15 **Red first.** In `web-ui/test/audio-section.test.ts`, test a pure helper
      `restoredRoomGate(stored: string | null): number | null` in `web-ui/src/lib/audio-section.ts`.
      - `"6.5"` restores 6.5.
      - `null`, `""`, `"abc"`, `"NaN"` and `"Infinity"` restore nothing.

      Run `just test-ui` and confirm it fails for want of the helper, then write it and run green.
      The wrong code it catches is `Number(stored)`, which turns `""` into 0 and `null` into 0
- [ ] 4.16 Serve and use the key.
      - `src/web_api.nim`: add `audioKeys()` beside `matrixKeys`, returning `{ roomGate:
        AUDIO_ROOM_GATE_STORAGE_KEY }`.
      - `web-ui/src/garden-api.ts`: declare `AudioKeys` and `audioKeys()`, with the comment that Nim
        owns the key.
      - `web-ui/src/components/Panel.tsx`: on mount, read localStorage under `api.audioKeys().roomGate`
        and pass a restored value to `setParam("audioRoomGate", value)`. Write the synced value
        whenever it differs from the last value written.

      Verify `just build-app` and `just build-ui`, and grep `web-ui/src` for `pg.audio` to confirm no
      literal key
- [ ] 4.17 `just happen` builds and `just check` is green

## 5. Help and enforcement

- [x] 5.1 Fill `docs/help/65-audio.md`: what Listen does and that captured sound never leaves
      the app, the permission prompt and how to revisit a refusal in the browser's site
      settings, the six sources in the room's terms, what the meters show, what the four shipped
      rows do (bass into `fluidStrength`, loudness and onset together into `forceStrength`), and
      `audio:high` into `glowIntensity` waiting at zero depth with the invitation to raise and
      remap it. Name each source in bold, the form `bindingReferenceBody` uses, since
      `namedControlIds` reads only code-span lines and a source id resolves to no descriptor or
      catalog entry. Run `nim c -r tests/test_help_content.nim` green
> 2026-09-13: the body of 5.1 above now names the four rows that shipped; it first read three live
> rows and three at zero depth. `docs/help/65-audio.md` already describes the four.

- [x] 5.2 In `docs/enforcement.md` add `src/ui/input/audio_core.nim` to "Where authority
      lives" and three guarantee rows: every feature finite and in [0, 1] with silence reading
      zero (Test-held, `tests/test_audio_core.nim`); the capture chain created inside the listen
      gesture and released on stop (Unenforced, review against `src/audio_input.nim` and the
      gate record from 1.6); delivery before the frame's flush (Unenforced, review of the loop in
      `src/app.nim`). Verify by reading the tables
- [x] 5.3 `just happen` builds and `just check` is green
- [ ] 5.4 **Red first.** Run `nim c -r tests/test_help_content.nim` and confirm "every descriptor is
      named by its group's file" fails naming `audioRoomGate`. Remove `"audio"` from
      `ReservedHelpKeys` in `src/ui/api/help_content.nim`, since the key is now a descriptor group.
      In `docs/help/65-audio.md` add a `` - `audioRoomGate` `` line saying what the Room Gate does:
      raise it in a loud room until the meters rest, lower it for a quiet instrument, and below its
      default Silent may never come. Say too that this browser remembers it, that loading a preset
      leaves it where it is, and that a controller can map it but an audio source cannot. In the
      Listen paragraph, say that the line reads Learning for the first seconds after connecting,
      while the room is learned; that Listen is best pressed with the room as it will be, fans or
      fridges running and the music not yet playing; that pressed mid-music, the music reads as
      room; and that turning Listen off and on learns the room again. In the meters paragraph,
      say that each meter spreads over the loudest stretch of what it recently heard, so a soft
      passage right after a loud one reads empty for a moment. Say too that a single hit shrinks a
      held sound's meter for about a second and never empties it. Run the help
      suite green, "every declared key is a descriptor group or reserved" included
- [ ] 5.5 In `docs/enforcement.md` add five guarantee rows:
      - A quiet room reads zero on every level feature and reaches silence, and a held sound keeps
        its reading, including through a hit shorter than half a second (Test-held,
        `tests/test_audio_core.nim`, synthetic rooms and hits only).
      - The Room Gate is absent from presets (Test-held, `tests/test_param_descriptor.nim`).
      - No audio source's row writes the Room Gate (Test-held, `tests/test_control_matrix.nim`).
      - The room is relearned when Listen is turned off and on (Unenforced, review of
        `stopListening` in `src/audio_input.nim`, which re-initializes the analysis state).
      - The Room Gate lands on the next analysed frame, survives a stop, and survives a reload
        (Unenforced, review of `pollAudioFrame` and `stopListening` in `src/audio_input.nim` and
        the restore in `web-ui/src/components/Panel.tsx`).

      Verify by reading the tables
- [ ] 5.6 `just happen` builds and `just check` is green

## 6. Live verification

Each task names the agent procedure and the observation that settles it. Claude in Chrome against
the user's Chrome (CLAUDE.md's in-app order), `./main --serve` in a persistent background shell, the port killed at the end. The permission
clicks are the user's, for the reason group 1 states.

- [ ] 6.1 `just happen`, run `./main --serve` as a persistent background shell, poll the port, navigate the
      connected tab, and snapshot the Audio section: a switch named Listen with
      `aria-checked` false, a state line reading `Disconnected`, five meters at zero, and one
      slider named Room Gate at its default notch, with no other slider in the section
- [ ] 6.2 Press Listen and snapshot before the user answers: `aria-checked` true and the line
      reading `Requesting`. Ask the user, before allowing, to leave the room as it will be (any fan,
      fridge or heating running as usual, no music), then allow. Snapshot every second for the
      first ten seconds, then every ten seconds.
      **Quiet-room check, with the Room Gate at its default, five minutes.** The run is longer
      than the 180 s compressor cycle the critique modelled, so one appliance cycle can fall
      inside it. Ask the user to note the time of anything that switches on or off.
      - Prediction, if the synthetic gates and the learned room hold in this room: the line reads
        `Learning` for about three seconds, then `Connected`. It reads `Silent` about three seconds
        later, and every meter reads under 0.05 for the rest of the run, save while a noted
        appliance changes state.
      - Then ask the user to hum or hold one note for 30 s: the line reads `Connected` throughout,
        and the loudness meter never falls under 0.05 while the note sounds. When the note stops:
        `Silent` again within about three seconds.
      - Then make a short sound: back to `Connected` within one analyser window.
      - If an appliance switched on during the run and moved the meters: record the Room Gate
        position that rests them. Then turn Listen off and on with the appliance running, and
        record whether the meters rest at the default. Decision 5 predicts both.
      - Kill condition, stop and record: with no appliance changing state, a meter holds above
        0.05 at rest, or `Silent` has not come 20 s after `Learning` ends. The synthetic gates
        then stand refuted for this room. Record which meter reads what; the next step re-derives
        the constant from a live excursion log.
      - Kill condition, stop and record: the held note reads `Silent`, or its loudness meter falls
        to zero while it sounds. The frozen room then stands refuted live.
      - **Hit over a held sound, under a minute.** Ask the user to hold a note again (hummed, sung,
        or a sustained synth), wait two seconds, clap once or strike one drum hit near the
        microphone, and keep the note sounding for five seconds. Snapshot as fast as the tool
        returns from the clap on, and ask the user whether the loudness meter emptied at any
        moment. Twice is enough.
        - Prediction, if the held level holds live: the loudness meter drops after the clap but
          never reaches zero, and is back within 10% of its pre-clap reading about two seconds
          after (1.95 s on the synthetic full-scale click, decision 5).
        - Kill condition, stop and record: the meter reads zero in a snapshot or the user saw it
          empty, or it is still more than 10% under its pre-clap reading 2.5 s after the clap. The
          held level then stands refuted live; record the clap's peak meter reading and how long
          the dip lasted.
      - Budget: ten minutes of the user's time, the hit check included.

      Record in `scratchpad/audio-interface/live-states__<DD-MM-YY-HHmm>.md`
- [ ] 6.3 With sound playing, read the Fluid Strength and Force Strength sliders' excursion
      shading on successive stats pushes and watch a hit lift Force Strength sharply above loudness's
      excursion (the onset row ships as a Modulate impulse on `forceStrength`, not a blast);
      confirm Glow Intensity, Secretion Rate and Scent-following show no excursion. Press
      Listen off mid-sound: the two sliders return to their stored positions and the OS
      indicator goes dark, which the user reports
- [ ] 6.4 Collapse the Audio section, make a sound, reopen it: the first render shows the
      current state and the meters resume, with no interval under `web-ui/src/components/`
      (held by the reachability suite). Collapse the whole panel and reopen: the same
- [ ] 6.5 Ask the user to block the microphone in the site's permission settings and press
      Listen: the line reads `Denied`, `aria-checked` is false, and no slider moves. Ask the
      user to restore the permission and press Listen again: the same rows drive with no edit
- [ ] 6.6 Open the mapping editor: the six audio sources are offered with their kinds, and the
      four shipped audio rows sit with their targets (`audio:high` → `glowIntensity` the one at
      zero depth).
> 2026-09-13: no panel control lists sources. `gardenAPI.mappingSources()` serves every
> declaration (`src/web_api.nim:1567`), but no component calls it; the editor
> (`web-ui/src/components/MidiSection.tsx`) renders rows only, and a new row's source arrives
> empty until learn fills it from a live signal. So the audio-input scenario "The sources are
> mappable before first use" is unmet in the panel. Resolved by adding a source picker (4.5,
> 4.6); 6.6's first clause waits on them. Open help on the Audio section and confirm
      the audio file is served
- [ ] 6.7 Open help on the Audio section and snapshot: the file names the Room Gate and says what
      raising and lowering it does
- [ ] 6.8 **Loud-room check.** The maximum is derived, not measured here. Ask the user to play music
      loudly through speakers, or to supply crowd or PA noise, with Listen on and the Room Gate at its
      default.
      - Snapshot the meters.
      - Drag the Room Gate up in steps until every meter rests between phrases, and record the
        position.
      - Prediction, if the curve places measured rooms where it gives them travel: the meters rest
        by +12 dB, twice the widest gate (45.9% of the travel), and loudness still moves on each
        phrase.
      - Kill condition: the meters need more than half the travel (+16.3 dB) to rest, or still read
        above 0.05 at the maximum. Record the position, and note that the exponent's condition, or
        the full-scale bound, stands refuted for this room.

      Append to the 6.2 record
- [ ] 6.9 Move the Room Gate off its default, save a preset, move the gate again, and load the
      preset: the slider keeps its second position. Stop and restart listening: the slider still
      keeps it
- [ ] 6.10 **Needs a controller, which the user connects.** Add a Write row from a controller knob to
      `audioRoomGate` in the mapping editor and ask the user to turn the knob: the Room Gate slider
      follows within a frame's push. Try to add a Modulate row on `audioRoomGate`: the editor
      reports the refusal naming the audio store. Then try a Write row from `audio:loudness` to
      `audioRoomGate`: the editor reports the refusal naming the feedback loop. The second half
      needs no controller. If no controller is available, record 6.10 as
      not run and why
- [ ] 6.11 Move the Room Gate off its default, reload the page, and snapshot it: the slider sits at
      the moved position. Ask the user to clear this site's storage for the key the boundary serves
      (DevTools, Application, Local Storage) and reload: the slider sits at its default
- [ ] 6.12 Kill the port 8089 listener; `openspec validate audio-interface --strict` reports the
      change valid; `just happen` builds and `just check` is green on a clean tree
