# This module dispatches the GPU compute pipeline with AoS (Array of
# Structures) buffers. Which passes run each frame, and their order, is
# sim_registry.buildFrame's to say — this module executes that frame
# description rather than a fixed pass list.
#
# AoS LAYOUT BENEFIT:
# With AoS, each Particle is a 32-byte struct containing pos, vel, species, density.
# This enables:
# - Fewer buffer bindings (1 particles buffer vs 4-6 separate arrays)
# - Better cache locality when accessing multiple fields
# - Merged passes (bin-scatter and integrate are each a single pass)
#
# Buffer inventory and per-buffer semantics: memory_layout.nim's MemoryOffsets.
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
import field_core
from physics_core import frameFactor
from memory_layout import MAX_BODIES
from body_core import nil
  # Qualified throughout: gpu_types generates BodyParams' field indices under
  # the same BODY_ prefix this module's physical constants carry, so
  # `bodyParamsData[BODY_LINEAR_DAMPING] = body_core.BODY_LINEAR_DAMPING` is
  # the index on the left and the number on the right.

# Alias for GPU buffers to distinguish from CPU buffers
template gpuBuffers*(): untyped = webgpu_init.buffers

# Expected entry counts for each pass (from shader binding manifests).
const EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT* = 3          # AoS: uniform + particles + gridCounts
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL* = 4
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS* = 3
const EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL* = 3
const EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER* = 6        # AoS: merged pass
const EXPECTED_BIND_GROUP_ENTRIES_FORCES* = 8             # AoS: velocity + colony and crowd density deltas
const EXPECTED_BIND_GROUP_ENTRIES_FORCES_SPH* = 7         # SPH: forces' slots, with its own density at 6
const EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE* = 6          # AoS: + all three density deltas to resolve
# Reaction-diffusion passes. See the four field shaders' binding manifests.
const EXPECTED_BIND_GROUP_ENTRIES_FIELD_SEED* = 2         # dstField(storage) + fieldParams (for the nonce)
const EXPECTED_BIND_GROUP_ENTRIES_FIELD_DEPOSIT* = 5      # gridParams + particles + deposit + fieldParams + speciesChemistry
const EXPECTED_BIND_GROUP_ENTRIES_FIELD_RESOLVE* = 4      # srcField(sample) + dstField(storage) + deposit + alive-cell census
const EXPECTED_BIND_GROUP_ENTRIES_RD_STEP* = 4            # srcField(sample) + dstField(storage) + fieldParams + reactionParams
const EXPECTED_BIND_GROUP_ENTRIES_FIELD_FORCE* = 6        # gridParams + particles + field(sample) + velocityDelta + fieldParams + speciesChemistry
# The bodies pass. See body-force.wgsl's binding manifest.
const EXPECTED_BIND_GROUP_ENTRIES_BODY_FORCE* = 6         # gridParams + particles + bodies + envelope + velocityDelta + bodyParams

proc getExpectedEntryCount(passName: cstring): int =
  case $passName
  of "binCount": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_COUNT
  of "prefixLocal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_LOCAL
  of "prefixBlocks": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_BLOCKS
  of "prefixFinal": result = EXPECTED_BIND_GROUP_ENTRIES_PREFIX_FINAL
  of "binScatter": result = EXPECTED_BIND_GROUP_ENTRIES_BIN_SCATTER
  of "forces": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES
  of "forcesSph": result = EXPECTED_BIND_GROUP_ENTRIES_FORCES_SPH
  of "integrate": result = EXPECTED_BIND_GROUP_ENTRIES_INTEGRATE
  of "fieldSeed": result = EXPECTED_BIND_GROUP_ENTRIES_FIELD_SEED
  of "fieldDeposit": result = EXPECTED_BIND_GROUP_ENTRIES_FIELD_DEPOSIT
  of "fieldResolve": result = EXPECTED_BIND_GROUP_ENTRIES_FIELD_RESOLVE
  # rdStepToFront and rdStepToTrail share one WGSL pipeline; each gets its own
  # bind group (opposite ping-pong orientation) with the same three-entry shape.
  of "rdStepToFront", "rdStepToTrail": result = EXPECTED_BIND_GROUP_ENTRIES_RD_STEP
  of "fieldForce": result = EXPECTED_BIND_GROUP_ENTRIES_FIELD_FORCE
  of "bodyForce": result = EXPECTED_BIND_GROUP_ENTRIES_BODY_FORCE
  else: result = -1

var shaderModules* {.exportc.}: JsObject = createJsObject()
var pipelines* {.exportc.}: JsObject = createJsObject()
var bindGroupLayouts* {.exportc.}: JsObject = createJsObject()
var uniformBuffers* {.exportc.}: JsObject = createJsObject()
var bindGroups* {.exportc.}: JsObject = createJsObject()
var cachedBindGroupGridW: int = -1
var cachedBindGroupGridH: int = -1
var isPipelineReady* {.exportc.}: bool = false

# The frame description the executor walks. Rebuilt only when a strength
# crosses zero, never per frame — see sim_registry.nim.
var activeFrame: FrameDescription = @[]
var activeCouplings*: WorldCouplings
var activeRdSteps = 0
  ## Field steps the active description encodes. Zero until the first build, so
  ## the first setCouplings always builds.
  ## Zero until app.nim's subscription delivers the live strengths, which it
  ## does before the frame loop starts. This module sits below the typed state
  ## in the import order and reads the couplings only through setCouplings.

var pendingFieldSeed = false
  ## Set when something asks for a fresh reaction-diffusion pattern; consumed
  ## by the next encoded frame.
var fieldSeedNonce = 0
  ## Written into FieldParams.seedNonce, which field-seed.wgsl hashes to place
  ## its blobs. Incrementing it is what makes each re-seed a DIFFERENT pattern
  ## rather than the same one again.

