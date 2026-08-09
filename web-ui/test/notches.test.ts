import { describe, expect, test } from "bun:test";
import { applySnap, snapTarget, SNAP_FRACTION } from "../src/lib/notches";
import type { ParamNotch } from "../src/garden-api";

// The feed axis as Nim serves it: six regime coordinates over [0.010, 0.085].
// Values are duplicated here only as test fixtures — the panel reads them from
// the descriptor, and test_param_descriptor.nim is what pins them to the range
// authority.
const FEED_MIN = 0.01;
const FEED_MAX = 0.085;
const FEED_NOTCHES: ParamNotch[] = [
  { value: 0.014, label: "Waves" },
  { value: 0.028, label: "Mitosis" },
  { value: 0.029, label: "Labyrinth" },
  { value: 0.035, label: "Spots" },
  { value: 0.078, label: "Worms" },
  { value: 0.082, label: "Coral" },
];

// The feed axis is linear, so a value distance of `span * SNAP_FRACTION` and a
// travel distance of SNAP_FRACTION are the same reach — which is why the pull
// arithmetic below still reads in feed units.
const feedPositionOf = (value: number) =>
  (Math.min(Math.max(value, FEED_MIN), FEED_MAX) - FEED_MIN) /
  (FEED_MAX - FEED_MIN);

describe("snapTarget", () => {
  const pull = (FEED_MAX - FEED_MIN) * SNAP_FRACTION;

  test("a drag landing exactly on a notch snaps to it", () => {
    expect(snapTarget(0.035, FEED_NOTCHES, feedPositionOf)?.label).toBe(
      "Spots",
    );
  });

  test("a drag just inside the pull snaps", () => {
    const near = 0.035 + pull * 0.5;
    expect(snapTarget(near, FEED_NOTCHES, feedPositionOf)?.label).toBe(
      "Spots",
    );
  });

  test("a drag beyond the pull is left alone", () => {
    // The point of a soft magnet: the track stays continuous, so a value
    // between two named regimes is still reachable.
    const far = 0.035 + pull * 3;
    expect(snapTarget(far, FEED_NOTCHES, feedPositionOf)).toBeNull();
  });

  test("between two notches, the nearer one wins", () => {
    // Mitosis (.028) and Labyrinth (.029) sit one slider step apart — the
    // tightest pair on this axis, and the one a too-wide pull would collapse.
    expect(snapTarget(0.0281, FEED_NOTCHES, feedPositionOf)?.label).toBe(
      "Mitosis",
    );
    expect(snapTarget(0.0289, FEED_NOTCHES, feedPositionOf)?.label).toBe(
      "Labyrinth",
    );
  });

  test("two notches can never both claim the same point, so ties cannot arise", () => {
    // A drag parked between two notches must not flicker between them frame to
    // frame. The neighbour cap rules that out rather than a tie-break rule
    // does: each notch reaches at most 40% of the way to its neighbour, so no
    // point is within reach of both. The midpoint reaches neither.
    const tie = 0.0285; // exactly between Mitosis (.028) and Labyrinth (.029)
    expect(snapTarget(tie, FEED_NOTCHES, feedPositionOf)).toBeNull();
  });

  test("snapping is a pure function of its inputs", () => {
    // Same inputs, same answer, however often it is asked — the panel calls
    // this on every input event.
    for (const raw of [0.0281, 0.035, 0.05, 0.0782, 0.082]) {
      const first = snapTarget(raw, FEED_NOTCHES, feedPositionOf);
      const second = snapTarget(raw, FEED_NOTCHES, feedPositionOf);
      expect(second?.label).toBe(first?.label);
    }
  });

  test("no notches means no snapping", () => {
    expect(snapTarget(0.035, [], feedPositionOf)).toBeNull();
  });

  test("a boundary that cannot place a value declines to snap", () => {
    // The panel takes the mapping from Nim rather than computing one; an
    // answer that is not a position is no answer to measure against. Its own
    // notch array, because one array is served by one mapping.
    const unplaceable: ParamNotch[] = [{ value: 0.035, label: "Spots" }];
    expect(snapTarget(0.035, unplaceable, () => NaN)).toBeNull();
  });

  test("some value between every adjacent pair of notches stays reachable", () => {
    // The property that makes this a magnet and not a hard stop, checked
    // structurally rather than by trusting SNAP_FRACTION: a flat pull of 1.5%
    // of the feed axis is 0.001125, wider than the 0.001 gap between Mitosis
    // and Labyrinth. Each notch's pull is capped against its nearest
    // neighbour, which holds at any SNAP_FRACTION.
    const sorted = [...FEED_NOTCHES].sort((a, b) => a.value - b.value);
    sorted.forEach((notch, index) => {
      const previous = sorted[index - 1];
      if (!previous) return; // the first notch has no pair below it
      const midpoint = (notch.value + previous.value) / 2;
      expect(snapTarget(midpoint, FEED_NOTCHES, feedPositionOf)).toBeNull();
    });
  });

  test("a dense neighbourhood shrinks the pull rather than swallowing the gap", () => {
    // Mitosis and Labyrinth are one slider step apart. Neither may reach the
    // other's coordinate, however wide the track-wide pull is.
    expect(snapTarget(0.029, FEED_NOTCHES, feedPositionOf)?.label).toBe(
      "Labyrinth",
    );
    expect(snapTarget(0.028, FEED_NOTCHES, feedPositionOf)?.label).toBe(
      "Mitosis",
    );
  });

  test("an isolated notch keeps the full track-wide pull", () => {
    // The cap is a neighbourhood constraint, not a general narrowing: a lone
    // notch on a slider still gets the whole magnet.
    const lone: ParamNotch[] = [{ value: 0.05, label: "only" }];
    expect(
      snapTarget(0.05 + pull * 0.9, lone, feedPositionOf)?.label,
    ).toBe("only");
    expect(snapTarget(0.05 + pull * 1.1, lone, feedPositionOf)).toBeNull();
  });
});

