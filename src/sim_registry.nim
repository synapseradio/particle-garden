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

# field_core and balance_core are themselves pure (no FFI), so importing them
# keeps this module's own purity guarantee intact. profiler_slots is
# re-exported: webgpu_compute and the tests read the PROFILER_SLOT_*
# constants through sim_registry, as they did when they were declared here.
import field_core
import balance_core
import profiler_slots
export profiler_slots

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
#   the deposit, field-force, and the long-range mesh's whole chain. Each is
#   multiplied by its strength across its entire output — for the chain, that
#   output is the one velocity delta its last pass writes, which is what lets a
#   single strength skip six passes ahead of it.
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
    bodies*: float
      ## How much of what a body says lands (body-force.wgsl and
      ## body-integrate.wgsl), scaling the forces particles receive and the
      ## reaction bodies receive together, so action and reaction cannot be
      ## scaled apart.
    longRange*: float
      ## How hard the long-range mesh pulls (lr-force.wgsl). It scales the
      ## whole chain's only output — the velocity delta the force pass
      ## accumulates — so at zero the solve feeding it is skipped too.

func sameFrameShape*(lhs, rhs: WorldCouplings): bool =
  ## Whether two coupling vectors compose the same frame. Only the zeros decide
  ## that, which is why this compares them rather than the strengths: a slider
  ## moving from 0.4 to 0.5 must not rebuild anything, and the two settings are
  ## the same world as far as the executor is concerned.
  ##
  ## It sits beside buildFrame because it answers a question about buildFrame:
  ## a strength missing from this comparison leaves the executor running the
  ## frame a previous world composed.
  (lhs.forces == 0.0) == (rhs.forces == 0.0) and
    (lhs.fluid == 0.0) == (rhs.fluid == 0.0) and
    (lhs.deposit == 0.0) == (rhs.deposit == 0.0) and
    (lhs.fieldForce == 0.0) == (rhs.fieldForce == 0.0) and
    (lhs.bodies == 0.0) == (rhs.bodies == 0.0) and
    (lhs.longRange == 0.0) == (rhs.longRange == 0.0)

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
      ## Every contributor — forces, forcesSph, fieldForce, lrForce —
      ## accumulates into it atomically, and the frame clears it once at the
      ## top. That split is
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
    sbBodies
      ## The body table: MAX_BODIES records of pose and shaping. Nim writes a
      ## slot once at ignition and bodyIntegrate writes pose thereafter, so the
      ## frame never clears it — a cleared body is a body at the origin with no
      ## mass.
    sbBodyEnvelope
      ## One f32 of presence per slot, rewritten by Nim every frame. Separate
      ## from the record because the writers differ in cadence: this one is
      ## CPU-written per frame while the record beside it is GPU-written, and a
      ## strided per-frame write into the record would race the integrate.
    sbBodyAccum
      ## Three atomic i32 per body — force in two axes and torque — at the body
      ## scales rather than velocityDelta's, since one word here can take a
      ## contribution from every particle in the world in one dispatch. The
      ## frame clears it, because bodyIntegrate reads it without resetting it.
    sbLrDensity
      ## The long-range mesh's charge accumulator, one i32 per species per
      ## cell of the LIVE grid. Its own fixed-point scale, not the velocity
      ## deltas' — long_range_core.LR_DENSITY_SCALE records why. The frame
      ## clears it once per rendered frame, the cadence of the deposit that
      ## fills it and the solve that consumes it.
    sbLrSpectrumA
    sbLrSpectrumB
      ## The two spectra the round trip ping-pongs between, each a complex
      ## pair per species per bin. Two are required rather than convenient:
      ## the kernel pass reads every source species at a bin to write every
      ## receiver at that bin, so its output cannot alias its input, and each
      ## transform stage likewise reads one and writes the other.
    sbLrPotential
      ## The solved potential, one f32 per species per cell, read by the force
      ## pass across every substep of the frame that produced it.

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
    dsLrRowWorkgroups
      ## One workgroup per row of the live mesh, species on z: (gridH, 1,
      ## speciesCount). The transform gives a whole line to one workgroup, so
      ## the count of lines IS the dispatch extent, and a world running four
      ## species pays for four.
    dsLrColWorkgroups
      ## The same, per column: (gridW, 1, speciesCount).
    dsLrBinWorkgroups
      ## One invocation per bin of the live mesh, no species extent:
      ## (ceil(gridW * gridH / workgroup size), 1, 1). Unlike the transforms,
      ## the pass this sizes mixes across species, so one invocation reads
      ## every source species at its bin and writes every receiver from them.

  Dispatch* = object
    ## One setPipeline/setBindGroup/dispatchWorkgroups triple. pipelineKey
    ## indexes webgpu_compute's pipelines/bindGroups dictionaries.
    pipelineKey*: string
    size*: DispatchSize

  FrameNodeKind* = enum
    fnkClearBuffer
    fnkCopyBuffer
    fnkComputePass

  FrameNodeCadence* = enum
    ## How often the executor encodes a node inside one rendered frame.
    fncEverySubstep  ## Once per substep, which is what substepping is for.
    fncOncePerFrame  ## Once per rendered frame, however many substeps run.

  FrameNode* = object
    ## One step of a frame: an encoder-level buffer operation or a compute
    ## pass grouping dispatches under a label and a profiler slot.
    ##
    ## A node is the unit the executor skips, so a node holds exactly one
    ## cadence: work that must run per substep and work that must not cannot
    ## share one.
    cadence*: FrameNodeCadence
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

