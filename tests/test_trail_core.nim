# Behavioral tests for src/trail_core.nim: the trail's geometric decay and the
# trail-length slider's mapping onto it. Two halves of one effect, and the
# suite reaches both — the per-frame decay is what web/shaders/src/fade.wgsl
# runs, and the mapping is what src/webgpu_render.nim writes into the fade
# uniform, from this module.
#
# What a response probe reads: `persistenceReferenceFrames` is the observable
# the trail slider is measured through: the reference frames a trail takes to
# decay to 1/e of its brightness. Reference frames are what a viewer sees the
# trail last for, and fadeAmount is not — the fade multiplier crowds into the
# top of its own range while the trail it produces keeps growing.

import std/[unittest, math, random]
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
    check persistenceReferenceFrames(TRAIL_LENGTH_MIN) == 0.0
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


suite "The Trail Slider Buys Reference Frames":
  test "persistence rises monotonically with trailLength":
    # CONTRACT: the slider's promise. Every step along the track buys more
    # trail than the step before it left.
    var previous = -1.0
    for step in 0 .. SWEEP_STEPS:
      let frames = persistenceReferenceFrames(sweptLength(step))
      check frames > previous
      previous = frames

  test "persistence in reference frames is linear in trail length":
    # What the mapping buys: fadeAmountFor crowds into the top of its own
    # range — 0.963 by a fifth of the track, and only 0.993 at the end of it —
    # while the reference frames it produces are exactly proportional to the
    # position: persistence = trailLength * TRAIL_FRAMES_PER_DIAMETER /
    # ln(1/residual). This is the fact a response-probe sweep of trailLength
    # rests on, and it is a property of the mapping rather than of any
    # coordinate.
    let expectedSlope = TRAIL_FRAMES_PER_DIAMETER /
      ln(1.0 / TRAIL_RESIDUAL_FRACTION)
    for step in 1 .. SWEEP_STEPS:
      let length = sweptLength(step)
      check abs(persistenceReferenceFrames(length) - length * expectedSlope) <
        FRAME_TOLERANCE

  test "a trail decays to the residual fraction over the reference frames it names":
    # CONTRACT: the mapping's own construction (webgpu_render's decay target).
    # A trail of L diameters is meant to be visible for L * frames-per-diameter
    # reference frames, which is the claim recorded beside
    # TRAIL_LENGTH_WHEN_ENABLED: 25 diameters decays to 5% over roughly 50
    # reference frames.
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


suite "The Trail Fades Per Reference Frame":
  const
    FF_SEQUENCE_SEED = 20_260_922
    FF_SPANS = [(span: 1.0, steps: 3), (span: 120.0, steps: 12),
      (span: 600.0, steps: 40)]
      ## Each span is split into `steps` random frame factors summing to it
      ## exactly, each drawn from [0, min(30, remaining)] — a subrange of the
      ## app's own ff domain [0, 30] (design.md, D6's boundary table).
    FF_TRIALS_PER_SPAN = 5
    FADE_PRODUCT_TOLERANCE = 1e-6

  template checkNoVerdicts(verdicts: seq[string]) =
    for message in verdicts[0 ..< min(verdicts.len, 4)]:
      checkpoint message
    check verdicts.len == 0

  func ffSequenceSumming(rng: var Rand, span: float, steps: int): seq[float] =
    ## `steps` frame factors, each at most the span left to spend, summing to
    ## exactly `span`.
    result = newSeq[float](steps)
    var total = 0.0
    for i in 0 ..< steps - 1:
      let v = rng.rand(0.0 .. min(30.0, span - total))
      result[i] = v
      total += v
    result[steps - 1] = span - total

  test "a trail keeps the same share over the same world time at every frame factor (22)":
    # CONTRACT: frameFadeFor(L, ff) = fadeRef^ff, so any split of a span of
    # reference frames into rendered frames has to multiply back to
    # fadeRef^(sum of ff) — design.md D8, "frames compose exactly".
    var rng = initRand(FF_SEQUENCE_SEED)
    var verdicts: seq[string]
    for step in 1 .. SWEEP_STEPS:
      let length = sweptLength(step)
      for spanCase in FF_SPANS:
        for trial in 0 ..< FF_TRIALS_PER_SPAN:
          let sequence = ffSequenceSumming(rng, spanCase.span, spanCase.steps)
          var product = 1.0
          for ff in sequence:
            product *= frameFadeFor(length, ff)
          let expected = pow(TRAIL_RESIDUAL_FRACTION,
            spanCase.span / (length * TRAIL_FRAMES_PER_DIAMETER))
          if abs(product - expected) > FADE_PRODUCT_TOLERANCE:
            verdicts.add "L " & $length & " span " & $spanCase.span &
              " trial " & $trial & ": product " & $product & ", expected " &
              $expected
    checkNoVerdicts(verdicts)

  test "a zero-length trail clears at every frame factor (23)":
    # CONTRACT: pow(0.0, 0.0) is 1 in Nim's std/math, so the zero-length
    # branch has to run ahead of the power or a stopped frame would keep a
    # cleared trail whole.
    for ff in [0.0, 0.084, 0.42, 1.0, 30.0]:
      check frameFadeFor(0.0, ff) == 0.0

  test "a frame that advances no world time keeps the trail whole (24)":
    # CONTRACT: ff 0 means the world did not move this frame, so nothing of
    # any trail may fade.
    for length in [1.0, 25.0, 200.0]:
      check frameFadeFor(length, 0.0) == 1.0
