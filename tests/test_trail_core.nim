# ==============================================================================
# PARTICLE GARDEN - TRAIL CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/trail_core.nim: the trail's geometric decay and the
# trail-length slider's mapping onto it. Two halves of one effect, and the
# suite reaches both — the per-frame decay is what web/shaders/src/fade.wgsl
# runs (:104-105), and the mapping is what src/webgpu_render.nim writes into
# the fade uniform, from this module.
#
# WHAT A RESPONSE PROBE READS. `persistenceFrames` is the observable the trail
# slider is measured through (design E1): the frames a trail takes to decay to
# 1/e of its brightness. Frames are what a viewer sees the trail last for, and
# fadeAmount is not — the fade multiplier crowds into the top of its own range
# while the trail it produces keeps growing.
#
# Run with: just test
#
# ==============================================================================

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
    ## Trail lengths sampled across the shipped range.

func sweptLength(step: int): float =
  TRAIL_LENGTH_MIN +
    (TRAIL_LENGTH_MAX - TRAIL_LENGTH_MIN) * step.float / SWEEP_STEPS.float


suite "The Trail Decays Geometrically":
  test "persistence length is 1/e frames at the fade amount":
    # CONTRACT: fade.wgsl:105 multiplies the previous frame's alpha by
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
    # fade.wgsl:105 then keeps nothing — the pass clears rather than trailing.
    # A persistence of "one frame" would credit the trail with a frame the
    # viewer never sees.
    check persistenceFramesForFade(0.0) == 0.0
    check persistenceFrames(TRAIL_LENGTH_MIN) == 0.0
    check fadeAmountFor(TRAIL_LENGTH_MIN) == 0.0
    check fadedAlpha(1.0, 0.0) == 0.0

  test "the mix carries the trail's colour at the alpha's own rate":
    # CONTRACT: fade.wgsl:104 mixes the previous colour toward the background
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
    # WHAT THE MAPPING BUYS. fadeAmountFor crowds into the top of its own
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
