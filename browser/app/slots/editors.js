// app/slots/editors.ts — the inline building blocks, framework-free.
//
// The free-association editing grammar, translated from Svelte runes to
// plain DOM + our signals: NO save button anywhere — every commit is a
// keystroke (choices) or a blur (text); toggle pills, not multi-selects;
// −/+ steppers around quantities; presets first, "custom…" last; every
// "add" seeds a working value, nothing starts blank. Each builder returns
// a DOM element and calls onChange(newValue) — the caller owns the slot
// object and the immutable-copy discipline (edit → copy → declare).
import { DAYS, DAY_LETTERS, TIME_PRESETS, DAY_PRESETS, seedArc, MONTHS_SHORT, WEEK_ORDINALS, TIME_MODES, DAY_MODES, MONTH_MODES, WEEK_MODES, timeModeOf, dayModeOf, monthModeOf, weekModeOf } from './model.js';
import { mk as el } from '../dom.js';
import { spoken, spanSentence } from './declarations.js';
// text that commits on blur (and Enter), only when actually changed
/**
 * Arm, then confirm — the two-tap destructive control, no modal. The first tap
 * arms the element (its text becomes `armed`, class `arm`) for `ms`; a second
 * tap inside that window runs `onConfirm`; silence disarms it. ONE shape for a
 * slot's delete, a grant's recall and the lent rail's recall alike.
 */
