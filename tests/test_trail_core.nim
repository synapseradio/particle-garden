# Behavioral tests for src/trail_core.nim: the trail's geometric decay and the
# trail-length slider's mapping onto it. Two halves of one effect, and the
# suite reaches both — the per-frame decay is what web/shaders/src/fade.wgsl
# runs, and the mapping is what src/webgpu_render.nim writes into the fade
# uniform, from this module.
#
# What a response probe reads: `persistenceFrames` is the observable the trail
# slider is measured through: the frames a trail takes to decay to 1/e of its
# brightness. Frames are what a viewer sees the trail last for, and
# fadeAmount is not — the fade multiplier crowds into the top of its own range
# while the trail it produces keeps growing.

import std/[unittest, math]
import ../src/trail_core
import ../src/config_ranges
import ../src/ui/state/render_state

const TRAIL_CORE_TESTS_LOADED* = true

const
  EPSILON = 1e-12
  FRAME_TOLERANCE = 1e-9
    ## Slack in frames on the closed-form persistence, which the module derives
    ## from a logarithm rather than by iterating.
  SWEEP_STEPS = 64

func sweptLength(step: int): float =
  TRAIL_LENGTH_MIN +
    (TRAIL_LENGTH_MAX - TRAIL_LENGTH_MIN) * step.float / SWEEP_STEPS.float


suite "The Trail Decays Geometrically":
  test "persistence length is 1/e frames at the fade amount":
    # CONTRACT: fade.wgsl multiplies the previous frame's alpha by
    # fadeAmount every frame, so brightness after n frames is fadeAmount^n and
    # the 1/e point sits at n = -1 / ln(fadeAmount). The closed form and the
    # shader's repeated multiply have to name the same frame.
    for step in 1 .. SWEEP_STEPS:
      let fade = fadeAmountFor(sweptLength(step))
      let frames = persistenceFramesForFade(fade)
      check frames > 0.0
      check abs(pow(fade, frames) - 1.0 / E) < FRAME_TOLERANCE

      # The same answer by iteration, which is what the fade pass actually
      # does: one frame short is still brighter than 1/e, one frame past is
      # already dimmer.
      var alpha = 1.0
      for _ in 0 ..< int(floor(frames)):
        alpha = fadedAlpha(alpha, fade)
      check alpha >= 1.0 / E - FRAME_TOLERANCE
      alpha = fadedAlpha(alpha, fade)
      check alpha < 1.0 / E

  test "zero fade amount gives zero persistence":
    # CONTRACT: webgpu_render writes fadeAmount 0 for a zero-length trail, and
    # fade.wgsl then keeps nothing — the pass clears rather than trailing.
    # A persistence of "one frame" would credit the trail with a frame the
    # viewer never sees.
    check persistenceFramesForFade(0.0) == 0.0
    check persistenceFrames(TRAIL_LENGTH_MIN) == 0.0
    check fadeAmountFor(TRAIL_LENGTH_MIN) == 0.0
    check fadedAlpha(1.0, 0.0) == 0.0

  test "the mix carries the trail's colour at the alpha's own rate":
    # CONTRACT: fade.wgsl mixes the previous colour toward the background
    # with the same fadeAmount, so a channel's distance from the background
    # decays exactly as alpha does. One rate governs the whole trail.
    let fade = fadeAmountFor(TRAIL_LENGTH_WHEN_ENABLED)
    for background in [0.0, 0.04, 0.06]:
      for previous in [0.0, 0.25, 1.0]:
        let faded = fadedChannel(background, previous, fade)
        check abs((faded - background) - fade * (previous - background)) <
          EPSILON


suite "The Trail Slider Buys Frames":
  test "persistence rises monotonically with trailLength":
    # CONTRACT: the slider's promise. Every step along the track buys more
    # trail than the step before it left.
    var previous = -1.0
    for step in 0 .. SWEEP_STEPS:
      let frames = persistenceFrames(sweptLength(step))
      check frames > previous
      previous = frames

  test "persistence in frames is linear in trail length":
    # What the mapping buys: fadeAmountFor crowds into the top of its own
    # range — 0.963 by a fifth of the track, and only 0.993 at the end of it —
    # while the frames it produces are exactly proportional to the position:
    # persistence = trailLength * TRAIL_FRAMES_PER_DIAMETER / ln(1/residual).
    # This is the fact a response-probe sweep of trailLength rests on, and it
    # is a property of the mapping rather than of any coordinate.
    let expectedSlope = TRAIL_FRAMES_PER_DIAMETER /
      ln(1.0 / TRAIL_RESIDUAL_FRACTION)
    for step in 1 .. SWEEP_STEPS:
      let length = sweptLength(step)
      check abs(persistenceFrames(length) - length * expectedSlope) <
        FRAME_TOLERANCE

  test "a trail decays to the residual fraction over the frames it names":
    # CONTRACT: the mapping's own construction (webgpu_render's decay target).
    # A trail of L diameters is meant to be visible for L * frames-per-diameter
    # frames, which is the claim recorded beside TRAIL_LENGTH_WHEN_ENABLED:
    # 25 diameters decays to 5% over roughly 50 frames.
    for length in [TRAIL_LENGTH_WHEN_ENABLED, TRAIL_LENGTH_MAX,
        TRAIL_LENGTH_MAX * 0.1]:
      let fade = fadeAmountFor(length)
      let visibleFrames = length * TRAIL_FRAMES_PER_DIAMETER
      check abs(pow(fade, visibleFrames) - TRAIL_RESIDUAL_FRACTION) <
        FRAME_TOLERANCE

  test "the fade multiplier stays inside the range the shader can use":
    # A fadeAmount at or above 1 would keep the previous frame whole and the
    # screen would never clear; below 0 it would invert the trail.
    for step in 0 .. SWEEP_STEPS:
      let fade = fadeAmountFor(sweptLength(step))
      check fade >= 0.0
      check fade < 1.0


