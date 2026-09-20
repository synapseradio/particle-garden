# ==============================================================================
# PARAMETRIC BODIES (Pure)
# ==============================================================================
#
# A body is a few numbers whose surface is an analytic signed distance function.
# One evaluation per particle yields the distance to that surface, the direction
# it lies in, and which side the particle is on, and proximity and enclosure both
# fall out of those three facts.
#
# This is a reference oracle, like physics_core and field_core: the arithmetic
# that really runs lives in web/shaders/src/body-force.wgsl (one thread per
# particle) and web/shaders/src/body-integrate.wgsl (one thread per body), where
# no native test can reach it. Change a shader and this mirror in the same diff,
# or the pair drifts — docs/enforcement.md records that the pair is held by
# review alone.
#
# The records here carry `float`. The GPU structs they mirror carry f32 and
# src/gpu_types.nim owns those offsets; keeping the oracle's arithmetic wider
# than the shader's is what makes a failing test an algebra error rather than an
# f32 rounding artifact.
#
# Pure module: no FFI, no imports from GPU-facing code. Compiles on both the
# native (just test) and JS backends.
#
# ==============================================================================

import std/[math, options]
import memory_layout
import physics_core

type
  Body* = object
    ## One body's whole record. Pose is GPU-owned — only body-integrate writes
    ## centre, angle and the two velocities — and the shaping below is written
    ## once at ignition, because a body keeps what it was ignited with while
    ## the sliders move on.
    centerX*, centerY*: float   ## World coordinates, wrapped to the torus.
    velX*, velY*: float
    angle*, angVel*: float
    radius*: float              ## Semi-axis along the body's own x.
    anisotropy*: float          ## Semi-axis along y, as a multiple of radius.
    bandWidth*: float
      ## Proximity's reach either side of the surface, and where enclosure
      ## peaks; enclosure's own reach is twice this.
    proximity*: float           ## Signed: toward the surface.
    enclosure*: float           ## Signed: positive holds in, negative keeps out.
    invMass*, invInertia*: float
      ## Derived from the body's area at ignition and stored inverted, so the
      ## shader divides nothing.

  BodySample* = object
    ## What one evaluation returns. Both force laws read this and nothing else,
    ## which is what holds the pass to one evaluation per body per particle.
    distance*: float
      ## Signed, negative inside. Exact when the two semi-axes are equal and a
      ## lower bound on the true distance otherwise, never an overestimate.
      ## Nothing in this capability reads an absolute distance — the forces read
      ## the sign, the direction and the ordering, all of which the scaling
      ## leaves exact.
    normalX*, normalY*: float   ## Unit, pointing away from the body.

  BodyShaping* = object
    ## What a body is born with. None of these is a descriptor: they are fixed
    ## when a body ignites rather than adjusted while it lives, so they travel
    ## on the ignition call and are clamped there.
    anisotropy*: float     ## One is a circle; above and below are ellipses.
    envelopeSkew*: float   ## Moves weight between the rise and the fall.
    sustain*: float        ## The level decay falls to.

  BodyDisposition* = object
    ## What the world's sliders say at the moment a body is born. A body keeps
    ## these while the sliders move on, which is what makes it an event in the
    ## world rather than a view of the panel.
    radius*: float
    bandWidth*: float
    proximity*: float
    enclosure*: float
    lifetime*: float

  BodySlot* = object
    ## One place in the table. A lifetime of zero means the slot has never held
    ## a body — the one state the clock alone cannot describe.
    ignitedAt*: float
    lifetime*: float
    envelopeSkew*: float
    sustain*: float
    body*: Body

  BodyState* = object
    ## Everything Nim knows about the bodies. Pose is absent on purpose: the
    ## GPU owns it and nothing here reads it back.
    slots*: array[MAX_BODIES, BodySlot]

  BodyDraw* = object
    ## One body the world's sequence yields: where it goes and what shape it is
    ## born with. The dispositions are not here — those are the live sliders',
    ## so a body the world lights and a body a player lights are the same kind
    ## of thing.
    atX*, atY*: float
    shaping*: BodyShaping

  BodyGenerator* = object
    ## The world's own source of bodies: a phase on the wall clock and a seeded
    ## sequence. Both pure, so what the world lights is reproducible and the
    ## cadence is testable without a world to light it in.
    phase*: float       ## Seconds since the last body, from any source.
    sequence*: uint64   ## Advanced once per draw.

  BodyAccumulator* = object
    ## One body's share of sbBodyAccum: force in two axes and torque, in fixed
    ## point at the body's own scales. Every particle in the world may add to
    ## one of these words in one dispatch, which is why the scales are not the
    ## per-particle accumulator's.
    forceX*, forceY*, torque*: int32

