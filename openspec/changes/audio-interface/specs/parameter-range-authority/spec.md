## ADDED Requirements

### Requirement: Room Gate range

`src/config_ranges.nim` SHALL define `AUDIO_ROOM_GATE_MIN_DB` and `AUDIO_ROOM_GATE_MAX_DB`, the Room
Gate's range in decibels, under the standard static non-emptiness assertion, with zero inside the
range. Each carries the condition it was chosen under beside it:
- The minimum is the negated widest per-feature room gate, the offset below which no feature's
  lower edge opens further.
- The maximum is 0 minus the core's level floor, 120 dB. The float frequency data the core reads is
  unclipped decibels (`minDecibels` bounds only the byte data), the core clamps every level at or
  above -120 dB, and a full-scale input bounds every level at or below 0 dBFS. So at the maximum
  every lower edge stands above full scale and every feature reads zero.

The descriptor SHALL travel on the power curve, so the low offsets where measured rooms sit keep
most of the travel.

The descriptor table SHALL consume both like every other range, and the default SHALL come from
`ROOM_GATE_DEFAULT_DB` in `src/ui/input/audio_core.nim`, the way the camera's default comes from
`camera_core`.

The Room Gate is deliberately absent from the preset schema: it describes the room, not the world,
so a preset loaded mid-set leaves it where the performer put it. `tests/test_param_descriptor.nim`
SHALL pin `audioRoomGate` as the only descriptor routed through the audio store, so a second one
cannot widen that hole silently.

Enforcement: agent-checkable by:
- The compile-time range assertions in `src/config_ranges.nim` (`just build-app`, `just test`).
- `tests/test_audio_core.nim`, holding the minimum equal to the negated widest room gate and the
  maximum equal to 0 minus the level floor.
- `tests/test_param_descriptor.nim` under `just test`, pinning the audio-store set, the descriptor's
  range and its default.

#### Scenario: A write clamps at the authority's bounds
- **WHEN** a slider drag or a Write row drives the Room Gate beyond either bound
- **THEN** the stored offset clamps to the `config_ranges` constant

#### Scenario: A second descriptor joins the audio store
- **WHEN** a descriptor other than `audioRoomGate` is routed through the audio store
- **THEN** `just test` fails at the audio-routing assertion, which pins that set to one id

#### Scenario: A preset carries no Room Gate
- **WHEN** a preset is exported
- **THEN** its schema holds no Room Gate field, and importing it leaves the Room Gate unchanged
