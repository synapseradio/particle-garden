## ADDED Requirements

### Requirement: The listen affordance crosses as synchronous calls with a pushed outcome

The boundary SHALL expose starting and stopping listening as synchronous calls, and SHALL let no
promise cross into the panel. A start call SHALL leave the affordance in its requesting state before
it returns, and the request's outcome SHALL reach the panel on the metering push. A stop call SHALL
leave the affordance in its disconnected state before it returns, so the panel never renders a claim
of listening the boundary has already ended.

Enforcement: the build. The call signatures are declared in `web-ui/src/garden-api.ts` and checked
by `tsc --noEmit` (`justfile:29-31`), so a promise-typed return or a method the boundary does not
declare fails the typecheck. That the calls return before the browser settles the request is
review-enforced, because this module compiles on the JS backend alone and no native test imports it
(`src/web_api.nim:29-32`).

#### Scenario: The start call returns before permission is answered
- **WHEN** the panel calls the start method
- **THEN** the call returns in the same tick with the affordance reporting its requesting state, and
  returns no promise

#### Scenario: The outcome arrives on the next push
- **WHEN** the user answers the permission prompt
- **THEN** the settled state reaches the panel on the next push, through the metering subscription it
  already holds

#### Scenario: The stop call lands before it returns
- **WHEN** the panel calls the stop method
- **THEN** the call returns with the affordance reporting its disconnected state

### Requirement: The frame loop pushes the listen state and the feature values

The boundary SHALL expose a subscription for audio metering, and the frame loop SHALL push once per
frame while a subscriber is registered and a capture chain is live. A push SHALL carry the affordance
state's name and the six features: five as continuous values inside [0, 1], and onset as the event it
fires, with its energy, in the frame it fires. Meters therefore move on the clock that produces the
values.

With no subscriber registered, the boundary SHALL push nothing and SHALL allocate no sample, the
guard the stats push already holds (`src/web_api.nim:820-821`). While a subscriber is registered and
no capture chain is live, the per-frame push SHALL stand down, and the boundary SHALL push once on
each affordance state change, so a settled request reaches the panel without a poll.

Metering SHALL widen no stats sample. The stats push keeps its own payload and its own 500 ms window
(`src/app.nim:284`), a cadence at which a meter reads as broken.

Every threshold behind the state stays in Nim, the silence window, the band edges, and the
normalization window included. The panel SHALL restate none of them, and the decay of its onset
indicator is presentation carrying no number from the audio path.

Enforcement: the build. The payload is declared in `web-ui/src/garden-api.ts` and checked by
`tsc --noEmit` (`justfile:29-31`), so a field the Nim side stops writing surfaces at the typecheck.
The per-frame cadence and the "restates none" half are review-enforced, because this module compiles
on the JS backend alone (`src/web_api.nim:29-32`).

#### Scenario: A closed section costs nothing
- **WHEN** the audio section is closed, leaving no subscriber registered
- **THEN** the loop pushes nothing and allocates no sample

#### Scenario: Listening off stands the per-frame push down
- **WHEN** the audio section is open and no capture chain is live
- **THEN** no per-frame push runs, and the panel receives one push on each affordance state change

#### Scenario: Meters move with the world
- **WHEN** the audio section is open and a capture chain is live
- **THEN** the panel receives one push per frame, carrying that frame's affordance state and its five
  continuous feature values

#### Scenario: An onset reaches the panel in the frame it fires
- **WHEN** the core fires an onset
- **THEN** that frame's push carries the onset with its energy, and the panel's indicator decays as
  presentation

#### Scenario: The meter shows what the world received
- **WHEN** a frame's push arrives
- **THEN** it carries the same values that frame delivered to the control matrix