const
  ENVELOPE_PROPORTIONS* = (attack: 0.15, hold: 0.25, decay: 0.25,
    release: 0.35)
    ## How an unskewed lifetime divides between the four phases. One duration
    ## reaches the panel and these split it, so lifetime is the sum of the
    ## phases by construction rather than by a user's arithmetic.
  ENVELOPE_SKEW_SPAN* = 0.3
    ## How far a skew of one moves weight from the fall into the rise. At the
    ## extremes the rise runs from a tenth of the lifetime to seven tenths, so
    ## every phase keeps a positive duration — which the assertion below holds
    ## against a retune of either constant.
  BODY_WORLD_W* = 3840.0
  BODY_WORLD_H* = 2160.0
    ## The world a body lives in. Stated here because this module is pure and
    ## cannot import config.nim, which carries FFI pragmas;
    ## tests/test_body_core.nim reads config.nim from source and holds the two
    ## together, the way field_core's world aspect is held.
  BODY_WORLD_HALF_DIAGONAL* =
    0.5 * sqrt(BODY_WORLD_W * BODY_WORLD_W + BODY_WORLD_H * BODY_WORLD_H)
    ## The longest lever arm a minimum-image displacement can present, and so
    ## the bound the torque accumulator's scale is sized against.
  BODY_PARTICLE_SPEED_CEILING* = 100.0
    ## The fastest a particle may travel: config_ranges' MAX_VELOCITY_MAX.
    ## Stated here because this module sits upstream of config_ranges and
    ## cannot import it; tests/test_body_core.nim holds the two equal.
  BODY_LARGEST_SUBSTEP_DT* = 0.05 * 5.0
    ## The longest a substep can be: src/app.nim caps a frame's raw delta at
    ## 0.05 s and multiplies by timeScale, whose ceiling is config_ranges'
    ## TIME_SCALE_MAX; one substep takes the whole of it. tests/test_body_core.nim
    ## holds both factors against their sources.
  BODY_LARGEST_FRAME_FACTOR* =
    BODY_LARGEST_SUBSTEP_DT / physics_core.FRAME_DT_REFERENCE
    ## That substep as a multiple of the reference frame every force constant
    ## here was measured against: the largest `frames` body-integrate
    ## multiplies the decoded reaction, the change caps and the damping by.

  BODY_STRENGTH_CEILING* = 1.0
    ## One is the whole coupling: this multiplies the entire output of both
    ## bodies passes, so a value above one would amplify past the range the
    ## stability sweep covers. Ask for a stronger pull through proximity, whose
    ## ceiling answers.
  BODY_FORCE_CEILING* = 10.0
    ## The largest magnitude proximity or enclosure may carry, as a velocity
    ## impulse per reference frame. Both are signed and their ranges are
    ## symmetric about zero, since each sign is an ordinary value of one
    ## quantity rather than a second parameter.
  BODY_RADIUS_FLOOR* = 40.0
  BODY_RADIUS_CEILING* = 800.0
    ## A body a fifth of the world across at its widest. Above that a body
    ## stops reading as a shape inside the world and starts reading as the
    ## world's own boundary.
  BODY_BAND_CEILING* = 600.0
  BODY_LIFETIME_FLOOR* = 0.5
  BODY_LIFETIME_CEILING* = 60.0
  BODY_IGNITION_RATE_CEILING* = 2.0
    ## Bodies per second the world may ignite unasked. Its floor is zero and
    ## that is the shipped default: a world does not make shapes nobody asked
    ## for until someone asks.
  BODY_ANISOTROPY_FLOOR* = 0.25
  BODY_ANISOTROPY_CEILING* = 4.0
    ## Reciprocal ends, so a body is as elongated one way as the other.
  BODY_SKEW_EXTENT* = 1.0
    ## The envelope skew runs from minus this to plus this. It is the unit the
    ## static assertion below reads: a skew of one moves ENVELOPE_SKEW_SPAN of
    ## the lifetime from the fall into the rise, and both must stay positive.
  BODY_SUSTAIN_FLOOR* = 0.0
  BODY_SUSTAIN_CEILING* = 1.0
    ## Sustain is a level of the envelope, so its range is the envelope's.

  BODY_BAND_FLOOR* =
    BODY_PARTICLE_SPEED_CEILING * BODY_LARGEST_SUBSTEP_DT
    ## DERIVED, not chosen: the distance a particle at the speed cap covers in
    ## the largest substep. A particle crossing an enclosing surface has to land
    ## inside the band on the substep that carries it across, or it skips the
    ## hold's rise; at half this floor it lands at the reach's end, where the
    ## hold is zero, and is let go in one step. At this floor the fastest
    ## particle the world admits still lands on the rise.
    ## Re-derive when the speed ceiling, the frame cap or the time-scale ceiling
    ## moves.

  BODY_MAX_FORCE_PER_PARTICLE* =
    2.0 * BODY_FORCE_CEILING * BODY_STRENGTH_CEILING
    ## The largest velocity impulse one body may hand one particle per
    ## reference frame: proximity and enclosure, each at its ceiling.
    ## tests/test_body_core.nim sweeps bodyForceAt under it.

  BODY_FIXED_POINT_SCALE* = 16.0
    ## The per-body force accumulator's own scale, far coarser than
    ## velocityDelta's 65536. One body's word may receive a contribution from
    ## every particle in the world in a single dispatch, where a particle's word
    ## receives only its own; the static assertion below relates the budget, the
    ## largest contribution the bounds admit, and this scale, and is what fixes
    ## the value here.
  BODY_TORQUE_FIXED_SCALE* = 1.0 / 128.0
    ## The torque word's scale, coarser again because torque carries a lever arm
    ## bounded only by the world's half-diagonal. Below one: 128 torque units to
    ## the accumulator's unit. A body's moment of inertia is of order its mass
    ## times its size squared, so one unit of torque turns it by far less than a
    ## frame can show, and the resolution that matters is the summed crowd's
    ## rather than one particle's.
  BODY_DENSITY* = 0.05
    ## A body's mass per unit of its own bounding area, in the units a particle
    ## impulse carries — a particle is one mass unit, so this says how many
    ## particles a body of unit area weighs. At the default radius a body weighs
    ## of order a thousand particles, so a handful of neighbours barely moves it
    ## and a crowd does. First of the three mechanisms the stability sweep
    ## reaches for, and the only one that is physics rather than a bound.
  BODY_LINEAR_DAMPING* = 0.96
  BODY_ANGULAR_DAMPING* = 0.96
    ## Velocity retained per reference frame, applied as pow(damping, dt) so the
    ## substep count cannot change how fast a body settles. At this retention a
    ## body coasts to a tenth of its speed over about sixty reference frames —
    ## half a second of drift after the crowd that pushed it disperses, which is
    ## what makes a body read as carried rather than as switched off.
  BODY_MAX_SPEED_CHANGE* = 40.0
    ## The most one reference frame of accumulated impulse may change a body's
    ## speed by, in world units per second. With the damping above it fixes the
    ## reachable ceiling at cap * frames * d / (1 - d), between five hundred and
    ## a thousand world units a second depending on the frame length — a body
    ## crossing the world in four to eight seconds at its fastest and never
    ## faster however large the crowd. Third mechanism: it bounds what one
    ## substep may do to one body without bounding what a player may ask for.
  BODY_GENERATOR_SEED* = 0x2545F4914F6CDD1D'u64
    ## Where the world's sequence starts, every run. Fixed rather than sampled
    ## from a clock, so the cadence tests can assert the bodies the world lights
    ## rather than merely that it lit one.
  BODY_MAX_SPIN_CHANGE* = 0.03
    ## The same cap on angular speed, in radians per second. The same geometric
    ## sum puts a body's fastest turn near half a radian a second, a slow tumble
    ## rather than a spin.

