// app/keys.ts — every localStorage key the app uses, named once.
//
// A key is a promise to the person's own past: what was written under it last
// month is read under it today. So the names live in one table, each with
// what it holds, and a name that changes carries the name it had — MIGRATE
// moves the value across before anything reads it.
//
// ── THE CONVENTION ──────────────────────────────────────────────────────────
// `pn.<area>.<name>`, lowercase, dots between parts. A key that belongs to
// one identity ends `:<aid>`. The `playnet-` prefix is left to the REPL
// page's organisations, whose Goblins stores are `playnet-<org name>` — an
// app key under that prefix could be an organisation's name.
//
// ── WHO READS THEM ──────────────────────────────────────────────────────────
// Everything under ui/ and browser/lib/ imports the names from here. Three
// readers cannot import and spell the names themselves; tests/browser/
// keys-test.mjs holds each of them to this table:
//   · hoot/day-boot.scm (the spine)      the KEL, the device wire, the mesh seed
//   · hoot/repl.scm (the REPL page)      the identity hint, the KEL, and its own keys
//   · browser/app.html's pre-paint script  the three theme keys
//
// ── THE MIGRATION ───────────────────────────────────────────────────────────
// migrateKeys() runs when this module is first evaluated, and app/store.ts
// imports this module, so it has run before any read through the door. It
// copies, then removes: a value is under its new name before its old name is
// let go, and a store that refuses the copy keeps the old name for the next
// load. It imports nothing.
const table = [];
const prefixes = [];
/** A key. WAS is the name it had before this table. */
const k = (key, holds, was) => { table.push({ key, holds, was }); return key; };
/** A family of keys, one per identity (or face): the name is this prefix and then the id. */
const per = (key, holds, was) => { prefixes.push({ key, holds, was }); return key; };
export const K = {
    // ── identity ──────────────────────────────────────────────────────────────
    idHint: k("pn.id.hint", "who this device remembers: aid|name|email|k0 (the passcode is kept nowhere)", "playnet-keri-id"),
    idKel: k("pn.id.kel", "the controller's own key event log, ordered JSON (written by the spine)", "playnet-keri-kel"),
    idPhc: k("pn.id.phc", "the personhood credential this person carries", "playnet-keri-phc"),
    idVouches: k("pn.id.vouches", "vouches carried by and for this person", "playnet-keri-vouches"),
    idConsent: k("pn.id.consent", "the notices' version this person accepted, and when", "playnet-legal-consent"),
    voteConsent: k("pn.vote.consent", "explicit Art 9(2)(a) consent to record a political opinion against this identity, kept until the operator qualifies under Art 9(2)(d)", "playnet-vote-consent"),
    idNamePending: k("pn.id.name-pending", "a name typed before the commune could be told", "playnet-name-pending"),
    demoBannerSeen: k("pn.demo.seen", "the deployment-status sentence this device has dismissed; reappears when the sentence changes", "playnet-demo-seen"),
    // ── this device ───────────────────────────────────────────────────────────
    deviceId: k("pn.device.id", "this device's id, for its push subscription", "playnet-device-id"),
    deviceWire: k("pn.device.wire", "the device authorization credential, as it crosses the wire (read by the spine)", "playnet-keri-device"),
    deviceMesh: k("pn.device.mesh", "the mesh seed, sealed under the device's seal key (written by the spine)", "playnet-keri-device-mesh"),
    deviceKey: k("pn.device.key", "which tier this device's key is, and its WebAuthn credential", "playnet-keri-device-key"),
    deviceStale: k("pn.device.stale", "the SAID of a device credential the commune has retired", "playnet-device-stale"),
    deviceDeclined: k("pn.device.declined", "the person said no to staying signed in on this device", "playnet-device-declined"),
    meshIdentity: k("pn.mesh.identity", "the anonymous Reticulum key, sealed (lib/rns-identity.js)", "reticulum-identity"),
    // ── what the person keeps ────────────────────────────────────────────────
    logEntries: k("pn.log.entries", "the captain's log, newest first, within its byte budget", "dial-log"),
    logDigest: k("pn.log.digest", "the log's last digest (regenerable)", "dial-log-digest"),
    profile: k("pn.profile", "diet, body, labour hours — the walk's answers", "profile"),
    standing: k("pn.profile.standing.3", "skill standing rows kept for offline", "profile-standing-3"),
    onboardWalk: k("pn.onboard.walk", "where the onboarding walk stands", "onboard"),
    dwelling: k("pn.dwelling", "the dwelling as measured", "playnet-dwelling"),
    home: k("pn.home", "the registered home place", "playnet-home"),
    locationMode: k("pn.location.mode", "how location is shared", "playnet-location-mode"),
    reach: k("pn.reach", "the ways to reach this person", "playnet-reach"),
    bodiesDraft: k("pn.bodies.draft", "a legal body drafted, not yet declared"),
    barcodes: k("pn.barcodes", "barcodes paired with resources", "playnet-barcodes"),
    photoQueue: k("pn.photo.queue", "shots waiting to be read", "playnet-photo-queue"),
    dropoffLog: k("pn.dropoff.log", "the drop-off log", "playnet-dropoff-log"),
    dropoffPlayer: k("pn.dropoff.player", "an anonymous player id, where there is no identity", "playnet-dropoff-player"),
    webDrafts: k("pn.web.drafts", "recipe drafts", "web.drafts"),
    lendLast: k("pn.lend.last", "the last span and rule lent under", "lend:last"),
    feedbackDraft: k("pn.feedback.draft", "an unsent feedback draft"),
    chatSeen: k("pn.chat.seen", "per topic, when it was last read"),
    // ── how the app is set ───────────────────────────────────────────────────
    prefs: k("pn.prefs", "preferences: week start, feedback, dev mode, tabs, home face, currency", "playnet-prefs"),
    theme: k("pn.theme", "the theme's id (read before first paint by app.html)"),
    themeBg: k("pn.theme.bg", "the theme's ground colour (read before first paint)"),
    themeCss: k("pn.theme.css", "the theme's rendered CSS (read before first paint)"),
    scope: k("pn.scope", "the commune last looked at"),
    aiModel: k("pn.ai.model", "the model the orb asks", "dial-ai-model"),
    calendarsOff: k("pn.calendars.off", "calendars switched off", "playnet-calendars-off"),
    dialViews: k("pn.dial.views", "the dial's view toggles", "playnet-dial-views"),
    mapPoisOff: k("pn.map.pois.off", "the families of places the map does NOT label (app/basemap.js)"),
    routeMode: k("pn.map.route.mode", "the mode the route preview opens on: transit, walk, bicycle or drive (app/route/preview.js)"),
    worldClocks: k("pn.world-clocks", "the world clock's rows", "playnet-world-clocks"),
    dockPos: k("pn.dock.pos", "where the voice dock sits", "playnet.dock.pos"),
    panelW: k("pn.panel.w", "the side panel's width", "playnet.panel.w"),
    panelShutNarrow: k("pn.panel.shut.narrow", "the drawer over the stage is shut", "playnet.panel.shut.narrow"),
    planScheduleOpen: k("pn.plan.schedule-open", "the plan's schedule is open", "plan.schedule.open"),
    webCut: k("pn.web.cut", "the recipe web's cut", "web.cut"),
    webDrawing: k("pn.web.drawing", "the recipe web's drawing", "web.drawing"),
    webFlow: k("pn.web.flow", "the recipe web shows flow", "web.flow"),
    webSectors: k("pn.web.sectors", "the recipe web shows sectors", "web.sectors"),
    ambientOn: k("pn.ambient.on", "the ambient piece is playing", "ambient-on"),
    ambientVolume: k("pn.ambient.volume", "its volume", "ambient-volume"),
    capNotice: k("pn.capNotice.dismissed", "the capability notice this person dismissed (lib/capabilities.js)"),
    // ── the REPL page's own (hoot/repl.scm spells these) ─────────────────────
    replCredentials: k("pn.repl.credentials", "credentials the REPL holds, a Scheme datum", "playnet-keri-credentials"),
    replContacts: k("pn.repl.contacts", "the REPL's contact lines", "playnet-keri-contacts"),
    replOrgs: k("pn.repl.orgs", "the names of the organisations kept on this device", "playnet-index"),
    replPriorities: k("pn.repl.priorities", "the priority tree", "playnet-prio-tree"),
    replCalEvents: k("pn.repl.cal-events", "the REPL calendar's events", "playnet-cal-events"),
    replCalPeople: k("pn.repl.cal-people", "the REPL calendar's people", "playnet-cal-people"),
    replSyntax: k("pn.repl.syntax", "lisp or wisp", "playnet-syntax-mode"),
    // ── families: the name is the prefix, then the id ────────────────────────
    ringAvail: per("pn.ring.avail:", "availability arcs, per identity (or `local`)", "playnet-avail-"),
    ringEvents: per("pn.ring.events:", "the person's own events, per identity (or `local`)", "playnet-events-"),
    pins: per("pn.pins:", "the pin book, per identity (or `anon`)"),
    slotsTwin: per("pn.slots.twin:", "the share bar's standing orders, per identity"),
    panelShutFace: per("pn.panel.shut.face.", "the side panel is shut, per face", "playnet.panel.shut.face."),
};
/** Every key and family, with what it holds — for a reader, a lint, a doc. */
export const KEY_TABLE = table;
export const KEY_FAMILIES = prefixes;
/**
 * Move every value kept under a former name to its name in the table.
 * Returns how many moved. STORE is the device's localStorage.
 */
export function migrateKeys(store) {
    let moved = 0;
    const move = (from, to) => {
        const old = store.getItem(from);
        if (old === null)
            return;
        // a value already under the new name is the newer one
        if (store.getItem(to) === null)
            store.setItem(to, old);
        store.removeItem(from);
        moved++;
    };
    for (const e of table)
        if (e.was)
            move(e.was, e.key);
    const families = prefixes.filter(e => e.was);
    if (families.length) {
        const names = [];
        for (let i = 0; i < store.length; i++) {
            const n = store.key(i);
            if (n !== null)
                names.push(n);
        }
        for (const n of names)
            for (const e of families)
                if (n.startsWith(e.was))
                    move(n, e.key + n.slice(e.was.length)); // filtered to those with a former prefix
    }
    return moved;
}
// A device whose storage is blocked has nothing to move; one that refuses a
// write part-way keeps the remaining old names, and the next load goes on.
try {
    if (typeof localStorage !== "undefined")
        migrateKeys(localStorage);
}
catch (_) { /* the next load tries again */ }
