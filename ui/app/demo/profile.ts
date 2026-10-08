// app/demo/profile.ts — the offline profile: who "you" are in the demo day.
//
// The same "you" the social pool carries (demo/social-pool.ts): the person who
// offers bike repair and asks for bread and childcare. Here is what that person
// says about themselves, in the exact shape the my-skill-standing door answers,
// so the profile block draws one way over either source. Served only while
// the wire brings nothing; an edit offline is kept on this device.
//
// Every row is a skill and what the record shows for it, in hours, and the
// rows are chosen to show every standing a declared skill can have:
//   bike repair     declared; 46.5 h validated, standing at 33.6 today,
//                   co-signed by six
//   baking          declared; 12 h validated, no witness yet, one ceremony
//                   collecting
//   facilitation    declared, and nothing worked under it yet — your word
//   sewing          declared; 7 h validated, worn to 4 by the months since
//   tool care       practice you never declared: the record shows it anyway
//
// The places are the demo day's own (demo.ts lived events).

import type { StandingRow } from '../tabs/social/standing.js';

export const DEMO_STANDING: StandingRow[] = [
  { skill: "bike repair", held: true, hours: 46.5, competence: 33.6, events: 19, witnessed: 14, attesters: 6, witnessedHours: 38, pending: [] },
  { skill: "baking", held: true, hours: 12, competence: 12, events: 6, witnessed: 0, attesters: 0, witnessedHours: 0, pending: [{ count: 1, quorum: 2 }] },
  { skill: "facilitation", held: true, hours: 0, competence: 0, events: 0, witnessed: 0, attesters: 0, witnessedHours: 0, pending: [] },
  { skill: "sewing", held: true, hours: 7, competence: 4.2, events: 4, witnessed: 2, attesters: 2, witnessedHours: 3, pending: [] },
  { skill: "tool care", held: false, hours: 3, competence: 3, events: 2, witnessed: 1, attesters: 2, witnessedHours: 1.5, pending: [] },
];

/** Where the demo's "you" stands and will stand — the location sheet's own three facts. */
export const DEMO_WHERE: { mode: "off" | "here" | "live"; place: string; ahead: { day: string; place: string }[] } = {
  mode: "here",
  place: "repair café",
  ahead: [{ day: "tomorrow", place: "Bakery Vitosha" }, { day: "in 3 days", place: "community farm" }],
};
