# ==============================================================================
# PARTICLE GARDEN - TRAIL CORE (Pure)
# ==============================================================================
#
# The trail, as arithmetic: the per-frame decay web/shaders/src/fade.wgsl runs
# (:104-105), and the mapping from the trail-length slider onto the fade
# multiplier that drives it.
#
# TWO HALVES, ONE HOME. The decay itself runs in a fragment shader no native
# test can execute, so `fadedAlpha` and `fadedChannel` mirror it and the suite
# holds both sides to the same arithmetic (engineering principle 5). The
# mapping is ordinary Nim that the renderer used to inline; it lives here, and
# src/webgpu_render.nim calls `fadeAmountFor` when it writes the fade uniform,
# so the number the GPU receives and the number the suite measures are one
# number rather than two that agree today.
#
# WHAT A RESPONSE PROBE READS. `persistenceFrames` is the observable the trail
# slider is measured through (design E1): the frames a trail takes to fall to
# 1/e of its brightness. The fade multiplier itself is a poor observable, since
# it crowds into the top of its range while the trail keeps lengthening; frames
# are what a viewer actually watches.
#
# Used by:
#   - tests/test_trail_core.nim (native tests)
#   - src/webgpu_render.nim (writes the FadeParams uniform)
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

func fadedAlpha*(previousAlpha, fadeAmount: float): float =
  ## One frame of decay on the trail texture's alpha (fade.wgsl:105).
  previousAlpha * fadeAmount

func fadedChannel*(background, previous, fadeAmount: float): float =
  ## One frame of decay on a colour channel (fade.wgsl:104). The trail's colour
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
