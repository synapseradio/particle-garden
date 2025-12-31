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
import buffers as cpuBuffers
import config

# Alias for GPU buffers to distinguish from CPU buffers
template gpuBuffers*(): untyped = webgpu_init.buffers

# ==============================================================================
# SECTION 2: BINDING CONTRACT VALIDATION CONSTANTS (AoS)
# ==============================================================================

# Expected entry counts for each pass (from shader binding manifests).
const EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT* = 3          # AoS: uniform + particles + gridCounts
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_SUM* = 3
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL* = 4
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS* = 3
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL* = 3
const EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER* = 6        # AoS: merged pass
const EXPECTED_BIND_GROUP_ENTRIES_FORCES* = 7             # AoS: velocity + density deltas for symmetric accumulation
const EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE* = 4          # AoS: + densityDelta for temporal smoothing

proc getExpectedEntryCount(passName: cstring): int =
  ## Get expected bind group entry count for a pass name.
  case $passName
  of "binCount": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT
  of "prefixSum": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_SUM
  of "prefixLocal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL
  of "prefixBlocks": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS
  of "prefixFinal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL
  of "binScatter": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER
  of "forces": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES
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
var cachedBindGroupParity: int = -1
var isPipelineReady* {.exportc.}: bool = false

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
      for i in 0..<jsArrayLength(errors):
        let err = cast[JsObject](errors[i])
        errorDetails &= "  Line " & $err.msgLineNum & ": " & $err.msgMessage & "\n"
      raise newException(CatchableError, "Shader compilation failed for \"" & $label & "\":\n" & errorDetails)

    if jsArrayLength(warnings) > 0:
      for i in 0..<jsArrayLength(warnings):
        let w = cast[JsObject](warnings[i])
        consoleWarn(("Shader warning for \"" & $label & "\" Line " & $w.msgLineNum & ": " & $w.msgMessage).toJs)

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
    for i in 0..<jsArrayLength(entries):
      let e = cast[JsObject](entries[i])
      let binding = e["binding"]
      let resource = e["resource"]
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

