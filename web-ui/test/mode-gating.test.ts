import { describe, expect, test } from "bun:test";
import {
  filterVisibleIds,
  groupParamIds,
  isGroupVisible,
  isModeExclusiveGroup,
  visibleGroups,
  type GatedMode,
  type GatedParam,
} from "../src/lib/mode-gating";

// The group taxonomy the Nim side serves through simModes(). Membership is
// Nim's to decide; these fixtures only mirror it closely enough that a
// regression in the gating arithmetic reads as a real panel bug.
const modes: GatedMode[] = [
  {
    id: "particle-life",
    groups: [
      "simulation",
      "grid",
      "particle-life",
      "force-model",
      "force-polynomial",
      "force-exponential",
      "matrix",
      "render",
      "glow",
      "bloom",
      "palette",
    ],
  },
  {
    id: "sph",
    groups: ["simulation", "grid", "sph", "render", "glow", "bloom", "palette"],
  },
  {
    id: "reaction-diffusion",
    groups: [
      "simulation",
      "rd",
      "rd-field",
      "render",
      "glow",
      "bloom",
      "palette",
    ],
  },
];

// What a stale web/app.js serves: modes without the groups field at all.
const ungroupedModes: GatedMode[] = [
  { id: "particle-life" },
  { id: "sph" },
  { id: "reaction-diffusion" },
];

const descriptors: GatedParam[] = [
  { id: "particleCount", group: "simulation" },
  { id: "speciesCount", group: "simulation" },
  { id: "interactionRadius", group: "grid" },
  { id: "forceStrength", group: "particle-life" },
  { id: "friction", group: "simulation" },
  { id: "timeScale", group: "simulation" },
  { id: "ruleTemperature", group: "particle-life" },
  { id: "rdFeed", group: "rd" },
  { id: "rdKill", group: "rd" },
  { id: "fieldOpacity", group: "rd-field" },
];

describe("visibleGroups", () => {
  test("returns the active mode's own group set", () => {
    expect(visibleGroups(modes, "sph")).toEqual(
      new Set(["simulation", "grid", "sph", "render", "glow", "bloom", "palette"]),
    );
  });

  test("returns null when the active mode serves no groups", () => {
    expect(visibleGroups(ungroupedModes, "sph")).toBeNull();
  });

  test("returns null when the active mode id matches no served mode", () => {
    expect(visibleGroups(modes, "no-such-mode")).toBeNull();
  });

  test("returns null when no modes are served at all", () => {
    expect(visibleGroups([], "sph")).toBeNull();
  });
});

describe("isGroupVisible", () => {
  test("hides the matrix from SPH", () => {
    expect(isGroupVisible(modes, "sph", "matrix")).toBe(false);
  });

  test("keeps the grid group in SPH, which needs interactionRadius", () => {
    expect(isGroupVisible(modes, "sph", "grid")).toBe(true);
  });

  test("hides the grid group from reaction-diffusion", () => {
    expect(isGroupVisible(modes, "reaction-diffusion", "grid")).toBe(false);
  });

  test("shows every mode the groups it lists", () => {
    expect(isGroupVisible(modes, "particle-life", "matrix")).toBe(true);
    expect(isGroupVisible(modes, "reaction-diffusion", "rd")).toBe(true);
    expect(isGroupVisible(modes, "sph", "rd")).toBe(false);
  });

  test("shows shared groups in all three modes", () => {
    for (const mode of modes) {
      expect(isGroupVisible(modes, mode.id, "simulation")).toBe(true);
      expect(isGroupVisible(modes, mode.id, "palette")).toBe(true);
    }
  });

  test("fails open, showing every group when no groups are served", () => {
    expect(isGroupVisible(ungroupedModes, "sph", "matrix")).toBe(true);
    expect(isGroupVisible(ungroupedModes, "sph", "rd")).toBe(true);
    expect(isGroupVisible([], "sph", "matrix")).toBe(true);
  });
});

describe("isModeExclusiveGroup", () => {
  test("is true for a group only the active mode lists", () => {
    expect(isModeExclusiveGroup(modes, "reaction-diffusion", "rd")).toBe(true);
    expect(isModeExclusiveGroup(modes, "sph", "sph")).toBe(true);
    expect(isModeExclusiveGroup(modes, "particle-life", "force-model")).toBe(
      true,
    );
  });

  test("is false for a group another mode also lists", () => {
    expect(isModeExclusiveGroup(modes, "sph", "grid")).toBe(false);
    expect(isModeExclusiveGroup(modes, "sph", "simulation")).toBe(false);
  });

  test("is false for a group the active mode does not list", () => {
    expect(isModeExclusiveGroup(modes, "sph", "rd")).toBe(false);
  });

  test("fails closed, auto-expanding nothing when no groups are served", () => {
    expect(isModeExclusiveGroup(ungroupedModes, "sph", "sph")).toBe(false);
  });

  test("fails closed when only some modes serve groups", () => {
    const partial: GatedMode[] = [{ id: "sph", groups: ["sph"] }, { id: "x" }];
    expect(isModeExclusiveGroup(partial, "sph", "sph")).toBe(false);
  });
});

describe("groupParamIds", () => {
  test("returns the group's ids in descriptor order", () => {
    expect(groupParamIds(descriptors, "rd")).toEqual(["rdFeed", "rdKill"]);
    expect(groupParamIds(descriptors, "particle-life")).toEqual([
      "forceStrength",
      "ruleTemperature",
    ]);
  });

  test("returns an empty list for a group no descriptor claims", () => {
    expect(groupParamIds(descriptors, "matrix")).toEqual([]);
  });
});

describe("filterVisibleIds", () => {
  const ordered = [
    "particleCount",
    "speciesCount",
    "interactionRadius",
    "forceStrength",
    "friction",
    "timeScale",
    "ruleTemperature",
  ];

  test("preserves caller order while dropping hidden groups", () => {
    expect(filterVisibleIds(descriptors, modes, "sph", ordered)).toEqual([
      "particleCount",
      "speciesCount",
      "interactionRadius",
      "friction",
      "timeScale",
    ]);
  });

  test("drops the grid slider too in reaction-diffusion", () => {
    expect(
      filterVisibleIds(descriptors, modes, "reaction-diffusion", ordered),
    ).toEqual(["particleCount", "speciesCount", "friction", "timeScale"]);
  });

  test("keeps every slider in particle-life", () => {
    expect(filterVisibleIds(descriptors, modes, "particle-life", ordered)).toEqual(
      ordered,
    );
  });

  test("fails open, keeping every id when no groups are served", () => {
    expect(
      filterVisibleIds(descriptors, ungroupedModes, "sph", ordered),
    ).toEqual(ordered);
  });

  test("keeps an id no descriptor claims rather than swallowing it", () => {
    expect(filterVisibleIds(descriptors, modes, "sph", ["mystery"])).toEqual([
      "mystery",
    ]);
  });
});
