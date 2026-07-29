# ==============================================================================
# PARTICLE GARDEN - HELP CONTENT (compile-time)
# ==============================================================================
#
# docs/help/*.md staticRead at compile time — the mechanism the render shaders
# already use — one file per descriptor group plus orientation and glossary.
# Front matter is exactly three lines: ---, "group: <key>", ---. A group file
# names its controls in list lines of the form "- `id` — ...", which is the
# shape tests/test_help_content.nim holds the coverage relations over.

import std/strutils
import ../input/binding_table

const HelpSourceDir* = "docs/help"
  ## Repo-relative; the native suite walks it and holds the listing equal to
  ## HelpFileNames.

const HelpFileNames* = [
  "00-orientation.md",
  "10-simulation.md",
  "11-grid.md",
  "12-species.md",
  "20-force-polynomial.md",
  "21-force-exponential.md",
  "30-fluid.md",
  "40-rd.md",
  "41-rd-field.md",
  "42-chemistry.md",
  "50-render.md",
  "51-glow.md",
  "52-bloom.md",
  "53-palette.md",
  "60-camera.md",
  "90-glossary.md",
]
  ## The panel's section order.

const ReservedHelpKeys* = ["orientation", "reference", "glossary"]
  ## Keys that name no descriptor group. "reference" is generated from the
  ## binding table rather than read from a file.

type HelpEntry* = object
  key*: string   ## Descriptor group id, or a reserved key.
  body*: string  ## Markdown after the front matter.

func parseHelpEntry*(raw: string): HelpEntry =
  let lines = raw.splitLines()
  doAssert lines.len >= 4 and lines[0] == "---" and lines[2] == "---" and
    lines[1].startsWith("group: "),
    "help front matter is exactly ---, 'group: <key>', ---"
  HelpEntry(key: lines[1]["group: ".len .. ^1].strip(),
    body: lines[3 .. ^1].join("\n").strip())

func namedControlIds*(body: string): seq[string] =
  ## The ids a file names, from its "- `id` ..." list lines.
  for line in body.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("- `"):
      let rest = stripped[3 .. ^1]
      let closeTick = rest.find('`')
      if closeTick > 0:
        result.add rest[0 ..< closeTick]

func bindingReferenceBody*(): string =
  ## The gesture and key reference, generated from the binding table — a
  ## binding cannot exist without appearing here, because this renders the
  ## same rows the handlers read. Bulleted with strong gestures, not code
  ## spans, so namedControlIds keeps reading only control lines.
  result = "# Gestures & Keys"
  var lastDevice = bdMouse
  var first = true
  for binding in InputBindings:
    if first or binding.device != lastDevice:
      result.add "\n\n## " & $binding.device & "\n"
      lastDevice = binding.device
      first = false
    result.add "\n- **" & binding.gesture & "** — " & binding.description

const HelpEntries* = block:
  # Parsed at compile time, so a malformed file fails the build. The
  # generated reference slots in just before the glossary.
  var entries: seq[HelpEntry] = @[]
  for name in HelpFileNames:
    entries.add parseHelpEntry(staticRead("../../../" & HelpSourceDir & "/" & name))
  entries.insert(HelpEntry(key: "reference", body: bindingReferenceBody()),
    entries.len - 1)
  entries
