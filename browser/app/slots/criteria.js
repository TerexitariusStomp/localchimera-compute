// app/slots/criteria.ts — the matcher-only sidecar on the card: ⚙️
// divisibility and 🔒 eligibility.
//
// free-association's DivisibilityEditor (min_atomic_size · max_participation
// · max_concurrency) and FilterRuleEditor (a JSON-logic rule with presets)
// land here as two card sections over ONE object — the slot's `criteria`,
// which is <intent-matching-criteria> on the wire (matching/filter-rule.scm
// parses it, match-slots enforces it). Both editors commit a PATCH of the
// criteria; the card merges it and re-declares, as every other section does.
//
// The rule's vocabulary is the commons' own — an s-expression in JSON arrays:
//   true · false · ["aid", A…] · ["not-aid", A…] · ["min-recognition", r]
//   · ["in-scope", S…] · ["has-skill", SPEC…] · ["within-km", d]
//   · ["in-group", REL…] · ["vouched"]
//   · ["and"|"or", …] · ["not", x]
// The presets cover what a citizen usually means; "custom" shows the rule as
// it is written and lets it be edited by hand.
import { TENSIONS, TENSION_LABEL, TENSION_HINT, VOICE_LADDER, ladderIndex } from './model.js';
import { book as contactBook, kindsInBook, kindOf, nameOf } from '../contact-book.js';
import { audienceOf, ruleOf, openTo, relOf, admitted } from '../lend-core.js';
import { mk as el } from '../dom.js';
// ── reading the sidecar back as words (the card's button labels) ──────────
export function fmtDivisibility(c) {
    if (!c)
        return "";
    const parts = [];
    if (c["min-atomic-size"])
        parts.push(`size ≥ ${c["min-atomic-size"]}`);
    if (c["max-participation"])
        parts.push(`max ${c["max-participation"]} people`);
    if (c["max-concurrency"])
        parts.push(`max ${c["max-concurrency"]} at once`);
    return parts.join(", ");
}
export function fmtRule(r) {
    if (r === undefined || r === null || r === true)
        return "";
    if (r === false || r === "deny-all")
        return "nobody";
    if (!Array.isArray(r))
        return "custom";
    const [op, ...args] = r;
    switch (op) {
        case "aid": return `only ${args.map(a => nameOf(String(a))).join(", ")}`;
        case "not-aid": return `not ${args.map(a => nameOf(String(a))).join(", ")}`;
        case "min-recognition": return `trusted ≥ ${args[0]}`;
        case "in-scope": return `in ${args.length} scope${args.length === 1 ? "" : "s"}`;
        case "has-skill": return `skilled: ${args.join(", ")}`;
        case "in-group": return `your ${args.map(a => kindOf(String(a)).plural).join(", ")}`;
        case "vouched": return "people you vouch for";
        // any of them admits: the picks read as one list, "your friends + Priya"
        case "or": return args.map(a => fmtRule(a).replace(/^only /, "")).join(" + ");
        case "within-km": return `within ${args[0]} km`;
        default: return "custom";
    }
}
// ── ⚙️ divisibility: three numbers, each optional ─────────────────────────
export function divisibilityEditor(c, onCommit) {
    const box = el("div", "sl-div");
    const field = (key, label, help) => {
        const row = el("label", "sl-div-row");
        const inp = el("input", "sl-div-in");
        inp.type = "number";
        inp.min = "0";
        inp.step = "1";
        inp.placeholder = "—";
        const v = c && c[key];
        inp.value = v ? String(v) : "";
        inp.addEventListener("change", () => {
            const n = Number(inp.value);
            onCommit({ [key]: isFinite(n) && n > 0 ? n : undefined });
        });
        inp.addEventListener("keydown", ev => { if (ev.key === "Enter")
            inp.blur(); });
        row.append(el("span", "sl-div-l", label), inp, el("span", "sl-div-h", help));
        box.appendChild(row);
    };
    field("min-atomic-size", "smallest useful piece", "an offer smaller than this is no match — a night's shelter is not half a night");
    field("max-participation", "at most … people", "how many may share it");
    field("max-concurrency", "at most … at once", "how many at the same time");
    return box;
}
// ── the contact book as chips: one person, one chip ───────────────────────
// Every picker of people draws them the same way — the name, ✍ when you vouch
// for them, the colour of the kind you know them as.
function personChips(people, isOn, flip, empty = "the people you connect with appear here, to pick by name") {
    const wrap = el("div", "sl-people");
    if (!people.length)
        wrap.appendChild(el("div", "sl-ghost", empty));
    for (const c of people) {
        const on = isOn(c), kind = kindOf(relOf(c));
        const chip = el("a", "sl-chip" + (on ? " on" : ""), `${c.mine ? "✍ " : ""}${c.alias || c.aid.slice(0, 8)}`);
        chip.title = `${kind.id}${c.mine ? " · you vouch for them" : ""}`;
        if (!on)
            chip.style.borderColor = kind.colour;
        chip.addEventListener("click", () => flip(c));
        wrap.appendChild(chip);
    }
    return wrap;
}
// ── who: the audience picker — the contact book itself, as a rule ─────────
// The people you vouch for, each kind you tag people with, and every person by
// name, picked together: any of them admits (lend-core.ts audienceOf / ruleOf).
// A kind and a vouch stay LIVE — the rule names the kind, so a tag changed or a
// vouch signed tomorrow moves who it admits. One picker for a slot's 🔒 and a
// lend's "who may work on it".
export function audiencePicker(rule, onCommit) {
    const box = el("div", "ld-who");
    const a = audienceOf(rule);
    if (!a) { // a rule an audience does not write: read it, offer the way back
        const row = el("div", "sl-presets");
        row.appendChild(el("span", "sl-soc-of", `${fmtRule(rule)} — a rule written by hand`));
        const clear = el("a", "sl-chip", "anyone instead");
        clear.addEventListener("click", () => onCommit(undefined));
        row.appendChild(clear);
        box.appendChild(row);
        return box;
    }
    const people = contactBook();
    const chip = (label, on, title, flip, colour) => {
        const c = el("a", "sl-chip" + (on ? " on" : ""), label);
        c.title = title;
        if (colour && !on)
            c.style.borderColor = colour;
        c.addEventListener("click", () => { flip(); onCommit(ruleOf(a)); });
        return c;
    };
    const flipIn = (set, k) => { if (set.has(k))
        set.delete(k);
    else
        set.add(k); };
    const kinds = el("div", "sl-presets");
    kinds.appendChild(chip("anyone", openTo(a), "the plan may pick anyone", () => { a.vouched = false; a.kinds.clear(); a.people.clear(); }));
    kinds.appendChild(chip(`✍ people I vouch for · ${people.filter(c => c.mine).length}`, a.vouched, "everyone you hold a signed vouch for — it follows your vouches as they change", () => { a.vouched = !a.vouched; }));
    for (const k of kindsInBook()) {
        const kind = kindOf(k);
        kinds.appendChild(chip(`${kind.plural} · ${people.filter(c => relOf(c) === k).length}`, a.kinds.has(k), `everyone you know as ${kind.plural} — it follows the tags in your contacts`, () => flipIn(a.kinds, k), kind.colour));
    }
    box.append(kinds, personChips(people, c => a.people.has(c.aid), c => { flipIn(a.people, c.aid); onCommit(ruleOf(a)); }));
    if (!openTo(a)) {
        const now = admitted(a, people);
        box.appendChild(el("div", "ld-now", now.length
            ? `today that is ${now.map(c => c.alias || c.aid.slice(0, 8)).join(", ")}`
            : "today that is nobody in your contacts"));
    }
    return box;
}
const modeOf = (r) => audienceOf(r) ? "who"
    : (r === false || r === "deny-all") ? "none"
        : Array.isArray(r) && r[0] === "not-aid" ? "not"
            : "custom";