suite "The Trail Elongates With Length":
  test "the elongation scale pins the shipped motion-blur mapping":
    # render.wgsl stretches dots along their velocity by this multiplier.
    # Pinned so a change to the slope is a decision, not a drift: zero length
    # elongates nothing, and 100 diameters doubles the stretch.
    check trailElongationScale(0.0) == 0.0
    check abs(trailElongationScale(100.0) - 2.0) < 1e-12

  test "the elongation scale is linear in trail length":
    for step in 0 .. SWEEP_STEPS:
      let length = sweptLength(step)
      check abs(trailElongationScale(length) -
        length * TRAIL_ELONGATION_PER_DIAMETER) < 1e-12


suite "The Trail Opens From Rest Without A Step":
  # A particle at rest and the same particle one frame into motion are one
  # particle. Its brightness has to say so. Speeds in a settled lattice
  # oscillate around zero, so any step in this curve at elongN = 0 fires on
  # every frame that crossing happens — across the whole field at once, which
  # is what a viewer reports as flicker rather than as motion.
  const
    SPINE_SAMPLES = 32
    OPENING_STEPS = 24
    TAPER_TOLERANCE = 1e-6

  func sampledAlongN(sample: int, elongN: float): float =
    ## A point on the spine, from the tail edge to the head edge.
    let tailEdge = -(1.0 + elongN)
    tailEdge + (1.0 - tailEdge) * sample.float / SPINE_SAMPLES.float

  test "a motionless particle carries one flat alpha across its whole disc":
    # elongN = 0 is a plain disc: no spine, nothing to taper along.
    for sample in 0 .. SPINE_SAMPLES:
      check abs(trailTaperAlpha(sampledAlongN(sample, 0.0), 0.0) - 1.0) <
        TAPER_TOLERANCE

  test "the taper never fades deeper than the tail that earns it":
    # THE MEASUREMENT THAT MATTERS, and it is a relation rather than a
    # threshold: however far the alpha sits from flat, the tail is at least
    # that long. Sweeping elongN toward zero therefore squeezes the whole
    # spine back onto the flat disc above, with no step to cross.
    #
    # Applying the full head-to-tip curve to every non-zero tail fails this
    # at the tail edge for every elongN, by the whole depth of the curve.
    for step in 1 .. OPENING_STEPS:
      let elongN = pow(10.0, -step.float / 3.0)
      for sample in 0 .. SPINE_SAMPLES:
        let alpha = trailTaperAlpha(sampledAlongN(sample, elongN), elongN)
        checkpoint("elongN " & $elongN & " alpha " & $alpha)
        check 1.0 - alpha <= min(elongN, 1.0) + TAPER_TOLERANCE

  test "a tail too short to see leaves the disc flat":
    # One frame out of rest. The tail measures a millionth of a radius, so
    # nothing about the particle's brightness may have moved yet.
    let elongN = 1e-6
    for sample in 0 .. SPINE_SAMPLES:
      let alpha = trailTaperAlpha(sampledAlongN(sample, elongN), elongN)
      check abs(alpha - 1.0) < 1e-5

  test "a tail that is open fades from head to tip":
    # The taper still has to do its job once the tail is genuinely long.
    let head = trailTaperAlpha(1.0, 2.0)
    let tip = trailTaperAlpha(-3.0, 2.0)
    check head > tip
    check abs(head - 1.0) < TAPER_TOLERANCE
    check tip < 0.05

  test "alpha never leaves the range a blend can use":
    for step in 0 .. OPENING_STEPS:
      let elongN = step.float * 0.25
      for sample in 0 .. SPINE_SAMPLES:
        let alpha = trailTaperAlpha(sampledAlongN(sample, elongN), elongN)
        check alpha >= 0.0
        check alpha <= 1.0
