import { describe, expect, test } from "bun:test";
import {
  groupParamIds,
  scalarParamIds,
  type ArityParam,
  type GroupedParam,
} from "../src/lib/param-groups";

// The group taxonomy the Nim side attaches to each descriptor. Membership is
// Nim's to decide; these fixtures only mirror it closely enough that a
// regression in the group arithmetic reads as a real panel bug.
const descriptors: GroupedParam[] = [
  { id: "particleCount", group: "simulation" },
  { id: "speciesCount", group: "simulation" },
  { id: "interactionRadius", group: "grid" },
  { id: "forceStrength", group: "species" },
  { id: "friction", group: "simulation" },
  { id: "timeScale", group: "simulation" },
  { id: "ruleTemperature", group: "species" },
  { id: "fluidStrength", group: "fluid" },
  { id: "sphRestDensity", group: "fluid" },
  { id: "rdFeed", group: "rd" },
  { id: "rdKill", group: "rd" },
  { id: "fieldOpacity", group: "rd-field" },
];

describe("groupParamIds", () => {
  test("returns the group's ids in descriptor order", () => {
    expect(groupParamIds(descriptors, "rd")).toEqual(["rdFeed", "rdKill"]);
    expect(groupParamIds(descriptors, "species")).toEqual([
      "forceStrength",
      "ruleTemperature",
    ]);
  });

  test("keeps a coupling strength ahead of the knobs that shape it", () => {
    expect(groupParamIds(descriptors, "fluid")).toEqual([
      "fluidStrength",
      "sphRestDensity",
    ]);
  });

  test("returns an empty list for a group no descriptor claims", () => {
    expect(groupParamIds(descriptors, "matrix")).toEqual([]);
  });

  test("never drops an id: every descriptor lands in exactly one group", () => {
    const groups = new Set(descriptors.map((entry) => entry.group));
    const collected = [...groups].flatMap((group) =>
      groupParamIds(descriptors, group),
    );
    expect(collected.sort()).toEqual(descriptors.map((e) => e.id).sort());
  });
});

// One table serves both cardinalities, so the panel filters rather than reading
// a second one. Mirrors what Nim serves: sliders alongside the two per-species
// chemistry columns.
const mixed: ArityParam[] = [
  { id: "friction", arity: "scalar" },
  { id: "secretion", arity: "perSpecies" },
  { id: "rdFeed", arity: "scalar" },
  { id: "tropism", arity: "perSpecies" },
];

describe("scalarParamIds", () => {
  test("keeps the scalars in descriptor order", () => {
    expect(scalarParamIds(mixed)).toEqual(["friction", "rdFeed"]);
  });

  test("drops the per-species columns, which getParam cannot serve", () => {
    // The defect this pins. A per-species column holds one value per species in
    // a live array, so there is no single number for getParam to return. Asking
    // for one warns on the Nim side and would seed the panel with a zero that
    // looks like a real setting.
    expect(scalarParamIds(mixed)).not.toContain("secretion");
    expect(scalarParamIds(mixed)).not.toContain("tropism");
  });

  test("returns every id when nothing is per-species", () => {
    const scalars: ArityParam[] = [
      { id: "friction", arity: "scalar" },
      { id: "timeScale", arity: "scalar" },
    ];
    expect(scalarParamIds(scalars)).toEqual(["friction", "timeScale"]);
  });

  test("returns nothing rather than guessing when every column is per-species", () => {
    expect(scalarParamIds([{ id: "secretion", arity: "perSpecies" }])).toEqual(
      [],
    );
  });
});
