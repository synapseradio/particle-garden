# The justfile and particle_garden.nimble each carry the compiler flag list,
# and the justfile's own comment says the two "must stay in sync". A comment
# cannot check that. This does.
#
# Why two lists exist at all: the just recipes invoke `nim` directly because
# nimble 0.22.2 exits 0 even when a task's exec fails, so a nimble-based recipe
# cannot fail a build. The nimble tasks stay for manual use. Both therefore
# compile the same sources, and a flag present in one alone means a warning
# that is fatal through one entry point and silent through the other.

import std/[unittest, strutils, algorithm]

const BUILD_FLAGS_TESTS_LOADED* = true

const
  Justfile = "justfile"
  Nimblefile = "particle_garden.nimble"

func flagTokens(text: string): seq[string] =
  ## Every compiler flag in `text`, sorted, with duplicates kept.
  ##
  ## Sorted because neither file's order is meaningful to `nim` and holding
  ## them to an order would fail on a rearrangement that changes no build.
  for token in text.split({' ', '"'}):
    if token.startsWith("--") or token.startsWith("-d:"):
      result.add token
  result.sort()

proc flagsOnLinesContaining(path: string; needles: openArray[string]): seq[string] =
  ## The flags on every line of `path` holding any of `needles`.
  for line in readFile(path).splitLines():
    for needle in needles:
      if needle in line:
        result.add flagTokens(line)
        break
  result.sort()

suite "The Two Build Entry Points Compile With The Same Flags":
  test "the justfile and the nimble file agree on the quality flags":
    # The justfile holds them on one line; the nimble file splits them across
    # styleFlags and warningFlags and concatenates. Compared as sorted sets,
    # so the split is free to move.
    let fromJust = flagsOnLinesContaining(Justfile, ["quality_flags :="])
    let fromNimble = flagsOnLinesContaining(Nimblefile,
      ["const styleFlags", "const warningFlags"])

    if fromJust != fromNimble:
      for flag in fromJust:
        if flag notin fromNimble:
          checkpoint(Justfile & " has " & flag & ", " & Nimblefile & " does not")
      for flag in fromNimble:
        if flag notin fromJust:
          checkpoint(Nimblefile & " has " & flag & ", " & Justfile & " does not")
    check fromJust == fromNimble

    # NON-VACUITY. Both files are read from the repository root, and a wrong
    # working directory or a rename would otherwise compare two empty lists.
    check fromJust.len > 0

  test "the justfile and the nimble file agree on the release flags":
    # js adds -d:release; native adds --opt:speed on top of it. Read from the
    # lines that define them rather than from the recipes, because the recipes
    # interpolate.
    let fromJust = flagsOnLinesContaining(Justfile,
      ["js_flags :=", "native_flags :="])
    let fromNimble = flagsOnLinesContaining(Nimblefile,
      ["const jsFlags", "const nativeFlags"])

    if fromJust != fromNimble:
      checkpoint(Justfile & ": " & fromJust.join(" "))
      checkpoint(Nimblefile & ": " & fromNimble.join(" "))
    check fromJust == fromNimble
    check fromJust.len > 0

  test "the justfile and the nimble file agree on the Windows static flags":
    let fromJust = flagsOnLinesContaining(Justfile, ["windows_static_flags :="])
    let fromNimble = flagsOnLinesContaining(Nimblefile,
      ["const windowsStaticFlags"])

    if fromJust != fromNimble:
      checkpoint(Justfile & ": " & fromJust.join(" "))
      checkpoint(Nimblefile & ": " & fromNimble.join(" "))
    check fromJust == fromNimble
    check fromJust.len > 0
