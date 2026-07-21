// localStorage bookkeeping for saved presets — the storage half of the
// hybrid preset design. Keys and preset JSON come from gardenAPI (Nim owns
// the schema, validation, and apply order); this module owns reading and
// writing the browser's localStorage in the exact shape the old Nim
// preset_store used, so presets saved under the old UI keep working.
//
// The index (a JSON array of names under keys.indexKey) mirrors
// preset_store_core.nim's semantics: malformed JSON, a non-array root, or a
// non-string element degrades to an empty list rather than throwing.

import type { PresetKeys } from "../garden-api";

export interface StringStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export function parseIndexJson(text: string | null): string[] {
  if (text === null) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  if (!parsed.every((entry) => typeof entry === "string")) return [];
  return parsed;
}

export function indexToJson(names: string[]): string {
  return JSON.stringify(names);
}

export function addToIndex(names: string[], name: string): string[] {
  return names.includes(name) ? names : [...names, name];
}

export function readIndex(storage: StringStorage, keys: PresetKeys): string[] {
  return parseIndexJson(storage.getItem(keys.indexKey));
}

export function presetStorageKey(keys: PresetKeys, name: string): string {
  return keys.prefix + name;
}

export function readPreset(
  storage: StringStorage,
  keys: PresetKeys,
  name: string,
): string | null {
  return storage.getItem(presetStorageKey(keys, name));
}

export function writePreset(
  storage: StringStorage,
  keys: PresetKeys,
  name: string,
  presetJson: string,
): void {
  storage.setItem(presetStorageKey(keys, name), presetJson);
  const updated = addToIndex(readIndex(storage, keys), name);
  storage.setItem(keys.indexKey, indexToJson(updated));
}

export function presetExists(
  storage: StringStorage,
  keys: PresetKeys,
  name: string,
): boolean {
  return storage.getItem(presetStorageKey(keys, name)) !== null;
}

export function nameIsReserved(keys: PresetKeys, name: string): boolean {
  // A name whose storage key composes to the index's own key would let a
  // saved preset overwrite the index that lists it (same generic guard as
  // the old preset_store).
  return presetStorageKey(keys, name) === keys.indexKey;
}
