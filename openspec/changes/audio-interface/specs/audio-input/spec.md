## Purpose

Turns what a microphone hears into six bounded control sources the world can be played with: the
listen affordance and its capture chain, the per-frame analysis poll, and the pure Nim core that
reduces spectra to named features.

## ADDED Requirements

### Requirement: Capture starts inside the listen gesture and stops completely

The audio context, the microphone request, and the analyser SHALL all be created inside the handler
of the listen control's activation. None of them SHALL be created at launch, on preset load, or on
any other event: the click is the consent, every session.

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

### Requirement: The affordance reports one of five states

The affordance SHALL report exactly one of five states, and the panel SHALL render the state's name
while restating none of the thresholds behind it:

- `Disconnected`: never asked, or turned off.
- `Requesting`: the permission prompt is open.
- `Connected`: the stream is live.
- `Denied`: the request ended without a live stream, whether the user refused the prompt or the
  launched window offers no capture.
- `Silent`: connected, with the loudness feature at the bottom of its normalized window for three
  seconds, the state that answers whether the room is quiet or the capture is broken.

A request SHALL leave `Requesting` when it settles, either way.

Enforcement: the states are one Nim enum, so a consumer that leaves a state unhandled fails the Nim
build wherever it matches exhaustively (`just build-app`, `justfile:26-27`). The transitions
themselves are review-enforced and verified in a running app, since the capture chain is never
mocked.

#### Scenario: The prompt is open
- **WHEN** the user activates the listen control and the browser's permission prompt is open
- **THEN** the affordance reports `Requesting`

#### Scenario: A refused request settles
- **WHEN** the request ends without a live stream
- **THEN** the affordance reports `Denied` and does not remain in `Requesting`

#### Scenario: A quiet room is legible
- **WHEN** a live capture reports loudness at the bottom of its window for three seconds
- **THEN** the affordance reports `Silent` and the capture stays live

#### Scenario: Sound returns
- **WHEN** a `Silent` capture receives sound above the floor
- **THEN** the affordance reports `Connected` on the next analysed frame

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

Exactly four inputs SHALL cross into the feature core each frame: the frequency array of 1024
decibel values, the time-domain array of 2048 samples, the sample rate, and the frame's wall-clock
delta. Every constant (band edges, window widths, thresholds, the refractory span) and every
arithmetic step from arrays to feature values SHALL live inside that module, which SHALL read a
decibel value of negative infinity as zero magnitude. No feature value SHALL be computed in
JavaScript, in a shader, or in the panel, and the wiring around the core SHALL do nothing but poll,
copy, and call.

Every constant the core expresses in time SHALL be honored against that delta rather than counted in
frames, so the refractory window and the adaptation span the same wall-clock time at any frame rate.
A constant counted in frames spans half the seconds at 120 fps that it spans at 60.

Enforcement: the module compiles on both backends and a native test compiled with `nim c` exercises
it under `just test`, the pattern the pure cores already follow (`src/climate_core.nim`,
`tests/test_climate_core.nim`). The "computed nowhere else" half is review-enforced.

#### Scenario: A frame's analysis is one call
- **WHEN** a frame polls the analyser
- **THEN** the wiring copies the two arrays, hands them to the core with the sample rate and the
  frame's wall-clock delta, and receives the six feature values back

#### Scenario: Time constants hold at any frame rate
- **WHEN** the same signal is analysed twice, once at a 8.33 ms frame delta and once at 16.7 ms
- **THEN** the refractory window and the gain adaptation span the same wall-clock time in both runs

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
  by logarithmic frequency position between 200 Hz and 8000 Hz. Below the energy floor the centroid
  is undefined, so brightness SHALL decay toward zero across frames instead of jumping to a value.

Enforcement: a native test over the core under `just test`, holding a single-bin spectrum at 440 Hz
to its logarithmic position within tolerance, and holding energy confined to one band to that band's
feature leading while the others stay low.

#### Scenario: A single tone lands where its frequency says
- **WHEN** the core receives a spectrum with all energy in the bin nearest 440 Hz
- **THEN** brightness reports 440 Hz's logarithmic position within tolerance, and bass and high stay
  near zero

#### Scenario: Band energy reaches its own feature
- **WHEN** the core receives a spectrum with energy confined to one band
- **THEN** that band's feature leads and the other two stay low

#### Scenario: Brightness fades instead of jumping
- **WHEN** energy falls below the floor where the centroid is undefined
- **THEN** brightness decays toward zero across frames, neither snapping to zero in one frame nor
  holding its last value

### Requirement: Onset fires on rectified spectral flux with a refractory window

`audio:onset` SHALL be delivered as an event source. The core SHALL compute half-wave rectified
spectral flux, the sum of per-bin magnitude increases since the previous frame, normalized by a
running median. A flux crossing of the threshold SHALL fire exactly one event carrying its energy
clamped to [0, 1]. For 100 ms after a firing, no further event SHALL fire however the flux moves.

