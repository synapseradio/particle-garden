## Purpose

Turns what a microphone hears into six bounded control sources the world can be played with: the
listen affordance and its capture chain, the per-frame analysis poll, and the pure Nim core that
reduces spectra to named features.

## ADDED Requirements

### Requirement: Capture starts inside the listen gesture and stops completely

The audio context, the microphone request, and the analyser SHALL all be created inside the handler
of the listen control's activation. None of them SHALL be created at launch, on preset load, or on
any other event: the click is the consent, every session.

The microphone request SHALL ask for `echoCancellation`, `noiseSuppression`, and `autoGainControl`
each `false`, so the browser's call-tuned processing neither moves the level under the core's own
normalization nor removes sustained tones. The measurement gate SHALL read the granted track's
settings back and report which of the three the launched window honored.

Turning listening off SHALL stop the media stream's tracks and close the audio context, so the
operating system's own microphone indicator goes dark while the affordance reports that listening
stopped.

Enforcement: the build compiles the capture binding (`just build-app`, `justfile:26-27`), and the
proposal's measurement gate confirms a live stream inside the launched window. The lifecycle is
otherwise review-enforced and verified in a running app, because the capture chain is browser
territory that this project verifies by the build and never mocks, the stance the boundary module
already records for its own wiring (`src/web_api.nim:29-32`).

#### Scenario: A launched app asks for nothing
- **WHEN** the application starts and nobody activates the listen control
- **THEN** no permission prompt appears, no audio context exists, and no microphone stream is
  requested

#### Scenario: A preset never starts listening
- **WHEN** a preset is applied, built-in or user-saved
- **THEN** the listening state is unchanged and no permission prompt appears

#### Scenario: The permission request rides the activation
- **WHEN** the user activates the listen control
- **THEN** the audio context is created and the microphone is requested inside that same gesture

#### Scenario: The request asks for raw audio
- **WHEN** the microphone is requested
- **THEN** the constraints carry echo cancellation, noise suppression, and automatic gain control
  each set false, and the gate's report names which the granted track honored

#### Scenario: Stopping releases the microphone
- **WHEN** the user turns listening off
- **THEN** the stream's tracks are stopped and the audio context is closed, and the operating system
  stops showing the application as capturing audio

### Requirement: Captured audio reaches nothing but the analyser

The analyser SHALL be the only consumer of the microphone stream, connected onward to no
destination. The application SHALL neither store captured audio nor send it anywhere, and only the
six feature values and the affordance state SHALL leave the audio path.

Enforcement: review-enforced. Nothing mechanically prevents a second connection from the source
node, and the help file states the promise to the user in the same words
(`src/ui/api/help_content.nim:38-40` carries the key it is served under).

#### Scenario: Nothing is played back
- **WHEN** a capture chain is live
- **THEN** the captured signal reaches no output device and is never audible

#### Scenario: Nothing leaves the machine
- **WHEN** a capture chain is live
- **THEN** no captured sample and no derived spectrum is written to storage or sent over a network

### Requirement: The affordance reports one of six states

The affordance SHALL report exactly one of six states, and the panel SHALL render the state's name
while restating none of the thresholds behind it:

- `Disconnected`: never asked, or turned off.
- `Requesting`: the permission prompt is open.
- `Learning`: the stream is live and the core is learning the room, for the learning window of
  heard audio after connecting.
- `Connected`: the stream is live and the room is learned.
- `Denied`: the request ended without a live stream, whether the user refused the prompt or the
  launched window offers no capture.
- `Silent`: connected, with the loudness level at or under its room edge for three seconds, the
  state that answers whether the room is quiet or the capture is broken.

A request SHALL leave `Requesting` when it settles, either way. The core's report SHALL be one value
naming learning, sounding or silent, so no frame can report silent while the room is being learned.

Enforcement: the states are one Nim enum, so a consumer that leaves a state unhandled fails the Nim
build wherever it matches exhaustively (`just build-app`, `justfile:26-27`). The core's report, which
decides `Learning`, `Connected` and `Silent`, is agent-checkable by native tests under `just test`
(`tests/test_audio_core.nim`), including a room whose noise flickers by several decibels frame to
frame and a soft passage held after music. That the switch reads checked in `Learning` is held by
`web-ui/test/audio-section.test.ts` under `just test-ui`. The transitions themselves are
review-enforced and verified in a running app, since the capture chain is never mocked.

#### Scenario: The prompt is open
- **WHEN** the user activates the listen control and the browser's permission prompt is open
- **THEN** the affordance reports `Requesting`

