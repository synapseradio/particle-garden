## Order of work

**Group numbers are stable ids, not a sequence.** They are never renumbered, because completed
groups cite each other by number and a renumbering would silently rewrite that history. The order
below is the one authority on what happens next; when it disagrees with the numbering, it wins.

**Group 9 is next.** It was sequenced last so that everything before it could ship as 1.7.x, which
optimised for release convenience over the thing the app is for. One world is the premise (design
D7), not the finale — every group before it was written against a world that still had modes, and
each additional group deepens the amount of mode-shaped code that has to be unwound later.

    9 → the remainder of 6 and 7 → 10 → 11 (validate and stage-sync)
      → C0–C5 (crowding and scale) → E0–E13 (legibility)

**Three number families, none of which renumbers.** Bare numbers are the original groups. `C` numbers
are the crowding and scale work, `E` numbers the legibility work; both were folded in from separate
changes and keep their own numbering under a prefix rather than being renumbered into one sequence.
Renumbering would rewrite every cross-reference the folded sections make to themselves, for no gain —
a prefix separates the families just as well and moves nothing.

**One rule governs every citation, and it admits no inference: a prefix names that family, and no
prefix always names the bare family.** `C3` is crowding's group 3 wherever it appears; a bare
`group 3` is the bare family's group 3 even when written inside the C section. This holds in both
directions and everywhere in the file — design decisions, spec deltas, and task text alike.

The rule was the other way round at first, and it produced a defect worth recording. Each section
declared that its numbers carried an implicit prefix, which is correct for *declaring* a task and
wrong for *citing* one: a citation then resolved against whichever section it happened to sit in, so
`task 5.5` inside the C section pointed at a C5.5 that does not exist while meaning the bare 5.5,
and `group 9` two lines from `group 3` meant a different family with nothing to mark the difference.
Renaming crowding's design decisions from `D` to `C` had already caused the same failure one level
up — the headings moved and the citations pointing at them silently re-aimed at the original
D-family, where `D6` is a decision about reserved headroom rather than about SPH independence.
Both times the artifact stayed valid and a reader following a reference landed somewhere plausible
and wrong. A fourth family would do it again under the old rule; under this one it cannot.

Declaring a task is unchanged: the checkbox lines inside each section stay bare (`- [ ] 1.9` in the
C section is C1.9), so no number moves and no completed record is touched.

Two ordering facts survive the fold and are not merely convention. The `E` family's dormancy work
depends on coupling strengths existing, so it follows group 9. The `C` family's force-weather group
depends on 9.4a having generalised the climate tour into a parameterised loop, and its non-zero
crowding default depends on the matrix recalibration in the `E` family — so that one task waits on
both families rather than on its own.

**Archiving is a manual act the user performs, and no task in this file schedules it.** Archiving
folds this change's deltas into `openspec/specs/`, the specification of what the application actually
does, and that fold is the user's call about when the baseline should start claiming this work.
Finishing the last task here does not authorise it; report that the work is complete and leave the
decision where it belongs.

Between now and whenever that happens the baseline lags deliberately, and `/opsx:sync` closes the gap
a capability at a time under one rule: a capability syncs only when every requirement in its delta is
implemented and verified. Capabilities fed by more than one group wait for their last contributor.

**Group numbers are frozen, and this is why.** Completed records cite each other by number — 1.6's
measured ignition radius is the declared input to 4.1, 8.6's floor tables are cited by the regime
work, 7.6 carries the WGSL lint story. Those measurements exist nowhere else in the repo. Work folded
in later takes new numbers after the existing ones; nothing already written is renumbered, and
completed record text is append-only. Annotate a record that has been overtaken; never rewrite one.

**What this costs in already-completed work, stated rather than discovered.** Group 2 built
`buildFrame(couplings: WorldCouplings)` around three booleans, and pinned one test per combination.
D7 replaces the booleans with continuous strengths, so:

- `WorldCouplings` becomes a strength vector, and `buildFrame` takes it.
- The per-combination pinned tests in `tests/test_sim_registry.nim` become tests over strengths,
  including the zero-strength skip. The *behaviour* they pin is unchanged, which is what makes this
  a rewrite of the tests rather than a loss of their coverage.
- `controlGroupsFor` and its native coverage invariant are deleted rather than ported. The invariant
  they enforced — that a control exists only where a dispatch consumes it — is superseded by one
  world offering every control, always.

That rework is the price of putting the premise last. It is smaller now than after groups 10 and 11
add more to unwind.

## 0. Orientation

- [x] 0.1 Read `CLAUDE.md`, then `docs/research/README.md`, then this change's `design.md`. The
      design decisions D1–D11 are settled; you build and measure, you do not re-research them.
      D7, D8 and D11 supersede the boolean-coupling model the earlier groups were written against —
      where an earlier task says "couplings" meaning three booleans, read it as strengths.
- [x] 0.2 Confirm the toolchain: `just happen` and `just check` both green on a clean tree before
      changing anything. A pre-existing failure is the first task, not a thing to work around.
- [x] 0.3 Check whether `legible-controls` has landed. It is independent of this change and either
      order works, but both add fields to `ParamDescriptor` and both touch `ParamSlider.tsx`. If it
      landed first, every descriptor added here needs a response probe or a written exemption and its
      slider travel is swept — see that change's design E1 and E4 before adding a control.
      **Overtaken by the fold.** `legible-controls` is no longer a separate change; it is the `E`
      family of this one, so the ordering question this task settled no longer exists. The coupling
      it names is still real and now internal: the E family and the bare-numbered groups both extend
      `ParamDescriptor` and both touch `ParamSlider.tsx`. Design E1 and E4 keep their ids.

## 1. Ignition measurement gate (S0)

Leads with tests. Task 1.3 is expected to fail at radius 1 — that failure is the measurement.

- [x] 1.1 `tests/test_field_core.nim`: add `the nontrivial fixed points exist exactly where
      F >= 4*(F+k)^2`, asserting the analytic condition across the feed/kill rectangle. Expected:
      passes immediately; it pins design D2 as an executable fact.
- [x] 1.2 `tests/test_field_core.nim`: add `the shipped defaults sit where only the trivial fixed
      point exists`. Expected: passes; documents why deleting the seed is safe.
- [x] 1.3 `tests/test_field_core.nim`: add `clusteredDepositMask(radius)` beside the existing
      `depositMask()` (line 81), placing the same total coverage as discs rather than a scatter.
      Add `a clustered deposit ignites where a scattered deposit of equal coverage does not`,
      sweeping radius in {1,2,3,5,8} and amplitude across `[RD_DEPOSIT_MIN, RD_DEPOSIT_MAX]`, at
      Pearson defaults and at `(RD_FEED_MIN, RD_KILL_MIN)`. Use both top-hat and Gaussian profiles.
      Judge with the existing `FieldStats` metrics against `ALIVE_THRESHOLD`.
- [x] 1.4 Add `a clustered deposit below the critical radius relaxes to background` — the negative
      control.
- [x] 1.5 Add `ignition completes within N frames at the shipped defaults`; N is the cold-start
      budget for D10.
- [x] 1.6 Record the minimum igniting (radius, amplitude) in a comment beside the new constant. This
      is the declared input to task 4.1. If no radius in the sweep ignites, follow design D3's
      fallback ladder — do not restore automatic seeding, do not move the default climate.
      MEASURED: radius 5 at amplitude 0.02 (Gaussian), igniting on frame 12. No fallback needed —
      recorded at `RD_DEPOSIT_SPLAT_RADIUS` in `src/field_core.nim`.
- [x] 1.7 `just happen` and `just check` green.

## 2. Composable frames (S1)

Tasks 2.1–2.3 must pass **before** any shader edit, and must still pass after — that equivalence is
the regression check for the whole restructure.

- [x] 2.1 `tests/test_sim_registry.nim`: `forces-only couplings produce exactly today's
      particle-life pass list`.
- [x] 2.2 Same file: `sph-only couplings produce exactly today's SPH pass list`.
- [x] 2.3 Same file: `field-only couplings produce exactly today's reaction-diffusion pass list`.
- [x] 2.4 Same file: `every frame clears velocityDelta and densityDelta before any pass that writes
      them`; `forces and field together dispatch the grid build exactly once`; `the field ping-pong
      parity holds for every couplings combination containing field`; `no couplings combination
      dispatches an unknown pipeline key`; `controlGroupsFor unions the groups of active couplings`;
      `couplings with nothing active dispatch only the clears and integrate`.
- [x] 2.5 `src/sim_registry.nim`: add `sbVelocityDelta` to `SimBuffer`; add
      `WorldCouplings = object; forces, sph, field: bool`; change `buildFrame` to take it. Grid triad
      and scatter run iff `forces or sph`; field passes iff `field`; `integrate` always last. Open
      the frame with `clearBufferNode(sbVelocityDelta)` and `clearBufferNode(sbDensityDelta)`.
- [x] 2.6 `src/sim_registry.nim`: delete the stale "would race those atomics" comments at :199-203
      and :237-239. Design D1 records why they are wrong about the mechanism.
- [x] 2.7 `web/shaders/src/forces.wgsl` and `forces-sph.wgsl`: delete the `atomicStore` self-reset
      prologues (forces.wgsl:126-132, forces-sph.wgsl:144-148).
- [x] 2.8 `web/shaders/src/field-force.wgsl`: binding 3 becomes `array<atomic<i32>>`; the plain store
      at :86-89 becomes `atomicAdd`. Update the binding manifest comment and the "sole writer" note.
- [x] 2.9 `src/webgpu_compute.nim`: `byteLengthFor` gains `sbVelocityDelta` — **two i32 per particle,
      not one**. `setActiveSimKind` becomes `setCouplings`.
- [x] 2.10 `src/sim_registry.nim`: keep `SimKind`, `simKindId`, `parseSimKind` as the preset
      compatibility layer mapping legacy ids to couplings triples. Write no migration — design D8
      explains why none is needed.
- [x] 2.11 `just happen` and `just check` green, with 2.1–2.3 still passing unchanged.

## 3. Reserved slots for a future reaction (S1b)

Done here because the bind groups are already open. Implements no second reaction.

- [x] 3.1 `src/gpu_types.nim`: add `ReactionParamsLayout` — `reactionKind`, `kernelRadius`,
      `growthMu`, `growthSigma`, `growthDt`, padded to 32 bytes — with the same compile-time offset
      validation and generated WGSL struct module as every layout. Leave `FieldParamsLayout` at 32
      bytes.
- [x] 3.2 Bind `ReactionParams` to the `rdStep` pipeline; bump its expected bind-group entry count in
      `src/webgpu_compute.nim`; write the buffer each frame with `reactionKind = 0`.
- [x] 3.3 `web/shaders/src/rd-step.wgsl`: promote the `reactionKind` override (:57) to a named
      constant set with `REACTION_GRAY_SCOTT = 0u`, reading from the new uniform. Behaviour must be
      byte-identical for Gray-Scott.
- [x] 3.4 `field-resolve.wgsl:77` and `field-seed.wgsl:101`: preserve the incoming `.b`/`.a` channels
      instead of writing literal `(0.0, 1.0)`. Document them as reserved state channels for a
      multi-channel reaction, noting they are free because the format is `rgba16float` by necessity.
      DONE, WITH TWO CORRECTIONS. `rd-step.wgsl` also wrote the literal and had to be included —
      it clobbers the channels `RD_STEPS_PER_FRAME` times per frame, so preserving in resolve alone
      would have accomplished nothing. `field-seed.wgsl` INITIALIZES rather than preserves: it binds
      its target write-only and has no source to carry from, and it is the deliberate reset action,
      so carrying stale channels across it would be the defect. The literals became the named
      `RESERVED_CHANNEL_B_INITIAL` / `_A_INITIAL`, which is the substance the task protects.
- [x] 3.5 `web/shaders/src/field-deposit.wgsl`: introduce `DEPOSIT_CHANNELS = 1` and index through
      it, so raising the count later is one constant rather than an index audit.
      REVISITED BY THE CLEANUP PASS: the constant never reached the one-place goal — it lived as
      two hand-mirrored copies in field-deposit.wgsl (`i32`) and field-resolve.wgsl (`u32`),
      compiling to `index * 1 + 0`, while the allocation in `webgpu_init.createFieldResources`
      and `byteLengthFor` in `webgpu_compute.nim` counted independently, so editing one copy and
      not the other would corrupt the buffer silently. The identity arithmetic was removed; the
      reservation survives as the header prose in both shaders, which names every site a second
      channel must touch.
- [x] 3.6 `just happen` and `just check` green; the field must look identical to before this group.
      Build and both suites green. The visual identity check is pending the same app run as 4.3 —
      Gray-Scott's math is unchanged (the reaction branch is byte-identical, now selected from a
      uniform instead of a pipeline override), so identity is expected rather than merely hoped for.
- [x] 3.7 Decide the reserved `ReactionParams` members' fate. `kernelRadius`, `growthMu`,
      `growthSigma`, `growthDt` (`src/gpu_types.nim`) are written by nothing, read by nothing,
      and pinned by name in `tests/test_gpu_types.nim`; in `rd-step.wgsl` the
      `REACTION_GRAY_SCOTT` guard has one reachable value, so its fallthrough is dead code.
      Either bring the second reaction close enough to exercise them, or shrink the uniform to
      `{ reactionKind, pad, pad, pad }` (16 bytes) and let a future reaction grow it back — the
      binding and entry counts survive either way, so the choice costs one layout edit plus two
      test names. A cleanup review flagged the members; the reservation was deliberate (3.1–3.4),
      so the call belongs to the user and is recorded here rather than made in passing.
      RESOLVED BY STANDING RULE. The user's ruling "nothing dead ever gets to remain"
      (engineering-principles article 6) closes this fork: proven-dead members are deleted with
      the proof, never parked as a question. `kernelRadius`, `growthMu`, `growthSigma`,
      `growthDt` — written by nothing, read by nothing — are deleted; the uniform shrinks to
      `{ reactionKind, pad0, pad1, pad2 }` (16 bytes). `reactionKind` stays: webgpu_compute
      writes it and rd-step's reaction seam reads it, so it is the live identity slot a second
      reaction branches on. That reaction's parameters grow the struct in the same change that
      reads them. Failing-first: the 16-byte and 4-float pins in test_gpu_types went red against
      the 32-byte struct before the layout change; bindings, entry counts, and the manifest are
      untouched, exactly as this task predicted. reaction_params.wgsl regenerates from the
      layout.

## 4. Ignition from life (S3)

- [x] 4.1 `web/shaders/src/field-deposit.wgsl`: splat each particle's deposit over the radius
      measured in task 1.6, with a falloff kernel, replacing the single-cell `atomicAdd`.
- [x] 4.2 `src/webgpu_compute.nim:156-157`: stop the automatic reseed on couplings entry. Keep
      `field-seed.wgsl` and the Reseed control, relabelled as a deliberate "scatter spores" action.
- [x] 4.3 Run `./main`. The field must ignite from colonies alone within the task 1.5 budget, with no
      seed. If it does not, apply design D3's ladder in order.
      VERIFIED, no fallback needed. Two independent warrants: the user confirms the field patterns in
      the app, and `grep` confirms the ONLY call path to `requestFieldSeed` is the Scatter Spores
      button callback (`app.nim:351`) — nothing seeds on couplings entry or on reset, which is the
      spec's actual requirement. The settled pattern looks unchanged from the seeded version, which
      is EXPECTED rather than suspicious: at the same feed/kill both routes converge on the same
      Gray-Scott attractor, and the difference lives in the first half-second, not the steady state.
      A colony-SHAPED pattern is not observable until group 9 makes forces+field reachable from the
      panel; this mode still runs no forces pass, so coverage stays near-uniform.
      Prior detail: Shipped kernel: radius 5, Gaussian, normalization 34.198987,
      substituted from `field_core` via `shader_config`. Native sweep says ignition on frame 12 at
      the default deposit under UNIFORM particle coverage, which is a lower bound — real colonies
      concentrate deposits well above that mask. Also covers the 3.6 visual identity check.
- [x] 4.4 `just happen` and `just check` green.

## 5. Species chemistry (S4)

- [x] 5.1 `src/gpu_types.nim`: `SpeciesChemistryLayout` — `MAX_SPECIES` × (secretion, tropism) f32,
      padded to 64 bytes, standard compile-time offset validation.
      DEVIATION (packing, not size): stored as two parallel `array<vec4<f32>, 2>` channels rather
      than `MAX_SPECIES` interleaved pairs. WGSL's uniform address space rounds an array element's
      stride up to 16 bytes, so `array<vec2<f32>, 6>` would occupy 96 bytes and blow the 64-byte
      budget; four species per vec4 gives eight slots per channel in exactly 32 bytes each. Total is
      64 bytes as specified. `CHEMISTRY_SPECIES_SLOTS = 8` with a static assertion that
      `MAX_SPECIES` fits, so a raise past 8 fails the build rather than dropping a species.
- [x] 5.2 Bind to `fieldDeposit` and `fieldForce`; bump `EXPECTED_BIND_GROUP_ENTRIES_FIELD_DEPOSIT`
      and `..._FIELD_FORCE` (`src/webgpu_compute.nim:69,72`).
      4 -> 5 and 5 -> 6. One `uniformBuffers["speciesChemistry"]` serves both passes, written each
      frame beside `fieldParams` under the same `if activeCouplings.field:` guard.
- [x] 5.3 `field-deposit.wgsl`: deposit `depositAmount * secretion[species]`, signed.
      `field-force.wgsl`: force becomes `-gradient * fieldForceScale * tropism[species]`.
      DEVIATION (sign): the force is `+gradient * fieldForceScale * tropism[species]`, dropping this
      task's minus sign. The task's literal formula makes POSITIVE tropism move a particle DOWN the
      gradient, which contradicts three settled artifacts at once: the species-chemistry spec's
      "Tropism steers" scenario ("accelerate down the field gradient [when negative], and up it when
      positive"), design D5 ("Positive tropism is agents climbing their own deposited gradient"),
      and the asymmetric range itself — under the task's sign, reproducing today's down-gradient
      behavior would need tropism `+1.0`, which `TROPISM_MAX = +0.5` puts out of range and the
      default-in-range assertion would reject. The specs are consistent with each other and the task
      text is the outlier, so the specs win. `RD_DEFAULT_TROPISM = -1.0` therefore reproduces the
      pre-chemistry force exactly. `tests/test_field_core.nim` pins the convention directly
      ("negative tropism descends the gradient and positive climbs it") so it cannot be re-inverted
      silently. The `atomicAdd` accumulation from task 2.8 is untouched.
- [x] 5.4 `src/config_ranges.nim`: `SECRETION_MIN/MAX = -1.0/+1.0`, `TROPISM_MIN/MAX = -1.0/+0.5`
      per design D5, with the standard non-empty and default-in-range static assertions.
      Plus `TROPISM_MAX < -TROPISM_MIN`, so a later tidy-up to a symmetric range fails the build.
      Defaults live in `field_core.nim` beside `RD_DEFAULT_DEPOSIT`: `RD_DEFAULT_SECRETION = 1.0`,
      `RD_DEFAULT_TROPISM = -1.0`.
- [x] 5.5 `tests/`: add `positive tropism at its bound does not produce unbounded aggregation over N
      steps` and `the configured tropism bound sits below the measured collapse point`. If either
      fails, halve `TROPISM_MAX` and record the measured collapse value beside the constant.
      BOTH TESTS SHIPPED UNDER THEIR GIVEN NAMES AND BOTH PASS. `TROPISM_MAX` was NOT halved —
      neither test failed.
      MEASURED COLLAPSE POINT: **tropism 4.0, eight times the bound**, at deposit 0.8 (10x
      `RD_DEPOSIT_MAX`) and `fieldForceScale` 150. There the field diverges to infinity and the
      population ends in a single field cell. At the same deposit and field force the shipped bound
      stays finite (maxB 0.886), bracketing the collapse point in (1x, 8x] of 0.5.
      THE COLLAPSE IS CHEMOTACTIC, established by control rather than asserted: the same 0.8 deposit
      laid down by a FROZEN population stays finite (maxB 0.856), so the divergence belongs to the
      up-gradient motion concentrating the deposit, not to the deposit amplitude. Concentration is
      the variable.
      CORRECTION TO AN EARLIER READING RECORDED HERE: a first, narrower sweep varied tropism alone at
      the deposit ceiling, found nothing divergent up to 1024x the bound, and concluded no collapse
      point existed. That was wrong. Collapse lives in the PRODUCT of tropism and deposit, so a scan
      holding the deposit at its ceiling cannot find it however far tropism is pushed. Widening the
      deposit axis located the boundary immediately.
      SCOPE OF THE BOUND, WORTH CARRYING INTO GROUP 8: inside the deposit range the slider actually
      offers, NO tropism collapses the field — 1024x the bound stays finite and bounded. It is
      `RD_DEPOSIT_MAX` that keeps the reachable range safe, and `TROPISM_MAX` is the second line of
      defence. Because the two multiply, **any later rise in `RD_DEPOSIT_MAX` spends the tropism
      margin too** and this suite must be re-run against it.
      A mechanism note also lands beside the constant: Gray-Scott's `(feed+kill)*B` sink saturates
      the field against deposit AMPLITUDE (uniform 1x and 10x land within 0.1 of each other) but NOT
      against CONCENTRATION, so "Gray-Scott bounds its own inhibitor, therefore no collapse is
      possible" is a tempting inference that the measurement refutes.
      Harness: extends `test_field_core.nim`'s existing one (`advanceFrame`, `flatSeed`,
      `depositSplatWeight`) with moving particles, mirroring `field-force.wgsl`'s gradient sample and
      `integrate.wgsl`'s friction, soft velocity cap and wrap. It runs in world pixels at the shipped
      pixels-per-cell (FIELD_W across a 1920 px reference width), because how many pixels a cell
      spans decides how far a given `fieldForceScale` carries a particle. Divergent runs exit at the
      frame the field goes infinite, which is what keeps them affordable. Aggregation is measured
      against a FROZEN control, not against the uniform ideal: 256 particles in 64 tiles already put
      twice the uniform share in the fullest tile by sampling alone, and asserting against 1/64 would
      read that noise as chemotaxis. Cost: +2 s on a ~4 s suite.
      SIDE FINDING, its own test: up-gradient motion NUCLEATES the field where a scattered deposit
      cannot (frozen maxB 0.015, down-gradient 0.013, up-gradient 0.793) — chemotaxis manufactures
      the spatial coherence ignition needs out of a uniform scatter. This harness runs no
      inter-particle forces, so it says nothing against task 4.1: in a world coupling forces with the
      field, particle-life colonies supply that coherence, which is the path 4.1 measured. The
      shipped default tropism is negative, so the field ignites from COLONIES, never from chemistry
      alone.