static:
  doAssert abs(ENVELOPE_PROPORTIONS.attack + ENVELOPE_PROPORTIONS.hold +
    ENVELOPE_PROPORTIONS.decay + ENVELOPE_PROPORTIONS.release - 1.0) < 1e-9,
    "the envelope proportions must sum to one, or a body's realized lifetime " &
    "stops being the lifetime it was ignited with"
  doAssert ENVELOPE_PROPORTIONS.attack > 0.0 and
    ENVELOPE_PROPORTIONS.hold > 0.0 and ENVELOPE_PROPORTIONS.decay > 0.0 and
    ENVELOPE_PROPORTIONS.release > 0.0
  # The body accumulator cannot overflow its fixed-point range. One body's word
  # may receive a contribution from EVERY particle in the world in a single
  # dispatch, where velocityDelta's word receives only that particle's own, so
  # the two scales are not the same number and this is what fixes theirs.
  # Widening a bodies bound, raising the particle budget, or coarsening a
  # scale all land here rather than wrapping around in the browser — where a
  # wrapped word shows as a body flung across the world, a bug that looks like
  # physics.
  doAssert float(MAX_PARTICLES) * BODY_MAX_FORCE_PER_PARTICLE *
    BODY_FIXED_POINT_SCALE < float(high(int32)),
    "the body force accumulator overflows int32 under a full crowd; widen " &
    "BODY_FIXED_POINT_SCALE's headroom or narrow what the bounds admit"
  # Torque carries a lever arm, bounded by the minimum image and so by the
  # world's half-diagonal, which is why its word needs a scale of its own.
  doAssert float(MAX_PARTICLES) * BODY_MAX_FORCE_PER_PARTICLE *
    BODY_WORLD_HALF_DIAGONAL * BODY_TORQUE_FIXED_SCALE < float(high(int32)),
    "the body torque accumulator overflows int32 under a full crowd at the " &
    "world's half-diagonal"
  doAssert BODY_BAND_FLOOR < BODY_BAND_CEILING
  doAssert BODY_RADIUS_FLOOR < BODY_RADIUS_CEILING
  doAssert BODY_LIFETIME_FLOOR > 0.0 and
    BODY_LIFETIME_FLOOR < BODY_LIFETIME_CEILING,
    "a lifetime of zero is a body that never existed, not a quieter one"
  doAssert BODY_ANISOTROPY_FLOOR > 0.0,
    "a zero semi-axis divides by zero in the evaluation"
  doAssert BODY_SKEW_EXTENT * ENVELOPE_SKEW_SPAN <
    min(ENVELOPE_PROPORTIONS.attack + ENVELOPE_PROPORTIONS.hold,
      ENVELOPE_PROPORTIONS.decay + ENVELOPE_PROPORTIONS.release),
    "a skew at its extent must leave both the rise and the fall a positive " &
    "duration"
  doAssert BODY_SUSTAIN_FLOOR < BODY_SUSTAIN_CEILING

