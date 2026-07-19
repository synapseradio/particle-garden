# ==============================================================================
# PARTICLE GARDEN - WEBGPU COMPUTE PIPELINE ORCHESTRATION (AoS Layout)
# ==============================================================================
#
# This module implements the physics pipeline with AoS (Array of Structures):
# - Pass 1: bin-count (count particles per cell)
# - Pass 2: prefix-sum (exclusive scan for cell offsets)
# - Pass 3: bin-scatter (physically scatter entire Particle structs)
# - Pass 4: forces (compute inter-particle forces from SORTED buffer)
# - Pass 5: integrate (apply velocity deltas and update positions)
#
# AoS LAYOUT BENEFIT:
# With AoS, each Particle is a 32-byte struct containing pos, vel, species, density.
# This enables:
# - Fewer buffer bindings (1 particles buffer vs 4-6 separate arrays)
# - Better cache locality when accessing multiple fields
# - Merged passes (bin-scatter and integrate are now single passes)
#
# BUFFER ORGANIZATION:
# - particlesA: Primary particle buffer (N * 32 bytes)
# - particlesSorted: Spatially-sorted for cache-friendly force computation
# - velocityDelta: Interleaved i32 pairs for Newton's 3rd law atomics
# - Grid buffers: counts, offsets, fillPointers
# - Index mappings: sortedIndices, reverseIndices
#
# ==============================================================================

from std/jsffi import JsObject, toJs, to, `[]`, `[]=`
import std/asyncjs
import std/strutils
import bindings/js_interop
import bindings/webgpu
import bindings/typed_arrays

# Local aliases to avoid ambiguity with std/jsffi (which js_interop exports)
proc createJsObject(): JsObject {.importjs: "({})".}
proc createJsArray(): JsObject {.importjs: "([])".}
proc typeofJs(obj: JsObject): cstring {.importjs: "(typeof #)".}

import webgpu_init
import gpu_profiler
import buffers as cpuBuffers
import config
import shader_config
import gpu_types
import sim_registry
import shader_manifest
import sph_core

# Alias for GPU buffers to distinguish from CPU buffers
template gpuBuffers*(): untyped = webgpu_init.buffers

# ==============================================================================
# SECTION 2: BINDING CONTRACT VALIDATION CONSTANTS (AoS)
# ==============================================================================

# Expected entry counts for each pass (from shader binding manifests).
const EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT* = 3          # AoS: uniform + particles + gridCounts
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL* = 4
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS* = 3
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL* = 3
const EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER* = 6        # AoS: merged pass
const EXPECTED_BIND_GROUP_ENTRIES_FORCES* = 7             # AoS: velocity + density deltas for symmetric accumulation
const EXPECTED_BIND_GROUP_ENTRIES_FORCES_SPH* = 7         # SPH: clones the forces layout exactly (7 entries)
const EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE* = 4          # AoS: + densityDelta for temporal smoothing

proc getExpectedEntryCount(passName: cstring): int =
  ## Get expected bind group entry count for a pass name.
  case $passName
  of "binCount": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT
  of "prefixLocal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL
  of "prefixBlocks": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS
  of "prefixFinal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL
  of "binScatter": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER
  of "forces": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES
  of "forcesSph": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES_SPH
  of "integrate": result = EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE
  else: result = -1

# ==============================================================================
# SECTION 3: PIPELINE STATE
# ==============================================================================

var shaderModules* {.exportc.}: JsObject = createJsObject()
var pipelines* {.exportc.}: JsObject = createJsObject()
var bindGroupLayouts* {.exportc.}: JsObject = createJsObject()
var uniformBuffers* {.exportc.}: JsObject = createJsObject()
var bindGroups* {.exportc.}: JsObject = createJsObject()
var cachedBindGroupGridW: int = -1
var cachedBindGroupGridH: int = -1
var isPipelineReady* {.exportc.}: bool = false

# The frame description the executor walks. Built once per structural change
# (mode switch), never per frame — see sim_registry.nim.
var activeFrame: FrameDescription = @[]
var activeSimKind*: SimKind = skParticleLife

const prewarmedKinds = {skParticleLife, skSph}
  ## Kinds whose compute shaders exist on disk this build and pre-warm at init.
  ## skSph joins particle-life now that forces-sph.wgsl exists and main.nim
  ## serves it: its forcesSph pipeline is created here and its bind group in
  ## createBindGroups, so a switch to skSph finds a ready pipeline. SPH's other
  ## pipelines (grid triad, bin-scatter, integrate) are shared with
  ## particle-life. skReactionDiffusion registers no shaders yet (roadmap S8).