# Staging arrays for the per-frame uniform uploads, allocated once and refilled
# in place. Every slot each one carries is written unconditionally before its
# upload, so nothing survives a frame; the slots no writer touches stay at the
# zero they were allocated with, exactly as a freshly allocated array gave them.
# A pair of views over one buffer (the *Uint aliases) lets a layout mix u32 and
# f32 members without a second allocation.
let gridParamsData = newUint32Array(GRID_PARAMS_U32_COUNT)
let gridParamsFloat = newFloat32Array(gridParamsData.buffer)
let scanParamsData = newUint32Array(SCAN_PARAMS_U32_COUNT)
let simParamsData = newFloat32Array(SIM_PARAMS_F32_COUNT)
let simParamsUint = newUint32Array(simParamsData.buffer)
let integrationParamsData = newFloat32Array(INTEG_PARAMS_F32_COUNT)
let integrationParamsUint = newUint32Array(integrationParamsData.buffer)
let fieldParamsData = newFloat32Array(FIELD_PARAMS_F32_COUNT)
let chemistryData = newFloat32Array(CHEM_PARAMS_F32_COUNT)
let bodyParamsData = newFloat32Array(BODY_PARAMS_F32_COUNT)
let bodyParamsUint = newUint32Array(bodyParamsData.buffer)
let bodyEnvelopeData = newFloat32Array(MAX_BODIES)
  ## Not a uniform: the envelope is a storage buffer both bodies passes read,
  ## refilled here from the slot table every frame.

var bodyState = body_core.initBodyState()
  ## Everything Nim knows about the bodies. Pose is absent — the GPU owns it —
  ## so this module writes a slot at ignition and reads the clock for the rest.
var bodySeconds = 0.0
  ## The bodies' own clock, in wall-clock seconds, advanced by app.nim's frame
  ## loop. Wall clock rather than the timeScale-scaled dt, because a lifetime
  ## slider set to eight seconds means eight seconds however fast the world is
  ## running; capped delta rather than a timestamp, because a pause or a stall
  ## must not age a body that nothing was drawing.

proc advanceBodyClock*(seconds: float) =
  ## Move the bodies' clock forward. Called once per frame with the same capped
  ## wall-clock delta the weathers run on.
  bodySeconds += seconds

let bodySlotData = newFloat32Array(BODY_SLOT_PARAMS_F32_COUNT)
  ## One body record, refilled per ignition. The pads it was allocated with stay
  ## zero, and so do the four pose slots a new body starts at rest with.

proc writeBodySlot(slot: int) =
  ## Put one slot's record on the GPU, at that slot's own byte offset. The table
  ## is never rewritten wholesale: body-integrate owns pose, so Nim's copy of a
  ## living body's centre is stale from the substep after it ignited.
  let body = bodyState.slots[slot].body
  bodySlotData[BODY_SLOT_CENTER_X] = float32(body.centerX)
  bodySlotData[BODY_SLOT_CENTER_Y] = float32(body.centerY)
  bodySlotData[BODY_SLOT_VEL_X] = float32(body.velX)
  bodySlotData[BODY_SLOT_VEL_Y] = float32(body.velY)
  bodySlotData[BODY_SLOT_ANGLE] = float32(body.angle)
  bodySlotData[BODY_SLOT_ANG_VEL] = float32(body.angVel)
  bodySlotData[BODY_SLOT_RADIUS] = float32(body.radius)
  bodySlotData[BODY_SLOT_ANISOTROPY] = float32(body.anisotropy)
  bodySlotData[BODY_SLOT_BAND_WIDTH] = float32(body.bandWidth)
  bodySlotData[BODY_SLOT_PROXIMITY] = float32(body.proximity)
  bodySlotData[BODY_SLOT_ENCLOSURE] = float32(body.enclosure)
  bodySlotData[BODY_SLOT_INV_MASS] = float32(body.invMass)
  bodySlotData[BODY_SLOT_INV_INERTIA] = float32(body.invInertia)
  # Ordered against the frames already submitted on this queue, so an ignition
  # between frames lands before the next dispatch rather than racing it.
  queue.writeBufferTyped(cast[GPUBuffer](gpuBuffers.bodies),
    slot * BodyLayout.totalSize, bodySlotData)

proc igniteBody*(atX, atY: float): bool =
  ## Put a body at a world point and report whether a slot was found. The one
  ## entry every source of an ignition reaches the world through.
  ##
  ## The world has nowhere to put a body before its buffers exist, so an
  ## ignition arriving then is refused rather than held.
  if not isPipelineReady:
    return false
  let disposition = body_core.BodyDisposition(
    radius: config.CONFIG.bodyRadius,
    bandWidth: config.CONFIG.bodyBand,
    proximity: config.CONFIG.bodyProximity,
    enclosure: config.CONFIG.bodyEnclosure,
    lifetime: config.CONFIG.bodyLifetime)
  # A circle with an even envelope holding half way through its decay.
  let shaping = body_core.BodyShaping(
    anisotropy: 1.0, envelopeSkew: 0.0, sustain: 0.5)
  # The allocator answers where before it answers whether, and it is the same
  # search igniteBody runs, so the index and the record cannot disagree.
  let slot = body_core.freeSlotIndex(bodyState, bodySeconds)
  result = body_core.igniteBody(bodyState, atX, atY, disposition, shaping,
    bodySeconds)
  if result:
    writeBodySlot(slot)

proc requestFieldSeed*() =
  ## Ask for the field to be re-seeded on the next frame. Synchronous and
  ## fire-and-forget, so it is callable straight from an Observable
  ## subscription or from initParticles. Honoured in every world, because the
  ## field exists in every world — scattering spores into a world whose
  ## particles neither feed the field nor feel it still leaves a pattern to
  ## watch, which is the point of the control.
  inc fieldSeedNonce
  pendingFieldSeed = true

func sameFrameShape(lhs, rhs: WorldCouplings): bool =
  ## Whether two coupling vectors compose the same frame. Only the zeros decide
  ## that, which is why this compares them rather than the strengths: a slider
  ## moving from 0.4 to 0.5 must not rebuild anything, and the two settings are
  ## the same world as far as the executor is concerned.
  (lhs.forces == 0.0) == (rhs.forces == 0.0) and
    (lhs.fluid == 0.0) == (rhs.fluid == 0.0) and
    (lhs.deposit == 0.0) == (rhs.deposit == 0.0) and
    (lhs.fieldForce == 0.0) == (rhs.fieldForce == 0.0) and
    (lhs.bodies == 0.0) == (rhs.bodies == 0.0)

