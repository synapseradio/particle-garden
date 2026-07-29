# ==============================================================================
# PARTICLE GARDEN - SLIDER CURVE
# ==============================================================================
#
# The travel curve maps a handle position in [0, 1] to a parameter value and
# back — in Nim, so the panel computes no mapping and setParam's clamp can
# never disagree with the handle. valueAt and positionOf are mutual inverses
# on the descriptor's own step lattice: valueAt lands every result on that
# lattice, positionOf stays continuous.
#
# Both directions read the bounds the CALLER says are served —
# `boundMin`/`boundMax` default to the descriptor's envelope, and a derived
# bound passes its live ceiling — so position keeps meaning
# "fraction of the reachable track" at every ceiling, and the curve needs no
# knowledge of why the interval is what it is.
#
# The curve changes nothing but the handle's position. Stored values, preset
# keys, clamps, notch coordinates and the readout all carry the value; a
# preset written before a curve changes loads identically after.

import std/math

import param_descriptor

func servedInterval(descriptor: ParamDescriptor;
    boundMin, boundMax: float): tuple[lo, hi: float] =
  (
    lo: (if boundMin.isNaN: descriptor.minValue else: boundMin),
    hi: (if boundMax.isNaN: descriptor.maxValue else: boundMax))

func snapToLattice(descriptor: ParamDescriptor;
    value, lo, hi: float): float =
  ## The nearest position the slider can actually land on: the descriptor's
  ## step lattice, anchored at the envelope minimum, clamped to the served
  ## interval.
  if descriptor.step <= 0.0:
    return clamp(value, lo, hi)
  let stepped = descriptor.minValue +
    round((value - descriptor.minValue) / descriptor.step) * descriptor.step
  clamp(stepped, lo, hi)

func valueAt*(descriptor: ParamDescriptor; position: float;
    boundMin = NaN; boundMax = NaN): float =
  ## The value the handle at `position` names, on the descriptor's lattice.
  let (lo, hi) = servedInterval(descriptor, boundMin, boundMax)
  if hi <= lo:
    return lo
  let travel = clamp(position, 0.0, 1.0)
  let raw =
    case descriptor.curve
    of cLinear:
      lo + travel * (hi - lo)
    of cLog:
      # The static gate in param_descriptor holds lo above zero for cLog.
      lo * pow(hi / lo, travel)
    of cPower:
      lo + (hi - lo) * pow(travel, descriptor.curveExponent)
  snapToLattice(descriptor, raw, lo, hi)

func positionOf*(descriptor: ParamDescriptor; value: float;
    boundMin = NaN; boundMax = NaN): float =
  ## Where on the track a value sits. Continuous — rounding belongs to the
  ## value direction alone, or the pair stops being inverses.
  let (lo, hi) = servedInterval(descriptor, boundMin, boundMax)
  if hi <= lo:
    return 0.0
  let clamped = clamp(value, lo, hi)
  case descriptor.curve
  of cLinear:
    (clamped - lo) / (hi - lo)
  of cLog:
    ln(clamped / lo) / ln(hi / lo)
  of cPower:
    pow((clamped - lo) / (hi - lo), 1.0 / descriptor.curveExponent)
