// The attraction-matrix grid: reads the live Float32Array by reference,
// writes edited cells straight back into it (the GPU reads the buffer every
// frame, so a write is live immediately). Cell colors and clamping come
// from the Nim side; the stride never appears as a literal here.

import { createMemo, For, Show } from "solid-js";
import type { PanelController } from "../state";

interface CellData {
  row: number;
  col: number;
  value: number;
  background: string;
}

export function MatrixEditor(props: { ctrl: PanelController }) {
  const { api } = props.ctrl;

  const grid = createMemo(() => {
    props.ctrl.matrixVersion();
    if (!props.ctrl.ready()) return null;
    const species = props.ctrl.params["speciesCount"] ?? 0;
    const stride = api.matrixStride();
    const matrix = api.matrix();
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
          value,
          background: api.matrixCellColor(value),
        });
      }
      rows.push(cells);
    }
    return { species, headers, rows };
  });

  const editCell = (row: number, col: number, rawText: string) => {
    const parsed = parseFloat(rawText);
    if (Number.isNaN(parsed)) {
      props.ctrl.bumpMatrix(); // re-render resets the input to the live value
      return;
    }
    const clamped = api.clampMatrixValue(parsed);
    api.matrix()[row * api.matrixStride() + col] = clamped;
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
                          step="0.1"
                          value={cell.value.toFixed(2)}
                          onChange={(event) =>
                            editCell(cell.row, cell.col, event.currentTarget.value)
                          }
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
