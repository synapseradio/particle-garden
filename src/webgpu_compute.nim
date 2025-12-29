# ==============================================================================
# EMERGENT GARDEN - WEBGPU COMPUTE PIPELINE ORCHESTRATION
# ==============================================================================
#
# This module implements the 5-pass physics pipeline:
# - Pass 1: bin-count (count particles per cell)
# - Pass 2: prefix-sum (exclusive scan for cell offsets)
# - Pass 3: bin-scatter (scatter particles to sorted order)
# - Pass 4: forces (compute inter-particle forces)
# - Pass 4b: density (compute particle density)
# - Pass 5: integrate (apply forces and update positions)
#
# BUFFER PARITY:
# The simulation uses double-buffering (A/B sets) to avoid read-write hazards.
# - Read from buffer set with parity N
# - Write to buffer set with parity (1-N)
# - After integration, flip parity
#
# SYNCHRONIZATION:
# All 5 passes are encoded into a single command buffer and submitted together.
# The GPU automatically handles inter-pass synchronization via buffer barriers.
#
# ===============================================================================
# BINDING MANIFESTS (Shader Contract Documentation)
# ===============================================================================
#
# These manifests document the binding contracts between WGSL shaders and JS bind
# groups. The shader declarations are the canonical source of truth.
#
# PASS 1: BIN-COUNT (bin-count.wgsl)
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | gridParams       | 32 bytes   |
# |   1   | storage       | read           | px (parity src)  | N * 4      |
# |   2   | storage       | read           | py (parity src)  | N * 4      |
# |   3   | storage       | read_write     | gridCounts       | cells * 4  |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 4
#
# PASS 2: PREFIX-SUM (prefix-sum.wgsl)
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | scanParams       | 16 bytes   |
# |   1   | storage       | read           | gridCounts       | cells * 4  |
# |   2   | storage       | read_write     | gridOffsets      | cells * 4  |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 3
#
# PASS 3: BIN-SCATTER (bin-scatter.wgsl)
#
# ARCHITECTURAL NOTE: This shader only builds sortedIndices mapping, it does NOT
# physically scatter particle data. The forces pass uses indirect indexing
# (pxA[sortedIndices[j]]) to read particles in spatially-sorted order from the
# original unsorted buffers. This design keeps us under WebGPU's 8-storage-buffer
# limit. If cache performance becomes a bottleneck, we could split into multiple
# passes to physically scatter data.
#
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | gridParams       | 32 bytes   |
# |   1   | storage       | read           | srcPx            | N * 4      |
# |   2   | storage       | read           | srcPy            | N * 4      |
# |   3   | storage       | read_write     | sortedIndices    | N * 4      |
# |   4   | storage       | read_write     | fillPointers     | cells * 4  |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 5
# STORAGE BUFFER COUNT: 4 (under 8-buffer WebGPU limit)
#
# NOTE: fillPointers is copied from gridOffsets by JS before dispatch
#
# PASS 4: FORCES (forces.wgsl)
#
# ARCHITECTURAL NOTE: JS binds only the ACTIVE buffer set (A or B) based on
# parity - shader doesn't select at runtime. Matrix is embedded in SimParams
# uniform to stay at exactly 8 storage buffers (the WebGPU per-stage limit).
# Density computation removed; add separate pass if needed.
#
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | simParams        | 192 bytes  |
# |       | (w/ matrix)   |                | (12 params + 36) |            |
# |   1   | storage       | read           | pxSrc (active)   | N * 4      |
# |   2   | storage       | read           | pySrc (active)   | N * 4      |
# |   3   | storage       | read           | speciesSrc       | N * 4      |
# |   4   | storage       | read           | sortedIndices    | N * 4      |
# |   5   | storage       | read           | cellOffsets      | cells * 4  |
# |   6   | storage       | read           | cellCounts       | cells * 4  |
# |   7   | storage       | read_write     | vxDelta          | N * 4      |
# |   8   | storage       | read_write     | vyDelta          | N * 4      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 9
# STORAGE BUFFER COUNT: 8 (at WebGPU limit)
#
# PASS 4b: DENSITY (density.wgsl)
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | densityParams    | 32 bytes   |
# |   1   | storage       | read           | pxSrc (active)   | N * 4      |
# |   2   | storage       | read           | pySrc (active)   | N * 4      |
# |   3   | storage       | read           | speciesSrc       | N * 4      |
# |   4   | storage       | read           | sortedIndices    | N * 4      |
# |   5   | storage       | read           | cellOffsets      | cells * 4  |
# |   6   | storage       | read           | cellCounts       | cells * 4  |
# |   7   | storage       | read_write     | density          | N * 4      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 8
#
# PASS 5: INTEGRATE (integrate.wgsl)
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | integrationParams| 16 bytes   |
# |   1   | storage       | read_write     | px (active)      | N * 4      |
# |   2   | storage       | read_write     | py (active)      | N * 4      |
# |   3   | storage       | read_write     | vx (active)      | N * 4      |
# |   4   | storage       | read_write     | vy (active)      | N * 4      |
# |   5   | storage       | read           | vxDelta          | N * 4      |
# |   6   | storage       | read           | vyDelta          | N * 4      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 7
#
# Compile with: nim js -d:release -d:danger --out:web/webgpu-compute.js src/webgpu_compute.nim
#
# ==============================================================================

