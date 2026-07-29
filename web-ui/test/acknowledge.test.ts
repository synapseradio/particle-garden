import { describe, expect, test } from "bun:test";
import { horizonMs, settlingActive } from "../src/lib/acknowledge";

describe("the response horizon times the settling indicator", () => {
  test("an instant response needs no indicator", () => {
    expect(horizonMs("instant")).toBe(0);
    expect(settlingActive(1000, "instant", 1000)).toBe(false);
  });

  test("a settling move stays lit for about a second", () => {
    expect(settlingActive(1000, "settling", 1900)).toBe(true);
    expect(settlingActive(1000, "settling", 1000 + horizonMs("settling"))).toBe(
      false,
    );
  });

  test("a structural move stays lit for several seconds", () => {
    expect(horizonMs("structural")).toBeGreaterThan(horizonMs("settling"));
    expect(settlingActive(0, "structural", horizonMs("structural") - 1)).toBe(
      true,
    );
    expect(settlingActive(0, "structural", horizonMs("structural"))).toBe(
      false,
    );
  });

  test("an untouched control shows nothing", () => {
    expect(settlingActive(null, "structural", 99999)).toBe(false);
  });
});
