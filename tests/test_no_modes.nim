#
# The simulation MODE concept is deleted: a world composes couplings freely,
# never selects one of a fixed list of kinds. This suite sweeps src/ and
# web-ui/src/ for the vocabulary a mode model used — its type, its id
# round-trip pair, its string catalog, its getter/setter pair — so the
# concept cannot grow back under a name that once meant something here.
#
# Precedent: tests/test_wgsl_lint.nim reads real source from disk and asserts
# the directory it reads was actually found, so a sweep over an empty or
# wrong-cwd tree cannot pass by finding nothing. This suite follows the same
# shape: a sweep, plus a check that the sweep looked at real files.

import std/[unittest, os, strutils]

const NO_MODES_TESTS_LOADED* = true

const FORBIDDEN_IDENTIFIERS = [
  "SimKind", "simKindId", "parseSimKind", "couplingsFor", "controlGroupsFor",
  "simKindCeiling", "setSimMode", "getSimMode", "simModes",
]
  ## Every name a SimKind-based world used: the enum itself, the id
  ## round-trip pair, the two lookups that turned a kind into a frame or a
  ## control set, the per-kind particle ceiling, and the API's own mode
  ## getter/setter. A world is couplings now, so none of these has a live
  ## referent to name.

const FORBIDDEN_MODE_STRINGS = [
  "\"particle-life\"", "\"sph\"", "\"reaction-diffusion\"",
]
  ## The three ids a SimKind serialized as, quoted so a hit requires the
  ## literal token: `sphRestDensity`, `forces-sph.wgsl`, and `atmosphere`
  ## all carry `sph` as a substring, none as a standalone quoted string, and
  ## none matches.

const SWEEP_ROOTS = ["src", "web-ui" / "src"]
const SWEEP_EXTENSIONS = [".nim", ".ts", ".tsx"]

#
# src/preset.nim's LEGACY_MODE_COUPLINGS maps each pre-2.0 mode id to the
# coupling strengths that mode meant, so migrate's fromVersion < 2 branch can
# translate an old preset file. Nothing above it in the file consults the
# table and no live path reaches it: it decodes a mode out of a file written
# before modes existed, which is a different thing from the running program
# naming one. That claim is exactly what the two tests below check, so the
# exemption stops applying the moment the claim stops being true.
#
# The exemption is the table's own source span, not the whole file: masking
# only that span means a mode concept added anywhere else in preset.nim is
# still caught by the same sweep as every other file.

const PRESET_FILE = "src" / "preset.nim"
const LEGACY_TABLE_START = "const LEGACY_MODE_COUPLINGS"
const LEGACY_TABLE_END = "proc legacyCouplingsFor"

func maskLegacyTable(content: string): string =
  ## Preserves newlines so every other line keeps its real line number; the
  ## masked span leaves nothing for the mode-string sweep to match.
  result = content
  let startIdx = content.find(LEGACY_TABLE_START)
  let endIdx = content.find(LEGACY_TABLE_END)
  if startIdx >= 0 and endIdx > startIdx:
    for i in startIdx ..< endIdx:
      if result[i] != '\n':
        result[i] = ' '

func isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

func wholeWordOffsets(content, needle: string): seq[int] =
  ## Byte offsets of `needle` bounded by non-identifier characters (or a text
  ## edge) on both sides, so `parseSimKind` cannot fire on a longer
  ## identifier that merely contains it as a substring.
  var start = 0
  while true:
    let idx = content.find(needle, start)
    if idx < 0: break
    let before = idx - 1
    let after = idx + needle.len
    if (before < 0 or not isIdentChar(content[before])) and
       (after >= content.len or not isIdentChar(content[after])):
      result.add idx
    start = idx + 1

func literalOffsets(content, needle: string): seq[int] =
  ## Byte offsets of `needle`, verbatim. Used for the quoted mode-id strings,
  ## where the quote characters already bound the match on both sides.
  var start = 0
  while true:
    let idx = content.find(needle, start)
    if idx < 0: break
    result.add idx
    start = idx + 1

func lineAt(content: string, offset: int): int =
  ## 1-based line number containing byte `offset`, for a failure message
  ## that points at a line instead of a raw byte position.
  result = 1
  for i in 0 ..< offset:
    if content[i] == '\n': inc result

proc sweptFiles(): seq[string] =
  for root in SWEEP_ROOTS:
    if not dirExists(root): continue
    for path in walkDirRec(root):
      if path.splitFile.ext in SWEEP_EXTENSIONS:
        result.add path

suite "The Legacy Mode Table Stays Honest":
  test "LEGACY_MODE_COUPLINGS is where the exemption says it is":
    # Without this the exemption below can go stale silently: if the markers
    # stop matching, maskLegacyTable masks nothing, and the mode-string sweep
    # would then flag preset.nim's own legitimate legacy table as an offender
    # instead of exempting it.
    let content = readFile(PRESET_FILE)
    check content.find(LEGACY_TABLE_START) >= 0
    check content.find(LEGACY_TABLE_END) > content.find(LEGACY_TABLE_START)

  test "the exempted span still names all three legacy modes":
    # THE NON-VACUOUS CHECK. The exemption is honest only while the span it
    # covers really is the mode-id table, not an emptied stub still wearing
    # the table's name. If a future edit drops one of the three ids, this
    # fails alongside the sweep it excuses, rather than the sweep passing for
    # the wrong reason.
    let content = readFile(PRESET_FILE)
    let startIdx = content.find(LEGACY_TABLE_START)
    let endIdx = content.find(LEGACY_TABLE_END)
    require startIdx >= 0 and endIdx > startIdx
    let exempt = content[startIdx ..< endIdx]
    for lit in FORBIDDEN_MODE_STRINGS:
      check lit in exempt

suite "No Mode Concept In Source":
  test "no forbidden mode identifier appears in src/ or web-ui/src/":
    var offenders: seq[string]
    for path in sweptFiles():
      let content = readFile(path)
      for id in FORBIDDEN_IDENTIFIERS:
        for offset in wholeWordOffsets(content, id):
          offenders.add(path & ":" & $lineAt(content, offset) & " " & id)
    check offenders.len == 0
    if offenders.len > 0:
      echo "  Mode identifiers found: ", offenders.join(", ")

  test "no mode-id string literal appears in src/ or web-ui/src/ outside the legacy table":
    var offenders: seq[string]
    for path in sweptFiles():
      var content = readFile(path)
      if path == PRESET_FILE:
        content = maskLegacyTable(content)
      for lit in FORBIDDEN_MODE_STRINGS:
        for offset in literalOffsets(content, lit):
          offenders.add(path & ":" & $lineAt(content, offset) & " " & lit)
    check offenders.len == 0
    if offenders.len > 0:
      echo "  Mode-id strings found: ", offenders.join(", ")

  test "the swept source directories were actually found":
    # Without this the two sweeps above pass vacuously when run from the
    # wrong working directory, which would make them silently worthless.
    check dirExists("src")
    check dirExists(SWEEP_ROOTS[1])
