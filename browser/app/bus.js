// SPDX-License-Identifier: AGPL-3.0-or-later
// app/bus.ts — the app's own wires: one topic, many readers.
//
// Two kinds of traffic ran over the seam that never crossed a language
// boundary: a push from the spine that more than one face wanted (grants,
// chat, the slot pool), and a module telling another that something it owns
// changed (the plan landed, the recipes reloaded, stock moved). Both are one
// wire with more than one reader, and both are TypeScript talking to
// TypeScript. This module carries them; the seam carries only what the spine
// and the app actually exchange.
//
// A topic is a name and its argument list, typed once in Topics. `on` adds a
// reader, `emit` calls every reader in order; a reader that throws does not
// stop the ones behind it, and a topic with no reader is a push nobody wanted
// yet, never an error. A leaf module: nothing here imports anything at runtime.
const readers = {};
/** Read TOPIC. Returns the unsubscribe. */
export function on(topic, fn) {
    const list = (readers[topic] ||= []);
    list.push(fn);
    return () => { const i = list.indexOf(fn); if (i >= 0)
        list.splice(i, 1); };
}
/** Tell every reader of TOPIC. */
export function emit(topic, ...args) {
    const list = readers[topic];
    if (!list)
        return;
    [...list].forEach(fn => {
        try {
            fn(...args);
        }
        catch (e) {
            console.warn(`[bus] ${topic} reader threw`, e);
        }
    });
}
