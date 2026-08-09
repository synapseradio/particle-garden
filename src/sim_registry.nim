# ==============================================================================
# PARTICLE GARDEN - SIMULATION PASS REGISTRY (Pure)
# ==============================================================================
#
# The frame as data: a pure, natively-tested description of the GPU work one
# physics frame performs. webgpu_compute.nim builds the frame once (at init and
# whenever a strength crosses zero, never per frame) and walks it each frame,
# resolving symbolic dispatch sizes against the live particle count and grid
# dimensions.
#
# A new coupling adds a strength and one guarded dispatch here instead of
# forking the executor: its pass becomes data, its pipeline pre-warms at init
# with every other, and its composition with the couplings that already exist is
# pinned by tests/test_sim_registry.nim rather than written out per combination.
# docs/one-world.md walks that addition end to end.
#
# Pure module: no FFI, no imports from GPU-facing code. Compiles on both the
# native (just test) and JS backends.
#
# ==============================================================================

# field_core is itself pure (no FFI), so importing it for RD_STEPS_PER_FRAME
# keeps this module's own purity guarantee intact.
import field_core

# ==============================================================================
# SECTION 1: COUPLING STRENGTHS
# ==============================================================================
#
# There is one world. Species forces, fluid pressure, and chemistry are things
# that world does at once and in any proportion, so each arrives as a continuous
# strength rather than a switch, and zero is an ordinary value of that strength
# rather than a state of the world. A world with no fluid is a world whose fluid
# strength is zero, reached by moving a slider, indistinguishable in kind from a
# world with a little fluid.
#
# THE FRAME ASKS EXACTLY ONE QUESTION OF A STRENGTH: is it zero. Nothing here
# reads a magnitude, compares against a threshold, or branches on a combination.
# A pass whose strength is exactly zero provably contributes nothing, so the
# frame may leave it out; that skip is derived from a number the user set and is
# invisible above the executor.
#
# WHICH PASSES A STRENGTH MAY SKIP, AND WHY THE ANSWER IS NOT "ITS OWN".
# A strength may skip a pass only when it multiplies EVERYTHING that pass
# produces. Where a pass also produces something no strength scales, skipping it
# would remove an output the strength never owned and the world would jump at
# zero — which is the mode returning as a floating-point comparison. So passes
# divide in two:
#
#   World-intrinsic, never skipped. The spatial hash, the neighbour sweep in
#   forces.wgsl (which measures density and carries the mouse and the blast as
#   well as applying the species force), the field's own Gray-Scott evolution,
#   and integrate. These are what the world IS.
#
#   Coupling-owned, skipped at exactly zero. forces-sph's velocity contribution,
#   the deposit, and field-force. Each is multiplied by its strength across its
#   entire output.
#
# Forces are the asymmetric case and the reason this split exists: the
# force TERM is coupling-owned and `forces` scales it inside the shader, but its
# pass measures density and applies user input too, so no force strength may
# skip it. The neighbour sweep therefore runs in a world where no forces act.
# That is the honest price of one world, paid in the frame rather than in a
# discontinuity.

type
  WorldCouplings* = object
    ## How strongly this world couples each contribution. Every member is a
    ## live simulation parameter, not a copy of one: the panel writes these
    ## through the same descriptor path as any other slider.
    forces*: float
      ## Species attraction and repulsion (forces.wgsl's force term). Scales
      ## the term inside a pass that runs regardless — see above.
    fluid*: float
      ## Smoothed-particle pressure and viscosity (forces-sph.wgsl), scaling
      ## its whole per-pair velocity contribution.
    deposit*: float
      ## How much a particle secretes into the chemical field
      ## (field-deposit.wgsl).
    fieldForce*: float
      ## How hard the field's gradient steers particles (field-force.wgsl).

