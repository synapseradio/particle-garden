// Pure helpers behind the MIDI mapping editor. Every field read here is one
// the boundary already serves on a MappingRow (garden-api.ts); this file
// invents no id, no label and no number of its own.

import type { MappingRow, MidiState } from "../garden-api";

// The parameter ids a row's rank orders it on: a write row's target, or every
// axis the tour row's registered tour writes. Only these two kinds carry a
// rank field, so only these two ever need the editor to show one.
export function rowRankTargets(row: MappingRow): string[] {
  switch (row.kind) {
    case "write":
      return [row.writeParamId];
    case "tour":
      return row.axisParamIds;
    default:
      return [];
  }
}

// Which parameter ids more than one writer reaches, so the editor shows a
// rank input exactly where arbitration order matters and nowhere else.
export function collidingTargets(rows: MappingRow[]): Set<string> {
  const counts = new Map<string, number>();
  for (const row of rows) {
    for (const target of new Set(rowRankTargets(row))) {
      counts.set(target, (counts.get(target) ?? 0) + 1);
    }
  }
  const colliding = new Set<string>();
  for (const [target, count] of counts) {
    if (count > 1) colliding.add(target);
  }
  return colliding;
}

// Whether this row's rank matters: one of the parameters it writes is also
// written by another row.
export function showsRank(row: MappingRow, colliding: Set<string>): boolean {
  return rowRankTargets(row).some((target) => colliding.has(target));
}

// Which connect-affordance states hold the switch checked, on the terms
// listenChecked (audio-section.ts) already reads AudioSample.state by.
const MIDI_CHECKED_STATES: ReadonlySet<MidiState> = new Set([
  "Requesting",
  "Connected",
]);

export function midiConnectChecked(state: MidiState): boolean {
  return MIDI_CHECKED_STATES.has(state);
}

// One line per row, built from served fields alone — the editor's row list
// reads this rather than switching on kind itself.
export function rowSummary(row: MappingRow): string {
  switch (row.kind) {
    case "modulate":
      return `${row.source} → ${row.modParamId} (depth ${row.depth.toFixed(2)})`;
    case "write":
      return `${row.source} → ${row.writeParamId} (rank ${row.rank}, ${
        row.jump ? "jump" : "soft takeover"
      })`;
    case "fire":
      return `${row.source} → ${row.actionId} (event ${row.ordinal})`;
    case "touch":
      return `${row.source} → ${row.gridCols}×${row.gridRows} pad from note ${row.baseNote}`;
    case "tour":
      return `${row.source} → ${row.tourId} tour (rank ${row.tourRank})`;
  }
}

// A row's own resolution flag, named for what the editor marks it with.
export function isUnresolved(row: MappingRow): boolean {
  return !row.resolved;
}