export function ruleEditor(c, onCommit) {
    const box = el("div", "sl-rule");
    const rule = c && c["filter-rule"];
    let mode = modeOf(rule);
    const commit = (r) => onCommit({ "filter-rule": r });
    const modes = el("div", "sl-presets");
    const detail = el("div", "sl-rule-detail");
    const MODES = [
        ["who", "anyone, or the people you pick", "pair with anyone, or only with the people, kinds and vouches you pick"],
        ["none", "nobody", "hold it — nothing pairs with this for now"],
        ["not", "everyone but…", "pair with anyone but the contacts you pick"],
        ["custom", "custom…", "the rule as it is written"],
    ];
    const draw = () => {
        modes.replaceChildren();
        for (const [k, label, title] of MODES) {
            const chip = el("a", "sl-chip" + (mode === k ? " on" : ""), label);
            chip.title = title;
            chip.addEventListener("click", () => {
                if (mode === k)
                    return;
                mode = k;
                if (k === "who")
                    commit(undefined);
                else if (k === "none")
                    commit(false);
                else
                    draw(); // the picker below finishes it
            });
            modes.appendChild(chip);
        }
        detail.replaceChildren();
        if (mode === "who")
            detail.appendChild(audiencePicker(rule, commit));
        if (mode === "not") {
            const out = new Set(Array.isArray(rule) && rule[0] === "not-aid" ? rule.slice(1) : []);
            detail.appendChild(personChips(contactBook(), p => out.has(p.aid), p => {
                if (out.has(p.aid))
                    out.delete(p.aid);
                else
                    out.add(p.aid);
                commit(out.size ? ["not-aid", ...out] : undefined);
            }));
        }
        if (mode === "custom")
            detail.appendChild(customBox());
    };
    const customBox = () => {
        const wrap = el("div", "sl-custom-rule");
        const ta = el("textarea", "sl-rule-text");
        ta.rows = 2;
        ta.placeholder = '["and", ["min-recognition", 0.5], ["within-km", 10]]';
        ta.value = rule === undefined || rule === null ? "" : JSON.stringify(rule);
        const err = el("div", "sl-rule-err", "");
        ta.addEventListener("change", () => {
            const t = ta.value.trim();
            if (!t) {
                commit(undefined);
                return;
            }
            try {
                const v = JSON.parse(t);
                if (typeof v === "boolean" || (Array.isArray(v) && typeof v[0] === "string")) {
                    err.textContent = "";
                    commit(v);
                }
                else
                    err.textContent = "a rule is true, false, or [\"op\", …]";
            }
            catch (_) {
                err.textContent = "not JSON";
            }
        });
        wrap.append(ta, err, el("div", "sl-ghost", 'ops: aid · not-aid · in-group · vouched · min-recognition · in-scope · has-skill · within-km · and · or · not'));
        return wrap;
    };
    draw();
    box.append(modes, detail);
    return box;
}
// ── ⭐ priority: who this capacity serves first ─────────────────────────────
// free-association's SlotPriorityDistributionEditor: per-person priorities on
// a capacity that override the global recognition for this one slot. Ours: a
// contact chip per person, a weight (0..1) once chosen; the ring reads the
// distribution as a dimension of the match (matching/filter-rule.scm
// priority-for) — the person named first ranks first.
export function fmtPriority(c) {
    const d = c && c["priority-distribution"];
    const n = d ? Object.keys(d).length : 0;
    if (n)
        return `${n} first`;
    return c && c.priority != null ? `priority ${c.priority}` : "";
}
export function priorityEditor(c, onCommit) {
    const box = el("div", "sl-prio");
    const dist = { ...((c && c["priority-distribution"]) || {}) };
    const commit = () => onCommit({ "priority-distribution": Object.keys(dist).length ? dist : undefined });
    box.appendChild(el("div", "sl-ghost", "who this serves first — pick people, then say how strongly; everyone else follows by recognition"));
    const book = contactBook();
    const chips = el("div");
    const rows = el("div", "sl-prio-rows");
    const draw = () => {
        rows.replaceChildren();
        chips.replaceChildren(personChips(book, p => p.aid in dist, p => {
            if (p.aid in dist)
                delete dist[p.aid];
            else
                dist[p.aid] = 1;
            commit();
            draw();
        }));
        for (const [aid, w] of Object.entries(dist)) {
            const row = el("label", "sl-prio-row");
            const who = book.find(x => x.aid === aid);
            const range = el("input", "sl-prio-range");
            range.type = "range";
            range.min = "0";
            range.max = "1";
            range.step = "0.1";
            range.value = String(w);
            const val = el("span", "sl-prio-val", w.toFixed(1));
            range.addEventListener("input", () => { val.textContent = Number(range.value).toFixed(1); });
            range.addEventListener("change", () => { dist[aid] = Number(range.value); commit(); });
            row.append(el("span", "sl-div-l", who ? who.alias : aid.slice(0, 8) + "…"), range, val);
            rows.appendChild(row);
        }
    };
    draw();
    box.append(chips, rows);
    return box;
}
// ── ⚖️ the need's kind and attached voice ─────────────────────────────────
// Not a matcher sidecar: the kind and voice ride on the intent itself, as
// classification terms the demand fold carries up as totals (tension-terms.scm).
// Voice is the row's total tension mass, spent from the citizen's purse of
// emphasis — the attachment IS the weight, so the statement is the payment
// (docs/planning/identity/truth-telling.md stage 2). The slider offers it on the
// VOICE_LADDER (model.ts); 0 = nothing attached.
export function fmtTension(tension, voice) {
    const t = tension || "des";
    const v = voice || 0;
    return `${TENSION_LABEL[t]}${t === "floor" || v <= 0 ? "" : ` · ${v}`}`;
}
const grantCovers = (g, k) => k === "des" || (!!g && (g.kind === k || (g.kind === "floor" && k === "held")));
export function tensionEditor(tension, voice, onCommit, displacementOf, gate, handShare) {
    const box = el("div", "sl-tension");
    let t = tension || "des";
    let idx = ladderIndex(voice || 0);
    const chips = el("div", "sl-people");
    const hint = el("div", "sl-ghost", TENSION_HINT[t]);
    // the gate: a right or a need is the table's statement, never one person's
    // (truth-telling.md stage 1). Tapping an unratified kind opens the rite —
    // one line naming what the table would be saying, and the act that
    // records it — rather than a refusal after the fact.
    let grant = null;
    const rite = el("div", "sl-ghost sl-rite");
    rite.style.display = "none";
    gate?.ratified().then(g => { grant = g; draw(); });
    const commit = (k) => {
        t = k;
        hint.textContent = TENSION_HINT[t];
        rite.style.display = "none";
        onCommit({ tension: t, voice: VOICE_LADDER[idx] });
        draw();
    };
    const openRite = (k) => {
        rite.replaceChildren();
        rite.append(`${TENSION_LABEL[k]} is the table's statement, never one person's — `);
        const act = el("a", "sl-chip", `the table ratifies this as ${TENSION_LABEL[k]}`);
        act.addEventListener("click", () => {
            act.textContent = "recording…";
            gate.ratify(k).then(ok => {
                if (ok) {
                    grant = { kind: k, by: "you" };
                    commit(k);
                }
                else {
                    act.textContent = "the scope declined";
                }
            });
        });
        rite.appendChild(act);
        rite.style.display = "";
    };
    // what asking displaces, shown BEFORE any voice is attached: what one unit
    // of this spec currently moves elsewhere in the plan — the last solve's
    // dual μ, the marginal externality (planner solve/externality.scm). Silent until
    // read: a scope with no solve yet, or a demo, keeps the editor as it was.
    const moved = el("div", "sl-ghost sl-displacement");
    moved.style.display = "none";
    const fmtMu = (n) => (Math.abs(n) >= 100 ? n.toFixed(0) : n.toPrecision(3));
    displacementOf?.().then(p => {
        if (!p || !p.read)
            return;
        moved.textContent =
            `what this ask displaces: one more unit moves ≈ ${fmtMu(p.perUnit)} elsewhere in the plan · the whole ask ≈ ${fmtMu(p.moved)}`
                + (p.honesty ? ` · honest by shape: no rewrite moves the plan past ${fmtMu(p.honesty.radiusWholeHand)}` : "")
                + (p.honesty?.solveTolerance && p.honesty.solveTolerance > 0
                    ? ` · certified within ${fmtMu(p.honesty.solveTolerance)} of the true optimum`
                    : "")
                + (p.lately && p.lately.solves > 1
                    ? ` · lately ≈ ${fmtMu(p.lately.meanMoved)} per solve over ${p.lately.solves}`
                    : "");
        moved.style.display = "";
    });
    const row = el("label", "sl-prio-row");
    const range = el("input", "sl-prio-range");
    range.type = "range";
    range.min = "0";
    range.max = String(VOICE_LADDER.length - 1);
    range.step = "1";
    range.value = String(idx);
    const val = el("span", "sl-prio-val", String(VOICE_LADDER[idx]));
    const draw = () => {
        chips.replaceChildren();
        for (const k of TENSIONS) {
            const ratified = k !== "des" && grantCovers(grant, k);
            const chip = el("a", "sl-chip" + (k === t ? " on" : ""), TENSION_LABEL[k] + (ratified ? " ✓" : ""));
            if (ratified && grant)
                chip.title = `ratified by ${grant.by}`;
            chip.addEventListener("click", () => {
                if (gate && !grantCovers(grant, k))
                    openRite(k);
                else
                    commit(k);
            });
            chips.appendChild(chip);
        }
        row.style.display = t === "floor" ? "none" : ""; // a right takes no voice: the wall is free, which is what makes it a right
    };
    range.addEventListener("input", () => { val.textContent = String(VOICE_LADDER[Number(range.value)]); });
    range.addEventListener("change", () => { idx = Number(range.value); onCommit({ tension: t, voice: VOICE_LADDER[idx] }); });
    row.append(el("span", "sl-div-l", "voice"), range, val);
    // what the attachment MEANS (playnet.typ §Desire as harmony, solve/emphasis.scm):
    // a share of this citizen's own hand — the rungs are relative, the hand is
    // whole — and a row with nothing attached follows the table's priorities
    const share = el("div", "sl-ghost", handShare === undefined ? ""
        : handShare > 0
            ? `this row holds ${Math.round(100 * handShare)}% of your emphasis · the rungs are shares of your own hand`
            : "nothing attached: this row follows the table's current priorities");
    box.append(el("div", "sl-ghost", "how far this may be sacrificed when the commons is short"), chips, hint, rite, moved, row, share);
    draw();
    return box;
}
