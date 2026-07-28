# ==============================================================================
# PARTICLE GARDEN - GPU PASS PROFILER (timestamp-query)
# ==============================================================================
#
# Measures GPU execution time per pass with WebGPU timestamp queries.
# Inactive when the adapter lacks the timestamp-query feature — callers see
# zeroed timings and the stats panel keeps showing placeholders.
#
# Query layout: two timestamps per pass slot (begin at 2p, end at 2p+1).
# Compute and render passes attach their slots via attachTimestamps; the
# frame's final encoder resolves all queries and copies them to a mappable
# buffer; pumpReadback maps that copy asynchronously and folds the deltas
# into an exponential moving average. While a readback is in flight the
# resolve step is skipped (the copy target is mapped), so timings sample
# roughly every other frame rather than every frame — sufficient for a
# smoothed per-pass baseline.

from std/jsffi import JsObject, toJs, `[]`, `[]=`
import std/asyncjs
import bindings/webgpu
import webgpu_init

const
  passGridBuild* = 0
  passPhysics* = 1
  passDraw* = 2
  passPresent* = 3
  passBloom* = 4
    ## One span bucket across the three bloom passes (glow-HDR, blur-H,
    ## blur-V): the begin edge is written by the first pass, the end edge by
    ## the last (attachBeginTimestamp/attachEndTimestamp), so the delta is
    ## the whole bloom chain including any inter-pass gap. Only written when
    ## bloom is enabled.
  passField* = 5
    ## The reaction-diffusion field pass (deposit, resolve, the Gray-Scott
    ## substeps, field force). Its own slot rather than passGridBuild's:
    ## reaction-diffusion dispatches no grid-build passes at all, so reporting
    ## field time under "GPU grid" made the two modes' numbers mean different
    ## things under one label. The honest consequence is that grid time now
    ## reads 0 in reaction-diffusion, which is what it genuinely is.
  numPasses* = 6
  numQueries = numPasses * 2

proc createJsObject(): JsObject {.importjs: "({})".}
proc bigInt64View(buffer: JsObject): JsObject {.importjs: "new BigInt64Array(#)".}
proc timestampNs(view: JsObject, idx: int): float {.importjs: "Number(#[#])".}

var
  active = false
  querySet: GPUQuerySet = nil
  resolveBuffer: GPUBuffer = nil
  readbackBuffer: GPUBuffer = nil
  copyPending = false
  readbackBusy = false
  sampleCount = 0
  passMs: array[numPasses, float]

proc isActive*(): bool =
  active

proc passTimeMs*(pass: int): float =
  ## Smoothed GPU time for a pass slot, in milliseconds.
  passMs[pass]

proc initProfiler*() =
  ## Create the query set and readback buffers. No-op without timestamp-query.
  if not hasTimestampQuery or device.isNil:
    return
  let desc = createJsObject()
  desc["type"] = "timestamp".cstring.toJs
  desc["count"] = numQueries.toJs
  querySet = device.createQuerySet(desc)
  resolveBuffer = device.createBufferLabeled(numQueries * 8,
    bitwiseOr(gpuBufferUsageQueryResolve, gpuBufferUsageCopySrc),
    "Timestamp Resolve Buffer")
  readbackBuffer = device.createBufferLabeled(numQueries * 8,
    bitwiseOr(gpuBufferUsageCopyDst, gpuBufferUsageMapRead),
    "Timestamp Readback Buffer")
  active = true

proc attachTimestamps*(passDesc: JsObject, pass: int) =
  ## Attach timestampWrites for a pass slot to a compute/render pass descriptor.
  if not active:
    return
  let tw = createJsObject()
  tw["querySet"] = querySet.toJs
  tw["beginningOfPassWriteIndex"] = (pass * 2).toJs
  tw["endOfPassWriteIndex"] = (pass * 2 + 1).toJs
  passDesc["timestampWrites"] = tw

proc attachBeginTimestamp*(passDesc: JsObject, pass: int) =
  ## Attach only the beginning-of-pass timestamp write for a pass slot.
  ## Opens a span that a later pass closes with attachEndTimestamp, so one
  ## slot can bucket a chain of passes.
  if not active:
    return
  let tw = createJsObject()
  tw["querySet"] = querySet.toJs
  tw["beginningOfPassWriteIndex"] = (pass * 2).toJs
  passDesc["timestampWrites"] = tw

proc attachEndTimestamp*(passDesc: JsObject, pass: int) =
  ## Attach only the end-of-pass timestamp write for a pass slot — the
  ## closing edge of a span opened by attachBeginTimestamp.
  if not active:
    return
  let tw = createJsObject()
  tw["querySet"] = querySet.toJs
  tw["endOfPassWriteIndex"] = (pass * 2 + 1).toJs
  passDesc["timestampWrites"] = tw

proc encodeResolve*(encoder: GPUCommandEncoder) =
  ## Record resolve + copy of all pass timestamps into the frame's final encoder.
  if not active or readbackBusy or copyPending:
    return
  encoder.resolveQuerySet(querySet, 0, numQueries, resolveBuffer, 0)
  encoder.copyBufferToBuffer(resolveBuffer, 0, readbackBuffer, 0, numQueries * 8)
  copyPending = true

proc readback(): Future[void] {.async.} =
  await readbackBuffer.mapAsyncRead()
  let view = bigInt64View(readbackBuffer.getMappedRange())
  for passIdx in 0 ..< numPasses:
    let deltaMs = (timestampNs(view, passIdx * 2 + 1) - timestampNs(view, passIdx * 2)) / 1e6
    # Negative or zero deltas mean the slot was not written this frame; skip.
    if deltaMs > 0.0:
      passMs[passIdx] =
        if sampleCount == 0: deltaMs
        else: passMs[passIdx] * 0.9 + deltaMs * 0.1
  readbackBuffer.unmap()
  sampleCount = sampleCount + 1
  readbackBusy = false

proc pumpReadback*() =
  ## Start an async readback after submit when a resolve copy was recorded.
  if not active or not copyPending or readbackBusy:
    return
  copyPending = false
  readbackBusy = true
  discard readback()