func acts(strength: float): bool =
  ## Whether a coupling contributes at all. The one place the frame compares a
  ## strength to anything, so a threshold cannot be introduced anywhere else
  ## without deleting this function first.
  strength != 0.0

type
  SimBuffer* = enum
    ## GPU buffers a frame node may clear or copy. The executor maps each to
    ## the live GPUBuffer and its per-frame byte length (the first four are
    ## sized by grid cell count; sbFieldDeposit is sized by field cell count).
    sbGridCounts
    sbGridOffsets
    sbFillPointers
    sbVelocityDelta
      ## The per-particle velocity accumulator, TWO i32 per particle (x and y).
      ## Every contributor — forces, forcesSph, fieldForce — accumulates into
      ## it atomically, and the frame clears it once at the top. That split is
      ## what lets two contributors run in the same frame: if each pass
      ## self-reset the buffer, whichever ran second would erase the first.
    sbDensityDelta
    sbSphDensityDelta
      ## The fluid's own kernel-density accumulator, one i32 per particle.
      ## Separate from sbDensityDelta because the two carry different
      ## quantities: this one feeds the Tait equation of state, that one feeds
      ## the renderer. Sharing a buffer makes the glow track the fluid strength.
    sbCrowdDensityDelta
      ## The species-blind crowd-density accumulator, one i32 per particle.
      ## Separate from sbDensityDelta for the same reason again: the crowding
      ## cap has to count every neighbour the spatial hash counts, while the
      ## renderer wants same-species neighbours only. One buffer serving both
      ## would make dot size track species mixing.
    sbFieldDeposit
      ## The reaction-diffusion fixed-point splat buffer: one i32 per FIELD_W x
      ## FIELD_H cell. fieldDeposit accumulates each particle's inhibitor
      ## contribution into it and fieldResolve reads it to update the field
      ## texture. The frame never clears it, because fieldResolve zeroes each
      ## cell as it consumes it — which is also what makes skipping the deposit
      ## at zero strength exact rather than merely cheap: the buffer a skipped
      ## deposit leaves behind is already zero.
    sbFieldAlive
      ## One-word alive-cell census fieldResolve accumulates. Cleared per
      ## frame description, so under substepping the value at frame end is
      ## the last substep's census, never a sum.

  DispatchSize* = enum
    ## Symbolic dispatch sizes, resolved by the executor each frame. The
    ## description itself stays immutable: particle count and grid size
    ## changes never rebuild it.
    dsParticleWorkgroups  ## ceil(particleCount / workgroup size)
    dsScanBlocks          ## ceil(numCells / prefix-sum block size)
    dsOne                 ## a single workgroup
    dsFieldWorkgroups
      ## ceil(FIELD_W / workgroup size X) x ceil(FIELD_H / workgroup size Y):
      ## the one 2D dispatch size in this enum. Every other DispatchSize
      ## resolves to a single workgroup count; the executor special-cases
      ## this value with a dispatchWorkgroups(x, y) call
      ## (webgpu_compute.nim's frame walk) rather than resolving it through
      ## the same one-int path as the others.

  Dispatch* = object
    ## One setPipeline/setBindGroup/dispatchWorkgroups triple. pipelineKey
    ## indexes webgpu_compute's pipelines/bindGroups dictionaries.
    pipelineKey*: string
    size*: DispatchSize

  FrameNodeKind* = enum
    fnkClearBuffer
    fnkCopyBuffer
    fnkComputePass

  FrameNode* = object
    ## One step of a frame: an encoder-level buffer operation or a compute
    ## pass grouping dispatches under a label and a profiler slot.
    case kind*: FrameNodeKind
    of fnkClearBuffer:
      clearTarget*: SimBuffer
    of fnkCopyBuffer:
      copySource*: SimBuffer
      copyDest*: SimBuffer
    of fnkComputePass:
      label*: string
      profilerSlot*: int
      dispatches*: seq[Dispatch]

  FrameDescription* = seq[FrameNode]