# The PROFILER_SLOT_* constants live in profiler_slots, imported above: both
# this module and gpu_profiler (JS-only) read the same values, closing the
# pairing a comment alone used to promise.

func resolveOneDimensional*(size: DispatchSize;
    particleWorkgroups, scanBlocks: int): int =
  ## The one-integer dispatch path: a size that names a single workgroup count
  ## resolved against the live counts.
  ##
  ## A size of another dimensionality raises here rather than returning a
  ## number. It would be a number the executor could dispatch — the field's
  ## (x, y) or the mesh's (x, y, z) flattened to x alone — and the GPU would
  ## run it without complaint, leaving the rest of the grid holding the
  ## previous frame's contents. The executor dispatches those sizes from their
  ## own branches of the frame walk.
  case size
  of dsParticleWorkgroups: particleWorkgroups
  of dsScanBlocks: scanBlocks
  of dsOne: 1
  of dsFieldWorkgroups, dsLrRowWorkgroups, dsLrColWorkgroups,
      dsLrBinWorkgroups:
    raise newException(CatchableError,
      $size & " is dispatched multi-dimensionally, not as one workgroup count")

func clearBufferNode*(target: SimBuffer;
    cadence: FrameNodeCadence = fncEverySubstep): FrameNode =
  FrameNode(kind: fnkClearBuffer, clearTarget: target, cadence: cadence)

func copyBufferNode*(source, dest: SimBuffer;
    cadence: FrameNodeCadence = fncEverySubstep): FrameNode =
  FrameNode(kind: fnkCopyBuffer, copySource: source, copyDest: dest,
    cadence: cadence)

func computePassNode*(label: string, profilerSlot: int,
    dispatches: seq[Dispatch];
    cadence: FrameNodeCadence = fncEverySubstep): FrameNode =
  FrameNode(kind: fnkComputePass, label: label, profilerSlot: profilerSlot,
    dispatches: dispatches, cadence: cadence)

func dispatch*(pipelineKey: string, size: DispatchSize): Dispatch =
  Dispatch(pipelineKey: pipelineKey, size: size)

