# The gates over src/agreements.nim, the inventory of facts stated at two
# sites. Each predicate below is a named function so the live gate and the
# can-fail suite exercise the same code; a green here reports on predicates
# the can-fail suite has driven red.

import std/[os, sets, strutils, tables, unittest]

const AGREEMENTS_TESTS_LOADED* = true

import ../src/agreements
import ../src/shader_config

func label(entry: Agreement): string =
  "entry `" & entry.key & "`"

proc sitePathsExist*(entry: Agreement): seq[string] =
  for site in entry.sites:
    if not fileExists(site.path):
      result.add entry.label & " names a missing file " & site.path

proc siteAnchorsFound*(entry: Agreement): seq[string] =
  for site in entry.sites:
    if not fileExists(site.path) or site.anchor notin readFile(site.path):
      result.add entry.label & " anchor `" & site.anchor &
        "` not found in " & site.path

func hasTwoSites*(entry: Agreement): seq[string] =
  if entry.sites.len < 2:
    result.add entry.label & " names " & $entry.sites.len &
      " site(s); an agreement is two-sided"

proc holderCitationFound*(entry: Agreement): seq[string] =
  if entry.tier == Unenforced:
    return
  if not fileExists(entry.holder.path):
    result.add entry.label & " claims " & $entry.tier &
      " held by a missing file " & entry.holder.path
  elif entry.holder.anchor notin readFile(entry.holder.path):
    result.add entry.label & " claims " & $entry.tier & " held by `" &
      entry.holder.anchor & "`, which " & entry.holder.path & " does not contain"

func reasonsPresent*(entry: Agreement): seq[string] =
  if entry.tier != Derived and entry.whyNotStronger.len == 0:
    result.add entry.label & " is " & $entry.tier &
      " and gives no reason it is not derived"
  if entry.tier == Unenforced and entry.wouldClose.len == 0:
    result.add entry.label & " is Unenforced and names nothing that would close it"

proc tableIsPopulated*(table: openArray[Agreement]): seq[string] =
  if table.len == 0:
    return @["the inventory is empty"]
  var named = initHashSet[string]()
  var resolved = 0
  for entry in table:
    for site in entry.sites:
      if site.path notin named:
        named.incl site.path
        if fileExists(site.path):
          inc resolved
  if resolved == 0:
    result.add "no path the inventory names resolves from " & getCurrentDir()

template checkClean(violations: seq[string]) =
  for violation in violations:
    checkpoint(violation)
  check violations.len == 0

suite "The Inventory Holds":
  test "the table is non-empty and its paths resolve from here":
    checkClean tableIsPopulated(AGREEMENTS)
    check AGREEMENTS.len > 0

  test "every site names a file that exists":
    for entry in AGREEMENTS:
      checkClean sitePathsExist(entry)

  test "every site's anchor occurs in its file":
    var sites = 0
    for entry in AGREEMENTS:
      checkClean siteAnchorsFound(entry)
      sites += entry.sites.len
    check sites > 0

  test "every entry names at least two sites":
    for entry in AGREEMENTS:
      checkClean hasTwoSites(entry)

  test "every held entry cites a holder its file contains":
    for entry in AGREEMENTS:
      checkClean holderCitationFound(entry)

  test "every entry below Derived says why, and every Unenforced entry what would close it":
    for entry in AGREEMENTS:
      checkClean reasonsPresent(entry)

  test "keys are unique":
    var keys = initHashSet[string]()
    for entry in AGREEMENTS:
      keys.incl entry.key
    check keys.len == AGREEMENTS.len

const ShaderSourceDirs = ["web" / "shaders" / "src", "web" / "shaders" / "modules"]

proc shaderSources(): Table[string, string] =
  ## Every shader source keyed by its stem, the name the bundler substitutes
  ## a per-shader workgroup size under.
  for dir in ShaderSourceDirs:
    for path in walkFiles(dir / "*.wgsl"):
      result[path.extractFilename.changeFileExt("")] = readFile(path)

suite "Every Emitted Placeholder Is Consumed":
  # The bundler fails on a placeholder no key emits. This is the reverse: a key
  # emitted against a shader that spells the value by hand instead. The subject
  # is enumerated from the map and the sources, so no entry is needed.

  test "every key getPlaceholderMap emits is read by a shader source":
    let placeholders = getPlaceholderMap()
    let sources = shaderSources()
    var rewritten = initHashSet[string]()
    for name, content in sources:
      if "{{WORKGROUP_SIZE}}" in content:
        rewritten.incl workgroupKeyFor(name)
    var unconsumed: seq[string]
    for key in placeholders.keys:
      if key in rewritten:
        continue
      var read = false
      for content in sources.values:
        if ("{{" & key & "}}") in content:
          read = true
          break
      if not read:
        unconsumed.add key
    for key in unconsumed:
      checkpoint("emitted and read by no shader: " & key)
    check unconsumed.len == 0
    check placeholders.len > 0
    check sources.len > 0
    check rewritten.len > 0

