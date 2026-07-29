// The help panel: the docs/help markdown Nim serves, rendered through the
// restricted subset. Opened by the panel's "?" button and the "?" key,
// closed by Escape; internal links jump between sections.

import { For, Match, onCleanup, Show, Switch } from "solid-js";
import { Dynamic } from "solid-js/web";
import type { PanelController } from "../state";
import { parseMarkdown, type Block, type Inline } from "../lib/markdown";

function Inlines(props: { inlines: Inline[] }) {
  return (
    <For each={props.inlines}>
      {(inline) => (
        <Switch>
          <Match when={inline.kind === "text"}>{inline.text}</Match>
          <Match when={inline.kind === "em"}>
            <em>{inline.text}</em>
          </Match>
          <Match when={inline.kind === "strong"}>
            <strong>{inline.text}</strong>
          </Match>
          <Match when={inline.kind === "code"}>
            <code>{inline.text}</code>
          </Match>
          <Match when={inline.kind === "link"}>
            <a href={`#help-${(inline as { target: string }).target}`}>
              {inline.text}
            </a>
          </Match>
        </Switch>
      )}
    </For>
  );
}

function Blocks(props: { blocks: Block[] }) {
  return (
    <For each={props.blocks}>
      {(block) => (
        <Switch>
          <Match when={block.kind === "heading"}>
            <Dynamic
              component={`h${(block as { level: number }).level}`}
            >
              <Inlines inlines={(block as { inlines: Inline[] }).inlines} />
            </Dynamic>
          </Match>
          <Match when={block.kind === "paragraph"}>
            <p>
              <Inlines inlines={(block as { inlines: Inline[] }).inlines} />
            </p>
          </Match>
          <Match when={block.kind === "list"}>
            <ul>
              <For each={(block as { items: Inline[][] }).items}>
                {(item) => (
                  <li>
                    <Inlines inlines={item} />
                  </li>
                )}
              </For>
            </ul>
          </Match>
        </Switch>
      )}
    </For>
  );
}

export function HelpPanel(props: {
  ctrl: PanelController;
  open: boolean;
  onClose: () => void;
}) {
  const sections = props.ctrl.api
    .help()
    .map((entry) => ({ key: entry.key, blocks: parseMarkdown(entry.body) }));

  const onKey = (event: KeyboardEvent) => {
    if (event.key === "Escape") props.onClose();
  };
  document.addEventListener("keydown", onKey);
  onCleanup(() => document.removeEventListener("keydown", onKey));

  return (
    <Show when={props.open}>
      <div class="help-panel" role="dialog" aria-label="Help">
        <button class="collapse-btn" onClick={() => props.onClose()}>
          ×
        </button>
        <For each={sections}>
          {(section) => (
            <section id={`help-${section.key}`}>
              <Blocks blocks={section.blocks} />
            </section>
          )}
        </For>
      </div>
    </Show>
  );
}
