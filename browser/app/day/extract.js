// app/extract.ts — the log's extraction pipeline: speech → structure.
//
// One module owns every pass that reads the captain's log back, so refining
// the pipeline is editing THIS file: each pass is a declarative entry in
// PASSES — its system prompt, its context builders, its sanitizer — and one
// door (`ask`) carries them all through the gateway's AI seam. The consumer
// (tabs/log.js) only ever sees clean, typed results.
//
// The pipeline is GROUNDED in the knowledge layer: the scope's recipe
// library (the corpus pipeline's output — every resource-spec the planner
// can actually provision) rides into every prompt as the preferred
// vocabulary, and every extracted spec is stamped `known` when it names one.
// A known spec is a suggestion the plan can act on directly; an unknown one
// is honest free text — the same facts-vs-leads discipline the corpus
// tooling keeps.
//
// Three passes, three rhythms:
//   entry  — one diary entry → the contacts it speaks about + the VF
//            economic events it narrates (what HAPPENED)
//   digest — a week of entries → standing needs worth planning
//            (what RECURS)
//   slot   — one spoken sentence from the share bar → the fields of ONE
//            need or offer slot (what is WANTED or GIVEN), filling the
//            creation pill for the speaker to read before the ➕ commits
//
// Every pass has a life without AI: `scanContacts` is the standalone floor
// for the entry pass, and `runPass` returns null on any failure (no seam, no
// keys, bad JSON) — never a throw. The AI path is gateway-only, the orb's
// rule: the seam's handlers.ai, read at call time, no client key.
//
// The ask itself is app/conform.ts, the one door every shape-asking caller
// shares with the gateway's (playnet ai conform): a reply that fails a pass's
// `check` is asked again with the reason quoted back, once; then `sanitize`
// salvages what it can of the last reply — the floor.
import { conform, readFirstJSONObject } from "../conform.js";
import { recipes } from "../recipe-graph.js";
import { seam } from "../seam.js";
import { scopeSig } from "../scope.js";
// ── the vocabulary: what the scope knows how to make ───────────────────────
// The recipe library's spec names — produces, inputs, outputs — deduped.
// This is where the corpus→recipe pipeline meets the log: a textbook that
// became a recipe becomes, here, a word the extraction prefers.
export function knownSpecs() {
    const rs = recipes();
    const specs = new Set();
    rs.forEach(r => {
        if (r.produces)
            specs.add(r.produces);
        (r.steps || []).forEach(s => [...(s.in || []), ...(s.out || [])].forEach(f => f.spec && specs.add(f.spec)));
    });
    return [...specs];
}
const specLine = (specs) => specs.length
    ? `\nKnown resource/skill specs (use these EXACT names whenever the text ` +
        `means one of them; free text only for things outside the library): ` +
        `${JSON.stringify(specs)}\n`
    : "";
const stampKnown = (v, specs) => ({ ...v, known: specs.includes(v.spec) });
// ── the one AI door ─────────────────────────────────────────────────────────
// the gateway's handler, read at call time; null when the door is shut.
const aiHandler = () => {
    const h = seam.handlers;
    return h.ai || null;
};
export const aiAvailable = () => !!seam.handlers.ai;
// ── the standalone floor ────────────────────────────────────────────────────
// every book alias named in the text is a suggestion already — no AI, no
// gateway, and it gives the entry pass a floor rather than a race.
export function scanContacts(text, book) {
    const low = text.toLowerCase();
    return book.filter(c => c.alias && c.alias.length > 1
        && low.includes(c.alias.toLowerCase()))
        .map(c => ({ alias: c.alias, why: "named in the entry" }));
}
// ── the passes ──────────────────────────────────────────────────────────────
export const LOG_ACTIONS = ["work", "produce", "consume", "use", "raise", "lower"];
const sift = (field, v, fault) => {
    const faults = Array.isArray(v) ? [] : [`"${field}" must be an array`];
    const kept = [];
    (Array.isArray(v) ? v : []).forEach((r, i) => {
        if (!r || typeof r !== "object") {
            faults.push(`${field}[${i}] must be an object`);
            return;
        }
        const f = fault(r);
        if (f)
            faults.push(`${field}[${i}]${f}`);
        else
            kept.push(r);
    });
    return { kept, faults };
};
const reasons = (fs) => fs.length ? fs.map(f => `- ${f}`).join("\n") : null;
const positive = (x) => +x > 0;
const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const HHMM = /^\d{2}:\d{2}$/;
const contactFault = (book) => {
    const aliases = new Set(book.map(c => c.alias));
    return c => aliases.has(c.alias) ? null
        : `.alias "${c.alias}" is not in the book; use an alias verbatim or drop the contact`;
};
const eventFault = v => !LOG_ACTIONS.includes(v.action) ? `.action "${v.action}" must be one of ${LOG_ACTIONS.join("|")}`
    : !v.spec ? `.spec must name the resource or skill`
        : !positive(v.qty) ? `.qty must be a number above 0` : null;
