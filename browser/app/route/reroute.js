// app/route/reroute.ts — when you have left the way.
//
// A fix beside the line is not yet a wrong turn: a phone's position wanders by its own accuracy, and
// a corner is cut. You are off the way when you have been beyond its reach for several fixes running,
// the reach being the larger of a floor and a multiple of the fix's own doubt. Having asked for a new
// way — and whether it came — the watcher holds still for a while, so one stray stretch is not asked
// about over and over. A ride is never off the way: a vehicle follows its own line, and the position
// of a person on it says nothing of what the rider should do.
//
// Pure: it is told how far off each fix is and when it was, and answers whether to ask again.
export function offRouteWatch(o = {}) {
    const floorKm = o.floorKm ?? 0.03, factor = o.accuracyFactor ?? 2, need = o.fixes ?? 3, cooldownMs = o.cooldownMs ?? 20_000;
    let run = 0, holdUntil = 0;
    return {
        see(offKm, accuracyM, now, riding) {
            if (riding || now < holdUntil) {
                run = 0;
                return false;
            }
            const reach = Math.max(floorKm, factor * (accuracyM ?? 0) / 1000);
            run = offKm > reach ? run + 1 : 0;
            return run >= need;
        },
        asked(now) { run = 0; holdUntil = now + cooldownMs; },
        reset() { run = 0; },
    };
}
