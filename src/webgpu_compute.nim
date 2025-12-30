# ==============================================================================
# EMERGENT GARDEN - WEBGPU COMPUTE PIPELINE ORCHESTRATION
# ==============================================================================
#
# This module implements the 7-pass physics pipeline with physical scatter:
# - Pass 1: bin-count (count particles per cell)
# - Pass 2: prefix-sum (exclusive scan for cell offsets)
# - Pass 3a: bin-scatter-positions (physically scatter positions + build indices)
# - Pass 3b: bin-scatter-velocities (physically scatter velocities + species)
# - Pass 4: forces (compute inter-particle forces from SORTED buffers)
# - Pass 5a: integrate-velocities (un-scatter velocities back to original order)
# - Pass 5b: integrate-positions (un-scatter positions back to original order)
#
# BUFFER PARITY (WebGPU path):
# Unlike the WASM path which uses double-buffering with scatter, the WebGPU
# pipeline performs IN-PLACE updates on a single buffer set (always parity 0).
# - Bind groups select buffers based on activeParity at dispatch time
# - All passes read and write to the SAME buffer set
# - No parity flip occurs — the renderer reads from the same buffers
#
# This works because GPU commands execute sequentially within a command buffer,
# and WebGPU handles inter-pass synchronization via implicit barriers.
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
# PASS 3a: BIN-SCATTER-POSITIONS (bin-scatter-positions.wgsl)
#
# PHYSICAL SCATTER: This shader copies position data into sorted buffers,
# enabling sequential memory access in the forces pass (L1 cache hits vs L3 misses).
# Split into two passes due to WebGPU's 8-storage-buffer limit.
#
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | gridParams       | 32 bytes   |
# |   1   | storage       | read           | srcPx            | N * 4      |
# |   2   | storage       | read           | srcPy            | N * 4      |
# |   3   | storage       | read_write     | dstPxSorted      | N * 4      |
# |   4   | storage       | read_write     | dstPySorted      | N * 4      |
# |   5   | storage       | read_write     | sortedIndices    | N * 4      |
# |   6   | storage       | read_write     | reverseIndices   | N * 4      |
# |   7   | storage       | read_write     | fillPointers     | cells * 4  |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 8
# STORAGE BUFFER COUNT: 7 (under 8-buffer WebGPU limit)
#
# PASS 3b: BIN-SCATTER-VELOCITIES (bin-scatter-velocities.wgsl)
#
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | gridParams       | 32 bytes   |
# |   1   | storage       | read           | srcVx            | N * 4      |
# |   2   | storage       | read           | srcVy            | N * 4      |
# |   3   | storage       | read           | srcSpecies       | N * 4      |
# |   4   | storage       | read           | reverseIndices   | N * 4      |
# |   5   | storage       | read_write     | dstVxSorted      | N * 4      |
# |   6   | storage       | read_write     | dstVySorted      | N * 4      |
# |   7   | storage       | read_write     | dstSpeciesSorted | N * 4      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 8
# STORAGE BUFFER COUNT: 7 (under 8-buffer WebGPU limit)
#
# PASS 4: FORCES (forces.wgsl)
#
# CACHE OPTIMIZATION: Forces now reads from SORTED buffers (pxSorted, pySorted, etc.)
# instead of using indirect indexing. Sequential memory access = L1 cache hits.
# Matrix is embedded in SimParams uniform.
#
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | simParams        | 192 bytes  |
# |       | (w/ matrix)   |                | (12 params + 36) |            |
# |   1   | storage       | read           | pxSorted         | N * 4      |
# |   2   | storage       | read           | pySorted         | N * 4      |
# |   3   | storage       | read           | speciesSorted    | N * 4      |
# |   4   | storage       | read           | sortedIndices    | N * 4      |
# |   5   | storage       | read           | cellOffsets      | cells * 4  |
# |   6   | storage       | read           | cellCounts       | cells * 4  |
# |   7   | storage       | read_write     | density          | N * 4      |
# |   8   | storage       | read_write     | velocityDelta    | N * 8      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 9
# STORAGE BUFFER COUNT: 8 (at WebGPU per-stage limit)
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
# PASS 5a: INTEGRATE-VELOCITIES (integrate-velocities.wgsl)
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | integrationParams| 32 bytes   |
# |   1   | storage       | read           | vxSorted         | N * 4      |
# |   2   | storage       | read           | vySorted         | N * 4      |
# |   3   | storage       | read           | sortedIndices    | N * 4      |
# |   4   | storage       | read           | velocityDelta    | N * 8      |
# |   5   | storage       | read_write     | vx (active)      | N * 4      |
# |   6   | storage       | read_write     | vy (active)      | N * 4      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 7
#
# PASS 5b: INTEGRATE-POSITIONS (integrate-positions.wgsl)
# +-------+---------------+----------------+------------------+------------+
# |Binding| Shader Type   | Access         | JS Buffer        | Size       |
# +-------+---------------+----------------+------------------+------------+
# |   0   | uniform       | read           | integrationParams| 32 bytes   |
# |   1   | storage       | read           | pxSorted         | N * 4      |
# |   2   | storage       | read           | pySorted         | N * 4      |
# |   3   | storage       | read           | sortedIndices    | N * 4      |
# |   4   | storage       | read           | vx (active)      | N * 4      |
# |   5   | storage       | read           | vy (active)      | N * 4      |
# |   6   | storage       | read_write     | px (active)      | N * 4      |
# |   7   | storage       | read_write     | py (active)      | N * 4      |
# +-------+---------------+----------------+------------------+------------+
# EXPECTED ENTRY COUNT: 8
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
import config