func smoothstepUnit(atFraction: float): float =
  ## The Hermite ease climate_core uses, on an already-normalized fraction:
  ## zero slope at both ends, so a value crossing a phase boundary has no
  ## corner in it either.
  let clamped = clamp(atFraction, 0.0, 1.0)
  clamped * clamped * (3.0 - 2.0 * clamped)

func envelopePhases*(lifetime, skew: float): tuple[
    attack, hold, decay, release: float] =
  ## The four durations this lifetime and this skew divide into. Their sum is
  ## the lifetime at every skew, which is the property slot allocation rests on:
  ## Nim knows when a slot frees the moment the body ignites, however the
  ## envelope is shaped.
  let rise = ENVELOPE_PROPORTIONS.attack + ENVELOPE_PROPORTIONS.hold
  let fall = ENVELOPE_PROPORTIONS.decay + ENVELOPE_PROPORTIONS.release
  let risePart = rise + skew * ENVELOPE_SKEW_SPAN
  let fallPart = 1.0 - risePart
  (attack: lifetime * risePart * ENVELOPE_PROPORTIONS.attack / rise,
   hold: lifetime * risePart * ENVELOPE_PROPORTIONS.hold / rise,
   decay: lifetime * fallPart * ENVELOPE_PROPORTIONS.decay / fall,
   release: lifetime * fallPart * ENVELOPE_PROPORTIONS.release / fall)

