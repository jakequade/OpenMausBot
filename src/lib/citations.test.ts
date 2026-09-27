import { describe, expect, it } from "vitest";
import { composeMessage, isAttachment } from "./composer-attachments";
import {
  citationAttachment,
  citationFallback,
  citationPreviewText,
  createCitationTextSelector,
  findCitationText,
  serializeCitation,
  splitTranscriptCitations,
  withCitationComment,
} from "./citations";

const source = { ownerType: "bot" as const, ownerId: "bot-1", threadId: "thread-1", messageId: "message-1" };

describe("selected-text citations", () => {
  it("round-trips multiline Unicode and code without changing the immutable quote", () => {
    const text = "Before\nconst greeting = \"G'day 🐭\";\n  return greeting;\nAfter";
    const start = text.indexOf("const");
    const selector = createCitationTextSelector(text, start, text.indexOf("\nAfter"))!;
    const original = citationAttachment(source, selector, "Explain the indentation");
    const edited = withCitationComment(original, "  Check Unicode too  ");
    const stored = composeMessage("Please review", [edited]);
    const parsed = splitTranscriptCitations(stored);

    expect(parsed.display).toBe("Please review");
    expect(parsed.citations).toEqual([edited]);
    expect(parsed.citations[0]!.quote).toBe("const greeting = \"G'day 🐭\";\n  return greeting;");
    expect(parsed.citations[0]!.source).toEqual(original.source);
    expect(parsed.citations[0]!.comment).toBe("Check Unicode too");
    expect(stored).toContain(citationFallback(edited));
    expect(stored).toContain(">   return greeting;");
  });

  it("keeps each citation readable and ordered in the exact prompt used by sends, queues, and steers", () => {
    const first = citationAttachment(source, createCitationTextSelector("alpha beta", 0, 5)!, "first note");
    const second = citationAttachment({ ...source, messageId: "message-2" }, createCitationTextSelector("γamma delta", 0, 5)!);
    const prompt = composeMessage("Compare these", [first, second]);
    expect(prompt.indexOf("Compare these")).toBeLessThan(prompt.indexOf("> alpha"));
    expect(prompt.indexOf("> alpha")).toBeLessThan(prompt.indexOf("> γamma"));
    expect(prompt).toContain("Comment:\nfirst note");
    expect(splitTranscriptCitations(prompt).citations).toEqual([first, second]);
    expect(citationPreviewText(prompt)).toBe("Compare these alpha — first note γamma");
  });

  it("leaves malformed or altered serialized data visible instead of trusting it", () => {
    const citation = citationAttachment(source, createCitationTextSelector("quoted text", 0, 11)!);
    const serialized = serializeCitation(citation);
    expect(splitTranscriptCitations(serialized.replace("Quoted message", "Changed message"))).toEqual({
      display: serialized.replace("Quoted message", "Changed message"),
      citations: [],
    });
    expect(splitTranscriptCitations("<!--omb-citation-v1:not-json-->\n> Quoted message:\n> unsafe")).toEqual({
      display: "<!--omb-citation-v1:not-json-->\n> Quoted message:\n> unsafe",
      citations: [],
    });
    expect(isAttachment({ ...citation, quote: "" })).toBe(false);
  });

  it("does not parse a serialized citation nested inside quoted or comment content", () => {
    const inner = citationAttachment(source, createCitationTextSelector("inner quote", 0, 11)!);
    const outer = citationAttachment(
      { ...source, messageId: "outer" },
      createCitationTextSelector("outer quote", 0, 11)!,
      serializeCitation(inner),
    );
    expect(splitTranscriptCitations(serializeCitation(outer))).toEqual({ display: "", citations: [outer] });
  });

  it("resolves one repeated quote only with unique context and never guesses an ambiguous occurrence", () => {
    const text = "left repeated right; other repeated ending";
    const start = text.lastIndexOf("repeated");
    const selector = createCitationTextSelector(text, start, start + "repeated".length)!;
    expect(findCitationText(text, selector)).toEqual({ start, end: start + 8 });
    expect(findCitationText("repeated and repeated", { text: "repeated", start: 99, end: 107, prefix: "", suffix: "" })).toBeNull();
    expect(findCitationText("source was deleted", selector)).toBeNull();
  });
});