func buildFrame*(couplings: WorldCouplings;
    rdSteps: int = RD_STEPS_PER_FRAME): FrameDescription =
  ## The full GPU frame this world runs: everything world-intrinsic, plus each
  ## coupling whose strength is not zero.
  ##
  ## rdSteps is how many Gray-Scott steps the chemistry runs this frame, which
  ## Time Scale sets through field_core.rdStepsForTimeScale. It must be odd for
  ## the ping-pong chain to close, which that function guarantees.
  ##
  ## READ THIS AS A UNION, NEVER AS A TABLE OF WORLDS. The intrinsic sequence is
  ## always present and always in this order; each `acts(...)` guard inserts one
  ## coupling's pass into it. No combination is named anywhere, and stripping the
  ## coupling-owned passes from any frame leaves exactly the intrinsic sequence —
  ## which tests/test_sim_registry.nim asserts as a derivation rather than as a
  ## list, so a further coupling cannot reintroduce enumeration by accident.
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
    # The census counts the field the chemistry leaves, so it resets on the
    # chemistry's cadence rather than the substep's.
    clearBufferNode(sbFieldAlive, fncOncePerFrame),
    # The bodies' own accumulator. body-integrate reads it without resetting it,
    # so the frame owns this clear exactly as it owns velocityDelta's.
    clearBufferNode(sbBodyAccum),
    # The mesh's charge accumulator clears on the cadence of the pass that
    # fills it: the deposit runs once per rendered frame, so a per-substep
    # clear would empty the grid under a solve that already read it.
    clearBufferNode(sbLrDensity, fncOncePerFrame),
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
  result.add computePassNode("Physics", PROFILER_SLOT_PHYSICS, @[
    dispatch("binScatter", dsParticleWorkgroups),
    dispatch("forces", dsParticleWorkgroups),
  ])

  # The fluid's own node, apart from the sweep: its cost is a coupling's, and
  # a slot shared with the world-intrinsic sweep could only report their sum.
  if acts(couplings.fluid):
    result.add computePassNode("Fluid", PROFILER_SLOT_FLUID, @[
      dispatch("forcesSph", dsParticleWorkgroups),
    ])

  # The mesh solve reads particle positions and nothing else, so it follows
  # Physics; its placement against the field passes is free, and it goes first
  # so the two once-per-frame nodes sit together. Once per frame because the
  # potential it leaves is good for the whole rendered frame: solving it per
  # substep would multiply its cost by sphSubsteps and make Fluid Strength a
  # second, undeclared control over how hard this coupling pulls.
  #
  # The whole chain is guarded by one strength. Nothing outside it reads the
  # density, either spectrum or the potential, so the chain's only output is
  # the velocity delta the force pass writes, and the strength multiplies that
  # output entirely — the same rule a single pass answers to, applied to a
  # chain.
  if acts(couplings.longRange):
    result.add computePassNode("Long Range Solve", PROFILER_SLOT_LONG_RANGE, @[
      dispatch("lrDeposit", dsParticleWorkgroups),
      dispatch("lrFftRows", dsLrRowWorkgroups),
      dispatch("lrFftCols", dsLrColWorkgroups),
      dispatch("lrKernel", dsLrBinWorkgroups),
      dispatch("lrFftColsInv", dsLrColWorkgroups),
      dispatch("lrFftRowsInv", dsLrRowWorkgroups),
    ], fncOncePerFrame)

  # The deposit is a coupling's own writer into the field, and its own node
  # ahead of the field: sharing the field's slot would fold its cost into a
  # pass that runs whether or not anything deposits. fieldResolve consumes
  # this buffer, so the node must precede the field node that holds it.
  if acts(couplings.deposit):
    result.add computePassNode("Deposit", PROFILER_SLOT_DEPOSIT, @[
      dispatch("fieldDeposit", dsParticleWorkgroups),
    ], fncOncePerFrame)

  # The field belongs to the world, not to a coupling: it evolves whether or not
  # particles write to it or read from it. A field frozen mid-pattern at zero
  # deposit and breathing again one epsilon above it would be a mode, and a
  # visible one. What chemistry's strengths own is the two couplings BETWEEN
  # particles and field — the deposit going in, the gradient force coming out.
  var fieldDispatches = @[dispatch("fieldResolve", dsFieldWorkgroups)]

  # rdSteps Gray-Scott substeps, alternating which of the two
  # field-texture copies is read from vs. written to each substep (the ping-pong
  # pattern a storage texture needs since a shader cannot read and write the
  # same texture binding in one dispatch).
  #
  # THE CHAIN MUST CLOSE. fieldResolve above is itself a ping-pong stage — it
  # reads the front texture and writes the trailing one — so the frame performs
  # 1 + rdSteps swaps in total. The substeps therefore start on the
  # texture resolve just wrote (the trail, hence ToFront first) and must end back
  # on the front, which is what the renderer, fieldForce, and the next frame's
  # resolve all read. That closure is why the count must be odd: an even count
  # leaves the live field on the trailing texture where nothing looks for it,
  # silently discarding the last substep every single frame. field_core asserts
  # it of RD_STEPS_PER_FRAME and guarantees it of every count
  # rdStepsForTimeScale returns.
  #
  # Both stages are unguarded, and the parity argument is why that matters
  # beyond the field being intrinsic: skipping fieldResolve at zero deposit
  # would remove one swap and land the live field on the wrong texture.
  for stepIndex in 0 ..< rdSteps:
    if stepIndex mod 2 == 0:
      fieldDispatches.add dispatch("rdStepToFront", dsFieldWorkgroups)
    else:
      fieldDispatches.add dispatch("rdStepToTrail", dsFieldWorkgroups)

  # The chemistry evolves once per rendered frame. The executor encodes this
  # description once per substep, so without the cadence a fluid world ran the
  # pattern forward sphSubsteps times per frame and folded the deposit that many
  # times, which made Fluid Strength a second, undeclared control on how fast the
  # pattern moves.
  result.add computePassNode(
    "Field (RD)", PROFILER_SLOT_FIELD, fieldDispatches, fncOncePerFrame)

  # The field force writes a velocity delta, and every substep clears that buffer
  # and integrates what it holds, so this runs per substep like every other
  # contributor. Its own node because a node carries one cadence; its own
  # dispatch is cheap, and the frame scale webgpu_compute writes into
  # FieldParams already divides a frame's worth of push across the substeps.
  if acts(couplings.fieldForce):
    result.add computePassNode("Field Force", PROFILER_SLOT_SCENT, @[
      dispatch("fieldForce", dsParticleWorkgroups),
    ])

  # The force reads the potential the solve left and accumulates into the
  # velocity delta, which every substep clears and integrates — so it runs per
  # substep, beside the other contributors, while the solve behind it does not.
  # Substeps read that potential without writing it, sound the same way
  # fieldForce reading the field texture across substeps is sound.
  if acts(couplings.longRange):
    result.add computePassNode("Long Range Force", PROFILER_SLOT_LR_FORCE, @[
      dispatch("lrForce", dsParticleWorkgroups),
    ])

  # The bodies read particle positions and write velocityDelta, exactly as the
  # field force does, so where they sit among the contributors is free. Last
  # among them is the useful place: the body's own step then closes on the same
  # substep's forces rather than on the previous one's.
  #
  # THE SKIP AT ZERO IS EXACT, and rests on one premise: bodies are not drawn.
  # A body's motion is observable only through forces this strength scales, so
  # at zero a frozen body and a drifting one are indistinguishable. Drawing a
  # body would make its step world-intrinsic and this guard wrong.
  if acts(couplings.bodies):
    # Two dispatches in ONE node: they share a cadence, and WebGPU orders
    # dispatches inside a compute pass with the memory barriers the grid build's
    # four already rest on, so the integrate reads the sum the force pass just
    # wrote. dsOne covers the whole table, which shader_config's assertion holds
    # the workgroup wide enough for.
    result.add computePassNode("Bodies", PROFILER_SLOT_BODIES, @[
      dispatch("bodyForce", dsParticleWorkgroups),
      dispatch("bodyIntegrate", dsOne),
    ])

  # integrate always closes the frame: it is the one pass that reads the
  # summed deltas and moves particles, so every contributor must already have
  # run. It sits in its own pass because the field passes have to come between
  # it and the force pass, and one compute pass cannot be in two places.
  result.add computePassNode("Integrate", PROFILER_SLOT_INTEGRATE, @[
    dispatch("integrate", dsParticleWorkgroups),
  ])