# Alias for GPU buffers to distinguish from CPU buffers
template gpuBuffers*(): untyped = webgpu_init.buffers

# ==============================================================================
# SECTION 2: BINDING CONTRACT VALIDATION CONSTANTS
# ==============================================================================

# Expected entry counts for each pass (from shader binding manifests above).
# These are the canonical source of truth from the WGSL shader declarations.
const EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT* = 4
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_SUM* = 3
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL* = 4
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS* = 3
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL* = 3
const EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER_POSITIONS* = 8  # Physical scatter positions pass
const EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER_VELOCITIES* = 8  # Physical scatter velocities pass
const EXPECTED_BIND_GROUP_ENTRIES_CELL_STATS* = 8
const EXPECTED_BIND_GROUP_ENTRIES_FORCES* = 9  # Now reads from sorted buffers
const EXPECTED_BIND_GROUP_ENTRIES_DENSITY* = 8
const EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE_VELOCITIES* = 7  # Un-scatter velocities
const EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE_POSITIONS* = 8   # Un-scatter positions

proc getExpectedEntryCount(passName: cstring): int =
  ## Get expected bind group entry count for a pass name.
  case $passName
  of "binCount": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT
  of "prefixSum": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_SUM
  of "prefixLocal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL
  of "prefixBlocks": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS
  of "prefixFinal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL
  of "binScatterPositions": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER_POSITIONS
  of "binScatterVelocities": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER_VELOCITIES
  of "cellStats": result = EXPECTED_BIND_GROUP_ENTRIES_CELL_STATS
  of "forces": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES
  of "density": result = EXPECTED_BIND_GROUP_ENTRIES_DENSITY
  of "integrateVelocities": result = EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE_VELOCITIES
  of "integratePositions": result = EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE_POSITIONS
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

