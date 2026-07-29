// Restricted markdown for the help panel: headings (1-3), paragraphs,
// unordered lists, emphasis, strong, code spans, and internal links
// ([text](#target)). Markup outside the subset renders as literal text.
// Pure: parse only; the panel maps blocks to elements.

export type Inline =
  | { kind: "text"; text: string }
  | { kind: "em"; text: string }
  | { kind: "strong"; text: string }
  | { kind: "code"; text: string }
  | { kind: "link"; text: string; target: string };

export type Block =
  | { kind: "heading"; level: number; inlines: Inline[] }
  | { kind: "paragraph"; inlines: Inline[] }
  | { kind: "list"; items: Inline[][] };

const INLINE_PATTERN =
  /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(\[[^\]]+\]\(#[^)\s]+\))/g;

export function parseInlines(text: string): Inline[] {
  const inlines: Inline[] = [];
  let cursor = 0;
  for (const match of text.matchAll(INLINE_PATTERN)) {
    const start = match.index ?? 0;
    if (start > cursor) {
      inlines.push({ kind: "text", text: text.slice(cursor, start) });
    }
    const token = match[0];
    if (token.startsWith("`")) {
      inlines.push({ kind: "code", text: token.slice(1, -1) });
    } else if (token.startsWith("**")) {
      inlines.push({ kind: "strong", text: token.slice(2, -2) });
    } else if (token.startsWith("*")) {
      inlines.push({ kind: "em", text: token.slice(1, -1) });
    } else {
      const link = /^\[([^\]]+)\]\(#([^)\s]+)\)$/.exec(token);
      if (link) {
        inlines.push({ kind: "link", text: link[1], target: link[2] });
      }
    }
    cursor = start + token.length;
  }
  if (cursor < text.length) {
    inlines.push({ kind: "text", text: text.slice(cursor) });
  }
  return inlines;
}

export function parseMarkdown(source: string): Block[] {
  const blocks: Block[] = [];
  let paragraph: string[] = [];
  let list: Inline[][] | null = null;

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      blocks.push({ kind: "paragraph", inlines: parseInlines(paragraph.join(" ")) });
      paragraph = [];
    }
  };
  const flushList = () => {
    if (list) {
      blocks.push({ kind: "list", items: list });
      list = null;
    }
  };

  for (const rawLine of source.split("\n")) {
    const line = rawLine.trimEnd();
    const heading = /^(#{1,3}) (.+)$/.exec(line);
    if (heading) {
      flushParagraph();
      flushList();
      blocks.push({
        kind: "heading",
        level: heading[1].length,
        inlines: parseInlines(heading[2]),
      });
    } else if (line.startsWith("- ")) {
      flushParagraph();
      list = list ?? [];
      list.push(parseInlines(line.slice(2)));
    } else if (line.trim() === "") {
      flushParagraph();
      flushList();
    } else {
      flushList();
      paragraph.push(line.trim());
    }
  }
  flushParagraph();
  flushList();
  return blocks;
}
