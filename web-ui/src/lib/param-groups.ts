// Descriptor group arithmetic. Nim decides which group a parameter belongs to;
// this module only reads that membership back, and the panel only decides where
// each group sits on screen. Nothing here hides a control: every group the Nim
// side serves is laid out, and tests/test_panel_reachability.nim fails the
// build if one stops being.

/** The slice of a ParamDescriptor this module reads. */
export interface GroupedParam {
  id: string;
  group: string;
}

/** The ids a group owns, in the order the descriptors arrive. */
export function groupParamIds(
  descriptors: readonly GroupedParam[],
  group: string,
): string[] {
  return descriptors
    .filter((entry) => entry.group === group)
    .map((entry) => entry.id);
}