from std/jsffi import JsObject, toJs, to, `[]`, `[]=`
import std/asyncjs
import bindings/js_interop
import bindings/webgpu
import bindings/typed_arrays

# Local aliases to avoid ambiguity with std/jsffi (which js_interop exports)
proc createJsObject(): JsObject {.importjs: "({})".}
proc createJsArray(): JsObject {.importjs: "([])".}
proc typeofJs(obj: JsObject): cstring {.importjs: "(typeof #)".}

import webgpu_init
import buffers as cpuBuffers

# Alias for GPU buffers to distinguish from CPU buffers
template gpuBuffers*(): untyped = webgpu_init.buffers

# ==============================================================================
# SECTION 2: BINDING CONTRACT VALIDATION CONSTANTS
# ==============================================================================

# Expected entry counts for each pass (from shader binding manifests above).
# These are the canonical source of truth from the WGSL shader declarations.
const EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT* = 4
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_SUM* = 3
const EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER* = 5
const EXPECTED_BIND_GROUP_ENTRIES_FORCES* = 9
const EXPECTED_BIND_GROUP_ENTRIES_DENSITY* = 8
const EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE* = 7

proc getExpectedEntryCount(passName: cstring): int =
  ## Get expected bind group entry count for a pass name.
  case $passName
  of "binCount": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT
  of "prefixSum": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_SUM
  of "binScatter": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER
  of "forces": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES
  of "density": result = EXPECTED_BIND_GROUP_ENTRIES_DENSITY
  of "integrate": result = EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE
  else: result = -1

# ==============================================================================
# SECTION 3: PIPELINE STATE
# ==============================================================================

# Compiled shader modules for each pass.
var shaderModules* {.exportc.}: JsObject = createJsObject()

# Compute pipelines for each pass.
var pipelines* {.exportc.}: JsObject = createJsObject()

# Bind group layouts for each pass.
var bindGroupLayouts* {.exportc.}: JsObject = createJsObject()

# Uniform buffers for passing parameters to shaders.
var uniformBuffers* {.exportc.}: JsObject = createJsObject()

# Bind groups (created per-frame based on parity).
# We don't cache these because they change with parity.
var bindGroups* {.exportc.}: JsObject = createJsObject()

# Whether pipelines have been initialized.
var isPipelineReady* {.exportc.}: bool = false

# ==============================================================================
# SECTION 4: SHADER VALIDATION
# ==============================================================================

proc jsArrayLength*(arr: JsObject): int {.importjs: "#.length".}
  ## Get length of a JavaScript array.

proc jsArrayFilter*(arr: JsObject, predicate: proc(item: JsObject): bool): JsObject {.importjs: "#.filter(#)".}
  ## Filter a JavaScript array.

proc jsArrayMap*(arr: JsObject, mapper: proc(item: JsObject): JsObject): JsObject {.importjs: "#.map(#)".}
  ## Map a JavaScript array.

proc jsArrayJoin*(arr: JsObject, separator: cstring): cstring {.importjs: "#.join(#)".}
  ## Join array elements into a string.

proc msgType*(msg: JsObject): cstring {.importjs: "#.type".}
  ## Get message type from compilation message.

proc msgMessage*(msg: JsObject): cstring {.importjs: "#.message".}
  ## Get message text from compilation message.

proc msgLineNum*(msg: JsObject): int {.importjs: "#.lineNum".}
  ## Get line number from compilation message.

proc validateShaderCompilation*(shaderModule: GPUShaderModule, label: cstring): Future[void] {.async, exportc.} =
  ## VALIDATION: Verify shader compilation succeeded.
  ## Checks for compilation errors that would cause silent failures later.
  let compilationInfo = await shaderModule.getCompilationInfo()
  let messages = compilationInfo.messages

  if jsArrayLength(messages) > 0:
    # Filter for errors
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

      let errorMsg = "Shader compilation failed for \"" & $label & "\":\n" & errorDetails
      raise newException(CatchableError, errorMsg)

    if jsArrayLength(warnings) > 0:
      for i in 0..<jsArrayLength(warnings):
        let w = cast[JsObject](warnings[i])
        consoleWarn(("Shader warning for \"" & $label & "\" Line " & $w.msgLineNum & ": " & $w.msgMessage).toJs)

