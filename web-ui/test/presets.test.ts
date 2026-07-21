import { describe, expect, test } from "bun:test";
import type { PresetKeys } from "../src/garden-api";
import {
  addToIndex,
  indexToJson,
  nameIsReserved,
  parseIndexJson,
  presetExists,
  presetStorageKey,
  readIndex,
  readPreset,
  writePreset,
  type StringStorage,
} from "../src/lib/presets";

// The key shape the Nim side serves via presetKeys(); tests pin the same
// values preset_store_core.nim defines so old saved presets keep resolving.
const keys: PresetKeys = {
  prefix: "pg.presets.",
  indexKey: "pg.presets.index",
  defaultName: "Untitled Preset",
};

function memoryStorage(initial: Record<string, string> = {}): StringStorage {
  const backing = new Map(Object.entries(initial));
  return {
    getItem: (key) => (backing.has(key) ? backing.get(key)! : null),
    setItem: (key, value) => void backing.set(key, value),
    removeItem: (key) => void backing.delete(key),
  };
}

describe("parseIndexJson", () => {
  test("round-trips through indexToJson", () => {
    const names = ["alpha", "beta gamma"];
    expect(parseIndexJson(indexToJson(names))).toEqual(names);
  });

  test("degrades malformed input to an empty list instead of throwing", () => {
    expect(parseIndexJson(null)).toEqual([]);
    expect(parseIndexJson("not json")).toEqual([]);
    expect(parseIndexJson('{"a":1}')).toEqual([]);
    expect(parseIndexJson("[1,2]")).toEqual([]);
  });
});

describe("addToIndex", () => {
  test("appends a new name and ignores a duplicate", () => {
    expect(addToIndex([], "one")).toEqual(["one"]);
    expect(addToIndex(["one"], "one")).toEqual(["one"]);
    expect(addToIndex(["one"], "two")).toEqual(["one", "two"]);
  });
});

describe("storage round-trips", () => {
  test("writePreset stores under the pg.presets key and updates the index", () => {
    const storage = memoryStorage();
    writePreset(storage, keys, "my garden", '{"schemaVersion":1}');
    expect(storage.getItem("pg.presets.my garden")).toBe('{"schemaVersion":1}');
    expect(readIndex(storage, keys)).toEqual(["my garden"]);
  });

  test("a preset saved under the OLD Nim UI reads back unchanged", () => {
    // Same key scheme the old preset_store used, so backward compatibility
    // reduces to key equality.
    const storage = memoryStorage({
      "pg.presets.legacy": '{"schemaVersion":1,"name":"legacy"}',
      "pg.presets.index": '["legacy"]',
    });
    expect(readIndex(storage, keys)).toEqual(["legacy"]);
    expect(readPreset(storage, keys, "legacy")).toBe(
      '{"schemaVersion":1,"name":"legacy"}',
    );
    expect(presetExists(storage, keys, "legacy")).toBe(true);
    expect(presetExists(storage, keys, "missing")).toBe(false);
  });

  test("overwriting an indexed preset leaves the index without duplicates", () => {
    const storage = memoryStorage();
    writePreset(storage, keys, "same", "v1");
    writePreset(storage, keys, "same", "v2");
    expect(readPreset(storage, keys, "same")).toBe("v2");
    expect(readIndex(storage, keys)).toEqual(["same"]);
  });
});

describe("nameIsReserved", () => {
  test("rejects the one name whose key collides with the index", () => {
    expect(nameIsReserved(keys, "index")).toBe(true);
    expect(nameIsReserved(keys, "anything else")).toBe(false);
    expect(presetStorageKey(keys, "index")).toBe(keys.indexKey);
  });
});