func bodyEnvelope*(elapsed, lifetime, skew, sustain: float): float =
  ## A body's presence at `elapsed` seconds after its ignition: zero before it,
  ## zero from its lifetime onward, and continuous everywhere between.
  ##
  ## Zero is an ordinary value of this and no threshold is compared against it
  ## anywhere on the force path — a body contributes what its envelope says,
  ## down to arbitrarily small values.
  if elapsed < 0.0 or elapsed >= lifetime or lifetime <= 0.0:
    return 0.0
  let phases = envelopePhases(lifetime, skew)
  if elapsed < phases.attack:
    return smoothstepUnit(elapsed / phases.attack)
  let decayStart = phases.attack + phases.hold
  if elapsed < decayStart:
    return 1.0
  let releaseStart = decayStart + phases.decay
  if elapsed < releaseStart:
    return 1.0 + (sustain - 1.0) * smoothstepUnit(
      (elapsed - decayStart) / phases.decay)
  sustain * (1.0 - smoothstepUnit((elapsed - releaseStart) / phases.release))

func minimumImage*(delta, size: float): float =
  ## The shortest displacement across a torus of this size. Mirrors
  ## physics_core.wrapDelta, in float and taking the full size rather than both
  ## halves, since a body's reach is not bounded by a grid cell.
  let half = size * 0.5
  if delta > half: delta - size
  elif delta < -half: delta + size
  else: delta

func wrapToTorus*(position, size: float): float =
  ## A position folded back into [0, size). `mod` rather than the single
  ## add-or-subtract integrate.wgsl uses, because a body's step is not bounded
  ## by a speed cap the way a particle's is.
  let wrapped = position mod size
  if wrapped < 0.0: wrapped + size else: wrapped

func sampleBody*(body: Body; atX, atY, worldW, worldH: float): BodySample =
  ## The anisotropic disc, evaluated at a world point.
  ##
  ## Carry the point into body space, divide by the per-axis radii, and scale
  ## the unit circle's distance back out by the SMALLER semi-axis. That divisor
  ## is the Lipschitz correction: it makes the returned value a lower bound on
  ## the true distance rather than an overestimate, and the true distance itself
  ## when the radii are equal.
  let toPointX = minimumImage(atX - body.centerX, worldW)
  let toPointY = minimumImage(atY - body.centerY, worldH)
  let cosA = cos(body.angle)
  let sinA = sin(body.angle)
  # rot(-angle): into the body's own frame.
  let localX = toPointX * cosA + toPointY * sinA
  let localY = -toPointX * sinA + toPointY * cosA
  let semiX = body.radius
  let semiY = body.radius * body.anisotropy
  let unitX = localX / semiX
  let unitY = localY / semiY
  let unitLength = sqrt(unitX * unitX + unitY * unitY)
  let smaller = min(semiX, semiY)
  # The gradient of the unit-circle distance, carried back out: dividing a
  # second time by each semi-axis is what tilts the normal away from the radius
  # on an ellipse.
  var gradientX = unitX / semiX
  var gradientY = unitY / semiY
  let gradientLength = sqrt(gradientX * gradientX + gradientY * gradientY)
  if gradientLength > 0.0:
    gradientX = gradientX / gradientLength
    gradientY = gradientY / gradientLength
  else:
    # Dead centre: no direction is outward. Any unit vector keeps the forces
    # finite, and a particle exactly on a body's centre would otherwise poison
    # the whole accumulator with a NaN.
    gradientX = 1.0
    gradientY = 0.0
  BodySample(
    distance: (unitLength - 1.0) * smaller,
    normalX: gradientX * cosA - gradientY * sinA,
    normalY: gradientX * sinA + gradientY * cosA)

