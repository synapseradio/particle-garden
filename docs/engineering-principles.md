# Engineering principles

An emergent-life engine grows by composition: an open-ended vision, three languages that cannot
type-check each other, and behavior that lives partly in a GPU runtime the test suite cannot
execute. These principles keep that openness from becoming entropy. Each is stated as a
principle — general, portable, short — followed by a **Here:** line naming how this repo enforces
it, because a principle without an enforcement path is a poster.

Amendment is a PR that states the failure or measurement motivating the change.

## 1. Validate at the boundaries

Check data where it crosses an ownership line — user input, serialized state, foreign-runtime
structs, API surfaces — and let code inside the boundary trust what reaches it. A boundary
without validation exports its callers' mistakes as its own undefined behavior.

**Here:** `gardenAPI` clamps every parameter write against the descriptor table; preset JSON is
validated and clamped at decode; GPU uniforms cross through generated layouts with compile-time
offset checks.

## 2. Every fact has one home

State each number, name, table, and contract in exactly one owning module; every other site
references the owner. Two copies held equal by an assertion are still two copies — collapse them.

**Here:** `config_ranges` owns ranges, `memory_layout` owns buffer shape, `param_descriptor` owns
the parameter contract; where a second copy is forced, a drift test makes disagreement loud.

## 3. Agreement is checked, never remembered

Where two representations of one thing must match, either one generates the other or an automated
check fails the build on divergence. Comments and discipline record intentions; they hold nothing
together.

**Here:** WGSL struct modules are generated from the Nim layouts; `wgsl_lint` runs inside the
bundler; bind groups validate entry counts; the binding manifest covers what counts cannot see.

## 4. Trust no gate that cannot fail

A check that passes vacuously, a tool that exits zero on failure, or a surface no test executes
is not coverage. Prove a gate can go red — watch it fail once — before crediting its green.

**Here:** just recipes call the compilers directly because nimble swallows task failures;
directory sweeps assert the directory was found; expected failures are watched failing before the
fix lands.

## 5. Mirror what you cannot test

When shipping logic runs where the suite cannot reach, keep a pure, testable mirror of it, hold
both to the same arithmetic in the same order, and name the lockstep where an editor will meet it.

**Here:** the reference oracles (`physics_core`, `sph_core`, `field_core`, `camera_core`, …)
mirror the shaders; a shader change without its mirror change in the same diff is the review flag.

## 6. Build nothing without a consumer

Ship a mechanism only alongside the code that uses it. A genuine reservation is prose naming what
a future consumer must touch — never dead fields, dead branches, or machinery kept dormant. What
is proven dead is deleted in the same change that proves it; deferring the deletion — to a later
pass, or to someone else's authority — is how dead machinery survives.

**Here:** the build fails on unused imports and variables; for everything larger the review
question is "who reads this?", and "nothing yet" ends the discussion. Deleting proven-dead code
carries standing authorization and is never parked as a question.

## 7. Compose; never enumerate

Model capabilities as orthogonal, continuous quantities that combine by running together, with
zero as an ordinary value. A list of valid combinations is a defect: it grows multiplicatively
and hides every world nobody thought to list.

**Here:** couplings are strengths; `sim_registry.acts` is the one site allowed to compare a
strength with zero; `test_no_modes` sweeps the tree for enumeration vocabulary.

## 8. Derive limits from capability

Bound a value at what the mechanism can actually do. When a tighter bound matters, measure it and
record the conditions beside the constant; when a limit chafes, fix the mechanism rather than
lowering the ceiling.

**Here:** the particle bound is the allocation bound; measured bounds (tropism, cell deposit)
carry their conditions and name the suites that re-run when a premise moves.

## 9. Lead with the failing test

Change behavior by first writing the test that fails for the stated reason, then the code that
turns it green. The observed failure is the proof that the test can see the defect at all.

**Here:** the TDD flow governs every behavior change; task records state the expected failure
before the fix.

## 10. Measure like an experiment

A number worth acting on comes with controls, settling time, and every relevant axis swept. The
measurement overrules the plan that requested it, and records enough conditions that a stranger
can re-run it.

**Here:** calibrations ride with negative controls and separation checks; deviations from task
text cite the measurement that forced them.

## 11. Inherit no defaults unchosen

Every behavior a platform or dependency supplies is a decision someone else made; adopt it
deliberately or override it. Pin what you depend on; suppress what you replace.

**Here:** libraries are exact-pinned with committed locks; the browser is a portability runtime,
not a website — input handlers `preventDefault` the page gestures they replace, and the binary
serves everything it needs.

## 12. One concern per change; history append-only

A commit answers one question — a message that needs "and" is two commits. Records of finished
work are annotated, never rewritten, and cited by identifiers that never renumber.

**Here:** conventional commits, one task per commit; task records append corrections under the
original entry; number families keep frozen prefixes.
