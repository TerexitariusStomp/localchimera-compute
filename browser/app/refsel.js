// Naming an element so a maintainer can find it again.
//
// The feedback lane lets someone point at a piece of the interface and say
// what they mean about it. That reference has to survive the trip: stored as
// text in a JSON body, read later by a maintainer, and — while the visitor is
// still on the page — turned back into the element to flash it.
//
// Pure tree-walking, no document, so the rules are testable: an id anchors
// and stops the climb, classes are capped at two, a tag that repeats among
// its siblings takes an :nth-of-type, and the whole chain caps at six hops.
//
// A selector is BEST EFFORT. Six hops with no id anchor is relative, so it
// can match an equivalent subtree elsewhere; the label beside it is what
// makes a reference legible to a person, and the person is the reader that
// matters. Everything here refuses rather than guesses: a name CSS cannot
// address is dropped from the selector instead of being spliced in, because
// an invalid selector makes querySelector THROW and a thrown selector takes
// the click handler with it.
const MAX_HOPS = 6;
const MAX_CLASSES = 2;
// A CSS identifier we are willing to splice unescaped: letters, digits,
// hyphen, underscore, not starting with a digit. Everything else — colons,
// slashes, dots inside a name, spaces — is refused.
const SAFE = /^[A-Za-z_-][A-Za-z0-9_-]*$/;
const safeName = (s) => s && SAFE.test(s) ? s : null;
/** The dial's svg layers say what they are here and nowhere else in the DOM. */
const layerOf = (el) => safeName(el.getAttribute?.("data-layer"));
/** How this element addresses itself, if it does at all. */
const selfName = (el) => {
    const id = safeName(el.id);
    if (id)
        return `#${id}`;
    const tag = safeName(el.tagName)?.toLowerCase();
    if (!tag)
        return null;
    const layer = layerOf(el);
    if (layer)
        return `${tag}[data-layer="${layer}"]`;
    const cls = classesOf(el);
    return cls.length ? `${tag}.${cls.join(".")}` : null;
};
const classesOf = (el) => {
    const out = [];
    for (let i = 0; i < el.classList.length && out.length < MAX_CLASSES; i++) {
        const c = safeName(el.classList.item(i));
        if (c)
            out.push(c);
    }
    return out;
};
/**
 * A selector that finds EL again, climbing until STOP (exclusive), an id, or
 * the hop cap. Returns "" when nothing addressable can be said about it.
 */
export function selectorFor(el, stop) {
    const parts = [];
    let cur = el;
    while (cur && cur !== stop && parts.length < MAX_HOPS) {
        const id = safeName(cur.id);
        if (id) {
            parts.unshift(`#${id}`);
            break;
        }
        const tag = safeName(cur.tagName);
        if (!tag)
            break;
        const layer = layerOf(cur);
        let part = layer ? `${tag.toLowerCase()}[data-layer="${layer}"]`
            : tag.toLowerCase();
        const cls = layer ? [] : classesOf(cur);
        if (cls.length)
            part += "." + cls.join(".");
        const parent = cur.parentElement;
        if (parent) {
            // :nth-of-type counts among siblings sharing the tag — so it is worth
            // adding exactly when the tag repeats there
            let n = 0, mine = 0;
            for (let i = 0; i < parent.children.length; i++) {
                const sib = parent.children[i];
                if (sib.tagName !== cur.tagName)
                    continue;
                n++;
                if (sib === cur)
                    mine = n;
            }
            if (n > 1 && mine > 0)
                part += `:nth-of-type(${mine})`;
        }
        parts.unshift(part);
        cur = parent;
    }
    return parts.join(" > ");
}
/**
 * What a person reads on the chip, and what a maintainer reads in the pool.
 *
 * Both halves earn their place: the id or class is how you FIND the thing in
 * the source, and the visible text is how you recognise the thing that was
 * pointed at — someone aiming at a pill saw the word on it, not its class.
 * So a named element that also carries text says both.
 */
export function labelFor(el) {
    const tag = el.tagName.toLowerCase();
    const layer = el.getAttribute?.("data-layer");
    const name = el.id ? `#${el.id}`
        : layer ? `${tag}[${layer}]`
            : (el.classList.item(0) ? `${tag}.${el.classList.item(0)}` : tag);
    const text = (el.textContent || "").trim().replace(/\s+/g, " ");
    if (!text)
        return name;
    const short = text.length > 18 ? text.slice(0, 18) + "…" : text;
    return `${name} “${short}”`;
}
/**
 * The nearest ancestor that says what it is — what to grep for when the
 * element itself is anonymous.
 *
 * A `<path>` inside the wheel names nothing: the selector can address it by
 * counting, but counting does not tell a maintainer which module drew it. The
 * enclosing named thing does, and for the dial's svg that is the layer. Empty
 * when the element already names itself.
 */
export function withinFor(el, stop) {
    if (selfName(el))
        return "";
    let cur = el.parentElement;
    let hops = 0;
    while (cur && cur !== stop && hops++ < MAX_HOPS) {
        const name = selfName(cur);
        if (name)
            return name;
        cur = cur.parentElement;
    }
    return "";
}