proc validateBindGroupLayout*(layout: GPUBindGroupLayout, passName: cstring) {.exportc.} =
  ## VALIDATION: Verify bind group layout extraction succeeded.
  ## The layout must exist and be a valid GPUBindGroupLayout object.
  if cast[JsObject](layout).isNullOrUndefined:
    let errorMsg = "Failed to extract bind group layout for pass \"" & $passName & "\". " &
      "Layout is null. This typically means the pipeline creation failed " &
      "or getBindGroupLayout(0) was called on an invalid pipeline."
    raise newException(CatchableError, errorMsg)

  # Type check (GPUBindGroupLayout should be an object)
  if typeofJs(cast[JsObject](layout)) != "object":
    let errorMsg = "Invalid bind group layout for pass \"" & $passName & "\". " &
      "Expected GPUBindGroupLayout object, got " & $typeofJs(cast[JsObject](layout)) & "."
    raise newException(CatchableError, errorMsg)

proc validateBindGroupEntryCount*(entries: JsObject, passName: cstring, phase: cstring) {.exportc.} =
  ## VALIDATION: Verify bind group entry count matches shader expectations.
  ## This catches mismatches between JS bind group creation and WGSL bindings.
  let expected = getExpectedEntryCount(passName)

  if expected == -1:
    let errorMsg = "Internal error: No expected entry count defined for pass \"" & $passName & "\". " &
      "Check EXPECTED_BIND_GROUP_ENTRIES constants."
    raise newException(CatchableError, errorMsg)

  let actual = jsArrayLength(entries)
  if actual != expected:
    let errorMsg = "Bind group entry count mismatch for pass \"" & $passName & "\" during " & $phase & ":\n" &
      "  Expected: " & $expected & " entries (from shader manifest)\n" &
      "  Actual: " & $actual & " entries\n" &
      "  This means the JS bind group creation does not match the WGSL shader bindings.\n" &
      "  Check the binding manifest at the top of this file for the correct contract."
    raise newException(CatchableError, errorMsg)

# ==============================================================================
# SECTION 5: BIND GROUP CREATION (PER-FRAME PHASE)
# ==============================================================================

proc createBindGroupWithValidation*(
  passName: cstring,
  layout: GPUBindGroupLayout,
  entries: JsObject,
  label: cstring
): Future[GPUBindGroup] {.async, exportc.} =
  ## Create a single bind group with error scope validation.
  ## Captures validation errors synchronously for debugging.
  device.pushErrorScope("validation")

  let descriptor = createJsObject()
  descriptor["layout"] = cast[JsObject](layout)
  descriptor["entries"] = entries
  descriptor["label"] = label.toJs

  let bindGroup = device.createBindGroup(descriptor)
  let error = await device.popErrorScope()

  if not error.isNullOrUndefined:
    # Build detailed error message with entry info
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

    let layoutLabel = if not cast[JsObject](layout)["label"].isNullOrUndefined:
      $cast[JsObject](layout)["label"].to(cstring)
    else:
      "unlabeled"

    let errorMsg = "Bind group creation failed for \"" & $passName & "\":\n" &
      "  Error: " & $error.message & "\n" &
      "  Layout: " & layoutLabel & "\n" &
      "  Entries (" & $jsArrayLength(entries) & "):\n" & entryDetails
    raise newException(CatchableError, errorMsg)

  return bindGroup

proc createBindGroupEntry(binding: int, buffer: JsObject): JsObject =
  ## Create a bind group entry for a buffer.
  result = createJsObject()
  result["binding"] = binding.toJs
  let resource = createJsObject()
  resource["buffer"] = buffer
  result["resource"] = resource