proc setActiveSimKind*(kind: SimKind) =
  ## Switch the executor to another simulation's frame description. A kind whose
  ## pipelines were not pre-warmed (its shaders do not exist on disk yet — see
  ## prewarmedKinds) is refused: the executor keeps its current frame rather
  ## than dispatching a pipeline that was never created. This keeps an imported
  ## preset that carries a not-yet-runnable mode (e.g. "sph" from a future
  ## build) from crashing the render loop; the mode becomes live once its
  ## shaders land and it joins prewarmedKinds.
  if kind notin prewarmedKinds:
    consoleWarn(("[sim] mode \"" & simKindId(kind) &
      "\" is not runnable in this build yet - keeping the current mode").toJs)
    return
  activeSimKind = kind
  activeFrame = buildFrame(kind)

# ==============================================================================
# SECTION 4: SHADER VALIDATION
# ==============================================================================

proc jsArrayLength*(arr: JsObject): int {.importjs: "#.length".}
proc jsArrayFilter*(arr: JsObject, predicate: proc(item: JsObject): bool): JsObject {.importjs: "#.filter(#)".}
proc msgType*(msg: JsObject): cstring {.importjs: "#.type".}
proc msgMessage*(msg: JsObject): cstring {.importjs: "#.message".}
proc msgLineNum*(msg: JsObject): int {.importjs: "#.lineNum".}

proc validateShaderCompilation*(shaderModule: GPUShaderModule, label: cstring): Future[void] {.async, exportc.} =
  let compilationInfo = await shaderModule.getCompilationInfo()
  let messages = compilationInfo.messages

  if jsArrayLength(messages) > 0:
    let errors = jsArrayFilter(messages, proc(msg: JsObject): bool =
      msg.msgType == "error"
    )
    let warnings = jsArrayFilter(messages, proc(msg: JsObject): bool =
      msg.msgType == "warning"
    )

    if jsArrayLength(errors) > 0:
      var errorDetails = ""
      for errorIndex in 0..<jsArrayLength(errors):
        let err = cast[JsObject](errors[errorIndex])
        errorDetails &= "  Line " & $err.msgLineNum & ": " & $err.msgMessage & "\n"
      raise newException(CatchableError, "Shader compilation failed for \"" & $label & "\":\n" & errorDetails)

    if jsArrayLength(warnings) > 0:
      for warningIndex in 0..<jsArrayLength(warnings):
        let warning = cast[JsObject](warnings[warningIndex])
        consoleWarn(("Shader warning for \"" & $label & "\" Line " & $warning.msgLineNum & ": " & $warning.msgMessage).toJs)

proc validateBindGroupLayout*(layout: GPUBindGroupLayout, passName: cstring) {.exportc.} =
  if cast[JsObject](layout).isNullOrUndefined:
    raise newException(CatchableError, "Failed to extract bind group layout for pass \"" & $passName & "\"")
  if typeofJs(cast[JsObject](layout)) != "object":
    raise newException(CatchableError, "Invalid bind group layout for pass \"" & $passName & "\"")

proc validateBindGroupEntryCount*(entries: JsObject, passName: cstring, phase: cstring) {.exportc.} =
  let expected = getExpectedEntryCount(passName)
  if expected == -1:
    raise newException(CatchableError, "No expected entry count for pass \"" & $passName & "\"")
  let actual = jsArrayLength(entries)
  if actual != expected:
    raise newException(CatchableError, "Bind group entry count mismatch for pass \"" & $passName & "\" during " & $phase &
      ": Expected " & $expected & " entries, got " & $actual)

# ==============================================================================
# SECTION 5: BIND GROUP CREATION
# ==============================================================================

proc createBindGroupWithValidation*(
  passName: cstring,
  layout: GPUBindGroupLayout,
  entries: JsObject,
  label: cstring
): Future[GPUBindGroup] {.async, exportc.} =
  device.pushErrorScope("validation")
  let descriptor = createJsObject()
  descriptor["layout"] = cast[JsObject](layout)
  descriptor["entries"] = entries
  descriptor["label"] = label.toJs
  let bindGroup = device.createBindGroup(descriptor)
  let error = await device.popErrorScope()

  if not error.isNullOrUndefined:
    var entryDetails = ""
    for entryIndex in 0..<jsArrayLength(entries):
      let entry = cast[JsObject](entries[entryIndex])
      let binding = entry["binding"]
      let resource = entry["resource"]
      let buffer = resource["buffer"]
      let bufferLabel = if not buffer.isNullOrUndefined and not buffer["label"].isNullOrUndefined:
        $buffer["label"].to(cstring)
      else:
        "unlabeled"
      entryDetails &= "    binding " & $binding.to(int) & ": buffer=" & bufferLabel & "\n"
    raise newException(CatchableError, "Bind group creation failed for \"" & $passName & "\":\n  Error: " & $error.message & "\n  Entries:\n" & entryDetails)

  return bindGroup