#### Scenario: A refused request settles
- **WHEN** the request ends without a live stream
- **THEN** the affordance reports `Denied` and does not remain in `Requesting`

#### Scenario: The room is learned before anything reads
- **WHEN** a request settles with a live stream
- **THEN** the affordance reports `Learning` until the learning window of heard audio has passed,
  every feature reads zero and no onset fires meanwhile, and the switch reads checked

#### Scenario: A quiet room is legible
- **WHEN** a live capture reports the loudness level at or under its room edge for three seconds
- **THEN** the affordance reports `Silent` and the capture stays live

#### Scenario: A flickering room still reaches Silent
- **WHEN** the core, having learned a room and heard a sounding passage, receives that room with its
  noise moving by several decibels from frame to frame
- **THEN** the core reports silent within the silence window plus the half-second margin its test pins

#### Scenario: A soft legato passage never reads Silent
- **WHEN** a held passage standing more than the loudness gate over the learned room sounds for
  35 seconds after music, with no note boundary in it
- **THEN** the core reports no silent frame after the passage's first half second

#### Scenario: Sound returns
- **WHEN** a `Silent` capture receives sound whose level rises above the room edge
- **THEN** the core reports not silent on the first analysed frame whose loudness level stands above
  its room edge, which natively is the next frame and live arrives within one analyser window

### Requirement: The analyser window is fixed and the browser averages nothing

The analyser SHALL run with `fftSize` 2048 and `smoothingTimeConstant` 0, both set explicitly from
constants owned by Nim, each carrying beside it the conditions it was chosen under: at a 48000 Hz
input, 2048 samples give a 23.4 Hz bin width and a 42.7 ms window. No conditioning of the spectrum
SHALL happen in the browser, so every step a test could hold lives where a test reaches it.

Enforcement: the constants are Nim values compiled into the binding (`just build-app`,
`justfile:26-27`). Their values in the running analyser are review-enforced and verified in a
running app.

#### Scenario: The analyser is configured from Nim
- **WHEN** the analyser is created
- **THEN** its `fftSize` is 2048 and its `smoothingTimeConstant` is 0, both read from Nim constants

#### Scenario: Successive frames are independent
- **WHEN** two consecutive frames carry different spectra
- **THEN** the second frame's array carries that frame's spectrum, averaged with no part of the first

### Requirement: One pure Nim module computes every feature value

Exactly five inputs SHALL cross into the feature core each frame: the frequency array of 1024
decibel values, the time-domain array of 2048 samples, the sample rate, the frame's wall-clock
delta, and the Room Gate offset in decibels. Every constant (band edges, window widths, room gates,
the learning window, thresholds, the refractory span) and every
arithmetic step from arrays to feature values SHALL live inside that module, which SHALL read a
decibel value of negative infinity as zero magnitude. No feature value SHALL be computed in
JavaScript, in a shader, or in the panel, and the wiring around the core SHALL do nothing but poll,
copy, read the Room Gate, and call.

Every constant the core expresses in time SHALL be honored against that delta rather than counted in
frames, so the refractory window, the learning window, the held window and the ceiling's decay span the same
wall-clock time at any frame rate.
A constant counted in frames spans half the seconds at 120 fps that it spans at 60.

Enforcement: the module compiles on both backends and a native test compiled with `nim c` exercises
it under `just test`, the pattern the pure cores already follow (`src/climate_core.nim`,
`tests/test_climate_core.nim`). The "computed nowhere else" half is review-enforced.

#### Scenario: A frame's analysis is one call
- **WHEN** a frame polls the analyser
- **THEN** the wiring copies the two arrays, hands them to the core with the sample rate, the
  frame's wall-clock delta and the current Room Gate offset, and receives the six feature values back

#### Scenario: Time constants hold at any frame rate
- **WHEN** the same signal is analysed twice, once at a 8.33 ms frame delta and once at 16.7 ms
- **THEN** the refractory window and the learning window span the same wall-clock time in both runs,
  and the first reading after learning lands one frame after the learning window in each

#### Scenario: The panel computes no feature
- **WHEN** the panel renders a meter
- **THEN** it displays a value the core produced, computing no band sum, no centroid, and no
  normalization of its own

### Requirement: Five continuous features name fixed bands and a fixed brightness mapping

Five sources SHALL be delivered as continuous values, each defined from the frame the core receives:

- `audio:loudness`: the RMS of the time-domain frame, expressed in decibels, then normalized.
- `audio:bass`, `audio:mid`, `audio:high`: the mean linear magnitude over the bins falling in
  20 to 250 Hz, 250 to 2000 Hz, and 2000 to 8000 Hz, expressed in decibels, each normalized against
  its own window because spectral tilt reads one shared window as a permanently quiet high band.
- `audio:brightness`: the spectral centroid over linear magnitudes between 20 Hz and 8000 Hz, placed
  by logarithmic frequency position between 200 Hz and 8000 Hz. The centroid is defined only on a
  frame where at least one band's level stands above its room edge and the spectrum stands above the energy
  floor. On any other frame the spectrum is the room's own timbre, so brightness SHALL decay toward
  zero across frames instead of jumping to a value.

Enforcement: agent-checkable by native tests over the core under `just test`
(`tests/test_audio_core.nim`): a single-bin spectrum at 440 Hz, heard over a learned room, held to its
logarithmic position within tolerance; energy confined to one band, over a learned room, leading that band's
feature while the others stay low; and a learned room in which brightness falls below 0.01.

#### Scenario: A single tone lands where its frequency says
- **WHEN** the core receives a spectrum with all energy in the bin nearest 440 Hz
- **THEN** brightness reports 440 Hz's logarithmic position within tolerance, and bass and high stay
  near zero

#### Scenario: Band energy reaches its own feature
- **WHEN** the core receives a spectrum with energy confined to one band
- **THEN** that band's feature leads and the other two stay low

#### Scenario: Brightness fades instead of jumping
- **WHEN** every band's level falls to its room edge, where the centroid is undefined
- **THEN** brightness decays toward zero across frames, neither snapping to zero in one frame nor
  holding its last value

#### Scenario: A quiet room has no brightness
- **WHEN** the core receives only a room whose every band stays under its room edge
- **THEN** brightness settles below 0.01, whatever the room's spectral shape

### Requirement: Onset fires on rectified spectral flux with a refractory window

`audio:onset` SHALL be delivered as an event source. The core SHALL compute half-wave rectified
spectral flux, the sum of per-bin magnitude increases since the previous frame, normalized by a
running median. A flux crossing of the threshold SHALL fire exactly one event carrying its energy
clamped to [0, 1], and only on a frame whose loudness level stands above its room edge, so the room's own
flicker fires nothing. For 100 ms after a firing, no further event SHALL fire however the flux moves.

Enforcement: agent-checkable by native tests under `just test` (`tests/test_audio_core.nim`): a click
train at a known period, asserting one event per click at the expected frames and none inside the
refractory window, and a flickering room asserting no event across its whole run.

#### Scenario: A click train fires once per click
- **WHEN** the core receives a click train whose period exceeds the refractory window
- **THEN** one event fires per click, at the expected frames

#### Scenario: The refractory window holds
- **WHEN** two threshold crossings fall within 100 ms of each other
- **THEN** only the first fires an event

#### Scenario: The room fires nothing
- **WHEN** the core receives a learned room whose noise flickers frame to frame under its room edge
- **THEN** no onset event fires across the run, though the room's flux crosses the threshold

#### Scenario: Steady sound fires nothing
- **WHEN** the core receives a loud steady spectrum whose bins stop increasing
- **THEN** no onset event fires, however loud the signal

### Requirement: Every feature stays inside [0, 1] and never reaches NaN

For any finite input arrays, any sample rate the analyser reports, and any Room Gate offset inside
its descriptor range, each of the six values SHALL be a finite number inside [0, 1]. Silence, every bin at negative infinity, SHALL give exactly zero
for every feature and fire no onset, and the core's own state SHALL stay finite across it, so the
next sounding frame produces finite values.

Enforcement: agent-checkable by two native tests under `just test` (`tests/test_audio_core.nim`), a
silence case and a fuzz sweep over random finite arrays and Room Gate offsets across the range in
`src/config_ranges.nim`, asserting range and finiteness on every feature.

#### Scenario: Random input stays in range
- **WHEN** the core receives random finite arrays at any Room Gate offset in range
- **THEN** every feature value is finite and inside [0, 1]

#### Scenario: Silence reads as zero
- **WHEN** every bin of a frame reads negative infinity
- **THEN** every feature is exactly zero, no onset fires, and the following sounding frame produces
  finite values

### Requirement: The room is learned once at Listen start and read as zero