# Bind groups - cached to avoid per-frame recreation overhead.
# In WebGPU mode, parity is always 0 (in-place updates), so bind groups are stable.
var bindGroups* {.exportc.}: JsObject = createJsObject()
var cachedBindGroupParity: int = -1  # -1 = not initialized, tracks when to recreate

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

  # Pass 2: Prefix Sum (legacy - sequential fallback)
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

  # Pass 2a: Prefix Local (parallel Blelloch scan within workgroups)
  let prefixLocalEntries = createJsArray()
  discard prefixLocalEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixLocalEntries.push(createBindGroupEntry(1, gpuBuffers["gridCounts"]))
  discard prefixLocalEntries.push(createBindGroupEntry(2, gpuBuffers["gridOffsets"]))
  discard prefixLocalEntries.push(createBindGroupEntry(3, gpuBuffers["blockSums"]))

  validateBindGroupEntryCount(prefixLocalEntries, "prefixLocal", "bind group creation")
  bindGroups["prefixLocal"] = await createBindGroupWithValidation(
    "Prefix Local",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixLocal"]),
    prefixLocalEntries,
    "Prefix Local Bind Group"
  )

  # Pass 2b: Prefix Blocks (scan of block totals)
  let prefixBlocksEntries = createJsArray()
  discard prefixBlocksEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixBlocksEntries.push(createBindGroupEntry(1, gpuBuffers["blockSums"]))
  discard prefixBlocksEntries.push(createBindGroupEntry(2, gpuBuffers["blockOffsets"]))

  validateBindGroupEntryCount(prefixBlocksEntries, "prefixBlocks", "bind group creation")
  bindGroups["prefixBlocks"] = await createBindGroupWithValidation(
    "Prefix Blocks",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixBlocks"]),
    prefixBlocksEntries,
    "Prefix Blocks Bind Group"
  )

  # Pass 2c: Prefix Final (add block offsets to local results)
  let prefixFinalEntries = createJsArray()
  discard prefixFinalEntries.push(createBindGroupEntry(0, uniformBuffers["scanParams"]))
  discard prefixFinalEntries.push(createBindGroupEntry(1, gpuBuffers["gridOffsets"]))
  discard prefixFinalEntries.push(createBindGroupEntry(2, gpuBuffers["blockOffsets"]))

  validateBindGroupEntryCount(prefixFinalEntries, "prefixFinal", "bind group creation")
  bindGroups["prefixFinal"] = await createBindGroupWithValidation(
    "Prefix Final",
    cast[GPUBindGroupLayout](bindGroupLayouts["prefixFinal"]),
    prefixFinalEntries,
    "Prefix Final Bind Group"
  )

  # Pass 3a: Bin Scatter Positions (physical scatter of positions + index mapping)
  let binScatterPositionsEntries = createJsArray()
  discard binScatterPositionsEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard binScatterPositionsEntries.push(createBindGroupEntry(1, pxSrc))
  discard binScatterPositionsEntries.push(createBindGroupEntry(2, pySrc))
  discard binScatterPositionsEntries.push(createBindGroupEntry(3, gpuBuffers["pxSorted"]))
  discard binScatterPositionsEntries.push(createBindGroupEntry(4, gpuBuffers["pySorted"]))
  discard binScatterPositionsEntries.push(createBindGroupEntry(5, gpuBuffers["sortedIndices"]))
  discard binScatterPositionsEntries.push(createBindGroupEntry(6, gpuBuffers["reverseIndices"]))
  discard binScatterPositionsEntries.push(createBindGroupEntry(7, gpuBuffers["fillPointers"]))

  validateBindGroupEntryCount(binScatterPositionsEntries, "binScatterPositions", "bind group creation")
  bindGroups["binScatterPositions"] = await createBindGroupWithValidation(
    "Bin Scatter Positions",
    cast[GPUBindGroupLayout](bindGroupLayouts["binScatterPositions"]),
    binScatterPositionsEntries,
    "Bin Scatter Positions Bind Group"
  )

  # Pass 3b: Bin Scatter Velocities (physical scatter of velocities + species)
  let vxSrc = if parity == 0: gpuBuffers["vxA"] else: gpuBuffers["vxB"]
  let vySrc = if parity == 0: gpuBuffers["vyA"] else: gpuBuffers["vyB"]

  let binScatterVelocitiesEntries = createJsArray()
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(1, vxSrc))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(2, vySrc))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(3, speciesSrc))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(4, gpuBuffers["reverseIndices"]))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(5, gpuBuffers["vxSorted"]))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(6, gpuBuffers["vySorted"]))
  discard binScatterVelocitiesEntries.push(createBindGroupEntry(7, gpuBuffers["speciesSorted"]))

  validateBindGroupEntryCount(binScatterVelocitiesEntries, "binScatterVelocities", "bind group creation")
  bindGroups["binScatterVelocities"] = await createBindGroupWithValidation(
    "Bin Scatter Velocities",
    cast[GPUBindGroupLayout](bindGroupLayouts["binScatterVelocities"]),
    binScatterVelocitiesEntries,
    "Bin Scatter Velocities Bind Group"
  )

  # Pass 3b: Cell Statistics (for hierarchical forces LOD)
  let cellStatsEntries = createJsArray()
  discard cellStatsEntries.push(createBindGroupEntry(0, uniformBuffers["cellStatsParams"]))
  discard cellStatsEntries.push(createBindGroupEntry(1, pxSrc))
  discard cellStatsEntries.push(createBindGroupEntry(2, pySrc))
  discard cellStatsEntries.push(createBindGroupEntry(3, speciesSrc))
  discard cellStatsEntries.push(createBindGroupEntry(4, gpuBuffers["sortedIndices"]))
  discard cellStatsEntries.push(createBindGroupEntry(5, gpuBuffers["gridOffsets"]))
  discard cellStatsEntries.push(createBindGroupEntry(6, gpuBuffers["gridCounts"]))
  discard cellStatsEntries.push(createBindGroupEntry(7, gpuBuffers["cellStats"]))

  validateBindGroupEntryCount(cellStatsEntries, "cellStats", "bind group creation")
  bindGroups["cellStats"] = await createBindGroupWithValidation(
    "Cell Stats",
    cast[GPUBindGroupLayout](bindGroupLayouts["cellStats"]),
    cellStatsEntries,
    "Cell Stats Bind Group"
  )

  # Pass 4: Forces (reads from SORTED buffers for cache efficiency)
  let forcesEntries = createJsArray()
  discard forcesEntries.push(createBindGroupEntry(0, uniformBuffers["simParams"]))
  discard forcesEntries.push(createBindGroupEntry(1, gpuBuffers["pxSorted"]))      # Sorted positions
  discard forcesEntries.push(createBindGroupEntry(2, gpuBuffers["pySorted"]))      # Sorted positions
  discard forcesEntries.push(createBindGroupEntry(3, gpuBuffers["speciesSorted"])) # Sorted species
  discard forcesEntries.push(createBindGroupEntry(4, gpuBuffers["sortedIndices"])) # sortedIdx -> originalIdx
  discard forcesEntries.push(createBindGroupEntry(5, gpuBuffers["gridOffsets"]))
  discard forcesEntries.push(createBindGroupEntry(6, gpuBuffers["gridCounts"]))
  discard forcesEntries.push(createBindGroupEntry(7, denSrc))                      # Density output (original order)
  discard forcesEntries.push(createBindGroupEntry(8, gpuBuffers["velocityDelta"]))

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

  # Pass 5a: Integrate Velocities (un-scatter velocities from sorted to original)
  let pxActive = if parity == 0: gpuBuffers["pxA"] else: gpuBuffers["pxB"]
  let pyActive = if parity == 0: gpuBuffers["pyA"] else: gpuBuffers["pyB"]
  let vxActive = if parity == 0: gpuBuffers["vxA"] else: gpuBuffers["vxB"]
  let vyActive = if parity == 0: gpuBuffers["vyA"] else: gpuBuffers["vyB"]

  let integrateVelocitiesEntries = createJsArray()
  discard integrateVelocitiesEntries.push(createBindGroupEntry(0, uniformBuffers["integrationParams"]))
  discard integrateVelocitiesEntries.push(createBindGroupEntry(1, gpuBuffers["vxSorted"]))      # Read from sorted
  discard integrateVelocitiesEntries.push(createBindGroupEntry(2, gpuBuffers["vySorted"]))      # Read from sorted
  discard integrateVelocitiesEntries.push(createBindGroupEntry(3, gpuBuffers["sortedIndices"])) # sortedIdx -> originalIdx
  discard integrateVelocitiesEntries.push(createBindGroupEntry(4, gpuBuffers["velocityDelta"])) # Deltas (original order)
  discard integrateVelocitiesEntries.push(createBindGroupEntry(5, vxActive))                    # Write to original
  discard integrateVelocitiesEntries.push(createBindGroupEntry(6, vyActive))                    # Write to original

  validateBindGroupEntryCount(integrateVelocitiesEntries, "integrateVelocities", "bind group creation")
  bindGroups["integrateVelocities"] = await createBindGroupWithValidation(
    "Integrate Velocities",
    cast[GPUBindGroupLayout](bindGroupLayouts["integrateVelocities"]),
    integrateVelocitiesEntries,
    "Integrate Velocities Bind Group"
  )

  # Pass 5b: Integrate Positions (un-scatter positions from sorted to original)
  let integratePositionsEntries = createJsArray()
  discard integratePositionsEntries.push(createBindGroupEntry(0, uniformBuffers["integrationParams"]))
  discard integratePositionsEntries.push(createBindGroupEntry(1, gpuBuffers["pxSorted"]))       # Read from sorted
  discard integratePositionsEntries.push(createBindGroupEntry(2, gpuBuffers["pySorted"]))       # Read from sorted
  discard integratePositionsEntries.push(createBindGroupEntry(3, gpuBuffers["sortedIndices"]))  # sortedIdx -> originalIdx
  discard integratePositionsEntries.push(createBindGroupEntry(4, vxActive))                     # Read new velocity
  discard integratePositionsEntries.push(createBindGroupEntry(5, vyActive))                     # Read new velocity
  discard integratePositionsEntries.push(createBindGroupEntry(6, pxActive))                     # Write to original
  discard integratePositionsEntries.push(createBindGroupEntry(7, pyActive))                     # Write to original

  validateBindGroupEntryCount(integratePositionsEntries, "integratePositions", "bind group creation")
  bindGroups["integratePositions"] = await createBindGroupWithValidation(
    "Integrate Positions",
    cast[GPUBindGroupLayout](bindGroupLayouts["integratePositions"]),
    integratePositionsEntries,
    "Integrate Positions Bind Group"
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
    let prefixLocalModule = await loadShader("./shaders/prefix-sum-local.wgsl", "Prefix Sum Local Shader")
    let prefixBlocksModule = await loadShader("./shaders/prefix-sum-blocks.wgsl", "Prefix Sum Blocks Shader")
    let prefixFinalModule = await loadShader("./shaders/prefix-sum-final.wgsl", "Prefix Sum Final Shader")
    let binScatterPositionsModule = await loadShader("./shaders/bin-scatter-positions.wgsl", "Bin Scatter Positions Shader")
    let binScatterVelocitiesModule = await loadShader("./shaders/bin-scatter-velocities.wgsl", "Bin Scatter Velocities Shader")
    let cellStatsModule = await loadShader("./shaders/cell-stats.wgsl", "Cell Stats Shader")
    let forcesModule = await loadShader("./shaders/forces.wgsl", "Forces Shader")
    let densityModule = await loadShader("./shaders/density.wgsl", "Density Shader")
    let integrateVelocitiesModule = await loadShader("./shaders/integrate-velocities.wgsl", "Integrate Velocities Shader")
    let integratePositionsModule = await loadShader("./shaders/integrate-positions.wgsl", "Integrate Positions Shader")

    shaderModules["cellStats"] = cast[JsObject](cellStatsModule)
    shaderModules["binCount"] = cast[JsObject](binCountModule)
    shaderModules["prefixSum"] = cast[JsObject](prefixSumModule)
    shaderModules["prefixLocal"] = cast[JsObject](prefixLocalModule)
    shaderModules["prefixBlocks"] = cast[JsObject](prefixBlocksModule)
    shaderModules["prefixFinal"] = cast[JsObject](prefixFinalModule)
    shaderModules["binScatterPositions"] = cast[JsObject](binScatterPositionsModule)
    shaderModules["binScatterVelocities"] = cast[JsObject](binScatterVelocitiesModule)
    shaderModules["forces"] = cast[JsObject](forcesModule)
    shaderModules["density"] = cast[JsObject](densityModule)
    shaderModules["integrateVelocities"] = cast[JsObject](integrateVelocitiesModule)
    shaderModules["integratePositions"] = cast[JsObject](integratePositionsModule)

    consoleLog(("[PHASE: SHADER LOADING] Success - Shaders loaded: 12").toJs)

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
    uniformBuffers["integrationParams"] = device.createBufferLabeled(32, uniformUsage, "Integration Parameters Uniform")

    # Density parameters (32 bytes aligned)
    uniformBuffers["densityParams"] = device.createBufferLabeled(32, uniformUsage, "Density Parameters Uniform")

    # Cell stats parameters (16 bytes aligned)
    uniformBuffers["cellStatsParams"] = device.createBufferLabeled(16, uniformUsage, "Cell Stats Parameters Uniform")

    consoleLog("[PHASE: UNIFORM BUFFER CREATION] Success - Uniform buffers created: 6".toJs)

    # =========================================================================
    # PHASE: PIPELINE CREATION
    # =========================================================================
    consoleLog("[PHASE: PIPELINE CREATION] Creating compute pipelines...".toJs)

    pipelines["binCount"] = await createPipelineWithValidation("Bin Count", binCountModule, "main")
    pipelines["prefixSum"] = await createPipelineWithValidation("Prefix Sum", prefixSumModule, "main")
    pipelines["prefixLocal"] = await createPipelineWithValidation("Prefix Local", prefixLocalModule, "main")
    pipelines["prefixBlocks"] = await createPipelineWithValidation("Prefix Blocks", prefixBlocksModule, "main")
    pipelines["prefixFinal"] = await createPipelineWithValidation("Prefix Final", prefixFinalModule, "main")
    pipelines["binScatterPositions"] = await createPipelineWithValidation("Bin Scatter Positions", binScatterPositionsModule, "main")
    pipelines["binScatterVelocities"] = await createPipelineWithValidation("Bin Scatter Velocities", binScatterVelocitiesModule, "main")
    pipelines["cellStats"] = await createPipelineWithValidation("Cell Stats", cellStatsModule, "computeCellStats")
    pipelines["forces"] = await createPipelineWithValidation("Forces", forcesModule, "computeForces")
    pipelines["density"] = await createPipelineWithValidation("Density", densityModule, "computeDensity")
    pipelines["integrateVelocities"] = await createPipelineWithValidation("Integrate Velocities", integrateVelocitiesModule, "main")
    pipelines["integratePositions"] = await createPipelineWithValidation("Integrate Positions", integratePositionsModule, "main")

    # Extract bind group layouts
    consoleLog("[PHASE: LAYOUT EXTRACTION] Extracting bind group layouts...".toJs)

    device.pushErrorScope("validation")
    bindGroupLayouts["binCount"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binCount"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixSum"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixSum"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixLocal"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixLocal"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixBlocks"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixBlocks"]).getBindGroupLayout(0))
    bindGroupLayouts["prefixFinal"] = cast[JsObject](cast[GPUComputePipeline](pipelines["prefixFinal"]).getBindGroupLayout(0))
    bindGroupLayouts["binScatterPositions"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binScatterPositions"]).getBindGroupLayout(0))
    bindGroupLayouts["binScatterVelocities"] = cast[JsObject](cast[GPUComputePipeline](pipelines["binScatterVelocities"]).getBindGroupLayout(0))
    bindGroupLayouts["cellStats"] = cast[JsObject](cast[GPUComputePipeline](pipelines["cellStats"]).getBindGroupLayout(0))
    bindGroupLayouts["forces"] = cast[JsObject](cast[GPUComputePipeline](pipelines["forces"]).getBindGroupLayout(0))
    bindGroupLayouts["density"] = cast[JsObject](cast[GPUComputePipeline](pipelines["density"]).getBindGroupLayout(0))
    bindGroupLayouts["integrateVelocities"] = cast[JsObject](cast[GPUComputePipeline](pipelines["integrateVelocities"]).getBindGroupLayout(0))
    bindGroupLayouts["integratePositions"] = cast[JsObject](cast[GPUComputePipeline](pipelines["integratePositions"]).getBindGroupLayout(0))
    let layoutError = await device.popErrorScope()

    if not layoutError.isNullOrUndefined:
      raise newException(CatchableError, "Bind group layout extraction failed: " & $layoutError.message)

    # Validate all layouts
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binCount"]), "binCount")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixSum"]), "prefixSum")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixLocal"]), "prefixLocal")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixBlocks"]), "prefixBlocks")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["prefixFinal"]), "prefixFinal")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binScatterPositions"]), "binScatterPositions")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["binScatterVelocities"]), "binScatterVelocities")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["cellStats"]), "cellStats")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["forces"]), "forces")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["density"]), "density")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["integrateVelocities"]), "integrateVelocities")
    validateBindGroupLayout(cast[GPUBindGroupLayout](bindGroupLayouts["integratePositions"]), "integratePositions")

    consoleLog("[PHASE: PIPELINE CREATION] Success - All pipelines and layouts validated".toJs)

    isPipelineReady = true

    let resultObj = createJsObject()
    resultObj["success"] = true.toJs
    let infoObj = createJsObject()
    infoObj["shaderCount"] = 12.toJs
    infoObj["pipelineCount"] = 12.toJs
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
  let workgroupSize = 128  # Tuned for performance - must match shader @workgroup_size
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
  # struct ScanParams { numCells: u32, numBlocks: u32, padding1: u32, padding2: u32 }
  let numBlocksForScan = jsCeil(numCells.float / 256.0)  # 256 = prefix sum block size
  let scanParamsData = newUint32Array(4)
  scanParamsData[0] = numCells
  scanParamsData[1] = numBlocksForScan
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

  # Integration parameters (8 values = 32 bytes)
  let integrationParamsData = newFloat32Array(8)
  integrationParamsData[0] = width
  integrationParamsData[1] = height
  integrationParamsData[2] = friction
  integrationParamsData[3] = float32(config.CONFIG.maxVelocity)
  let integrationParamsUint = newUint32Array(integrationParamsData.buffer)
  integrationParamsUint[4] = particleCount
  integrationParamsUint[5] = 0  # padding
  integrationParamsUint[6] = 0  # padding
  integrationParamsUint[7] = 0  # padding
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["integrationParams"]), 0, integrationParamsData)

  # Cell statistics parameters (for hierarchical forces LOD)
  let cellStatsParamsData = newUint32Array(4)
  cellStatsParamsData[0] = numCells
  cellStatsParamsData[1] = particleCount
  cellStatsParamsData[2] = 0 # padding
  cellStatsParamsData[3] = 0 # padding
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["cellStatsParams"]), 0, cellStatsParamsData)

  # =========================================================================
  # PHASE: BIND GROUP CREATION (cached)
  # =========================================================================
  # Only recreate bind groups when parity changes (in WebGPU mode, this is never)
  if parity != cachedBindGroupParity:
    await createBindGroups(parity, gridW, gridH)
    cachedBindGroupParity = parity

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
  # Toggle between parallel (Blelloch) and sequential implementations
  const USE_PARALLEL_PREFIX_SUM = true  # Set to true for parallel, false for sequential

  when USE_PARALLEL_PREFIX_SUM:
    # Parallel Prefix Sum (3-pass Blelloch algorithm)
    # - Each workgroup processes 256 cells
    # - numBlocks = ceil(numCells / 256)
    let prefixBlockSize = 256
    let numBlocks = jsCeil(numCells.float / prefixBlockSize.float)

    # Pass 2a: Local scan within workgroups
    gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixLocal"]))
    gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixLocal"]))
    gridBuildPass.dispatchWorkgroups(numBlocks)

    # Pass 2b: Scan block totals (single workgroup)
    gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixBlocks"]))
    gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixBlocks"]))
    gridBuildPass.dispatchWorkgroups(1)

    # Pass 2c: Add block offsets to local results
    gridBuildPass.setPipeline(cast[GPUComputePipeline](pipelines["prefixFinal"]))
    gridBuildPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["prefixFinal"]))
    gridBuildPass.dispatchWorkgroups(numBlocks)
  else:
    # Sequential Prefix Sum (single-threaded fallback)
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

  # Clear velocityDelta buffer before forces pass (required for atomic accumulation)
  # Buffer is interleaved fixed-point i32: [deltaVx_0, deltaVy_0, deltaVx_1, ...]
  let velocityDeltaBytes = particleCount * 2 * 4  # 2 i32 values per particle
  commandEncoder.clearBuffer(cast[GPUBuffer](gpuBuffers["velocityDelta"]), 0, velocityDeltaBytes)

  # Compute Pass 2: Physics (Physical Scatter Pipeline)
  let physicsPassDesc = createJsObject()
  physicsPassDesc["label"] = "Physics Compute Pass".cstring.toJs
  let physicsPass = commandEncoder.beginComputePass(physicsPassDesc)

  # Pass 3a: Bin Scatter Positions (physical scatter + index building)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["binScatterPositions"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["binScatterPositions"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 3b: Bin Scatter Velocities (uses reverseIndices from Pass 3a)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["binScatterVelocities"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["binScatterVelocities"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Cell-stats pass removed - LOD disabled due to visual artifacts

  # Pass 4: Forces + Density (reads from SORTED buffers for L1 cache efficiency)
  # Sequential memory access: pxSorted[j] instead of px[sortedIndices[j]]
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["forces"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["forces"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 5a: Integrate Velocities (un-scatter from sorted to original)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["integrateVelocities"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["integrateVelocities"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  # Pass 5b: Integrate Positions (un-scatter from sorted to original)
  physicsPass.setPipeline(cast[GPUComputePipeline](pipelines["integratePositions"]))
  physicsPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["integratePositions"]))
  physicsPass.dispatchWorkgroups(particleWorkgroups)

  physicsPass.endPass()

  # Submit compute work (no readback needed - render shader reads directly from GPU buffers)
  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = createJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  queue.submit(commandBufferArray)

  # NOTE: WebGPU does IN-PLACE updates on a single buffer set.
  # No parity flip needed - the same buffer that was written is read by renderer.
  # This differs from WASM path which scatters to opposite buffer and flips.

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