export function armTwice(btn, o) {
    let armed = false, timer = 0;
    const disarm = () => { armed = false; btn.textContent = o.rest; btn.classList.remove("arm"); };
    btn.textContent = o.rest;
    btn.addEventListener("click", () => {
        if (armed) {
            clearTimeout(timer);
            disarm();
            o.onConfirm();
            return;
        }
        armed = true;
        btn.textContent = o.armed;
        btn.classList.add("arm");
        timer = window.setTimeout(disarm, o.ms ?? 3000);
    });
}
export function inlineText(value, { placeholder = "", cls = "", onCommit }) {
    const i = el("input", "sl-in " + cls);
    i.type = "text";
    i.value = value || "";
    i.placeholder = placeholder;
    i.addEventListener("keydown", ev => { if (ev.key === "Enter")
        i.blur(); });
    // a blur commits only a CHANGE — measured against what was last committed,
    // so an edit back to the original value is a change too
    let last = value || "";
    i.addEventListener("blur", () => {
        if (i.value !== last) {
            last = i.value;
            onCommit(i.value);
        }
    });
    return i;
}
// −/+ stepper around a live number input (their QuantityInput)
export function qtyStepper(value, { min = 0, step = 1, onCommit }) {
    const wrap = el("span", "sl-qty");
    const minus = el("button", "sl-step", "−");
    const input = el("input", "sl-qtyin");
    input.type = "number";
    input.min = String(min);
    input.step = String(step);
    input.value = String(value);
    const plus = el("button", "sl-step", "＋");
    const commit = (v) => { const n = Math.max(min, Number(v) || 0); input.value = String(n); onCommit(n); };
    minus.addEventListener("click", () => commit(Number(input.value) - step));
    plus.addEventListener("click", () => commit(Number(input.value) + step));
    input.addEventListener("change", () => commit(input.value));
    wrap.append(minus, input, plus);
    return wrap;
}
// the seven M-T-W-T-F-S-S toggle pills (the dial's own dayPicker grammar)
export function dayPills(days, { onCommit }) {
    const row = el("span", "sl-days");
    const set = new Set(days || []);
    DAYS.forEach((d, i) => {
        const p = el("a", "sl-day" + (set.has(d) ? " on" : ""), DAY_LETTERS[i]);
        p.title = d;
        p.addEventListener("click", () => {
            if (set.has(d))
                set.delete(d);
            else
                set.add(d);
            onCommit(DAYS.filter(x => set.has(x))); // canonical order
        });
        row.appendChild(p);
    });
    return row;
}
// the tiers above the day: which weeks of the month (1st…5th) and which
// months — free-association's SentenceBuilder "In months › on weeks › on days
// • time"; here two pill rows that stay folded until an arc needs them
export function tierPills(kind, chosen, { onCommit }) {
    const row = el("span", `sl-tier sl-${kind}`);
    const labels = kind === "weeks" ? WEEK_ORDINALS : MONTHS_SHORT;
    const set = new Set(chosen || []);
    labels.forEach((l, i) => {
        const n = i + 1;
        const p = el("a", "sl-day sl-tierpill" + (set.has(n) ? " on" : ""), l);
        p.title = kind === "weeks" ? `the ${l} week of the month` : l;
        p.addEventListener("click", () => {
            if (set.has(n))
                set.delete(n);
            else
                set.add(n);
            const all = [...set].sort((a, b) => a - b);
            onCommit(all.length && all.length < labels.length ? all : undefined); // all = every = absent
        });
        row.appendChild(p);
    });
    return row;
}
// one HH:MM–HH:MM pair with live start<end validation (red borders)
export function timeRangePair(start, end, { onCommit }) {
    const wrap = el("span", "sl-times");
    const a = el("input", "sl-time");
    a.type = "time";
    a.value = start;
    const b = el("input", "sl-time");
    b.type = "time";
    b.value = end;
    const validate = () => {
        const bad = a.value >= b.value;
        a.classList.toggle("bad", bad);
        b.classList.toggle("bad", bad);
        return !bad;
    };
    const commit = () => { if (validate())
        onCommit(a.value, b.value); };
    a.addEventListener("change", commit);
    b.addEventListener("change", commit);
    wrap.append(a, el("span", "sl-dash", "–"), b);
    return wrap;
}
// ── the arcs editor: WHEN, as one sentence per rhythm ──────────────────────
// free-association's SentenceBuilder: "In [months] on [weeks] on [days] at
// [time]" — one line, four dropdowns, each a named preset ("mornings
// (8am–12pm)", "weekdays (Mon–Fri)", "summer (Jun–Aug)"…) with "custom…"
// last, which reveals the fine control (a month/week pill grid, day pills, a
// time-range pair) in place of the dropdown it followed. A rhythm with
// months/weeks left at "all"/"every week" carries no months/weeks field on
// the wire — the sentence still reads whole, the arc stays as spare as it
// was before the tiers existed.
function segment(modes, mode, onPick) {
    const sel = el("select", "sl-mode");
    for (const m of modes) {
        const o = el("option", null, m.label);
        o.value = m.value;
        sel.appendChild(o);
    }
    sel.value = mode;
    sel.addEventListener("change", () => onPick(modes.find(m => m.value === sel.value)));
    return sel;
}
/**
 * One axis of the sentence: a preset dropdown, and its own reveal slot right
 * under it. Picking "custom…" opens the fine control WITHOUT touching the
 * arc — the current value (whatever it is) is what the fine control starts
 * from, so switching axes never resets one you already dialled in. Picking a
 * named preset commits the concrete value and clears the slot. Independent
 * per axis, so an arc that reads custom on two axes at once (the common
 * case — "mon wed fri 17:00–19:00" matches no named preset on either) shows
 * both pickers together, not one at a time.
 */