const
  PROFILER_SLOT_GRID_BUILD* = 0
    ## Mirrors gpu_profiler.passGridBuild (that module is JS-only, so the
    ## value is duplicated here; both sides document the pairing).
    ## TODO(2026-07-29T19:17:40Z): no test pins the pairing — gpu_profiler cannot
    ## compile natively, so an equality check needs the pass constants
    ## extracted to a pure module first.
  PROFILER_SLOT_PHYSICS* = 1
    ## Mirrors gpu_profiler.passPhysics.
  PROFILER_SLOT_FIELD* = 5
    ## Mirrors gpu_profiler.passField — the Gray-Scott field pass. Distinct
    ## from PROFILER_SLOT_GRID_BUILD because both passes run every frame, so
    ## one slot could only report their sum.
  PROFILER_SLOT_INTEGRATE* = 6
    ## Mirrors gpu_profiler.passIntegrate. integrate sits outside the physics
    ## pass because it must run after the field passes and the field passes
    ## must run after forces — three orderings that no single pass can hold.
    ## app.nim adds this slot into the reported physics time, so the number the
    ## stats show covers forces and integrate together.

func clearBufferNode*(target: SimBuffer): FrameNode =
  FrameNode(kind: fnkClearBuffer, clearTarget: target)

func copyBufferNode*(source, dest: SimBuffer): FrameNode =
  FrameNode(kind: fnkCopyBuffer, copySource: source, copyDest: dest)

func computePassNode*(label: string, profilerSlot: int,
    dispatches: seq[Dispatch]): FrameNode =
  FrameNode(kind: fnkComputePass, label: label, profilerSlot: profilerSlot,
    dispatches: dispatches)

func dispatch*(pipelineKey: string, size: DispatchSize): Dispatch =
  Dispatch(pipelineKey: pipelineKey, size: size)

