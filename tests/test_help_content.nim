# PARTICLE GARDEN - HELP COVERAGE TESTS
#
# The four coverage relations that keep the documentation true: every group
# has a file, every declared key exists, every descriptor is named by its
# group's file, and no file names a non-descriptor. A control renamed without
# its documentation following goes red here, at the rename.

import std/[os, sequtils, sets, strutils, tables, unittest]

const HELP_CONTENT_TESTS_LOADED* = true

import ../src/ui/api/help_content
import ../src/ui/api/param_descriptor
import ../src/ui/input/shipped_mapping
import ../src/ui/input/control_matrix

let helpDir = currentSourcePath().parentDir.parentDir / HelpSourceDir

let descriptors = buildParamDescriptors()
var descriptorIds = initHashSet[string]()
var groupIds = initHashSet[string]()
for descriptor in descriptors:
  descriptorIds.incl descriptor.id
  groupIds.incl descriptor.group

var entriesByKey = initTable[string, HelpEntry]()
for entry in HelpEntries:
  entriesByKey[entry.key] = entry

suite "Help Files Match The Directory":
  test "docs/help holds exactly the declared files":
    check dirExists(helpDir)
    var onDisk = initHashSet[string]()
    for kind, path in walkDir(helpDir):
      if kind == pcFile:
        onDisk.incl path.extractFilename
    check onDisk == HelpFileNames.toSeq.toHashSet

  test "keys are unique across entries":
    check entriesByKey.len == HelpEntries.len

suite "Coverage Runs In Both Directions":
  test "every descriptor group has a help file":
    for group in groupIds:
      if group notin entriesByKey:
        checkpoint("group \"" & group & "\" has no help file")
      check group in entriesByKey

  test "every declared key is a descriptor group or reserved":
    for entry in HelpEntries:
      check entry.key in groupIds or entry.key in ReservedHelpKeys

  test "every descriptor is named by its group's file":
    for descriptor in descriptors:
      let named = namedControlIds(entriesByKey[descriptor.group].body)
      if descriptor.id notin named:
        checkpoint(descriptor.id & " is not named by its group's file")
      check descriptor.id in named

  test "no help file names an id that is not a descriptor":
    for entry in HelpEntries:
      for id in namedControlIds(entry.body):
        if id notin descriptorIds:
          checkpoint(entry.key & " names unknown control `" & id & "`")
        check id in descriptorIds

suite "The MIDI Help File Covers The Shipped Mapping":
  test "docs/help holds the MIDI file":
    check fileExists(helpDir / "70-midi.md")

  test "each family's help file names every shipped mapping row's target":
    # Derived from DEFAULT_MAPPING itself, not spelled out here, so a shipped
    # row added or retargeted moves this relation instead of leaving it to
    # drift from what actually ships. A row's family is its source id's first
    # segment: the audio rows are the audio help's, and every other row,
    # the clock-driven tours included, is the MIDI help's.
    require "midi" in entriesByKey
    require "audio" in entriesByKey
    var missing: seq[string]
    for row in DEFAULT_MAPPING:
      let key = if row.sourceId.startsWith("audio:"): "audio" else: "midi"
      let target =
        case row.kind
        of rkWrite: row.writeParamId
        of rkFire: row.actionId
        of rkTouch: row.sourceId
        of rkTour: row.tourId
        of rkModulate: row.modParamId
      if target notin entriesByKey[key].body:
        missing.add key & " lacks " & target
    check missing.len == 0
    if missing.len > 0:
      echo "  help is missing: ", missing.join(", ")

suite "The Coverage Sweep Can Fail":
  test "a control line with a bogus id is seen":
    check namedControlIds("- `notAControl` — nothing\n") == @["notAControl"]

  test "a malformed front matter fails the parse":
    expect AssertionDefect:
      discard parseHelpEntry("no front matter at all")

  test "a well-formed entry round-trips key and body":
    let entry = parseHelpEntry("---\ngroup: glow\n---\n\n# Glow\n\nbody\n")
    check entry.key == "glow"
    check entry.body == "# Glow\n\nbody"
