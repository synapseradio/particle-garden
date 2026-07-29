# Nim owns every parameter fact and the panel restates none of them, but the
# two sides cannot type-check each other. These suites read the panel's own
# source and fail on the disagreements a compiler cannot see.
#
# REACHABILITY. A descriptor is a promise that a control exists. Nim builds the
# descriptor table and the panel lays it out, and a descriptor the panel never
# places is a parameter with a range, a default, a hint and no way to reach it.
# A control reaches the screen two ways: the panel names its id directly, or it
# names the group the id belongs to and loops the group's members.
#
# DERIVATION. The panel must reach a Nim-owned list by asking for it. A list
# the panel keeps its own copy of drifts silently, because nothing on the TS
# side derives from anything: the copy stays syntactically fine while the
# simulation moves on without it. The climate's written parameters are one
# such list, so the panel is checked for quoting them.
#
# Precedent: tests/test_no_modes.nim reads real source from disk and asserts
# the file it read was actually found, so a sweep over a missing or wrong-cwd
# tree cannot pass by finding nothing. These suites follow that shape.

import std/[unittest, os, strutils]
import ../src/ui/api/param_descriptor
import ../src/climate_core

const PANEL_REACHABILITY_TESTS_LOADED* = true

const PANEL_FILE = "web-ui" / "src" / "components" / "Panel.tsx"
const STATE_FILE = "web-ui" / "src" / "state.ts"

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
    # The defect this pins: a control the panel never places is unreachable by
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

suite "The Panel Derives The Climate's Written Parameters":
  test "the controller source is where this suite says it is":
    # Same vacuity guard the sweep above carries: a check that reads nothing
    # passes for the wrong reason.
    check fileExists(STATE_FILE)
    check readFile(STATE_FILE).len > 0

  test "the controller quotes no parameter the climate writes":
    # The defect this pins: the weather walks these ids from the frame loop and
    # the controller re-reads them; held as a second copy in TypeScript, an
    # added axis leaves the simulation drifting on a coordinate the panel never
    # reads back, and every file still compiles. The controller must ask
    # gardenAPI which ids the climate writes rather than spelling them out.
    let state = readFile(STATE_FILE)
    require state.len > 0
    var restated: seq[string]
    for axis in ClimateAxis:
      if namesId(state, CLIMATE_PARAM_IDS[axis]):
        restated.add(CLIMATE_PARAM_IDS[axis])
    check restated.len == 0
    if restated.len > 0:
      echo "  Climate ids the controller restates: ", restated.join(", ")

  test "the controller asks gardenAPI for them":
    # The other half of the same claim. Quoting none of the ids is what a file
    # that had dropped the feature entirely would also do, so name the call
    # that supplies them. Reduced to a bool before the check so a failure
    # reports the verdict rather than echoing the whole file.
    let asksNim = "climateParamIds" in readFile(STATE_FILE)
    check asksNim

  test "the quoting guard can find a quoted id":
    # THE NON-VACUOUS CHECK, both directions. The predicate must find a literal
    # in source that has one, and must not find one that is absent — otherwise
    # the sweep above is satisfied by a search that never matches anything.
    check namesId("""const ids = ["rdFeed", "rdKill"];""", "rdFeed")
    check not namesId(readFile(STATE_FILE), "noSuchParameter")