proc createBindGroupEntry(binding: int, buffer: JsObject): JsObject =
  result = createJsObject()
  result["binding"] = binding.toJs
  let resource = createJsObject()
  resource["buffer"] = buffer
  result["resource"] = resource

proc push*(arr: JsObject, item: JsObject): int {.importjs: "#.push(#)", discardable.}

proc createBindGroups*(gridW: int, gridH: int): Future[void] {.async, exportc.} =
  ## Create bind groups for all passes (AoS layout).

  # Pass 1: Bin Count (AoS: particles buffer)
  let binCountEntries = createJsArray()
  discard binCountEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard binCountEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard binCountEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.gridCounts)))

  validateBindGroupEntryCount(binCountEntries, "binCount", "bind group creation")
  bindGroups["binCount"] = await createBindGroupWithValidation(
    "Bin Count",
    cast[GPUBindGroupLayout](bindGroupLayouts["binCount"]),
    binCountEntries,
    "Bin Count Bind Group"
  )

  # Pass 2a: Prefix Local
  let prefixLocalEntries = createJsArray()
  discard prefixLocalEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixLocalEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.gridCounts)))
  discard prefixLocalEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.gridOffsets)))
  discard prefixLocalEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.blockSums)))

  validateBindGroupEntryCount(prefixLocalEntries, "prefixLocal", "bind group creation")
  bindGroups["prefixLocal"] = await createBindGroupWithValidation(
    "Prefix Local",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixLocal"]),
    prefixLocalEntries,
    "Prefix Local Bind Group"
  )

  # Pass 2b: Prefix Blocks
  let prefixBlocksEntries = createJsArray()
  discard prefixBlocksEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixBlocksEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.blockSums)))
  discard prefixBlocksEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.blockOffsets)))

  validateBindGroupEntryCount(prefixBlocksEntries, "prefixBlocks", "bind group creation")
  bindGroups["prefixBlocks"] = await createBindGroupWithValidation(
    "Prefix Blocks",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixBlocks"]),
    prefixBlocksEntries,
    "Prefix Blocks Bind Group"
  )

  # Pass 2c: Prefix Final
  let prefixFinalEntries = createJsArray()
  discard prefixFinalEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixFinalEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.gridOffsets)))
  discard prefixFinalEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.blockOffsets)))

  validateBindGroupEntryCount(prefixFinalEntries, "prefixFinal", "bind group creation")
  bindGroups["prefixFinal"] = await createBindGroupWithValidation(
    "Prefix Final",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixFinal"]),
    prefixFinalEntries,
    "Prefix Final Bind Group"
  )

  # Pass 3: Bin Scatter (AoS - unified scatter of entire Particle struct)
  let binScatterEntries = createJsArray()
  discard binScatterEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard binScatterEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard binScatterEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.particlesSorted)))
  discard binScatterEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.sortedIndices)))
  discard binScatterEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.reverseIndices)))
  discard binScatterEntries.push(createBindGroupEntry(5, cast[JsObject](gpuBuffers.fillPointers)))

  validateBindGroupEntryCount(binScatterEntries, "binScatter", "bind group creation")
  bindGroups["binScatter"] = await createBindGroupWithValidation(
    "Bin Scatter",
    cast[GPUBindGroupLayout](bindGroupLayouts["binScatter"]),
    binScatterEntries,
    "Bin Scatter Bind Group"
  )

  # Pass 4: Forces (AoS - reads from particlesSorted, writes velocity+density deltas)
  # Note: Original particles buffer not needed here - we read sorted, write to delta buffers
  let forcesEntries = createJsArray()
  discard forcesEntries.push(createBindGroupEntry(0, uniformBuffers["simParams"]))
  discard forcesEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesSorted)))
  discard forcesEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.sortedIndices)))
  discard forcesEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.gridOffsets)))
  discard forcesEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.gridCounts)))
  discard forcesEntries.push(createBindGroupEntry(5, cast[JsObject](gpuBuffers.velocityDelta)))
  discard forcesEntries.push(createBindGroupEntry(6, cast[JsObject](gpuBuffers.densityDelta)))  # Symmetric density

  validateBindGroupEntryCount(forcesEntries, "forces", "bind group creation")
  bindGroups["forces"] = await createBindGroupWithValidation(
    "Forces",
    cast[GPUBindGroupLayout](bindGroupLayouts["forces"]),
    forcesEntries,
    "Forces Bind Group"
  )

  # Pass 4 (SPH): forces-sph clones the forces layout exactly (same 7 buffers in
  # the same binding slots), so its bind group is a clone of the one above. Built
  # unconditionally here because skSph pre-warms; the executor picks it by
  # pipeline key when the SPH frame is active.
  let forcesSphEntries = createJsArray()
  discard forcesSphEntries.push(createBindGroupEntry(0, uniformBuffers["simParams"]))
  discard forcesSphEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesSorted)))
  discard forcesSphEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.sortedIndices)))
  discard forcesSphEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.gridOffsets)))
  discard forcesSphEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.gridCounts)))
  discard forcesSphEntries.push(createBindGroupEntry(5, cast[JsObject](gpuBuffers.velocityDelta)))
  discard forcesSphEntries.push(createBindGroupEntry(6, cast[JsObject](gpuBuffers.densityDelta)))

  validateBindGroupEntryCount(forcesSphEntries, "forcesSph", "bind group creation")
  bindGroups["forcesSph"] = await createBindGroupWithValidation(
    "SPH Forces",
    cast[GPUBindGroupLayout](bindGroupLayouts["forcesSph"]),
    forcesSphEntries,
    "SPH Forces Bind Group"
  )

  # Pass 5: Integrate (AoS - unified velocity + position update)
  # Applies velocity deltas (Newton's 3rd law accumulation) and density deltas
  # (symmetric neighbor accumulation) with temporal smoothing
  let integrateEntries = createJsArray()
  discard integrateEntries.push(createBindGroupEntry(0, uniformBuffers["integrationParams"]))
  discard integrateEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard integrateEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.velocityDelta)))
  discard integrateEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.densityDelta)))  # Symmetric density

  validateBindGroupEntryCount(integrateEntries, "integrate", "bind group creation")
  bindGroups["integrate"] = await createBindGroupWithValidation(
    "Integrate",
    cast[GPUBindGroupLayout](bindGroupLayouts["integrate"]),
    integrateEntries,
    "Integrate Bind Group"
  )

