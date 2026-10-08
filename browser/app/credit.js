// app/credit.ts — ONE reading of the citizen's certificate, for every face.
//
// The wire's credit block (seam.ts Credit, derived server-side from the event
// log) when the gateway has answered; the demo citizen's numbers before then,
// so every face draws the same person offline. The demo pending is the
// silence rail's window: hours of diffuse work standing open to the scope.
import { EXT } from './core.js';
export const DEMO_CREDIT = {
    gross: 46, claimed: 12.5, drawable: 33.5, capacity: 46,
    pool: 480, voice: 0.062, freeTime: 0.31, pending: 5,
};
export const liveCredit = () => (EXT.credit && isFinite(Number(EXT.credit.drawable)) ? EXT.credit : null);
export const creditNow = () => liveCredit() || DEMO_CREDIT;
