// The matrix cell's edit-state machine, pure so the suite can pin it without
// a DOM. An edit belongs to the user until commit: any intermediate text —
// empty included — is held as typed, and only commit parses, clamps, and
// writes. Retyping a number passes through "", "-", "0."; treating those as
// errors and reverting mid-keystroke is the defect this module ends.

export type MatrixEdit = { row: number; col: number; text: string } | null;

/** The text a cell's input shows: the in-progress edit for the one cell
 * being edited, the live buffer's formatted value for every other cell. An
 * external matrix update therefore refreshes the grid without touching what
 * the user is typing. */
export function editText(
  edit: MatrixEdit,
  row: number,
  col: number,
  liveText: string,
): string {
  if (edit && edit.row === row && edit.col === col) return edit.text;
  return liveText;
}

/** Parse a committed edit through the boundary's clamp. Null when the text
 * holds no number: that commit is a revert to the live value, not a write. */
export function commitValue(
  text: string,
  clamp: (value: number) => number,
): number | null {
  const parsed = parseFloat(text);
  if (Number.isNaN(parsed)) return null;
  return clamp(parsed);
}
