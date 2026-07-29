// Descriptor group arithmetic. Nim decides which group a parameter belongs to;
// this module only reads that membership back, and the panel only decides where
// each group sits on screen. Nothing here hides a control: every group the Nim
// side serves is laid out, and tests/test_panel_reachability.nim fails the
// build if one stops being.

import type { ParamArity } from "../garden-api";

/** The slice of a ParamDescriptor the group arithmetic reads. */
export interface GroupedParam {
  id: string;
  group: string;
}

/** The slice of a ParamDescriptor the cardinality filter reads. */
export interface ArityParam {
  id: string;
  arity: ParamArity;
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

/**
 * The ids the scalar getParam/setParam path serves, in descriptor order.
 *
 * A per-species column holds one value per species in the live array
 * chemistry() returns, so getParam has no single number to answer with. The
 * panel reads and writes those cells directly and clamps them through
 * clampParam instead.
 */
export function scalarParamIds(descriptors: readonly ArityParam[]): string[] {
  return descriptors
    .filter((entry) => entry.arity === "scalar")
    .map((entry) => entry.id);
}
