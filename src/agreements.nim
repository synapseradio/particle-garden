# ==============================================================================
#
# The inventory of two-sided agreements: facts the tree states at two sites,
# each with the tier that holds the sites together and the reason it sits no
# higher. A site is a path and a literal anchor that occurs in that file, so
# collapsing a duplication removes the anchor and the entry fails its gate
# until it is deleted with the fix.
#
# Used by:
#   - tests/test_agreements.nim (the gates over this table)
#
# docs/agreements.md explains the tiers, how to choose an anchor, and what the
# inventory does not cover.
#
# ==============================================================================

type
  AgreementTier* = enum
    Derived        ## one site computes from the other; no second copy exists
    BuildAsserted  ## a static assertion fails compilation on disagreement
    TestHeld       ## a native test relates the sites; the build does not
    AgentCheckable ## no automated gate; a named procedure detects a violation
    Unenforced     ## nothing detects a violation

  AgreementSite* = object
    path*: string    ## relative to the repository root
    anchor*: string  ## literal text that occurs in the file

  Agreement* = object
    key*: string
    statement*: string
    sites*: seq[AgreementSite]
    tier*: AgreementTier
    holder*: AgreementSite
      ## The gate: the assertion's text, the test's name, or the procedure's
      ## description. Empty at Unenforced.
    whyNotStronger*: string  ## required below Derived
    wouldClose*: string      ## required at Unenforced

func site(path, anchor: string): AgreementSite =
  AgreementSite(path: path, anchor: anchor)

const AGREEMENTS* = @[
  Agreement(
    key: "species-ceiling-preset",
    statement: "the species ceiling sizes the preset's matrix, palette, and chemistry arrays",
    sites: @[
      site("src/memory_layout.nim", "MAX_SPECIES* = 12"),
      site("src/preset.nim", "const MAX_SPECIES* = 12")],
    tier: BuildAsserted,
    holder: site("src/preset.nim", "doAssert MAX_SPECIES == SPECIES_COUNT_MAX"),
    whyNotStronger: "preset carries no dependency on memory_layout or any other " &
      "src/ module, to stay a leaf the storage and UI layers build on"),

  Agreement(
    key: "chemistry-stride",
    statement: "the per-species chemistry stride the preset stores equals the field's",
    sites: @[
      site("src/field_core.nim", "SPECIES_CHEMISTRY_STRIDE* = 2"),
      site("src/preset.nim", "const CHEMISTRY_STRIDE* = 2")],
    tier: Unenforced,
    whyNotStronger: "a doAssert would need preset to import field_core, " &
      "which its leaf constraint forbids",
    wouldClose: "a native test in tests/test_preset.nim relating the two"),
]