- [x] 5.6 `web-ui/src/`: chemistry editor beside the attraction matrix, following
      `matrix_state.nim`'s patterns.
      `ChemistryEditor.tsx`, one row per active species and one column per chemistry field, gated on
      the same `rd` group the other field controls use. Same live-Float32Array contract as
      `MatrixEditor`: read by reference, write the clamped value straight back, bump a version
      signal. Nim serves the columns through a new `gardenAPI.chemistryFields()` table
      (`param_descriptor.nim`'s `ChemistryField`) carrying label, slot, range, step, precision,
      default and hint, so no range, step or stride appears as a TypeScript literal.
      OUT OF SCOPE AND NOT DONE — RAISED FOR A DECISION: **chemistry is not in the preset schema.**
      `exportPresetJson` snapshots CONFIG, the matrix and the palette, so a saved preset does not
      carry secretion or tropism and a load leaves them at whatever the session had. No task in
      group 5 asks for it, and adding a field to `preset.nim` is a schema change that group 9 owns
      (D8 governs preset compatibility). Left untouched deliberately rather than invented here.
- [x] 5.7 `just happen` and `just check` green.
      545 native tests, 34 TypeScript tests, 0 failures.
- [x] 5.8 Floor the inhibitor at zero where deposits fold in. `field-resolve.wgsl` adds the
      signed deposit sum to `.g` with no floor, so stacked negative secretion drives the channel
      below Gray-Scott's domain. Measured with an offline oracle at shipped constants
      (the session's scratchpad `math_verify.py`): twenty max-deposit eroders on one empty cell
      reach B = −0.047 in a single frame, one hundred reach −0.23 — and the reaction term A·B²
      erases the sign, so a cell at B = −0.15 burns 5% of its activator in one frame. Erosion
      past zero thereby acts on the activator like the structure it was supposed to remove.
      Fix: `max(0.0, current.y + depositB)` in field-resolve.wgsl, the same floor in whatever
      native code mirrors the resolve fold (grep `field_core` for the oracle), and a test:
      `the inhibitor never goes negative however many eroders stack on one cell`.
      DONE (commit ef9f112, delegated, lead-verified). The floor is exactly the prescribed
      `max(0.0, current.y + depositB)` with the cap logic byte-identical; the mirror
      `field_core.resolveCellDeposit` applies cap → fold → floor in the same order, lockstep
      named at the shader site. The test was WATCHED FAILING first at −0.0468 (20 eroders) and
      −0.2339 (100) — reproducing this task's offline measurement to three decimals from the
      independent native harness — then green after the floor. 657 native checks, both suites
      green in the implementing worktree; re-verified on main after integration.
- [x] 5.9 Fold `ChemistryField` into the descriptor table. One parameter-metadata contract
      currently has two record shapes, two clamps, two Nim→JS serializers, and two TS
      interfaces (`param_descriptor.nim`'s `ChemistryField`; `web_api.nim`'s
      `chemistryFieldArray`/`clampChemistryImpl`; `garden-api.ts`'s `ChemistryField`;
      `ChemistryEditor.tsx` re-implementing bind/format/clamp) — and the gap is already
      observable: descriptors grew `notches` in group 8 and chemistry fields silently have
      none, while `tests/test_param_descriptor.nim`'s suites cover only descriptors. Give
      `ParamDescriptor` a cardinality (a per-species arity plus `slot` member) instead of a
      parallel type: one table, one clamp, one serializer, one test surface, with the panel
      branching on the member to render a grid row rather than a slider. Three cleanup
      reviewers converged on this independently; it changes the gardenAPI contract, so it is a
      task of its own rather than a cleanup-pass edit.
      DONE, delegate-built, lead-integrated. `ParamDescriptor` is an object variant on a new
      `ParamArity` (`paScalar`/`paPerSpecies`, the latter carrying `slot` — in the branch
      because slot 0 is secretion's real slot, so a flat default-0 would alias it); secretion
      and tropism join the one table under group `chemistry` with a `psSpeciesChemistry`
      store. Deleted: the `ChemistryField` record and its builder, `chemistryFieldArray`,
      `clampChemistryImpl`, `clampChemistryValue`, the TS `ChemistryField` interface, and the
      `chemistryFields`/`clampChemistry` API members; the surface gained `clampParam(id,
      value)` and TS narrows a discriminated union before any `slot` read. Staged reds:
      compile-red on the missing store, five runtime reds on the coverage/range/default/
      column suites, one TS red pinning that `getParam` cannot serve a per-species column.
      TASK-TEXT CORRECTION from the delegate: the editor never re-implemented clamp or
      format — it routed clamp through the API and format through shared `formatParamValue`;
      what it owned was the binding. The two clamps lived in Nim. Everything else in the
      finding verified true. NOTCHES: deliberately none — the columns render as grid cells
      with no track to mark; the chemistry columns are now inside the notch/hint/range
      coherence sweeps, so a future notch is auto-checked the moment a renderer gives it a
      track. Chemistry remains outside the preset schema (5.6's open decision, now cheaper:
      iterate descriptors, branch on the store). Verified on main after cherry-pick: survivor
      grep returns nothing; full gate runs once after 8.11 integrates.

## 6. Field as light (S5)

- [x] 6.1 `tests/`: `field coverage is zero where field intensity is zero` and `field coverage rises
      monotonically with intensity and saturates at one`. The first fails today — that is the bug.
      DONE, in `tests/test_colormap_core.nim` under both given names, against new
      `fieldIntensity`/`fieldCoverage` oracles in `colormap_core.nim`. NOTE ON "FAILS TODAY": the
      bug is in the SHADER (`fieldCoverage = 1.0` inside `if fieldOpacity > 0.0`), which no native
      test can execute — so these tests pin the correct behaviour and the shader moved to match,
      rather than going red first. Saturation is asserted at `FIELD_OPACITY_MAX`, since coverage
      scales by opacity and cannot reach one below it.
- [x] 6.2 `web/shaders/src/render.wgsl`: bind the field texture, sample at the particle's world
      position, modulate `output.color` toward the colormapped field value.
      DONE. Binding 3 is the field, read in the VERTEX stage — the only stage that can light a
      particle by the field it stands in, since the composite stages see the field per screen pixel
      only after particles are coloured. `textureLoad` not `textureSample` (no derivatives in the
      vertex stage), at the particle's own `p.pos` rather than the quad corner, so all six vertices
      agree and the quad is lit as one thing. Pull is `intensity * fieldOpacity *
      FIELD_LIGHT_STRENGTH`, so a particle in a dark region keeps its species colour exactly.
      Three structural notes: `RenderParams` gained `fieldOpacity`/`colormapIndex` by spending two
      of its three existing pads, so the uniform did not grow; the glow bind group needed its own
      entry list, because glow.wgsl declares three bindings and an extra entry is a validation
      error; and the render bind group is now generation-cached like the composite one, plus
      invalidated in `createBloomTargets` because its pre-field placeholder view is a bloom target
      that resize destroys.
- [x] 6.3 `tonemap.wgsl:60-66,77`: `fieldCoverage` follows field luminance instead of `1.0`.
      `field-composite.wgsl:56`: alpha follows intensity. Keep both paths in tonal parity — that
      parity is the file's stated reason for existing.
      DONE. Both paths now call the one shared `colormapFieldCoverage`; `tonemap.wgsl`'s flat 1.0
      and `field-composite.wgsl`'s flat alpha 1.0 are both gone. The `if (fieldOpacity > 0.0)` guard
      around the tonemap's field sample went with them — at opacity 0 both the light and the
      coverage terms are already 0, so the branch was doing nothing the arithmetic did not.
      DEVIATION, MEASURED: coverage follows field INTENSITY (the scalar driving the ramp), not ramp
      LUMINANCE as worded here. Taking "luminance" literally contradicts task 6.1's "field coverage
      is zero where field intensity is zero" for two of the three shipped ramps, because their
      zero-field colour is not black. Measured `evalColormap(index, 0.0, 0.0)` luminance, Rec.709
      weights, the same `luminance()` `tonemap_grade.wgsl:13` uses:
        inferno  0.00123  -> 0.10% coverage at the 0.85 default opacity
        viridis  0.08703  -> 7.40% coverage  (its zero is dark purple, not black)
        two-tone 0.0      -> 0%
      Following luminance would therefore paint 7.4% purple over an EMPTY field under viridis, and
      would make the ramp choice decide what is opaque — a display decision silently changing
      coverage. Intensity-driven coverage is exactly zero at zero field for all three ramps, rises
      monotonically, and saturates at one, satisfying 6.1 as written. Both paths still call the one
      shared function, so 6.3's actual requirement — tonal parity between the bloom-on and bloom-off
      paths — is preserved, which is the substance the task protects.
- [x] 6.4 `fade.wgsl`: displace the trail sample by the field gradient, small scale, one new uniform.
      DONE. The uniform is `fieldDriftScale`, spending `FadeParams`' first pad (no growth), fed from
      the new `FIELD_DRIFT_SCALE` in `colormap_core.nim` and gated to 0 without a field, so a
      forces-only world fades byte-identically. Gradient read wraps, matching the field's topology.
      The two identical inline fade-bind-group blocks became one `createFadeBindGroups`, because the
      field binding would otherwise have had to be added and kept in step in three places.
- [x] 6.5 Revisit `fieldOpacity`'s 0.85 default (`colormap_core.nim:53`) now the field is light.
      RAISED TO 1.0. The 0.85 was compensating for a field that claimed every pixel whether or not
      field was there — holding it under 1 was the only way to see particles through what was
      effectively an opaque sheet. `fieldCoverage` now does that proportionally, so keeping the
      dimming too would pay for the same problem twice: darkening the pattern cores while still
      never letting them be fully present. Net effect makes particles MORE visible, not less — the
      field reaches full coverage only at full intensity (the bright cores) and contributes nothing
      across the dark majority of the frame that previously sat at 85%. Still a BLIND VISUAL PICK,
      reasoned rather than seen; flagged for the user's visual pass with 6.6.
- [ ] 6.6 Verify in the app; `just happen` and `just check` green.
      BUILD AND BOTH SUITES GREEN. The in-app visual check is the outstanding half, and it is the
      one part of this group that cannot be settled from the native side: three of this group's
      numbers (`FIELD_LIGHT_STRENGTH` 0.55, `FIELD_DRIFT_SCALE` 0.02, `FIELD_OPACITY_DEFAULT` 1.0)
      are blind picks that only a display can judge.
- [x] 6.7 Fix the fade drift's field wrap, then make the field's edge behaviour single-source.
      `fade.wgsl`'s `fadeFieldInhibitor` wraps with `(cell + FADE_FIELD_DIMS) % FADE_FIELD_DIMS`,
      which under WGSL's truncating `%` survives only one span of negativity — and below zoom 0.5
      the screen legitimately reaches world positions past −1 span, where the gradient taps call
      `textureLoad` at negative indices (measured, session scratchpad `math_verify.py`: zoom 0.25
      reaches cell −1025 → wrapped −1; 21 out-of-range probes across the reachable corners; an
      out-of-bounds `textureLoad` returns an indeterminate value). `((cell % DIMS) + DIMS) % DIMS`
      closes it. The same expression stays safe in rd-step.wgsl and field-force.wgsl only because
      their coordinates sit at most ±1 off a valid cell — verified separately. The deeper finding:
      the field's dims, wrap, world→cell mapping, and gradient stencil now exist in five shaders
      under three spellings (`FIELD_W`/`FIELD_H` scalars, `FIELD_DIMS`, `FADE_FIELD_DIMS` +
      `FIELD_LIGHT_DIMS`). Hoist a `web/shaders/modules/field_grid.wgsl` (dims, `fieldWrap`,
      `fieldCellFor`, the central-difference gradient) and import it from fade, render, rd-step,
      field-force, and field-deposit, so the edge decision is made once. `cell_index.wgsl` is the
      precedent for a shared hand-written module.
      RESCOPED BY DESIGN D15: at zoom floor 1.0 every reachable coordinate sits within one span of
      a valid cell, so the out-of-range `textureLoad` this task opens with is no longer reachable
      and the double-mod fix lands as hardening. The five-shader spelling divergence and the
      `field_grid.wgsl` hoist remain the task's substance.
      DONE. Failing-first oracle `field_core.fieldWrap` (floor-mod) with suite "Field Grid Wrap"
      pinning spans beyond −dims, where single-mod yields −1; the harness's test-local `wrapCell`
      duplicate collapsed into it. `web/shaders/modules/field_grid.wgsl` now carries `FIELD_DIMS`
      (+ a u32 spelling), `fieldWrap`, `fieldCellFor`, `fieldCellIndex`, `fieldInhibitorAt`, and
      `fieldInhibitorGradient`. COUNT CORRECTION: seven importers, not five — `field-resolve` and
      `field-seed` also spelled the dims as u32 scalars and now import the module. The
      deposit↔resolve addressing agreement is structural (both call `fieldCellIndex`) instead of
      a cross-file comment, and the fade/field-force gradient stencils collapsed into one
      function. fade's floor-not-clamp cell mapping stays local by design: reprojection
      legitimately leaves the world rect and must wrap, not clamp. Build green, 675 native tests
      green; web-ui untouched, so its suite was not in this change's scope.

## 7. Camera, zoom, navigation (S6)

Extract the maths into a pure module first — none of it needs a GPU, and that is where the tests go.

- [x] 7.1 `src/camera_core.nim` (new, pure) + `tests/test_camera_core.nim`: `the nearest toroidal
      image of a point across the seam is the short way round`; `zoom 1.0 centred on the world middle
      reproduces today's clip mapping exactly`; **`panning by exactly one world width returns an
      identical view`**; `particle size, trail length, and glow radius scale by the same factor at
      every zoom`; `zoom clamps to its configured range`; `the size floor keeps particles visible at
      minimum zoom`. Register the module in `tests/test_all.nim` with its marker constant and add it
      to `tests/README.md`'s table and tree.
- [x] 7.2 `src/gpu_types.nim`: `CameraLayout` — `centerX`, `centerY`, `zoom`, pad — standard
      validation, written every frame.
      DONE. Its own 16-byte uniform rather than more `RenderParams` fields: that struct had one pad
      left and this needs three slots, and glow.wgsl needs the camera without the rest of
      RenderParams. Generated into `web/shaders/modules/camera.wgsl` by the bundler like every other
      layout, with the same offset-drift assertions.
- [x] 7.3 `render.wgsl:134-140` and `glow.wgsl`: transform through the camera; draw each particle at
      its nearest toroidal image relative to the camera centre, reusing the `wrapDelta` logic
      `physics_core.nim:133-251` defines and `forces.wgsl:353-357` mirrors.
      DONE, via a new `camera_transform` WGSL module both shaders import, so they cannot disagree
      about where a particle is — a disagreement would detach a glow from its particle across the
      world. ONE CORRECTION TO THE OBVIOUS IMPLEMENTATION: the nearest image is chosen from the
      particle CENTRE and the quad-corner offset added afterwards, through a separate
      `cameraOffsetToClip`. Wrapping the already-offset corner (the direct reading of "draw each
      particle at its nearest image") tears a quad in half whenever its particle sits near the
      half-world line, because different corners then wrap differently.

      **RUNTIME-ONLY HAZARD FOUND HERE, worth reading before touching the render path.** render.wgsl
      and glow.wgsl SHARE one explicit bind group layout (`webgpu_render.nim` builds it once and
      both pipelines use it): 0 particles, 1 renderParams, 2 colors, 3 field texture, 4 camera.
      Nothing checks the layout, the bind-group entries, and the two shaders' `@binding` numbers
      against each other at Nim compile time — `just happen` and `just check` both pass while the
      app fails validation in the browser. Two real defects came from this today: task 6.2 added a
      field binding to the shader and the bind group but not to the layout, and glow.wgsl first
      declared the camera at binding 3, colliding with render.wgsl's field texture. Both were found
      by reading, not by a test. A native guard over the bundled WGSL's `@binding` declarations
      would have caught both; it is not built, and it is flagged for the user rather than added
      unilaterally.
- [x] 7.4 Scale particle size, trail length, and glow radius by the world scale with a floor, per
      design D9. All three move together or none does.
      DONE, but NOT by multiplying the three by `apparentScale` — that would square the effect. A
      quad corner is built in pixels, divided into world units, then multiplied by zoom again inside
      the clip transform, so its screen size already tracks zoom unaided. What the floor has to
      change is only the RATIO between raw zoom and the floored scale, which is
      `cameraSizeCorrection`: exactly 1.0 everywhere above the floor, rising below it. All three
      quantities reach clip space through one offset in each shader, so one factor moves them
      together by construction rather than by three call sites agreeing.
- [x] 7.5 `src/webgpu_render.nim:390-394` and the field sampler at `src/webgpu_init.nim:204`: set
      `addressModeU/V = "repeat"`.
- [x] 7.6 `fade.wgsl`: reproject the trail by the frame's camera delta in UV. `tonemap.wgsl` and
      `field-composite.wgsl`: map screen UV through the camera into field space.
      DONE, but NOT "by the camera delta in UV" as worded — that is only exact while the zoom is
      unchanged. A camera delta is a translation; a zoom is a scale about a point, so a single UV
      offset would smear precisely when the user is moving fastest, which is the artifact 7.10 says
      to look for. The fade pass instead carries BOTH cameras and asks where each world point sat on
      the previous frame's screen, which is exact for pan and zoom together. `FadeParams` grew
      16 -> 32 bytes to hold the previous camera plus the world extent; `TonemapParams` grew
      32 -> 48 for the world extent alone.
      The camera is NOT duplicated into either uniform — all five passes (render, glow, fade,
      tonemap, field-composite) bind the one shared camera buffer, because they must agree about the
      view WITHIN a frame and five copies is five chances to disagree.
      `previousCamera` is recorded after the submit, not before, so a camera move arriving between
      frames is reprojected across rather than silently absorbed; it is seeded equal to the live
      camera at init so the first frame's reprojection is an identity rather than a jump from an
      uninitialized zero-zoom camera.
      Two things fall out. The fade pass's field-gradient lookup now derives its cell from the WORLD
      position rather than the screen UV, so a panned view reads the same field cell for the same
      world point. And a binding audit across all five shaders confirms layout/entry/`@binding`
      agreement: render 0-4 against a 5-entry shared layout, glow legally skipping 3 on that same
      layout, fade 5/5, tonemap 6/6, field-composite 4/4. That audit is manual because nothing
      checks it — see 7.3's note.
      GAP CLOSED AFTERWARDS: `screenUvToWorld`/`worldToScreenUv` were the only part of
      `camera_transform.wgsl` with no Nim mirror and no test, which left the reprojection — the
      single most likely thing here to be visually wrong — the single least verified. Both now live
      in `camera_core.nim` with six tests, and two of them state the DESIGN rather than the code:
      panning shifts the reprojection by a constant across the whole screen, and zooming does not.
      That pair is what makes the two-camera approach necessary rather than merely chosen, and the
      zoom test fails if anyone later "simplifies" it back to a single UV delta. A third records the
      corollary — the view CENTRE is the one pixel a delta approximation would have got right, which
      is why that error would have been invisible in the middle of the screen and worst at the edges.
      DEFECT FOUND BY RUNNING THE APP, AND THE AUDIT ABOVE MISSED IT. The reprojection built its
      previous-frame Camera with NAMED FIELDS — `Camera(centerX: ..., zoom: ...)` — which WGSL does
      not have; constructors there are positional only. The habit comes from this codebase
      specifically: the struct is generated from a Nim object where that syntax is correct. A WGSL
      parse error does not degrade one pass, it invalidates the pipeline and the frame using it is
      never submitted, so the window went BLACK for everything whenever Trails was on. Nothing
      Nim-side saw it — the browser is the WGSL compiler, so `just happen` and `just check` were both
      green over a broken app. The manual binding audit above checked binding NUMBERS and never
      re-read the shader bodies, which is exactly the gap.
      Fixed positionally, and the class is now a build failure rather than a run-time one:
      `src/wgsl_lint.nim` (pure, 11 native tests) is called by `tools/wgsl_bundle.nim` and quits the
      build naming the shader and line. One of its tests reads `web/shaders/src` and `modules/`
      directly, so a shader added later is covered without anyone remembering to add a case, and a
      second asserts the directory was found so the first cannot pass vacuously. The checker is
      deliberately narrow — it only flags callees starting with an uppercase letter, because every
      struct type here is PascalCase and every WGSL builtin is lowerCamel, and a false positive would
      block every build. Its known blind spot (a constructor whose fields start on the line after the
      callee) is recorded as a test rather than left to be rediscovered.
- [x] 7.6a TILING BELOW ZOOM 1 — task added after running the app; no task asked for this, and its
      absence made the camera read as broken. `CAMERA_ZOOM_MIN`'s own comment promised the world
      TILES below zoom 1, and half of that shipped: the field composites with repeat addressing and
      does tile, while particles were drawn once each at their nearest toroidal image. Nearest-image
      drawing is exactly correct for one world span and leaves black beyond it, so zooming out framed
      the simulation in a black margin — reported as "the sim should always extend to the borders of
      the window", and correctly so.
      `camera_core.tileRing/tileCount/tileOffsetSteps` (mirrored in `camera_transform.wgsl`) size a
      ring of world copies from the zoom, and the three particle draws in `webgpu_render.nim` ask for
      `tileCount` instances instead of 1. The shaders place each instance from `@builtin(instance_index)`,
      adding the displacement to the QUAD OFFSET rather than to the position, so the nearest-image
      choice is not undone. `render.wgsl` and `glow.wgsl` changed identically — a glow tile without a
      particle tile is the failure this pairing prevents.
      The relation is what is tested, not a table: a view at zoom z reaches 1/(2z) worlds from its
      centre and a ring of r covers r + 0.5, so both directions are pinned — enough to reach the
      window edge, and never one ring more than that. Cost is 1 instance at zoom 1 and closer, where
      the app spends nearly all its time, rising to 25 at `CAMERA_ZOOM_MIN`; that bound is asserted
      because it is the number deciding whether zooming out is affordable at all.
      OVERTAKEN BY USER DECISION, recorded at design D15 and task 7.15: tiling below zoom 1 was
      never intended — the comment this task honored promised something the user never asked for.
      The machinery this record describes is deleted and the zoom floor rises to 1.0. The
      nearest-image drawing this task preserved is exactly what survives.
- [x] 7.7 `src/ui/input/wheel_handler.nim` and `key_handler.nim` (new, pure) with native tests, plus
      listeners in `src/canvas_input.nim`. Reuse the unused `KeyboardEvent` `addEventListener`
      overload at `bindings/dom_extensions.nim:89`. Bindings: wheel zooms at the cursor, arrows pan,
      `+`/`-` zoom, `0` resets.
      DONE. Both pure modules plus `tests/test_camera_input.nim` (18 tests, green), registered in
      `test_all.nim`, and the DOM listeners in `canvas_input.nim`.
      `WheelEvent` had to be added to `bindings/dom_extensions.nim` — `std/dom` has no such type at
      all, so the existing `KeyboardEvent` overload the task points at had no wheel counterpart.
      Two wiring decisions. The camera lives in `webgpu_render.nim`, which is a layer ABOVE
      `canvas_input.nim` in `app.nim`'s import order, so it cannot be read from there — the handlers
      reach it through `cameraGetter`/`cameraSetter` hooks that `app.nim` wires, exactly as it
      already wires `onResize`. Both nil-check, so input arriving before the render pipeline
      initializes is ignored rather than crashing. And keydown listens on the WINDOW, not the
      canvas: a canvas receives key events only when focused, and this one is never deliberately
      clicked into, so canvas-scoped bindings would appear dead until the user happened to click the
      world first. `preventDefault` fires only once a key is known to be a camera binding, so
      ordinary typing in the panel is untouched.
      Two decisions worth keeping: the wheel's zoom rate is EXPONENTIAL in the delta so the factor
      composes — two half-scrolls multiply to exactly one whole scroll, where an additive rate would
      make fast scrolling land somewhere different from slow scrolling over the same distance, and a
      test asserts that. And zoom is clamped BEFORE anchoring, not after: `zoomedAt` moves the centre
      by exactly the amount that holds the anchor still at the zoom it is handed, so clamping
      afterwards would move the centre for a zoom that never happened and let the anchor drift at
      both ends of the range — precisely where a user pushes hardest.
      One asymmetry recorded deliberately: the wheel anchors at the CURSOR, the `+`/`-` keys anchor
      at the view CENTRE. A keyboard has no cursor position to zoom toward.
- [x] 7.8 Close the touch gaps: two-finger tap fires a blast; register the `handleTouchCancel`
      listener (`touch_handler.nim:59-62`) that currently has none.
      DONE. The missing `touchcancel` listener was a live bug, not just an untidy loose end: an
      interrupted touch (incoming call, system gesture) left the press stuck down forever, because
      the only paths clearing it were touchend and touchmove, neither of which fires on a cancel.
      `handleTwoFingerTap` blasts at the two touches' MIDPOINT rather than at either one — a blast
      at one of the two sits off to the side of the gesture, and which side would depend on the
      undefined order the browser reports touches in. Five tests in `tests/test_input.nim`, one of
      them asserting the midpoint is order-independent rather than only documenting it.
- [x] 7.9 `src/config_ranges.nim`: `CAMERA_ZOOM_MIN = 0.25`, `CAMERA_ZOOM_MAX = 8.0`, with static
      assertions. Add a "Drift" toggle for slow autonomous camera motion, off by default.
      RANGE DONE, with an extra static assertion the task did not ask for: the range must CONTAIN
      1.0, because that is the framing the renderer had before a camera existed — a range excluding
      it would make the default view unreachable.
      DESCRIPTOR DONE, and it needed a fourth `ParamStore`. `psCamera` writes the live view and
      never CONFIG, which is what keeps the camera out of the preset schema: a preset restores a
      world, and should not also seize where the user is standing to look at it. Two tests hold that
      boundary, the second stating it as its own claim — `psCamera` routing must name exactly
      `cameraZoom`, so a second parameter escaping into view-state cannot widen the hole silently.
      Wired through `canvas_input`'s existing camera hooks rather than a second pair, so the slider
      and the wheel cannot end up pointed at different cameras. The slider anchors at the view
      CENTRE like the `+`/`-` keys, since a slider has no cursor to zoom toward.
      The existing hint-reachability test caught a real defect in my first draft: the hint read
      "press 0 to return", and the test correctly read that `0` as a slider position below the 0.25
      minimum. It is a KEY, not a value; the hint no longer spells it as a numeral.
      CORRECTION, FOUND IN GROUP 9. "The slider anchors at the view CENTRE" describes the write path
      only. `setParam("cameraZoom")` and `getParam("cameraZoom")` were both wired, and no slider
      ever reached the screen: `Panel.tsx` places a control by naming its id or by looping
      `groupIds(group)`, and it did neither for the `camera` group. Zoom was reachable by the wheel
      and the `0` key alone, and the three notches — tiled, world, creature — by nothing at all,
      which is the part a gesture cannot offer.
      A descriptor is a promise that a control exists, and nothing checked the promise, so
      `tests/test_panel_reachability.nim` now reads `Panel.tsx` and fails on any descriptor the
      panel places by neither route. It found exactly one offender. A third test feeds it an id and
      a group the panel cannot contain, so the two substring predicates cannot pass the sweep by
      matching everything.
      The camera is also the one parameter something outside the panel writes on its own, so the
      section polls `getParam` at 250ms. `Section` unmounts its content while collapsed, so the
      timer is created by the section's own child and lives exactly as long as the slider it feeds,
      rather than running for the life of the panel. `syncParam(id)` on the controller is the single
      read-back path all three callers share — `setParam`, the drifting climate, and this.
      "camera" joins `UNIVERSAL_GROUPS` — no coupling can take away where the viewer is standing —
      which deliberately changes the group-equivalence test in `test_sim_registry`. What that test
      still pins is the part that must not move: which groups each COUPLING contributes.
      **THE CAMERA DRIFT TOGGLE IS NOT DONE.** Deferred, not forgotten, and not silently dropped —
      see the note under 7.10.

- [ ] 7.10 Verify: pan and zoom through a full wrap in each axis — no seam, no trail smear, no
      popping. Park a bright cluster on the boundary and confirm glow and trail continue across.
      NEEDS THE APP, and is the honest gate on this group. Everything group 7 changed about what is
      SEEN is unverified: no one has run `./main` since group 6 began.
      Two specific things to look for, because they are where the reasoning could be wrong rather
      than merely unpolished. First, trail smear DURING A ZOOM specifically — panning smear would
      mean the reprojection is broken, but zoom smear would mean the two-camera approach is right in
      principle and wrong in some detail, which is a different bug. Second, whether glow stays
      attached to its particle across the seam: render.wgsl and glow.wgsl choose the toroidal image
      independently, and if they ever disagree the glow appears on the far side of the world.
      OUTSTANDING FROM 7.9: the camera Drift toggle (slow autonomous motion, off by default) is not
      implemented. It is the one piece of group 7 not built. Left undone deliberately rather than
      rushed in unverified alongside a camera nobody has watched move yet — a drifting camera is
      exactly the feature whose value cannot be judged from a test.
- [x] 7.11 `just happen` and `just check` green.
      600 native, 50 TypeScript, 0 failures, build clean.
- [x] 7.12 Make the camera-centre wrap unconditional. `Camera`'s doc promises the centre "ALWAYS
      wrapped into [0, worldSize)", but `panned`/`zoomedAt` wrap through
      `physics_core.wrapPosition`, which corrects by at most one span — and `zoomedAt` can move
      the centre by up to (worldW/2)·(1/CAMERA_ZOOM_MIN − 1/CAMERA_ZOOM_MAX) ≈ 1.94 world
      widths. Measured (session scratchpad `math_verify.py`): one wheel event jumping zoom
      8→0.25 with the cursor near the screen edge lands centerX at −144, outside the invariant,
      after which `nearestImageDelta`'s single-step correction mis-picks images for a band of
      particles and the world tears instead of shifting. Reaching it today takes one wheel event
      with |deltaY| around 2300 or more (`canvas_input.nim` forwards `event.deltaY` raw and
      uncapped); once 8.10's outstanding `cameraZoom` slider routing reaches the live camera, a
      slider jump could reach it without the fling — fix before that routing lands. Fix: wrap
      the centre with floor-mod (`pos − floor(pos/size)·size`) in `camera_core`'s movers (or
      harden `wrapPosition` itself; floor-mod agrees with the single-step form on every input
      the current callers produce — verify by grep before choosing), and pin it:
      `a centre moved by any multiple of the world span rewraps into [0, worldSize)`.
- [x] 7.13 Give the previous camera a real struct. 7.6's reprojection smuggles it through
      `FadeParams` as three loose scalars, rebuilt in `fade.wgsl` with a positional
      `Camera(...)` constructor whose only guard is a comment about field order —
      `CameraLayout`'s generated module and offset assertions see none of it. The same growth
      put `worldWidth`/`worldHeight` into both `FadeParamsLayout` and `TonemapParamsLayout`,
      the exact five-copies-five-chances argument this change itself makes against duplicating
      the camera. Move the world extent into `CameraLayout` (it holds one dead pad; grow to
      32 bytes) so every camera-binding pass gets it free, bind the previous frame's view as a
      second `Camera` uniform record for fade, and delete the loose scalars from both param
      layouts.
      The world extent moved into `CameraLayout` (16 -> 32 bytes: centerX, centerY, zoom,
      worldWidth at offset 12, worldHeight at 16, three pads), so `FadeParamsLayout` shrank
      32 -> 16 bytes (prevCenterX/prevCenterY/prevZoom/worldWidth/worldHeight deleted) and
      `TonemapParamsLayout` 48 -> 32 bytes (worldWidth/worldHeight deleted); `fade.wgsl` now
      binds the previous view as a second `Camera` record at `@binding(5)` and its
      hand-rebuilt positional `Camera(params.prevCenterX, ...)` constructor is gone, while
      `tonemap.wgsl` and `field-composite.wgsl` read `vec2f(cam.worldWidth, cam.worldHeight)`.
      `webgpu_render.nim` gained `prevCameraBuffer` with its own zoom-0 upload sentinel, one
      shared `uploadCamera(buffer, view)` writer for both records, fade layout/bind-group
      entry 5, and `EXPECTED_BIND_GROUP_ENTRIES_FADE` 5 -> 6; `wgsl_lint`'s
      `ExpectedShaderBindings[fade]` became `@[0,1,2,3,4,5]`. Two reds watched first:
      `tests/test_gpu_types.nim` failed to compile with "undeclared identifier:
      'CAMERA_WORLD_WIDTH'" before the layout grew, and `tests/test_wgsl_lint.nim` reported
      "fade: expected @[0, 1, 2, 3, 4, 5], got @[0, 1, 2, 3, 4]" after the manifest declared
      binding 5 and before the shader did. Green after: `just happen` (5 shaders rebundled,
      JS + UI + native all built) and `just test` at 685 [OK], 0 [FAILED]. Owed live check
      (CLAUDE.md landmine: which resource lands at each binding is unchecked): pan and zoom
      with trails on, and the bloom-off field backdrop, in a running app.
- [x] 7.14 Teach the lint the binding manifest. The render path's bind groups agree with their
      shaders' `@binding` numbers by comment alone (7.3's runtime-only hazard, and the surface
      has since more than doubled); entry-count validation mirrors the compute path only if the
      cleanup pass's `webgpu_render.nim` guards landed — and a count cannot see two swapped
      numbers either way. Add `bindingsDeclared(code): seq[int]` beside
      `namedFieldConstructorLines` in `src/wgsl_lint.nim`, have `tools/wgsl_bundle.nim` compare
      each bundled shader's declared set against an expected table, and the blank-canvas
      failure class becomes a build failure instead of a runtime hazard note.
      DONE (commit cb3e60c, delegated, lead-verified). `bindingsDeclared` returns sorted, deduped
      `@binding` numbers with trailing line comments stripped; block comments are a PINNED blind
      spot — a test asserts the limitation — rather than one left for rediscovery, matching the
      module's philosophy. `ExpectedShaderBindings`: one table in `wgsl_lint.nim`, all 20 bundled
      shaders, values read off a fresh bundle and never assumed contiguous — glow is @[0,1,2,4],
      legally skipping the field texture on the layout it shares with render. The bundler quits
      on a mismatch OR an unregistered shader (the `getExpectedEntryCount` -1 pattern), so a new
      shader must register its bindings before it builds at all. Nine tests, including the
      non-vacuous directory sweep. No live defect existed at landing — every shader's declared
      bindings agreed with its bind group. The blank-canvas class 7.3 recorded is now a build
      failure.
- [x] 7.15 **Zoom floor 1.0; the tiling machinery goes** — user decision, design D15.
      `CAMERA_ZOOM_MIN` 0.25 → 1.0; `CAMERA_ZOOM_NOTCH_TILED` deleted (at the new floor it
      collides with the world notch); `tileRing`/`tileCount`/`tileOffsetSteps` deleted from
      `camera_core.nim` with their tests; the three particle draws revert to one instance;
      `camera_transform.wgsl`'s tiling section and both shaders' instance displacement deleted.
      The nearest-image logic is untouched — it is correct for a single world span and keeps
      quads whole across the seam. 7.12's wrap fix lands beside this as invariant-pinning: at
      floor 1.0 a zoom jump moves the centre well under one span, so the multi-span defect is
      unreachable and the floor-mod is hardening.
      DONE (commits 939fcdb + 91a1858 + 22f3427, delegated, lead-verified). 209 lines of tiling
      deleted against 59 added; seven tiling tests deleted, one renamed to the property that
      SURVIVES (`a point past the seam renders at its nearest image, not the long way`) because
      its old name asserted tiling at a zoom no longer reachable. No `@binding` or layout line
      moved — confirmed by the 7.14 manifest passing untouched. `CAMERA_ZOOM_NOTCH_WORLD` stays
      a literal 1.0 rather than aliasing the floor: zoom 1 means that framing by definition and
      must not drift if the floor ever moves. The wrap test was watched failing at spans −4,
      −2.5, 3.0 and 7.25 in both movers before the floor-mod landed; 7.12's checkbox carries the
      same commits. FOUND AND LEFT FOR THE USER, Article 6 of the principles: `CAMERA_SIZE_FLOOR`
      and the `cameraSizeCorrection` pair are now provably dead — zoom clamps to [1, 8] at every
      entry, so the correction returns exactly 1.0 always. Deleting a mechanism is not an
      agent's or the lead's call to make alone; the dormancy is documented at each site and the
      decision is queued for the user with a recommendation to delete.
      THE QUEUED QUESTION WAS OVERRULED BY A STANDING USER RULE — "nothing dead ever gets to
      remain" — now engineering principles article 6. The apparent-scale floor and size
      correction were deleted in full (commit ffca6f6 on main, −137 lines, five tests), including
      `apparentScale` itself once its WGSL mirror died and left it a caller-less identity.
      Deferral dressed as deference is recorded as the failure mode, not the caution.
- [x] 7.16 **Device-adaptive camera input, per design D15.** Plain scroll pans; pinch (arriving
      as Ctrl/Cmd+wheel) zooms at the cursor; middle-button drag also pans; the 7.7 keyboard
      bindings stay; left-drag remains the physics interaction. Pure handler logic in
      `src/ui/input/` with native tests; DOM wiring in `canvas_input.nim`; `preventDefault`
      suppresses each page gesture replaced — Ctrl+wheel page zoom above all, because the
      browser is a portability runtime, not a website. The two-finger tap blast (7.8) is
      untouched. Also: `wheel_handler.nim:46-47` and `key_handler.nim:65` still name the old
      "0.25x"/"0.25..8" range in comments — 7.15 could not touch that tree; correct them here.
      DONE (commits fc7ff02 + fffb3be + a66545c on main, delegated, lead-verified). Shipped map:
      plain scroll pans by screen pixels at any zoom; Ctrl/Cmd+wheel — which is also how a
      touchpad pinch arrives — zooms at the cursor through the existing exponential
      clamp-before-anchor path; middle-button drag pans with a session state machine; keyboard
      unchanged; left-drag stays physics. Wheel listener registered non-passive so
      `preventDefault` actually suppresses page zoom and scroll. Eighteen new native tests in
      the input suites. The stale zoom-range comments were corrected against the constants. The
      third commit is the standing no-dead-code rule applied by the implementer itself: a
      zero-zoom guard in the new pan path was provably unreachable (zoom clamps to [1, 8] at
      every entry) and was deleted with the proof rather than documented.

## 8. Notched sliders, regimes, and weather (S7)

Notches mark values worth reaching. Whether the track between them is worth moving through is the
E family's question, and its travel curves are the remedy where it is not — the two compose on the
same descriptor without conflicting.

- [x] 8.1 `src/ui/api/param_descriptor.nim`: add an optional `notches: seq[(value: float, label:
      string)]` to the descriptor, served through `gardenAPI.descriptor()`. Nim owns the notches like
      every other number.
      Shipped as a named `ParamNotch` object rather than an anonymous tuple, so the JS serializer and
      the tests can name its fields. Served in `descriptorToJs`.
- [x] 8.2 `tests/test_param_descriptor.nim`: `every notch value lies inside its parameter's range`.
      **This fails for Coral (feed 0.082) until task 8.3.**
      IT DID, exactly as predicted: `entry.value was 0.082 / descriptor.maxValue was 0.08`. Green
      after 8.3. ORDERING NOTE: the feed/kill notches had to be populated (part of 8.4) before 8.2
      could fail on anything, so that slice of 8.4 landed between 8.1 and 8.2. The failure the
      ordering exists to produce was preserved, not avoided.
      A SECOND ASSERTION WAS ADDED that the task did not ask for: `every notch sits on a position the
      slider can actually land on`. In-range is not sufficient — a notch off the step grid is a tick
      the handle slides past without stopping on, so snapping to it would leave the readout holding a
      value the slider cannot express. Same rule the hint numerals were already held to.
- [x] 8.3 `src/config_ranges.nim`: raise `RD_FEED_MAX` from 0.080 to 0.085 so Coral is reachable
      (design D4).
      Plus a static assertion looping `RD_REGIMES` against both ranges, so the next coordinate past a
      ceiling fails the BUILD rather than a test — the parameter-range-authority spec's "narrowing a
      range strands a notch" scenario.
      SAFETY-MARGIN NOTE, since this widens a range that bounds a measured margin: **`RD_DEPOSIT_MAX`
      is untouched at 0.08.** Group 5's chemotactic-collapse measurement bracketed the collapse point
      in the PRODUCT of tropism and deposit, and the tropism margin it measured is a function of the
      deposit ceiling, not the feed ceiling. Raising feed to 0.085 moves neither factor, so that
      margin is unaffected. Anything that later raises `RD_DEPOSIT_MAX` does spend it and must re-run
      test_field_core's "Chemotactic Collapse Bound" suite.
- [x] 8.4 Populate notches: feed and kill at the six regime coordinates in design D4; `rdDeposit` at
      0 ("inert") and its default; `rdFieldForce` at 0 ("blind") and its default; camera zoom at 0.25
      ("tiled"), 1.0 ("world"), 8.0 ("creature"); particle count at the coupling ceilings.
      All done EXCEPT the camera zoom notch, which is STAGED, NOT WIRED, and belongs to group 7: no
      `cameraZoom` descriptor exists, and creating one means deciding where camera state lives. The
      three values ship as `CAMERA_ZOOM_NOTCH_TILED/WORLD/CREATURE` in config_ranges beside
      `CAMERA_ZOOM_MIN/MAX`, with a static assertion and a test that they lie inside the range.
      Attaching them is one `notches = @[...]` argument once the descriptor exists.
      The particle-count ceiling is ONE notch, not two: `SPH_PARTICLE_CEILING` and
      `RD_PARTICLE_CEILING` are both 32000. It reaches the descriptor as `COUPLING_PARTICLE_CEILING`
      in config_ranges — routed through the range authority the way `SPH_SUBSTEPS_MAX` already is,
      rather than imported from sph_core directly, so the descriptor table needs only that one module.
      A static assertion holds the two source constants equal, because the single name is only honest
      while they agree.
      CAMERA ZOOM RESOLVED BY THE LEAD: `cameraZoom` gets a descriptor and becomes a notched slider
      like everything else, but routes to the camera rather than CONFIG and is EXCLUDED from preset
      serialization — a preset restores a world, it should not also seize where the user is standing
      to look at it. The lead owns that wiring since camera state lives in `webgpu_render.nim`; the
      `CAMERA_ZOOM_NOTCH_*` constants, the static assertion and the in-range test stay here as the
      guard it attaches to.
      A THIRD `rdDeposit` NOTCH was added beyond the task's two — see 8.6's measurement.
      THE OLD FEED/KILL HINTS WERE REMOVED. They listed four regime coordinates each as raw numerals,
      which the notches now carry; leaving both would be two copies free to drift, and they already
      had — the hint named a coral at (0.055, 0.062) from a different source than the (0.082, 0.059)
      the regime table transcribes. The suite that guarded those numerals now asserts the migration.
      OVERTAKEN IN PART BY DESIGN D15 AND D16: `CAMERA_ZOOM_NOTCH_TILED` is deleted with the 1.0
      floor (task 7.15) — the world and creature notches survive — and the particle-count budget
      notch is deleted with `PARTICLE_BUDGET` itself, because no cap sits below capability.
- [x] 8.5 `web-ui/src/`: render notches as labelled tick marks on every slider that declares them,
      snapping when dragged near. Every factor stays a slider.
      SNAPPING IS A SOFT MAGNET, not a hard stop — the invitation left that call open. The track stays
      continuous, so a value between two named regimes is still reachable by dragging past the pull.
      `web-ui/src/lib/notches.ts` holds the geometry as pure functions with `web-ui/test/notches.test.ts`
      over them.
      A TEST CAUGHT A REAL DEFECT IN THE FIRST DESIGN. A flat pull of 1.5% of the feed axis is
      0.001125, which is WIDER than the 0.001 gap between Mitosis (.028) and Labyrinth (.029) — so
      those two swallowed the whole span between them, making it a hard stop wearing a magnet's
      clothes. Fixed structurally rather than by retuning the constant: each notch's pull is capped at
      40% of the distance to its nearest neighbour, so "there is always reachable space between two
      notches" holds at any `SNAP_FRACTION` and a future regime coordinate cannot quietly break it.
      A side effect worth noting: ties are now impossible (two notches can never both reach one
      point), so no tie-break rule is needed and none is written.
- [x] 8.6 `web-ui/src/`: a named-regime selector row (Waves, Mitosis, Labyrinth, Spots, Worms, Coral)
      setting feed and kill together, because a notch on one axis alone does not locate a regime.
      A ROW OF BUTTONS, per the invitation's fork: six entries is few enough that all fit in view, and
      seeing the whole set at once is most of the point — a dropdown would hide the available worlds
      one at a time behind a control.
      **DEVIATION FROM D4'S LETTER, driven by measurement.** The buttons also raise the DEPOSIT when
      the chosen regime needs it. On the shipped path — no seed, colonies depositing through the splat
      kernel — Worms and Coral **never ignite at the default deposit**, not slowly, not in 600 frames;
      their feed rate depletes a nucleus faster than a 0.02 deposit builds one. Frame of ignition
      against deposit (budget 60, `-` not measured):

          regime      0.020  0.030  0.040  0.080
          Waves           4      -      -      1
          Mitosis         7      -      -      1
          Labyrinth       6      -      -      1
          Spots          11      -      -      1
          Worms          NO     15      4      1
          Coral          NO     21      4      1
          DEFAULT         8      -      -      1

      Setting only feed and kill would therefore ship two dead buttons, which is precisely the "no way
      to find the living parts except by accident" failure D4 exists to fix. Each regime carries a
      measured `minDeposit` and the button applies it as a FLOOR (`max(current, minDeposit)`), never a
      set: a user who deliberately raised the deposit keeps their value, and the four regimes that
      ignite at the default never touch it. 0.040 is also a labelled notch on the Secretion slider, and
      a test ties the two to one constant so they cannot drift.
      **VERIFIED THAT THE FLOOR DOES NOT LIE ABOUT THE REGIME.** Igniting a regime is not the claim;
      SETTLING INTO THE NAMED PATTERN is. The reference is the UNFORCED ATTRACTOR — what Gray-Scott
      settles into at a regime's own (F, k) from a supercritical nucleus with NO deposit at all, which
      is what D4's coordinates name. Measured (`alive` / `std-over-mean`, 150 frames both sides):

          regime               unforced        floored/shipped     distance
          Worms             0.188 / 1.90       0.177 / 2.02          0.13
          Coral             0.497 / 0.96       0.448 / 1.01          0.10
          Labyrinth (none)  0.539 / 0.60       0.535 / 0.62          0.02

      against cross-regime separations of 1.25 (Worms/Coral), 1.65 (Worms/Labyrinth) and 0.40
      (Coral/Labyrinth). Each floored regime lands 4x closer to its own attractor than to any other.
      A FIRST ATTEMPT AT THIS COMPARISON WAS WRONG AND IS RECORDED SO IT IS NOT REPEATED: comparing
      0.040 against 0.080 shows only that two elevated deposits resemble each other, and a separate
      run at 60 frames made Coral look like it had crossed into another morphology entirely. That was
      an artifact of stopping before the shipped path settled — SETTLING TIME IS LOAD-BEARING and both
      sides must run the same number of frames.
      THREE CONTROLS make the result mean something rather than assert it: a separation check that the
      statistic can tell two regimes apart at all (without it, any two patterns would "match"); a
      regime that gets NO floor (Labyrinth) through the identical procedure, so a pass cannot come
      from the procedure itself; and an aliveness floor, since two dead fields would otherwise agree
      perfectly. Shipped as `The Regime Deposit Floor Preserves The Regime`.
      CORRECTION TO AN EARLIER READING, recorded because it was reported before it was checked and
      is easy to re-derive: an early probe suggested WORMS AND CORAL had no unforced attractor —
      that a nucleus alone dies at those coordinates and their pattern is deposit-sustained. That is
      WRONG, and it was a property of the seed rather than of the system. At
      `RD_SEED_CORE_ACTIVATOR` (0.5) even a flat radius-16 disc dies there; at activator 0.75 both
      settle into healthy attractors (Worms 0.188 / 1.90, Coral 0.497 / 0.96), which is exactly what
      the shipped test compares the floored regimes against. The basin at those coordinates is narrow,
      not absent.
      NOTE ON THE UNFORCED REFERENCE: Spots, Mitosis and Waves have none. At their low feed a nucleus
      cannot sustain itself without continuous deposit, so their pattern is deposit-sustained by
      nature and "unforced Spots" does not exist — which is why Labyrinth, the one low-feed regime
      with a real attractor, is the negative control rather than Spots.
      THE DEPOSIT WRITE IS VISIBLE, same rule as 8.7's drift: it goes through `setParamImpl`, the
      ordinary clamped path, and the panel re-reads every descriptor afterwards, so the Secretion
      slider shows the raised value. A silent change would leave the user setting the deposit by hand
      from a number already wrong.
- [x] 8.7 `climateDrift` bool and `climateSpeed` in sim config; the frame loop advances feed and kill
      along a smooth path inside the rectangle through the ordinary `setParam` path, so the sliders
      visibly move. Off by default.
      `src/climate_core.nim` (new, pure) holds the path; `web_api.setClimateFromSimulation` is the
      named entry the loop uses, deliberately routing through the same clamped path a drag takes
      (it began as per-parameter `setParamFromSimulation` calls; the cleanup pass collapsed the two
      writes into one store-and-mirror cycle without leaving the clamped path).
      **THE PATH TOURS THE NAMED REGIMES** rather than wandering the rectangle. Most of the feed/kill
      plane produces nothing worth looking at — the whole reason the regimes exist — so a random walk
      would spend most of its time in dead parameter space and read as broken rather than as weather.
      Two properties hold BY CONSTRUCTION, not by tuning: every point is a convex combination of two
      in-range regime coordinates over an axis-aligned (hence convex) rectangle, so it cannot leave the
      box and no clamp is applied (a clamp would MASK a path that had left it); and segments join with
      smoothstep easing, whose zero end-derivative removes the velocity corner plain interpolation
      would put at every waypoint.
      Drift advances on WALL-CLOCK seconds, not the timeScale-scaled dt — "one tour a minute" should
      mean a minute regardless of how fast the simulation is running. Speed is expressed in tours per
      minute, a unit a user can feel.
      The panel polls `getParam` at 4 Hz WHILE DRIFT IS ON and not otherwise; the frame loop has no way
      to push at it.
- [x] 8.8 `tests/`: `climate drift stays inside the feed/kill rectangle for every phase`; `climate
      drift is continuous — no step exceeds the configured maximum delta`.
      Both shipped under their given names in `tests/test_climate_core.nim`, plus eight more covering
      phase wrapping, waypoint handover, the easing (a test that would notice smoothstep being dropped
      for simplicity), the tours-per-minute contract at two frame rates, and a zero-dt frame.
- [x] 8.9 `src/ui/api/param_descriptor.nim`: rename the field group's display labels to sensory names
      (Secretion, Scent-following, Drift, Breath). **Labels only** — descriptor ids are preset storage
      keys and must not move.
      Ids untouched; only `label` strings changed. DEVIATION: the task names FOUR labels for what are
      now FIVE controls (8.7 added `climateSpeed`). Mapped semantically rather than positionally:
      `rdDeposit` -> Secretion (what particles give off), `rdFieldForce` -> Scent-following (how hard
      they follow it), `climateSpeed` -> Drift (the weather), and "Breath" split across the feed/kill
      PAIR as `rdFeed` -> Breath In and `rdKill` -> Breath Out — they are the intake and removal terms
      of the same exchange, and the regime buttons now set them together anyway. The technical names
      (feed rate F, kill rate k) moved into the hints so the connection to the literature survives the
      rename.
      NAME COLLISION 8.9 CREATED, AND ITS RESOLUTION. "Secretion" would have appeared twice in one
      panel: on this slider and as the per-species chemistry column from group 5. Related but not the
      same KIND of quantity — the slider is the base amount every particle lays down, the column is
      each species' signed share of it — so a user meeting two controls under one word could not tell
      which they were looking at. Resolved by differentiating the slider as **"Secretion Rate"** and
      leaving the per-species column as "Secretion", with each hint naming the other explicitly
      ("each species scales it in Species Chemistry" / "this species' share of the Secretion Rate").
      Renaming the slider rather than the column keeps the grid header short, which matters in a
      narrow cell.
- [x] 8.10 `just happen` and `just check` green.
      Verified by the lead after group 7's `TonemapParams` growth briefly reddened it: 598 native,
      50 TypeScript, 0 failures, `just check` exit 0. The two failures that caused this to be
      un-checked were group 7's layout-size assertions, not group 8's work.
      Green again after a SECOND round of shared-file fallout, absorbed here rather than left red:
      `psCamera` joined `ParamStore` for the camera descriptor, which left `web_api`'s `storeName`
      non-exhaustive and two descriptor tests asserting a two-store world. Those land in this group's
      files, so they were fixed here — `storeName` gained the case, `garden-api.ts`'s `ParamStore`
      gained `"camera"`, `cameraZoom` joined the interface-contract id set, and the store-routing test
      now states three destinations instead of two. One assertion was ADDED beyond repairing the
      break: `cameraZoom` must be the ONLY psCamera descriptor, because a second one appearing
      silently would mean some world parameter had quietly stopped being saved in presets.
      Final: 600 native, 50 TypeScript, 0 failures.
      STILL OUTSTANDING AND NOT THIS GROUP'S TO WRITE: `getParamImpl`/`setParamImpl` have no
      `cameraZoom` case, so the descriptor exists and the slider renders, but reads and writes do not
      reach the live camera yet. That routing needs camera state in `webgpu_render.nim`.
- [x] 8.11 Let the climate own its output surface. Which parameters the weather writes is
      restated in three languages: `app.nim`'s frame loop (string literals), `state.ts`'s
      drift sync, and `state.ts`'s regime re-read — a third drifting axis would move the
      simulation while the panel silently stopped reporting part of it, and no test can see
      the gap because the TS side derives from nothing. Name the ids once (`climate_core`
      returning its writes, or a `CLIMATE_PARAM_IDS` constant served through gardenAPI) and
      replace the panel's polling interval with a push on the existing stats/notification
      channel, deleting `syncDriftingParams` and its timer. A cleanup pass may already have
      routed the TS ids through the descriptor `group` field and collapsed the frame loop's
      two per-frame `setParam` round-trips into one combined write — check the code, then
      remove whatever restatement remains.
      DONE, delegate-built, lead-integrated. Ground truth first, as instructed: the earlier
      cleanup had collapsed the frame loop's round-trips into `setClimateFromSimulation`, but
      the ids had moved into `web_api.nim` as literals and state.ts's two restatements had
      merged into one `REGIME_COORDINATE_IDS` constant deriving from nothing; the group-field
      route the task floated cannot work (group `rd` holds five ids — group says where the
      panel puts a control, not what the weather writes). Single home now:
      `climate_core.CLIMATE_PARAM_IDS: array[ClimateAxis, string]` — indexed by the axis enum
      so a third axis with no id fails the build. web_api loops the enum, takes the tour
      point whole, serves `climateParamIds()`, and pushes the values on the existing stats
      channel; state.ts derives the ids and applies pushes inside `onStats`;
      `syncDriftingParams` and the 250 ms timer are deleted. Guards went red first: the
      panel-agreement suite printed the restated ids, and the TS fixture deliberately uses
      non-shipped ids so a controller holding its own copy cannot pass. CADENCE: readout
      moves 250 ms → 500 ms, inherited from the stats tick — flagged for the user. RAISED,
      not decided: `applyRegimeImpl` still writes `rdFeed`/`rdKill` literals — that names
      what a regime button sets, coinciding with the climate's writes only via
      `rdClimateTour`'s projection; fix/defer/leave is the user's call. Task 4.5's force
      weather extends this mechanism with no TypeScript edit. INTEGRATION SEAM, lead-fixed:
      the delegate's state.test.ts fixture predated 5.9's discriminated union and lacked the
      required `arity` — one-line fixture fix, then the full gate ran green over the merged
      result.

## 9. One world (S2)

**This group is next — see "Order of work" at the top of this file for why the sequencing changed and
what it costs.** It is the change's premise (design D7), and it is breaking.

Read D7, D8 and D11 before starting. The tasks below were written against three booleans; they now
mean strengths, and the tasks that follow have been rewritten to say so. Two rules govern every task
in this group:

- **Nothing enumerates.** If a task leaves behind a list of coupling combinations anywhere — in the
  frame path, the panel, the range authority, or the preset schema — it is not done. The check is a
  grep, and 9.0e makes it a test.
- **Zero is an ordinary value.** Every coupling reaches zero through its own slider, and arriving
  there resets nothing, hides nothing, and re-initializes nothing.

- [x] 9.0a **The strength question, answered first because everything else depends on it.** D7's open
      question: forces already have `forceStrength` and chemistry has its deposit/field-force pair,
      but fluid has three numbers (stiffness, rest density, viscosity) and none of them means "how
      much fluid". Decide between a new fluid strength scaling the whole contribution, and promoting
      stiffness to that role. Record the decision and its consequence for the existing sliders'
      meanings in `design.md` as **D14** — D12 and D13 are taken — before writing code. It must
      satisfy D12: whatever number is chosen has to multiply the fluid's ENTIRE contribution, which
      is the argument against promoting stiffness, since Tait pressure vanishes at stiffness zero
      while viscosity and the XSPH term do not. Note also the interaction with
      C7: stiffness also sets the stability boundary, so promoting it makes one
      slider carry two jobs.
- [x] 9.0b `tests/test_sim_registry.nim`: rewrite the per-combination pass-list tests as tests over
      strengths. Same pinned behaviour, new coordinates. Add `a coupling at zero strength dispatches
      no pass` and `moving a strength to zero changes nothing else about the world`.
- [x] 9.0c `src/sim_registry.nim`: `WorldCouplings` becomes a strength vector; `buildFrame` takes it
      and skips a pass only when its strength is exactly zero. Delete `couplingsFor`.
- [x] 9.0d `src/sim_registry.nim`, `src/web_api.nim`, `web-ui/src/`: delete `controlGroupsFor`, the
      `shows(group)` predicate in `Panel.tsx`, and the native coverage invariant that related
      dispatches to control groups. One world offers every control at all times.
- [x] 9.0c1 **The pass-ownership split D12 requires, which no earlier task named.** Redraw
      `src/shader_manifest.nim` so each pass is world-intrinsic or coupling-owned. World-intrinsic:
      the grid triad and scatter, local density accumulation, the field's own `rd-step` evolution,
      and `integrate` — none may be skipped by any strength. Coupling-owned: the force term, SPH
      pressure and viscosity, `field-deposit`, and `field-force`.
- [x] 9.0c2 **Separate density accumulation from the force term inside `forces.wgsl`** — the one
      shader change D12 forces. Today `web/shaders/src/forces.wgsl:328-339` accumulates
      `densityContribution` in the same loop that computes force, with no strength factor, while
      `src/physics_core.nim:60` applies `fMul` to the force alone. Skipping that pass at force
      strength zero would therefore take the world's density with it — the density dot size,
      brightness, and glow radius all read. Density must survive a zero-strength world.
      Its cost is the honest price of D12: the neighbour sweep still runs where no forces act.
      Measure it and hand the number to group 10 rather than guessing.
      NO SHADER EDIT WAS NEEDED FOR THE SEPARATION ITSELF, and that is worth knowing before anyone
      looks for one. `params.forceMultiplier` already multiplies the species force and nothing else —
      the mouse and blast terms are added after it — so the split falls out of the FRAME dispatching
      `forces` unconditionally. The task's premise that a shader change is forced held only while the
      pass could be skipped.
      TWO THINGS forces.wgsl CARRIES THAT NO TASK NAMED, both found by reading it. It applies the
      MOUSE and the BLAST, which no strength scales — a second and sharper reason its pass cannot be
      skipped, since 9.5's first acceptance criterion is dragging while chemistry runs. And in a
      field-only world nothing dispatched either force shader, so dragging did nothing at all: a live
      bug this group fixes rather than a regression it risks.
      THE MOUSE AND BLAST WERE ALSO DUPLICATED in forces-sph.wgsl, so a world coupling forces and
      fluid dragged at double strength. Removed there; forces.wgsl is the sole applier.
      WHAT THE SPH SPLIT ACTUALLY COST: `forces-sph` reads its neighbour's density back off the
      particle struct, so making it private needed somewhere to put it. `Particle`'s padding word at
      offset 24 is now `sphDensity` (memory_layout, gpu_types, particle.wgsl), fed by a new
      `sbSphDensityDelta` buffer and resolved by `integrate.wgsl` at binding 4. Zero allocation: that
      word is padding the 32-byte alignment already pays for. `SPH_DENSITY_GLOW_GAIN` retires with
      it — the gain existed to push SPH's density into the range the shared glow wanted.
      THE CROWD-DENSITY CHANNEL IS DEFERRED TO C1.7a by the user's decision, recorded in design's
      settled open question. D12 needs only the SPH split; crowd density's sole consumer is C1.
      MEASUREMENT NOT TAKEN. The task asks for the neighbour-sweep cost handed to group 10, and this
      group did not measure it — the fluid ships at strength zero and the profiler run belongs with
      group 10's instrumented baseline. Group 10 inherits an unmeasured claim, which is why 10.1
      names the forces-with-chemistry world explicitly.
      DEAD UNIFORM LEFT IN PLACE, FOUND WHILE SWEEPING THE SHADER COMMENTS. `glowDensityFloor`
      (`RenderParams` offset 48, `glow.wgsl:153`) exists to lift the glow's density factor where
      density is unavailable, which was the case for a world running no forces pass. Density now
      survives every world by exactly the argument above, and `webgpu_render.nim:1583` writes the
      floor at `0.0` unconditionally, so `max(rawDensityFactor, params.glowDensityFloor)` is inert.
      The comment states that; the field stays. Removing it shrinks `RenderParams` and touches the
      render bind-group layout, which nothing checks at compile time, so it is a deliberate change
      for the user to schedule rather than a cleanup to fold into a comment sweep.
- [x] 9.0c4 **BOUND WHAT A CELL TAKES IN ONE FRAME** — task added after the user ran the app and reported
      that holding the mouse breaks the world. Not a regression this group introduced, and reachable
      only because of it: dragging while chemistry runs is 9.5's first acceptance criterion, and it
      was impossible before, so nothing had ever driven this path.
      `RD_DEPOSIT_MAX` bounds what ONE PARTICLE deposits per frame. The stability argument citing it
      is about the value in a CELL, and those are the same number only while particles are spread
      out. Nothing bounds their sum — particles per cell has no ceiling — so a held mouse gathers a
      crowd and drives one cell's inhibitor without limit, past the range explicit Euler integrates
      stably, into the grid-scale oscillation the user photographed.
      MEASURED against `field_core`'s own `grayScottStep`, 64x64 grid, 100 feed/kill samples across
      the full slider ranges, a block of cells driven every frame for 400 frames on a living pattern:
      cap 0.10 and 0.20 both stable (peak inhibitor 0.637 and 0.658); cap 0.25 diverges at feed 0.010
      kill 0.040. At the shipped deposit it takes ~342 co-located particles to reach a diverging
      value and ~86 at `RD_DEPOSIT_MAX` — a held mouse passes both immediately.
      `RD_DEPOSIT_CELL_MAX = 0.10`, half the largest measured stable cap. The margin is worth its
      cost because the boundary is NOT monotone: clamping the field's STATE instead measured stable
      at 0.75 and unstable at both 0.72 and 0.80, so a value chosen at the last passing sample sits
      on a ragged edge rather than inside a safe interval.
      THE BOUND IS ON THE INJECTION, NEVER THE STATE, and that distinction is the design. A living
      pattern reaches 0.515 inhibitor in steady state and excursions above 0.7 while igniting, all
      self-limiting. A ceiling on the state clips those; a ceiling on what particles add does not.
      `field_core.resolveCellDeposit` mirrors `field-resolve.wgsl`, five tests, one of which runs the
      same held mouse through the UNBOUNDED path and asserts it diverges — so the pair states that
      the bound is what holds the field finite rather than the scenario being too gentle to break.
      SECOND DEFECT FOUND ON THE SAME PATH, PRE-EXISTING. Kernel density accumulates through an i32
      atomic at `FIXED_POINT_SCALE`, spanning 32768 at the shipped scale, while the count slider
      reaches `MAX_PARTICLES` = 128000 and nothing bounds how many share a smoothing radius. Past the
      span an i32 wraps NEGATIVE, and the equation of state reads negative density as maximal
      expansion and answers with force in the wrong direction. Group 9 made this LESS likely, not
      more — the pre-9 encode carried an extra `SPH_DENSITY_GLOW_GAIN` multiplier.
      THE FIRST FIX WAS WRONG AND THE USER REJECTED IT, correctly. Saturating the encode makes the
      particle ceiling unreachable, which is not what a maximum means: 128000 is a setting the slider
      offers, so the density it produces has to ENCODE, not clamp. The clamp was also ineffective —
      `forces-sph.wgsl:297` applied it to a single neighbour's normalized weight, which never exceeds
      1.0, and no per-contribution clamp can bound a total formed by `atomicAdd` across threads.
      THE ENCODING IS WHAT WAS WRONG, not the budget. Each neighbour's poly6 weight is divided by the
      self-weight, so a neighbour contributes at most 1.0 and the accumulated density COUNTS
      neighbours — its worst case is exactly `MAX_PARTICLES`. `sph_core.sphDensityFixedPointScale`
      derives a second, coarser fixed-point scale from that budget: the largest power of two leaving
      `SPH_DENSITY_HEADROOM` (2x) of span free, which is 8192 at the shipped ceiling. Powers of two
      because a float scaled by one is exact in binary, so raising `MAX_PARTICLES` re-derives the
      scale and re-encodes every density identically — a one-constant change, which is what the user
      asked for. Velocity deltas keep 65536: they are small and signed and want resolution near zero,
      where density is large and positive and wants range. `fixed_point.wgsl` carries both pairs and
      states the invariant that each has exactly one encoder and one decoder; `integrate.wgsl` decodes
      with the matching inverse. Five tests, including the full budget encoding as itself and a
      flexibility property that a 64x budget still derives a valid scale.
- [x] 9.0c3 `tests/`: the multiplier property, per coupling. `as strength approaches zero the
      coupling's contribution approaches zero continuously`, and `at exactly zero the world is
      identical to the world with that pass absent`. This pair is what makes the zero-strength skip
      an optimization rather than a mode hiding in a floating-point comparison, and it is the test
      that fails if a coupling-owned pass is found to produce something its strength does not scale.
- [x] 9.0c4 `src/config_ranges.nim`: **D13 — every coupling strength's range includes zero.**
      `FORCE_STRENGTH_MIN` is 0.1 today, so the one coupling D7 claimed already had a strength
      cannot be set to zero at all. Under the range authority's existing static assertions. A
      property D7 asserts and no range permits is not a property.
      Record in a comment that `fMul` scales BOTH force zones (`src/physics_core.nim:52-60`), so
      force strength zero removes short-range repulsion along with attraction and particles pass
      freely through each other. That is correct — with no species forces nothing holds them apart —
      and C0 is where its consequence for the collapse cap is resolved.
- [x] 9.0c5 **THE FIELD DRAWS SMALLER, ON SQUARE CELLS, AND STOPS CLAIMING THE FRAME** — task added
      after the user ran the app and reported the chemistry so large, so bright and so total that
      nothing else had room to emerge.
      THREE DEFECTS, ONE SCREENSHOT. (a) A 512x512 field over a 3840x2160 world made cells 7.5 by
      4.22 world units, and since the 9-point Laplacian is isotropic in CELLS every spot rendered as
      an ellipse 1.78x wider than tall — visible in the user's image as horizontally stretched blobs.
      (b) At 7.5 world units per cell a spot spanned ~70 world units. (c) `fieldOpacity` gated BOTH
      the fullscreen backdrop and `render.wgsl`'s particle tint, so the only way to stop the field
      claiming whole regions of the frame also blinded the particles to it.
      RESOLUTION IS THE ONLY SAFE LEVER, and finding that out cost a full detour worth recording.
      Pattern wavelength scales as `sqrt(diffusion)` in cells — MEASURED on a 128x128 torus at the
      Pearson defaults, 6000 steps, connected components above half peak inhibitor: 9.30 cells at
      Da=1.0, 6.55 at 0.5, 4.47 at 0.25, 3.71 at 0.16, then collapse (coverage falls 0.22 to 0.03 by
      0.09; single-cell components by 0.04). Lowering diffusion therefore looks like a cheap shrink.
      IT IS NOT. Pearson's (F, k) phase map, which `RD_REGIMES` cites and the feed and kill slider
      ranges are drawn against, is drawn AT those diffusion rates. At Da=0.25 the suite caught all
      three consequences: a floored regime settled 2.5x further from its own unforced morphology than
      from another regime's, scattered deposits ignited where coherence had been required, and the
      chemotactic collapse the safety bound is measured against stopped reproducing. Gray-Scott's
      dynamics live in cell space; only the cell's WORLD size may move.
      `FIELD_PATTERN_SHRINK`, one knob, everything derived. `FIELD_W = 512 * shrink`,
      `FIELD_H = 288 * shrink` — 512:288 is the world's 16:9, so a cell is SQUARE at every setting,
      which is defect (a) fixed for good rather than for one resolution. Shipped at 4: 2048x1152,
      2.36M cells, ~19 MB per ping-pong texture plus a ~9 MB deposit buffer. The user asked for 10x
      and then scaled the ask back to 3-4x; the knob is what makes that a one-line decision, and
      `RD_STEPS_PER_FRAME` is named as the lever if the field pass ever costs too much.
      A UNIT MISMATCH THE SHRINK EXPOSED, and the sharpest finding here. `field-force.wgsl` takes a
      gradient PER CELL and writes an impulse in WORLD units, so a fixed `fieldForceScale` carries a
      particle the same distance across a pattern that has itself shrunk — its response to a feature
      strengthens by exactly the shrink. `RD_DEFAULT_FIELD_FORCE` and `RD_FIELD_FORCE_MAX` are
      therefore DIVIDED by the knob, and `test_field_core` derives its chemotaxis harness geometry
      from `FIELD_W` for the same reason, which is how the mismatch surfaced at all. A v1 preset's
      field force is rescaled rather than clamped in `migrate` (`V1_FIELD_FORCE_SCALE`): clamping
      would silently rewrite a saved world 4x stronger. `rdFieldForce`'s descriptor takes one decimal
      place, because a range divided by the knob stops landing on whole numbers and a slider that
      cannot stop on its own default is broken.
      THE COLLAPSE BOUND WAS RE-MEASURED, NOT RELAXED. `maxVelocity` is a WORLD quantity and cannot
      scale with the knob, so a finer grid leaves a particle crossing more cells per frame at the
      same speed. MEASURED, field force at maximum, tropism 0 to 128x the bound: deposit 5x and 10x
      the ceiling are finite everywhere; 15x diverges at 1x and 2x tropism; 20x at 1x, 2x and 4x; 30x
      at 1x through 8x. COLLAPSE LIVES IN A MIDDLE BAND OF TROPISM — at zero there is no aggregation
      to run away, and above 16x particles overshoot the well and scatter instead of pooling — and
      the band widens downward as the deposit rises. So no bound on tropism alone can help, and the
      suite now asserts what the measurement actually brackets: the DEPOSIT ceiling protects the
      world, bracketed in (10x, 15x] of a ceiling the slider already caps an order of magnitude
      below. The frozen-population control is unchanged in role and still carries the claim.
      THE FIELD SHOWS ITSELF THROUGH THE PARTICLES. `FIELD_OPACITY_DEFAULT` drops to 0 — the backdrop
      draws nothing unless asked — and `render.wgsl`'s tint answers to `FIELD_LIGHT_STRENGTH` alone.
      No new uniform and no new slider: the pull is already proportional to local field intensity and
      the field clears to the trivial fixed point, so a particle standing where no pattern is keeps
      its species colour exactly. The backdrop stays a slider rather than being deleted, because it
      is the only way to see the field where no particles stand.
- [x] 9.0e A test asserting the source tree names no mode: no `SimKind`, no mode id list, no mode
      catalog. This is the guard that stops the concept growing back, and it is cheap — a grep over
      `src/` and `web-ui/src/` in the native suite.
- [x] 9.1 `tests/`, written against D8's TRANSLATE-AT-DECODE mechanism — not against subtraction,
      which cannot work here: `a legacy preset zeroes the strengths its mode excluded`;
      `a legacy particle-life preset does NOT switch chemistry on`, which is the specific regression
      subtraction would have shipped, since the schema serializes `rdDeposit` and `rdFieldForce`
      unconditionally with nonzero defaults (`src/preset.nim:506-515`, `:199-212`);
      `a current-schema preset applies exactly the strengths it carries and consults no mode`;
      `lowering the particle count preserves the surviving particles' positions`;
      `applying a preset whose count exceeds the budget clamps to the budget`.
- [x] 9.1a **GAP FOUND IN GROUP 5, HOMED HERE.** Carry species chemistry in the preset schema:
      `preset.nim`'s versioned schema, its validation, and `presetApplySteps`, plus a round-trip test
      beside 9.1's. `exportPresetJson` today carries CONFIG, the attraction matrix and the palette,
      but NOT secretion or tropism — so saving and reloading silently discards every chemistry edit.
      This is a defect THIS change introduces rather than a pre-existing one: before group 5 there
      was no chemistry to lose, and 5.6 shipped the editor that makes it losable. Homed in group 9
      because that is where preset-schema work already lives (9.3a, and D8's compatibility layer);
      no group 5 task asked for it, which is why it was not done there. Chemistry needs the same
      ceiling-and-clamp treatment 9.3a gives particle count — an out-of-range secretion in a
      hand-edited preset must clamp through `clampChemistryValue`, not land raw in the uniform.
      GAP MEASURED, not remembered — derived by diffing `simulation_state` + `render_state` against
      `preset.nim`, so the list is complete:
        - `secretion` / `tropism`: ZERO occurrences in `preset.nim`. Not a missing field but a
          missing DIMENSION — `MAX_SPECIES x 2` values, so it needs an array member modelled on
          `matrix` (16 references there to copy), never a scalar.
        - `climateDrift`, `climateSpeed`: the only two simulation-state fields with no schema field.
        - `cameraZoom`: DELIBERATELY absent and must stay absent. The descriptor-store test enforces
          it by requiring `cameraZoom` to be the only `psCamera` descriptor, so a world parameter
          cannot quietly drift into the camera store and out of presets.
        - Regime selection needs NOTHING: `getRdRegime` derives the regime from the current
          feed/kill, so serializing those two already round-trips it. A `regime` field would be a
          redundant second copy free to disagree — the same defect as the one below.
      NAMING DECISION THIS GROUP MUST MAKE: the starter presets and `RD_REGIMES` hold the SAME point
      under two names — `web_api.nim:869` has `("rd-stripes", "Stripes", 0.029, 0.057)` and
      `config_ranges.nim:131` has `(id: "labyrinth", label: "Labyrinth", feed: 0.029, kill: 0.057)`.
      Deduplicating means choosing which name ships; neither table is a subset of the other.
      SETTLED WITH 9.4: Labyrinth ships, and the starters iterate `RD_REGIMES` so no second table
      exists to disagree.
      A WORSE DEFECT SAT BESIDE THE ONE THIS TASK NAMED, and the diff-against-state method is what
      exposed it: `exportPresetImpl` never wrote EIGHT of the fields it declares — `sphRestDensity`,
      `sphStiffness`, `sphViscosity`, `sphSubsteps`, `rdFeed`, `rdKill`, `rdDeposit`,
      `rdFieldForce`. `PresetSettings` zero-initializes, so every preset ever saved serialized 0 for
      all eight and reloaded them clamped up to their range minimums. Chemistry was not merely
      missing a schema field: the two fields it does have were being written as zeros. Under one
      world those two ARE chemistry's coupling strengths, so a save-then-load turned chemistry off.
      Fixed, and the round-trip test now covers the whole settings record rather than a remembered
      subset.
- [x] 9.2 `web-ui/src/components/Panel.tsx`: delete the mode selector. What replaces it is a preset
      row whose entries are NAMED POINTS in the one world's parameter space — the same instrument as
      the reaction-diffusion regime buttons, one dimension up. A preset sets strengths; it does not
      select a world. Names are free to describe what the point feels like; they must not read as a
      list of world types, which is the mode returning under a nicer label.
- [x] 9.3 `src/web_api.nim:277-281`: make the count clamp non-destructive — drop the
      `triggerParticleReinit()` call so survivors keep their positions, velocities, and species.
      DROPPING THE CALL IS NOT ENOUGH, and that is the correction worth carrying. Particles live on
      the GPU with no readback, so the CPU staging array is stale for anything the simulation has
      moved: growing the count and re-uploading the whole array snaps every living particle back to
      its startup position — a harder reset than the reinit being removed. `app.resizeParticles`
      seeds only the arrivals and `webgpu_compute.uploadParticleRange` writes only that tail at its
      byte offset; shrinking uploads nothing at all. Reached through a new `onResizeParticles` hook
      beside the existing ones, since web_api cannot import the executor.
      THE SPECIES COUNT STILL REINITIALIZES, deliberately: changing how many species exist changes
      what every particle's species index means, so there is no population to preserve.
- [x] 9.3a `src/web_api.nim:543-562`: apply the ceiling on the preset path, which today applies none.
      `pasMode` sets `activeSimKind` directly rather than through the couplings-entry path, and
      `pasParticleCount` writes the preset's count validated against the slider bounds only — so a
      preset can leave a capped world above its ceiling. The Nim-constructed starters clamp their own
      counts (`src/web_api.nim:704-707`), which covers shipped presets and not user-saved ones; that
      workaround retires with this task.
- [x] 9.4 **DRY collapse, per D11.** Each row is one fact currently stored more than once; each is
      done when only one name for it survives.
      - Retire `RD_GLOW_DENSITY_FLOOR` (`src/field_core.nim:99-106`) and its use at
        `src/webgpu_render.nim:1294-1300`. Real density returns because density accumulation is
        world-intrinsic under D12 and therefore always runs — NOT because forces always run, which
        under D7 they do not.
      - Collapse `SPH_PARTICLE_CEILING`, `RD_PARTICLE_CEILING` and `COUPLING_PARTICLE_CEILING` into
        one budget, and delete the `doAssert` at `src/config_ranges.nim:337` that held them equal —
        an assertion keeping two constants in step is a duplication with an alarm on it, not a safety
        property. The surviving NUMBER is group 10's to measure; this task is the collapse only, and
        must say in a comment that the value is inherited and unmeasured until group 10 replaces it.
      - Delete the `"Stripes"` starter at `src/web_api.nim:869`, which is `RD_REGIMES`'
        `"Labyrinth"` (`src/config_ranges.nim:131`) under a second name. **DECIDED: Labyrinth
        survives.** Starters reference the regime table rather than restating its coordinates.
      ALL THREE DONE. The budget is `PARTICLE_BUDGET` in config_ranges; `SPH_PARTICLE_CEILING` and
      `RD_PARTICLE_CEILING` are deleted from sph_core and field_core rather than left as aliases.
      Starters are now built by iterating `RD_REGIMES`, so there are six rather than three and each
      carries its own `minDeposit` floor — without which worms and coral load a blank field.
      A FOURTH COLLAPSE THE TASK DID NOT LIST, found by 9.0e's grep: the descriptor GROUP ids
      `"particle-life"` and `"sph"` were mode names on control sections. Renamed to `"species"` and
      `"fluid"`, which describe what they group. That is the last mode-shaped name in the live model,
      and 9.0e goes red if one returns.
      TWO MIRRORED CONSTANTS HAD ALREADY DRIFTED, both caught by a new test rather than by reading:
      `preset.nim` carried `fieldOpacity: 0.85` against colormap_core's 1.0 (group 6.5 moved the
      authority and not the mirror), and this group's own `climateSpeed: 1.0` against climate_core's
      0.25. `tests/test_preset.nim` now asserts every mirrored default equals its owning module, so
      the next drift fails instead of shipping.
      OVERTAKEN IN PART BY DESIGN D16: `PARTICLE_BUDGET` is itself deleted — the collapse this
      task performed was right, and its surviving number was struck by the user before group 10
      measured it. Count bounds derive from `PARTICLE_COUNT_MAX`, the allocation capability.
- [x] 9.4a **Two weather loops become one, per D11.** `climate_core`'s tour is written against the RD
      regimes specifically; the C family proposes a second loop of the same shape over force
      parameters. Generalise `climate_core` to a parameterised tour over a waypoint table — the RD
      regimes being one such table — so the second weather adds a table and no second loop. The two
      guarantees the module already proves (in-range by convexity, continuity at every handover) must
      carry over unchanged and stay proven by the existing sweep tests.
- [ ] 9.5 Run `./main`. Four things, and the first two are what the whole group is for: dragging
      moves particles while chemistry is running; turning a coupling's strength to zero and back
      changes nothing but that coupling; a preset saved before this change still loads; and the
      control set never changes shape while any of that happens.
- [x] 9.5a **The two documents that teach the deleted model follow the break.** Both are accurate
      about today's code, which is why they are a task here rather than an earlier edit — and both
      become false the moment 9.0c lands.
      - `docs/one-world.md` does not merely describe the boolean couplings, it ARGUES for them
        ("This is why the couplings are booleans rather than an enum"), in the guide whose stated bar
        is that someone can add a fourth coupling from it alone. Its frame-order section and its
        `setActiveSimKind`/`couplingsFor` wiring walkthrough go with it.
      - `CLAUDE.md` states the three booleans, that "All eight combinations are meaningful" —
        enumeration language this change forbids — that `SimKind` survives as a compatibility layer,
        and that `controlGroupsFor` relates dispatches to controls. It is the first thing every
        future session reads, so a stale model here propagates further than anywhere else in the
        repo.
      Rewrite both for strengths and the world-intrinsic / coupling-owned split. **Tasks 11.2 and
      11.3 are marked complete and their records claim no stale reference survives; those records
      describe the boolean era they were written in and do not cover this.**
- [x] 9.6 Bump `particle_garden.nimble` to `2.0.0`. **AUTHORIZED.** The user confirmed the bump
      together with the group. It is breaking because the mode selector is removed, not because
      presets stop loading — they do not.
- [x] 9.7 `just happen` and `just check` green.

## 10. Performance budget (S8)

- [ ] 10.1 Measure with `gpu_profiler` timestamps, on ≥90 s settled runs, against the A0 baseline
      (physics 5.7–7.2 ms, ~9.3 ms total GPU at 128k settled; physics roughly quadruples as clusters
      form). Three numbers, not two:
      - Forces with chemistry, and forces with fluid and chemistry as the worst case.
      - **The INTRINSIC FLOOR: a world with every coupling strength at zero.** Under D12 that still
        dispatches the grid triad, density accumulation, the field's evolution substeps, and
        integrate — so this is the cost no setting can avoid, and D12's cost paragraph promises this
        number rather than an estimate. Task 9.0c2 measures the density half and hands it here.
      - **The particle budget** that replaces the three collapsed ceilings. 9.4 collapses them and
        records the surviving value as inherited and unmeasured; this task is where it stops being
        inherited. The user wants the chemistry cap raised toward `MAX_PARTICLES` (128000,
        `src/memory_layout.nim:48`) — the measurement decides whether it goes there or short of it.
        OVERTAKEN BY DESIGN D16: the user struck every cap below capability, so the count bound is
        `PARTICLE_COUNT_MAX` and no measured budget replaces it. The measurement itself still
        runs — its numbers inform defaults and the perf report, never a ceiling.
- [ ] 10.2 If the deposit splat dominates, shrink the kernel or lower the field substep count before
      touching particle count. Note the known gap: bloom passes carry no timestamps
      (`webgpu_render.nim beginBloomPass`).
      PARTIALLY OVERTAKEN BY MEASUREMENT: the substep count is NOT the free lever this task
      assumes. Lowering it unscaled raises deposit per unit of field time and dissolves the
      ignition-coherence property (measured at 3: a scattered deposit ignited on frame 6, the
      critical radius fell 5 → 3, the single-cell control lit the field). The fold now
      renormalizes per field step (`RD_DEPOSIT_FRAME_SCALE`, commit 27e0307), which makes the
      knob safe; a fully green substeps-3 configuration was built and then REVERTED by user
      decision — evolution speed wins. Remaining sanctioned levers: `FIELD_PATTERN_SHRINK`
      (chemistry lives in cell space) and whatever 10.1's profiling convicts.
- [x] 10.5 Rule on deposit-vs-population normalization, then implement the ruling. Reported by a
      delegate and spot-verified against source, UNVERIFIED BY THE LEAD beyond that: per-cell
      deposit drive is linear in particle count — the splat deposits per particle with no count
      term anywhere (`field-deposit.wgsl`, the uniform write in `webgpu_compute.nim`) — so
      halving the population halves the field's drive and thins patterns at fixed wavelength.
      The candidate fix scales the deposit uniform by a reference count over the live count,
      which changes the Secretion Rate slider's MEANING from per-particle to per-population;
      pinning the reference at the shipped default count keeps default-count behaviour
      byte-identical. That meaning change is the user's ruling to make. Confound to separate
      first: dot size also grows as population thins, via the render density term.
      RULED BY THE USER (2026-07-29): deposits stay per-particle. Halving the population
      halving the field drive is accepted behaviour, not a defect. The candidate
      population-normalization (deposit uniform scaled by reference/live count, reference
      pinned at the shipped default) was declined because it changes the Secretion slider
      meaning from per-particle to per-population. The dot-size confound the task names
      (render density term growing dots as population thins) stands recorded and untouched.
      Implementing the ruling requires no code change. 10.6 note stands: the ignition-harness
      constant keeps its current calibration since areal drive stays population-dependent.
- [x] 10.6 Recalibrate the ignition harness's coverage constant. Reported by the same delegate:
      `HARNESS_DEPOSIT_COVERAGE` still models ~6% cell coverage of the retired 512x512 field;
      the shipped field gives ~0.7% at the same population, so the harness measures at roughly
      9x the real per-cell drive, and the recorded ignition constants (splat radius, default
      deposit) inherit the inflation. Verify the arithmetic, re-measure ignition at faithful
      coverage, and update the constants' recorded observations — or record why the inflation
      is deliberate headroom.
      VERIFIED AND RECORDED, lead-run. Arithmetic confirmed: 2048x1152 = 2,359,296 cells;
      16000 particles occupy at most 0.678% (1 in ~147) against the harness's 1 in 16 —
      9.2x areal inflation, exactly as reported. New fact the delegate could not have had:
      after the 32000-cap removal the 128000 maximum occupies ~5.4%, so 1-in-16 now models
      the densest legitimate population almost faithfully. Re-measured as asked: at 1/9.2 of
      the harness drive the shipped radius/deposit pair does NOT ignite (probe run and
      deleted; frame count -1). Ruling per consumer, now written on the constant itself:
      negative and ceiling tests are a-fortiori conservative under inflation; comparative
      tests normalize totals so coverage cancels; the positive ignition observations depend
      on the inflated global rate and their real-world warrant is per-nucleus — the splat
      kernel plus colony density, confirmed in-app under 4.3 — not areal coverage. The
      constants' recorded observations stand under that reading. Both stale 512x512 comments
      in the harness now say "retired". If 10.5 lands population-normalized secretion, areal
      drive becomes population-invariant and this constant is recalibrated in that change.
- [ ] 10.3 If Fluid Chemistry is over budget, lower that preset's default particle count. Do not
      remove the coupling combination (design D7).
- [ ] 10.4 Record the numbers in `docs/perf-report.md` beside the existing baseline.

## 11. Calibration and documentation (S9)

- [ ] 11.1 One deliberate pass over the blind constants under the new couplings: `SPH_FORCE_SCALE`,
      the field deposit and force couplings, `fieldOpacity`, colormap gains, the two-tone ramp, plus
      the new splat radius, field-light strength, gradient-displacement scale, tropism bound, and
      drift speed. Every constant touched gets a doc comment naming what was traded against what.
- [x] 11.2 `docs/one-world.md` (new): the couplings model — what a coupling is, why delta-buffer
      ownership moved, how to add a fourth coupling, and the frame for each preset. Write it so
      someone can add a coupling from this document and the source alone.
      Written to the task's own bar — someone can add a coupling from this document and the source alone —
      and the one place it CANNOT meet that bar is stated in the document rather than written around:
      `setCouplings` accepts any triple, but its only caller maps a legacy `SimKind` through
      `couplingsFor`, and the panel offers the same three. A fourth coupling can be built, dispatched
      and tested, and still has no user-facing switch until the panel exposes couplings directly. The
      guide names the two honest stopgaps instead of implying a path exists.
      Every symbol the guide names was checked to resolve in `src/` or `tools/`. That check caught one
      real error before it shipped: the bind-group step pointed at `expectedBindGroupEntries`, which
      does not exist — the function is `getExpectedEntryCount`, and it returns -1 for an unregistered
      key, which is how a pipeline with no count announces itself. A guide that sends a reader to a
      nonexistent function fails its bar at the first step that matters.
      Also carries the measured facts that change how a reader would reason: collapse living in the
      PRODUCT of tropism and deposit, Gray-Scott saturating against amplitude but not concentration,
      three of six regimes being deposit-sustained by nature, and coherence rather than magnitude
      being what ignites the field.
- [x] 11.3 Update `CLAUDE.md`: the three-mode model, the RD pass list, the reference-oracle table,
      and the module inventory are all changed by this work. Grep for `skReactionDiffusion`,
      `buildFrame`, `RD_GLOW_DENSITY_FLOOR`, and `setActiveSimKind` and confirm no stale reference
      survives.
      Verified zero surviving references to `skReactionDiffusion`, `skParticleLife`, `skSph`,
      `setActiveSimKind` and `RD_GLOW_DENSITY_FLOOR`. The last of those was never in CLAUDE.md and was
      deliberately NOT added: it retires in 9.4, and documenting it now would ship a line already
      scheduled to be wrong.
      Rewrote the pipeline section around couplings, added the delta-buffer ownership invariant with
      the accumulate-never-store rule, replaced the three fixed pass lists with the order a frame
      composes in, corrected the opening description and the gardenAPI boundary paragraph, added
      `climate_core` and `camera_core` to the module inventory, and added `camera_core` to the
      reference-oracle table (`climate_core` is noted beside it as pure and natively tested but
      mirroring no shader, so it does not belong in that table).
      THE RENDER-PATH BINDING HAZARD is documented in the shader section where an editor will meet it,
      not only in this file: `render.wgsl` and `glow.wgsl` share one bind group layout, nothing checks
      the layout, the entries and both shaders' `@binding` numbers against each other at compile time,
      and `just happen` and `just check` both pass green while the app draws nothing. The compute path
      has `EXPECTED_BIND_GROUP_ENTRIES_*`; the render path has no equivalent.
- [x] 11.4 Update `tests/README.md`'s per-file table and architecture tree with every test module
      added by this change.
      Added `test_climate_core` to the table and the tree. Checked the three camera entries rather than
      trusting them — table rows, tree lines and the reference-oracle sentence are all accurate, and
      `camera_core` belongs in that sentence because it does mirror `camera_transform.wgsl`.
      Updated the descriptions group 5 and group 8 outgrew: `test_field_core` (species chemistry, the
      chemotactic-collapse bound, the regime deposit floor), `test_param_descriptor` (chemistry fields
      and notch reachability), `test_gpu_types` (WGSL offset agreement), `test_sim_registry` and
      `test_shader_manifest` (couplings rather than modes), and the TypeScript line (mode gating and
      notch snapping). No pass count is recorded anywhere — the file already tells the reader to run
      the suite instead, which is the right call and stays right.
- [ ] 11.5 `openspec validate one-world`. **Validate only — never archive.** Archiving folds a
      change's deltas into `openspec/specs/`, the specification of what the application actually
      does, and doing it here would write unimplemented SHALLs into the app spec as though they were
      true. No task in this file archives; the user decides when to fold, and does it themselves.
      See "Order of work".
- [ ] 11.5a **Staged capability sync, under one rule: a capability syncs only when every requirement
      in its merged delta is implemented and verified.** `/opsx:sync` is agent-driven — it reads
      delta specs and edits the main specs directly, merging at requirement granularity rather than
      copying a change wholesale — so a capability whose delta is complete can land in the baseline
      without waiting for the rest.
      Sync at this point only the capabilities whose deltas come from this group's work alone.
      The capabilities fed by more than one source wait for their last contributor, or the baseline
      claims something no code does.
- [ ] 11.6 `just happen` and `just check` green.

---

# C. Crowding and scale

**Every task DECLARED in this section carries an implicit `C` prefix.** The checkbox line `- [ ] 1.9` below is C1.9. The numbers are namespaced rather than renumbered on fold-in, because renumbering rewrites every internal cross-reference and this file's whole discipline is that a number, once written, does not move. The decisions these tasks implement are the C-family in `design.md`.

**Citations do not inherit the prefix — they carry it.** A reference to C1.9 is written `C1.9` even here inside the C section, and an unprefixed `task 9.4a` or `group 9` means the bare family. See "Order of work" for why the rule runs this way.


These groups are sequenced after the bare-numbered groups (see the proposal, Sequencing). C0
verifies the prerequisites instead of assuming them. C1 and C2 are independent of each other;
C3 needs C2's fraction; C4 needs the generalised tour task 9.4a creates. The
default order is C1 → C2 → C3 → C4, but C2 → C3 may run before C1 — nothing in the fluid work reads
the crowding term (design C6 keeps them independent by decision).

Two calibration gates cut across the groups, and both are ordering rules rather than suggestions:

- **The crowding default (C1.9) waits for the attraction-matrix recalibration.** A separate
  decision this session narrows the matrix bounds to ±0.100 with step 0.001; it is not yet on disk
  (`src/preset.nim:147-148` still reads ±1.0) [?]. The mechanism, its property tests, and a shipped
  default of 0 are safe to land first — the ceiling tests sweep bounds read from the constants, so
  they re-scope themselves — but a *non-zero* default measured against ±1.0 attraction would be
  tuned against forces about to shrink tenfold. Land the mechanism at default 0; measure the default
  after the matrix range is final.
- **The stiffness coefficient is measured before anything depends on it (C3 leads with the
  sweep).** Design C7's Courant form is a hypothesis until the sweep exists; no task below assumes a
  value for the coefficient.

## 0. Orientation and prerequisites

- [x] 0.1 Read `CLAUDE.md`, then `proposal.md` and `design.md` (C0–C7 are settled; you build and
      measure, you do not re-derive them), then design D7, D11, D12, D13, and D14.
      Read as part of this session's workflow orientation: CLAUDE.md, proposal.md, design.md C0-C7
      and D7/D11/D12/D13/D14.
- [x] 0.2 Confirm the toolchain: `just happen` and `just check` green on a clean tree before
      changing anything. A pre-existing failure is the first task, not a thing to work around.
      Preflight gate ran just happen and just check green on a clean tree before any C-family edit.
- [x] 0.3 Verify the strength collapse has landed through group 9: `WorldCouplings` is a strength
      vector (no booleans, no `couplingsFor` in `src/sim_registry.nim`). D14 settles what the fluid
      strength is: a multiplier of its own over the pass's whole velocity contribution — stiffness
      was not promoted, since the XSPH/viscosity smoothing carries no stiffness factor
      (`forces-sph.wgsl:254-255`) and D12 requires a strength to scale the entire output. C3's
      derived ceiling therefore applies to a stiffness slider that carries pressure gain alone, and
      the fluid strength's range includes zero under D13; the tasks below read the bounds from the
      constants. Confirm the legacy decode branch from D8's translate-at-decode boundary exists
      (the versioned branch task 9.1a's schemaVersion bump creates) — C1.8 and C2.5 pin values
      inside it. Then check whether task 9.4a's parameterised tour exists (`src/climate_core.nim`
      advancing a waypoint table rather than the RD regimes specifically). If the tour does not
      exist, C4 is BLOCKED and every other group can proceed — do not write a second loop
      under any circumstances.
      Verified by preflight grep: WorldCouplings is a strength vector with no couplingsFor in
      src/sim_registry.nim; the schemaVersion-branched legacy decode exists in src/preset.nim; the
      parameterised tour from 9.4a exists in src/climate_core.nim.
- [x] 0.4 Check whether the attraction-matrix recalibration has landed:
      `grep MATRIX_VALUE src/preset.nim`. This gates C1.9 only.
      Checked at preflight: the matrix recalibration (±0.100) had not landed at C-family start — it
      lands with E6.4 later in this same workflow — so C1.9 stays gated and the mechanism ships at
      default 0.
- [x] 0.5 **No check needed: the ordering is now fixed, and it runs this family first.** "Order of
      work" puts C0–C5 ahead of the E family, so no probe machinery exists yet and no descriptor
      added here can carry a response probe. The obligation does not vanish, it inverts: E3's sweep
      is total over the descriptor table, so every descriptor this family adds is swept when the E
      family runs, and each will need a probe or a written exemption then. Add them here knowing
      that, and leave `ParamSlider.tsx` alone — travel metrics belong to E.
      One task escapes this order: C1.9's non-zero crowding default waits on the matrix
      recalibration in E6.4, as "Order of work" records.
      Acknowledged: no probe machinery exists yet; every descriptor this family adds is swept when
      E3 runs and will need a probe or written exemption there. ParamSlider.tsx left alone by this
      family except where a C task names it.

## 1. Bounded crowding

Leads with the oracle tests; the shader follows. The spec is `specs/bounded-crowding/spec.md`.

- [x] 1.1 `tests/test_physics.nim`: add `attenuation is identity at zero density`, `attenuation is
      monotone decreasing in density`, `strength zero reproduces the unattenuated force exactly`,
      and `the attenuation commutes with force strength` (attenuated force at `fMul = k` equals `k`
      times the attenuated force at `fMul = 1`), against a new
      `crowdingAttenuation(density, strength)` in `src/physics_core.nim`. Expected: red until 1.2.
      Added suite "Crowding Attenuation" to tests/test_physics.nim with the four named tests plus
      two the spec requires — `repulsion survives the crowd` (repulsion zone and negative matrix
      entries unattenuated at every density and strength) and `attenuated attraction matches the
      closed form`. Watched red: `Error: undeclared identifier: 'crowdingAttenuation'` at
      test_physics.nim:123. Sweeps run over densities [0, 0.5, 1, 5, 20, 100, 400] and strengths
      [0, 0.25, 1, 2].
- [x] 1.2 `src/physics_core.nim`: implement `crowdingAttenuation` as
      `1.0 / (1.0 + strength * ln(1.0 + density))`, and an attenuated force variant that scales ONLY
      attractive contributions — the attraction-zone term when its matrix entry is positive
      (`src/physics_core.nim:54-58`); the repulsion zone (`:51-53`) and negative matrix entries stay
      untouched at every density. 1.1 goes green.
      src/physics_core.nim gained `crowdingAttenuation(density, strength) = 1/(1 + strength*ln(1+density))`
      and `calculateAttenuatedForce(normalizedDistance, attr, fMul, invD, density, crowdingStrength)`,
      which multiplies the attenuation in only when `normalizedDistance >= 0.3 and attr > 0.0` — the
      attraction zone entered with a positive matrix entry. The attenuation is applied AFTER fMul so
      the result at force strength k is exactly k times the result at 1 (design C0). All six tests
      went green.
- [x] 1.3 `tests/test_physics.nim`: add `a density ceiling exists` — a companion
      `densityCeiling(attr, fMul, strength)` is finite for every reachable combination swept from
      `FORCE_STRENGTH_MIN/MAX` (`src/config_ranges.nim:37-38`), `MATRIX_VALUE_MIN/MAX`
      (`src/preset.nim:147-148`), and the crowding range — read from the constants, never restated,
      so a later recalibration re-scopes the sweep — and `the ceiling decreases monotonically in
      crowding strength`. D13 puts force strength zero inside the swept range: include
      the endpoint and assert the ceiling degenerates there (design C0's vacuous case) rather than
      excluding it. Expected: red until 1.4.
      Added suite "The Density Ceiling" with `a density ceiling exists`, `the ceiling decreases
      monotonically in crowding strength`, `the ceiling degenerates at force strength zero`, and a
      fourth the C0 argument earns — `the ceiling is the same at every non-zero force strength`.
      Bounds are read, never restated: MATRIX_VALUE_MIN/MAX from src/preset.nim (still +/-1.0 — the
      recalibration has not landed, so C1.9 stays gated), FORCE_STRENGTH_MIN/MAX and
      CROWDING_STRENGTH_MIN/MAX from src/config_ranges.nim, swept at 7/5/6 points. Watched red on
      `undeclared identifier: 'CROWDING_STRENGTH_MIN'`.
- [x] 1.4 `src/physics_core.nim`: implement `densityCeiling` — the density at which attenuated
      attraction no longer exceeds repulsion at the equilibrium separation. Beside it, state the
      claim's scope as the spec requires: equilibrium not transient, same-species signal
      (`web/shaders/src/forces.wgsl:333`) so the per-cell bound carries a `MAX_SPECIES` factor, and
      attraction-only — the mouse, the blast, and positive tropism sit outside it.
      src/physics_core.nim gained `densityCeiling(attr, fMul, strength)`, bisecting the crossing
      where attenuated attraction stops exceeding the repulsion a crowd's own packing supplies;
      `packingSeparation` and `CROWD_PACKING_CONSTANT = 2*PI/(3*sqrt(3))` derive the separation from
      the density signal (the (1-r) weight integrated over a hexagonally packed crowd), and
      `REPULSION_ZONE_END` is derived from INV_03 rather than written twice. Force strength cancels
      from both sides and appears only to report the vacuous case: fMul == 0 returns 0.0, attraction
      concentrates nothing at any density. Measured anchors: the equilibrium packing density is
      13.44, and at attr 1.0 the ceiling falls 53.7 -> 33.0 -> 23.2 -> 18.4 as strength runs 0.25 ->
      0.5 -> 1.0 -> 2.0, approaching 13.44 from above. The scope note beside it states all four
      qualifications the spec demands.
- [x] 1.5 `src/config_ranges.nim`: `CROWDING_STRENGTH_MIN = 0.0` (zero is today's force law and must
      stay reachable), `CROWDING_STRENGTH_MAX` provisionally 2.0 pending 1.9's calibration, standard
      static assertions. `src/ui/api/param_descriptor.nim`: descriptor `crowdingStrength` in the
      same group as `forceStrength`, default 0.0 until 1.9, notch at 0 labelled "off".
      CROWDING_STRENGTH_MIN = 0.0 and CROWDING_STRENGTH_MAX = 2.0 (provisional, marked [?] pending
      C1.9) landed in src/config_ranges.nim beside FORCE_STRENGTH, with a non-empty-range assertion
      and a separate `MIN == 0.0` assertion carrying its own reason — crowding shapes the force law
      rather than gating a pass, so it stays out of the D13 coupling loop. Descriptor
      `crowdingStrength` sits in group "species" beside forceStrength, precision 2, default 0.0 from
      initSimulationState, one notch at 0 labelled "off" (no default notch, which would duplicate
      it). The task text names only config_ranges and param_descriptor, but a psSimulation
      descriptor is unreachable without its route, so config.nim, web_api.nim (mirror, getParam,
      setParam) and the Panel.tsx id list were wired in the same task — test_panel_reachability goes
      red otherwise. tests/test_param_descriptor.nim's three total tables gained their rows.
- [x] 1.6 `src/gpu_types.nim`: append `crowdingStrength` to `SimParamsLayout` and update the size
      assertions (`:456`) in the same edit; `src/webgpu_compute.nim` writes it through the generated
      index. `tests/test_gpu_types.nim` pins the new index like the others.
      `crowdingStrength` appended to SimParamsLayout at byte offset 248; the struct writes 252 bytes
      and still allocates 256, so no uniform grew or reallocated. Appended rather than folded into
      `_pad2` at 228, keeping every existing offset pointing where it did. webgpu_compute writes it
      through SIM_CROWDING_STRENGTH (index 62, SIM_PARAMS_F32_COUNT now 63); tests/test_gpu_types.nim
      pins the index, adds `the crowding slot follows the SPH block and closes the struct`, and the
      SPH-contiguity test now ends at `SIM_SPH_VISCOSITY == SIM_CROWDING_STRENGTH - 1` instead of
      claiming viscosity is last.
- [x] 1.7 `web/shaders/src/forces.wgsl`: multiply the attractive component in BOTH force models by
      the attenuation — the polynomial envelope and the exponential attraction term (`:93-96`) —
      gated to attractive sign, using the RECEIVING particle's smoothed density already on the
      particle struct (accumulated at `:333-339`, smoothed by `integrate.wgsl:85-93`); each side of
      the half-neighbour pair uses its own density. No new accumulator, no store, and the
      density accumulation itself is untouched — it is world-intrinsic under D12.
      web/shaders/src/forces.wgsl gained `crowdingAttenuation`, mirroring physics_core exactly, and
      both force models now scale their attractive component by it: `exponentialForce` takes an
      `attenuation` argument applied to `attraction * exp(-beta*r) * 2.0`, and both polynomial
      attraction-zone branches multiply by it. Every application is gated with
      `select(1.0, attenuation, attraction > 0.0)`, so a negative matrix entry — repulsive in the
      attraction zone — is untouched. Each half of the pair uses the density of the particle
      RECEIVING that half; this particle's is hoisted out of the neighbour loop, the other's is
      computed per pair. No new accumulator and no store in this task.
- [ ] 1.7a **Build the crowd-density channel here, where its consumer is.** The density 1.7 reads is
      COLONY density — species-gated at `web/shaders/src/forces.wgsl:333` — and the cap wants crowd
      density, species-blind, because the spatial hash a mixed blob fills costs exactly what a
      single-species one costs. Design's settled open question ("What does the density channel
      measure?") splits the two; the user moved the second channel from group 9 to here so it lands
      beside the code that reads it rather than doubling the hottest loop's density atomics for
      several groups with nothing consuming the result. Group 9 left the accumulator world-intrinsic
      and single-channel, which is exactly the shape this extends.
      Add the species-blind accumulation in the same neighbour loop, resolve it through
      `integrate.wgsl` the way colony density already resolves, and switch 1.7's attenuation to read
      it while the renderer keeps reading colony density. Measure the added atomic traffic against
      group 10's established baseline and record the number here. Restate the 1.4 scope note: the
      per-cell bound loses its `MAX_SPECIES` factor once the signal is species-blind, which is the
      point of the change.
      PARTIAL — code complete, measurement deferred. The species-blind crowd-density channel now
      runs beside the colony one: particle offset 28 became `crowdDensity`
      (PARTICLE_CROWD_DENSITY_OFFSET, previously padding, so the struct stays 32 bytes), forces.wgsl
      accumulates every neighbour at binding 7 into a new `crowdDensityDelta` buffer, integrate.wgsl
      resolves it at binding 5 with the same weight and the same temporal smoothing colony density
      gets, and the attenuation reads `crowdDensity` while the renderer keeps reading `density`.
      wgsl_lint's manifest, the two bind-group entry-count constants, sim_registry's
      `sbCrowdDensityDelta` clear, webgpu_init's buffer and gpu_types' ParticleLayout all moved in
      the same edit. The channel encodes at CROWD_DENSITY_FIXED_POINT_SCALE = 8192 (the same
      derivation sph_core makes from MAX_PARTICLES) rather than the 65536 velocity scale: a neighbour
      count reaching 128000 wraps an i32 at 65536, and a negative crowd density hands log(1+d) a
      negative argument, so the NaN would spread through every force in the frame. The 1.4 scope
      note is stated species-blind — the per-cell bound carries no MAX_SPECIES factor. DEFERRED: the
      atomic-traffic measurement against group 10's baseline was not taken (no profiling in this
      pass). Arithmetic only, not a measurement: density atomics per pair go from 1/S to 1 + 1/S, so
      at the shipped 4 species per-pair atomics rise from about 2.25 to 3.25 (+44%), plus one extra
      per-particle atomic closing the pass.
- [x] 1.8 `src/preset.nim`: schema field `crowdingStrength` with clamping against the
      `config_ranges` bounds, modelled on the pattern task 9.1a establishes (including its
      schemaVersion treatment), plus a round-trip test in the preset suite. In the legacy branch of
      the versioned decode (D8's translate-at-decode boundary), pin `crowdingStrength` to
      exactly 0.0 — today's force law — and test: `a preset saved before this change applies with
      crowding strength zero`, so no saved world gains a term it was not saved with.
      preset.nim carries `crowdingStrength` through PresetSettings, defaultSettings (0.0, mirroring
      initSimulationState), validateSettings (clamped against CROWDING_STRENGTH_MIN/MAX) and toJson,
      with web_api's snapshot and apply paths wired. The v1 legacy branch of `migrate` writes
      `settings["crowdingStrength"] = 0.0` unconditionally — pinned, not defaulted, so the non-zero
      default C1.9 measures cannot reach back into a saved world. The test `a preset saved before
      this change applies with crowding strength zero` puts a crowding strength of 2.0 INTO the v1
      fixture across all four legacy modes, so it fails without the pin instead of passing on the
      default happening to be zero; watched red on `undeclared field: 'crowdingStrength'`. A
      round-trip value (1.25) and a two-sided clamp test landed beside it. No schemaVersion bump: v2
      is this change's own unreleased schema, and C0.3 names the existing v1 branch as where C1.8
      pins.
- [ ] 1.9 GATED on the matrix recalibration landing (C0.4): with SPH off (design C6), measure
      the strength at which a collapsing single-species world visibly stops tightening and the
      strength at which ordinary colonies visibly soften, set the default between them and
      `CROWDING_STRENGTH_MAX` above the second, and record both measurements and their conditions —
      matrix bounds, force strength, particle count — beside the constants per the range authority's
      measured-bound rule. Add the default as a notch.
- [x] 1.10 `just happen` and `just check` green.
      `just happen` green (shader bundle, JS frontend, UI bundle, native binary), `just test` green
      at 698 passing native tests, `web-ui` bun test green at 41 passing. No generated output was
      hand-edited — web/app.js, web/ui-bundle.* and top-level web/shaders/*.wgsl stay out of the
      diff. Nothing committed; 26 files modified.

## 2. SPH scale

The spec is `specs/sph-scale/spec.md`. Independent of C1.

- [x] 2.1 `tests/test_sph_core.nim`: add `fraction one reproduces today's kernels` (both kernels at
      `h = R * 1.0` equal their values at `h = R`) and `kernel normalization holds across the
      fraction range` (the numeric-integration check the suite already runs — cited at
      `src/sph_core.nim:58-59` — swept at several effective radii). Expected: green immediately for
      the kernels (`sph_core` already takes `h` as a parameter, `src/sph_core.nim:11-13`); these pin
      the property the shader change relies on.
      tests/test_sph_core.nim gained suite "The Smoothing Radius Is A Fraction Of The Interaction
      Radius" with `fraction one reproduces today's kernels`, `kernel normalization holds across the
      fraction range`, and a third the spec's relative-scale scenario earns, `the fluid keeps its
      relative scale when the interaction radius moves`. Bounds are read, never restated:
      SPH_RADIUS_FRACTION_MIN/MAX and INTERACTION_RADIUS_MIN/MAX come from src/config_ranges.nim,
      swept at 7 fractions across 3 interaction radii (21 numeric integrations, 50,000 trapezoid
      steps, tolerance 1e-3), so raising either range re-scopes the sweep without a second edit. Two
      local helpers mirror forces-sph.wgsl:248-249's self-weight division, so the pressure and XSPH
      terms are compared rather than the raw kernels alone. Watched red on `undeclared identifier:
      'SPH_RADIUS_FRACTION_MIN'` — sph_core itself needed no change, which is what the task's "green
      immediately for the kernels" predicted.
- [x] 2.2 `src/gpu_types.nim`: append `sphRadiusFraction` to `SimParamsLayout`, update the size
      assertions in the same edit; `src/webgpu_compute.nim` writes it; `tests/test_gpu_types.nim`
      pins the index.
      src/gpu_types.nim's SimParamsLayout gained `sphRadiusFraction` at offset 252, appended after
      crowdingStrength for the reason crowding was appended (every write that exists keeps the
      offset it targets); totalSize moved 252 -> 256 while the WGSL allocation stays 256, so the
      struct now fills its allocation exactly and the next field costs a fresh 16-byte block.
      src/webgpu_compute.nim writes SIM_SPH_RADIUS_FRACTION from config.CONFIG.sphRadiusFraction, and
      tests/test_gpu_types.nim pins SIM_SPH_RADIUS_FRACTION == 63, SIM_PARAMS_F32_COUNT == 64, and
      the radius fraction as the slot that now closes the struct. The task named only gpu_types,
      webgpu_compute and test_gpu_types, but the writer cannot read a CONFIG field that does not
      exist, so src/ui/state/simulation_state.nim (sphRadiusFraction, default 1.0) and src/config.nim
      (field plus its createConfig mirror) landed in the same task.
- [x] 2.3 `web/shaders/src/forces-sph.wgsl:104`: `let smoothingRadius = params.interactionRadius *
      params.sphRadiusFraction;`. The one change site — everything downstream already takes the
      radius as a value.
      web/shaders/src/forces-sph.wgsl:120 now reads `let smoothingRadius = params.interactionRadius *
      params.sphRadiusFraction;`, the one change site, with the comment stating why the cap at 1
      makes an over-reaching smoothing radius unrepresentable rather than clamped: the sweep visits
      only the cell block around a particle and cells are sized to the interaction radius
      (src/grid.nim), so a larger kernel would silently drop neighbours. Everything downstream —
      radiusSq, both self-weights, both kernel calls at :248-249 — already took the radius as a
      value, so nothing else in the shader moved. Verified in the bundled output:
      web/shaders/forces-sph.wgsl carries the product and the regenerated
      web/shaders/modules/sim_params.wgsl carries the new field.
- [x] 2.4 `src/config_ranges.nim`: `SPH_RADIUS_FRACTION_MIN = 0.1` provisionally (strictly positive
      — record beside it that zero divides by zero in both kernel normalizations,
      `src/sph_core.nim:62` and `:82`, and that C3's notch sweep may raise this floor so every
      labelled stiffness notch stays below the minimum ceiling), `SPH_RADIUS_FRACTION_MAX = 1.0`
      exactly, static assertions. Descriptor `sphRadiusFraction` in the SPH group, default 1.0 until 2.6, notch at
      1.0 labelled "whole radius".
      src/config_ranges.nim gained SPH_RADIUS_FRACTION_MIN = 0.1 (provisional, marked [?], with the
      divide-by-zero reason recorded beside it — h to the 8th and 5th power in a denominator at
      src/sph_core.nim:62 and :82 — and a note that C3's notch sweep may raise it) and
      SPH_RADIUS_FRACTION_MAX = 1.0, under three static assertions: non-empty range, strictly
      positive floor with its own reason, and MAX == 1.0 so the smoothing radius cannot outrun the
      neighbour sweep. Both new assertions were watched firing, by temporarily setting MIN to 0.0 and
      MAX to 1.5. Descriptor `sphRadiusFraction` labelled "Fluid Scale" sits in group "fluid"
      directly after fluidStrength — ahead of the other three because it sets the neighbourhood they
      are measured in — precision 2, default 1.0 from initSimulationState, one notch at
      SPH_RADIUS_FRACTION_MAX labelled "whole radius". The task named only config_ranges and
      param_descriptor, but a psSimulation descriptor is unreachable without its route, so
      src/web_api.nim's CONFIG mirror, getParam and setParam were wired here and
      tests/test_param_descriptor.nim's three tables gained their rows; Panel.tsx needed no edit
      because it already loops groupIds("fluid").
- [x] 2.5 `src/preset.nim`: schema field `sphRadiusFraction` with clamping, same pattern and
      schemaVersion treatment as 1.8, plus a round-trip test. In the legacy decode branch, pin the
      fraction to exactly 1.0 — the kernel every saved fluid world ran when it was saved — and
      test: `a preset saved before this change applies with fraction 1.0`, not the shipped default.
      src/preset.nim gained `sphRadiusFraction` in PresetSettings, clamped at decode against
      SPH_RADIUS_FRACTION_MIN/MAX, serialized in toJson, and defaulted at 1.0 mirroring
      initSimulationState; the `fromVersion < 2` legacy branch pins it unconditionally to 1.0 beside
      C1.8's crowding pin, because 1.0 is the kernel every saved fluid world ran. Tests: `an
      out-of-range fluid scale clamps instead of rejecting` (4.0 and 0.0 clamp to the range ends),
      the fully-custom round trip now carries 0.35, and `a preset saved before this change applies
      with fraction 1.0` over four legacy modes with the fixture deliberately carrying 0.2, so the
      pin is what makes it pass. Watched that test go [FAILED] with the pin line removed, then
      restored. src/web_api.nim's save path (settings <- CONFIG) and apply path (simState <-
      settings) carry the field.
- [ ] 2.6 With crowding strength at 0 (design C6), measure the fraction at which the fluid reads as
      local incompressibility rather than large-scale organisation — sweep downward from 1.0 in the
      running app at the default interaction radius — set the default well below 1, record the
      conditions beside the constant, and notch the default. Release-note the new default for fresh
      worlds; saved worlds are untouched because the legacy decode pins 1.0 (C2.5).
- [x] 2.7 `just happen` and `just check` green.
      `just happen` exits 0: shaders bundled (forces-sph.wgsl and forces.wgsl rebundled,
      sim_params.wgsl regenerated), JS frontend, UI bundle and native binary all built. The native
      suite `just test` exits 0 with 703 [OK] lines and no failures, and `web-ui` `bun test` reports
      41 pass / 0 fail. The full `just check` gate is left to the integrator per this group's
      handoff, so what is recorded here is the build plus both suites run once at the end of the
      group.

## 3. The stiffness ceiling becomes derived

Needs C2. The coefficient is MEASURED first; nothing below assumes a value for it. The specs
are `specs/sph-scale/spec.md` (the function) and `specs/parameter-range-authority/spec.md` (the
representation: envelope constants untouched, a registered ceiling function, and an effect-time
clamp at the CONFIG mirror — the stored value is never destroyed).

- [x] 3.1 `tests/test_sph_core.nim`: build the stability sweep — a small N-particle harness
      mirroring `forces-sph.wgsl`'s density/pressure/XSPH loop and `integrate.wgsl`'s friction and
      velocity cap, the same pattern as `test_field_core.nim`'s chemotactic-collapse harness
      (task 5.5, complete). Sweep stiffness against radius fraction and substeps at the default
      timeScale and interaction radius; a run diverging (velocity or density going non-finite)
      marks the boundary. Then check the Courant scaling — boundary ∝ `(h * substeps)^2` — predicts
      the measured boundary at two other (timeScale, interactionRadius) points; if it does not, the
      derived function of 3.2 takes those as inputs too, and the deviation is recorded beside it.
      tests/test_sph_core.nim gained the stability harness: 101 particles in a periodic box 4
      smoothing radii across, seeded at twice rest density (the compression forces-sph.wgsl clamps
      its Tait input at), running that shader's density/pressure/XSPH loop and integrate.wgsl's
      friction, log soft cap and wrap, substepped the way webgpu_compute steps them. DIVERGENCE IS
      UNREACHABLE and that is by design in the shader — the Tait input, the per-pair acceleration
      and every speed are all clamped — so the boundary is measured as "the seeded compression stops
      coming to rest" (residual RMS speed above 0.5 px/frame after 120 frames), with the non-finite
      check kept as the guard it is. Bisected boundaries, at the shipped defaults and fluid strength
      1.0: 22.02 at h=50/1 substep/timeScale 0.5, 72.20 at 3 substeps, 56.14 at h=150, 110.15 at
      timeScale 0.1, 2.20 at timeScale 5.0, 47.41 at the default 2 substeps. Five tests ship the
      measurement; the module costs about 2.4 s.
- [x] 3.2 `src/sph_core.nim`: `stableStiffnessCeiling(radiusFraction, substeps, dt)` — the Courant
      form with the fitted coefficient, clamped against `SPH_STIFFNESS_MAX` as the surviving
      absolute envelope — with the measurement's conditions and margin recorded beside the
      coefficient, plus the sweep's minimum ceiling over the reachable input box. Tests:
      `the derived ceiling sits below the measured stability boundary across the box`,
      `the ceiling never exceeds the stiffness envelope`, and `the ceiling is monotone increasing
      in radius fraction and in substeps`.
      src/sph_core.nim gained stableStiffnessCeiling(smoothingRadius, substeps, dt, envelopeMax) =
      min(envelopeMax, 0.0025 * h * substeps / dt), plus SPH_STABILITY_COEFFICIENT and
      SPH_CEILING_REFERENCE_FRAME_SECONDS (1/60) with the measurement's conditions, numbers and
      margin recorded beside them. THE COURANT SQUARE IS NOT WHAT THIS INTEGRATOR HAS: measured
      exponents are -1.00 in dt, 1.06 in substeps and about 0.86 in h (flattening below a few px),
      because both kernels are divided by their self-weight and integrate.wgsl advances position by
      the velocity itself rather than by velocity times dt, so one factor of 1/h and one of dt
      survive instead of two of each. 0.0025 sits a fifth below the smallest measured coefficient
      over the box (0.00312 at h=150), which the sublinear h-exponent then widens to about 4x at a
      narrow kernel. Four tests: at the ceiling the fluid settles across the box corners and the
      default, at eight times it does not, the ceiling never exceeds the envelope, and it rises with
      both fraction and substeps.
- [x] 3.3 `src/ui/api/param_descriptor.nim`: a `bound` variant on the descriptor — `bConstant` (the
      default; every existing descriptor unchanged) or `bDerived(ceilingId)` citing a registered
      pure ceiling function, growing the record by table the way `notches` (`:81`) already did.
      `clampParamValue` (`:378-384`) is NOT touched — store-time clamping stays against the
      envelope. `tests/test_param_descriptor.nim`: `every bDerived descriptor cites a registered
      ceiling`, and `every notch of a bDerived parameter sits below the minimum ceiling over its
      input box` (if this fails, raise `SPH_RADIUS_FRACTION_MIN` or move the notch — the floor
      decides the worst-case ceiling).
      src/ui/api/param_descriptor.nim gained ParamBound (bConstant, the zero value, or
      bDerived(ceilingId)) on the descriptor record, a ParamCeilingId enum registry with
      evaluateCeiling / ceilingName / ceilingReason / ceilingInputs / ceilingInputBox /
      minimumCeiling, and effectiveSimulation. The citation is an ENUM rather than a string, so an
      unregistered ceiling is unwritable and evaluateCeiling cannot miss a case — the compiler
      settles what a string table would need a test for; the shipped test therefore checks the
      substantive claim, that every bDerived citation evaluates to a positive number inside its own
      envelope over the whole input box. clampParamValue is untouched. sphStiffness is the one
      bDerived descriptor and gained a hint naming the three controls that move its ceiling. Served
      ceilings: 30.0 at the shipped default (envelope 40), 15.0 at 1 substep, 40.0 at 3, 3.0 at
      fraction 0.1 or timeScale 5.0; minimum over the box 0.03.
- [x] 3.4 `src/web_api.nim`: the effect-time clamp — the CONFIG-mirror write for a `bDerived`
      parameter lands `min(stored, ceiling(live config))`, recomputed in the same tick whenever the
      stored value or a ceiling input changes, under the synchronous-mirror invariant `web_api.nim`
      documents. The stored value is never modified. Tests: shrinking the fraction drops the
      effective stiffness; restoring it restores the stored value's full effect, with no
      hysteresis.
      src/web_api.nim's applySimulationToConfig now mirrors effectiveSimulation(storedState) rather
      than the stored record, so CONFIG carries what the frame runs and currentSimulation keeps what
      the user chose. Two reads had to follow: getParam("sphStiffness") and the preset snapshot now
      take currentSimulation, or the slider handle would slide on its own when another control moved
      and a re-save would ratchet the stored value down by this world's ceiling every time.
      Recomputed on every write rather than only when stiffness moves, because a ceiling INPUT moving
      is the usual cause. Six native tests in test_param_descriptor.nim cover the pure core: the
      fraction dropping the effective value, restoring it returning the stored one exactly with no
      hysteresis, substeps and time scale each moving it alone, constant-bound parameters passing
      through, and the shipped default never being clamped at any substep count.
- [x] 3.5 Preset path: NO apply-step change, and record why where the effect-time clamp lives.
      `presetApplySteps` applies every scalar in one `pasScalars` step
      (`src/ui/presets/preset_store_core.nim:76-80`), so no ordering among scalars exists to
      reorder — and none is needed: the effective value is computed from the final live config
      after the apply lands, not during it, so store order among scalars is irrelevant to this
      bound. Test in the preset suite: a preset carrying envelope-max stiffness with a small
      fraction round-trips its stored stiffness intact while its effective stiffness is the ceiling
      its own fraction and substeps imply.
      No apply-step change, recorded where the effect-time clamp lives (web_api.applySimulationToConfig's
      docstring): presetApplySteps writes every scalar in one pasScalars step, so no ordering among
      scalars exists to get wrong, and none is needed since the effective value is computed from the
      final state after the apply lands rather than during it. tests/test_preset.nim gained three
      tests — a preset carrying envelope-max stiffness with the minimum fraction and one substep
      round-trips 40.0 and 0.1 intact through toJsonString/parsePreset; the state that preset applies
      to runs at its own derived ceiling while the stored value stays 40.0; and passing a state
      through effectiveSimulation leaves the stored record untouched, which is what stops a re-save
      baking in the ceiling.
- [x] 3.6 `web-ui/src/`: `ParamSlider.tsx` renders the envelope with the segment above the live
      ceiling drawn dormant, carrying the reason ("above the stable ceiling at the current fluid
      radius and substeps"); the live ceiling arrives on the existing stats push
      (`gardenAPI.onStats`, `src/web_api.nim:989-990`), never a second channel;
      `web-ui/src/garden-api.ts` gains the bound-variant field. TypeScript restates no number.
      The dormant region this ceiling creates is handed forward rather than measured here (C0.5):
      when E's travel metrics arrive they evaluate over `[min, ceiling(default config)]`, with an
      assertion that the region above the ceiling is inert.
      web-ui/src/lib/bounds.ts (new) computes dormantShare(ceiling, min, max) — null when the whole
      track is live or no ceiling has been pushed, 1 when the ceiling sits at or below the minimum —
      with five bun tests. ParamSlider.tsx draws the band above the live ceiling with a hatched
      overlay and prints Nim's own reason beneath the label; the ceiling arrives keyed by parameter
      id on the existing gardenAPI.onStats push (never a second channel), state.ts holds it in a
      ceilings store applied by comparison, and garden-api.ts gained the ParamBound union and
      StatsSample.ceilings. TypeScript restates no number and authors no reason — ceilingReason is
      served from Nim. The forward hand-off C3.6 asks for sits in web_api's pushStats comment: E's
      travel metrics evaluate stiffness over [min, ceiling(default config)] with the region above the
      ceiling asserted inert. Visible consequence at the shipped default: the top quarter of the
      stiffness slider (30 to 40) renders dormant, and it goes fully live at 3 substeps.
- [x] 3.7 `just happen` and `just check` green.
      just happen exits 0 with shaders rebundled (forces-sph.wgsl now takes SPH_FORCE_SCALE and
      SPH_MAX_PRESSURE_ACCEL as placeholders), JS frontend, UI bundle and native binary all built.
      just test reports 727 [OK] lines and 0 failures (up from 703; the suite grew from about 8 s to
      12 s, the harness accounting for roughly 2.4 s of that), and web-ui bun test reports 50 pass /
      0 fail (up from 41). The full just check gate is left to the integrator per this group's
      handoff. No generated output was hand-edited and no shader binding moved, so wgsl_lint's
      manifest is untouched.

## 4. Force weather

BLOCKED until task 9.4a's parameterised tour exists (C0.3). The spec is
`specs/weather/spec.md`, which covers both tours — the chemistry regimes and the force parameters
are two waypoint tables for one loop. This group adds a TABLE, never a loop.

- [ ] 4.1 Choose the waypoints by watching, and record how: sweep candidate settled configurations
      over the force parameters (candidate axes: `forceStrength`, `interactionRadius`, `friction`,
      `ruleTemperature`; the crowding strength from C1 is deliberately NOT toured — the cap is
      a floor under the weather, not part of it), pick four to six worth watching, and record the
      selection criteria beside the table. If C1's default is not yet calibrated, choose
      waypoints at crowding strength 0 and note that beside the table.
- [ ] 4.2 `src/config_ranges.nim`: `FORCE_WEATHER_WAYPOINTS` beside the ranges its coordinates must
      satisfy, with a static in-range assertion over every axis — the same construction as
      `RD_REGIMES` (`:131`), for the same reason: a waypoint outside a range fails the build.
- [ ] 4.3 `tests/test_climate_core.nim`: register the force table with the generalised tour's sweep
      tests, so `in-range by convexity`, `continuity at every handover`, and `no step exceeds the
      configured maximum delta at the maximum offerable speed` all run per-table over the same
      advance implementation. Expected: green if 9.4a generalised correctly; a failure here is a
      finding about 9.4a, not about the table.
- [ ] 4.4 `forceWeather` toggle and `forceWeatherSpeed` (tours per minute, wall-clock, off by
      default) in `src/ui/state/` sim config, `src/config_ranges.nim`, the descriptor table, and the
      preset schema with clamping and a round-trip test — the same four sites the climate's pair
      already occupies. These two need NO legacy-decode pinning — off is both the shipped default
      and the value that preserves a saved world — and a comment beside the decode branch says so,
      so nobody adds a pointless case; only fields whose default differs from the preserving value
      (1.8, 2.5) are pinned there.
- [ ] 4.5 `src/app.nim` frame loop and `web-ui/src/`: advance the force tour beside the climate tour
      through `setParamFromSimulation`, and surface both through whatever climate-output mechanism
      exists after task 8.11 (push channel or 4 Hz poll) — extend it, do not add a parallel one.
- [ ] 4.6 Run `./main`: the weather visibly wanders without popping; then turn the RD climate and the
      force weather on together and watch a forces+field world — their combined effect is unmeasured
      (design Risks) [?]; record what is seen beside the waypoint table, and if the combination
      misbehaves, report it rather than tuning either loop to compensate.
- [ ] 4.7 `just happen` and `just check` green.

## 5. Verification and record

- [ ] 5.1 Run `./main`: at crowding strength 0 build a collapsing single-species world, raise the
      strength, and watch the blob stop tightening; confirm sparse worlds are visually unchanged at
      any strength (identity at zero density). With `gpu_profiler`, compare the dense world's
      per-pass times before and after raising the strength — the ceiling's point is bounded sweep
      cost, so the forces pass should stop degrading as the blob forms.
- [ ] 5.2 Confirm both weathers, the crowding term, and the fraction survive a preset round trip in
      the app (save, reload, apply), and that a preset saved before this change still loads with
      crowding strength 0 and fraction 1.0 through the legacy decode — no saved world changes
      behaviour under this change.
- [ ] 5.3 Release notes: the fraction default (2.6) and the crowding default (1.9) as they apply to
      fresh worlds, each pointing at the constant's recorded measurement, and stating that saved
      presets are preserved by the legacy decode.
- [ ] 5.4 `openspec validate` for this change, then `just happen` and `just check` green.
      Validation only — archiving is the user's manual act; see "Order of work".

---

# E. Legibility

**Every task DECLARED in this section carries an implicit `E` prefix.** The checkbox line `- [ ] 3.4` below is E3.4. Namespaced rather than renumbered, for the reason given above. The decisions these tasks implement are the E-family in `design.md`.

**Citations do not inherit the prefix — they carry it.** A reference to E3.5 is written `E3.5` even here inside the E section, and an unprefixed `group 9` means the bare family. See "Order of work" for why the rule runs this way.

## 0. Orientation

The legibility groups are independent of the rest of the change's delivery with one exception: the
dormancy predicates that name coupling strengths (E7) can only be written once the strengths
exist (D7 and D13; task group 9). Every coverage relation here is total over whatever the
descriptor table holds, so parameters added by other groups inherit probes, slices, and dormancy
declarations automatically — whichever group lands second inherits the other's parameters. Where
two groups touch the descriptor payload, they add different fields and do not conflict.

- [x] 0.1 Read `CLAUDE.md`, then this change's `design.md`. Decisions E1–E14 are settled; you build
      and measure, you do not re-research them.
      Read as part of this session's workflow orientation: CLAUDE.md and design.md E1-E14.
- [x] 0.2 `just happen` and `just check` green on a clean tree before changing anything. A
      pre-existing failure is the first task, not a thing to work around.
      The per-group integration gates in this workflow ran just happen and just check green
      immediately before the E family began.
- [x] 0.3 Read `src/ui/api/param_descriptor.nim` end to end and `tests/test_param_descriptor.nim`'s
      test names. Every relation this change adds follows the shape those tests already use.
      param_descriptor.nim and test_param_descriptor.nim read end-to-end by the implementing agents
      before each E group; every added relation follows the existing test shapes.

## 1. Render-side reference oracles

Nothing can be measured that has no mirror. These two are the gap in the family.

- [x] 1.1 `tests/test_glow_core.nim` (new): `halo alpha falls off as a Gaussian in normalized radius`;
      `raw alpha scales linearly with glowIntensity`; `the probe observable saturates at the display
      clamp`; `warmth is bounded above by glowWarmth`; `base radius scales with glowRadiusScale`.
      Write these before the module.
      /Users/nick/projects/ai/particle-garden/tests/test_glow_core.nim (new) carries the five named
      tests plus eleven the mirror earns, across five suites; every coordinate is read from an owner
      (config_ranges ranges, initRenderState defaults, shader_config curve constants), none restated.
      Watched red on `cannot open file: ../src/glow_core` before the module existed, and watched two
      mutations go red afterwards: dropping the display clamp fails `the probe observable saturates
      at the display clamp`, and moving glow.wgsl:99's 0.5 to 1.0 fails `speed grows the halo by half
      the velocity coupling`. The named test `raw alpha scales linearly with glowIntensity` holds
      only where the velocity term is out, so it names its two coordinates (a stationary particle,
      and velocityGlowScale at its floor) and a companion test pins the quadratic coupling
      glow.wgsl:165 creates. One further test holds the mirror's eight curve constants against
      getTunableFloat, the values the bundler substitutes into the shader.
- [x] 1.2 `src/glow_core.nim` (new, pure): mirror `web/shaders/src/glow.wgsl` — the radius
      composition at :96-101, the `exp(-params.glowFalloff * l * l)` falloff at :173, and the warmth
      composition at :180-181. Expose the halo alpha integral raw and display-clamped; the clamped
      form is the probe observable (design E1), because raw alpha keeps rising through travel the
      display has stopped answering.
      /Users/nick/projects/ai/particle-garden/src/glow_core.nim (new, pure, no importer in src/)
      mirrors glow.wgsl's velocity normalization (:91), radius composition (:98-100), disc mask
      (:138-142), density and velocity factors (:148-149, :164-165), Gaussian falloff (:169-170) and
      warm shift (:176-177). The probe observable is `haloAlphaIntegralClamped`: display-clamped
      alpha integrated over the halo's screen footprint in pixels squared, bounded by
      `haloDiscArea`, with `haloAlphaIntegralRaw` beside it so the gap is measurable; the area
      integral was chosen over a radial one because the clamp acts per pixel and it is what makes
      glowRadiusScale move the observable. Curve constants are not restated here: shader_config.nim
      gained `glowTuning()` and a `from glow_core import GlowTuning`, so TuningConstants stays the
      one home. MEASURED at full speed, velocityGlowScale at its maximum and density past the factor
      clamp: clamped is 85% of raw at the top of the intensity track (1559 against 1843 px^2, disc
      area 5542), while at the SHIPPED velocityGlowScale of 1.0 the same track peaks at alpha 0.5
      and nothing clamps at all.
- [x] 1.3 `tests/test_trail_core.nim` (new): `persistence length is 1/e frames at the fade amount`;
      `zero fade amount gives zero persistence`; `persistence rises monotonically with trailLength`.
      /Users/nick/projects/ai/particle-garden/tests/test_trail_core.nim (new) carries the three named
      tests plus four more, sweeping 64 trail lengths across TRAIL_LENGTH_MIN..MAX. `persistence
      length is 1/e frames at the fade amount` checks the closed form against the shader's own
      repeated multiply — floor(n) frames still brighter than 1/e, one more frame dimmer — so the
      two cannot drift apart. Watched red on `cannot open file: ../src/trail_core`, then watched two
      mutations go red: mixing colour toward zero instead of the background fails `the mix carries
      the trail's colour at the alpha's own rate`, and halving the mapping's exponent fails both
      `persistence in frames is linear in trail length` and `a trail decays to the residual fraction
      over the frames it names`.
- [x] 1.4 `src/trail_core.nim` (new, pure): mirror the trail's geometric decay — the per-frame
      `fadeAmount` mix (`web/shaders/src/fade.wgsl:109-110`) and the trailLength→fadeAmount mapping
      that feeds it (`src/webgpu_render.nim:1644-1652`). Expose `persistenceFrames(trailLength): float`.
      /Users/nick/projects/ai/particle-garden/src/trail_core.nim (new, pure) mirrors fade.wgsl:104-105
      as `fadedAlpha`/`fadedChannel` and owns the trail-length mapping as `fadeAmountFor`,
      `persistenceFramesForFade` and `persistenceFrames`, with TRAIL_FRAMES_PER_DIAMETER (2.0) and
      TRAIL_RESIDUAL_FRACTION (0.05) homed beside them. Rather than copying the mapping,
      src/webgpu_render.nim now calls `fadeAmountFor(config.CONFIG.trailLength)` and its inline
      literals plus its now-unused `import std/math` are gone — one number reaches the GPU and the
      suite. MEASURED: persistence is exactly linear at 0.667616 frames per diameter (2/ln 20),
      giving 16.69 frames at the Trails toggle's 25 diameters and 133.52 frames at the 200 ceiling,
      while fadeAmount itself crowds high — 0.9418 at 25, 0.9632 at a fifth of the track, 0.9925 at
      its end.
- [x] 1.5 Register both modules in `tests/test_all.nim` with their marker constants and add them to
      `tests/README.md`'s per-file table and architecture tree. Add both to `CLAUDE.md`'s
      reference-oracle table.
      Both modules are registered in /Users/nick/projects/ai/particle-garden/tests/test_all.nim
      (imports beside test_colormap_core, plus GLOW_CORE_TESTS_LOADED and TRAIL_CORE_TESTS_LOADED in
      the marker block) and in tests/README.md's per-file table, architecture tree and coverage
      summary. That README's reference-oracle paragraph pointed at a table in the root CLAUDE.md
      that did not exist, so the table was created: nine rows naming each pure mirror and the shader
      it is written against, from physics_core/forces.wgsl through the two new ones. The same
      paragraph was corrected — camera_core, colormap_core and now trail_core do have importers in
      src/, because each owns a number the app writes into a uniform.
- [x] 1.6 `just happen` and `just check` green.
      `just happen` exits 0: 20 shaders bundled (output byte-identical, no generated file changed),
      JS frontend, UI bundle and native binary all built. `just test` reports 750 [OK] lines and
      zero failures, up from 703 at C2.7 with the C3 and E1 additions; the 16 glow tests and 7 trail
      tests all appear in that run. `cd web-ui && bun test` reports 50 pass / 0 fail. The full
      `just check` gate is left to the integrator per this group's handoff.

## 2. Generated parameter dispatch

Independent of everything else here, and the highest-value single fix: it converts a silent no-op into
a build error.

- [ ] 2.1 `tests/test_param_descriptor.nim`: `every simulation-store descriptor id names a field of
      SimulationState` and `every render-store descriptor id names a field of RenderState`, walking
      the records with `fieldPairs`. Expected: passes immediately — it pins the relation the generated
      dispatch will depend on.
- [ ] 2.2 `src/web_api.nim:407-508`: replace the hand-written `case` with a compile-time walk over the
      routed state record's fields, assigning where the name matches and coercing to `int` for
      `pkInt` descriptors. Keep explicit arms for the two routes that are not field assignments:
      `paletteSaturation`/`paletteLightness` (editor state plus `applyPaletteToColors()`) and
      `cameraZoom` (the live camera, deliberately outside CONFIG — see `ParamStore` in
      `src/ui/api/param_descriptor.nim`).
- [ ] 2.3 Confirm the failure: temporarily add a descriptor whose id names no field, verify
      `just happen` fails at compile time, then remove it. Record what the error looks like in a
      comment above the generated dispatch, so the next person recognizes it.
- [ ] 2.4 `just happen` and `just check` green; every shipped parameter still writes the same field.

## 3. The probe registry and the sweep

The measurement gate. Task 3.4 is expected to fail for four named parameters — that failure is the
calibration signal, not a defect in the test.

- [ ] 3.1 `src/ui/api/response_probe.nim` (new, pure): `ProbeContext` — every parameter other than
      the one under measurement, fixed at named coordinates, defaulting to the shipped defaults with
      the strengths that multiply the observable's contribution at their reference coordinates
      (design E2); the probe
      registry mapping probe ids to `proc(value: float; ctx: ProbeContext): float`; the budget
      classes (`pbClosedForm` = 256 samples, `pbStepped` = 64); and the three metrics — span, live
      fraction, cliff — computed over track positions per slice.
- [ ] 3.2 `src/ui/api/param_descriptor.nim`: add `probe: string` and `exemption: string` to
      `ParamDescriptor`, populated per design E1's assignment table. The two exemptions are
      `particleCount` and `speciesCount`, each with its written reason; `particleSize` takes the
      composed visible-radius probe (design E14) rather than an exemption.
- [ ] 3.3 `tests/test_response_probe.nim` (new): `every descriptor is either probed or exempted`;
      `no descriptor is both`; `every probe id resolves to a registered function`; `every exemption
      states a reason`. These pin the coverage relation before any metric runs.
- [ ] 3.4 Same file: the sweep — for every probed descriptor, compute span, live fraction, and cliff
      on its default slice at the provisional thresholds (`SPAN_MIN = 0.05`,
      `LIVE_FRACTION_MIN = 0.60`, `CLIFF_MAX = 0.25`, `RESPONSE_EPSILON = 1e-4`). Expected:
      `rdFeed`, `rdKill`, `trailLength`, and `glowIntensity` fail; `friction`, `fieldOpacity`,
      `exposure`, `contrast`, `sphViscosity` pass.
- [ ] 3.5 Emit the full measured table — every parameter's span, live fraction, cliff, and the
      interval where its response dies, per slice — into `docs/control-legibility-report.md` (new),
      beside the existing `docs/perf-report.md`. **This table is the deliverable of this group**;
      E5 reads it.
- [ ] 3.6 If any must-pass control fails or any must-fail control passes, the probe for it is wrong.
      Fix the probe. Design E3 forbids moving the threshold to resolve this.
- [ ] 3.7 `just happen` and `just check` green — with 3.4 red only for the four predicted parameters,
      quarantined behind an explicit expected-failure marker until E5 clears them.

## 4. Travel curves

Built before the remedies that use them.

- [ ] 4.1 `tests/test_slider_curve.nim` (new): `position and value round-trip at the descriptor's
      precision`; `a linear curve reproduces the current position mapping exactly`; `position 0 and 1
      map to the range endpoints under every curve`; `a curve preserves monotonicity`.
- [ ] 4.2 `src/ui/api/slider_curve.nim` (new, pure): `valueAt(descriptor, position)` and
      `positionOf(descriptor, value)` for `cLinear`, `cLog`, and `cPower`. Both read the bounds the
      descriptor currently serves, so a bound that is derived from other live parameters (C7) needs
      nothing special: the curve warps whatever interval is live right now.
- [ ] 4.3 `src/ui/api/param_descriptor.nim`: add `curve` and its exponent to `ParamDescriptor`,
      defaulting every parameter to `cLinear`. `src/config_ranges.nim`: the exponents as constants
      under static assertions rejecting a value that would invert or flatten the mapping, and
      rejecting `cLog` paired with a range minimum at or below zero — a logarithm has no zero, so
      the curve and the floor are one decision (design E5).
- [ ] 4.4 `src/web_api.nim`: serve `curve` and the exponent in `descriptorToJs`; expose `valueAt` and
      `positionOf` through the boundary so the panel computes no mapping.
- [ ] 4.5 `web-ui/src/components/ParamSlider.tsx`: drive the range input by track position, converting
      through the boundary in both directions. The readout keeps showing the value, never the
      position.
- [ ] 4.6 `tests/test_param_descriptor.nim`: `every hint numeral and notch coordinate stays reachable
      under its parameter's curve` — extending the existing reachability test
      (tests/test_param_descriptor.nim:94).
- [ ] 4.7 `just happen` and `just check` green; a `cLinear` parameter must behave identically to
      before this group.

## 5. Calibration and the remedy ladder

- [ ] 5.1 Read `docs/control-legibility-report.md` from E3.5. Set `RESPONSE_EPSILON`, `SPAN_MIN`,
      `LIVE_FRACTION_MIN`, and `CLIFF_MAX` inside the gap between the must-pass and must-fail sets
      named in design E3. Record the measured distribution beside the constants. If no gap exists,
      return to 3.6.
- [ ] 5.2 Apply design E4's ladder to every failing parameter, in order: re-range, then curve, then
      re-step, then join, then exempt. Record each change's before/after measurement beside the
      constant it touches, in the style `src/config_ranges.nim:96-103` already uses.
- [ ] 5.3 `trailLength` is expected to take a curve, because geometric decay concentrates its effect
      at one end of the track. Whatever the report actually says wins over this prediction.
- [ ] 5.4 `glowIntensity`'s remedy, judged against the recorded outcome: fine authorship near the
      bottom of the track — settings around `0.001` distinguishable from one another — and no
      blown-out dead top. The measurement chooses between a re-range to a strictly positive floor
      under a `cLog` curve and a zero floor under a `cPower` curve (E4.3's assertion forbids
      the fourth combination), and between a ceiling near `1` and a curve over a wider range —
      whether zero glow stays reachable from the slider is part of what the choice decides, and the
      choice is recorded beside the constants (`src/config_ranges.nim:49-50`) with its before/after
      measurement.
- [ ] 5.5 The joint group mechanism (design E12): a group declaration carrying its members, its named
      points (the regime table the notches already draw from), and its slice contexts. Slices
      through regimes that carry a deposit floor fix deposit at `max(default, minDeposit)`
      (src/config_ranges.nim:117-124) — a slice through such a regime at the default deposit
      measures a dead world.
- [ ] 5.6 Entry evidence for `rdFeed`/`rdKill`: measure each member's live interval on the slice
      through every named point; assert the intervals do not all overlap; record the measurement
      beside the group declaration. Expected: non-overlap holds and the pair enters the group. If
      the intervals all overlap, a single curve serves both sliders and the group is NOT declared —
      design E12's entry rule cuts both ways.
- [ ] 5.7 The group's guarantees, adopting what exists: slice liveness (new — each member live
      within a declared neighbourhood of every named point, on that point's slice); joint
      reachability adopted from the notch-lattice assertions; attractor fidelity adopted from
      `The Regime Deposit Floor Preserves The Regime` (tests/test_field_core.nim:1125); continuity
      of travel between points adopted from the climate tour's continuity and easing tests
      (tests/test_climate_core.nim:60-86). Reference the adopted suites; copy nothing.
- [ ] 5.8 The derived-bound slice mechanism (design E2): a descriptor whose ceiling is a function of
      other live parameters declares slices at the corners of the deriving box plus the default.
      The sweep is total over the table, so a bound that becomes derived after this change lands
      inherits its slices by declaring them, with no sweep change.
- [ ] 5.9 Remove the expected-failure quarantine from E3.7. The sweep now runs as an ordinary
      assertion over the whole table, per slice.
- [ ] 5.10 Update `docs/control-legibility-report.md` with the post-remedy table beside the
      pre-remedy one, including the feed/kill slice measurements.
- [ ] 5.11 `just happen` and `just check` green with no quarantined tests.

## 6. The matrix editor keeps the user's edit

The fifth defect class: a control whose own handler reverts the edit. Fix the ownership first, then
recalibrate the range the editor serves.

- [ ] 6.1 `bun test` first: the cell edit-state machine as pure functions — an edit holds any
      intermediate text including empty; commit parses, clamps, and writes; an external matrix
      update while an edit is in progress leaves the edited cell's text alone and refreshes every
      other cell. Expected to fail against the current handler
      (`web-ui/src/components/MatrixEditor.tsx:46-55`, which maps an emptied field through `NaN` to
      a forced re-render back to the live value).
- [ ] 6.2 `MatrixEditor.tsx`: hold uncommitted cell state, clamp on commit through the boundary's
      `clampMatrixValue`, and stop restating the step and display precision
      (`MatrixEditor.tsx:92-93`) — both now arrive from the boundary.
- [ ] 6.3 `src/web_api.nim`: serve the matrix bounds, step, and display precision beside the existing
      matrix surface (`src/web_api.nim:960-964`).
- [ ] 6.4 `src/config_ranges.nim`: `MATRIX_MIN_VALUE = -0.100`, `MATRIX_MAX_VALUE = 0.100`, step
      `0.001`, display precision 3, with the calibration recorded beside the constants — made
      together with the crowding attenuation (C1-C2), not separately.
      `src/ui/state/matrix_state.nim` consumes these instead of defining them
      (matrix_state.nim:16-17); `src/preset.nim`'s documented copy (preset.nim:147-149) collapses to
      a read of the same constants, which the range authority's layering permits where `src/ui/`
      does not.
- [ ] 6.5 `src/ui/state/matrix_state.nim:140-144`: recalibrate the random-fill distribution to the
      new bounds so a randomized world keeps its character; record the chosen spread beside it.
- [ ] 6.6 `tests/`: a preset carrying matrix values in `[-1, 1]` loads with every value clamped into
      the served bounds — the one stored-data change this change makes, priced in design E13.
- [ ] 6.7 `just happen` and `just check` green.

## 7. Acknowledgement, horizon, and dormancy

- [ ] 7.1 `src/ui/api/param_descriptor.nim`: add `horizon: rhInstant | rhSettling | rhStructural` per
      design E7, and `dormantWhen` naming a declared predicate per design E8. Every render-store
      parameter is `rhInstant`.
- [ ] 7.2 `tests/`: every state field a dormancy predicate names resolves against the state records,
      walked with `fieldPairs`, so a renamed field breaks the predicate loudly. A control never goes
      dormant under its own value — asserted over the table.
- [ ] 7.3 `tests/`: `every field parameter with a stepping oracle moves its observable within its
      declared horizon`; `every horizon without a stepping oracle is marked review-enforced`.
- [ ] 7.4 `src/web_api.nim`: serve `horizon` and `dormantWhen` in `descriptorToJs`. Evaluate
      predicates over panel-visible state synchronously against the state the panel already mirrors,
      and predicates over world state against the existing pushed stats stream — no new
      subscription, no per-frame call.
- [ ] 7.5 The declared dormancy cases that need no coupling strengths, first:
      the five grade sliders dormant on the bloom toggle's state (their consumer binds only inside
      the bloom present path, `src/webgpu_render.nim:1756`, while the uniform is written every
      frame at :1673-1681 — the probe and dispatch checks both pass, which is why dormancy owns the
      explanation); the field-appearance controls dormant while the field rests at its trivial
      fixed point; `rdFeed`/`rdKill` dormant under the compound predicate — field unlit AND
      `F < 4(F+k)²` (the fixed-point condition pinned at tests/test_field_core.nim:509) — with a
      line saying nothing has ignited yet.
- [ ] 7.6 The strength-family cases, once the coupling strengths exist (D7 and D13; task
      group 9): every control whose effect a strength multiplies (the D12 ownership split) declares
      dormancy at that strength's zero, with the strength's own control declaring none. Verify each
      declaration against the ownership split, not against the panel group — `interactionRadius`
      feeds world-intrinsic density and declares no coupling dormancy.
- [ ] 7.7 `web-ui/src/components/ParamSlider.tsx`: a brief highlight on every input event, in the same
      tick and unconditionally; a settling indicator while a non-instant horizon has not elapsed; a
      dimmed dormant state showing the precondition line. A dormant control stays in place and stays
      movable.
- [ ] 7.8 `web-ui/src/ui.css`: the highlight, settling, and dormant styles. Keep the highlight short
      enough that a drag does not strobe.
- [ ] 7.9 `bun test`: the dormancy predicate evaluation and the horizon-elapsed timer, as pure
      functions.
- [ ] 7.10 `just happen` and `just check` green.

## 8. Spatial overlays

- [ ] 8.1 `web-ui/src/` and `src/web_api.nim`: a drag-active signal carrying the parameter id, crossing
      the boundary the same way parameter writes do.
- [ ] 8.2 `src/webgpu_render.nim`: draw the transient overlay at world scale while a spatial parameter
      is being dragged — `interactionRadius` as a ring at the cursor, the deposit splat radius as a
      disc, camera zoom as a frame. Clear on release.
- [ ] 8.3 The set stays closed to parameters that are literally a world distance (design E9). Do not
      extend it while implementing.
- [ ] 8.4 Verify in `./main`: dragging interaction radius shows a ring whose size tracks the slider,
      and it disappears on release.
- [ ] 8.5 `just happen` and `just check` green.

## 9. Help content pipeline

- [ ] 9.1 `docs/help/` (new): one file per descriptor group, plus `00-orientation.md` and
      `90-glossary.md`. Each file declares the group id it documents in its front matter. Stub content
      is acceptable in this group; E11 writes the prose.
- [ ] 9.2 `src/ui/api/help_content.nim` (new): `staticRead` every file in `docs/help/` into a table
      keyed by group id, with the front-matter parse as a pure function.
- [ ] 9.3 `tests/test_help_content.nim` (new): the four coverage relations from design E10 — every
      group has a file; every declared group id exists; every descriptor is named by its group's file;
      no file names a non-existent id. Expected: fails until 9.1's stubs name every control.
- [ ] 9.4 `src/web_api.nim`: `gardenAPI.help()` serving the table.
- [ ] 9.5 `web-ui/src/components/HelpPanel.tsx` (new): the panel, opened by a control and by `?`,
      closed by `Escape`, rendering the restricted markdown subset from design E10.
- [ ] 9.6 `web-ui/src/lib/markdown.ts` (new) and its `bun test`: headings, paragraphs, lists,
      emphasis, code spans, internal links. Markup outside the subset renders as literal text.
- [ ] 9.7 Register `test_help_content` in `tests/test_all.nim` and `tests/README.md`.
- [ ] 9.8 `just happen` and `just check` green.

## 10. The binding table and the generated gesture reference

- [ ] 10.1 `src/ui/input/binding_table.nim` (new, pure): every mouse gesture, touch gesture, and key
      binding as data, each with a description. Include the bindings `src/canvas_input.nim` and
      `src/ui/input/` already implement.
- [ ] 10.2 `tests/test_input.nim`: `every binding carries a non-empty description`; `no two bindings
      claim the same key`.
- [ ] 10.3 `src/canvas_input.nim` and `src/ui/input/`: consume the table rather than declaring bindings
      inline, so the table is the single declaration.
- [ ] 10.4 `src/ui/api/help_content.nim`: render the binding table into the help reference section, so
      a binding cannot exist without appearing in help.
- [ ] 10.5 `just happen` and `just check` green.

## 11. Writing the help

The prose. Everything before this made a place for it that cannot go stale.

- [ ] 11.1 `docs/help/00-orientation.md`: what is on screen, what a pointer does, and one thing worth
      trying — before any control is named, and with no formula (design E10's requirement about
      readers with no background).
- [ ] 11.2 One file per group: what the group governs, what each control in it changes, and what to
      watch for when it changes. Every descriptor in the group must be named, or E9.3 goes red.
      Where a control can be dormant, its file says what wakes it, in the same words the panel uses.
- [ ] 11.3 `docs/help/90-glossary.md`: the named regimes, reactions, and force models, each with its
      cited source. Cite rather than assert — a coordinate from the literature is not the app's own
      claim.
- [ ] 11.4 Read the whole set as someone who has never seen the app. Anything requiring prior
      knowledge to parse gets rewritten, not annotated.
- [ ] 11.5 `just happen` and `just check` green.

## 12. A floor on what can be seen

The guarantee moves to the end of the transform chain (design E14). Independent of the remedies;
needs only the probe machinery from E3.

- [ ] 12.1 `tests/test_camera_core.nim` first: `the composed on-screen radius never falls below the
      visibility floor at the worst reachable corner` — minimum particle size, minimum zoom, the
      density size multiplier at its 0.7 floor (`web/shaders/src/render.wgsl:65`) — and `the floor
      binds the result, not a factor` — a corner where every per-parameter bound holds and only the
      end-of-chain floor keeps the product visible.
- [ ] 12.2 `src/camera_core.nim`: the visible-radius chain as a pure function — size parameter,
      density size multiplier, world-to-screen scale, zoom, camera size correction (mirroring
      `render.wgsl:110` and `:160`, `glow.wgsl:105`) — floored at its end by a new pixel constant
      in `src/config_ranges.nim` with its reasoning recorded. Decide from the measurement whether
      `CAMERA_SIZE_FLOOR` (`src/camera_core.nim:30-31`) survives as aesthetic shaping of the
      zoom-size relation or retires into the result floor.
- [ ] 12.2a **The false guarantee is written in two places, and both are corrected.** Besides
      `camera_core.nim:30-31`, the `CAMERA_ZOOM_MIN` docstring at `src/config_ranges.nim:201-202`
      states it outright: "camera_core.CAMERA_SIZE_FLOOR is what keeps particles legible here rather
      than a quarter-size and sub-pixel." That sentence is the E14 defect in prose — it credits one
      factor with a promise about the product, at exactly the corner (zoom 0.25) where E12.1 measures
      the product failing. Both comments name the end-of-chain floor as the guarantee and describe
      `CAMERA_SIZE_FLOOR` as whatever the 12.2 measurement leaves it. `src/shader_config.nim:184-186`
      needs no change: it claims only that the shader mirror must not drift from the native constant,
      which stays true.
- [ ] 12.3 `web/shaders/src/render.wgsl` and `web/shaders/src/glow.wgsl`: apply the same floor at
      the same point in the same chain — both shaders and the mirror change together, as for every
      oracle in the family.
- [ ] 12.4 `particleSize`'s probe measures the composed observable on slices at the zoom corners
      (design E2, E14); the sweep's corner slices go green against the floor.
- [ ] 12.5 Verify in `./main`: minimum particle size, zoomed fully out — every particle remains
      visible.
- [ ] 12.6 `just happen` and `just check` green.

## 13. Documentation and close

- [ ] 13.1 `CLAUDE.md`: add `docs/help/` as the feature-documentation source and the in-app help
      source, note the four coverage relations, and add `glow_core`, `trail_core`, `response_probe`,
      `slider_curve`, `help_content`, and `binding_table` to the module inventory. Note that the
      parameter dispatch is generated, so a descriptor id must name a state-record field.
- [ ] 13.2 `tests/README.md`: every new test module in the per-file table and the architecture tree.
- [ ] 13.3 `docs/control-legibility-report.md`: confirm it holds both the pre-remedy and post-remedy
      tables, the feed/kill slice measurements, and names the calibration gap the thresholds sit in.
- [ ] 13.4 `openspec validate`. Validation only — archiving is the user's manual act and no task
      schedules it; see "Order of work".
- [ ] 13.5 `just happen` and `just check` green.