# ==============================================================================
# SECTION 3: THE COUPLING DECLARATIONS
# ==============================================================================
#
# One declaration per coupling: the strength parameter that gates it, the unit
# function that states its impulse (balance_core.UnitFnId), which passes it
# owns and at what cadence, slot and cost, its dimming predicate, the
# parameters its bounds read, the descriptors it alone shapes, the space each
# of its sizes is measured in, and whether it can raise the crowd density the
# neighbour sweep iterates over.
#
# Declarations as an array indexed by Coupling, not a seq: a coupling added to
# the enum without an entry here fails to compile, rather than passing a
# native suite that could miss it.

type
  Coupling* = enum
    cpSpecies, cpFluid, cpScent, cpDeposit, cpLongRange, cpBodies

  SizeSpace* = enum
    ssWorld, ssFieldCell, ssScreenPx

  CostScaling* = enum
    csPerParticle, csPerFieldCell, csPerMeshCell

  SubstepNeedId* = enum
    ## What a coupling's live values ask of the substep count. Only the
    ## member a declaration below needs exists; group 3 adds substepPlan and
    ## reads this field.
    snNone
    snFluidStiffness

  PassDecl* = object
    pipeline*: string          ## pipeline key, e.g. "forcesSph"
    cadence*: FrameNodeCadence
    slot*: int                 ## a PROFILER_SLOT_* constant
    cost*: CostScaling

  CouplingDecl* = object
    strengthParam*: string     ## descriptor id
    unit*: UnitFnId            ## balance_core enum
    passes*: seq[PassDecl]     ## the gate is acts(strength) over all of them
    dormancy*: string          ## dormancy predicate id (ui/api/dormancy.nim)
    boundsRead*: seq[string]   ## param ids its registered ceilings read
    ownParams*: seq[string]    ## descriptors that shape only this coupling
    sizes*: seq[(string, SizeSpace)]
    raisesCrowd*: bool
    substepNeed*: SubstepNeedId