proc setCouplings*(couplings: WorldCouplings) =
  ## Adopt the world these strengths describe.
  ##
  ## Called after every write to the simulation state, so the common case is a
  ## slider moving within its range and nothing to do. A strength crossing zero
  ## rebuilds the frame, which is pure sequence construction: every pipeline
  ## this world can dispatch is already registered
  ## (shader_manifest.allShaderSpecs), so a coupling switching on is synchronous.
  ##
  ## Nothing is seeded here. The field starts at its trivial fixed point and
  ## ignites where colonies deposit, which is what makes the pattern a record of
  ## the particles rather than a backdrop they sit on. Seeding is only ever a
  ## deliberate user action (requestFieldSeed).
  ## Time Scale rebuilds too: it sets how many Gray-Scott steps a frame runs,
  ## and the step count is part of the description rather than a uniform.
  let rdSteps = rdStepsForTimeScale(config.CONFIG.timeScale,
    RD_REFERENCE_TIME_SCALE)
  let rebuild = activeFrame.len == 0 or
    not sameFrameShape(activeCouplings, couplings) or
    rdSteps != activeRdSteps
  activeCouplings = couplings
  activeRdSteps = rdSteps
  if rebuild:
    activeFrame = buildFrame(couplings, rdSteps)

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
    consoleError(("Bind group creation failed for \"" & $passName & "\": " & $error.message).toJs)
    raise newException(CatchableError, "Bind group creation failed for \"" & $passName & "\":\n  Error: " & $error.message & "\n  Entries:\n" & entryDetails)

  return bindGroup

proc createBindGroupEntry(binding: int, buffer: JsObject): JsObject =
  result = createJsObject()
  result["binding"] = binding.toJs
  let resource = createJsObject()
  resource["buffer"] = buffer
  result["resource"] = resource

proc createBindGroupResourceEntry(binding: int, resource: JsObject): JsObject =
  ## Bind-group entry whose resource is used directly (a texture view or a
  ## sampler), rather than wrapped in a {buffer: ...} object.
  result = createJsObject()
  result["binding"] = binding.toJs
  result["resource"] = resource

proc push(arr: JsObject, item: JsObject): int {.importjs: "#.push(#)", discardable.}