# ==============================================================================
# SECTION 6: SHADER LOADING
# ==============================================================================

proc fetch*(path: cstring): Future[JsObject] {.importjs: "fetch(#)".}
proc ok*(response: JsObject): bool {.importjs: "#.ok".}
proc statusText*(response: JsObject): cstring {.importjs: "#.statusText".}
proc text*(response: JsObject): Future[cstring] {.importjs: "#.text()".}

proc loadShader(path: cstring, label: cstring): Future[GPUShaderModule] {.async.} =
  let response = await fetch(path)
  if not response.ok:
    raise newException(CatchableError, "Failed to load shader " & $path & ": " & $response.statusText)

  let code = await response.text()

  # DIAGNOSTIC: Count @binding declarations in shader code
  let bindingCount = ($code).count("@binding")
  consoleLog(("[SHADER LOAD] " & $label & " - Length: " & $len($code) & " bytes, @binding count: " & $bindingCount).toJs)

  let descriptor = createJsObject()
  descriptor["code"] = code.toJs
  descriptor["label"] = label.toJs

  let shaderModule = device.createShaderModule(descriptor)
  await validateShaderCompilation(shaderModule, label)
  return shaderModule

# ==============================================================================
# SECTION 7: PIPELINE CREATION HELPERS
# ==============================================================================

proc createPipelineWithValidation(name: cstring, shaderModule: GPUShaderModule, entryPoint: cstring): Future[GPUComputePipeline] {.async.} =
  device.pushErrorScope("validation")

  let descriptor = createJsObject()
  descriptor["layout"] = "auto".cstring.toJs
  let compute = createJsObject()
  compute["module"] = cast[JsObject](shaderModule)
  compute["entryPoint"] = entryPoint.toJs
  descriptor["compute"] = compute
  descriptor["label"] = ($name & " Pipeline").cstring.toJs

  let pipeline = device.createComputePipeline(descriptor)
  let error = await device.popErrorScope()

  if not error.isNullOrUndefined:
    raise newException(CatchableError, "Pipeline creation failed for \"" & $name & "\": " & $error.message)

  consoleLog(("  + " & $name & " pipeline created").toJs)
  return pipeline