const COUPLINGS*: array[Coupling, CouplingDecl] = [
  cpSpecies: CouplingDecl(
    strengthParam: "forceStrength",
    unit: ufSpecies,
    # No PassDecl: the species term lives inside forces.wgsl, the
    # world-intrinsic neighbour sweep, and belongs to no declaration.
    dormancy: "forceOff",
    ownParams: @["crowdingStrength", "repulsionEnd", "attractionPeak",
      "expRepulsionAlpha", "expAttractionBeta"],
    sizes: @[("interactionRadius", ssWorld)],
    raisesCrowd: true,
    substepNeed: snNone),
  cpFluid: CouplingDecl(
    strengthParam: "fluidStrength",
    unit: ufFluid,
    passes: @[PassDecl(pipeline: "forcesSph", cadence: fncEverySubstep,
      slot: PROFILER_SLOT_FLUID, cost: csPerParticle)],
    dormancy: "fluidOff",
    # sph_core.stableStiffnessCeiling multiplies by the substep count.
    boundsRead: @["interactionRadius", "sphRadiusFraction", "sphSubsteps",
      "timeScale"],
    ownParams: @["sphRadiusFraction", "sphRestDensity", "sphStiffness",
      "sphViscosity", "sphSubsteps"],
    raisesCrowd: false,
    substepNeed: snFluidStiffness),
  cpScent: CouplingDecl(
    strengthParam: "rdFieldForce",
    unit: ufScent,
    passes: @[PassDecl(pipeline: "fieldForce", cadence: fncEverySubstep,
      slot: PROFILER_SLOT_SCENT, cost: csPerParticle)],
    dormancy: "tropismOff",
    boundsRead: @["rdPatternScale"],
    ownParams: @["tropism"],
    sizes: @[("rdPatternScale", ssFieldCell)],
    raisesCrowd: true,
    substepNeed: snNone),
  cpDeposit: CouplingDecl(
    strengthParam: "rdDeposit",
    unit: ufDeposit,
    passes: @[PassDecl(pipeline: "fieldDeposit", cadence: fncOncePerFrame,
      slot: PROFILER_SLOT_DEPOSIT, cost: csPerParticle)],
    dormancy: "depositOff",
    ownParams: @["secretion"],
    sizes: @[("rdDepositSplatRadius", ssFieldCell)],
    raisesCrowd: false,
    substepNeed: snNone),
  cpLongRange: CouplingDecl(
    strengthParam: "longRangeStrength",
    unit: ufLongRange,
    passes: @[
      PassDecl(pipeline: "lrDeposit", cadence: fncOncePerFrame,
        slot: PROFILER_SLOT_LONG_RANGE, cost: csPerParticle),
      PassDecl(pipeline: "lrFftRows", cadence: fncOncePerFrame,
        slot: PROFILER_SLOT_LONG_RANGE, cost: csPerMeshCell),
      PassDecl(pipeline: "lrFftCols", cadence: fncOncePerFrame,
        slot: PROFILER_SLOT_LONG_RANGE, cost: csPerMeshCell),
      PassDecl(pipeline: "lrKernel", cadence: fncOncePerFrame,
        slot: PROFILER_SLOT_LONG_RANGE, cost: csPerMeshCell),
      PassDecl(pipeline: "lrFftColsInv", cadence: fncOncePerFrame,
        slot: PROFILER_SLOT_LONG_RANGE, cost: csPerMeshCell),
      PassDecl(pipeline: "lrFftRowsInv", cadence: fncOncePerFrame,
        slot: PROFILER_SLOT_LONG_RANGE, cost: csPerMeshCell),
      PassDecl(pipeline: "lrForce", cadence: fncEverySubstep,
        slot: PROFILER_SLOT_LR_FORCE, cost: csPerParticle),
    ],
    dormancy: "longRangeOff",
    boundsRead: @["interactionRadius", "longRangeGridIndex",
      "longRangeReach"],
    ownParams: @["longRangeReach", "longRangeGridIndex"],
    sizes: @[("longRangeReach", ssWorld)],
    raisesCrowd: true,
    substepNeed: snNone),
  cpBodies: CouplingDecl(
    strengthParam: "bodiesStrength",
    unit: ufBodies,
    passes: @[
      PassDecl(pipeline: "bodyForce", cadence: fncEverySubstep,
        slot: PROFILER_SLOT_BODIES, cost: csPerParticle),
      PassDecl(pipeline: "bodyIntegrate", cadence: fncEverySubstep,
        slot: PROFILER_SLOT_BODIES, cost: csPerParticle),
    ],
    dormancy: "bodiesOff",
    # bodyIgnitionRate is excluded from ownParams: a body keeps igniting at
    # bodiesStrength 0 (docs/help/35-bodies.md), so it is not this
    # coupling's alone to dim.
    ownParams: @["bodyRadius", "bodyBand", "bodyProximity", "bodyEnclosure",
      "bodyLifetime"],
    sizes: @[("bodyBand", ssWorld), ("bodyRadius", ssWorld)],
    raisesCrowd: true,
    substepNeed: snNone),
]

const RENDER_SIZES*: seq[(string, SizeSpace)] = @[
  ("particleSize", ssScreenPx),
  ("glowRadiusScale", ssScreenPx),
]
  ## Screen-pixel lengths that belong to no coupling (design N1): Particle
  ## Size and the glow halo radius.