proc createBindGroups*(gridW: int, gridH: int): Future[void] {.async, exportc.} =
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

  # Note: Original particles buffer not needed here - we read sorted, write to delta buffers
  let forcesEntries = createJsArray()
  discard forcesEntries.push(createBindGroupEntry(0, uniformBuffers["simParams"]))
  discard forcesEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesSorted)))
  discard forcesEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.sortedIndices)))
  discard forcesEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.gridOffsets)))
  discard forcesEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.gridCounts)))
  discard forcesEntries.push(createBindGroupEntry(5, cast[JsObject](gpuBuffers.velocityDelta)))
  discard forcesEntries.push(createBindGroupEntry(6, cast[JsObject](gpuBuffers.densityDelta)))  # Symmetric colony density
  discard forcesEntries.push(createBindGroupEntry(7, cast[JsObject](gpuBuffers.crowdDensityDelta)))  # Species-blind crowd density

  validateBindGroupEntryCount(forcesEntries, "forces", "bind group creation")
  bindGroups["forces"] = await createBindGroupWithValidation(
    "Forces",
    cast[GPUBindGroupLayout](bindGroupLayouts["forces"]),
    forcesEntries,
    "Forces Bind Group"
  )

  # Pass 4 (SPH): forces-sph mirrors the forces layout slot for slot EXCEPT at
  # binding 6, where it reads and writes its own kernel density rather than the
  # density the renderer sees. Always built, so a fluid strength leaving zero
  # finds a ready bind group.
  let forcesSphEntries = createJsArray()
  discard forcesSphEntries.push(createBindGroupEntry(0, uniformBuffers["simParams"]))
  discard forcesSphEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesSorted)))
  discard forcesSphEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.sortedIndices)))
  discard forcesSphEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.gridOffsets)))
  discard forcesSphEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.gridCounts)))
  discard forcesSphEntries.push(createBindGroupEntry(5, cast[JsObject](gpuBuffers.velocityDelta)))
  discard forcesSphEntries.push(createBindGroupEntry(6, cast[JsObject](gpuBuffers.sphDensityDelta)))

  validateBindGroupEntryCount(forcesSphEntries, "forcesSph", "bind group creation")
  bindGroups["forcesSph"] = await createBindGroupWithValidation(
    "SPH Forces",
    cast[GPUBindGroupLayout](bindGroupLayouts["forcesSph"]),
    forcesSphEntries,
    "SPH Forces Bind Group"
  )

  # Applies velocity deltas (Newton's 3rd law accumulation) and density deltas
  # (symmetric neighbor accumulation) with temporal smoothing
  let integrateEntries = createJsArray()
  discard integrateEntries.push(createBindGroupEntry(0, uniformBuffers["integrationParams"]))
  discard integrateEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard integrateEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.velocityDelta)))
  discard integrateEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.densityDelta)))  # Colony density
  discard integrateEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.sphDensityDelta)))  # Fluid's kernel density
  discard integrateEntries.push(createBindGroupEntry(5, cast[JsObject](gpuBuffers.crowdDensityDelta)))  # Crowd density

  validateBindGroupEntryCount(integrateEntries, "integrate", "bind group creation")
  bindGroups["integrate"] = await createBindGroupWithValidation(
    "Integrate",
    cast[GPUBindGroupLayout](bindGroupLayouts["integrate"]),
    integrateEntries,
    "Integrate Bind Group"
  )

  # ==========================================================================
  # REACTION-DIFFUSION PASSES
  # ==========================================================================
  # Built unconditionally (RD pre-warms). The field textures and deposit buffer
  # live in webgpu_init; fieldA is the fixed front — the texture the renderer,
  # fieldForce, and each frame's opening resolve all read. Texture views bind
  # directly; the compute passes read via textureLoad, so no sampler is bound
  # here.
  #
  # THE PING-PONG CHAIN, one frame, front = A and trail = B:
  #   fieldResolve   A -> B   (folds this frame's particle deposits in)
  #   rdStepToFront  B -> A   substep 1
  #   rdStepToTrail  A -> B   substep 2
  #   ...            alternating, RD_STEPS_PER_FRAME of them
  #   rdStepToFront  B -> A   substep RD_STEPS_PER_FRAME (odd, so it ends here)
  # The live field lands on A, where fieldForce and the renderer sample it and
  # the next frame's resolve picks it up. Every key below names its DESTINATION
  # for that reason.
  let fieldViewFront = cast[JsObject](webgpu_init.fieldSampledViewA())
  let fieldViewTrail = cast[JsObject](webgpu_init.fieldSampledViewB())
  let fieldDepositBuf = cast[JsObject](webgpu_init.fieldDepositGpuBuffer())

  # Field Deposit: particles splat inhibitor into the deposit buffer.
  let fieldDepositEntries = createJsArray()
  discard fieldDepositEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard fieldDepositEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard fieldDepositEntries.push(createBindGroupEntry(2, fieldDepositBuf))
  discard fieldDepositEntries.push(createBindGroupEntry(3, uniformBuffers["fieldParams"]))
  discard fieldDepositEntries.push(createBindGroupEntry(4, uniformBuffers["speciesChemistry"]))
  validateBindGroupEntryCount(fieldDepositEntries, "fieldDeposit", "bind group creation")
  bindGroups["fieldDeposit"] = await createBindGroupWithValidation(
    "Field Deposit",
    cast[GPUBindGroupLayout](bindGroupLayouts["fieldDeposit"]),
    fieldDepositEntries,
    "Field Deposit Bind Group"
  )

  # Field Resolve: read front texture (A) + deposits, write trailing texture (B).
  # This is the first of the frame's swaps, which is why the substeps that
  # follow start by writing back to the front.
  let fieldResolveEntries = createJsArray()
  discard fieldResolveEntries.push(createBindGroupResourceEntry(0, fieldViewFront))
  discard fieldResolveEntries.push(createBindGroupResourceEntry(1, fieldViewTrail))
  discard fieldResolveEntries.push(createBindGroupEntry(2, fieldDepositBuf))
  discard fieldResolveEntries.push(createBindGroupEntry(3,
    cast[JsObject](gpuBuffers.fieldAlive)))  # the one-word alive-cell census
  validateBindGroupEntryCount(fieldResolveEntries, "fieldResolve", "bind group creation")
  bindGroups["fieldResolve"] = await createBindGroupWithValidation(
    "Field Resolve",
    cast[GPUBindGroupLayout](bindGroupLayouts["fieldResolve"]),
    fieldResolveEntries,
    "Field Resolve Bind Group"
  )

  # RD Step To Front: read B, write A. The substep sequence starts here.
  let rdToFrontEntries = createJsArray()
  discard rdToFrontEntries.push(createBindGroupResourceEntry(0, fieldViewTrail))
  discard rdToFrontEntries.push(createBindGroupResourceEntry(1, fieldViewFront))
  discard rdToFrontEntries.push(createBindGroupEntry(2, uniformBuffers["fieldParams"]))
  discard rdToFrontEntries.push(createBindGroupEntry(3, uniformBuffers["reactionParams"]))
  validateBindGroupEntryCount(rdToFrontEntries, "rdStepToFront", "bind group creation")
  bindGroups["rdStepToFront"] = await createBindGroupWithValidation(
    "RD Step To Front",
    cast[GPUBindGroupLayout](bindGroupLayouts["rdStepToFront"]),
    rdToFrontEntries,
    "RD Step To Front Bind Group"
  )

  # RD Step To Trail: read A, write B (opposite orientation, same pipeline).
  let rdToTrailEntries = createJsArray()
  discard rdToTrailEntries.push(createBindGroupResourceEntry(0, fieldViewFront))
  discard rdToTrailEntries.push(createBindGroupResourceEntry(1, fieldViewTrail))
  discard rdToTrailEntries.push(createBindGroupEntry(2, uniformBuffers["fieldParams"]))
  discard rdToTrailEntries.push(createBindGroupEntry(3, uniformBuffers["reactionParams"]))
  validateBindGroupEntryCount(rdToTrailEntries, "rdStepToTrail", "bind group creation")
  bindGroups["rdStepToTrail"] = await createBindGroupWithValidation(
    "RD Step To Trail",
    cast[GPUBindGroupLayout](bindGroupLayouts["rdStepToTrail"]),
    rdToTrailEntries,
    "RD Step To Trail Bind Group"
  )

  # Field Seed: write the initial pattern into the FRONT texture only. Not both:
  # every frame opens with fieldResolve reading the front and writing the trail,
  # so the trail is overwritten before any pass reads it. Seeding it too would be
  # a second full-field dispatch that changes nothing.
  let fieldSeedEntries = createJsArray()
  discard fieldSeedEntries.push(createBindGroupResourceEntry(0, fieldViewFront))
  discard fieldSeedEntries.push(createBindGroupEntry(1, uniformBuffers["fieldParams"]))
  validateBindGroupEntryCount(fieldSeedEntries, "fieldSeed", "bind group creation")
  bindGroups["fieldSeed"] = await createBindGroupWithValidation(
    "Field Seed",
    cast[GPUBindGroupLayout](bindGroupLayouts["fieldSeed"]),
    fieldSeedEntries,
    "Field Seed Bind Group"
  )

  # Field Force: sample front field (A), write velocity deltas integrate consumes.
  let fieldForceEntries = createJsArray()
  discard fieldForceEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard fieldForceEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard fieldForceEntries.push(createBindGroupResourceEntry(2, fieldViewFront))
  discard fieldForceEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.velocityDelta)))
  discard fieldForceEntries.push(createBindGroupEntry(4, uniformBuffers["fieldParams"]))
  discard fieldForceEntries.push(createBindGroupEntry(5, uniformBuffers["speciesChemistry"]))
  validateBindGroupEntryCount(fieldForceEntries, "fieldForce", "bind group creation")
  bindGroups["fieldForce"] = await createBindGroupWithValidation(
    "Field Force",
    cast[GPUBindGroupLayout](bindGroupLayouts["fieldForce"]),
    fieldForceEntries,
    "Field Force Bind Group"
  )

  # Bodies: read the table and its envelope, write the velocity deltas
  # integrate consumes. No grid beyond the particle count — a body's reach is
  # its own band, not the neighbour sweep's radius.
  let bodyForceEntries = createJsArray()
  discard bodyForceEntries.push(createBindGroupEntry(0, uniformBuffers["gridParams"]))
  discard bodyForceEntries.push(createBindGroupEntry(1, cast[JsObject](gpuBuffers.particlesA)))
  discard bodyForceEntries.push(createBindGroupEntry(2, cast[JsObject](gpuBuffers.bodies)))
  discard bodyForceEntries.push(createBindGroupEntry(3, cast[JsObject](gpuBuffers.bodyEnvelope)))
  discard bodyForceEntries.push(createBindGroupEntry(4, cast[JsObject](gpuBuffers.velocityDelta)))
  discard bodyForceEntries.push(createBindGroupEntry(5, uniformBuffers["bodyParams"]))
  validateBindGroupEntryCount(bodyForceEntries, "bodyForce", "bind group creation")
  bindGroups["bodyForce"] = await createBindGroupWithValidation(
    "Body Force",
    cast[GPUBindGroupLayout](bindGroupLayouts["bodyForce"]),
    bodyForceEntries,
    "Body Force Bind Group"
  )

