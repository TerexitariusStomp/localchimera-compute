// app/route/ledger.ts — a journey as a LEDGER fact.
//
// A real trip is an observation like any other: begin mints the journey commitment and its pickup event, end records
// the dropoff fulfilling it — and the planner's transport coefficients learn from this very walk (solve/routing.scm's
// table). A destination the scope KNOWS goes by its location id; anywhere else goes faithfully as geo:lat,lng
// (recorded, priced later).
import { HANDLERS, EXT } from '../core.js';
import { locationOptions } from '../slots/model.js';
const geoRef = (p) => `geo:${p.lat.toFixed(5)},${p.lng.toFixed(5)}`;
const placeRef = (name, at) => {
    const l = locationOptions(EXT).find(x => x.name === name);
    return l ? l.id : geoRef(at);
};
/**
 * Begin a journey from `from` to `dest` by `costing`. Where the door is absent the journey is simply not recorded; a begin
 * the ledger refuses is handed to `refused` (the person is told where to go) and recorded as nothing.
 */
export function beginJourney(from, dest, place, costing, refused = () => { }) {
    let cid = null;
    HANDLERS.journey?.("begin", geoRef(from), placeRef(place, dest), costing, "")
        .then((r) => {
        if (r && r.startsWith("ok:") && r.length > 3)
            cid = r.slice(3);
        else
            refused(r);
    });
    return {
        end(at) {
            if (!cid || !HANDLERS.journey)
                return;
            HANDLERS.journey("end", geoRef(at), placeRef(place, dest), costing, cid).then(() => { });
            cid = null;
        },
    };
}
