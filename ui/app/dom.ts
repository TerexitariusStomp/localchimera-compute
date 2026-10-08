// app/dom.ts — making one element.
//
// Eleven modules had each written this same six-line factory privately, under
// three different names (`mk`, `el`, `mkEl`), and it is the single most-copied
// thing in the dial. Identical in behaviour, they had begun to drift in type:
// one pair of copies took `cls?: string` where the rest took `string | null`,
// which is the narrower claim and would have rejected the `mk("option", null,
// label)` idiom fourteen call sites use.
//
// This is the imperative half of building a panel, and it stays a real
// alternative to app/template.js rather than a lesser one. Reach for `html`
// when the markup is a picture of some state and a redraw may replace it
// wholesale; reach for `mk` when the NODE must persist — an <input> keeps its
// keyboard focus, its selection, and its in-flight pointer drag only as long
// as nobody rebuilds it, and those are exactly the elements a redraw must
// leave alone.
//
// The generic is load-bearing: `mk("input", …)` must come back as an
// HTMLInputElement so a caller can set `.value`, and widening the return to
// HTMLElement breaks that at a dozen sites.

export const mk = <K extends keyof HTMLElementTagNameMap>(
  tag: K, cls?: string | null, text?: string | null,
): HTMLElementTagNameMap[K] => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};