proc fetch*(path: cstring): Future[JsObject] {.importjs: "fetch(#)".}
proc ok*(response: JsObject): bool {.importjs: "#.ok".}
proc statusText*(response: JsObject): cstring {.importjs: "#.statusText".}
proc text*(response: JsObject): Future[cstring] {.importjs: "#.text()".}

proc loadShader(path: cstring, label: cstring): Future[GPUShaderModule] {.async.} =
  let response = await fetch(path)
  if not response.ok:
    raise newException(CatchableError, "Failed to load shader " & $path & ": " & $response.statusText)

  let code = await response.text()

  let bindingCount = ($code).count("@binding")
  consoleLog(("[SHADER LOAD] " & $label & " - Length: " & $len($code) & " bytes, @binding count: " & $bindingCount).toJs)

  let descriptor = createJsObject()
  descriptor["code"] = code.toJs
  descriptor["label"] = label.toJs

  let shaderModule = device.createShaderModule(descriptor)
  await validateShaderCompilation(shaderModule, label)
  return shaderModule

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

proc initPipelines*(): Future[JsObject] {.async, exportc.} =
  ## Create every compute pipeline the world can dispatch and arm the frame
  ## description the executor walks.
  if not isWebGPUAvailable or device.isNil:
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "WebGPU device not available".cstring.toJs
    return resultObj

  try:
    # Every pipeline the world can dispatch, created once. There is no
    # per-world subset to collect and deduplicate, because there is one world —
    # and registering everything is what lets a strength leave zero without
    # waiting for a shader to be fetched and compiled.
    let specs = allShaderSpecs()

    consoleLog("[PHASE: SHADER LOADING] Loading compute shaders...".toJs)
    for spec in specs:
      let shaderModule = await loadShader(spec.path.cstring, spec.label.cstring)
      shaderModules[spec.key.cstring] = cast[JsObject](shaderModule)
    consoleLog(("[PHASE: SHADER LOADING] Success - " & $specs.len & " compute shaders loaded").toJs)

    let uniformUsage = bitwiseOr(gpuBufferUsageUniform, gpuBufferUsageCopyDst)

    uniformBuffers["gridParams"] = device.createBufferLabeled(
      wgslUniformSize(GridParamsLayout), uniformUsage, "Grid Parameters Uniform")
    uniformBuffers["scanParams"] = device.createBufferLabeled(
      wgslUniformSize(ScanParamsLayout), uniformUsage, "Scan Parameters Uniform")
    uniformBuffers["simParams"] = device.createBufferLabeled(
      wgslUniformSize(SimParamsLayout), uniformUsage, "Simulation Parameters Uniform (with matrix + force model)")
    uniformBuffers["integrationParams"] = device.createBufferLabeled(32, uniformUsage, "Integration Parameters Uniform")
    # Reaction-diffusion field uniform (feed/kill/diffusion/deltaT/deposit/force).
    uniformBuffers["fieldParams"] = device.createBufferLabeled(
      wgslUniformSize(FieldParamsLayout), uniformUsage, "Field Parameters Uniform (RD)")
    # Which reaction the field runs. Separate from fieldParams because that
    # layout is full at 32 bytes; see gpu_types.ReactionParamsLayout for why
    # the uniform exists ahead of a second reaction.
    uniformBuffers["reactionParams"] = device.createBufferLabeled(
      wgslUniformSize(ReactionParamsLayout), uniformUsage, "Reaction Parameters Uniform")
    # Per-species field coupling: secretion (fieldDeposit) and tropism
    # (fieldForce). Both passes read the same buffer, so a chemistry edit
    # reaches deposit and force in the same frame.
    uniformBuffers["speciesChemistry"] = device.createBufferLabeled(
      wgslUniformSize(SpeciesChemistryLayout), uniformUsage,
      "Species Chemistry Uniform")
    # What both bodies passes need that belongs to no single body.
    uniformBuffers["bodyParams"] = device.createBufferLabeled(
      wgslUniformSize(BodyParamsLayout), uniformUsage, "Body Parameters Uniform")

    # Which reaction rd-step runs. Gray-Scott is the only implemented value, so
    # the contents never vary and the upload belongs here rather than in the
    # frame path. When a second reaction gains a selector, this write moves
    # into whatever handles that selection (the setter, or runPhysicsFrame's
    # field block beside the fieldParams upload), so choosing a reaction stays
    # a value change rather than a bind-group change.
    let reactionParamsData = newFloat32Array(REACTION_PARAMS_F32_COUNT)
    reactionParamsData[REACTION_KIND] = float32(0)
    queue.writeBufferTyped(
      cast[GPUBuffer](uniformBuffers["reactionParams"]), 0, reactionParamsData)

    consoleLog("[PHASE: UNIFORM BUFFER CREATION] Success - 7 uniform buffers created".toJs)

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

    setCouplings(activeCouplings)
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

proc uint32At(view: JsObject, index: int): int {.importjs: "#[#]".}
proc uint32View(buffer: JsObject): JsObject {.importjs: "new Uint32Array(#)".}

var fieldAliveReadbackBusy = false
var latestFieldAlive = 0

proc latestFieldAliveCells*(): int =
  ## Cells above field_core's aliveness threshold at the last readback; zero
  ## means the field is dark. One map-latency stale.
  latestFieldAlive

proc readFieldAlive(): Future[void] {.async.} =
  let readback = cast[GPUBuffer](gpuBuffers.fieldAliveReadback)
  await mapAsyncRead(readback)
  latestFieldAlive = uint32At(uint32View(readback.getMappedRange()), 0)
  readback.unmap()
  fieldAliveReadbackBusy = false

