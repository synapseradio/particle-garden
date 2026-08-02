# ==============================================================================
# PARTICLE GARDEN - TRAIL CORE (Pure)
# ==============================================================================
#
# The trail, as arithmetic: the per-frame decay web/shaders/src/fade.wgsl runs,
# and the mapping from the trail-length slider onto the fade multiplier that
# drives it.
#
# TWO HALVES, ONE HOME. The decay itself runs in a fragment shader no native
# test can execute, so `fadedAlpha` and `fadedChannel` mirror it and the suite
# holds both sides to the same arithmetic (engineering principle 5). The
# mapping is ordinary Nim, kept separate from the renderer that consumes it;
# it lives here, and src/webgpu_render.nim calls `fadeAmountFor` when it
# writes the fade uniform, so the number the GPU receives and the number the
# suite measures are one number rather than two that must be kept in
# agreement.
#
# WHAT A RESPONSE PROBE READS. `persistenceFrames` is the observable the trail
# slider is measured through: the frames a trail takes to fall to
# 1/e of its brightness. The fade multiplier itself is a poor observable, since
# it crowds into the top of its range while the trail keeps lengthening; frames
# are what a viewer actually watches.
#
# Used by:
#   - tests/test_trail_core.nim (native tests)
#   - src/webgpu_render.nim (writes the fade and render uniforms)
#
# ==============================================================================

import std/math

const
  TRAIL_FRAMES_PER_DIAMETER* = 2.0
    ## Frames a typical particle takes to cross one of its own diameters at
    ## 60fps. This is what turns a trail length in diameters — the unit the
    ## slider is labelled in — into a count of frames the trail must survive.
  TRAIL_RESIDUAL_FRACTION* = 0.05
    ## What is left of a trail at the end of the frames its length names. Five
    ## percent is faint enough to read as the end of the trail and bright
    ## enough that the decay does not visibly stop early.
  TRAIL_ELONGATION_PER_DIAMETER* = 0.02
    ## Motion-blur elongation render.wgsl applies per diameter of trail
    ## length: dots stretch along their velocity by trailLength * this, so
    ## 100 diameters doubles the stretch (pinned by tests/test_trail_core.nim).
  TRAIL_TAPER_FULL_ELONGATION* = 1.0
    ## Tail length, in particle radii, at which the head-to-tip fade reaches
    ## its full depth. Shorter tails fade proportionally less, so the taper
    ## grows in step with the tail it decorates rather than switching on with
    ## it.

func fadeAmountFor*(trailLength: float): float =
  ## The per-frame multiplier the fade pass keeps of the previous frame, for a
  ## trail of `trailLength` particle diameters.
  ##
  ## Zero length keeps nothing: the pass clears instead of trailing, which is
  ## what makes a zero-length trail invisible rather than permanent. Above
  ## zero, the multiplier is whatever decays the trail to
  ## TRAIL_RESIDUAL_FRACTION over the frames the length names.
  if trailLength <= 0.0:
    0.0
  else:
    let visibleFrames = trailLength * TRAIL_FRAMES_PER_DIAMETER
    pow(TRAIL_RESIDUAL_FRACTION, 1.0 / visibleFrames)

func trailElongationScale*(trailLength: float): float =
  ## The velocity-elongation multiplier the renderer writes for a trail of
  ## `trailLength` diameters. Linear, so the stretch reads as the same effect
  ## the fade lengthens.
  trailLength * TRAIL_ELONGATION_PER_DIAMETER

func trailTaperAlpha*(alongN, elongN: float): float =
  ## The alpha multiplier render.wgsl's fragment applies along a particle's
  ## motion-blur spine, so the tail fades toward its tip.
  ##
  ## `alongN` is the fragment's position along the velocity axis in radius
  ## units: +1 at the head edge, -(1 + elongN) at the tail edge. `elongN` is
  ## the tail's length in the same units, `elongation / halfSize`.
  ##
  ## Taper DEPTH scales with elongN, which is what keeps a particle leaving
  ## rest from flashing. Applying the full curve to any tail longer than zero
  ## drops a barely-moving particle to a half-faded disc while its tail is
  ## still too short to see, and speeds in a settled lattice cross zero every
  ## frame.
  let e = max(elongN, 0.0)
  let u = clamp((1.0 - alongN) / (2.0 + e), 0.0, 1.0)
  let depth = min(e / TRAIL_TAPER_FULL_ELONGATION, 1.0)
  1.0 - depth * (1.0 - sqrt(1.0 - u))

func fadedAlpha*(previousAlpha, fadeAmount: float): float =
  ## One frame of decay on the trail texture's alpha (fade.wgsl).
  previousAlpha * fadeAmount

func fadedChannel*(background, previous, fadeAmount: float): float =
  ## One frame of decay on a colour channel (fade.wgsl). The trail's colour
  ## falls toward the background rather than toward black, at the same rate the
  ## alpha falls toward nothing.
  background + (previous - background) * fadeAmount

func persistenceFramesForFade*(fadeAmount: float): float =
  ## The frames a trail decaying by `fadeAmount` each frame takes to fall to
  ## 1/e of its brightness: fadeAmount^n = 1/e, so n = -1 / ln(fadeAmount).
  ##
  ## A fade amount of zero persists for no frames at all — the pass clears the
  ## frame it is given.
  if fadeAmount <= 0.0:
    0.0
  else:
    -1.0 / ln(fadeAmount)

func persistenceFrames*(trailLength: float): float =
  ## The observable behind the trail-length slider: the frames a trail of
  ## `trailLength` diameters stays visible, to the 1/e point.
  ##
  ## Composing the two functions above collapses to a straight line —
  ## trailLength * TRAIL_FRAMES_PER_DIAMETER / ln(1 / TRAIL_RESIDUAL_FRACTION)
  ## — because the mapping is built to hit a fixed residual over a frame count
  ## proportional to the length. The composition is written out rather than
  ## short-cut to that line, so a change to either half stays visible here.
  persistenceFramesForFade(fadeAmountFor(trailLength))
