// app/demo/forum.ts — the forum's offline docket.
//
// The demo day has recipes, needs, a pool of means and a roster of communes;
// the forum's demo threads are born from THOSE objects, the way a live
// proposal is: every thread names its subject as a "kind:id" ref, and the
// face resolves it against the same demo fixtures the other faces read
// (demo.ts recipes/needs, demo/social-pool.ts, scopes).
// So a thread about the sourdough recipe opens the same recipe the recipes
// face shows, and a thread about bread the same need the plan draws.
//
// Demo voice: producer voice is PER SCOPE (your labour share there); consumer
// voice is one number over the federation — the same 6.2% the shop's demo
// credit carries. Delegations: a federation-default share and one per-scope
// override, so the voice map has something to show in every cell.
//
// The same discipline as the rest of demo.ts: the seam wins wherever it
// speaks (a commune has answered with its roster → the demo docket is never read).

/** One demo proposal, as the wire would carry it plus its counted result. */
export interface DemoProposal {
  id: string;
  status: "open" | "closed";
  kind: "ballot" | "expression";
  domain: string;
  /** The question, in the proposer's words. */
  text: string;
  /** What it is about, as "kind:id". */
  subject?: string;
  franchise: string;
  tally: Record<string, number>;
  /** Days ago it was opened — the list orders by it. */
  age: number;
}

/** One message under a demo thread. */
export interface DemoMessage {
  id: string;
  author: string;
  stratum: string;
  body: string;
  [key: string]: unknown;
}

export interface DemoDelegation {
  to: string;
  fraction: number;
  mandated?: boolean;
  /** A per-scope override; absent = the federation default. */
  scope?: string;
}

export interface DemoForum {
  proposals: DemoProposal[];
  discussion: Record<string, DemoMessage[]>;
  /** Your producer voice by scope id, and your one consumer voice. */
  voice: { consumer: number; producer: Record<string, number> };
  delegations: DemoDelegation[];
}

export const DEMO_FORUM: DemoForum = {
  proposals: [
    { id: "p-recipe-sourdough", status: "open", kind: "ballot", domain: "recipe", franchise: "scope",
      text: "Adopt the sourdough loaf as how Berlin/Brandenburg makes its bread?", subject: "recipe:rp-sourdough",
      tally: { yes: 0.41, no: 0.12 }, age: 2 },
    { id: "p-capacity-oven", status: "open", kind: "ballot", domain: "capacity", franchise: "scope",
      text: "Bring Noor's wood oven into the commune's use-pool for the bread runs?", subject: "slot:means:noor:spec-bread",
      tally: { yes: 0.22, abstain: 0.05 }, age: 1 },
    { id: "p-desire-warmth", status: "open", kind: "expression", domain: "desire", franchise: "federation",
      text: "Raise the priority of warmth for the winter — it is only 58% met.", subject: "need:shelter/warmth",
      tally: { yes: 0.31, no: 0.26 }, age: 4 },
    { id: "p-plan-childcare", status: "open", kind: "ballot", domain: "plan", franchise: "scope",
      text: "Provision the Tuesday childcare afternoons from the common plan?", subject: "slot:need:you:spec-childcare",
      tally: {}, age: 0 },
    { id: "p-formation-oakland", status: "open", kind: "ballot", domain: "formation", franchise: "federation",
      text: "Federate the Bay Area communes with Oakland?", subject: "scope:E_commune_Oakland",
      tally: { yes: 0.18, no: 0.02 }, age: 6 },
    { id: "p-recipe-greens", status: "closed", kind: "ballot", domain: "recipe", franchise: "scope",
      text: "Keep the garden greens on the allotment rather than the roof?", subject: "recipe:rp-garden-greens",
      tally: { yes: 0.62, no: 0.21, abstain: 0.04 }, age: 19 },
    { id: "p-policy-library", status: "closed", kind: "ballot", domain: "policy", franchise: "federation",
      text: "Open the tool library to the neighbouring commune on weekends?", subject: "scope:E_commune_SF",
      tally: { yes: 0.35, no: 0.44 }, age: 33 },
    { id: "p-desire-meals", status: "closed", kind: "expression", domain: "desire", franchise: "federation",
      text: "Weight shared meals above fresh veg for the spring plan.", subject: "need:nourishment/meals",
      tally: { yes: 0.55, no: 0.10 }, age: 41 },
  ],
  discussion: {
    "p-recipe-sourdough": [
      { id: "m1", author: "Luca", stratum: "committed", body: "The stone mill is back, so the flour is ours end to end — the loaf recipe finally stands on its own inputs." },
      { id: "m2", author: "Noor", stratum: "willing", body: "Nine runs a week is the plan's number. My oven takes four loaves a bake; two bakes a day covers it if someone shapes the dough the night before." },
      { id: "m3", author: "Ana", stratum: "public", body: "Does the rye field's harvest actually cover the grain? The recipe cites 2 kg flour a loaf." },
      { id: "m4", author: "Luca", stratum: "committed", body: "Yes — the field step produces 1.5 t a season, the mill has slack. It's the labour, not the grain, that's short." },
    ],
    "p-capacity-oven": [
      { id: "m5", author: "Noor", stratum: "committed", body: "It's a means I hold, not one I want to own the schedule of. Custody stays with me; the commune plans its use." },
      { id: "m6", author: "Mira", stratum: "public", body: "Does that make the bread runs fragile on one oven? Worth a second one in the capacity buffer." },
    ],
    "p-desire-warmth": [
      { id: "m7", author: "Kai", stratum: "public", body: "58% met means the cold rooms stay cold in January. Priority up moves fuel and hours toward it in the next solve." },
      { id: "m8", author: "Priya", stratum: "willing", body: "I'd rather insulate than burn — is there a recipe for that in the library yet?" },
    ],
    "p-plan-childcare": [
      { id: "m9", author: "Sam", stratum: "public", body: "Three households asked for the same afternoon. One provisioned slot beats three private arrangements." },
    ],
    "p-formation-oakland": [
      { id: "m10", author: "Ana", stratum: "public", body: "Their planner already reads our folksonomy; merging the labour pools is the real change." },
    ],
    "p-recipe-greens": [
      { id: "m11", author: "Priya", stratum: "committed", body: "The roof beds baked in July. The allotment has the water." },
    ],
    "p-policy-library": [
      { id: "m12", author: "Kai", stratum: "public", body: "Lost narrowly — the tools came back late twice. Try again with a steward on Saturdays." },
    ],
  },
  voice: {
    consumer: 0.062,
    producer: { E_commune_Berlin: 0.18, E_commune_SF: 0.07, E_commune_Oakland: 0 },
  },
  delegations: [
    { to: "Ana", fraction: 0.25, mandated: true },
    { to: "Luca", fraction: 0.4, scope: "E_commune_Berlin" },
  ],
};
