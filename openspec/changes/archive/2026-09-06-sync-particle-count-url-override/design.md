## Context

See `proposal.md` - Why for the defect and its evidence. Two mechanisms matter for the decision
below, both confirmed by reading the current source:

`web_api.updateSimulation*` (`src/web_api.nim:165-179`) is exported. It copies `currentSimulation`,
runs the caller's mutation, stores the copy back, mirrors the whole record into CONFIG through
`applySimulationToConfig`, and publishes `worldCouplings.set(couplingsOf(simState))`
(`src/ui/state/sim_config.nim:43-57, 64`). `couplingsOf` reads only `forceStrength`, `fluidStrength`,
`rdDeposit`, and `rdFieldForce` — never `particleCount` — and the field's own comment states that
publishing a value whose zeros are unchanged costs nothing, since `webgpu_compute` compares before
rebuilding a frame (`src/ui/state/sim_config.nim:59-63`). Calling `updateSimulation` for a
particle-count-only mutation before `webgpu_compute.setCouplings` is wired
(`src/app.nim:384-385`, which runs after the `?n=` override at `:328-329`) is therefore provably
inert on couplings: the published value is identical to the one the observable already holds.

`resetParticles` (`src/app.nim:164-165`, exported as `gardenAPI.resetParticles` at
`src/web_api.nim:1291`) is a real reinit path reachable without leaving the running app: the panel
can call it directly, `setSpeciesCountImpl` calls it on every species-count commit
(`src/web_api.nim:398-405`), and `applyPresetImpl`'s `pasParticleCount` step calls it after applying
a preset (`src/web_api.nim:960-973`). `resetParticles` calls `initParticles`, which reads
`config.CONFIG.particleCount` (`src/app.nim:98`). Consequence B in the proposal is reasoned from
this path, not witnessed in a running app, because the measurement runs that surfaced the defect
issued no `setParam` calls of a kind that would trigger a reinit.

## Goals / Non-Goals

**Goals:**
- Make the `?n=<count>` override participate in the single write path
  (`updateSimulation`/`applySimulationToConfig`) so `currentSimulation.particleCount` and
  `CONFIG.particleCount` cannot diverge from the moment the override applies.
- Keep the override's existing external contract: same URL parameter name, same clamp range
  (`1000` to `config.MAX_PARTICLES`), same point in boot order (before `buffers.allocateBuffers()`
  and `initParticles()`, both of which need the final count).

**Non-Goals:**
- Widening this fix to the `?seed=` or `?bloom=` URL overrides. `?seed=` feeds a PRNG, not a
  CONFIG-mirrored state field, so it has no analogous divergence. `?bloom=` already calls
  `web_api.setBloomImpl`, which goes through `updateRender` (`src/app.nim:402-403`), so it already
  follows the single write path and needs no change.
- Adding a compile-time or test gate that catches a future direct CONFIG write from outside
  `updateSimulation`/`updateRender`. CONFIG's mirrored fields are plain exported vars; closing that
  mechanically is a larger change to CONFIG's visibility than this defect calls for, and the spec
  delta names it as an open enforcement gap rather than closing it here.

## Decisions

**Route the override through `web_api.updateSimulation` directly, called once from `app.nim`.**

```
let requestedCount = urlParamInt("n", config.CONFIG.particleCount)
let clampedCount = clamp(requestedCount, 1000, config.MAX_PARTICLES)
web_api.updateSimulation(proc(simState: var SimulationState) =
  simState.particleCount = clampedCount)
```

This replaces the direct `config.CONFIG.particleCount = clampedCount` assignment at
`src/app.nim:328-329`. `updateSimulation` already performs the clamp-adjacent work this call site
needs (store, mirror) with the derived-ceiling pass `applySimulationToConfig` runs on every write
(`src/web_api.nim:135-160`); the override's own `clamp(..., 1000, config.MAX_PARTICLES)` stays, since
it enforces a floor `updateSimulation` does not know about.

Alternatives considered:

- **Write `currentSimulation.particleCount` directly alongside the existing CONFIG write.**
  `currentSimulation` is exported (`src/web_api.nim:81`), so `app.nim` could assign both vars at the
  same call site without calling `updateSimulation`. Rejected: this keeps two separate write
  statements standing for one fact, the exact shape `gardenapi-boundary`'s single-write-path
  requirement exists to prevent elsewhere in the boundary. A later change to
  `applySimulationToConfig` (for example, a new derived ceiling) would silently stop applying to
  this call site, because it bypasses the proc that runs it.
- **Defer the override until after `web_api`'s couplings subscription is wired
  (`src/app.nim:384-385`).** Motivated by an initial concern that `updateSimulation`'s
  `worldCouplings.set` call might need a live subscriber. Rejected once `couplingsOf` was read: the
  four fields it derives from are all unchanged by a particle-count-only mutation, so the publish is
  inert at that point regardless of subscription order (see Context). Deferring the override would
  also move it past `buffers.allocateBuffers()` and the first `initParticles()` call, both of which
  already depend on the final count being set at `:328-329`, so deferring costs reordering work this
  fix does not need.
- **Add a narrow setter (e.g. `web_api.setParticleCountFromUrl*`) instead of calling
  `updateSimulation` directly.** Rejected as unnecessary indirection: `updateSimulation` is already
  exported, already does exactly what this call site needs, and a narrow wrapper would exist only to
  rename an existing call with no added behavior.

## Risks / Trade-offs

[The override now runs `worldCouplings.set` once at boot, before any subscriber exists] → confirmed
inert: `couplingsOf` does not depend on `particleCount`, so the published value equals what the
observable already holds (`initSimulationState()`'s defaults), and `src/ui/state/sim_config.nim:59-63`
documents that a same-valued publish costs a comparison and nothing else once a subscriber does
attach.

[Consequence B (a reinit rebuilding the world at the wrong count) stays unverified by this change
alone] → the fix removes the mechanism (CONFIG and `currentSimulation` can no longer diverge), which
closes the consequence by construction rather than by observing a reinit run correctly; tasks.md
still calls for an agent-checkable run that issues a `setParam` call and then triggers a reinit
(`resetParticles`, a species-count commit, or a preset apply) to confirm the count carried through,
since this path has never been exercised in a running app.

## Migration Plan

None: this is a same-tick behavioral fix to one boot-time code path with no stored data, no schema,
and no preset format involved. No rollback beyond reverting the commit.