For the learning window after a fresh analysis state, the core SHALL gather each normalized
feature's level while every feature reads zero and no onset fires. The window counts heard seconds:
each frame adds its wall-clock delta, capped at one analyser window of audio. When it closes, each
feature's room level SHALL be the median of what it gathered. No room level SHALL move again, up or
down, until the analysis state is re-initialized, which turning Listen off does, so turning Listen
on again learns anew.

Each feature's lower edge SHALL stand at its room level plus that feature's room gate plus the Room
Gate offset, and SHALL rise above that only to 24 dB under the feature's held level, so a meter
spreads over the top 24 dB of what it recently heard. The held level is the median of the last
second of heard audio, so a sound held for less than half a second SHALL NOT raise the lower edge.
The ceiling rises instantly and decays toward the larger of the held level and the level with a
1 s time constant. The
feature is the level's clamped position between the lower edge and the ceiling, over a span of at
least the minimum window width, so silence divides by nothing. No window floor SHALL follow the level, so a
sound held at a steady level keeps its reading for as long as it sounds. The learning window, the
statistic, the held window, the ceiling decay and each room gate SHALL be constants carrying beside
them the conditions they were measured under. For a gate, that is the excursion of that feature's
level above the learned median that stationary room noise does not exceed. For the held window, it
is the longest hit it disregards.

An input gain applied before learning moves no feature, because the median, the held level, the
ceiling and every level shift together under a constant decibel offset. A gain applied after learning moves levels
against the room edge, which the Room Gate already does. No input-gain control SHALL ship.

Enforcement: agent-checkable by native tests under `just test` (`tests/test_audio_core.nim`):
- A sound more than 24 dB under a level held for one second reading zero, and one less than 24 dB
  under it reading above zero.
- A drone through one analyser window at full scale never reading zero, and returning within 10% of
  its reading within 2.5 s, two and a half ceiling-decay time constants.
- A sound 20 dB under a held drone reading above zero after a sound 20 dB over the drone covered
  0.4 s of the last second, which a mean of the second would not give.
- The same at 8.33 ms deltas, after a sound 12 dB over the drone covered 0.3 s, with the probe
  16 dB under it, which a window counted in frames would not give.
- A drone held 60 s after a learned room, whose loudness reading at 60 s stays within 0.01 of its
  reading at 1 s.
- A flickering room after a sounding passage, reading zero on every level feature at its 99th
  percentile.
- Zero readings and no onset while the room is learned.
- A burst shorter than half the learning window not learned as room.
- A fresh state learning a louder room as zero.
- Lowering the Room Gate never lowering a reading.
- Every level, learning included, shifted by one decibel offset changing no feature.

That no other audio control ships is held by `tests/test_param_descriptor.nim`, which pins
`audioRoomGate` as the only descriptor routed through the audio store.

#### Scenario: A drone held after a learned room keeps its reading
- **WHEN** a steady tone 12 dB over a learned room sounds for 60 seconds
- **THEN** its loudness reading at 60 seconds is within 0.01 of its reading at 1 second, and above
  0.1

#### Scenario: A single loud hit leaves a held sound its reading
- **WHEN** a steady tone 12 dB over a learned room is interrupted by one analyser window at full
  scale, and then sounds again
- **THEN** its loudness never reads zero, and it returns within 10% of its reading before the hit
  within 2.5 seconds

#### Scenario: A quiet room reads as zero
- **WHEN** the core, having learned a room, receives only that room's noise flickering by several
  decibels from frame to frame
- **THEN** loudness, bass, mid and high read zero on at least 99 frames in 100

#### Scenario: A burst at Listen start is not learned as room
- **WHEN** a sound covering less than half the learning window arrives while the room is learned
- **THEN** that sound, heard again after learning, reads above zero

#### Scenario: Turning Listen off and on learns the room again
- **WHEN** a fresh analysis state learns a room louder than the one learned before
- **THEN** that louder room reads zero and reaches silent

#### Scenario: A narrow window never divides by zero
- **WHEN** the level sits inside a window narrower than the minimum width
- **THEN** the feature value is finite, computed against the minimum width

#### Scenario: Microphone gain before learning moves nothing
- **WHEN** every bin and sample of a whole run, learning included, is scaled by one constant gain
  that keeps it above the level floor
- **THEN** every feature reads the same on every frame as the unscaled run

#### Scenario: Lowering the Room Gate never lowers a reading
- **WHEN** the same run is analysed at two Room Gate offsets inside the range
- **THEN** no level feature reads lower on any frame at the lower offset

### Requirement: One Room Gate control sets how far above the room a sound must rise

