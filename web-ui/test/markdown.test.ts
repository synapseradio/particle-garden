import { describe, expect, test } from "bun:test";
import { parseInlines, parseMarkdown } from "../src/lib/markdown";

describe("the restricted markdown subset parses", () => {
  test("headings at levels one through three", () => {
    const blocks = parseMarkdown("# One\n## Two\n### Three");
    expect(blocks).toEqual([
      { kind: "heading", level: 1, inlines: [{ kind: "text", text: "One" }] },
      { kind: "heading", level: 2, inlines: [{ kind: "text", text: "Two" }] },
      { kind: "heading", level: 3, inlines: [{ kind: "text", text: "Three" }] },
    ]);
  });

  test("paragraph lines join; a blank line separates paragraphs", () => {
    const blocks = parseMarkdown("first line\nsecond line\n\nnext");
    expect(blocks.length).toBe(2);
    expect(blocks[0]).toEqual({
      kind: "paragraph",
      inlines: [{ kind: "text", text: "first line second line" }],
    });
  });

  test("consecutive dashed lines form one list", () => {
    const blocks = parseMarkdown("- a\n- b\n\n- c");
    expect(blocks.length).toBe(2);
    expect(blocks[0].kind).toBe("list");
    expect((blocks[0] as { items: unknown[] }).items.length).toBe(2);
  });

  test("emphasis, strong, and code spans", () => {
    expect(parseInlines("a *b* **c** `d`")).toEqual([
      { kind: "text", text: "a " },
      { kind: "em", text: "b" },
      { kind: "text", text: " " },
      { kind: "strong", text: "c" },
      { kind: "text", text: " " },
      { kind: "code", text: "d" },
    ]);
  });

  test("an internal link carries its target", () => {
    expect(parseInlines("see [the glossary](#glossary)")).toEqual([
      { kind: "text", text: "see " },
      { kind: "link", text: "the glossary", target: "glossary" },
    ]);
  });
});

describe("markup outside the subset stays literal text", () => {
  test("an external link is not a link", () => {
    const inlines = parseInlines("go to [site](https://example.com) now");
    expect(inlines.every((inline) => inline.kind !== "link")).toBe(true);
  });

  test("html and images pass through as text", () => {
    expect(parseInlines("<b>bold</b>")).toEqual([
      { kind: "text", text: "<b>bold</b>" },
    ]);
    const image = parseInlines("![alt](pic.png)");
    expect(image.every((inline) => inline.kind === "text")).toBe(true);
  });

  test("a level-four heading reads as a paragraph", () => {
    const blocks = parseMarkdown("#### deep");
    expect(blocks[0].kind).toBe("paragraph");
  });
});