proc createBindGroups*(parity: int, gridW: int, gridH: int): Future[void] {.async, exportc.} =
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

  # Pass 2: Prefix Sum
  let prefixSumEntries = createJsArray()
  discard prefixSumEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixSumEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.gridCounts)))
  discard prefixSumEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.gridOffsets)))

  validateBindGroupEntryCount(prefixSumEntries, "prefixSum", "bind group creation")
  bindGroups["prefixSum"] = await createBindGroupWithValidation(
    "Prefix Sum",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixSum"]),
    prefixSumEntries,
    "Prefix Sum Bind Group"
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
  ## Initialize all compute pipelines for AoS layout.
  if not isWebGPUAvailable or device.isNil:
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "WebGPU device not available".cstring.toJs
    return resultObj

  try:
    # =========================================================================
    # PHASE: SHADER LOADING (AoS versions)
    # =========================================================================
    consoleLog("[PHASE: SHADER LOADING] Loading AoS compute shaders...".toJs)

    let binCountModule = await loadShader("./shaders/bin-count.wgsl", "Bin Count Shader (AoS)")
    let prefixSumModule = await loadShader("./shaders/prefix-sum.wgsl", "Prefix Sum Shader")
    let prefixLocalModule = await loadShader("./shaders/prefix-sum-local.wgsl", "Prefix Sum Local Shader")
    let prefixBlocksModule = await loadShader("./shaders/prefix-sum-blocks.wgsl", "Prefix Sum Blocks Shader")
    let prefixFinalModule = await loadShader("./shaders/prefix-sum-final.wgsl", "Prefix Sum Final Shader")
    let binScatterModule = await loadShader("./shaders/bin-scatter.wgsl", "Bin Scatter Shader (AoS)")
    let forcesModule = await loadShader("./shaders/forces.wgsl", "Forces Shader (AoS)")
    let integrateModule = await loadShader("./shaders/integrate.wgsl", "Integrate Shader (AoS)")

    shaderModules["binCount"] = cast[JsObject](binCountModule)
    shaderModules["prefixSum"] = cast[JsObject](prefixSumModule)
    shaderModules["prefixLocal"] = cast[JsObject](prefixLocalModule)
    shaderModules["prefixBlocks"] = cast[JsObject](prefixBlocksModule)
    shaderModules["prefixFinal"] = cast[JsObject](prefixFinalModule)
    shaderModules["binScatter"] = cast[JsObject](binScatterModule)
    shaderModules["forces"] = cast[JsObject](forcesModule)
    shaderModules["integrate"] = cast[JsObject](integrateModule)

    consoleLog("[PHASE: SHADER LOADING] Success - 8 AoS shaders loaded".toJs)

    # =========================================================================
    # PHASE: UNIFORM BUFFER CREATION
    # =========================================================================
    let uniformUsage = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst)

    uniformBuffers["gridParams"] = device.createBufferLabeled(32, uniformUsage, "Grid Parameters Uniform")
    uniformBuffers["scanParams"] = device.createBufferLabeled(16, uniformUsage, "Scan Parameters Uniform")
    uniformBuffers["simParams"] = device.createBufferLabeled(208, uniformUsage, "Simulation Parameters Uniform (with matrix + blast)")
    uniformBuffers["integrationParams"] = device.createBufferLabeled(32, uniformUsage, "Integration Parameters Uniform")

    consoleLog("[PHASE: UNIFORM BUFFER CREATION] Success - 4 uniform buffers created".toJs)

    # =========================================================================
    # PHASE: PIPELINE CREATION
    # =========================================================================
    consoleLog("[PHASE: PIPELINE CREATION] Creating AoS compute pipelines...".toJs)

    pipelines["binCount"] = await createPipelineWithValidation("Bin Count", binCountModule, "main")
    pipelines["prefixSum"] = await createPipelineWithValidation("Prefix Sum", prefixSumModule, "main")
    pipelines["prefixLocal"] = await createPipelineWithValidation("Prefix Local", prefixLocalModule, "main")
    pipelines["prefixBlocks"] = await createPipelineWithValidation("Prefix Blocks", prefixBlocksModule, "main")
    pipelines["prefixFinal"] = await createPipelineWithValidation("Prefix Final", prefixFinalModule, "main")
    pipelines["binScatter"] = await createPipelineWithValidation("Bin Scatter", binScatterModule, "main")
    pipelines["forces"] = await createPipelineWithValidation("Forces", forcesModule, "computeForces")
    pipelines["integrate"] = await createPipelineWithValidation("Integrate", integrateModule, "integrate")

    # Extract bind group layouts
    consoleLog("[PHASE: LAYOUT EXTRACTION] Extracting bind group layouts...".toJs)

    device.pushErrorScope("validation")
    bindGroupLayouts["binCount"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binCount"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixSum"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixSum"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixLocal"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixLocal"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixBlocks"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixBlocks"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixFinal"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixFinal"]).getBindGroupLayout(0))
    bindGroupLayouts["binScatter"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binScatter"]).getBindGroupLayout(0))
    bindGroupLayouts["forces"] = cast[JsObject](cast[GPUComputePipeline](pipelines["forces"]).getBindGroupLayout(0))

    # DIAGNOSTIC: Log integrate layout extraction
    consoleLog("[DIAGNOSTIC] Extracting integrate layout from pipeline...".toJs)
    bindGroupLayouts["integrate"] = cast[JsObject](cast[GPUComputePipeline](pipelines["integrate"]).getBindGroupLayout(0))
    consoleLog(("[DIAGNOSTIC] Integrate layout extracted: " & $typeofJs(bindGroupLayouts["integrate"])).toJs)

    let layoutError = await device.popErrorScope()

    if not layoutError.isNullOrUndefined:
      raise newException(CatchableError, "Bind group layout extraction failed: " & $layoutError.message)

    # Validate all layouts
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binCount"]), "binCount")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixSum"]), "prefixSum")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixLocal"]), "prefixLocal")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixBlocks"]), "prefixBlocks")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixFinal"]), "prefixFinal")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binScatter"]), "binScatter")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["forces"]), "forces")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["integrate"]), "integrate")

    consoleLog("[PHASE: PIPELINE CREATION] Success - 8 AoS pipelines and layouts validated".toJs)

    isPipelineReady = true

    let resultObj = createJsObject()
    resultObj["success"] = true.toJs
    let infoObj = createJsObject()
    infoObj["shaderCount"] = 8.toJs
    infoObj["pipelineCount"] = 8.toJs
    resultObj["info"] = infoObj
    return resultObj

  except CatchableError as e:
    consoleError(("Pipeline initialization failed: " & e.msg).toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = ("Pipeline initialization error: " & e.msg).cstring.toJs
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
  let parity = params["parity"].to(int)
  let matrix = params["matrix"]

  let numCells = gridW * gridH
  let workgroupSize = 128
  let particleWorkgroups = jsCeil(particleCount.float / workgroupSize.float)

  # =========================================================================
  # PHASE: PER-FRAME UNIFORM UPDATE
  # =========================================================================

  # Grid parameters (used by bin-count and bin-scatter)
  let gridParamsData = newUint32Array(8)
  gridParamsData[0] = gridW
  gridParamsData[1] = gridH
  gridParamsData[4] = particleCount
  let gridParamsFloat = newFloat32Array(gridParamsData.buffer)
  gridParamsFloat[2] = width
  gridParamsFloat[3] = height
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["gridParams"]), 0, gridParamsData)

  # Scan parameters (used by prefix-sum)
  let numBlocksForScan = jsCeil(numCells.float / 256.0)
  let scanParamsData = newUint32Array(4)
  scanParamsData[0] = numCells
  scanParamsData[1] = numBlocksForScan
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["scanParams"]), 0, scanParamsData)

  # Simulation parameters (used by forces)
  # Layout: 16 scalar params + 36 matrix floats = 52 floats
  let simParamsData = newFloat32Array(52)
  simParamsData[0] = dt
  simParamsData[1] = width
  simParamsData[2] = height
  simParamsData[3] = rMax
  simParamsData[4] = fMul
  let simParamsUint = newUint32Array(simParamsData.buffer)
  simParamsUint[5] = gridW
  simParamsUint[6] = gridH
  simParamsData[7] = mouseX
  simParamsData[8] = mouseY
  simParamsData[9] = if mouseDown != 0: 1.0 else: 0.0
  simParamsData[10] = if mouseRightDown != 0: 1.0 else: 0.0
  simParamsUint[11] = particleCount
  simParamsData[12] = blastX
  simParamsData[13] = blastY
  simParamsData[14] = blastStrength
  simParamsData[15] = 0.0  # padding for vec4 alignment
  # Copy attraction matrix (36 floats starting at index 16)
  for i in 0..<36:
    simParamsData[16 + i] = cast[JsObject](matrix[i]).to(float)
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["simParams"]), 0, simParamsData)

  # Integration parameters (8 values = 32 bytes)
  let integrationParamsData = newFloat32Array(8)
  integrationParamsData[0] = width
  integrationParamsData[1] = height
  integrationParamsData[2] = friction
  integrationParamsData[3] = float32(config.CONFIG.maxVelocity)
  let integrationParamsUint = newUint32Array(integrationParamsData.buffer)
  integrationParamsUint[4] = particleCount
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["integrationParams"]), 0, integrationParamsData)

  # =========================================================================
  # PHASE: BIND GROUP CREATION (cached)
  # =========================================================================
  if parity != cachedBindGroupParity:
    await createBindGroups(parity, gridW, gridH)
    cachedBindGroupParity = parity

  # =========================================================================
  # PHASE: COMMAND ENCODING
  # =========================================================================
  let commandEncoder = device.createCommandEncoderLabeled("Physics Frame Command Encoder")

  # Clear gridCounts before bin-count
  let gridCountBytes = numCells * 4
  commandEncoder.clearBuffer(cast[GPUBuffer](gpuBuffers.gridCounts), 0, gridCountBytes)

  # Compute Pass 1: Grid building
  let gridBuildPassDesc = createJsObject()
  gridBuildPassDesc["label"] = "Grid Build Compute Pass".cstring.toJs
  let gridBuildPass = commandEncoder.beginComputePass(gridBuildPassDesc)

  # Pass 1: Bin Count
  gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["binCount"]))
  gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["binCount"]))
  gridBuildPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 2: Prefix Sum (parallel Blelloch algorithm)
  let prefixBlockSize = 256
  let numBlocks = jsCeil(numCells.float / prefixBlockSize.float)

  gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixLocal"]))
  gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixLocal"]))
  gridBuildPass.dispatchWorkgroups(numBlocks)

  gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixBlocks"]))
  gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixBlocks"]))
  gridBuildPass.dispatchWorkgroups(1)

  gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixFinal"]))
  gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixFinal"]))
  gridBuildPass.dispatchWorkgroups(numBlocks)

  gridBuildPass.endPass()

  # Buffer Copy: Initialize fillPointers from gridOffsets
  let fillPointerBytes = numCells * 4
  commandEncoder.copyBufferToBuffer(
    cast[GPUBuffer](gpuBuffers.gridOffsets), 0,
    cast[GPUBuffer](gpuBuffers.fillPointers), 0,
    fillPointerBytes
  )

  # NOTE: Delta buffers are now initialized via atomicStore in forces.wgsl
  # This avoids race conditions between clearBuffer and atomic writes.
  # Each thread atomically resets its own particle's velocity and density deltas.

  # Compute Pass 2: Physics (AoS Pipeline)
  let physicsPassDesc = createJsObject()
  physicsPassDesc["label"] = "Physics Compute Pass (AoS)".cstring.toJs
  let physicsPass = commandEncoder.beginComputePass(physicsPassDesc)

  # Pass 3: Bin Scatter (unified AoS scatter)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["binScatter"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["binScatter"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 4: Forces (reads from particlesSorted, writes density to particles)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["forces"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["forces"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 5: Integrate (unified velocity + position update)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["integrate"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["integrate"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  physicsPass.endPass()

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
    for i in 0..<particleCount:
      let baseIdx = i * 8
      particleData[baseIdx + 0] = cpuBuffers.particlesA[i * 8 + 0]  # pos.x
      particleData[baseIdx + 1] = cpuBuffers.particlesA[i * 8 + 1]  # pos.y
      particleData[baseIdx + 2] = cpuBuffers.particlesA[i * 8 + 2]  # vel.x
      particleData[baseIdx + 3] = cpuBuffers.particlesA[i * 8 + 3]  # vel.y
      particleDataUint[baseIdx + 4] = uint32(cpuBuffers.particlesA[i * 8 + 4])  # species (reinterpret as u32)
      particleData[baseIdx + 5] = cpuBuffers.particlesA[i * 8 + 5]  # density
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

  except CatchableError as e:
    consoleError(("Failed to upload initial data: " & e.msg).toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = e.msg.cstring.toJs
    return resultObj