The audio section SHALL offer exactly one slider, the Room Gate, the decibel offset added to every
feature's room gate. It is the parameter descriptor `audioRoomGate`, labelled "Room Gate", in the
descriptor group `audio`, routed through a store of its own that never reaches `CONFIG`:
- Its range SHALL come from `src/config_ranges.nim`, its minimum being the negated widest room gate
  and its maximum 120 dB.
- Its default of zero SHALL come from `src/ui/input/audio_core.nim` beside the room gates, marked by
  a default notch.
- The panel SHALL restate none of its numbers.

The wiring SHALL read the offset every frame into the core's input, so a move lands on the next
analysed frame, and stopping listening SHALL leave the offset unchanged. The offset SHALL be
remembered on this browser across reloads, under the storage key the boundary serves, and SHALL
never be written into or read from a preset. No audio source's row SHALL write it, and a controller's
row may.

Raising the offset makes a louder room read as zero and reach `Silent`, which is how a room that
changed after Listen started is answered without relearning. Lowering it lets quieter
sounds through with the room's flicker. Below zero, `Silent` may not be reachable, and the help file
says so.

This control reverses an earlier rule that the audio section offer no numbers to tune. A quiet room
observed live read loudness far above zero and never reached `Silent`, and live sets run in rooms
whose noise changes after the room was learned.

Enforcement: agent-checkable by:
- `tests/test_param_descriptor.nim` under `just test`, pinning the descriptor's group, store and
  default and `audioRoomGate` as the only id its store routes.
- `src/config_ranges.nim`'s compile-time range assertions, and `tests/test_audio_core.nim` holding the
  minimum equal to the negated widest room gate and the offset's effect on the core.
- `tests/test_panel_reachability.nim`, holding that the panel places it.
- `tests/test_response_probe.nim`, holding that it carries a probe.

- `web-ui/test/audio-section.test.ts` under `just test-ui`, holding that a stored value restores only
  when it parses to a finite number.
- `tests/test_control_matrix.nim`, holding the refusal of an audio source's row.

Next-frame landing, survival across a stop, and survival across a reload are review-enforced against
`src/audio_input.nim` and `web-ui/src/components/Panel.tsx`, and verified in a running app.

#### Scenario: Raising the gate silences a steady sound
- **WHEN** the Room Gate is raised above a steady sound that stands a few decibels over the learned
  room
- **THEN** every level feature reads zero and the core reports silent within the silence window
  plus its pinned margin

#### Scenario: Lowering the gate returns the sound
- **WHEN** the Room Gate returns below that sound
- **THEN** the sound's level features read above zero again and the core reports not silent

#### Scenario: A preset does not carry the room
- **WHEN** a preset is saved with the Room Gate moved from its default, and loaded after the gate is
  moved again
- **THEN** the preset's schema holds no Room Gate field and the gate keeps its current position

#### Scenario: The Room Gate survives a reload
- **WHEN** the Room Gate is moved and the page is reloaded
- **THEN** the slider and the core's offset start at the moved position, clamped to the range

#### Scenario: A corrupt stored value leaves the default
- **WHEN** the stored Room Gate value parses to no finite number
- **THEN** the Room Gate starts at its default

#### Scenario: The only number in the section is the Room Gate
- **WHEN** the panel renders the audio section
- **THEN** it offers the listen control, the meters, and the Room Gate slider, and no slider for
  input gain, a per-feature gate, or the silence threshold

### Requirement: The core adds no smoothing beyond its definitions

A feature's value for a frame SHALL be a function of that frame's arrays, the previous frame's
spectrum where the definition differences against it, and the normalization state. No attack
constant, no release constant, and no fixed averaging SHALL be layered on top. The musical smoothing
is the matrix row's own attack and release, applied where the user chose them, and the meters
therefore show a transient as the core computed it.

Enforcement: a native test under `just test` asserting that a loud frame followed by a silent frame
lands the level features at their silent values on that next frame.

#### Scenario: A transient is not smeared
- **WHEN** a single loud frame is followed by a silent frame
- **THEN** loudness and the three band features read their silent values on that next frame, with no
  release ramp across frames

#### Scenario: Smoothing is the row's choice
- **WHEN** a user raises the release constant on a row driven by an audio source
- **THEN** the world's fall from a hit lengthens and the metered value is unchanged

### Requirement: Audio registers one source family and delivers before the flush