func bodyForceAt*(body: Body; atX, atY, worldW, worldH, envelope,
    strength: float): tuple[x, y: float] =
  ## The velocity impulse this body gives a particle at that point, both forces
  ## out of one evaluation.
  ##
  ## PROXIMITY acts inside a band around the surface and pulls toward it from
  ## either side, easing to zero with zero slope at the band's edge, so a
  ## particle drifting across that edge feels neither a step in the force nor a
  ## corner in it.
  ##
  ## ENCLOSURE is one signed strength read against the distance's sign: positive
  ## acts on what is outside and pushes it in, negative acts on what is inside
  ## and pushes it out, and zero does neither. It rises from zero at the
  ## surface to full at the band's edge and falls back to exactly zero at twice
  ## the band, with zero slope at all three, so past that reach a body hands a
  ## particle nothing. Where the two forces push the same way their eases sum
  ## to at most the larger strength, since smoothstep(x) + smoothstep(1 - x) = 1.
  ##
  ## The band is a divisor, so what keeps this finite is a band range whose
  ## floor is above zero, exactly as the SPH smoothing radius's floor keeps the
  ## kernel normalizations finite.
  let sample = sampleBody(body, atX, atY, worldW, worldH)
  let spanned = abs(sample.distance) / body.bandWidth
  let towardSurface = -float(sgn(sample.distance)) * body.proximity *
    smoothstepUnit(1.0 - spanned)
  let actingSide =
    if sample.distance * float(sgn(body.enclosure)) >= 0.0: 1.0 else: 0.0
  let holding = -body.enclosure * actingSide *
    smoothstepUnit(1.0 - abs(spanned - 1.0))
  let along = (towardSurface + holding) * envelope * strength
  (x: sample.normalX * along, y: sample.normalY * along)

# ==============================================================================
# THE REACTION AND THE RIGID STEP
# ==============================================================================

proc addBodyReaction*(accumulator: var BodyAccumulator; body: Body;
    atX, atY, worldW, worldH, forceX, forceY: float) =
  ## The equal and opposite impulse, and its torque about the body's centre over
  ## the toroidal minimum-image displacement, folded into the body's own
  ## accumulator. The integer add is what body-force.wgsl performs with
  ## atomicAdd, truncation and all.
  ##
  ## Reaction is the negation of action before any damping, so the pass has no
  ## way to give particles a push the body does not feel.
  let leverX = minimumImage(atX - body.centerX, worldW)
  let leverY = minimumImage(atY - body.centerY, worldH)
  accumulator.forceX += int32(-forceX * BODY_FIXED_POINT_SCALE)
  accumulator.forceY += int32(-forceY * BODY_FIXED_POINT_SCALE)
  accumulator.torque += int32(
    -(leverX * forceY - leverY * forceX) * BODY_TORQUE_FIXED_SCALE)

func decoded*(accumulator: BodyAccumulator): tuple[
    forceX, forceY, torque: float] =
  ## The accumulator read back as the quantities it stands for.
  (forceX: accumulator.forceX.float / BODY_FIXED_POINT_SCALE,
   forceY: accumulator.forceY.float / BODY_FIXED_POINT_SCALE,
   torque: accumulator.torque.float / BODY_TORQUE_FIXED_SCALE)

