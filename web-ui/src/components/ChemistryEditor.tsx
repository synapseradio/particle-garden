// The per-species chemistry grid: one row per active species, one column per
// chemistry field. Reads the live Float32Array by reference and writes edited
// cells straight back into it, exactly as MatrixEditor does — the frame loop
// copies the array into the SpeciesChemistry uniform every frame, so a write
// is live on the next frame.
//
// Every number here comes from Nim: the columns, their ranges, their step and
// precision, and the clamp. This file owns the layout and nothing else. Cell
// readouts go through the shared formatter as "float": both chemistry fields
// are continuous and signed, and each carries its own display precision.

import { createMemo, For, Show } from "solid-js";
import type { ChemistryField } from "../garden-api";
import type { PanelController } from "../state";
import { formatParamValue } from "../lib/format";

interface ChemistryCell {
  species: number;
  field: ChemistryField;
  value: number;
}

export function ChemistryEditor(props: { ctrl: PanelController }) {
  const { api } = props.ctrl;

  const grid = createMemo(() => {
    props.ctrl.chemistryVersion();
    if (!props.ctrl.ready()) return null;
    const species = props.ctrl.params["speciesCount"] ?? 0;
    const fields = api.chemistryFields();
    const stride = api.chemistryStride();
    const values = api.chemistry();
    const rows: { swatch: string; cells: ChemistryCell[] }[] = [];
    for (let index = 0; index < species; index += 1) {
      const cells: ChemistryCell[] = [];
      for (const field of fields) {
        cells.push({
          species: index,
          field,
          value: values[index * stride + field.slot] ?? field.defaultValue,
        });
      }
      rows.push({ swatch: api.speciesColor(index), cells });
    }
    return { fields, rows };
  });

  const editCell = (cell: ChemistryCell, rawText: string) => {
    const parsed = parseFloat(rawText);
    if (Number.isNaN(parsed)) {
      props.ctrl.bumpChemistry(); // re-render resets the input to the live value
      return;
    }
    const clamped = api.clampChemistry(cell.field.id, parsed);
    api.chemistry()[cell.species * api.chemistryStride() + cell.field.slot] =
      clamped;
    props.ctrl.bumpChemistry();
  };

  return (
    <div class="control-group matrix-group">
      <label>Species Chemistry</label>
      <Show when={grid()}>
        {(data) => (
          <>
            <div
              class="chemistry-display"
              style={{
                "grid-template-columns": `auto repeat(${data().fields.length}, 1fr)`,
              }}
            >
              <div class="chemistry-head" />
              <For each={data().fields}>
                {(field) => (
                  <div class="chemistry-head" title={field.hint}>
                    {field.label}
                  </div>
                )}
              </For>
              <For each={data().rows}>
                {(row) => (
                  <>
                    <div
                      class="matrix-cell matrix-header chemistry-swatch"
                      style={{ background: row.swatch }}
                    />
                    <For each={row.cells}>
                      {(cell) => (
                        <div class="matrix-cell chemistry-cell">
                          <input
                            type="number"
                            step={cell.field.step}
                            min={cell.field.min}
                            max={cell.field.max}
                            value={formatParamValue(
                              cell.value,
                              "float",
                              cell.field.precision,
                            )}
                            onChange={(event) =>
                              editCell(cell, event.currentTarget.value)
                            }
                          />
                        </div>
                      )}
                    </For>
                  </>
                )}
              </For>
            </div>
            <For each={data().fields}>
              {(field) => (
                <div class="chemistry-hint">
                  <strong>{field.label}</strong> {field.hint}
                </div>
              )}
            </For>
          </>
        )}
      </Show>
    </div>
  );
}
