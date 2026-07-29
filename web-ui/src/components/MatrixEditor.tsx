// The attraction-matrix grid: reads the live Float32Array by reference,
// writes committed cells straight back into it (the GPU reads the buffer
// every frame, so a write is live immediately). Cell colors, clamping, and
// the band's step and precision come from the Nim side; neither the stride
// nor any bound appears as a literal here.
//
// An edit belongs to the user until commit. The in-progress text — empty
// included — is held in a signal and survives external matrix updates; only
// commit parses, clamps through the boundary, and writes. The pure machine
// lives in lib/matrix-cell so the suite pins it without a DOM.

import { createMemo, createSignal, For, Show } from "solid-js";
import type { PanelController } from "../state";
import { commitValue, editText } from "../lib/matrix-cell";
import type { MatrixEdit } from "../lib/matrix-cell";

interface CellData {
  row: number;
  col: number;
  text: string;
  background: string;
}

export function MatrixEditor(props: { ctrl: PanelController }) {
  const { api } = props.ctrl;

  const [edit, setEdit] = createSignal<MatrixEdit>(null);

  const grid = createMemo(() => {
    props.ctrl.matrixVersion();
    if (!props.ctrl.ready()) return null;
    const species = props.ctrl.params["speciesCount"] ?? 0;
    const stride = api.matrixStride();
    const matrix = api.matrix();
    const spec = api.matrixSpec();
    const rows: CellData[][] = [];
    const headers: string[] = [];
    for (let index = 0; index < species; index += 1) {
      headers.push(api.speciesColor(index));
    }
    for (let row = 0; row < species; row += 1) {
      const cells: CellData[] = [];
      for (let col = 0; col < species; col += 1) {
        const value = matrix[row * stride + col] ?? 0;
        cells.push({
          row,
          col,
          text: value.toFixed(spec.precision),
          background: api.matrixCellColor(value),
        });
      }
      rows.push(cells);
    }
    return { species, headers, rows, spec };
  });

  const commitCell = (row: number, col: number, rawText: string) => {
    const value = commitValue(rawText, api.clampMatrixValue);
    if (value !== null) {
      api.matrix()[row * api.matrixStride() + col] = value;
    }
    // A null commit is a revert: the bump below redraws the live value.
    setEdit(null);
    props.ctrl.bumpMatrix();
  };

  return (
    <div class="control-group matrix-group">
      <label>Attraction Matrix</label>
      <Show when={grid()}>
        {(data) => (
          <div
            class="matrix-display"
            style={{
              "grid-template-columns": `repeat(${data().species + 1}, 1fr)`,
            }}
          >
            <div class="matrix-cell matrix-header" />
            <For each={data().headers}>
              {(swatch) => (
                <div
                  class="matrix-cell matrix-header"
                  style={{ background: swatch }}
                />
              )}
            </For>
            <For each={data().rows}>
              {(cells, rowIndex) => (
                <>
                  <div
                    class="matrix-cell matrix-header"
                    style={{ background: data().headers[rowIndex()] }}
                  />
                  <For each={cells}>
                    {(cell) => (
                      <div
                        class="matrix-cell"
                        style={{ background: cell.background }}
                      >
                        <input
                          type="number"
                          min={data().spec.min}
                          max={data().spec.max}
                          step={data().spec.step}
                          value={editText(
                            edit(),
                            cell.row,
                            cell.col,
                            cell.text,
                          )}
                          onInput={(event) =>
                            setEdit({
                              row: cell.row,
                              col: cell.col,
                              text: event.currentTarget.value,
                            })
                          }
                          onChange={(event) =>
                            commitCell(
                              cell.row,
                              cell.col,
                              event.currentTarget.value,
                            )
                          }
                          onBlur={() => setEdit(null)}
                        />
                      </div>
                    )}
                  </For>
                </>
              )}
            </For>
          </div>
        )}
      </Show>
    </div>
  );
}
