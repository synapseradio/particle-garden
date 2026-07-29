import { describe, expect, test } from "bun:test";
import { dormantShare } from "../src/lib/bounds";

describe("dormantShare", () => {
  test("a ceiling at or above the maximum leaves the whole track live", () => {
    expect(dormantShare(40, 1, 40)).toBeNull();
    expect(dormantShare(100, 1, 40)).toBeNull();
  });

  test("a ceiling inside the range takes the share above it", () => {
    // Envelope 1..41 is 40 wide; a ceiling of 31 leaves 10 above it.
    expect(dormantShare(31, 1, 41)).toBeCloseTo(0.25, 12);
    expect(dormantShare(21, 1, 41)).toBeCloseTo(0.5, 12);
  });

  test("a ceiling at or below the minimum takes the whole track", () => {
    // Reachable: a fluid narrow enough, fast enough and unsubstepped enough
    // holds less stiffness than the slider's own floor offers.
    expect(dormantShare(1, 1, 40)).toBe(1);
    expect(dormantShare(0.03, 1, 40)).toBe(1);
  });

  test("no ceiling reported yet reads as nothing dormant", () => {
    // Before the first stats push the panel has been told no ceiling at all,
    // which is different from having been told the track is dormant.
    expect(dormantShare(undefined, 1, 40)).toBeNull();
    expect(dormantShare(Number.NaN, 1, 40)).toBeNull();
    expect(dormantShare(Number.POSITIVE_INFINITY, 1, 40)).toBeNull();
  });

  test("a degenerate range reports nothing rather than dividing by zero", () => {
    expect(dormantShare(5, 10, 10)).toBeNull();
    expect(dormantShare(5, 10, 2)).toBeNull();
  });
});