Enforcement: a native test under `just test` feeding a click train at a known period, asserting one
event per click at the expected frames and none inside the refractory window.

#### Scenario: A click train fires once per click
- **WHEN** the core receives a click train whose period exceeds the refractory window
- **THEN** one event fires per click, at the expected frames

#### Scenario: The refractory window holds
- **WHEN** two threshold crossings fall within 100 ms of each other
- **THEN** only the first fires an event

#### Scenario: Steady sound fires nothing
- **WHEN** the core receives a loud steady spectrum whose bins stop increasing
- **THEN** no onset event fires, however loud the signal

### Requirement: Every feature stays inside [0, 1] and never reaches NaN

For any finite input arrays and any sample rate the analyser reports, each of the six values SHALL
be a finite number inside [0, 1]. Silence, every bin at negative infinity, SHALL give exactly zero
for every feature and fire no onset, and the core's own state SHALL stay finite across it, so the
next sounding frame produces finite values.

Enforcement: two native tests under `just test`, a silence case and a fuzz sweep over random finite
arrays asserting range and finiteness on every feature.

#### Scenario: Random input stays in range
- **WHEN** the core receives random finite arrays
- **THEN** every feature value is finite and inside [0, 1]

#### Scenario: Silence reads as zero
- **WHEN** every bin of a frame reads negative infinity
- **THEN** every feature is exactly zero, no onset fires, and the following sounding frame produces
  finite values

### Requirement: Normalization adapts to unknown gain without a control

Each normalized feature SHALL track a floor and a ceiling in decibels. The floor rises slowly and
falls instantly, tracking the noise floor. The ceiling rises instantly on a louder frame and decays
slowly, holding recent peaks. The feature is the level's clamped position inside that window, and
the window SHALL hold a minimum width so silence divides by nothing.

No calibration control SHALL ship with it: no input-gain slider, no loudest-pin, no threshold
control. Audio SHALL add no entry to the parameter descriptor table.

Enforcement: a native test under `just test` stepping the input level 20 dB up and back down and
asserting every feature returns inside (0, 1) within a bounded frame count the test pins. The empty
descriptor claim is held by `tests/test_param_descriptor.nim`, which walks the whole table.

#### Scenario: A gain step is absorbed
- **WHEN** the input level steps 20 dB up or down and holds
- **THEN** every feature returns inside (0, 1) within the bounded frame count the test pins

#### Scenario: A narrow window never divides by zero
- **WHEN** the level sits inside a window narrower than the minimum width
- **THEN** the feature value is finite, computed against the minimum width

#### Scenario: The audio section offers no numbers to tune
- **WHEN** the panel renders the audio section
- **THEN** it offers the listen control and the meters, and no slider for gain, threshold, or
  calibration

### Requirement: The core adds no smoothing beyond its definitions

A feature's value for a frame SHALL be a function of that frame's arrays, the previous frame's
spectrum where the definition differences against it, and the normalization state. No attack
constant, no release constant, and no fixed averaging SHALL be layered on top. The musical smoothing
is the matrix row's own slew, applied where the user chose it, and the meters therefore show a
transient as the core computed it.

Enforcement: a native test under `just test` asserting that a loud frame followed by a silent frame
lands the level features at their silent values on that next frame.

#### Scenario: A transient is not smeared
- **WHEN** a single loud frame is followed by a silent frame
- **THEN** loudness and the three band features read their silent values on that next frame, with no
  release ramp across frames

#### Scenario: Smoothing is the row's choice
- **WHEN** a user raises the slew on a row driven by an audio source
- **THEN** the world's response smooths and the metered value is unchanged

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
(`src/ui/api/help_content.nim:46-51`), keyed through `ReservedHelpKeys` because audio ships no
descriptor group (`src/ui/api/help_content.nim:38-40`). It SHALL cover what the listen control does,
that captured sound never leaves the application, the permission prompt and how to revisit a
refusal, the six sources in the room's terms, what the meters show, and what the shipped rows do,
with an invitation to remap them.

The file SHALL keep the four coverage relations green, including the relation that no help file
names an id absent from the descriptor table
(`tests/test_help_content.nim:29-63`).

Enforcement: `tests/test_help_content.nim` under `just test`, whose relations fail on a missing
file, an unresolvable key, an unnamed descriptor, and a named id no descriptor serves.

#### Scenario: Help for audio is served like every other group
- **WHEN** the user opens help with the audio section in view
- **THEN** the audio file's markdown is served through the boundary, with no prose held in the panel

#### Scenario: The audio file passes the coverage sweep
- **WHEN** `just test` runs with the audio help file in place
- **THEN** all four coverage relations pass, the audio key resolving as a reserved key and the file
  naming no id the descriptor table lacks