function axisSlot(modes, mode, buildCustom, onPick) {
    const slot = el("div", "sl-arc-custom");
    const sel = segment(modes, mode, m => {
        if (m.value === "custom") {
            slot.replaceChildren(buildCustom());
            return;
        }
        slot.replaceChildren();
        onPick(m);
    });
    if (mode === "custom")
        slot.replaceChildren(buildCustom());
    return { sel, slot };
}
export function arcsEditor(arcs, { onCommit }) {
    const box = el("div", "sl-arcs");
    // one list for the loop AND the closures it makes — they edit the same arcs
    const list = arcs || [];
    const commit = onCommit;
    list.forEach((arc, idx) => {
        const set = (patch) => commit(list.map((a, i) => i === idx ? { ...a, ...patch } : a));
        const row = el("div", "sl-arc");
        const sentence = el("div", "sl-sentence");
        const months = axisSlot(MONTH_MODES, monthModeOf(arc), () => tierPills("months", arc.months, { onCommit: v => set({ months: v }) }), m => set({ months: m.months }));
        const weeks = axisSlot(WEEK_MODES, weekModeOf(arc), () => tierPills("weeks", arc.weeks, { onCommit: v => set({ weeks: v }) }), m => set({ weeks: m.weeks }));
        const days = axisSlot(DAY_MODES, dayModeOf(arc), () => dayPills(arc.days, { onCommit: d => set({ days: d }) }), m => set({ days: m.days }));
        const time = axisSlot(TIME_MODES, timeModeOf(arc), () => timeRangePair(arc.start, arc.end, { onCommit: (start, end) => set({ start, end }) }), m => set({ start: m.start, end: m.end }));
        sentence.append(document.createTextNode("in "), months.sel, document.createTextNode(" on "), weeks.sel, document.createTextNode(" on "), days.sel, document.createTextNode(" at "), time.sel);
        const del = el("a", "sl-x", "✕");
        del.title = "remove this rhythm";
        del.addEventListener("click", () => commit(list.filter((_, i) => i !== idx)));
        sentence.appendChild(del);
        const custom = el("div", "sl-arc-customs");
        custom.append(months.slot, weeks.slot, days.slot, time.slot);
        row.append(sentence, custom);
        box.appendChild(row);
    });
    if (!list.length)
        box.appendChild(el("div", "sl-ghost", "anytime — add a rhythm below if it matters"));
    const presets = el("div", "sl-presets");
    for (const dp of DAY_PRESETS)
        for (const tp of TIME_PRESETS.slice(0, 3)) {
            const chip = el("a", "sl-chip", `${dp.label} ${tp.label}`);
            chip.addEventListener("click", () => commit([...list, { start: tp.start, end: tp.end, days: [...dp.days] }]));
            presets.appendChild(chip);
        }
    const addCustom = el("a", "sl-chip sl-custom", "+ a rhythm…");
    addCustom.addEventListener("click", () => commit([...list, seedArc()]));
    presets.appendChild(addCustom);
    box.appendChild(presets);
    return box;
}
/**
 * free-association's LocationEditor, structurally: a tab strip — None ·
 * Specific · Coordinates · Online · Live — content swapped per tab, not
 * chips-plus-a-detail-pane. Same five tabs, same fields (Specific's mailing
 * address as five inputs: street, city, state/province, postal code,
 * country; Coordinates as two number inputs, not one "lat, lon" text field);
 * ours adds a sixth, "known", first — the scope's already-declared places,
 * since we keep a shared place registry theirs doesn't. Declaring a NEW
 * place still goes through declare-place: the five address fields join into
 * the one string <spatial-thing> keeps (mappable-address) — presentation
 * richness without a schema theirs needed and ours doesn't.
 */
