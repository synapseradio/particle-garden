// Notch geometry and snapping. Pure functions over the descriptor's own
// numbers — this file compares pick-distances, and invents no values of its
// own.
//
// Every distance here is measured in TRAVEL, the [0, 1] the handle moves
// through, never in value. The two agree only on a linear track: under a
// curve, equal value distances buy unequal travel, and a magnet measured in
// value would grip hard where the curve is dense and let go early where it is
// sparse. The conversion is the boundary's, handed in as positionOf, because
// Nim owns every mapping between position and value.

import type { ParamNotch } from "../garden-api";

// How close a drag must come to a notch before it snaps, as a fraction of the
// slider's full travel. A soft magnet rather than a hard stop: the track stays
// continuous everywhere, and a user who wants a value between two regimes can
// still reach it by dragging past the pull and letting go.
//
// 1.5% of travel is roughly a handle-width at typical panel sizes — close
// enough that landing on a named value takes no precision.
export const SNAP_FRACTION = 0.015;

// A notch never pulls further than this fraction of the distance to its
// nearest neighbour, whatever SNAP_FRACTION says: capped below 0.5 so two
// pulls never meet. Uncapped, a flat pull can exceed the gap between two
// close-set coordinates and make the span between them unreachable —
// enforced by the reachability property test in notches.test.ts.
const NEIGHBOUR_PULL_FRACTION = 0.4;

// The notch a raw drag value should snap to, or null to leave it alone.
//
// Ties go to the nearer notch and, at exactly equal distance, to the earlier
// one in the served order — deterministic, so a drag that stops between two
// equidistant notches does not flicker between them frame to frame.
export function snapTarget(
  raw: number,
  notches: readonly ParamNotch[],
  positionOf: (value: number) => number,
): ParamNotch | null {
  const rawPosition = positionOf(raw);
  // A boundary that cannot say where a value sits cannot be snapped against.
  if (!Number.isFinite(rawPosition)) return null;
  let best: ParamNotch | null = null;
  let bestDistance = Infinity;
  for (const { notch, position, nearest } of withNeighbours(
    notches,
    positionOf,
  )) {
    const distance = Math.abs(position - rawPosition);
    if (distance >= bestDistance) continue;
    if (distance <= effectivePull(nearest)) {
      best = notch;
      bestDistance = distance;
    }
  }
  return best;
}

// Each notch paired with its track position and its travel distance to the
// nearest other notch. Paired at construction rather than held in parallel
// arrays, so the three can never be read out of step.
//
// Memoized against the notch array itself, which the descriptor hands over once
// and never mutates: a drag asks for this on every input event, and computing
// it inside the snap loop costs a full rescan per candidate. One array belongs
// to one descriptor, and so does the curve behind positionOf, so a cache hit
// carries the positions that array's own descriptor produces. The WeakMap holds
// no array alive past its descriptor.
type NotchNeighbour = { notch: ParamNotch; position: number; nearest: number };

const neighbourCache = new WeakMap<readonly ParamNotch[], NotchNeighbour[]>();

function withNeighbours(
  notches: readonly ParamNotch[],
  positionOf: (value: number) => number,
): NotchNeighbour[] {
  const cached = neighbourCache.get(notches);
  if (cached !== undefined) return cached;
  const placed = notches.map((notch) => ({
    notch,
    position: positionOf(notch.value),
  }));
  const paired = placed.map(({ notch, position }) => {
    let nearest = Infinity;
    for (const other of placed) {
      if (other.notch === notch) continue;
      nearest = Math.min(nearest, Math.abs(other.position - position));
    }
    return { notch, position, nearest };
  });
  neighbourCache.set(notches, paired);
  return paired;
}

// How far one notch pulls: the track-wide pull, capped so it cannot reach into
// a neighbour's territory. A lone notch has no neighbour to be capped against
// and keeps the whole magnet. See NEIGHBOUR_PULL_FRACTION.
function effectivePull(nearest: number): number {
  if (!Number.isFinite(nearest)) return SNAP_FRACTION;
  return Math.min(SNAP_FRACTION, nearest * NEIGHBOUR_PULL_FRACTION);
}

// The value a drag should actually write: the snapped notch where one is in
// range, otherwise the raw value untouched.
export function applySnap(
  raw: number,
  notches: readonly ParamNotch[],
  positionOf: (value: number) => number,
): number {
  return snapTarget(raw, notches, positionOf)?.value ?? raw;
}