# ==============================================================================
# SECTION 8: PIPELINE INITIALIZATION
# ==============================================================================

proc initPipelines*(): Future[JsObject] {.async, exportc.} =
  ## Initialize the compute pipelines for every simulation kind and arm the
  ## particle-life frame description.
  if not isWebGPUAvailable or device.isNil:
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "WebGPU device not available".cstring.toJs
    return resultObj

  try:
    # =========================================================================
    # PHASE: SHADER SPEC COLLECTION (deduplicated across sim kinds)
    # =========================================================================
    var specs: seq[ShaderSpec]
    for kind in SimKind:
      if kind notin prewarmedKinds:
        continue
      for spec in shaderSpecsFor(kind):
        var alreadyCollected = false
        for existing in specs:
          if existing.key == spec.key:
            alreadyCollected = true
            break
        if not alreadyCollected:
          specs.add(spec)

    # =========================================================================
    # PHASE: SHADER LOADING
    # =========================================================================
    consoleLog("[PHASE: SHADER LOADING] Loading compute shaders...".toJs)
    for spec in specs:
      let shaderModule = await loadShader(spec.path.cstring, spec.label.cstring)
      shaderModules[spec.key.cstring] = cast[JsObject](shaderModule)
    consoleLog(("[PHASE: SHADER LOADING] Success - " & $specs.len & " compute shaders loaded").toJs)

    # =========================================================================
    # PHASE: UNIFORM BUFFER CREATION
    # =========================================================================
    let uniformUsage = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst)

    uniformBuffers["gridParams"] = device.createBufferLabeled(
      wgslUniformSize(GridParamsLayout), uniformUsage, "Grid Parameters Uniform")
    uniformBuffers["scanParams"] = device.createBufferLabeled(
      wgslUniformSize(ScanParamsLayout), uniformUsage, "Scan Parameters Uniform")
    uniformBuffers["simParams"] = device.createBufferLabeled(
      wgslUniformSize(SimParamsLayout), uniformUsage, "Simulation Parameters Uniform (with matrix + force model)")
    uniformBuffers["integrationParams"] = device.createBufferLabeled(32, uniformUsage, "Integration Parameters Uniform")

    consoleLog("[PHASE: UNIFORM BUFFER CREATION] Success - 4 uniform buffers created".toJs)

    # =========================================================================
    # PHASE: PIPELINE CREATION + LAYOUT EXTRACTION
    # =========================================================================
    consoleLog("[PHASE: PIPELINE CREATION] Creating compute pipelines...".toJs)

    for spec in specs:
      pipelines[spec.key.cstring] = await createPipelineWithValidation(
        spec.label.cstring,
        cast[GPUShaderModule](shaderModules[spec.key.cstring]),
        spec.entryPoint.cstring)

    device.pushErrorScope("validation")
    for spec in specs:
      bindGroupLayouts[spec.key.cstring] = cast[JsObject](
        cast[GPUComputePipeline](pipelines[spec.key.cstring]).getBindGroupLayout(0))
    let layoutError = await device.popErrorScope()

    if not layoutError.isNullOrUndefined:
      raise newException(CatchableError, "Bind group layout extraction failed: " & $layoutError.message)

    for spec in specs:
      validateBindGroupLayout(
        cast[GPUBindGroupLayout](bindGroupLayouts[spec.key.cstring]), spec.key.cstring)

    consoleLog(("[PHASE: PIPELINE CREATION] Success - " & $specs.len & " pipelines and layouts validated").toJs)

    setActiveSimKind(skParticleLife)
    isPipelineReady = true

    let resultObj = createJsObject()
    resultObj["success"] = true.toJs
    let infoObj = createJsObject()
    infoObj["shaderCount"] = specs.len.toJs
    infoObj["pipelineCount"] = specs.len.toJs
    resultObj["info"] = infoObj
    return resultObj

  except CatchableError as err:
    consoleError(("Pipeline initialization failed: " & err.msg).toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = ("Pipeline initialization error: " & err.msg).cstring.toJs
    return resultObj

# ==============================================================================
# SECTION 9: PHYSICS FRAME EXECUTION
# ==============================================================================

proc runPhysicsFrame*(params: JsObject): Future[void] {.async, exportc.} =
  ## Run one physics frame using the AoS GPU compute pipeline.
  if not isPipelineReady:
    raise newException(CatchableError, "Pipelines not initialized. Call initPipelines() first.")

  # Extract parameters
  let dt = params["dt"].to(float)
  let particleCount = params["particleCount"].to(int)
  let width = params["width"].to(float)
  let height = params["height"].to(float)
  let gridW = params["gridW"].to(int)
  let gridH = params["gridH"].to(int)
  let rMax = params["rMax"].to(float)
  let fMul = params["fMul"].to(float)
  let friction = params["friction"].to(float)
  let mouseX = params["mouseX"].to(float)
  let mouseY = params["mouseY"].to(float)
  let mouseDown = params["mouseDown"].to(int)
  let mouseRightDown = params["mouseRightDown"].to(int)
  let blastX = params["blastX"].to(float)
  let blastY = params["blastY"].to(float)
  let blastStrength = params["blastStrength"].to(float)
  let matrix = params["matrix"]

  let numCells = gridW * gridH
  # bin-count, bin-scatter, forces, and integrate all dispatch per-particle
  # and share one workgroup-size-derived divisor. They're independently
  # tunable in shader_config.nim's WorkgroupConfig but all sit at the same
  # production value today; if that ever diverges, dsParticleWorkgroups needs
  # splitting into per-pass dispatch kinds in sim_registry.
  let workgroupSize = shader_config.getWorkgroupSize("bin-count")
  let particleWorkgroups = jsCeil(particleCount.float / workgroupSize.float)
  # The scan block size is the prefix-sum-local workgroup size; the WGSL side
  # receives the same value via its WORKGROUP_SIZE placeholder.
  let scanBlockSize = shader_config.getWorkgroupSize("prefix-sum-local")
  let scanBlocks = jsCeil(numCells.float / scanBlockSize.float)

  # =========================================================================
  # PHASE: PER-FRAME UNIFORM UPDATE
  # =========================================================================

  # Grid parameters (used by bin-count and bin-scatter)
  # Layout matches GridParamsLayout in gpu_types.nim
  let gridParamsData = newUint32Array(GRID_PARAMS_U32_COUNT)
  gridParamsData[GRID_W] = gridW
  gridParamsData[GRID_H] = gridH
  gridParamsData[GRID_PARTICLE_COUNT] = particleCount
  let gridParamsFloat = newFloat32Array(gridParamsData.buffer)
  gridParamsFloat[GRID_CANVAS_WIDTH] = width
  gridParamsFloat[GRID_CANVAS_HEIGHT] = height
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["gridParams"]), 0, gridParamsData)

  # Scan parameters (used by the prefix-sum passes)
  let scanParamsData = newUint32Array(SCAN_PARAMS_U32_COUNT)
  scanParamsData[SCAN_NUM_CELLS] = numCells
  scanParamsData[SCAN_NUM_BLOCKS] = scanBlocks
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["scanParams"]), 0, scanParamsData)

  # Substepping (SPH only): the executor runs the whole frame description
  # substepCount times per rendered frame for stability at high stiffness, each
  # substep advancing dt/substepCount. Particle-life always runs a single step.
  # sphSubsteps is clamped to sph_core's SPH_MAX_SUBSTEPS ceiling.
  let substepCount =
    if activeSimKind == skSph: clamp(config.CONFIG.sphSubsteps, 1, SPH_MAX_SUBSTEPS)
    else: 1
  let substepDt = dt / substepCount.float

  # Simulation parameters (used by forces)
  # Layout matches SimParamsLayout in gpu_types.nim
  let simParamsData = newFloat32Array(SIM_PARAMS_F32_COUNT)
  simParamsData[SIM_DT] = substepDt
  simParamsData[SIM_WORLD_WIDTH] = width
  simParamsData[SIM_WORLD_HEIGHT] = height
  simParamsData[SIM_INTERACTION_RADIUS] = rMax
  simParamsData[SIM_FORCE_MULTIPLIER] = fMul
  let simParamsUint = newUint32Array(simParamsData.buffer)
  simParamsUint[SIM_GRID_CELLS_X] = gridW
  simParamsUint[SIM_GRID_CELLS_Y] = gridH
  simParamsData[SIM_MOUSE_X] = mouseX
  simParamsData[SIM_MOUSE_Y] = mouseY
  simParamsData[SIM_MOUSE_LEFT_DOWN] = if mouseDown != 0: 1.0 else: 0.0
  simParamsData[SIM_MOUSE_RIGHT_DOWN] = if mouseRightDown != 0: 1.0 else: 0.0
  simParamsUint[SIM_PARTICLE_COUNT] = particleCount
  simParamsData[SIM_BLAST_X] = blastX
  simParamsData[SIM_BLAST_Y] = blastY
  simParamsData[SIM_BLAST_STRENGTH] = blastStrength
  simParamsData[SIM_PAD] = 0.0  # padding for vec4 alignment
  # Copy attraction matrix (36 floats starting at SIM_ATTRACTION_MATRIX_START)
  for matrixSlot in 0..<36:
    simParamsData[SIM_ATTRACTION_MATRIX_START + matrixSlot] = cast[JsObject](matrix[matrixSlot]).to(float)
  # Zone boundary params
  simParamsData[SIM_REPULSION_END] = float32(config.CONFIG.repulsionEnd)
  simParamsData[SIM_ATTRACTION_PEAK] = float32(config.CONFIG.attractionPeak)
  # Force model params
  simParamsUint[SIM_FORCE_MODEL] = uint32(config.CONFIG.forceModel)  # 0=polynomial, 1=exponential
  simParamsData[SIM_EXP_ALPHA] = float32(config.CONFIG.expRepulsionAlpha)
  simParamsData[SIM_EXP_BETA] = float32(config.CONFIG.expAttractionBeta)
  simParamsData[SIM_PAD2] = 0.0  # padding for 16-byte alignment
  # SPH fluid-mode params (read by forces-sph.wgsl; ignored by forces.wgsl).
  # gamma is the fixed Tait exponent from sph_core, not a live CONFIG value.
  simParamsData[SIM_SPH_REST_DENSITY] = float32(config.CONFIG.sphRestDensity)
  simParamsData[SIM_SPH_STIFFNESS] = float32(config.CONFIG.sphStiffness)
  simParamsData[SIM_SPH_GAMMA] = float32(SPH_DEFAULT_GAMMA)
  simParamsData[SIM_SPH_VISCOSITY] = float32(config.CONFIG.sphViscosity)
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["simParams"]), 0, simParamsData)

  # Integration parameters
  # Layout matches IntegrationParams indices in gpu_types.nim
  let integrationParamsData = newFloat32Array(INTEG_PARAMS_F32_COUNT)
  integrationParamsData[INTEG_WORLD_WIDTH] = width
  integrationParamsData[INTEG_WORLD_HEIGHT] = height
  integrationParamsData[INTEG_FRICTION] = friction
  integrationParamsData[INTEG_MAX_VELOCITY] = float32(config.CONFIG.maxVelocity)
  let integrationParamsUint = newUint32Array(integrationParamsData.buffer)
  integrationParamsUint[INTEG_PARTICLE_COUNT] = particleCount
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["integrationParams"]), 0, integrationParamsData)

  # =========================================================================
  # PHASE: BIND GROUP CREATION (cached by grid dimensions)
  # =========================================================================
  if gridW != cachedBindGroupGridW or gridH != cachedBindGroupGridH:
    await createBindGroups(gridW, gridH)
    cachedBindGroupGridW = gridW
    cachedBindGroupGridH = gridH

  # =========================================================================
  # PHASE: COMMAND ENCODING (walk the active frame description)
  # =========================================================================
  # The sequence lives in sim_registry.buildFrame — data, not code. Only the
  # dispatch sizes and buffer byte lengths are resolved here, per frame.

  proc gpuBufferFor(simBuffer: SimBuffer): GPUBuffer =
    case simBuffer
    of sbGridCounts: cast[GPUBuffer](gpuBuffers.gridCounts)
    of sbGridOffsets: cast[GPUBuffer](gpuBuffers.gridOffsets)
    of sbFillPointers: cast[GPUBuffer](gpuBuffers.fillPointers)
    of sbDensityDelta: cast[GPUBuffer](gpuBuffers.densityDelta)
    of sbFieldDeposit:
      # RD lands with its shader stage; the mode is not pre-warmed, so no
      # frame reaching this executor can name the buffer yet.
      raise newException(CatchableError, "field deposit buffer not created yet (roadmap S8)")

  proc byteLengthFor(simBuffer: SimBuffer): int =
    case simBuffer
    of sbGridCounts, sbGridOffsets, sbFillPointers: numCells * 4
    of sbDensityDelta: particleCount * 4  # i32 per particle
    of sbFieldDeposit:
      raise newException(CatchableError, "field deposit buffer not created yet (roadmap S8)")

  proc resolveDispatchSize(size: DispatchSize): int =
    case size
    of dsParticleWorkgroups: particleWorkgroups
    of dsScanBlocks: scanBlocks
    of dsOne: 1
    of dsFieldWorkgroups:
      # The one 2D dispatch size; the executor grows real 2D handling when the
      # RD shaders land. Unreachable until skReactionDiffusion pre-warms.
      raise newException(CatchableError, "field dispatch not implemented yet (roadmap S8)")

  let commandEncoder = device.createCommandEncoderLabeled("Physics Frame Command Encoder")

  # Encode the frame description substepCount times into this one encoder. Each
  # repetition is a full physics step (grid build + scatter + forces + integrate)
  # reading and writing particlesA in place; passes in a single encoder execute
  # in order, so the substeps advance sequentially. substepCount is 1 outside
  # SPH, making this a plain single walk of the frame.
  for substep in 0 ..< substepCount:
    # Timestamps write a fixed query slot per profiler pass; attach them only on
    # the first substep so multiple substeps never double-write the same query.
    let attachProfiling = (substep == 0)
    for node in activeFrame:
      case node.kind
      of fnkClearBuffer:
        commandEncoder.clearBuffer(gpuBufferFor(node.clearTarget), 0,
          byteLengthFor(node.clearTarget))
      of fnkCopyBuffer:
        commandEncoder.copyBufferToBuffer(
          gpuBufferFor(node.copySource), 0,
          gpuBufferFor(node.copyDest), 0,
          byteLengthFor(node.copySource))
      of fnkComputePass:
        let passDesc = createJsObject()
        passDesc["label"] = (node.label & " Compute Pass").cstring.toJs
        if attachProfiling:
          gpu_profiler.attachTimestamps(passDesc, node.profilerSlot)
        let computePass = commandEncoder.beginComputePass(passDesc)
        for dispatchStep in node.dispatches:
          computePass.setPipeline(cast[GPUComputePipeline](pipelines[dispatchStep.pipelineKey.cstring]))
          computePass.setBindGroup(0, cast[GPUBindGroup](bindGroups[dispatchStep.pipelineKey.cstring]))
          computePass.dispatchWorkgroups(resolveDispatchSize(dispatchStep.size))
        computePass.endPass()

  # Submit
  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = createJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  queue.submit(commandBufferArray)