proc createBindGroups*(parity: int, gridW: int, gridH: int): Future[void] {.async, exportc.} =
  ## Create bind groups for all passes based on current buffer parity.
  ## This is called each frame because bind groups reference different buffers
  ## depending on read/write parity.
  ##
  ## PHASE: PER-FRAME SETUP
  ## Precondition: Pipelines initialized, bind group layouts extracted
  ## Postcondition: All bind groups created with correct buffer bindings for current parity

  # Determine source buffers based on parity
  let pxSrc = if parity == 0: gpuBuffers["pxA"] else: gpuBuffers["pxB"]
  let pySrc = if parity == 0: gpuBuffers["pyA"] else: gpuBuffers["pyB"]
  let speciesSrc = if parity == 0: gpuBuffers["speciesA"] else: gpuBuffers["speciesB"]
  let denSrc = if parity == 0: gpuBuffers["denA"] else: gpuBuffers["denB"]

  # Pass 1: Bin Count (SoA layout - separate px/py buffers)
  let binCountEntries = createJsArray()
  discard binCountEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard binCountEntries.push(createBindGroupEntry(1, pxSrc))
  discard binCountEntries.push(createBindGroupEntry(2, pySrc))
  discard binCountEntries.push(createBindGroupEntry(3, gpuBuffers["gridCounts"]))

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
  discard prefixSumEntries.push(createBindGroupEntry(1, gpuBuffers["gridCounts"]))
  discard prefixSumEntries.push(createBindGroupEntry(2, gpuBuffers["gridOffsets"]))

  validateBindGroupEntryCount(prefixSumEntries, "prefixSum", "bind group creation")
  bindGroups["prefixSum"] = await createBindGroupWithValidation(
    "Prefix Sum",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixSum"]),
    prefixSumEntries,
    "Prefix Sum Bind Group"
  )

  # Pass 3: Bin Scatter (index mapping only - no physical scatter)
  let binScatterEntries = createJsArray()
  discard binScatterEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard binScatterEntries.push(createBindGroupEntry(1, pxSrc))
  discard binScatterEntries.push(createBindGroupEntry(2, pySrc))
  discard binScatterEntries.push(createBindGroupEntry(3, gpuBuffers["sortedIndices"]))
  discard binScatterEntries.push(createBindGroupEntry(4, gpuBuffers["fillPointers"]))

  validateBindGroupEntryCount(binScatterEntries, "binScatter", "bind group creation")
  bindGroups["binScatter"] = await createBindGroupWithValidation(
    "Bin Scatter",
    cast[GPUBindGroupLayout](bindGroupLayouts["binScatter"]),
    binScatterEntries,
    "Bin Scatter Bind Group"
  )

  # Pass 4: Forces
  let forcesEntries = createJsArray()
  discard forcesEntries.push(createBindGroupEntry(0, uniformBuffers["simParams"]))
  discard forcesEntries.push(createBindGroupEntry(1, pxSrc))
  discard forcesEntries.push(createBindGroupEntry(2, pySrc))
  discard forcesEntries.push(createBindGroupEntry(3, speciesSrc))
  discard forcesEntries.push(createBindGroupEntry(4, gpuBuffers["sortedIndices"]))
  discard forcesEntries.push(createBindGroupEntry(5, gpuBuffers["gridOffsets"]))
  discard forcesEntries.push(createBindGroupEntry(6, gpuBuffers["gridCounts"]))
  discard forcesEntries.push(createBindGroupEntry(7, gpuBuffers["vxDelta"]))
  discard forcesEntries.push(createBindGroupEntry(8, gpuBuffers["vyDelta"]))

  validateBindGroupEntryCount(forcesEntries, "forces", "bind group creation")
  bindGroups["forces"] = await createBindGroupWithValidation(
    "Forces",
    cast[GPUBindGroupLayout](bindGroupLayouts["forces"]),
    forcesEntries,
    "Forces Bind Group"
  )

  # Pass 4b: Density
  let densityEntries = createJsArray()
  discard densityEntries.push(createBindGroupEntry(0, uniformBuffers["densityParams"]))
  discard densityEntries.push(createBindGroupEntry(1, pxSrc))
  discard densityEntries.push(createBindGroupEntry(2, pySrc))
  discard densityEntries.push(createBindGroupEntry(3, speciesSrc))
  discard densityEntries.push(createBindGroupEntry(4, gpuBuffers["sortedIndices"]))
  discard densityEntries.push(createBindGroupEntry(5, gpuBuffers["gridOffsets"]))
  discard densityEntries.push(createBindGroupEntry(6, gpuBuffers["gridCounts"]))
  discard densityEntries.push(createBindGroupEntry(7, denSrc))

  validateBindGroupEntryCount(densityEntries, "density", "bind group creation")
  bindGroups["density"] = await createBindGroupWithValidation(
    "Density",
    cast[GPUBindGroupLayout](bindGroupLayouts["density"]),
    densityEntries,
    "Density Bind Group"
  )

  # Pass 5: Integration (in-place update on active buffer)
  let pxActive = if parity == 0: gpuBuffers["pxA"] else: gpuBuffers["pxB"]
  let pyActive = if parity == 0: gpuBuffers["pyA"] else: gpuBuffers["pyB"]
  let vxActive = if parity == 0: gpuBuffers["vxA"] else: gpuBuffers["vxB"]
  let vyActive = if parity == 0: gpuBuffers["vyA"] else: gpuBuffers["vyB"]

  let integrateEntries = createJsArray()
  discard integrateEntries.push(createBindGroupEntry(0, uniformBuffers["integrationParams"]))
  discard integrateEntries.push(createBindGroupEntry(1, pxActive))
  discard integrateEntries.push(createBindGroupEntry(2, pyActive))
  discard integrateEntries.push(createBindGroupEntry(3, vxActive))
  discard integrateEntries.push(createBindGroupEntry(4, vyActive))
  discard integrateEntries.push(createBindGroupEntry(5, gpuBuffers["vxDelta"]))
  discard integrateEntries.push(createBindGroupEntry(6, gpuBuffers["vyDelta"]))

  validateBindGroupEntryCount(integrateEntries, "integrate", "bind group creation")
  bindGroups["integrate"] = await createBindGroupWithValidation(
    "Integration",
    cast[GPUBindGroupLayout](bindGroupLayouts["integrate"]),
    integrateEntries,
    "Integration Bind Group"
  )

