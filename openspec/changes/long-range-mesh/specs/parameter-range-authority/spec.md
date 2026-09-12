## ADDED Requirements

### Requirement: The long-range ranges

`src/config_ranges.nim` SHALL define the long-range coupling's tunables under the standard static
non-emptiness and default-in-range assertions:

- **Long-range strength.** The shipped range is `0.0 .. 1.0` with default `0.0`. The range SHALL
  include zero, and zero SHALL be a labelled reachable notch, because zero is the world without the
  coupling and the static loop over coupling floors asserts it. The maximum is a working bound rather
  than a measured one until an in-app calibration sets it, and SHALL be marked as such beside the
  constant with the conditions the calibration must record: the strength at which a settled population
  visibly gathers toward the world's densest region within a few seconds, and the strength at which
  the long-range term overwhelms the species force at the interaction radius.
- **Reach.** The shipped range is `60 .. 4000` world units with default `600`, on logarithmic slider
  travel. The minimum SHALL be strictly positive, for a reason recorded beside the constant: the
  uniform carries the inverse squared screening length, so a reach of zero has no finite
  representation, and a reach below the grid's cell size names a force the softening has already
  removed. Because the range spans more than an order of magnitude, its slider travel SHALL be
  logarithmic, which the existing requirement on logarithmic curves permits only against this
  positive floor. The maximum SHALL be at or above the world's width, so the unscreened limit — a
  reach the world cannot exhaust — is a reachable slider position rather than an unreachable
  asymptote.
- **Grid size.** The live grid size SHALL be a selector over a declared set of sizes, not a numeric
  range, so a size that is not a power of two or exceeds the allocation ceiling is unrepresentable
  rather than clamped. Every declared size SHALL carry a static assertion that it is a power of two no
  larger than the ceiling and that one line of it fits the workgroup the transform runs it in. The
  default SHALL be the size the measured solve cost selects, and the constant SHALL record that
  measurement beside it under the measured-bound rule.

Each of the three SHALL reach the panel through one `floatParam` or selector in a `long-range`
descriptor group led by the strength, the ordering `fluidStrength` establishes: the strength says how
much of the coupling acts, the two below it say what kind of reach it has.

Enforced by: the static assertions at the bottom of `src/config_ranges.nim`, including the extended
coupling-floor loop (build-asserted); `tests/test_param_descriptor.nim` for the descriptor's presence,
clamp and selector membership (test-held); `tests/test_panel_reachability.nim`, which fails the native
suite for a descriptor the panel places by neither its id nor its group (test-held);
`tests/test_help_content.nim`, whose four relations require a `long-range` help file naming each of
the three ids (test-held).

#### Scenario: The coupling can be turned off

- **WHEN** the user drags the long-range strength to its minimum
- **THEN** the stored value is exactly zero and the frame dispatches none of the chain's passes

#### Scenario: A zero reach is unrepresentable

- **WHEN** input drives the reach to its minimum
- **THEN** the stored value is strictly positive, and the reason lives beside the constant

#### Scenario: Reach travels logarithmically

- **WHEN** the reach slider is dragged from end to end
- **THEN** equal travel anywhere on the slider multiplies the reach by an equal factor

#### Scenario: An undeclared grid size cannot be written

- **WHEN** a write names a grid size outside the declared set
- **THEN** the write lands on a declared size, because the selector admits no other value

#### Scenario: A working bound is marked as one

- **WHEN** the long-range strength ceiling is read
- **THEN** the constant states that it is provisional and names the measurement that would settle it
