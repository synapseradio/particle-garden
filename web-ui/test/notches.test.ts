import { describe, expect, test } from "bun:test";
import {
  applySnap,
  notchPosition,
  snapTarget,
  SNAP_FRACTION,
} from "../src/lib/notches";
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

describe("notchPosition", () => {
  test("maps the range ends to the track ends", () => {
    expect(notchPosition(FEED_MIN, FEED_MIN, FEED_MAX)).toBe(0);
    expect(notchPosition(FEED_MAX, FEED_MIN, FEED_MAX)).toBe(1);
  });

  test("places a midpoint halfway along the track", () => {
    expect(notchPosition(0.5, 0, 1)).toBeCloseTo(0.5, 10);
  });

  test("rejects a value outside the range rather than placing it off-track", () => {
    expect(notchPosition(0.09, FEED_MIN, FEED_MAX)).toBeNull();
    expect(notchPosition(0.005, FEED_MIN, FEED_MAX)).toBeNull();
  });

  test("rejects a degenerate range rather than dividing by zero", () => {
    expect(notchPosition(1, 1, 1)).toBeNull();
    expect(notchPosition(1, 2, 1)).toBeNull();
  });
});

describe("snapTarget", () => {
  const pull = (FEED_MAX - FEED_MIN) * SNAP_FRACTION;

  test("a drag landing exactly on a notch snaps to it", () => {
    expect(snapTarget(0.035, FEED_NOTCHES, FEED_MIN, FEED_MAX)?.label).toBe(
      "Spots",
    );
  });

  test("a drag just inside the pull snaps", () => {
    const near = 0.035 + pull * 0.5;
    expect(snapTarget(near, FEED_NOTCHES, FEED_MIN, FEED_MAX)?.label).toBe(
      "Spots",
    );
  });

  test("a drag beyond the pull is left alone", () => {
    // The point of a soft magnet: the track stays continuous, so a value
    // between two named regimes is still reachable.
    const far = 0.035 + pull * 3;
    expect(snapTarget(far, FEED_NOTCHES, FEED_MIN, FEED_MAX)).toBeNull();
  });

  test("between two notches, the nearer one wins", () => {
    // Mitosis (.028) and Labyrinth (.029) sit one slider step apart — the
    // tightest pair on this axis, and the one a too-wide pull would collapse.
    expect(snapTarget(0.0281, FEED_NOTCHES, FEED_MIN, FEED_MAX)?.label).toBe(
      "Mitosis",
    );
    expect(snapTarget(0.0289, FEED_NOTCHES, FEED_MIN, FEED_MAX)?.label).toBe(
      "Labyrinth",
    );
  });

  test("two notches can never both claim the same point, so ties cannot arise", () => {
    // A drag parked between two notches must not flicker between them frame to
    // frame. The neighbour cap rules that out rather than a tie-break rule
    // does: each notch reaches at most 40% of the way to its neighbour, so no
    // point is within reach of both. The midpoint reaches neither.
    const tie = 0.0285; // exactly between Mitosis (.028) and Labyrinth (.029)
    expect(snapTarget(tie, FEED_NOTCHES, FEED_MIN, FEED_MAX)).toBeNull();
  });

  test("snapping is a pure function of its inputs", () => {
    // Same inputs, same answer, however often it is asked — the panel calls
    // this on every input event.
    for (const raw of [0.0281, 0.035, 0.05, 0.0782, 0.082]) {
      const first = snapTarget(raw, FEED_NOTCHES, FEED_MIN, FEED_MAX);
      const second = snapTarget(raw, FEED_NOTCHES, FEED_MIN, FEED_MAX);
      expect(second?.label).toBe(first?.label);
    }
  });

  test("no notches means no snapping", () => {
    expect(snapTarget(0.035, [], FEED_MIN, FEED_MAX)).toBeNull();
  });

  test("some value between every adjacent pair of notches stays reachable", () => {
    // The property that makes this a magnet and not a hard stop, checked
    // structurally rather than by trusting SNAP_FRACTION: a flat pull of 1.5%
    // of the feed axis is 0.001125, wider than the 0.001 gap between Mitosis
    // and Labyrinth. Each notch's pull is capped against its nearest
    // neighbour, which holds at any SNAP_FRACTION.
    const sorted = [...FEED_NOTCHES].sort((a, b) => a.value - b.value);
    for (let index = 1; index < sorted.length; index += 1) {
      const midpoint = (sorted[index].value + sorted[index - 1].value) / 2;
      expect(snapTarget(midpoint, FEED_NOTCHES, FEED_MIN, FEED_MAX)).toBeNull();
    }
  });

  test("a dense neighbourhood shrinks the pull rather than swallowing the gap", () => {
    // Mitosis and Labyrinth are one slider step apart. Neither may reach the
    // other's coordinate, however wide the track-wide pull is.
    expect(snapTarget(0.029, FEED_NOTCHES, FEED_MIN, FEED_MAX)?.label).toBe(
      "Labyrinth",
    );
    expect(snapTarget(0.028, FEED_NOTCHES, FEED_MIN, FEED_MAX)?.label).toBe(
      "Mitosis",
    );
  });

  test("an isolated notch keeps the full track-wide pull", () => {
    // The cap is a neighbourhood constraint, not a general narrowing: a lone
    // notch on a slider still gets the whole magnet.
    const lone: ParamNotch[] = [{ value: 0.05, label: "only" }];
    expect(
      snapTarget(0.05 + pull * 0.9, lone, FEED_MIN, FEED_MAX)?.label,
    ).toBe("only");
    expect(snapTarget(0.05 + pull * 1.1, lone, FEED_MIN, FEED_MAX)).toBeNull();
  });
});

describe("applySnap", () => {
  test("returns the notch value when one is in reach", () => {
    expect(applySnap(0.0351, FEED_NOTCHES, FEED_MIN, FEED_MAX)).toBe(0.035);
  });

  test("returns the raw value untouched when none is", () => {
    expect(applySnap(0.05, FEED_NOTCHES, FEED_MIN, FEED_MAX)).toBe(0.05);
  });
});