Audio SHALL register one family under the id `audio`, declaring exactly six sources: five continuous
(`audio:loudness`, `audio:bass`, `audio:mid`, `audio:high`, `audio:brightness`) and one event
(`audio:onset`). Registration happens at wiring time, so the six ids are offerable in the mapping
editor and nameable in help whether or not a capture chain has ever been live.

Each frame with a live capture chain, audio SHALL poll the analyser, run the core, set the latest
value for each continuous source, and enqueue an onset event when one fires, all before that frame's
matrix flush, so the frame's world response uses the frame's own values. An onset event SHALL carry
its energy as magnitude and ordinal zero, since onset has no ordinal space of its own.

Audio SHALL reach the matrix only through the family's registration and delivery entry points,
inspecting no row, no arbitration, and no flush internals.

Enforcement: the shipped rows naming these ids are validated against the family's declarations by
the static gate the default matrix carries (`control-matrix`). The per-frame ordering is
review-enforced in the frame loop, which the JS backend builds and no native test runs, the same
limit the boundary module records (`src/web_api.nim:29-32`).

#### Scenario: A frame's values reach the frame's flush
- **WHEN** a frame's analysis completes
- **THEN** the six values are delivered before that frame's matrix flush

#### Scenario: An onset carries energy and no ordinal
- **WHEN** the core fires an onset
- **THEN** the event carries its energy in [0, 1] as magnitude and ordinal zero

#### Scenario: The sources are mappable before first use
- **WHEN** the user opens the mapping editor having never listened
- **THEN** all six audio sources are offered, with their kinds

### Requirement: Stopping listening returns the world to its authored base

While audio delivers nothing, before the first listen, after a denial, and after listening stops, no
audio row SHALL displace any parameter, and the world SHALL run on the values the user authored.
Stopping mid-excursion SHALL return the affected parameters to their stored values instead of
leaving them held at the last delivered value, and SHALL leave every stored row in place.

Enforcement: review-enforced on the audio side and verified in a running app. The return itself
lands through the one effect-time site, which recomputes the effective state from the stored record
on every write and leaves that record untouched (`src/web_api.nim:135-160`), and the matrix's
behavior for a zero-valued or inert row is held by the `control-matrix` capability's tests.

2026-09-12: `withdrawSourceFamily` in `src/ui/input/control_matrix.nim` zeroes a family's
continuous sources so their Modulate rows release toward base and their Write rows stop writing;
`stopListening` and `onMicrophoneDenied` in `src/audio_input.nim` call it with `"audio"` on
stop and on denial. Test-held in `tests/test_control_matrix.nim`.

#### Scenario: Stopping returns the sliders to their bases
- **WHEN** the user turns listening off while audio modulation is displacing parameters
- **THEN** the effective values return to the stored values and the sliders show their authored
  positions

#### Scenario: A denial displaces nothing
- **WHEN** a permission request ends in `Denied`
- **THEN** no audio row displaces anything and every stored row keeps its place

#### Scenario: Listening again resumes the same rows
- **WHEN** the user turns listening back on
- **THEN** the same rows drive again with no re-editing

### Requirement: A help file documents the listen control and the six sources

`docs/help/` SHALL carry one audio file with the three-line front matter the parser asserts
(`src/ui/api/help_content.nim:46-51`), keyed by the descriptor group `audio`, which the Room Gate
makes a group, so the key leaves `ReservedHelpKeys` (`src/ui/api/help_content.nim:42`). It SHALL cover
what the listen control does, that captured sound never leaves the application, the permission
prompt and how to revisit a refusal, the six sources in the room's terms, what the meters show, what
the `Learning` state and that turning Listen off and on learns the room again, what the Room Gate
does and when to raise or lower it, and what the four shipped rows do. It SHALL name
`audioRoomGate` on a code-span line.

The file SHALL keep the four coverage relations green, including the relation that no help file
names an id absent from the descriptor table
(`tests/test_help_content.nim:29-63`).

Enforcement: agent-checkable by `tests/test_help_content.nim` under `just test`, whose relations fail
on a missing file, an unresolvable key, a descriptor its group's file does not name, and a named id
no descriptor serves.

#### Scenario: Help for audio is served like every other group
- **WHEN** the user opens help with the audio section in view
- **THEN** the audio file's markdown is served through the boundary, with no prose held in the panel

#### Scenario: The audio file passes the coverage sweep
- **WHEN** `just test` runs with the audio help file in place
- **THEN** all four coverage relations pass, the audio key resolving as a descriptor group and the
  file naming `audioRoomGate` and no id the descriptor table lacks
