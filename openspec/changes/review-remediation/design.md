## Context

Twenty findings, six territories, one tree. The question this change answers is not how to repair
twenty faults but what would have caught them, because the goal is that the next review of this
codebase finds less than this one did while the twenty stay useful as reference.

Two experiments ran before any of this was designed. Both are recorded with their method and their
falsified predictions in `scratchpad/understand-enforcement-surface.md`.

## Proven properties

### Bidirectional relation coverage protects a subject; a count assertion does not

`buildParamDescriptors()` was truncated from sixty-odd entries to three by appending `[0 ..< 3]` to its
literal. Prediction before running: most descriptor sweeps stay green, because they iterate the list
and assert per entry without asserting how many entries there are. **The prediction was wrong. 33 tests
failed.**

They failed because the descriptor inventory sits in relations that are covered from both ends. A test
ranging over descriptors and requiring a help line, paired with a test ranging over help lines and
requiring a descriptor, catches shrinkage, growth and renames alike without either test naming a count.

This retires the working hypothesis that a missing `check ids.len == N` predicts vacuity. The corrected
predictor: **coverage running one direction only, over a subject sized outside the test.** Both
conditions must hold. `test_no_modes.nim:133` and `:144`, and `test_wgsl_lint.nim:80` and `:137`, are
where both do.

The design consequence: the meta-gate demands a reverse relation wherever the subject has a registry to
range over, and falls back to a non-empty-harvest guard only where no registry exists. It does not
demand count assertions anywhere.

### Substitution is what keeps reference oracles honest

All thirteen oracle pairs were read expression by expression against their shaders. Twelve agree. The
one divergence is `sph_core` ↔ `forces-sph.wgsl`, three ways, and its cause is structural rather than
inattentive: `SPH_MAX_DENSITY_RATIO` lives in `shader_config.nim`'s tuning record, downstream of
`sph_core`, so the oracle cannot express the shader's clamp without inverting the import direction.

Every constant that travels by `{{PLACEHOLDER}}` agreed. Every divergence sat where a number is spelled
twice. Three further SPH constants are spelled in both modules under comments claiming they agree
(`shader_config.nim:113`, `:114`, `:120`), and no test in `tests/` names any of the four field names.
Their values match today, which makes them latent rather than live, and one edit away from live.

### The declared oracle inventory is short by three

`physics_core` ↔ `integrate.wgsl`, `bloom_core` ↔ `tonemap_grade.wgsl` and `overlay_core` ↔
`overlay.wgsl` all agree and none appears in CLAUDE.md's table. A gate keyed on that table alone would
report full coverage over an inventory missing three entries. Shaders name their own oracle in their
headers, which gives a second derivation to assert the table against.

### The descriptor inventory is compile-time constructible

`param_descriptor.nim:730` holds a `static:` gate that binds `buildParamDescriptors()` at compile time.
Three attempts to wrap or forward-declare the function for the truncation experiment failed on exactly
this. A gate that wants the descriptor list at compile time therefore already has it.

## Designed but unexercised

The meta-gate, the vacuity gate and the duplicate-constant gate are designed here and built in stage 0.
Nothing in this change measures how many existing assertions the vacuity gate rejects on first run. The
prototype (`scratchpad/vacuity_sweep.py`) reported 80 candidate blocks and 65 without a size guard, but
that heuristic is the one the truncation experiment falsified, so the number carries no weight and is
recorded only as an upper bound on blocks worth reading.

`docs/agreements.md` is designed to be the artifact a reviewer reads instead of re-deriving agreements.
Whether it achieves that is measured by the next review, not here.

## Decisions

### Preset defaults move to their owning records rather than the owners moving to the preset

`defaultSettings()` (`preset.nim:205-240`) states it mirrors the shipped defaults and disagrees with the
owning records on five keys. Owners win.

Rejected: moving `simulation_state` and `render_state` to match `preset.nim`. That would change what a
fresh boot does, which is the state the world was tuned against, in order to preserve six starter
presets nobody tuned against the drifted values. It also puts the preset schema upstream of the state
records, inverting the direction every other fact flows.

Cost: the six regime presets change appearance. Marked **BREAKING** in the proposal.

### The third force law becomes a runtime model, parameterized

`physics_core.calculateForce` has no caller in `src/` and exists as a curve the tests exercise. It ships
as MODEL 2 rather than being deleted.

Rejected: shipping it with its fixed 0.3 and 0.65 breakpoints. Models 0 and 1 both read `repulsionEnd`
and `attractionPeak`, so a fixed MODEL 2 would leave two sliders inert whenever it is selected, which
makes a control assert a state it is not in. That is the exact fault class this whole change exists to
remove, so shipping one to close a finding would be self-defeating.

Chosen form: repulsion is `r / repulsionEnd - 1` over `[0, repulsionEnd]`, attraction is an asymmetric
triangle over `[repulsionEnd, 1]` peaking at `attractionPeak`. At `0.3 / 0.65` this reproduces the
existing fixed curve exactly, so the existing tests keep their meaning and gain a parameterization.

### Single-sourcing the constants, not pinning digests over oracle pairs

Rejected: a digest of each oracle and its shader, compared against a pinned baseline.

A digest goes red when a comment is reflowed and stays green when a constant is edited in both places to
two different values. Both failure directions are backwards. The thirteen-pair read showed the honest
pairs holding by substitution, so the mechanism that actually did the work gets the gate: no constant an
oracle owns may be spelled again in `shader_config.nim`'s tuning record.

Structure is what substitution cannot carry. That is left to the expression correspondence and to
reading, and this change does not claim to have automated it.

### The inventory lives in `docs/`, beside the principles

`docs/engineering-principles.md` names twelve articles and, for each, an enforcement path. It does not
name where each path applies. `docs/agreements.md` supplies that: one row per agreement, its two sides,
the direction facts flow, and the assertion holding it.

Rejected: putting the inventory in `openspec/specs/`. A spec describes a capability's requirements; the
inventory is a map of the tree and outlives any one change. Rejected also: generating it wholly from
code. The rows whose assertion column is empty are exactly the interesting ones, and a generated
inventory can only list what already has a mechanism.

### Stage 0 precedes stage 1 even though stage 1 holds the user-visible faults

The inventory decides which findings already have a gate and which need one built. Repairing an instance
before its class has a gate spends the repair without closing the class, and the four user-visible
faults are not urgent in the sense that would justify inverting that: the fluid has never worked, and
the input interception has shipped since the panel did.

Stage 0 needs nothing from the other stages. Both experiments are done and thirteen oracle pairs are
read.

## Open questions

None. Every fork this change reaches is closed above or in the proposal's Non-Goals.

The review's own three self-flagged uncertainties (the `requiredLimits` clamp rule, `app.nim` import
order, `GardenAPI` member-by-member agreement) are not carried into this change and remain unverified.
They are rows in `docs/agreements.md` with an empty assertion column, which is where an unverified
agreement belongs.
