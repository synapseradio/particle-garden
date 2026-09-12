# Relation tests for src/shader_manifest.nim against src/sim_registry.nim. The
# manifest lists the compute shaders the world needs; the frame description
# lists the pipeline keys a world dispatches. These must agree: a frame that
# dispatches a pipeline the manifest never registers is the "forgot to register
# the shader" bug, and it must fail here rather than as a blank GPU pipeline at
# runtime.
#
# The relation is swept across the corners of the strength space, so a pipeline
# reachable only from some setting of some strength is still covered.

import std/[unittest, sets, strutils]
import ../src/sim_registry
import ../src/shader_manifest
import coupling_space  # the corners of the strength space, ALL_COUPLINGS

const SHADER_MANIFEST_TESTS_LOADED* = true

proc dispatchKeysOf(frame: FrameDescription): seq[string] =
  ## Every pipeline key the frame's compute passes dispatch, in order.
  for node in frame:
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        result.add step.pipelineKey

let manifestKeys = block:
  var keys: HashSet[string]
  for spec in allShaderSpecs():
    keys.incl spec.key
  keys


suite "Every Dispatched Pipeline Has A Registered Shader Spec":
  test "every key any world dispatches is registered":
    for couplings in ALL_COUPLINGS:
      for dispatchKey in dispatchKeysOf(buildFrame(couplings)):
        if dispatchKey notin manifestKeys:
          checkpoint("unregistered pipeline key: " & dispatchKey)
        check dispatchKey in manifestKeys

  test "the relation covers every corner of the strength space":
    # Guards against the relation silently testing nothing.
    check ALL_COUPLINGS.len == 32

  test "the manifest registers no key twice":
    # A duplicate key would create the same pipeline twice under one dictionary
    # entry. Keys are shared by being hoisted out — integrate into
    # INTEGRATE_SPEC, the neighbour search into GRID_SPECS — so a duplicate can
    # only arrive from a new list repeating a key an existing one already holds.
    let specs = allShaderSpecs()
    check manifestKeys.len == specs.len

  test "one pipeline set serves every world":
    # The property that lets a strength cross zero synchronously. A manifest
    # that varies with the couplings makes a slider leaving zero wait on a
    # shader fetch and compile before its pass runs, and the frames in between
    # dispatch against a missing dictionary entry.
    for couplings in ALL_COUPLINGS:
      for dispatchKey in dispatchKeysOf(buildFrame(couplings)):
        check dispatchKey in manifestKeys

  test "every coupling-owned pipeline is registered though no default world dispatches it":
    # forcesSph is the case with teeth: the shipped world runs no fluid, so
    # nothing dispatches this pipeline until a user moves the slider. Registering
    # it anyway is what makes that move instant instead of asynchronous.
    check "forcesSph" in manifestKeys
    check "forcesSph" notin dispatchKeysOf(buildFrame(UNCOUPLED))

  test "the whole mesh chain is registered though the shipped world dispatches none of it":
    # Seven keys behind one strength, and the same teeth forcesSph has: the
    # shipped strength is zero, so nothing dispatches any of them until a user
    # moves the slider, and a key missing here would make that move an
    # asynchronous fetch of six shaders mid-frame.
    for key in ["lrDeposit", "lrFftRows", "lrFftCols", "lrKernel",
        "lrFftColsInv", "lrFftRowsInv", "lrForce"]:
      checkpoint("unregistered long-range key: " & key)
      check key in manifestKeys
      check key notin dispatchKeysOf(buildFrame(UNCOUPLED))


suite "Shader Spec Manifests Are Well-Formed":
  test "every spec path is a .wgsl file served under ./shaders/":
    # main.nim serves the compute shaders from ./shaders/; a path that does not
    # match cannot be fetched at pipeline-load time.
    for spec in allShaderSpecs():
      check spec.path.startsWith("./shaders/")
      check spec.path.endsWith(".wgsl")

  test "every spec names an entry point and a label":
    for spec in allShaderSpecs():
      check spec.entryPoint.len > 0
      check spec.label.len > 0

  test "the one-shot seed shader is registered without any frame dispatching it":
    # CONTRACT: fieldSeed runs on demand (reset, "scatter spores"), never as a
    # frame node, so it must be registered here to be fetched and pipelined even
    # though no frame names it. That asymmetry is why the relation above checks
    # dispatch keys are a SUBSET of spec keys rather than an equality.
    check "fieldSeed" in manifestKeys
    for couplings in ALL_COUPLINGS:
      check "fieldSeed" notin dispatchKeysOf(buildFrame(couplings))

  test "rdStepToFront and rdStepToTrail share one shader path and entry point":
    let specs = allShaderSpecs()
    let toFrontSpec = block:
      var found: ShaderSpec
      for spec in specs:
        if spec.key == "rdStepToFront": found = spec
      found
    let toTrailSpec = block:
      var found: ShaderSpec
      for spec in specs:
        if spec.key == "rdStepToTrail": found = spec
      found
    check toFrontSpec.path == toTrailSpec.path
    check toFrontSpec.entryPoint == toTrailSpec.entryPoint

  test "each transform file serves its forward and inverse key at different entry points":
    # The other shape a shared file takes. rdStep's two keys differ only in
    # which texture the bind group points at, so one entry point serves both;
    # here the direction is in the code, so one file carries two entry points
    # and a key naming the wrong one would run the round trip in one direction
    # twice.
    proc specFor(key: string): ShaderSpec =
      for spec in allShaderSpecs():
        if spec.key == key: return spec
      raise newException(KeyError, "no spec for key: " & key)
    for (forward, inverse) in [("lrFftRows", "lrFftRowsInv"),
        ("lrFftCols", "lrFftColsInv")]:
      checkpoint("the pair " & forward & " / " & inverse)
      check specFor(forward).path == specFor(inverse).path
      check specFor(forward).entryPoint != specFor(inverse).entryPoint
    # And the two files are themselves distinct: rows and columns walk
    # different strides, so one file serving both would transform one axis
    # twice.
    check specFor("lrFftRows").path != specFor("lrFftCols").path