func buildFrame*(couplings: WorldCouplings): FrameDescription =
  ## The full GPU frame this world runs: everything world-intrinsic, plus each
  ## coupling whose strength is not zero.
  ##
  ## READ THIS AS A UNION, NEVER AS A TABLE OF WORLDS. The intrinsic sequence is
  ## always present and always in this order; each `acts(...)` guard inserts one
  ## coupling's pass into it. No combination is named anywhere, and stripping the
  ## coupling-owned passes from any frame leaves exactly the intrinsic sequence —
  ## which tests/test_sim_registry.nim asserts as a derivation rather than as a
  ## list, so a fifth coupling cannot reintroduce enumeration by accident.
  ##
  ## THE FRAME OWNS THE DELTA RESETS. Every accumulation buffer is cleared here,
  ## once, before anything writes it; every contributing pass accumulates only.
  ## This is what lets forces and fieldForce both run in one frame — if each
  ## pass self-reset velocityDelta in its own prologue, whichever ran second
  ## would erase the first's contribution entirely.
  ##
  ## The clears are encoder-level operations interleaved into the same ordered
  ## command stream as the compute passes, so a clear that precedes a dispatch
  ## is ordered before it, not racing it. clearBufferNode(sbGridCounts) works
  ## this way ahead of bin-count's atomic increments.
  ##
  ## Substepping (running the whole frame N times per rendered frame for
  ## stability at high stiffness) is an EXECUTOR loop, not frame nodes: the
  ## executor encodes this description N times in one command encoder. The
  ## description stays one substep's worth of work.

  # Every delta buffer, every frame. Clearing a buffer no pass writes this frame
  # costs one encoder operation and removes a whole class of question about what
  # the previous frame left behind.
  result = @[
    clearBufferNode(sbVelocityDelta),
    clearBufferNode(sbDensityDelta),
    clearBufferNode(sbSphDensityDelta),
    clearBufferNode(sbCrowdDensityDelta),
    clearBufferNode(sbFieldAlive),
    # gridCounts must start at zero for bin-count's atomic increments.
    clearBufferNode(sbGridCounts),
  ]

  result.add computePassNode("Grid Build", PROFILER_SLOT_GRID_BUILD, @[
    dispatch("binCount", dsParticleWorkgroups),
    dispatch("prefixLocal", dsScanBlocks),
    dispatch("prefixBlocks", dsOne),
    dispatch("prefixFinal", dsScanBlocks),
  ])
  # bin-scatter consumes fillPointers as its running write cursors, which must
  # start at each cell's exclusive-scan offset.
  result.add copyBufferNode(sbGridOffsets, sbFillPointers)

  # forces.wgsl is world-intrinsic and unguarded: it measures each particle's
  # local density and applies the mouse and the blast, none of which any
  # strength scales. `couplings.forces` reaches it as a uniform and scales the
  # species force inside, which is how that term reaches zero continuously
  # without the frame changing shape.
  var forceDispatches = @[
    dispatch("binScatter", dsParticleWorkgroups),
    dispatch("forces", dsParticleWorkgroups),
  ]
  if acts(couplings.fluid):
    forceDispatches.add dispatch("forcesSph", dsParticleWorkgroups)
  result.add computePassNode("Physics", PROFILER_SLOT_PHYSICS, forceDispatches)

  # The field belongs to the world, not to a coupling: it evolves whether or not
  # particles write to it or read from it. A field frozen mid-pattern at zero
  # deposit and breathing again one epsilon above it would be a mode, and a
  # visible one. What chemistry's strengths own is the two couplings BETWEEN
  # particles and field — the deposit going in, the gradient force coming out.
  var fieldDispatches: seq[Dispatch]
  if acts(couplings.deposit):
    fieldDispatches.add dispatch("fieldDeposit", dsParticleWorkgroups)
  fieldDispatches.add dispatch("fieldResolve", dsFieldWorkgroups)

  # RD_STEPS_PER_FRAME Gray-Scott substeps, alternating which of the two
  # field-texture copies is read from vs. written to each substep (the ping-pong
  # pattern a storage texture needs since a shader cannot read and write the
  # same texture binding in one dispatch).
  #
  # THE CHAIN MUST CLOSE. fieldResolve above is itself a ping-pong stage — it
  # reads the front texture and writes the trailing one — so the frame performs
  # 1 + RD_STEPS_PER_FRAME swaps in total. The substeps therefore start on the
  # texture resolve just wrote (the trail, hence ToFront first) and must end back
  # on the front, which is what the renderer, fieldForce, and the next frame's
  # resolve all read. That closure is why field_core statically asserts
  # RD_STEPS_PER_FRAME is odd: an even count leaves the live field on the
  # trailing texture where nothing looks for it, silently discarding the last
  # substep every single frame.
  #
  # Both stages are unguarded, and the parity argument is why that matters
  # beyond the field being intrinsic: skipping fieldResolve at zero deposit
  # would remove one swap and land the live field on the wrong texture.
  for stepIndex in 0 ..< RD_STEPS_PER_FRAME:
    if stepIndex mod 2 == 0:
      fieldDispatches.add dispatch("rdStepToFront", dsFieldWorkgroups)
    else:
      fieldDispatches.add dispatch("rdStepToTrail", dsFieldWorkgroups)

  if acts(couplings.fieldForce):
    fieldDispatches.add dispatch("fieldForce", dsParticleWorkgroups)
  result.add computePassNode(
    "Field (RD)", PROFILER_SLOT_FIELD, fieldDispatches)

  # integrate always closes the frame: it is the one pass that reads the
  # summed deltas and moves particles, so every contributor must already have
  # run. It sits in its own pass because the field passes have to come between
  # it and the force pass, and one compute pass cannot be in two places.
  result.add computePassNode("Integrate", PROFILER_SLOT_INTEGRATE, @[
    dispatch("integrate", dsParticleWorkgroups),
  ])
