import { describe, expect, test } from "bun:test";
import {
  collidingTargets,
  isUnresolved,
  midiConnectChecked,
  rowRankTargets,
  rowSummary,
  showsRank,
} from "../src/lib/mapping-editor";
import type { MappingRow } from "../src/garden-api";

const writeRow = (over: Partial<MappingRow & { kind: "write" }> = {}) =>
  ({
    index: 0,
    kind: "write" as const,
    source: "midi:cc:1:7",
    resolved: true,
    writeParamId: "forceStrength",
    jump: false,
    rank: 1,
    ...over,
  }) satisfies MappingRow;

const tourRow = (over: Partial<MappingRow & { kind: "tour" }> = {}) =>
  ({
    index: 0,
    kind: "tour" as const,
    source: "clock:frame",
    resolved: true,
    tourId: "climate",
    runningParamId: "climateDrift",
    tourSpeedParamId: "climateSpeed",
    tourRank: 0,
    axisParamIds: ["rdFeed", "rdKill"],
    ...over,
  }) satisfies MappingRow;

const modulateRow: MappingRow = {
  index: 0,
  kind: "modulate",
  source: "audio:loudness",
  resolved: true,
  modParamId: "fluidStrength",
  depth: 0.5,
  attackMs: 0,
  releaseMs: 0,
};

const fireRow: MappingRow = {
  index: 0,
  kind: "fire",
  source: "midi:pc:1",
  resolved: true,
  actionId: "regime:waves",
  ordinal: 0,
};

const touchRow: MappingRow = {
  index: 0,
  kind: "touch",
  source: "midi:notes:1",
  resolved: true,
  gridCols: 4,
  gridRows: 4,
  baseNote: 36,
};

describe("collidingTargets", () => {
  test("names a parameter that two write rows both target", () => {
    const rows = [
      writeRow({ index: 0, source: "midi:cc:1:7" }),
      writeRow({ index: 1, source: "midi:cc:1:2", rank: 2 }),
    ];
    expect(collidingTargets(rows)).toEqual(new Set(["forceStrength"]));
  });

  test("leaves a solitary write row's target uncollided", () => {
    const rows = [writeRow()];
    expect(collidingTargets(rows)).toEqual(new Set());
  });

  test("names every axis two rows of one tour both write", () => {
    const rows = [
      tourRow({ index: 0 }),
      tourRow({ index: 1, source: "clock:frame", tourRank: 1 }),
    ];
    expect(collidingTargets(rows)).toEqual(new Set(["rdFeed", "rdKill"]));
  });

  test("names a parameter a write row and a tour axis both reach", () => {
    const rows = [
      writeRow({ index: 0 }),
      tourRow({
        index: 1,
        tourId: "forceWeather",
        axisParamIds: ["forceStrength", "interactionRadius", "friction"],
      }),
    ];
    expect(collidingTargets(rows)).toEqual(new Set(["forceStrength"]));
  });

  test("leaves a tour whose axes no other row writes uncollided", () => {
    expect(collidingTargets([writeRow(), tourRow()])).toEqual(new Set());
  });

  test("ignores modulate, fire and touch rows, which carry no rank", () => {
    const rows = [modulateRow, fireRow, touchRow];
    expect(collidingTargets(rows)).toEqual(new Set());
  });
});

describe("rowSummary", () => {
  test("summarizes a write row's source, target and rank", () => {
    expect(rowSummary(writeRow())).toBe(
      "midi:cc:1:7 → forceStrength (rank 1, soft takeover)",
    );
  });

  test("names a jump write row as a jump rather than soft takeover", () => {
    expect(rowSummary(writeRow({ jump: true }))).toBe(
      "midi:cc:1:7 → forceStrength (rank 1, jump)",
    );
  });

  test("summarizes a modulate row's source, target and depth", () => {
    expect(rowSummary(modulateRow)).toBe(
      "audio:loudness → fluidStrength (depth 0.50)",
    );
  });

  test("summarizes a fire row's source, action and ordinal", () => {
    expect(rowSummary(fireRow)).toBe("midi:pc:1 → regime:waves (event 0)");
  });

  test("summarizes a touch row's source and pad grid", () => {
    expect(rowSummary(touchRow)).toBe(
      "midi:notes:1 → 4×4 pad from note 36",
    );
  });

  test("summarizes a tour row's source, tour id and rank", () => {
    expect(rowSummary(tourRow())).toBe(
      "clock:frame → climate tour (rank 0)",
    );
  });
});

describe("rowRankTargets", () => {
  test("names a write row's own target id", () => {
    expect(rowRankTargets(writeRow())).toEqual(["forceStrength"]);
  });

  test("names a tour row's served axes", () => {
    expect(rowRankTargets(tourRow())).toEqual(["rdFeed", "rdKill"]);
  });

  test("names no target for kinds that carry no rank", () => {
    expect(rowRankTargets(modulateRow)).toEqual([]);
    expect(rowRankTargets(fireRow)).toEqual([]);
    expect(rowRankTargets(touchRow)).toEqual([]);
  });
});

describe("showsRank", () => {
  test("shows a rank on each row that shares a parameter with another", () => {
    const write = writeRow();
    const tour = tourRow({
      tourId: "forceWeather",
      axisParamIds: ["forceStrength", "interactionRadius", "friction"],
    });
    const colliding = collidingTargets([write, tour, modulateRow]);
    expect(showsRank(write, colliding)).toBe(true);
    expect(showsRank(tour, colliding)).toBe(true);
    expect(showsRank(modulateRow, colliding)).toBe(false);
  });

  test("shows no rank on a writer nothing else contests", () => {
    const write = writeRow();
    expect(showsRank(write, collidingTargets([write, tourRow()]))).toBe(false);
  });
});

describe("midiConnectChecked", () => {
  test("checks the switch while a connection request is in flight", () => {
    expect(midiConnectChecked("Requesting")).toBe(true);
  });

  test("checks the switch while a controller is connected", () => {
    expect(midiConnectChecked("Connected")).toBe(true);
  });

  test("leaves the switch unchecked before anything was asked", () => {
    expect(midiConnectChecked("Disconnected")).toBe(false);
  });

  test("leaves the switch unchecked when no MIDI access exists", () => {
    expect(midiConnectChecked("Unavailable")).toBe(false);
  });
});

describe("isUnresolved", () => {
  test("reads an unresolved row from its served resolution flag", () => {
    expect(isUnresolved(writeRow({ resolved: false }))).toBe(true);
  });

  test("reads a resolved row from its served resolution flag", () => {
    expect(isUnresolved(writeRow({ resolved: true }))).toBe(false);
  });
});
