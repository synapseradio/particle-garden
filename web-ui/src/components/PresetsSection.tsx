// Presets UI over the hybrid boundary: gardenAPI snapshots/validates/applies
// (Nim owns the schema and apply order), this component owns localStorage
// under the same pg.presets.* keys the old panel used, so presets saved
// before the port keep loading.

import { createSignal, For } from "solid-js";
import type { PanelController } from "../state";
import {
  nameIsReserved,
  presetExists,
  readIndex,
  readPreset,
  writePreset,
} from "../lib/presets";

export function PresetsSection(props: { ctrl: PanelController }) {
  const { api } = props.ctrl;
  const keys = api.presetKeys();
  const [names, setNames] = createSignal(readIndex(localStorage, keys));
  const [selected, setSelected] = createSignal("");
  const [jsonText, setJsonText] = createSignal("");

  const selectedOrDefault = () =>
    selected().length > 0 ? selected() : keys.defaultName;

  const save = () => {
    const entered = window.prompt("Preset name:", selectedOrDefault());
    if (entered === null) return;
    const name = api.normalizePresetName(entered);
    if (name.length === 0) {
      window.alert("Preset name cannot be empty.");
      return;
    }
    if (nameIsReserved(keys, name)) {
      window.alert(
        `The name "${name}" is reserved; please choose a different name.`,
      );
      return;
    }
    if (
      presetExists(localStorage, keys, name) &&
      !window.confirm(`A preset named "${name}" already exists. Overwrite it?`)
    ) {
      return;
    }
    writePreset(localStorage, keys, name, api.exportPresetJson(name));
    setNames(readIndex(localStorage, keys));
  };

  const load = () => {
    const name = selected();
    if (name.length === 0) {
      window.alert("Select a preset to load first.");
      return;
    }
    const json = readPreset(localStorage, keys, name);
    if (json === null) {
      window.alert(`No preset named "${name}" was found.`);
      return;
    }
    const result = props.ctrl.applyPresetJson(json);
    if (!result.ok) {
      window.alert(`Could not load preset "${name}": ${result.error}`);
    }
  };

  const exportToTextarea = () => {
    setJsonText(api.exportPresetJsonPretty(selectedOrDefault()));
  };

  const importFromTextarea = () => {
    const result = props.ctrl.applyPresetJson(jsonText());
    if (!result.ok) {
      window.alert(`Could not import preset: ${result.error}`);
    }
  };

  return (
    <>
      <div class="control-group">
        <label>Saved Presets</label>
        <select
          class="preset-list"
          value={selected()}
          onChange={(event) => setSelected(event.currentTarget.value)}
        >
          <For each={names()}>
            {(name) => <option value={name}>{name}</option>}
          </For>
        </select>
      </div>

      <div class="control-group model-selector">
        <button class="model-btn" onClick={load}>
          Load
        </button>
        <button class="model-btn" onClick={save}>
          Save
        </button>
        <button class="model-btn" onClick={exportToTextarea}>
          Export
        </button>
        <button class="model-btn" onClick={importFromTextarea}>
          Import
        </button>
      </div>

      <div class="control-group">
        <label>Preset JSON (Export / Import)</label>
        <textarea
          class="preset-json-area"
          rows="6"
          value={jsonText()}
          onInput={(event) => setJsonText(event.currentTarget.value)}
        />
      </div>
    </>
  );
}
