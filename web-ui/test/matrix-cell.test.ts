import { describe, expect, test } from "bun:test";
import { commitValue, editText } from "../src/lib/matrix-cell";
import type { MatrixEdit } from "../src/lib/matrix-cell";

// The clamp stands in for gardenAPI.clampMatrixValue: the boundary owns the
// bounds, the edit machine only routes values through whatever clamp it is
// handed. Mock written against the gardenAPI surface as of this suite.
const clamp = (value: number) => Math.max(-0.1, Math.min(0.1, value));

describe("a cell edit belongs to the user until commit", () => {
  test("an edit holds any intermediate text, including empty", () => {
    // Retyping a number passes through "", "-", "0."; treating any of them
    // as an error and reverting is the defect this machine exists to end.
    expect(editText({ row: 1, col: 2, text: "" }, 1, 2, "0.100")).toBe("");
    expect(editText({ row: 1, col: 2, text: "-" }, 1, 2, "0.100")).toBe("-");
    expect(editText({ row: 1, col: 2, text: "0.0" }, 1, 2, "0.100")).toBe(
      "0.0",
    );
  });

  test("an external update refreshes every cell but the one being edited", () => {
    const edit: MatrixEdit = { row: 1, col: 2, text: "0.05" };
    expect(editText(edit, 1, 2, "0.100")).toBe("0.05");
    expect(editText(edit, 0, 0, "-0.020")).toBe("-0.020");
    expect(editText(edit, 1, 0, "0.030")).toBe("0.030");
    expect(editText(null, 1, 2, "0.100")).toBe("0.100");
  });

  test("commit parses and clamps through the boundary's clamp", () => {
    expect(commitValue("0.05", clamp)).toBe(0.05);
    expect(commitValue("0.25", clamp)).toBe(0.1);
    expect(commitValue("-1", clamp)).toBe(-0.1);
    expect(commitValue("  0.02 ", clamp)).toBe(0.02);
  });

  test("a commit that holds no number is a revert, not a write", () => {
    expect(commitValue("", clamp)).toBeNull();
    expect(commitValue("-", clamp)).toBeNull();
    expect(commitValue("abc", clamp)).toBeNull();
  });
});
