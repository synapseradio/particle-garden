// The per-species chemistry grid: one row per active species, one column per
// per-species descriptor. Reads the live Float32Array by reference and writes
// edited cells straight back into it, exactly as MatrixEditor does — the frame
// loop copies the array into the SpeciesChemistry uniform every frame, so a
// write is live on the next frame.
//
// The columns are ordinary descriptors that happen to carry paPerSpecies, so
// their label, range, step, precision, hint and clamp arrive the same way a
// slider's do. This file owns the layout and nothing else: it renders a grid
// row where ParamSlider renders a track, and that branch is the only thing
// the cardinality changes.

import { createMemo, For, Show } from "solid-js";
import type { PerSpeciesParam } from "../garden-api";
import type { PanelController } from "../state";
import { formatParamValue } from "../lib/format";

interface ChemistryCell {
  species: number;
  column: PerSpeciesParam;
  value: number;
}

export function ChemistryEditor(props: {
  ctrl: PanelController;
  ids: string[];
}) {
  const { api } = props.ctrl;

  // Narrowing on the arity is what makes `slot` reachable: a scalar descriptor
  // has none, and indexing the array without one would alias every column onto
  // the first value of each species.
  const columns = createMemo(() =>
    props.ids
      .map((id) => props.ctrl.byId.get(id))
      .filter((entry): entry is PerSpeciesParam => entry?.arity === "perSpecies"),
  );

  const grid = createMemo(() => {
    props.ctrl.chemistryVersion();
    if (!props.ctrl.ready()) return null;
    const species = props.ctrl.params["speciesCount"] ?? 0;
    const stride = api.chemistryStride();
    const values = api.chemistry();
    const rows: { swatch: string; cells: ChemistryCell[] }[] = [];
    for (let index = 0; index < species; index += 1) {
      const cells: ChemistryCell[] = [];
      for (const column of columns()) {
        cells.push({
          species: index,
          column,
          value: values[index * stride + column.slot] ?? column.defaultValue,
        });
      }
      rows.push({ swatch: api.speciesColor(index), cells });
    }
    return { columns: columns(), rows };
  });

  const editCell = (cell: ChemistryCell, rawText: string) => {
    const parsed = parseFloat(rawText);
    if (Number.isNaN(parsed)) {
      props.ctrl.bumpChemistry(); // re-render resets the input to the live value
      return;
    }
    const clamped = api.clampParam(cell.column.id, parsed);
    api.chemistry()[cell.species * api.chemistryStride() + cell.column.slot] =
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
                "grid-template-columns": `auto repeat(${data().columns.length}, 1fr)`,
              }}
            >
              <div class="chemistry-head" />
              <For each={data().columns}>
                {(column) => (
                  <div class="chemistry-head" title={column.hint}>
                    {column.label}
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
                            step={cell.column.step}
                            min={cell.column.min}
                            max={cell.column.max}
                            value={formatParamValue(
                              cell.value,
                              cell.column.kind,
                              cell.column.precision,
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
            <For each={data().columns}>
              {(column) => (
                <div class="chemistry-hint">
                  <strong>{column.label}</strong> {column.hint}
                </div>
              )}
            </For>
          </>
        )}
      </Show>
    </div>
  );
}
