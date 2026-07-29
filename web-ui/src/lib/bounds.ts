// Where a live ceiling cuts a slider's track. Pure geometry over numbers Nim
// owns — this file decides no ceiling and invents no reason for one.

// The share of the track lying above a ceiling, as a 0..1 fraction measured
// from the right-hand end, or null when the ceiling leaves the whole track
// live.
//
// A ceiling at or above the maximum takes nothing, and returning null rather
// than 0 lets the caller skip rendering entirely — a zero-width band still
// carries a reason nobody needs to read. A ceiling at or below the minimum
// takes the whole track, which is a real state: a fluid configured somewhere it
// can hold no stiffness at all has no live stiffness to offer.
export function dormantShare(
  ceiling: number | undefined,
  min: number,
  max: number,
): number | null {
  if (ceiling === undefined || !Number.isFinite(ceiling)) return null;
  const span = max - min;
  if (!(span > 0)) return null;
  if (ceiling >= max) return null;
  if (ceiling <= min) return 1;
  return (max - ceiling) / span;
}