suite "Collapsed Agreements Stay Collapsed":
  # Source sweeps over modules the native suite cannot import: each names the
  # derivation that replaced a copy, so the copy cannot grow back.

  test "matrix_state reads the species ceiling from config_ranges":
    let content = readFile("src" / "ui" / "state" / "matrix_state.nim")
    check "SPECIES_COUNT_MAX" in content
    check "MATRIX_SIZE" notin content

  test "grid.nim sizes the grid through grid_core's oracle":
    # grid.nim pulls std/jsffi, so the native suite cannot import it; the
    # sweep is the available gate.
    let content = readFile("src" / "grid.nim")
    check "grid_core.computeGridDims" in content
    check "jsFloor(config.WORLD_W" notin content

suite "The Document Names No Entry":
  test "docs/agreements.md explains the inventory and lists none of it":
    # A second list of entries could disagree with the table, and nothing
    # would detect it.
    let path = "docs" / "agreements.md"
    check fileExists(path)
    let content = readFile(path)
    check "src/agreements.nim" in content
    for entry in AGREEMENTS:
      if entry.key in content:
        checkpoint("docs/agreements.md names entry `" & entry.key & "`")
      check entry.key notin content
    check AGREEMENTS.len > 0

func site(path, anchor: string): AgreementSite =
  AgreementSite(path: path, anchor: anchor)

const wellFormed = Agreement(
  key: "fixture",
  statement: "a fixture whose every site is this suite's own source",
  sites: @[
    site("tests" / "test_agreements.nim", "AGREEMENTS_TESTS_LOADED"),
    site("tests" / "test_all.nim", "import test_agreements")],
  tier: TestHeld,
  holder: site("tests" / "test_agreements.nim", "The Inventory Gate Can Fail"),
  whyNotStronger: "a fixture")

suite "The Inventory Gate Can Fail":
  test "the well-formed fixture passes every predicate":
    checkClean sitePathsExist(wellFormed)
    checkClean siteAnchorsFound(wellFormed)
    checkClean hasTwoSites(wellFormed)
    checkClean holderCitationFound(wellFormed)
    checkClean reasonsPresent(wellFormed)

  test "a nonexistent path is seen":
    var entry = wellFormed
    entry.sites[0].path = "tests" / "no_such_file.nim"
    let violations = sitePathsExist(entry)
    check violations.len == 1
    check "no_such_file.nim" in violations[0]

  test "an absent anchor is seen":
    var entry = wellFormed
    entry.sites[1].anchor = "this text appears in no test module"
    let violations = siteAnchorsFound(entry)
    check violations.len == 1
    check "test_all.nim" in violations[0]

  test "a one-site entry is seen":
    var entry = wellFormed
    entry.sites = entry.sites[0 .. 0]
    let violations = hasTwoSites(entry)
    check violations.len == 1
    check "fixture" in violations[0]

  test "a BuildAsserted entry citing absent text is seen":
    var entry = wellFormed
    entry.tier = BuildAsserted
    entry.holder = site("src" / "preset.nim", "doAssert no such assertion exists")
    let violations = holderCitationFound(entry)
    check violations.len == 1
    check "BuildAsserted" in violations[0]

  test "a holder in a missing file is seen":
    var entry = wellFormed
    entry.holder = site("tests" / "no_such_file.nim", "anything")
    let violations = holderCitationFound(entry)
    check violations.len == 1
    check "no_such_file.nim" in violations[0]

  test "an Unenforced entry with no closing note is seen":
    var entry = wellFormed
    entry.tier = Unenforced
    entry.wouldClose = ""
    let violations = reasonsPresent(entry)
    check violations.len == 1
    check "would close" in violations[0]

  test "an entry below Derived with no reason is seen":
    var entry = wellFormed
    entry.whyNotStronger = ""
    let violations = reasonsPresent(entry)
    check violations.len == 1
    check "not derived" in violations[0]

  test "an empty table is seen":
    let violations = tableIsPopulated(newSeq[Agreement]())
    check violations == @["the inventory is empty"]

  test "a table whose paths resolve nowhere is seen":
    var entry = wellFormed
    for index in 0 ..< entry.sites.len:
      entry.sites[index].path = "nowhere" / $index & ".nim"
    let violations = tableIsPopulated([entry])
    check violations.len == 1
    check "resolves" in violations[0]
