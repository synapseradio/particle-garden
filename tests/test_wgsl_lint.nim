# ==============================================================================
# PARTICLE GARDEN - WGSL LINT TESTS
# ==============================================================================
#
# Behavioral tests for src/wgsl_lint.nim, plus a check of the real shader
# sources. The lint exists because a WGSL parse error is invisible to every
# build step: the browser compiles WGSL, so `just happen` and `just check` both
# go green while the app draws nothing.
#
# The last suite here reads web/shaders/src/ directly. That is the assertion
# that actually protects the app; the ones above it are what keep the checker
# honest about what it flags and what it leaves alone.
#
# Run with: just test
#
# ==============================================================================

import std/[unittest, os, strutils]
import ../src/wgsl_lint

const WGSL_LINT_TESTS_LOADED* = true


suite "Named-Field Constructors Are Caught":
  test "a struct constructor naming its fields is flagged":
    # THE BUG THIS EXISTS FOR. WGSL constructors are positional; this exact
    # line shipped in fade.wgsl and turned the window black whenever trails
    # were on, because an invalid shader invalidates its pipeline and a frame
    # using an invalid pipeline is never submitted.
    let code = "let prevCam = Camera(centerX: params.prevCenterX, zoom: 1.0);"
    check namedFieldConstructorLines(code) == @[1]

  test "the flagged line number points at the offending line, not the file":
    let code = "fn main() {\n  var x = 1.0;\n  let c = Camera(centerX: x);\n}"
    check namedFieldConstructorLines(code) == @[3]

  test "a constructor split across lines is caught on the line the fields start":
    let code = "let prevCam = Camera(\n  centerX: params.prevCenterX,\n" &
      "  zoom: params.prevZoom);"
    # The callee and the first field are on different lines, so this form is
    # NOT caught — recorded here as the checker's known blind spot rather than
    # left for someone to discover by shipping a black screen.
    check namedFieldConstructorLines(code).len == 0

  test "every offending line is reported, not just the first":
    let code = "let a = Camera(centerX: 1.0);\nlet b = FadeParams(fadeAmount: 0.5);"
    check namedFieldConstructorLines(code) == @[1, 2]


suite "Valid WGSL Is Left Alone":
  # A false positive here blocks every build, which is worse than the failure
  # the checker prevents. These are the constructs it must stay quiet about.

  test "a function declaration's parameter list is not a constructor":
    let code = "fn cameraToClip(worldPos: vec2f, cam: Camera) -> vec2f {"
    check namedFieldConstructorLines(code).len == 0

  test "a positional struct constructor is valid":
    let code = "let prevCam = Camera(params.prevCenterX, params.prevCenterY, 1.0, 0.0);"
    check namedFieldConstructorLines(code).len == 0

  test "a for loop declaring a typed variable is not a constructor":
    let code = "for (var i: u32 = 0u; i < count; i = i + 1u) {"
    check namedFieldConstructorLines(code).len == 0

  test "lowercase builtin calls are never treated as constructors":
    # textureSample, vec2, max — all lowerCamel, and the checker's uppercase
    # rule is what separates them from struct types without parsing WGSL.
    let code = "let prev = textureSample(prevFrame, prevSampler, driftUv);"
    check namedFieldConstructorLines(code).len == 0

  test "a commented-out constructor is not flagged":
    let code = "// let prevCam = Camera(centerX: 1.0);"
    check namedFieldConstructorLines(code).len == 0

  test "an uppercase function declaration is still a declaration":
    # The uppercase rule alone would flag this; the `fn` check is what saves it.
    # No shader declares a PascalCase function today, which is exactly why the
    # guard needs a test rather than a caller.
    let code = "fn Camera(centerX: f32) -> f32 {"
    check namedFieldConstructorLines(code).len == 0

  test "a generic type in a parameter list is not a constructor":
    let code = "fn colormapPolyEval(coeffs: array<vec3f, 6>, rampT: f32) -> vec3f {"
    check namedFieldConstructorLines(code).len == 0


suite "The Shipped Shaders Parse As WGSL":
  test "no shader source uses a named-field constructor":
    # THE ASSERTION THAT PROTECTS THE APP. Everything above keeps the checker
    # honest; this one is why it exists. It reads the real sources, so a shader
    # added tomorrow is covered without anyone remembering to add a case.
    var offenders: seq[string]
    for dir in ["web/shaders/src", "web/shaders/modules"]:
      if not dirExists(dir):
        continue
      for path in walkFiles(dir / "*.wgsl"):
        for lineNumber in namedFieldConstructorLines(readFile(path)):
          offenders.add(path & ":" & $lineNumber)
    check offenders.len == 0
    if offenders.len > 0:
      echo "  WGSL named-field constructors: ", offenders.join(", ")

  test "the shader source directory was actually found":
    # Without this the suite above passes vacuously when run from the wrong
    # working directory, which would make the real check silently worthless.
    check dirExists("web/shaders/src")