func bodyRigidStep*(body: Body; forceX, forceY, torque, dtSeconds,
    worldW, worldH: float): Body =
  ## Semi-implicit Euler: velocity first, then position from the new velocity.
  ## The accumulated reaction is a velocity impulse per reference frame, so the
  ## reference-frame count multiplies it at the decode, as integrate.wgsl's
  ## frame factor multiplies a particle's. Damping and the change caps run on
  ## the same count; position advances over `dtSeconds` as a particle's does.
  result = body
  let frames = frameFactor(dtSeconds)
  var changeX = forceX * frames * body.invMass
  var changeY = forceY * frames * body.invMass
  let allowance = BODY_MAX_SPEED_CHANGE * frames
  let asked = sqrt(changeX * changeX + changeY * changeY)
  if asked > allowance:
    changeX = changeX * allowance / asked
    changeY = changeY * allowance / asked
  let spinAllowance = BODY_MAX_SPIN_CHANGE * frames
  let changeSpin = clamp(torque * frames * body.invInertia,
    -spinAllowance, spinAllowance)
  result.velX = (body.velX + changeX) * pow(BODY_LINEAR_DAMPING, frames)
  result.velY = (body.velY + changeY) * pow(BODY_LINEAR_DAMPING, frames)
  result.angVel =
    (body.angVel + changeSpin) * pow(BODY_ANGULAR_DAMPING, frames)
  result.centerX = wrapToTorus(body.centerX + result.velX * dtSeconds, worldW)
  result.centerY = wrapToTorus(body.centerY + result.velY * dtSeconds, worldH)
  result.angle = body.angle + result.angVel * dtSeconds

# ==============================================================================
# IGNITION AND SLOTS
# ==============================================================================

func bodyInverseMasses*(radius, anisotropy: float): tuple[
    invMass, invInertia: float] =
  ## Mass from area, so a big body is hard to push and a small one skitters, and
  ## the moment of inertia the ellipse's own m(a^2 + b^2)/4. Stored inverted:
  ## the shader divides nothing.
  let semiX = radius
  let semiY = radius * anisotropy
  let mass = BODY_DENSITY * semiX * semiY
  let inertia = mass * (semiX * semiX + semiY * semiY) * 0.25
  (invMass: 1.0 / mass, invInertia: 1.0 / inertia)

func initBodyState*(): BodyState =
  ## Every slot free. A slot with no lifetime has never held a body, which is
  ## the one state the clock cannot describe.
  BodyState()

func slotIsLive*(slot: BodySlot; nowSeconds: float): bool =
  ## Whether this slot holds a body that has not finished. Computable from the
  ## wall clock alone — Nim never reads a body back from the GPU.
  slot.lifetime > 0.0 and nowSeconds - slot.ignitedAt < slot.lifetime

func liveSlots*(state: BodyState; nowSeconds: float): int =
  for slot in state.slots:
    if slot.slotIsLive(nowSeconds):
      inc result

func freeSlots*(state: BodyState; nowSeconds: float): int =
  MAX_BODIES - state.liveSlots(nowSeconds)

func envelopeValues*(state: BodyState;
    nowSeconds: float): array[MAX_BODIES, float] =
  ## One envelope value per slot, the contiguous array Nim uploads each frame.
  ## A free slot reads exactly zero, so the pass costs a branch rather than an
  ## evaluation there.
  for index, slot in state.slots:
    if slot.slotIsLive(nowSeconds):
      result[index] = bodyEnvelope(nowSeconds - slot.ignitedAt, slot.lifetime,
        slot.envelopeSkew, slot.sustain)

func freeSlotIndex*(state: BodyState; nowSeconds: float): int =
  ## Where the next ignition lands, or -1 when the table is full. The allocation
  ## rule itself, so a caller that needs the index and the ignition that takes it
  ## cannot answer differently.
  for index, slot in state.slots:
    if not slot.slotIsLive(nowSeconds):
      return index
  -1