const WHERE_TABS = [
    ["none", "None"], ["known", "Known"], ["specific", "Specific"],
    ["coordinates", "Coordinates"], ["online", "Online"], ["live", "Live"],
];
export function whereEditor(where, locs, { onCommit, here, online, onOnline, onNewPlace, follow }) {
    const places = locs || [];
    const box = el("div", "sl-where");
    const tabs = el("div", "sl-where-tabs");
    const body = el("div", "sl-where-body");
    // which tab starts active: follow what the slot already carries
    let active = follow?.on ? "follow"
        : online ? "online"
            : where && places.some(l => l.id === where) ? "known"
                : where ? "specific" : "none";
    // no save button anywhere: switching to None IS clearing it — the same
    // "select is the commit" their tab strip uses (onclick sets the type AND
    // fires the update in one motion), not a second confirming tap
    const setTab = (t) => {
        active = t;
        draw();
        if (t === "none")
            onCommit("");
    };
    if (follow) {
        const b = el("a", "sl-where-tab", `◎ ${follow.label}`);
        b.dataset.tab = "follow";
        b.addEventListener("click", () => { active = "follow"; draw(); follow.pick(); });
        tabs.appendChild(b);
    }
    for (const [id, label] of WHERE_TABS) {
        if (id === "live" && !here)
            continue; // nothing to share without a live position
        if (id === "online" && !onOnline)
            continue;
        const b = el("a", "sl-where-tab", label);
        b.dataset.tab = id;
        b.addEventListener("click", () => setTab(id));
        tabs.appendChild(b);
    }
    // ── None ──
    const drawNone = () => {
        body.appendChild(el("div", "sl-ghost", "no place set — the plan reads this as anywhere"));
    };
    // ── Known: the scope's already-declared places ──
    const drawKnown = () => {
        if (!places.length) {
            body.appendChild(el("div", "sl-ghost", "the scope has no places yet — declare one under Specific"));
            return;
        }
        const grid = el("div", "sl-where-chips");
        for (const l of places) {
            const c = el("a", "sl-chip" + (where === l.id ? " on" : ""), l.name);
            if (l.address)
                c.title = l.address;
            c.addEventListener("click", () => onCommit(l.id));
            grid.appendChild(c);
        }
        body.appendChild(grid);
    };
    // ── Specific / Coordinates: no save button — every blur commits, exactly
    // their onblur={emitUpdate} discipline. A form here makes a NEW place
    // rather than editing fields already on the slot, so "commit" means
    // declare-place; re-blurring re-declares (the deterministic id makes that
    // just another edit, the same as every other field in this codebase).
    // Only fires once a name exists — the one thing a place cannot be without.
    // The group commits as ONE when focus leaves it — not a button, and not a
    // blur on every field either: a commit here is a server round trip that
    // rebuilds the card the form sits in (declare-place → the slot's `where`
    // changes → the whole accordion redraws, same as every other field in this
    // codebase), so firing per-keystroke-field would tear the form down between
    // "street" and "city" before the address is even half typed. Firing once
    // focus truly leaves the group — Tab past the last field, click away,
    // switch tabs — keeps "no save button" without losing what is mid-typing.
    const addrForm = (coords) => {
        const form = el("div", "sl-addr-form");
        const name = el("input", "sl-in sl-placein");
        name.type = "text";
        name.placeholder = "its name";
        const err = el("span", "sl-rule-err", "");
        let lat, lon;
        let street, city, state, postal, country;
        const fire = async () => {
            const nm = name.value.trim();
            if (!nm || !onNewPlace)
                return;
            err.textContent = "";
            const id = coords
                ? await onNewPlace(nm, +lat.value || 0, +lon.value || 0, "")
                : await onNewPlace(nm, 0, 0, [street.value, city.value, state.value, postal.value, country.value]
                    .map(v => v.trim()).filter(Boolean).join(", "));
            if (id)
                onCommit(id);
            else
                err.textContent = "couldn't reach the scope — try again once signed in";
        };
        form.addEventListener("focusout", () => {
            setTimeout(() => { if (!form.contains(document.activeElement))
                fire(); }, 0);
        });
        name.addEventListener("keydown", ev => { if (ev.key === "Enter")
            name.blur(); });
        if (coords) {
            const row = el("div", "sl-addr-row");
            lat = el("input", "sl-in sl-latin");
            lat.type = "number";
            lat.step = "0.000001";
            lat.min = "-90";
            lat.max = "90";
            lat.placeholder = "latitude";
            lon = el("input", "sl-in sl-lonin");
            lon.type = "number";
            lon.step = "0.000001";
            lon.min = "-180";
            lon.max = "180";
            lon.placeholder = "longitude";
            row.append(lat, lon);
            form.append(name, row, err);
        }
        else {
            street = el("input", "sl-in sl-addr-street");
            street.type = "text";
            street.placeholder = "street address";
            const row = el("div", "sl-addr-row");
            city = el("input", "sl-in sl-addr-city");
            city.type = "text";
            city.placeholder = "city";
            state = el("input", "sl-in sl-addr-state");
            state.type = "text";
            state.placeholder = "state / province";
            row.append(city, state);
            const row2 = el("div", "sl-addr-row");
            postal = el("input", "sl-in sl-addr-postal");
            postal.type = "text";
            postal.placeholder = "postal code";
            country = el("input", "sl-in sl-addr-country");
            country.type = "text";
            country.placeholder = "country";
            row2.append(postal, country);
            form.append(name, street, row, row2, err);
        }
        return form;
    };
    const drawSpecific = () => { const f = addrForm(false); body.appendChild(f); f.querySelector("input").focus(); };
    const drawCoordinates = () => { const f = addrForm(true); body.appendChild(f); f.querySelector("input").focus(); };
    // ── Online: a meeting link, not a place ──
    const drawOnline = () => {
        if (!onOnline)
            return;
        const inp = inlineText(online || "", { placeholder: "https://zoom.us/j/… (a room, a call, a board)",
            cls: "sl-linkin", onCommit: v => onOnline(v.trim()) });
        const clear = el("a", "sl-x", "no link");
        clear.addEventListener("click", () => { onOnline(""); inp.value = ""; });
        body.append(inp, clear);
        inp.focus();
    };
    // ── Live: shared only during the availability window ──
    const drawLive = () => {
        const info = el("div", "sl-live-info");
        info.append(el("div", "sl-live-h", "📍 live location"), el("div", "sl-live-p", "shared only while the rhythm above is active"));
        body.appendChild(info);
        if (here) {
            const h = el("a", "sl-chip sl-here" + (where === here ? " on" : ""), "◉ use where you are now");
            h.addEventListener("click", () => onCommit(here));
            body.appendChild(h);
        }
    };
    // ── Follow: the outside source's own word for where this looks ──
    const drawFollow = () => { body.appendChild(el("div", "sl-ghost", follow?.note || "")); };
    const DRAW = {
        follow: drawFollow, none: drawNone, known: drawKnown, specific: drawSpecific,
        coordinates: drawCoordinates, online: drawOnline, live: drawLive,
    };
    function draw() {
        for (const b of tabs.querySelectorAll(".sl-where-tab"))
            b.classList.toggle("on", b.dataset.tab === active);
        body.replaceChildren();
        (DRAW[active] || drawNone)();
    }
    draw();
    box.append(tabs, body);
    return box;
}
// ── the span: where this pool stands, spoken as a governor ─────────────
// One sentence with a place to pick and a button, under the lend (lend.ts): the
// same card, a different act — the lend is the owner's, the span is the scope's.
export function standsRow(name, sp) {
    const row = el("div", "sl-soc-row sl-soc-span");
    const sel = el("select", "sl-soc-span-at");
    const known = sp.places.some(p => p.id === sp.at);
    if (sp.at && !known)
        sel.appendChild(new Option(sp.at, sp.at));
    for (const p of sp.places)
        sel.appendChild(new Option(p.name, p.id));
    sel.value = sp.at || (sp.places[0] ? sp.places[0].id : "");
    const go = el("button", "sl-soc-go sl-soc-span-go", "declare the span");
    const said = el("span", "sl-soc-of");
    go.addEventListener("click", () => {
        if (!sel.value) {
            said.textContent = "pick a place";
            return;
        }
        go.disabled = true;
        go.textContent = "declaring…";
        spoken(sp.declare(sel.value), spanSentence(name, sel.selectedOptions[0]?.text || sel.value))
            .then(w => { go.disabled = false; go.textContent = "declare the span"; said.textContent = w.text; });
    });
    row.append(el("span", "sl-soc-of", "as a governor, the pool stands at "), sel, go, said);
    return row;
}