// The zoom axis as Nim serves it under a logarithmic track: two notches at the
// ends of [1, 8]. The pair below mirrors slider_curve.nim's cLog case only so
// the test can ask where on the track a value sits — the panel itself receives
// this mapping from the boundary and computes none.
const ZOOM_MIN = 1;
const ZOOM_MAX = 8;
const ZOOM_NOTCHES: ParamNotch[] = [
  { value: ZOOM_MIN, label: "world" },
  { value: ZOOM_MAX, label: "creature" },
];
const logPositionOf = (value: number) =>
  Math.log(Math.min(Math.max(value, ZOOM_MIN), ZOOM_MAX) / ZOOM_MIN) /
  Math.log(ZOOM_MAX / ZOOM_MIN);
const logValueAt = (position: number) =>
  ZOOM_MIN * (ZOOM_MAX / ZOOM_MIN) ** position;

// The share of TRAVEL over which a notch still claims the drag, found by
// bisecting for the position where the magnet lets go. Midtrack is claimed by
// neither notch, which is what makes it a valid open end for the search.
const travelShareClaimed = (
  label: string,
  from: number,
  direction: 1 | -1,
): number => {
  let held = from;
  let free = from + direction * 0.5;
  for (let step = 0; step < 60; step += 1) {
    const middle = (held + free) / 2;
    const claimed =
      snapTarget(logValueAt(middle), ZOOM_NOTCHES, logPositionOf)
        ?.label === label;
    if (claimed) held = middle;
    else free = middle;
  }
  return Math.abs(held - from);
};

describe("snapTarget on a curved track", () => {
  test("a notch claims the same share of travel wherever it sits", () => {
    // SNAP_FRACTION is a fraction of the slider's full travel, and travel is
    // what the hand moves. A magnet measured in value distances instead
    // stretches where the curve is dense and shrinks where it is sparse, so
    // the same control pulls unequally at its two ends.
    expect(travelShareClaimed("world", 0, 1)).toBeCloseTo(SNAP_FRACTION, 5);
    expect(travelShareClaimed("creature", 1, -1)).toBeCloseTo(
      SNAP_FRACTION,
      5,
    );
  });
});

describe("applySnap", () => {
  test("returns the notch value when one is in reach", () => {
    expect(applySnap(0.0351, FEED_NOTCHES, feedPositionOf)).toBe(0.035);
  });

  test("returns the raw value untouched when none is", () => {
    expect(applySnap(0.05, FEED_NOTCHES, feedPositionOf)).toBe(0.05);
  });
});
