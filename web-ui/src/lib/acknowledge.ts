// Acknowledgement is the panel's own and lands in the same tick; the
// response is the world changing, on a declared horizon. These pure helpers
// time the settling indicator that stays lit until the horizon elapses.

export type Horizon = "instant" | "settling" | "structural";

/** How long after a move the world's response may still be arriving, in
 * milliseconds. Instant responses need no indicator at all. */
export function horizonMs(horizon: Horizon): number {
  if (horizon === "settling") return 1200;
  if (horizon === "structural") return 4000;
  return 0;
}

/** Whether the settling indicator is lit at `now` for a control last moved
 * at `movedAt` (both in ms; null means never moved). */
export function settlingActive(
  movedAt: number | null,
  horizon: Horizon,
  now: number,
): boolean {
  if (movedAt === null) return false;
  return now - movedAt < horizonMs(horizon);
}