# ==============================================================================
# SECTION 6: SHADER LOADING
# ==============================================================================

proc fetch*(path: cstring): Future[JsObject] {.importjs: "fetch(#)".}
  ## Fetch a resource from a URL.

proc ok*(response: JsObject): bool {.importjs: "#.ok".}
  ## Check if fetch response was successful.

proc statusText*(response: JsObject): cstring {.importjs: "#.statusText".}
  ## Get status text from fetch response.

proc text*(response: JsObject): Future[cstring] {.importjs: "#.text()".}
  ## Get response body as text.

proc loadShader(path: cstring, label: cstring): Future[GPUShaderModule] {.async.} =
  ## Load and compile a WGSL shader from a file path.
  let response = await fetch(path)
  if not response.ok:
    raise newException(CatchableError, "Failed to load shader " & $path & ": " & $response.statusText)

  let code = await response.text()

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
  ## Create a compute pipeline with error scope validation.
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
  ## Initialize all compute pipelines and buffers.
  ## Call this once after WebGPU device initialization.
  ##
  ## Returns: Promise<{success: boolean, error?: string}>
  if not isWebGPUAvailable or device.isNil:
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "WebGPU device not available".cstring.toJs
    return resultObj

  try:
    # =========================================================================
    # PHASE: SHADER LOADING
    # =========================================================================
    consoleLog("[PHASE: SHADER LOADING] Loading WebGPU compute shaders...".toJs)

    let binCountModule = await loadShader("./shaders/bin-count.wgsl", "Bin Count Shader")
    let prefixSumModule = await loadShader("./shaders/prefix-sum.wgsl", "Prefix Sum Shader")
    let binScatterModule = await loadShader("./shaders/bin-scatter.wgsl", "Bin Scatter Shader")
    let forcesModule = await loadShader("./shaders/forces.wgsl", "Forces Shader")
    let densityModule = await loadShader("./shaders/density.wgsl", "Density Shader")
    let integrateModule = await loadShader("./shaders/integrate.wgsl", "Integration Shader")

    shaderModules["binCount"] = cast[JsObject](binCountModule)
    shaderModules["prefixSum"] = cast[JsObject](prefixSumModule)
    shaderModules["binScatter"] = cast[JsObject](binScatterModule)
    shaderModules["forces"] = cast[JsObject](forcesModule)
    shaderModules["density"] = cast[JsObject](densityModule)
    shaderModules["integrate"] = cast[JsObject](integrateModule)

    consoleLog(("[PHASE: SHADER LOADING] Success - Shaders loaded: 6").toJs)

    # =========================================================================
    # PHASE: UNIFORM BUFFER CREATION
    # =========================================================================
    let uniformUsage = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst)

    # Grid parameters for bin-count, bin-scatter (32 bytes aligned)
    uniformBuffers["gridParams"] = device.createBufferLabeled(32, uniformUsage, "Grid Parameters Uniform")

    # Scan parameters for prefix-sum (16 bytes aligned)
    uniformBuffers["scanParams"] = device.createBufferLabeled(16, uniformUsage, "Scan Parameters Uniform")

    # Simulation parameters for forces (192 bytes: 12 params + 36 matrix floats)
    uniformBuffers["simParams"] = device.createBufferLabeled(192, uniformUsage, "Simulation Parameters Uniform (with matrix)")

    # Integration parameters (16 bytes aligned)
    uniformBuffers["integrationParams"] = device.createBufferLabeled(16, uniformUsage, "Integration Parameters Uniform")

    # Density parameters (32 bytes aligned)
    uniformBuffers["densityParams"] = device.createBufferLabeled(32, uniformUsage, "Density Parameters Uniform")

    consoleLog("[PHASE: UNIFORM BUFFER CREATION] Success - Uniform buffers created: 5".toJs)

    # =========================================================================
    # PHASE: PIPELINE CREATION
    # =========================================================================
    consoleLog("[PHASE: PIPELINE CREATION] Creating compute pipelines...".toJs)

    pipelines["binCount"] = await createPipelineWithValidation("Bin Count", binCountModule, "main")
    pipelines["prefixSum"] = await createPipelineWithValidation("Prefix Sum", prefixSumModule, "main")
    pipelines["binScatter"] = await createPipelineWithValidation("Bin Scatter", binScatterModule, "main")
    pipelines["forces"] = await createPipelineWithValidation("Forces", forcesModule, "computeForces")
    pipelines["density"] = await createPipelineWithValidation("Density", densityModule, "computeDensity")
    pipelines["integrate"] = await createPipelineWithValidation("Integration", integrateModule, "integrate")

    # Extract bind group layouts
    consoleLog("[PHASE: LAYOUT EXTRACTION] Extracting bind group layouts...".toJs)

    device.pushErrorScope("validation")
    bindGroupLayouts["binCount"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binCount"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixSum"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixSum"]).getBindGroupLayout(0))
    bindGroupLayouts["binScatter"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binScatter"]).getBindGroupLayout(0))
    bindGroupLayouts["forces"] = cast[JsObject](cast[GPUComputePipeline](pipelines["forces"]).getBindGroupLayout(0))
    bindGroupLayouts["density"] = cast[JsObject](cast[GPUComputePipeline](pipelines["density"]).getBindGroupLayout(0))
    bindGroupLayouts["integrate"] = cast[JsObject](cast[GPUComputePipeline](pipelines["integrate"]).getBindGroupLayout(0))
    let layoutError = await device.popErrorScope()

    if not layoutError.isNullOrUndefined:
      raise newException(CatchableError, "Bind group layout extraction failed: " & $layoutError.message)

    # Validate all layouts
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binCount"]), "binCount")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixSum"]), "prefixSum")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binScatter"]), "binScatter")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["forces"]), "forces")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["density"]), "density")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["integrate"]), "integrate")

    consoleLog("[PHASE: PIPELINE CREATION] Success - All pipelines and layouts validated".toJs)

    isPipelineReady = true

    let resultObj = createJsObject()
    resultObj["success"] = true.toJs
    let infoObj = createJsObject()
    infoObj["shaderCount"] = 6.toJs
    infoObj["pipelineCount"] = 6.toJs
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

