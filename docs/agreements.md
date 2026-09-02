# The agreement inventory

A two-sided agreement is one fact the tree states at two sites. Article 2 of
[engineering-principles.md](engineering-principles.md) asks for one home per fact, and article 3
asks that where two copies must exist, one generates the other or an automated check fails on
divergence. The inventory in `src/agreements.nim` records every pair that has not reached that
bar, with the tier that holds it and the reason it sits no higher. `tests/test_agreements.nim`
gates the table in both directions, so an entry cannot outlive the agreement it records and a
tier cannot be claimed without its gate.

## Tiers

The tiers are the ones [enforcement.md](enforcement.md) uses, as an enum the compiler checks.

| Tier | Meaning | Where the tree does it |
|---|---|---|
| Derived | One site computes from the other, so no second copy exists | `src/config_ranges.nim` writes its species ceiling as `memory_layout.MAX_SPECIES` |
| BuildAsserted | A `static:` block or `doAssert` fails compilation on disagreement | `src/gpu_types.nim` asserts every struct offset against its layout table |
| TestHeld | A native test relates the sites and the build does not | `tests/test_shader_config.nim` relates the emitted SPH epsilon to `sph_core`'s constant |
| AgentCheckable | No automated gate exists, and a named procedure detects a violation | The landmines in [enforcement.md](enforcement.md), each with the observation that would catch it |
| Unenforced | Nothing detects a violation | The reference-oracle mirrors, held by review |

A Derived pair needs no entry at all, since there is nothing left to disagree. Every entry below
Derived carries `whyNotStronger`, the reason the pair is not derived. Every Unenforced entry also
carries `wouldClose`, naming what would detect a violation. The gate fails on an entry missing
either.

## Sites and anchors

A site is a file path, relative to the repository root, and an anchor: a literal substring that
occurs in that file, taken from the text the agreement is made of. `MATRIX_LEN* = MAX_SPECIES *
MAX_SPECIES` is an anchor. A line number is not, since an unrelated edit above it moves the line.

The anchor is what makes an entry retire itself. Collapsing the duplication removes the text the
anchor names, the gate reports the entry as stale, and the entry is deleted with the fix. The
inventory cannot go on describing an agreement that has gone.

Choose an anchor long enough to be unique in its file. `= 12` matches many lines. The
declaration text, with its name and its value, matches one. Before adding an entry, search the
file for the anchor and confirm it occurs once, since a second occurrence keeps a stale entry
green.

## Adding an entry

1. Confirm the pair cannot be derived. An import that already exists, or a placeholder the
   bundler already substitutes, is usually available and costs less than an entry.
2. Write the entry in `src/agreements.nim`: a key, a one-sentence statement of the fact, at least
   two sites, the tier, and the holder for any tier above Unenforced. The holder is a site too:
   the assertion's own text for BuildAsserted, the test's name for TestHeld.
3. Write `whyNotStronger` for any tier below Derived, and `wouldClose` for Unenforced.
4. Run `just test`. The gate reads every anchor from disk and fails on one it cannot find.

Removing an entry happens when its agreement disappears. Make the fix, watch the anchor gate
fail on the entry, and delete it in the same change.

## What the inventory does not cover

No gate detects a duplication absent from the table. A constant copied into a second module with
no entry added passes `just check`, and only review catches it. This residue is unenforced. What
closes it for a class of agreement is a detector that enumerates the class from the code and
needs no entry per member. `tests/test_agreements.nim` carries one such detector: every key
`getPlaceholderMap` emits must be consumed by a shader source, the reverse of the bundler's own
check that every placeholder a shader reads is emitted. The placeholder pairs need no entry
because that test derives its subject from the map and the shader sources.

Three classes have an owner elsewhere and appear nowhere in the table:

- Shader binding placement is held by `src/wgsl_lint.nim`, whose manifest the bundler checks
  every shader against.
- GPU struct offsets are held by `src/gpu_types.nim`, whose layout tables generate the WGSL
  struct modules and are static-asserted.
- Placeholder substitution is held by `src/shader_config.nim` with the consumption test above.
- Oracle-to-shader mirrors are listed under "Reference oracles" in
  [enforcement.md](enforcement.md), and held by review.

This document names no entry. The table in `src/agreements.nim` is the one list, and a second
list of the same entries would be the defect the inventory exists to remove.