const proposalFault = p => !p.spec ? `.spec must name the resource or skill`
    : !positive(p.qty) ? `.qty must be a number above 0` : null;
const arcFault = a => {
    if (!HHMM.test(String(a.start)) || !HHMM.test(String(a.end)))
        return ` start and end must be HH:MM`;
    const days = Array.isArray(a.days) ? a.days.map((d) => String(d).toLowerCase()) : [];
    const bad = days.filter((d) => !DAYS.includes(d));
    if (bad.length)
        return `.days ${JSON.stringify(bad)} must be lowercase full day names`;
    return days.length ? null : `.days must name at least one day`;
};
async function plannerLint(records) {
    const lint = seam.handlers.lintRecords;
    if (!lint || !records.length)
        return [];
    try {
        const raw = await lint(scopeSig() || "", JSON.stringify(records));
        if (typeof raw !== "string" || raw.startsWith("err:"))
            return [];
        const findings = JSON.parse(raw);
        return findings.filter(f => f.severity === "error").slice(0, 8)
            .map(f => `${f.subject} ${f.detail}`);
    }
    catch (_) {
        return [];
    }
}
/** The local faults, and when there are none, what the planner would refuse. */
async function checked(faults, records) {
    return reasons(faults.length ? faults : await plannerLint(records));
}
const PASSES = {
    entry: {
        system: specs => `You extract structure from one captain's-log diary entry for a ValueFlows ` +
            `planner. Reply with EXACTLY one JSON object, no prose, no fences:\n` +
            `{"contacts":[{"alias":"<an alias from the book, verbatim>","why":"<≤6 words>"}],` +
            `"events":[{"action":"work|produce|consume|use|raise|lower","spec":"<short ` +
            `resource or skill name>","qty":<number>,"unit":"<h|each|kg|l|km>",` +
            `"when":"<ISO 8601, or empty>","summary":"<one short line>"}]}\n` +
            specLine(specs) +
            `Contacts: only aliases present in the book, and only when the entry is ` +
            `about that person. Events: only what the entry states ACTUALLY HAPPENED ` +
            `(work = labour hours spent; produce/consume/use = things made, eaten, ` +
            `used; raise/lower = stock found or lost) — never plans or wishes. ` +
            `Empty arrays when nothing qualifies.`,
        user: ({ text, tIso, book }) => `contact book: ${JSON.stringify(book.map(c => ({ alias: c.alias, rel: c.rel || "contact" })))}\n` +
            `entry (logged ${tIso}):\n${text}`,
        check: (got, { book }) => checked([
            ...sift("contacts", got.contacts, contactFault(book)).faults,
            ...sift("events", got.events, eventFault).faults
        ], sift("events", got.events, eventFault).kept.map(v => ({ kind: "event", action: v.action, spec: v.spec, qty: v.qty, unit: v.unit }))),
        sanitize: (got, { book, specs }) => ({
            contacts: sift("contacts", got.contacts, contactFault(book)).kept
                .map(c => ({ alias: String(c.alias), why: String(c.why || "") })),
            events: sift("events", got.events, eventFault).kept
                .map(v => stampKnown({
                action: v.action, spec: String(v.spec), qty: +v.qty,
                unit: String(v.unit || (v.action === "work" ? "h" : "each")),
                when: String(v.when || ""), summary: String(v.summary || "")
            }, specs)),
        }),
    },
    digest: {
        system: specs => `You read several days of one person's captain's-log diary for a ValueFlows ` +
            `planner and propose STANDING NEEDS worth planning for — recurring wants ` +
            `and frictions the entries reveal, not one-off happenings already past. ` +
            `Reply with EXACTLY one JSON object, no prose, no fences:\n` +
            `{"proposals":[{"spec":"<short resource or skill name>","name":"<display ` +
            `name>","emoji":"<one emoji>","qty":<number per week>,"unit":"<h|each|kg|l|km>",` +
            `"why":"<one short line, citing the entries>"}]}\n` +
            specLine(specs) +
            `At most 5, strongest first; an empty array when the log reveals nothing recurring.`,
        user: ({ lines }) => `the log, newest first:\n${lines}`,
        check: got => {
            const { kept, faults } = sift("proposals", got.proposals, proposalFault);
            if (kept.length > 5)
                faults.push(`at most 5 proposals, strongest first`);
            return checked(faults, kept.map(p => ({ kind: "need", spec: p.spec, qty: p.qty, unit: p.unit })));
        },
        sanitize: (got, { specs }) => ({
            proposals: sift("proposals", got.proposals, proposalFault).kept
                .slice(0, 5)
                .map(p => stampKnown({
                spec: String(p.spec), name: String(p.name || p.spec),
                emoji: String(p.emoji || "✶").slice(0, 4),
                qty: +p.qty, unit: String(p.unit || "each"),
                why: String(p.why || ""), declared: false
            }, specs)),
        }),
    },
    slot: {
        system: specs => `You read ONE spoken sentence from a commons member and fill the fields of ` +
            `ONE slot for a ValueFlows planner — a NEED (something they want the ` +
            `plan to provide, a standing order) or an OFFER (a capacity they can give: ` +
            `hours, tools, goods, care). Reply with EXACTLY one JSON object, no prose, ` +
            `no fences:\n` +
            `{"slot":{"name":"<short thing, 1-3 words>","emoji":"<one emoji>",` +
            `"qty":<number>,"unit":"<each|kg|L|hours|hours/day|hours/week|kg/week|…>",` +
            `"spec":"<the known spec name when one fits, else the name>",` +
            `"arcs":[{"start":"HH:MM","end":"HH:MM","days":["monday",…]}],` +
            `"where":"<a place, verbatim from the list or as said, or empty>",` +
            `"note":"<what the sentence adds beyond the fields, or empty>"}}\n` +
            specLine(specs) +
            `Units: a count is a stock, "X/day" or "X/week" is a rate, bare hours on an ` +
            `offer is a budget. arcs: only when the sentence gives a rhythm (days and ` +
            `hours) — never invent one; the days are lowercase full names. qty defaults ` +
            `to 1 when unsaid. When the sentence names nothing that could be a need or ` +
            `an offer, reply {"slot":null}.`,
        user: ({ text, kind, places }) => `rail: ${kind === "need" ? "NEED (they ask)" : "OFFER (they give)"}\n` +
            (places.length ? `places the commons knows: ${JSON.stringify(places)}\n` : "") +
            `spoken:\n${text}`,
        check: (got, { kind }) => {
            const s = got.slot;
            if (s === null)
                return null; // "nothing here" is a valid reply
            if (!s || typeof s !== "object")
                return `"slot" must be an object or null`;
            const faults = s.arcs === undefined ? [] : sift("slot.arcs", s.arcs, arcFault).faults;
            if (!s.name)
                faults.unshift(`slot.name must be a short thing, 1-3 words`);
            return checked(faults, [{ kind, spec: s.spec || s.name, qty: s.qty ?? 1, unit: s.unit || "each",
                    arcs: s.arcs === undefined ? [] : sift("slot.arcs", s.arcs, arcFault).kept }]);
        },
        sanitize: (got, { specs }) => {
            const s = got.slot;
            if (!s || typeof s !== "object" || !s.name)
                return { slot: null };
            const arcs = sift("slot.arcs", s.arcs, arcFault).kept
                .map(a => ({ start: String(a.start), end: String(a.end),
                days: a.days.map(d => String(d).toLowerCase()) }));
            const qty = +s.qty;
            return { slot: stampKnown({
                    name: String(s.name).trim(), emoji: String(s.emoji || "").slice(0, 4),
                    qty: qty > 0 ? qty : 1, unit: String(s.unit || "each"),
                    spec: String(s.spec || s.name).trim(), arcs,
                    where: String(s.where || ""), note: String(s.note || "")
                }, specs) };
        },
    },
    // the omnibar's AI step — a NORMALIZER, not a resolver: it may only rewrite
    // the residual into words the deterministic floor (app/utter.ts) already
    // understands. It never names a verb, a face id, a spec id or a scope id
    // itself — those all come from the floor re-parsing what comes back, which
    // is what keeps this pass unable to invent behaviour the floor wouldn't.
    utter: {
        system: () => `A commons member typed words a simple parser could not fully place. ` +
            `Rewrite them into the SAME kind of words the parser already understands, ` +
            `so it can read them on a second pass. Reply with EXACTLY one JSON object, ` +
            `no prose, no fences: {"rewrite":"<the words, rewritten, or null>"}\n` +
            `The parser understands: a bang for a face ("!map", "!calendar"); dates as ` +
            `YYYY-MM-DD, "today", "tomorrow", "tonight", or a weekday name; clock times ` +
            `as "14:30" or "2pm"; a quantity immediately before its unit ("3 kg", ` +
            `"2 hours"); place names copied VERBATIM from the list given; and a plain ` +
            `English name for whatever is needed or offered. Only rewrite what the ` +
            `words actually said — never add a date, place or quantity nobody stated. ` +
            `When the words already say nothing rewritable (they are already plain, or ` +
            `name nothing the parser's vocabulary below covers), reply {"rewrite":null}.`,
        user: ({ text, faces, places, scopes }) => `residual words: ${text}\n` +
            (faces.length ? `known faces: ${faces.join(", ")}\n` : "") +
            (places.length ? `known places (copy verbatim): ${places.join(", ")}\n` : "") +
            (scopes.length ? `known scopes: ${scopes.join(", ")}\n` : ""),
        check: got => {
            const r = got.rewrite;
            if (r === null || typeof r === "string")
                return null;
            return `"rewrite" must be a string of the rewritten words, or null`;
        },
        sanitize: (got) => {
            const r = got.rewrite;
            return { rewrite: typeof r === "string" && r.trim() && r.trim().length < 200 ? r.trim() : null };
        },
    },
};
// run one pass; null when the AI door is shut or nothing readable came back —
// the caller keeps whatever floor it already has. A reply that fails the
// pass's check is asked again once with the reason; the last readable reply
// is then sanitized (the salvage floor), so a partly-good answer still lands.
export async function runPass(name, ctx) {
    const ai = aiHandler();
    if (!ai)
        return null;
    const pass = PASSES[name];
    const specs = knownSpecs();
    const full = { ...ctx, specs };
    return conform({
        ask: (system, user) => ai(system, user, ""),
        system: pass.system(specs),
        user: pass.user(ctx),
        read: readFirstJSONObject,
        check: got => pass.check(got, full),
        accept: got => pass.sanitize(got, full),
        floor: last => last ? pass.sanitize(last, full) : null,
    });
}