proc push*(arr: JsObject, item: JsObject): int {.importjs: "#.push(#)", discardable.}
  ## Push an item onto a JavaScript array.

proc runPhysicsFrame*(params: JsObject): Future[void] {.async, exportc.} =
  ## Run one physics frame using the 5-pass GPU compute pipeline.
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
  let parity = params["parity"].to(int)
  let matrix = params["matrix"]

  let numCells = gridW * gridH
  let workgroupSize = 64
  let particleWorkgroups = jsCeil(particleCount.float / workgroupSize.float)

  # =========================================================================
  # PHASE: PER-FRAME UNIFORM UPDATE
  # =========================================================================

  # Grid parameters (used by bin-count and bin-scatter)
  let gridParamsData = newUint32Array(8)
  gridParamsData[0] = gridW
  gridParamsData[1] = gridH
  # [2] and [3] are floats, set via float view
  gridParamsData[4] = particleCount
  let gridParamsFloat = newFloat32Array(gridParamsData.buffer)
  gridParamsFloat[2] = width
  gridParamsFloat[3] = height
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["gridParams"]), 0, gridParamsData)

  # Scan parameters (used by prefix-sum)
  let scanParamsData = newUint32Array(4)
  scanParamsData[0] = numCells
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["scanParams"]), 0, scanParamsData)

  # Simulation parameters (used by forces)
  let simParamsData = newFloat32Array(48)
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
  # Copy attraction matrix (36 floats starting at index 12)
  for i in 0..<36:
    simParamsData[12 + i] = cast[JsObject](matrix[i]).to(float)
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["simParams"]), 0, simParamsData)

  # Density parameters
  let densityParamsData = newFloat32Array(8)
  densityParamsData[0] = width
  densityParamsData[1] = height
  densityParamsData[2] = rMax
  let densityParamsUint = newUint32Array(densityParamsData.buffer)
  densityParamsUint[3] = gridW
  densityParamsUint[4] = gridH
  densityParamsUint[5] = particleCount
  densityParamsUint[6] = 0 # padding
  densityParamsUint[7] = 0 # padding
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["densityParams"]), 0, densityParamsData)

  # Integration parameters
  let integrationParamsData = newFloat32Array(4)
  integrationParamsData[0] = width
  integrationParamsData[1] = height
  integrationParamsData[2] = friction
  let integrationParamsUint = newUint32Array(integrationParamsData.buffer)
  integrationParamsUint[3] = particleCount
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["integrationParams"]), 0, integrationParamsData)

  # =========================================================================
  # PHASE: BIND GROUP CREATION
  # =========================================================================
  await createBindGroups(parity, gridW, gridH)

  # =========================================================================
  # PHASE: COMMAND ENCODING (DISPATCH)
  # =========================================================================
  let commandEncoder = device.createCommandEncoderLabeled("Physics Frame Command Encoder")

  # Clear gridCounts before bin-count
  let gridCountBytes = numCells * 4
  commandEncoder.clearBuffer(cast[GPUBuffer](gpuBuffers["gridCounts"]), 0, gridCountBytes)

  # Compute Pass 1: Grid building
  let gridBuildPassDesc = createJsObject()
  gridBuildPassDesc["label"] = "Grid Build Compute Pass".cstring.toJs
  let gridBuildPass = commandEncoder.beginComputePass(gridBuildPassDesc)

  # Pass 1: Bin Count
  gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["binCount"]))
  gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["binCount"]))
  gridBuildPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 2: Prefix Sum
  gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixSum"]))
  gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixSum"]))
  gridBuildPass.dispatchWorkgroups(1)

  gridBuildPass.endPass()

  # Buffer Copy: Initialize fillPointers from gridOffsets
  let fillPointerBytes = numCells * 4
  commandEncoder.copyBufferToBuffer(
    cast[GPUBuffer](gpuBuffers["gridOffsets"]), 0,
    cast[GPUBuffer](gpuBuffers["fillPointers"]), 0,
    fillPointerBytes
  )

  # Compute Pass 2: Physics
  let physicsPassDesc = createJsObject()
  physicsPassDesc["label"] = "Physics Compute Pass".cstring.toJs
  let physicsPass = commandEncoder.beginComputePass(physicsPassDesc)

  # Pass 3: Bin Scatter
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["binScatter"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["binScatter"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 4: Forces
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["forces"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["forces"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 4b: Density
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["density"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["density"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 5: Integration
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["integrate"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["integrate"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  physicsPass.endPass()

  # =========================================================================
  # PHASE: GPU->CPU READBACK
  # =========================================================================
  let pxGPU = if parity == 0: gpuBuffers["pxA"] else: gpuBuffers["pxB"]
  let pyGPU = if parity == 0: gpuBuffers["pyA"] else: gpuBuffers["pyB"]
  let vxGPU = if parity == 0: gpuBuffers["vxA"] else: gpuBuffers["vxB"]
  let vyGPU = if parity == 0: gpuBuffers["vyA"] else: gpuBuffers["vyB"]
  let denGPU = if parity == 0: gpuBuffers["denA"] else: gpuBuffers["denB"]
  let speciesGPU = if parity == 0: gpuBuffers["speciesA"] else: gpuBuffers["speciesB"]

  let pxCPU = if parity == 0: cpuBuffers.pxA else: cpuBuffers.pxB
  let pyCPU = if parity == 0: cpuBuffers.pyA else: cpuBuffers.pyB
  let vxCPU = if parity == 0: cpuBuffers.vxA else: cpuBuffers.vxB
  let vyCPU = if parity == 0: cpuBuffers.vyA else: cpuBuffers.vyB
  let denCPU = if parity == 0: cpuBuffers.denA else: cpuBuffers.denB
  let speciesCPU = if parity == 0: cpuBuffers.speciesA else: cpuBuffers.speciesB

  # Create staging buffers for readback
  let bytesPerParticle = particleCount * 4
  let stagingUsage = bitwiseOr(gpuBufferUsageCopyDst, gpuBufferUsageMapRead)

  let stagingPx = device.createBufferLabeled(bytesPerParticle, stagingUsage, "Staging Buffer (px)")
  let stagingPy = device.createBufferLabeled(bytesPerParticle, stagingUsage, "Staging Buffer (py)")
  let stagingVx = device.createBufferLabeled(bytesPerParticle, stagingUsage, "Staging Buffer (vx)")
  let stagingVy = device.createBufferLabeled(bytesPerParticle, stagingUsage, "Staging Buffer (vy)")
  let stagingDen = device.createBufferLabeled(bytesPerParticle, stagingUsage, "Staging Buffer (den)")
  let stagingSpecies = device.createBufferLabeled(bytesPerParticle, stagingUsage, "Staging Buffer (species)")

  # Encode copy commands
  commandEncoder.copyBufferToBuffer(cast[GPUBuffer](pxGPU), 0, stagingPx, 0, bytesPerParticle)
  commandEncoder.copyBufferToBuffer(cast[GPUBuffer](pyGPU), 0, stagingPy, 0, bytesPerParticle)
  commandEncoder.copyBufferToBuffer(cast[GPUBuffer](vxGPU), 0, stagingVx, 0, bytesPerParticle)
  commandEncoder.copyBufferToBuffer(cast[GPUBuffer](vyGPU), 0, stagingVy, 0, bytesPerParticle)
  commandEncoder.copyBufferToBuffer(cast[GPUBuffer](denGPU), 0, stagingDen, 0, bytesPerParticle)
  commandEncoder.copyBufferToBuffer(cast[GPUBuffer](speciesGPU), 0, stagingSpecies, 0, bytesPerParticle)

  # Submit work
  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = createJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  queue.submit(commandBufferArray)

  # Wait for GPU work to complete
  await queue.onSubmittedWorkDone()

  # Map staging buffers and copy to SharedArrayBuffer
  await stagingPx.mapAsyncRead()
  await stagingPy.mapAsyncRead()
  await stagingVx.mapAsyncRead()
  await stagingVy.mapAsyncRead()
  await stagingDen.mapAsyncRead()
  await stagingSpecies.mapAsyncRead()

  let pxMapped = newFloat32Array(stagingPx.getMappedRange())
  let pyMapped = newFloat32Array(stagingPy.getMappedRange())
  let vxMapped = newFloat32Array(stagingVx.getMappedRange())
  let vyMapped = newFloat32Array(stagingVy.getMappedRange())
  let denMapped = newFloat32Array(stagingDen.getMappedRange())
  let speciesMapped = newUint32Array(stagingSpecies.getMappedRange())

  # Copy to CPU buffers
  pxCPU.set(pxMapped.subarray(0, particleCount))
  pyCPU.set(pyMapped.subarray(0, particleCount))
  vxCPU.set(vxMapped.subarray(0, particleCount))
  vyCPU.set(vyMapped.subarray(0, particleCount))
  denCPU.set(denMapped.subarray(0, particleCount))

  # Convert species from u32 (GPU) to u8 (CPU)
  for i in 0..<particleCount:
    speciesCPU[i] = speciesMapped[i]

  # NOTE: WebGPU does IN-PLACE updates on a single buffer set.
  # No parity flip needed - the same buffer that was written is read by renderer.
  # This differs from WASM path which scatters to opposite buffer and flips.

  # Unmap and destroy staging buffers
  stagingPx.unmap()
  stagingPy.unmap()
  stagingVx.unmap()
  stagingVy.unmap()
  stagingDen.unmap()
  stagingSpecies.unmap()

  stagingPx.destroy()
  stagingPy.destroy()
  stagingVx.destroy()
  stagingVy.destroy()
  stagingDen.destroy()
  stagingSpecies.destroy()

# ==============================================================================
# SECTION 10: INITIAL DATA UPLOAD
# ==============================================================================

proc uploadInitialData*(particleCount: int): Future[JsObject] {.async, exportc.} =
  ## Upload initial particle data from SharedArrayBuffer to GPU buffers.
  ## Call this once after pipeline initialization and particle initialization.
  if device.isNil or queue.isNil:
    consoleError("Cannot upload initial data: WebGPU device not initialized".toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "Device not initialized".cstring.toJs
    return resultObj

  try:
    let bytesPerParticle = particleCount * 4

    # Convert species from uint8 to uint32
    let speciesA_u32 = newUint32Array(particleCount)
    let speciesB_u32 = newUint32Array(particleCount)
    for i in 0..<particleCount:
      speciesA_u32[i] = cpuBuffers.speciesA[i]
      speciesB_u32[i] = cpuBuffers.speciesB[i]

    # Upload A set
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["pxA"]), 0, cpuBuffers.pxA.buffer, cpuBuffers.pxA.byteOffset, bytesPerParticle)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["pyA"]), 0, cpuBuffers.pyA.buffer, cpuBuffers.pyA.byteOffset, bytesPerParticle)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["vxA"]), 0, cpuBuffers.vxA.buffer, cpuBuffers.vxA.byteOffset, bytesPerParticle)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["vyA"]), 0, cpuBuffers.vyA.buffer, cpuBuffers.vyA.byteOffset, bytesPerParticle)
    queue.writeBufferTyped(cast[GPUBuffer](gpuBuffers["speciesA"]), 0, speciesA_u32)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["denA"]), 0, cpuBuffers.denA.buffer, cpuBuffers.denA.byteOffset, bytesPerParticle)

    # Upload B set
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["pxB"]), 0, cpuBuffers.pxB.buffer, cpuBuffers.pxB.byteOffset, bytesPerParticle)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["pyB"]), 0, cpuBuffers.pyB.buffer, cpuBuffers.pyB.byteOffset, bytesPerParticle)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["vxB"]), 0, cpuBuffers.vxB.buffer, cpuBuffers.vxB.byteOffset, bytesPerParticle)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["vyB"]), 0, cpuBuffers.vyB.buffer, cpuBuffers.vyB.byteOffset, bytesPerParticle)
    queue.writeBufferTyped(cast[GPUBuffer](gpuBuffers["speciesB"]), 0, speciesB_u32)
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["denB"]), 0, cpuBuffers.denB.buffer, cpuBuffers.denB.byteOffset, bytesPerParticle)

    # Upload attraction matrix
    queue.writeBufferFromView(cast[GPUBuffer](gpuBuffers["matrix"]), 0, cpuBuffers.matrix.buffer, cpuBuffers.matrix.byteOffset, cpuBuffers.matrix.byteLength)

    consoleLog(("Uploaded " & $particleCount & " particles to GPU (" & $(bytesPerParticle * 12 + cpuBuffers.matrix.byteLength) & " bytes)").toJs)

    let resultObj = createJsObject()
    resultObj["success"] = true.toJs
    return resultObj

  except CatchableError as e:
    consoleError(("Failed to upload initial data: " & e.msg).toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = e.msg.cstring.toJs
    return resultObj

