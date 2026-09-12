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

## 1. Prove the rig and gate the microphone

The proposal's measurement gate. Browser MCP cannot press the browser's own permission prompt
and does not drive the webui-launched window, so the two clicks in 1.6 are the user's; the
feature core in group 2 waits on nothing here.

- [ ] 1.1 Confirm the Browser MCP tools are present and connected. If not, ask the user to
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
- [x] 1.5 **Red first.** Run `nim c -r tests/test_panel_reachability.nim` and confirm "every
      catalog entry is placed by some component" fails naming `listen`. Write
      `web-ui/src/components/AudioSection.tsx` rendering `<Toggle ctrl={ctrl} id="listen" ...>`
      whose `checked` is true in `Requesting`, `Connected` and `Silent`, calling
      `ctrl.api.startListening()` or `stopListening()` on change, with the state's name on a
      line under it; place `<Section title="Audio">` in `web-ui/src/components/Panel.tsx` after
      the mappings section `midi-interface` adds and before Presets. Run the reachability suite
      green
- [ ] 1.6 **Live gate.** `just happen`, launch `./main` in the background, poll
      `http://127.0.0.1:8089` for 200, navigate the connected tab there, press Listen, and ask
      the user to allow the prompt; read the `[audio]` line through the console log and record
      which constraints the tab honored. Press Listen again and ask the user whether the OS
      microphone indicator went dark. Then ask the user to press Listen in the webui-launched
      window and report whether it prompted and connected, since that window is not the
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

## 3. The per-frame poll and the matrix hand-off

- [ ] 3.1 In `src/audio_input.nim` register the `audio` family at wiring time through
      `web_api.registerSourceFamily` with five continuous declarations and one event
      declaration, each carrying the label the meters and the mapping editor show. Add
      `pollAudioFrame(dtSeconds)`: with a live chain, copy the two arrays, call `analyse`, set
      each continuous source through `setSourceValue`, emit `audio:onset` through
      `emitSourceEvent` with the energy as magnitude and ordinal zero, and move the state between
      `Connected` and `Silent` on the core's silence report. In `src/app.nim` call it in the
      frame loop directly before `web_api.flushMatrix(cappedDt)`. Verify `just build-app`, and by
      reading the loop that the call precedes the flush
- [ ] 3.2 **Red first.** In the shipped-matrix test `midi-interface` lands beside
      `src/ui/input/control_matrix.nim`, pin six audio rows by source, kind, target and depth:
      `audio:onset` Touch on a one-cell grid with `baseNote` 0; `audio:bass` Modulate
      `fluidStrength` +0.30; `audio:loudness` Modulate `forceStrength` +0.25; `audio:high`
      Modulate `glowIntensity` 0; `audio:mid` Modulate `rdDeposit` 0; `audio:brightness`
      Modulate `rdFieldForce` 0; every Modulate row at a zero attack and an 80 ms release; the
      six targets distinct. Run it and confirm it fails. Add the rows to the default matrix
      `const` in `src/ui/input/control_matrix.nim` and run green; `just build-app` passes the
      static gate on the shipped rows
- [ ] 3.3 `just happen` builds and `just check` is green

## 4. Metering push and the affordance

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
- [x] 4.4 `just happen` builds and `just check` is green

## 5. Help and enforcement

- [ ] 5.1 Fill `docs/help/65-audio.md`: what Listen does and that captured sound never leaves
      the app, the permission prompt and how to revisit a refusal in the browser's site
      settings, the six sources in the room's terms, what the meters show, what the three live
      rows do, and the three rows waiting at zero depth with the invitation to raise and remap
      them. Name each source in bold, the form `bindingReferenceBody` uses, since
      `namedControlIds` reads only code-span lines and a source id resolves to no descriptor or
      catalog entry. Run `nim c -r tests/test_help_content.nim` green
- [x] 5.2 In `docs/enforcement.md` add `src/ui/input/audio_core.nim` to "Where authority
      lives" and three guarantee rows: every feature finite and in [0, 1] with silence reading
      zero (Test-held, `tests/test_audio_core.nim`); the capture chain created inside the listen
      gesture and released on stop (Unenforced, review against `src/audio_input.nim` and the
      gate record from 1.6); delivery before the frame's flush (Unenforced, review of the loop in
      `src/app.nim`). Verify by reading the tables
- [x] 5.3 `just happen` builds and `just check` is green

## 6. Live verification

Each task names the agent procedure and the observation that settles it. Browser MCP against
the user's Chrome, `./main` in the background, the port killed at the end. The permission
clicks are the user's, for the reason group 1 states.

- [ ] 6.1 `just happen`, launch `./main` in the background, poll the port, navigate the
      connected tab, and snapshot the Audio section: a switch named Listen with
      `aria-checked` false, a state line reading `Disconnected`, five meters at zero, no slider
- [ ] 6.2 Press Listen and snapshot before the user answers: `aria-checked` true and the line
      reading `Requesting`. After the user allows: `Connected`, the meters moving with sound in
      the room. Stay quiet for three seconds: `Silent`, the switch still on. Make a sound: back
      to `Connected` on the next frame. Record in
      `scratchpad/audio-interface/live-states__<DD-MM-YY-HHmm>.md`
- [ ] 6.3 With sound playing, read the Fluid Strength and Force Strength sliders' excursion
      shading on successive stats pushes and watch a blast land at the view's center on a hit;
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
      three zero-depth rows sit with their targets. Open help on the Audio section and confirm
      the audio file is served
- [ ] 6.7 Kill the port 8089 listener; `openspec validate audio-interface --strict` reports the
      change valid; `just happen` builds and `just check` is green on a clean tree
