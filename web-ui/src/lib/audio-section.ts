// Pure helpers behind the Audio section: which affordance states hold the
// Listen switch checked, and what level the onset indicator shows for a
// pushed sample. No number here belongs to this file — Nim owns every
// threshold behind ListenState and every feature value in AudioSample.

import type { AudioSample, ListenState } from "../garden-api";

const CHECKED_STATES: ReadonlySet<ListenState> = new Set([
  "Requesting",
  "Connected",
  "Silent",
]);

export function listenChecked(state: ListenState): boolean {
  return CHECKED_STATES.has(state);
}

export function onsetLevel(sample: AudioSample): number {
  return sample.onset ?? 0;
}