proc runPhysicsFrame*(params: JsObject): Future[void] {.async, exportc.} =
  if not isPipelineReady:
    raise newException(CatchableError, "Pipelines not initialized. Call initPipelines() first.")

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
  let mouseRange = params["mouseRange"].to(float)
  let blastX = params["blastX"].to(float)
  let blastY = params["blastY"].to(float)
  let blastStrength = params["blastStrength"].to(float)
  let matrix = params["matrix"]

  let numCells = gridW * gridH
  # bin-count, bin-scatter, forces, and integrate all dispatch per-particle
  # and share one workgroup-size-derived divisor. They're independently
  # tunable in shader_config.nim's WorkgroupConfig but all sit at the same
  # production value; if that ever diverges, dsParticleWorkgroups needs
  # splitting into per-pass dispatch kinds in sim_registry.
  let workgroupSize = shader_config.getWorkgroupSize("bin-count")
  let particleWorkgroups = jsCeil(particleCount.float / workgroupSize.float)
  # The scan block size is the prefix-sum-local workgroup size; the WGSL side
  # receives the same value via its WORKGROUP_SIZE placeholder.
  let scanBlockSize = shader_config.getWorkgroupSize("prefix-sum-local")
  let scanBlocks = jsCeil(numCells.float / scanBlockSize.float)

  # Grid parameters (used by bin-count and bin-scatter)
  # Layout matches GridParamsLayout in gpu_types.nim
  gridParamsData[GRID_W] = gridW
  gridParamsData[GRID_H] = gridH
  gridParamsData[GRID_PARTICLE_COUNT] = particleCount
  gridParamsFloat[GRID_WORLD_WIDTH] = width
  gridParamsFloat[GRID_WORLD_HEIGHT] = height
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["gridParams"]), 0, gridParamsData)

  # Scan parameters (used by the prefix-sum passes)
  scanParamsData[SCAN_NUM_CELLS] = numCells
  scanParamsData[SCAN_NUM_BLOCKS] = scanBlocks
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["scanParams"]), 0, scanParamsData)

  # Substepping: the executor runs the whole frame description substepCount
  # times per rendered frame for stability at high stiffness, each substep
  # advancing dt/substepCount. Only the fluid needs it, so a world with no fluid
  # runs a single step and pays nothing. sphSubsteps is clamped to sph_core's
  # SPH_MAX_SUBSTEPS ceiling.
  let substepCount =
    if activeCouplings.fluid != 0.0:
      clamp(config.CONFIG.sphSubsteps, 1, SPH_MAX_SUBSTEPS)
    else: 1
  let substepDt = dt / substepCount.float

  # Simulation parameters (used by forces)
  # Layout matches SimParamsLayout in gpu_types.nim
  simParamsData[SIM_DT] = substepDt
  simParamsData[SIM_WORLD_WIDTH] = width
  simParamsData[SIM_WORLD_HEIGHT] = height
  simParamsData[SIM_INTERACTION_RADIUS] = rMax
  simParamsData[SIM_FORCE_MULTIPLIER] = fMul
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
  simParamsData[SIM_FLUID_STRENGTH] = float32(config.CONFIG.fluidStrength)
  # Copy the attraction matrix into its SIM_ATTRACTION_MATRIX_START.._END run
  for matrixSlot in 0 .. SIM_ATTRACTION_MATRIX_END - SIM_ATTRACTION_MATRIX_START:
    simParamsData[SIM_ATTRACTION_MATRIX_START + matrixSlot] = cast[JsObject](matrix[matrixSlot]).to(float)
  simParamsData[SIM_REPULSION_END] = float32(config.CONFIG.repulsionEnd)
  simParamsData[SIM_ATTRACTION_PEAK] = float32(config.CONFIG.attractionPeak)
  simParamsUint[SIM_FORCE_MODEL] = uint32(config.CONFIG.forceModel)  # 0=polynomial, 1=exponential
  simParamsData[SIM_EXP_ALPHA] = float32(config.CONFIG.expRepulsionAlpha)
  simParamsData[SIM_EXP_BETA] = float32(config.CONFIG.expAttractionBeta)
  simParamsData[SIM_MOUSE_RANGE] = mouseRange
  # SPH fluid params (read by forces-sph.wgsl; ignored by forces.wgsl).
  # gamma is the fixed Tait exponent from sph_core, not a live CONFIG value.
  simParamsData[SIM_SPH_REST_DENSITY] = float32(config.CONFIG.sphRestDensity)
  simParamsData[SIM_SPH_STIFFNESS] = float32(config.CONFIG.sphStiffness)
  simParamsData[SIM_SPH_GAMMA] = float32(SPH_DEFAULT_GAMMA)
  simParamsData[SIM_SPH_VISCOSITY] = float32(config.CONFIG.sphViscosity)

  # Crowding: how hard local density attenuates the attractive half of the
  # species force. Zero is the force law without it.
  simParamsData[SIM_CROWDING_STRENGTH] = float32(config.CONFIG.crowdingStrength)

  # The fraction of the interaction radius the fluid's kernel spans. One is the
  # whole radius; the range caps it there, so the smoothing radius can never
  # exceed the sweep's reach.
  simParamsData[SIM_SPH_RADIUS_FRACTION] =
    float32(config.CONFIG.sphRadiusFraction)
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["simParams"]), 0, simParamsData)

  # Layout matches IntegrationParams indices in gpu_types.nim
  integrationParamsData[INTEG_WORLD_WIDTH] = width
  integrationParamsData[INTEG_WORLD_HEIGHT] = height
  integrationParamsData[INTEG_FRICTION] = friction
  integrationParamsData[INTEG_MAX_VELOCITY] = float32(config.CONFIG.maxVelocity)
  integrationParamsUint[INTEG_PARTICLE_COUNT] = particleCount
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["integrationParams"]), 0, integrationParamsData)

  # Field parameters. feed, kill, deposit, and field force are the live UI
  # knobs, descriptor-clamped in web_api before they reach CONFIG; the diffusion
  # rates and timestep come from field_core (the natively-tested authority)
  # because the shader's stability depends on them and no slider offers them.
  #
  # Unguarded, because the field belongs to the world and evolves at every
  # setting of every strength. A guard here starves a live pass of its
  # parameters whenever chemistry's strengths sit at zero.
  fieldParamsData[FIELD_FEED] = float32(config.CONFIG.rdFeed)
  fieldParamsData[FIELD_KILL] = float32(config.CONFIG.rdKill)
  fieldParamsData[FIELD_DIFFUSION_A] = float32(RD_DIFFUSION_A)
  fieldParamsData[FIELD_DIFFUSION_B] = float32(RD_DIFFUSION_B)
  fieldParamsData[FIELD_DELTA_T] = float32(RD_DELTA_T)
  # field-resolve.wgsl multiplies the deposit by the RD_DEPOSIT_FRAME_SCALE the
  # bundler substituted, which is pinned to the shipped step count. Time Scale
  # moves the live count, so the ratio here restores the product: the deposit
  # rate per FIELD STEP is what every ignition constant was measured against,
  # and holding it fixed is what keeps Time Scale a speed control rather than a
  # second control on what it takes to ignite.
  fieldParamsData[FIELD_DEPOSIT_AMOUNT] = float32(config.CONFIG.rdDeposit *
    depositFrameScale(activeRdSteps) / RD_DEPOSIT_FRAME_SCALE)
  fieldParamsData[FIELD_FORCE_SCALE] =
    float32(frameScaledFieldForce(config.CONFIG.rdFieldForce,
      frameFactor(substepDt)))
  fieldParamsData[FIELD_SEED_NONCE] = float32(fieldSeedNonce)
  queue.writeBufferTyped(cast[GPUBuffer](uniformBuffers["fieldParams"]), 0, fieldParamsData)

  # Per-species chemistry. The CPU array interleaves (secretion, tropism)
  # per species; the uniform holds them as two parallel channels, so this
  # write de-interleaves. Slots past the active speciesCount carry their
  # defaults and are never indexed — no particle holds a species above the
  # count — but they are written anyway so the uniform never contains
  # whatever the buffer was allocated with.
  for speciesIndex in 0 ..< config.MAX_SPECIES:
    let base = speciesIndex * SPECIES_CHEMISTRY_STRIDE
    chemistryData[CHEM_SECRETION_START + speciesIndex] =
      config.SPECIES_CHEMISTRY[base + SPECIES_SECRETION_SLOT]
    chemistryData[CHEM_TROPISM_START + speciesIndex] =
      config.SPECIES_CHEMISTRY[base + SPECIES_TROPISM_SLOT]
  queue.writeBufferTyped(
    cast[GPUBuffer](uniformBuffers["speciesChemistry"]), 0, chemistryData)

  # The bodies' two per-frame uploads, both unguarded by the strength. acts() is
  # the only place a strength is compared to anything, and the envelope is 128
  # bytes — cheaper than a second site that could disagree with it.
  #
  # count is every slot, not the live ones: presence is what a slot says it is,
  # and a free slot says zero, so the walk needs no second census to skip it.
  bodyParamsUint[BODY_COUNT] = uint32(MAX_BODIES)
  bodyParamsData[BODY_STRENGTH] = float32(config.CONFIG.bodiesStrength)
  bodyParamsData[BODY_WORLD_W] = width
  bodyParamsData[BODY_WORLD_H] = height
  # Both clocks: seconds is what a body travels over, frames is what its damping
  # and its change caps were measured in.
  bodyParamsData[BODY_DT_SECONDS] = substepDt
  bodyParamsData[BODY_FRAMES] = float32(frameFactor(substepDt))
  # The accumulator's scales arrive inverted, so the integrate multiplies where
  # body_core.decoded divides.
  bodyParamsData[BODY_FORCE_SCALE] = float32(1.0 / body_core.BODY_FIXED_POINT_SCALE)
  bodyParamsData[BODY_TORQUE_SCALE] =
    float32(1.0 / body_core.BODY_TORQUE_FIXED_SCALE)
  bodyParamsData[BODY_LINEAR_DAMPING] = float32(body_core.BODY_LINEAR_DAMPING)
  bodyParamsData[BODY_ANGULAR_DAMPING] = float32(body_core.BODY_ANGULAR_DAMPING)
  bodyParamsData[BODY_MAX_SPEED_CHANGE] =
    float32(body_core.BODY_MAX_SPEED_CHANGE)
  bodyParamsData[BODY_MAX_SPIN_CHANGE] = float32(body_core.BODY_MAX_SPIN_CHANGE)
  queue.writeBufferTyped(
    cast[GPUBuffer](uniformBuffers["bodyParams"]), 0, bodyParamsData)

  let presences = body_core.envelopeValues(bodyState, bodySeconds)
  for slot in 0 ..< MAX_BODIES:
    bodyEnvelopeData[slot] = presences[slot]
  queue.writeBufferTyped(
    cast[GPUBuffer](gpuBuffers.bodyEnvelope), 0, bodyEnvelopeData)

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
    of sbVelocityDelta: cast[GPUBuffer](gpuBuffers.velocityDelta)
    of sbDensityDelta: cast[GPUBuffer](gpuBuffers.densityDelta)
    of sbSphDensityDelta: cast[GPUBuffer](gpuBuffers.sphDensityDelta)
    of sbCrowdDensityDelta: cast[GPUBuffer](gpuBuffers.crowdDensityDelta)
    of sbFieldAlive: cast[GPUBuffer](gpuBuffers.fieldAlive)
    of sbFieldDeposit: webgpu_init.fieldDepositGpuBuffer()
    of sbBodies: cast[GPUBuffer](gpuBuffers.bodies)
    of sbBodyEnvelope: cast[GPUBuffer](gpuBuffers.bodyEnvelope)
    of sbBodyAccum: cast[GPUBuffer](gpuBuffers.bodyAccum)

  proc byteLengthFor(simBuffer: SimBuffer): int =
    case simBuffer
    of sbGridCounts, sbGridOffsets, sbFillPointers: numCells * 4
    of sbVelocityDelta: particleCount * 8
      # TWO i32 per particle — x and y. Clearing only particleCount * 4 would
      # zero every x and leave every y holding the previous frame's impulse,
      # which reads as a world that drifts steadily downward.
    of sbDensityDelta, sbSphDensityDelta, sbCrowdDensityDelta:
      particleCount * 4  # i32 per particle
    of sbFieldAlive: 4  # one u32: the frame's alive-cell census
    of sbFieldDeposit: FIELD_W * FIELD_H * 4  # one i32 (inhibitor) per field cell
    of sbBodies: MAX_BODIES * BodyLayout.totalSize
    of sbBodyEnvelope: MAX_BODIES * 4
    of sbBodyAccum: MAX_BODIES * 3 * 4
      # Three i32 per body — force x, force y, torque. The whole table is
      # cleared whatever the live body count is: a slot that frees mid-frame
      # would otherwise carry its last impulse into whatever ignites next.

  # The 2D field dispatch (dsFieldWorkgroups) covers FIELD_W x FIELD_H in
  # fieldStepX x fieldStepY tiles. Every other DispatchSize is 1D; this one is
  # dispatched via the (x, y) overload in the walk below.
  let fieldStepX = shader_config.getWorkgroupSize("field-step-x")
  let fieldStepY = shader_config.getWorkgroupSize("field-step-y")
  let fieldGroupsX = jsCeil(FIELD_W.float / fieldStepX.float)
  let fieldGroupsY = jsCeil(FIELD_H.float / fieldStepY.float)

  proc resolveDispatchSize(size: DispatchSize): int =
    case size
    of dsParticleWorkgroups: particleWorkgroups
    of dsScanBlocks: scanBlocks
    of dsOne: 1
    of dsFieldWorkgroups:
      # Resolved inline as a 2D dispatch in the walk below, never through this
      # 1D path — see the dsFieldWorkgroups branch of the dispatch loop.
      raise newException(CatchableError, "dsFieldWorkgroups is dispatched 2D, not via resolveDispatchSize")

  let commandEncoder = device.createCommandEncoderLabeled("Physics Frame Command Encoder")

  # One-shot field seed, ahead of everything else this frame. Encoded here
  # rather than at the request site because both prerequisites are only
  # guaranteed at this point: createBindGroups has run, and the fieldParams
  # uniform carrying the nonce has been written. Deliberately NOT counted as a
  # profiler pass and deliberately NOT bumping fieldGeneration — the textures
  # are not recreated, and bumping would rebuild the render and tonemap bind
  # groups for nothing.
  if pendingFieldSeed:
    pendingFieldSeed = false
    let seedPassDesc = createJsObject()
    seedPassDesc["label"] = "Field Seed Compute Pass".cstring.toJs
    let seedPass = commandEncoder.beginComputePass(seedPassDesc)
    seedPass.setPipeline(cast[GPUComputePipeline](pipelines["fieldSeed".cstring]))
    seedPass.setBindGroup(0, cast[GPUBindGroup](bindGroups["fieldSeed".cstring]))
    seedPass.dispatchWorkgroups(fieldGroupsX, fieldGroupsY)
    seedPass.endPass()

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
      if node.cadence == fncOncePerFrame and substep > 0:
        continue
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
        if attachProfiling and node.profilerSlot != PROFILER_SLOT_NONE:
          gpu_profiler.attachTimestamps(passDesc, node.profilerSlot)
        let computePass = commandEncoder.beginComputePass(passDesc)
        for dispatchStep in node.dispatches:
          computePass.setPipeline(cast[GPUComputePipeline](pipelines[dispatchStep.pipelineKey.cstring]))
          computePass.setBindGroup(0, cast[GPUBindGroup](bindGroups[dispatchStep.pipelineKey.cstring]))
          if dispatchStep.size == dsFieldWorkgroups:
            # The one 2D dispatch: one workgroup per fieldStepX x fieldStepY tile.
            computePass.dispatchWorkgroups(fieldGroupsX, fieldGroupsY)
          else:
            computePass.dispatchWorkgroups(resolveDispatchSize(dispatchStep.size))
        computePass.endPass()

  # Census readback: 4 bytes, mapped only when the previous map finished, so
  # a slow readback thins the sampling instead of queueing work.
  let sampleFieldAlive = not fieldAliveReadbackBusy
  if sampleFieldAlive:
    commandEncoder.copyBufferToBuffer(
      cast[GPUBuffer](gpuBuffers.fieldAlive), 0,
      cast[GPUBuffer](gpuBuffers.fieldAliveReadback), 0, 4)

  let commandBuffer = commandEncoder.finish()
  let commandBufferArray = createJsArray()
  discard commandBufferArray.push(cast[JsObject](commandBuffer))
  queue.submit(commandBufferArray)

  if sampleFieldAlive:
    fieldAliveReadbackBusy = true
    discard readFieldAlive()

