// Collapsible section, matching the old panel's section-header/-content
// markup. Collapse state is Solid-local; sections start collapsed like the
// old panel's inline display:none, unless the caller opens them.
//
// defaultOpen is read once, at mount. Mode-gated sections are wrapped in
// <Show>, so a mode switch unmounts and remounts them — the section reopens
// for its own mode while a manual collapse still sticks within that mode.

import { createSignal, Show, type JSX } from "solid-js";

export function Section(props: {
  title: string;
  defaultOpen?: boolean;
  children: JSX.Element;
}) {
  const [open, setOpen] = createSignal(props.defaultOpen ?? false);
  return (
    <div class="control-section">
      <button class="section-header" onClick={() => setOpen(!open())}>
        {props.title} <span class="section-toggle">{open() ? "−" : "+"}</span>
      </button>
      <Show when={open()}>
        <div class="section-content">{props.children}</div>
      </Show>
    </div>
  );
}
