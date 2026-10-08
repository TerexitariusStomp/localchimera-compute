// app/esc.ts — text into markup.
//
// Its own few lines, so a module that prints or builds a page string loads
// where there is no page: template.ts reaches the theme, and the theme reaches
// the document. template.ts re-exports `esc`, so the faces keep one door.

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** TEXT with the characters markup reads, written as text. */
export const esc = (s: unknown): string => String(s ?? "").replace(/[&<>"']/g, c => ESCAPES[c]);
