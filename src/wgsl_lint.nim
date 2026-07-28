# ==============================================================================
# PARTICLE GARDEN - WGSL LINT (Pure Source Checks)
# ==============================================================================
#
# Checks on WGSL source text that the Nim compiler cannot make, because WGSL is
# compiled by the browser at run time. Everything here is a pure function over a
# string, so tests/test_wgsl_lint.nim can exercise it and tools/wgsl_bundle.nim
# can fail the build on it.
#
# The build is the only place these can fire usefully. A WGSL parse error does
# not degrade one shader — it invalidates the pipeline that uses it, which makes
# the whole frame's submission fail, which draws nothing. The symptom is a black
# window with a green build behind it, and no Nim-side signal at all.
#
# Used by:
#   - tools/wgsl_bundle.nim (fails the build)
#   - tests/test_wgsl_lint.nim (native tests)
#
# ==============================================================================

import std/strutils

# ==============================================================================
# NAMED-FIELD STRUCT CONSTRUCTORS
# ==============================================================================
#
# WGSL struct constructors are POSITIONAL only. `Camera(centerX: x, zoom: z)`
# is Nim/Rust habit and a WGSL parse error, and it is a comfortable mistake to
# make in this codebase specifically, because the struct being constructed was
# generated from a Nim object where that syntax is correct.

func isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

func precededByFn(line: string, identStart: int): bool =
  ## Whether the identifier at identStart is a function being DECLARED.
  ## `fn cameraToClip(worldPos: vec2f, ...)` is a parameter list, not a
  ## constructor, and its `name: type` pairs are correct WGSL.
  var i = identStart - 1
  while i >= 0 and line[i] in {' ', '\t'}:
    dec i
  i >= 1 and line[i] == 'n' and line[i - 1] == 'f' and
    (i - 2 < 0 or not isIdentChar(line[i - 2]))

func namedFieldConstructorLines*(code: string): seq[int] =
  ## 1-indexed lines where a struct constructor names its fields.
  ##
  ## Deliberately narrow: it only flags a call whose callee starts with an
  ## uppercase letter. Every struct type here is PascalCase (Camera,
  ## FadeParams, VertexOutput) and every WGSL builtin is lowerCamel, so that one
  ## restriction separates constructors from `textureSample(...)` and from
  ## `for (var i: u32 = 0u; ...)` without needing to parse WGSL. A false
  ## positive would block every build, which is a worse failure than the one
  ## this prevents — so when in doubt it stays quiet.
  var lineNumber = 0
  for line in code.splitLines:
    inc lineNumber
    if line.strip.startsWith("//"):
      continue
    for i in 0 ..< line.len:
      if line[i] != '(':
        continue

      # The callee: the identifier ending just before the paren.
      var identEnd = i - 1
      while identEnd >= 0 and line[identEnd] in {' ', '\t'}:
        dec identEnd
      var identStart = identEnd
      while identStart >= 0 and isIdentChar(line[identStart]):
        dec identStart
      inc identStart
      if identStart > identEnd or line[identStart] notin {'A'..'Z'}:
        continue
      if precededByFn(line, identStart):
        continue

      # The first argument: an identifier followed by a colon means a field
      # name, which positional-only WGSL cannot parse.
      var argStart = i + 1
      while argStart < line.len and line[argStart] in {' ', '\t'}:
        inc argStart
      var argEnd = argStart
      while argEnd < line.len and isIdentChar(line[argEnd]):
        inc argEnd
      if argEnd == argStart:
        continue
      var colon = argEnd
      while colon < line.len and line[colon] in {' ', '\t'}:
        inc colon
      if colon < line.len and line[colon] == ':':
        result.add(lineNumber)
        break
