import { describe, expect, test } from "bun:test";
import { listenChecked, onsetLevel } from "../src/lib/audio-section";
import type { AudioSample, ListenState } from "../src/garden-api";

const sampleAt = (state: ListenState, onset: number | null): AudioSample => ({
  state,
  loudness: 0,
  bass: 0,
  mid: 0,
  high: 0,
  brightness: 0,
  onset,
});

describe("listenChecked", () => {
  test("checks the switch while a request is in flight", () => {
    expect(listenChecked("Requesting")).toBe(true);
  });

  test("checks the switch while the stream is live", () => {
    expect(listenChecked("Connected")).toBe(true);
  });

  test("keeps the switch checked while the room reads quiet", () => {
    // Silent is still a live capture — the mic is on, the room is quiet.
    expect(listenChecked("Silent")).toBe(true);
  });

  test("leaves the switch unchecked before anything was asked", () => {
    expect(listenChecked("Disconnected")).toBe(false);
  });

  test("leaves the switch unchecked after a refusal", () => {
    expect(listenChecked("Denied")).toBe(false);
  });
});

describe("onsetLevel", () => {
  test("reports the fired onset's own energy", () => {
    expect(onsetLevel(sampleAt("Connected", 0.62))).toBe(0.62);
  });

  test("reads zero when no onset fired this frame", () => {
    expect(onsetLevel(sampleAt("Connected", null))).toBe(0);
  });
});
