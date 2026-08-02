# A gate over the test suite itself.
#
# Nothing else notices when an assertion stops examining anything. A sweep
# whose subject went empty finds no offender, reports nothing, and reads in
# every log exactly like coverage. The suite here had four such tests, one of
# them live: web/shaders/*.wgsl is gitignored bundler output and `just check`
# never runs the bundler, so on a clone that has never built, the sweep that
# protects the render bind-group layout passed over an empty directory.
#
# THE RULE. A test block that reads the filesystem must assert something
# positive about what it read. Stated mechanically: if every `check` and
# `require` in the block compares to zero, the block proves nothing when the
# subject is empty, and fails here.
#
# WHY FILESYSTEM ACCESS IS THE TRIGGER. The subject that can silently go empty
# is the one the test does not declare — a directory that moved, output that
# was never generated, a working directory the runner did not expect. A test
# asserting `.len == 0` over a string literal written three lines above it
# cannot suffer this, and flagging those would earn only exemptions.
#
# WHAT SATISFIES IT. Any assertion that is not a comparison to zero: a count
# guard (`check swept > 0`), a set equality, an expected value. Where the
# positive assertion is one a machine cannot recognise — a set equality is
# non-vacuous by construction, and unreadably so from source text — write the
# count guard alongside it. test_wgsl_lint.nim carries one such pair.

import std/[unittest, os, strutils, sequtils]

const META_VACUITY_TESTS_LOADED* = true

const
  TestSourceDir = "tests"
  FilesystemReaders = ["readFile", "walkFiles", "walkDirRec", ".lines"]
    ## Reading any of these makes the subject external, and therefore able to
    ## be empty for reasons no line of the test states. `.lines` carries its
    ## dot because the bare word is a substring of `namedFieldConstructorLines`
    ## and every other identifier ending in it.
  AssertionOpeners = ["check ", "require ", "check(", "require("]

type TestBlock = object
  file: string
  name: string
  body: seq[string]

func quotedName(line: string): string =
  ## The test name out of a `test "..."` line.
  let opening = line.find('"')
  let closing = line.rfind('"')
  if closing > opening: line[opening + 1 ..< closing] else: ""

proc testBlocks(path: string): seq[TestBlock] =
  ## Every `test` block in `path`, its body stripped of indentation.
  ##
  ## A block runs from its `test "..."` line to the next `test` or `suite`,
  ## which over-reads a `test` nested inside a helper proc. No test in this
  ## suite nests one, and an over-read block can only add assertions, so the
  ## error direction is toward passing a real offender rather than failing an
  ## innocent test — the direction a gate on other people's tests should lean.
  var current = TestBlock(file: path)
  var open = false
  for line in path.lines:
    let stripped = line.strip()
    let opensTest = stripped.startsWith("test \"")
    if opensTest or stripped.startsWith("suite \""):
      if open:
        result.add current
      open = opensTest
      current = TestBlock(file: path, name: if opensTest: quotedName(stripped) else: "")
      continue
    if open and not stripped.startsWith("#"):
      current.body.add stripped
  if open:
    result.add current

func readsFilesystem(blk: TestBlock): bool =
  for line in blk.body:
    for reader in FilesystemReaders:
      if reader in line:
        return true

func assertions(blk: TestBlock): seq[string] =
  for line in blk.body:
    for opener in AssertionOpeners:
      if line.startsWith(opener):
        result.add line
        break

func comparesToZero(assertion: string): bool =
  assertion.endsWith("== 0") or ".len == 0" in assertion

suite "No Test Sweeps A Subject That Can Be Empty":
  test "every filesystem-reading test asserts something beyond an absence":
    var swept = 0
    var sweeps = 0
    var offenders: seq[string]
    for path in walkFiles(TestSourceDir / "*.nim"):
      inc swept
      for blk in testBlocks(path):
        if not blk.readsFilesystem:
          continue
        inc sweeps
        let checks = blk.assertions
        # An empty `checks` flags too, and deliberately: a block that reads a
        # file and asserts nothing recognisable is the same defect further
        # along. Every assertion in this suite opens with one of
        # AssertionOpeners on its own line — unittest's `check:` block form
        # appears nowhere — so an empty list means no assertion, never an
        # unparsed one.
        if checks.allIt(it.comparesToZero):
          offenders.add(blk.file.extractFilename & ": \"" & blk.name &
            "\" asserts only " & checks.join(" / "))

    for offender in offenders:
      checkpoint(offender)
    check offenders.len == 0

    # This test is itself a filesystem sweep, so it owes what it demands. Both
    # lines: the test files had to be found, and among them the blocks this
    # gate exists to police.
    check swept > 0
    check sweeps > 0