# ==============================================================================
# SECTION 10: INITIAL DATA UPLOAD (AoS)
# ==============================================================================

proc uploadInitialData*(particleCount: int): Future[JsObject] {.async, exportc.} =
  ## Upload initial particle data to GPU buffers (AoS layout).
  ## Reads from CPU buffers and packs into 32-byte Particle structs.
  if device.isNil or queue.isNil:
    consoleError("Cannot upload initial data: WebGPU device not initialized".toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "Device not initialized".cstring.toJs
    return resultObj

  try:
    # Create AoS particle data buffer
    # Each particle: 8 floats (32 bytes) = pos.x, pos.y, vel.x, vel.y, species(as f32), density, pad, pad
    let particleData = newFloat32Array(particleCount * 8)
    let particleDataUint = newUint32Array(particleData.buffer)

    # Pack particle data from CPU SoA buffers into AoS format
    for particleIndex in 0..<particleCount:
      let baseIdx = particleIndex * 8
      particleData[baseIdx + 0] = cpuBuffers.particlesA[particleIndex * 8 + 0]  # pos.x
      particleData[baseIdx + 1] = cpuBuffers.particlesA[particleIndex * 8 + 1]  # pos.y
      particleData[baseIdx + 2] = cpuBuffers.particlesA[particleIndex * 8 + 2]  # vel.x
      particleData[baseIdx + 3] = cpuBuffers.particlesA[particleIndex * 8 + 3]  # vel.y
      particleDataUint[baseIdx + 4] = uint32(cpuBuffers.particlesA[particleIndex * 8 + 4])  # species (reinterpret as u32)
      particleData[baseIdx + 5] = cpuBuffers.particlesA[particleIndex * 8 + 5]  # density
      particleDataUint[baseIdx + 6] = 0  # padding
      particleDataUint[baseIdx + 7] = 0  # padding

    # Upload to GPU
    let bytesTotal = particleCount * 32
    queue.writeBufferTyped(cast[GPUBuffer](gpuBuffers.particlesA), 0, particleData)

    # Upload attraction matrix
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers.matrix), 0, cpuBuffers.matrix.buffer, cpuBuffers.matrix.byteOffset, cpuBuffers.matrix.byteLength)

    consoleLog(("Uploaded " & $particleCount & " particles to GPU (AoS, " & $bytesTotal & " bytes)").toJs)

    let resultObj = createJsObject()
    resultObj["success"] = true.toJs
    return resultObj

  except CatchableError as err:
    consoleError(("Failed to upload initial data: " & err.msg).toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = err.msg.cstring.toJs
    return resultObj
