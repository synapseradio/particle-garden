# ==============================================================================
# PARTICLE GARDEN - PANEL REACHABILITY GUARD TESTS
# ==============================================================================
#
# A descriptor is a promise that a control exists. Nim builds the descriptor
# table and the panel lays it out, and nothing on either side checks that the
# layout covers the table — a descriptor the panel never places is a parameter
# with a range, a default, a hint and no way to reach it.
#
# This suite reads the panel source and asks, for every descriptor, whether the
# panel places it. A control reaches the screen two ways: the panel names its
# id directly, or it names the group the id belongs to and loops the group's
# members. Either counts.
#
# Precedent: tests/test_no_modes.nim reads real source from disk and asserts
# the file it read was actually found, so a sweep over a missing or wrong-cwd
# tree cannot pass by finding nothing. This suite follows that shape.
#
# Run with: just test
#
# ==============================================================================

import std/[unittest, os, strutils]
import ../src/ui/api/param_descriptor

const PANEL_REACHABILITY_TESTS_LOADED* = true

const PANEL_FILE = "web-ui" / "src" / "components" / "Panel.tsx"

func namesId(panel, id: string): bool =
  ## The panel places a control by id when it passes the id as a quoted
  ## string, either standalone or inside a `For each` list.
  ("\"" & id & "\"") in panel

func namesGroup(panel, group: string): bool =
  ## The panel places a whole group by looping the ids `groupIds` returns for
  ## it. Matched on the call rather than the bare string so a group id
  ## appearing in a comment or a CSS class cannot count as layout.
  ("groupIds(\"" & group & "\")") in panel

suite "Every Descriptor Reaches The Panel":
  test "the panel source is where this suite says it is":
    # Without this the sweep below passes vacuously from the wrong working
    # directory, which would make it silently worthless.
    check fileExists(PANEL_FILE)
    check readFile(PANEL_FILE).len > 0

  test "every descriptor is placed by its id or by its group":
    # THE DEFECT THIS PINS. A control the panel never places is unreachable by
    # anyone using the panel, however complete its descriptor looks: range,
    # step, notches and hint all describe a slider that is not on screen.
    # Keyboard and mouse gestures do not excuse it — they are a second path to
    # a control, never the only one.
    let panel = readFile(PANEL_FILE)
    require panel.len > 0
    var unplaced: seq[string]
    for descriptor in buildParamDescriptors():
      if not (namesId(panel, descriptor.id) or
              namesGroup(panel, descriptor.group)):
        unplaced.add(descriptor.id & " (group " & descriptor.group & ")")
    check unplaced.len == 0
    if unplaced.len > 0:
      echo "  Descriptors the panel never places: ", unplaced.join(", ")

  test "the guard rejects a descriptor whose group the panel never loops":
    # THE NON-VACUOUS CHECK. Both predicates are substring tests, and a
    # substring test that matched everything would pass the sweep above for
    # the wrong reason. An id and a group the panel cannot contain must both
    # come back unplaced.
    let panel = readFile(PANEL_FILE)
    check not namesId(panel, "noSuchParameter")
    check not namesGroup(panel, "no-such-group")
