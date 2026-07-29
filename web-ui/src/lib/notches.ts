// Notch geometry and snapping. Pure functions over the descriptor's own
// numbers — this file computes positions and pick-distances, and invents no
// values of its own.

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

// Where a notch sits along the track, as a 0..1 fraction from min to max.
// Returns null for a degenerate range rather than dividing by zero.
export function notchPosition(
  value: number,
  min: number,
  max: number,
): number | null {
  const span = max - min;
  if (!(span > 0)) return null;
  const position = (value - min) / span;
  if (position < 0 || position > 1) return null;
  return position;
}

// The notch a raw drag value should snap to, or null to leave it alone.
//
// Ties go to the nearer notch and, at exactly equal distance, to the earlier
// one in the served order — deterministic, so a drag that stops between two
// equidistant notches does not flicker between them frame to frame.
export function snapTarget(
  raw: number,
  notches: readonly ParamNotch[],
  min: number,
  max: number,
): ParamNotch | null {
  const span = max - min;
  if (!(span > 0)) return null;
  const trackPull = span * SNAP_FRACTION;
  const neighbours = neighbourDistances(notches);
  let best: ParamNotch | null = null;
  let bestDistance = Infinity;
  for (let index = 0; index < notches.length; index += 1) {
    const notch = notches[index];
    const distance = Math.abs(notch.value - raw);
    if (distance >= bestDistance) continue;
    if (distance <= effectivePull(neighbours[index], trackPull)) {
      best = notch;
      bestDistance = distance;
    }
  }
  return best;
}

// Each notch's distance to its nearest neighbour, in the served order.
//
// Memoized against the notch array itself, which the descriptor hands over once
// and never mutates: a drag asks for this on every input event, and computing
// it inside the snap loop costs a full rescan per candidate. The WeakMap holds
// no array alive past its descriptor.
const neighbourCache = new WeakMap<readonly ParamNotch[], number[]>();

function neighbourDistances(notches: readonly ParamNotch[]): number[] {
  const cached = neighbourCache.get(notches);
  if (cached !== undefined) return cached;
  const distances = notches.map((notch) => {
    let nearest = Infinity;
    for (const other of notches) {
      if (other === notch) continue;
      nearest = Math.min(nearest, Math.abs(other.value - notch.value));
    }
    return nearest;
  });
  neighbourCache.set(notches, distances);
  return distances;
}

// How far one notch pulls: the track-wide pull, capped so it cannot reach into
// a neighbour's territory. A lone notch has no neighbour to be capped against
// and keeps the whole magnet. See NEIGHBOUR_PULL_FRACTION.
function effectivePull(nearest: number, trackPull: number): number {
  if (!Number.isFinite(nearest)) return trackPull;
  return Math.min(trackPull, nearest * NEIGHBOUR_PULL_FRACTION);
}

// The value a drag should actually write: the snapped notch where one is in
// range, otherwise the raw value untouched.
export function applySnap(
  raw: number,
  notches: readonly ParamNotch[],
  min: number,
  max: number,
): number {
  return snapTarget(raw, notches, min, max)?.value ?? raw;
}