proc uploadParticleRange*(startIndex, endIndex: int) =
  ## Upload particles [startIndex, endIndex) from the CPU staging buffer into
  ## the GPU buffer, leaving every particle below startIndex untouched.
  ##
  ## Particles live on the GPU and are never read back, so cpuBuffers.particlesA
  ## is stale for anything the simulation has moved. Uploading the whole array to
  ## append particles would snap every living one back to its startup position;
  ## writing only the tail lets the population grow without the world restarting.
  if device.isNil or queue.isNil or endIndex <= startIndex:
    return
  let count = endIndex - startIndex
  let particleData = newFloat32Array(count * 8)
  let particleDataUint = newUint32Array(particleData.buffer)
  for offsetIndex in 0 ..< count:
    let sourceBase = (startIndex + offsetIndex) * 8
    let destBase = offsetIndex * 8
    particleData[destBase + 0] = cpuBuffers.particlesA[sourceBase + 0]
    particleData[destBase + 1] = cpuBuffers.particlesA[sourceBase + 1]
    particleData[destBase + 2] = cpuBuffers.particlesA[sourceBase + 2]
    particleData[destBase + 3] = cpuBuffers.particlesA[sourceBase + 3]
    particleDataUint[destBase + 4] = uint32(cpuBuffers.particlesA[sourceBase + 4])
    particleData[destBase + 5] = cpuBuffers.particlesA[sourceBase + 5]
    particleDataUint[destBase + 6] = 0
    particleDataUint[destBase + 7] = 0
  queue.writeBufferTyped(
    cast[GPUBuffer](gpuBuffers.particlesA), startIndex * 32, particleData)

proc uploadInitialData*(particleCount: int): Future[JsObject] {.async, exportc.} =
  ## Reads from CPU buffers and packs into 32-byte Particle structs.
  if device.isNil or queue.isNil:
    consoleError("Cannot upload initial data: WebGPU device not initialized".toJs)
    let resultObj = createJsObject()
    resultObj["success"] = false.toJs
    resultObj["error"] = "Device not initialized".cstring.toJs
    return resultObj

  try:
    # Each particle: 8 floats (32 bytes) = pos.x, pos.y, vel.x, vel.y, species(as f32), density, pad, pad
    let particleData = newFloat32Array(particleCount * 8)
    let particleDataUint = newUint32Array(particleData.buffer)

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

    let bytesTotal = particleCount * 32
    queue.writeBufferTyped(cast[GPUBuffer](gpuBuffers.particlesA), 0, particleData)

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
