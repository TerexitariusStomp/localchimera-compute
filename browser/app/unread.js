// app/unread.ts — how many messages a topic has that you have not seen.
//
// free-association's getReactiveUnreadCount, on our chat: a topic's history
// (which also registers a live watch on the gateway) against the moment you
// last looked at it, kept in the browser (store.ts); live pushes bump the
// count for every topic that is not the one open, and mark the open one seen
// as they land. The count is a signal per topic, so a 💬 badge on a card
// redraws itself.
//
// One subscriber on the chat push (seam.ts's fan-out — chat.ts is the other):
// runs for every topic, alongside chat.ts's own reader for the open one.
import { signal } from './reactive.js';
import { HANDLERS } from './core.js';
import { readJSON, writeJSON } from './store.js';
import { on } from './bus.js';
import { K } from "./keys.js";
const SEEN = K.chatSeen; // topic → t of the last message seen
const seen = readJSON(SEEN, {});
const counts = signal({});
const asked = new Map(); // topic → when history was last read
let openTopic = null;
const RECHECK = 60_000;
/** The unread count of a topic, reactively (0 until known). */
export const unreadOf = (topic) => counts()[topic] || 0;
/** You are looking at it now — nothing there is unread, and pushes on it stay seen. */
export function markSeen(topic, t) {
    seen[topic] = Math.max(seen[topic] || 0, t || Math.floor(Date.now() / 1000));
    writeJSON(SEEN, seen);
    if (counts.peek()[topic])
        counts.set({ ...counts.peek(), [topic]: 0 });
}
/** The chat sheet's open topic — its pushes are seen as they land. */
export function chatOpen(topic) {
    openTopic = topic;
    if (topic)
        markSeen(topic);
}
/** Read these topics' histories (once a minute at most) and count what is newer than seen. */
export function trackUnread(topics) {
    if (!HANDLERS.chat)
        return;
    const now = Date.now();
    for (const topic of topics) {
        if ((asked.get(topic) || 0) > now - RECHECK)
            continue;
        asked.set(topic, now);
        HANDLERS.chat("history", topic, "").then(r => {
            if (typeof r !== "string" || !r.startsWith("["))
                return;
            try {
                const msgs = JSON.parse(r);
                const since = seen[topic] || 0;
                const n = topic === openTopic ? 0 : msgs.filter(m => (Number(m.t) || 0) > since).length;
                if ((counts.peek()[topic] || 0) !== n)
                    counts.set({ ...counts.peek(), [topic]: n });
            }
            catch (_) { }
        });
    }
}
// live pushes: the open topic is seen as it lands; every other topic counts up
on("chatMessage", (topic, message) => {
    const msg = message;
    if (topic === openTopic)
        markSeen(topic, Number(msg && msg.t) || undefined);
    else
        counts.set({ ...counts.peek(), [topic]: (counts.peek()[topic] || 0) + 1 });
});