proc igniteBody*(state: var BodyState; atX, atY: float;
    disposition: BodyDisposition; shaping: BodyShaping;
    nowSeconds: float): bool =
  ## Put a body at a world point, and report whether a slot was found.
  ##
  ## The one entry every source reaches the world through — the panel's
  ## gesture, the boundary method, the world's own generator — so the bounds
  ## this proc applies hold for all of them at once.
  ##
  ## Igniting into an occupied slot is refused rather than overwriting a live
  ## body, and the refusal is the return value.
  ##
  ## The shaping is clamped HERE rather than by the caller, so every source
  ## reaches the same bounds and none of them restates a number. The
  ## disposition is not: it arrives from descriptors already clamped at the
  ## boundary that wrote them.
  let shape = BodyShaping(
    anisotropy: clamp(shaping.anisotropy, BODY_ANISOTROPY_FLOOR,
      BODY_ANISOTROPY_CEILING),
    envelopeSkew: clamp(shaping.envelopeSkew, -BODY_SKEW_EXTENT,
      BODY_SKEW_EXTENT),
    sustain: clamp(shaping.sustain, BODY_SUSTAIN_FLOOR, BODY_SUSTAIN_CEILING))
  let index = state.freeSlotIndex(nowSeconds)
  if index < 0:
    return false
  let masses = bodyInverseMasses(disposition.radius, shape.anisotropy)
  state.slots[index] = BodySlot(
    ignitedAt: nowSeconds,
    lifetime: disposition.lifetime,
    envelopeSkew: shape.envelopeSkew,
    sustain: shape.sustain,
    body: Body(
      centerX: wrapToTorus(atX, BODY_WORLD_W),
      centerY: wrapToTorus(atY, BODY_WORLD_H),
      radius: disposition.radius,
      anisotropy: shape.anisotropy,
      bandWidth: disposition.bandWidth,
      proximity: disposition.proximity,
      enclosure: disposition.enclosure,
      invMass: masses.invMass,
      invInertia: masses.invInertia))
  true

# ==============================================================================
# THE WORLD'S OWN GENERATOR
# ==============================================================================

func initBodyGenerator*(seed: uint64): BodyGenerator =
  BodyGenerator(phase: 0.0, sequence: seed)

func nextUnit(sequence: uint64): tuple[next: uint64; value: float] =
  ## One step of splitmix64, and the [0, 1) value it yields. Chosen for being a
  ## few lines of pure arithmetic with no state beyond the word itself: the
  ## sequence a seed produces is the same on both backends and in the suite.
  let next = sequence + 0x9E3779B97F4A7C15'u64
  var mixed = next
  mixed = (mixed xor (mixed shr 30)) * 0xBF58476D1CE4E5B9'u64
  mixed = (mixed xor (mixed shr 27)) * 0x94D049BB133111EB'u64
  mixed = mixed xor (mixed shr 31)
  # 53 bits is what a float carries exactly, so every value is representable.
  (next: next, value: float(mixed shr 11) / float(1'u64 shl 53))

proc drawIgnition*(generator: var BodyGenerator): BodyDraw =
  ## The next body in the world's sequence, and the moment the cadence starts
  ## counting from again. Every ignition draws — a player's gesture takes the
  ## shaping and keeps its own point — so the world never fires on top of a
  ## body that has just been lit.
  generator.phase = 0.0
  let x = nextUnit(generator.sequence)
  let y = nextUnit(x.next)
  let shape = nextUnit(y.next)
  let skew = nextUnit(shape.next)
  let level = nextUnit(skew.next)
  generator.sequence = level.next
  BodyDraw(
    atX: x.value * BODY_WORLD_W,
    atY: y.value * BODY_WORLD_H,
    shaping: BodyShaping(
      # Geometric between the two bounds, not linear: anisotropy is a ratio, so
      # halving and doubling are the same distance from the circle at one.
      anisotropy: exp(ln(BODY_ANISOTROPY_FLOOR) + shape.value *
        (ln(BODY_ANISOTROPY_CEILING) - ln(BODY_ANISOTROPY_FLOOR))),
      envelopeSkew: (skew.value * 2.0 - 1.0) * BODY_SKEW_EXTENT,
      sustain: BODY_SUSTAIN_FLOOR + level.value *
        (BODY_SUSTAIN_CEILING - BODY_SUSTAIN_FLOOR)))

proc worldIgnition*(generator: var BodyGenerator;
    rate, deltaSeconds: float): Option[BodyDraw] =
  ## Advance the cadence by a wall-clock delta and hand back the body the world
  ## lights, if this is the moment. A rate of zero lights none: the world's own
  ## source is off at the bottom of its range, which is a rate rather than a
  ## mode.
  ##
  ## It reads its rate and the clock, never the bodies strength. A body lit into
  ## a world at zero strength costs a slot and moves nothing, and acts() is the
  ## one place a strength is read against zero.
  if rate <= 0.0:
    return none(BodyDraw)
  generator.phase += deltaSeconds
  if generator.phase < 1.0 / rate:
    return none(BodyDraw)
  some(generator.drawIgnition())
