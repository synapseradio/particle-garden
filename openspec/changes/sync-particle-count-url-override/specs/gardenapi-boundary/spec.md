## MODIFIED Requirements

### Requirement: Every parameter write mirrors into CONFIG in the same tick

Every write to a CONFIG field mirrored from `SimulationState` or `RenderState` SHALL pass through
`updateSimulation` or `updateRender` (`src/web_api.nim:165-179`), which write the typed state
record and then call `applySimulationToConfig` / `applyRenderToConfig` (`src/web_api.nim:135-164`)
to mirror it into the flat GPU-facing CONFIG before returning, whatever triggers the write: a panel
call through `gardenAPI`, a preset apply, or a boot-time override read from the URL. The mirror
SHALL NOT be rebuilt on a subscription, a promise, or a microtask: the frame loop reads CONFIG fresh
every frame, so a deferred flush would let a frame render against a stale value. Every `gardenAPI`
method is synchronous for this reason, and so is every other caller of `updateSimulation` /
`updateRender`.

A write that lands on CONFIG through any other route leaves `currentSimulation` or `currentRender`
holding a value CONFIG no longer agrees with, so the next unrelated write through
`updateSimulation` / `updateRender` overwrites the out-of-path value with the stale stored one,
because the mirror always writes every field of the stored record.

Enforcement: review-enforced. The invariant is stated at both ends of the boundary —
`src/web_api.nim:8-16` and `web-ui/src/garden-api.ts:7-9` — and no test or compile-time assertion
checks it, because `web_api.nim` compiles only on the JS backend and no native test imports it
(`src/web_api.nim:29-32`). CONFIG's fields are plain exported vars, so nothing currently stops a new
call site outside `updateSimulation` / `updateRender` from writing one directly; closing that gap
mechanically would need CONFIG's simulation- and render-mirrored fields hidden behind an accessor
only those two procs can reach.

#### Scenario: A write has landed by the time the call returns
- **WHEN** the panel calls `setParam` and the call returns
- **THEN** both the typed state record and CONFIG hold the new value

#### Scenario: The next frame sees the write
- **WHEN** a frame is dispatched after a parameter write
- **THEN** it reads the written value from CONFIG, never the previous one

#### Scenario: A boot-time override survives the next unrelated write
- **WHEN** the `?n=<count>` URL override sets the particle count at boot, and any `setParam` call
  follows before the next reinit
- **THEN** `currentSimulation.particleCount` and `CONFIG.particleCount` both hold the URL-requested
  count, and neither the `setParam` call nor a subsequent reinit changes it back to the boot default
