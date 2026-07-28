// Which controls a simulation mode uses, decided from the group ids the Nim
// side attaches to each mode. Membership is Nim's (descriptor groups, mode
// group lists); this module only does the set arithmetic, and the panel only
// does the ordering. No mode id is named here — a section auto-expands
// because the active mode is the sole mode listing its group, never because
// the code recognises the mode.
//
// Every function fails open: when the served modes carry no groups, nothing
// is gated and the panel renders the full control set. A stale web/app.js is
// the case that matters — gating that failed closed would blank the panel.

/** The slice of a SimMode this module reads. `groups` is optional here even
 *  though the boundary declares it required: an app.js built before the
 *  groups field existed still has to render. */
export interface GatedMode {
  id: string;
  groups?: readonly string[];
}

/** The slice of a ParamDescriptor this module reads. */
export interface GatedParam {
  id: string;
  group: string;
}

/** The groups the active mode uses, or null when the served modes cannot say. */
export function visibleGroups(
  modes: readonly GatedMode[],
  activeModeId: string,
): ReadonlySet<string> | null {
  const active = modes.find((mode) => mode.id === activeModeId);
  if (active?.groups === undefined) return null;
  return new Set(active.groups);
}

export function isGroupVisible(
  modes: readonly GatedMode[],
  activeModeId: string,
  group: string,
): boolean {
  const groups = visibleGroups(modes, activeModeId);
  return groups === null || groups.has(group);
}

/** True when the active mode is the only mode listing the group — the signal
 *  that a section belongs to this mode alone and should open with it.
 *  Exclusivity is unknowable unless every mode declares its groups, so a
 *  single silent mode collapses this to false and the section stays shut. */
export function isModeExclusiveGroup(
  modes: readonly GatedMode[],
  activeModeId: string,
  group: string,
): boolean {
  if (!modes.every((mode) => mode.groups !== undefined)) return false;
  const listing = modes.filter((mode) => mode.groups?.includes(group));
  return listing.length === 1 && listing[0]?.id === activeModeId;
}

/** The ids a group owns, in the order the descriptors arrive. */
export function groupParamIds(
  descriptors: readonly GatedParam[],
  group: string,
): string[] {
  return descriptors
    .filter((entry) => entry.group === group)
    .map((entry) => entry.id);
}

/** The caller's ids minus those whose group the active mode does not use.
 *  Order is the caller's — Nim owns membership, the panel owns layout. An id
 *  no descriptor claims survives the filter; there is no group to judge it by. */
export function filterVisibleIds(
  descriptors: readonly GatedParam[],
  modes: readonly GatedMode[],
  activeModeId: string,
  ids: readonly string[],
): string[] {
  const groups = visibleGroups(modes, activeModeId);
  if (groups === null) return [...ids];
  const groupOf = new Map(descriptors.map((entry) => [entry.id, entry.group]));
  return ids.filter((id) => {
    const group = groupOf.get(id);
    return group === undefined || groups.has(group);
  });
}
