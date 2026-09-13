// The MIDI section: the Connect switch, the served mappings and a one-line
// summary per row, a rank input where two writers collide, "Map this
// control" learn and its cancel, and export/import of the mapping document.
// Nim owns the row model, validation, the document schema and the shipped
// default; this component owns localStorage under matrixKeys().mapping,
// exactly the split PresetsSection already runs over presets. midiState() and
// midiPorts() carry no push of their own, so both read on the stats push,
// the cadence the excursions they sit beside arrive on.

import { createEffect, createSignal, For, onCleanup, Show } from "solid-js";
import type { PanelController } from "../state";
import type { MappingRow, MappingRowSpec } from "../garden-api";
import {
  collidingTargets,
  isUnresolved,
  midiConnectChecked,
  rowSummary,
  showsRank,
} from "../lib/mapping-editor";

export function MidiSection(props: { ctrl: PanelController; active: boolean }) {
  const { api } = props.ctrl;
  const keys = api.matrixKeys();

  const [rows, setRows] = createSignal<MappingRow[]>(api.mappingRows());
  const [learn, setLearn] = createSignal(api.learnState());
  const [target, setTarget] = createSignal(props.ctrl.descriptors[0]?.id ?? "");
  const [jsonText, setJsonText] = createSignal("");

  // Applied once, at mount: a session that left a mapping in storage takes
  // over from the shipped default the same way an applied preset would.
  // A refused document leaves the mapping as it was — here, the default that
  // was already running before this line.
  const stored = localStorage.getItem(keys.mapping);
  if (stored !== null) {
    const result = api.applyMappingJson(stored);
    if (!result.ok) {
      window.alert(`Could not load the saved MIDI mapping: ${result.error}`);
    }
  }

  // A subscribe pushes the current rows once, so opening the section shows
  // where the mapping already stands. Every push — an edit, an applied
  // document, or a completed learn — is also the ordinary-edit persistence
  // point: the document is re-exported and saved under the served key.
  createEffect(() => {
    if (!props.active) return;
    onCleanup(
      api.onMapping((next) => {
        setRows(next);
        setLearn(api.learnState());
        localStorage.setItem(keys.mapping, api.exportMappingJson());
      }),
    );
  });

  const midiState = () => {
    props.ctrl.stats();
    return api.midiState();
  };
  const ports = () => {
    props.ctrl.stats();
    return api.midiPorts();
  };

  const colliding = () => collidingTargets(rows());
  const rankOf = (row: MappingRow) =>
    row.kind === "write" ? row.rank : row.kind === "tour" ? row.tourRank : 0;

  const report = (result: { ok: boolean; error?: string }, verb: string) => {
    if (!result.ok) {
      window.alert(`Could not ${verb} this mapping: ${result.error}`);
    }
  };

  const setRank = (row: MappingRow, rank: number) => {
    if (!Number.isFinite(rank)) return;
    report(api.setMappingRank(row.index, rank), "reorder");
  };

  const removeRow = (row: MappingRow) => {
    report(api.removeMappingRow(row.index), "remove");
  };

  // The minimum learn slot the editor offers: a write row on a chosen
  // descriptor. Its source arrives empty; armLearn fills it from the next
  // qualifying delivery.
  const armWriteLearn = () => {
    const writeParamId = target();
    if (writeParamId.length === 0) return;
    const slot: MappingRowSpec = {
      kind: "write",
      source: "",
      writeParamId,
      jump: false,
      rank: 1,
    };
    api.armLearn(slot);
    setLearn(api.learnState());
  };

  const cancel = () => {
    api.cancelLearn();
    setLearn(api.learnState());
  };

  const exportToTextarea = () => setJsonText(api.exportMappingJson());
  const importFromTextarea = () =>
    report(api.applyMappingJson(jsonText()), "import");

  return (
    <>
      <div class="control-group">
        <label class="toggle-label">
          <input
            id="midi-connect"
            type="checkbox"
            role="switch"
            checked={midiConnectChecked(midiState())}
            onChange={(event) =>
              event.currentTarget.checked
                ? api.connectMidi()
                : api.disconnectMidi()
            }
          />
          Connect
          <span class="param-hint">
            {" "}
            — a controller becomes mappings this world can be played through
          </span>
        </label>
      </div>
      <div class="audio-state">{midiState()}</div>
      <Show when={midiState() === "Connected"}>
        <For each={ports()}>
          {(port) => <div class="control-group midi-port">{port.name}</div>}
        </For>
      </Show>

      <For each={rows()}>
        {(row) => (
          <div class="control-group mapping-row">
            <span>{rowSummary(row)}</span>
            <Show when={isUnresolved(row)}>
              <span class="mapping-unresolved"> — unresolved</span>
            </Show>
            <Show when={showsRank(row, colliding())}>
              <input
                type="number"
                class="mapping-rank"
                value={rankOf(row)}
                onChange={(event) =>
                  setRank(row, parseInt(event.currentTarget.value, 10))
                }
              />
            </Show>
            <button class="model-btn" onClick={() => removeRow(row)}>
              Remove
            </button>
          </div>
        )}
      </For>

      <div class="control-group">
        <label>
          Map this control
          <span class="param-hint">
            {" "}
            — arms the next move on a controller to bind it here
          </span>
        </label>
        <div class="model-selector">
          <select
            value={target()}
            onChange={(event) => setTarget(event.currentTarget.value)}
          >
            <For each={props.ctrl.descriptors}>
              {(descriptor) => (
                <option value={descriptor.id}>{descriptor.label}</option>
              )}
            </For>
          </select>
          <Show
            when={!learn().armed}
            fallback={
              <button class="model-btn" onClick={cancel}>
                Cancel
              </button>
            }
          >
            <button class="model-btn" onClick={armWriteLearn}>
              Map this control
            </button>
          </Show>
        </div>
        <Show when={learn().armed}>
          <p class="param-hint">Move a control on the controller to bind it.</p>
        </Show>
      </div>

      <div class="control-group">
        <label>Mapping JSON (Export / Import)</label>
        <textarea
          class="preset-json-area"
          rows="6"
          value={jsonText()}
          onInput={(event) => setJsonText(event.currentTarget.value)}
        />
      </div>
      <div class="control-group model-selector">
        <button class="model-btn" onClick={exportToTextarea}>
          Export
        </button>
        <button class="model-btn" onClick={importFromTextarea}>
          Import
        </button>
      </div>
    </>
  );
}
