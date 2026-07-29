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

import std/[strutils, sets, algorithm, tables]

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

# ==============================================================================
# BIND-GROUP BINDING NUMBERS
# ==============================================================================
#
# render.wgsl and glow.wgsl share ONE hand-built bind-group layout in
# webgpu_render.nim; nothing checks that the two shaders' @binding numbers
# still agree with it or with each other. A swapped or added binding compiles,
# bundles, and builds green — the GPU rejects the pipeline only at runtime,
# and the symptom is a blank canvas. Same shape as the named-field constructor
# above, one step earlier in the pipeline: a fact living in two places (the
# shader text, the bind group built against it) with nothing that fails
# loudly when they disagree.

func bindingsDeclared*(code: string): seq[int] =
  ## Sorted, deduplicated `@binding(N)` numbers a shader declares.
  ##
  ## A trailing `//` comment is stripped from each line before the scan, so
  ## prose that merely mentions a binding number can never inflate the set —
  ## the same false-positives-forbidden stance as namedFieldConstructorLines.
  ## A `/* */` block comment is NOT stripped; no bundled shader uses one
  ## today, so this is a recorded blind spot (see the tests) rather than a
  ## parser worth the complexity to close.
  const marker = "@binding("
  var seen: HashSet[int]
  for rawLine in code.splitLines:
    let commentAt = rawLine.find("//")
    let line = if commentAt >= 0: rawLine[0 ..< commentAt] else: rawLine
    var searchFrom = 0
    while true:
      let markerAt = line.find(marker, searchFrom)
      if markerAt < 0:
        break
      let numStart = markerAt + marker.len
      var numEnd = numStart
      while numEnd < line.len and line[numEnd] in {'0'..'9'}:
        inc numEnd
      if numEnd > numStart and numEnd < line.len and line[numEnd] == ')':
        seen.incl(parseInt(line[numStart ..< numEnd]))
      searchFrom = numStart
  for binding in seen:
    result.add(binding)
  result.sort()

# ==============================================================================
# EXPECTED-BINDINGS MANIFEST
# ==============================================================================
#
# One table, read by both tools/wgsl_bundle.nim (fails the build on mismatch or
# on a shader absent from this table) and tests/test_wgsl_lint.nim (asserts the
# bundled output still matches). Keys are bundled shader names — the filename
# under web/shaders/ with ".wgsl" stripped, exactly what wgsl_bundle.bundle's
# shaderName holds. Values are the DECLARED set per shader, not a shared-layout
# prefix: glow shares render's layout but skips a binding, so contiguity is
# never assumed here — every entry is read off the actual bundle.

const ExpectedShaderBindings*: Table[string, seq[int]] = {
  # Compute shaders (shader_manifest.nim / sim_registry.nim dispatch keys).
  "bin-count": @[0, 1, 2],
  "bin-scatter": @[0, 1, 2, 3, 4, 5],
  "prefix-sum-local": @[0, 1, 2, 3],
  "prefix-sum-blocks": @[0, 1, 2],
  "prefix-sum-final": @[0, 1, 2],
  "forces": @[0, 1, 2, 3, 4, 5, 6, 7],  # binding 7 is the crowd-density accumulator
  "forces-sph": @[0, 1, 2, 3, 4, 5, 6],
  "integrate": @[0, 1, 2, 3, 4, 5],  # binding 5 resolves the crowd density
  "field-seed": @[0, 1],
  "field-deposit": @[0, 1, 2, 3, 4],
  "field-resolve": @[0, 1, 2, 3],  # binding 3 is the one-word alive-cell counter the dormancy signal reads back
  "rd-step": @[0, 1, 2, 3],
  "field-force": @[0, 1, 2, 3, 4, 5],
  # Render shaders (staticRead into app.js by webgpu_render.nim).
  "render": @[0, 1, 2, 3, 4],
  "glow": @[0, 1, 2, 4],  # binding 3 (render's fieldTexture) legally absent — glow never samples the RD field
  "fade": @[0, 1, 2, 3, 4, 5],  # binding 5 is the PREVIOUS frame's camera, the second Camera record the trail reprojection reads
  "tonemap": @[0, 1, 2, 3, 4, 5],
  "field-composite": @[0, 1, 2, 3],
  "composite": @[0, 1],
  "blur": @[0, 1, 2],
  "overlay": @[0, 1, 2],
}.toTable
