# audio-interface

## Why

Particle Garden aims at expression, and the `midi-interface` change gives it hands. Sound is the second sense: a microphone's signal, reduced to a few legible features, plays the same control matrix, so a room or an instrument breathes through the world's couplings in real time. A visualizer's picture stops when the sound stops. This world keeps living between onsets, because its own dynamics stand between signal and image, and what reaches the eye is the world's response.

## What Changes

- **Audio capture behind a panel affordance.** The browser's microphone permission prompt fires on first use of a "listen" control rather than at startup, adopting the platform behavior deliberately (docs/engineering-principles.md, article 11). Capture uses `getUserMedia`, whose secure-context requirement localhost satisfies (https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia). The microphone is the first source. System audio and file playback stay out of scope.
- **Analysis rides the frame loop.** An `AnalyserNode` supplies frequency bins, polled once per frame (https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode). The browser supplies the FFT the way the GPU supplies compute, and 60 fps is the only consumer, so onset detection at frame granularity suffices and no AudioWorklet enters.
- **A pure feature core, natively tested.** Every step from bins to feature values lives in one pure Nim module compiled on both backends, tested natively against synthetic spectra, the discipline the input handlers already follow (`src/ui/input/key_handler.nim`, `tests/test_input.nim`). The shader oracles mirror math they cannot execute (CLAUDE.md, Reference oracles). This core needs no mirror, since it is the one implementation.
- **Six shipped sources.** Loudness, three band energies (bass, mid, high), and brightness (spectral centroid) arrive as continuous sources in [0, 1]. Onset arrives as an event source carrying its energy. Each is named in help like every binding (CLAUDE.md, Help).
- **Sources feed the control matrix, and nothing else changes there.** Continuous features drive Modulate and Write rows, onsets drive Fire and Touch rows, so a kick drum blasts the world the way a pad or a two-finger tap does (`src/canvas_input.nim:189-198`, `src/ui/state/input_state.nim:60-64`). Families normalize at their own boundary, so past that point the matrix cannot tell a feature from a CC (openspec/changes/midi-interface/proposal.md). Modulation leads the shipped audio defaults: excursions fold into the effective state at the one effect-time clamp site (`src/web_api.nim:135-160`), the stored record stays the user's own, and silence returns the world to the authored base. Which features map to which targets, the four coupling strengths leading (`couplingsOf`, `src/ui/state/sim_config.nim:43-57`), is a design decision recorded in design.md.
- **Metering by a per-frame push.** The frame loop pushes the listen state and the current feature values to the panel once per frame while the audio section subscribes, so a meter moves on the clock that produces the values. It rides a channel of its own rather than the stats push, which runs on the 500 ms fps window (`src/app.nim:284`) where a meter reads as broken, and which therefore stays exactly as it is. The listen affordance reports connected, denied, or silent.
- **This change consumes the control matrix.** The sibling change `midi-interface` introduces the matrix spine: the row model, arbitration, and the modulate arm. That spine absorbs the climate drift and the force weather, two self-movers already running in the frame loop (`src/app.nim:257-269`), so it earns its place with no controller attached and lands before this change. The work here is capture, the feature core, and family registration, with no matrix code of its own.

Out of scope: system audio capture (reachable later through `getDisplayMedia`'s share picker on Chrome 141+ with macOS 14.2 or newer, https://blog.addpipe.com/getdisplaymedia-allows-capturing-the-screen-with-system-sounds-on-chrome-on-macos/), file playback, the substrate register (band energies deposited into the Gray-Scott field as matter would need a new GPU pass plus its pure mirror, a change of its own), beat and tempo tracking, pitch detection.

## Capabilities

### New Capabilities

- `audio-input`: capture acquisition and the listen affordance, per-frame analysis polling, the pure feature core with its six shipped sources, and normalization into matrix sources.

### Modified Capabilities

- `gardenapi-boundary`: the boundary pushes the listen affordance state and the live feature values from the frame loop, once per frame while the panel subscribes.
- `control-matrix` (introduced by the sibling change `midi-interface`): the shipped defaults gain audio rows, modulation leading.

## Impact

- **Nim (JS backend).** A Web Audio binding joins `src/bindings/` (`getUserMedia`, `AudioContext`, `AnalyserNode`). A pure feature module joins the natively tested set. `src/web_api.nim` gains the listen affordance surface and feature metering on the push. `src/app.nim` polls the analyser each frame and hands source values to the same matrix flush the MIDI sources use, honoring its import-order constraint (`src/app.nim:8-11`).
- **Panel.** The listen affordance with its permission state, feature meters, and audio rows appearing in the matrix editor the sibling change builds.
- **Help.** An audio group documents under `docs/help/` in the same change that adds the sources, and the four test-held coverage relations extend to it (CLAUDE.md, Help).
- **Dependencies.** None added. Web Audio is an API of the launched browser window.
- **Measurement gate.** Before capture work proceeds, a spike confirms `getUserMedia` resolves with a live microphone stream inside the webui-launched window on this machine, since browser selection belongs to webui (https://github.com/webui-dev/webui) and the permission UI inside that window is the unproven part. If the launched browser refuses, the affordance reports unavailability, and the feature core stays blind to the outcome either way.
