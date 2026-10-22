# spec/ui-recompose.md — P6: the face dispositions

The inventory's two-tier rule applied to `ui/app/tabs/` (24 faces,
~10.5k lines): **the product's own faces stay custom** — the faces a
commons member lives in daily are the app's identity; **admin-shaped
CRUD faces recompose over refine/react-admin**, and faces that are
fronts for delegated backends become thin adapter faces against the
upstream's own API.

The faces are grouped by the app's own nav (browser/app.html): start
here / your day / the commons / how it holds / what it knows.

## Tier 1 — the focus (stays custom, ~3 faces)

| Face | Why it stays |
|---|---|
| `lend` (216) | the compute node IS this tab — offer lanes, claim jobs, run work, disputes. No framework sells it. |
| `onboard` (220) | the first walk — the product's own voice. |
| `map/` + `calrail` (413) | the earth view — MapLibre spatial, already adopted-lib; the face is layout, not CRUD. |

## Tier 2a — recompose over refine (admin-shaped CRUD)

**Correction after reading the faces (2026-10-21):** the tabs are not
generic CRUD — they are bespoke reactive panels over the app's shared
signal graph (S.root, stockData, PLAN, PLACES, the desire spine).
`inventory.ts` draws rail-grouped stock from `store-data`, `taxonomy.ts`
is a D3 treemap of the aggregated desire tree. Porting them to refine
means porting the state model, not the widgets — refine buys a data
grid, not the face. The refine target is narrower than first counted:
the admin-shaped slices below are the only ones that genuinely recompose;
the domain-viz faces stay custom but thin (their residue is the face,
not the backend — the backend rows already come from delegated seams).

| Face (lines) | Refine resource | Upstream the rows come from |
|---|---|---|
| `inventory` (207) | stock list/edit | hREA / Odoo stock.buffer |
| `store` (227) | places & containers | hREA agents/locations |
| `matter` (217) | resource flows | hREA EconomicEvents |
| `taxonomy` (153) | folksonomy terms | Jena corpus |
| `corpus` (154) | source texts | Jena corpus |
| `recipes` (182) + `recipe-render` (187) | recipe library | Jena corpus |
| `contacts` (465) | members/agents | keria + hREA agents |
| `match` (431) | needs/offers table | registry rows |
| `law` (1005) | jurisdiction rules report | OPA policy results |
| `fragility` (757) | safe-operating-space report | federation metrics |

## Tier 2b — thin adapter faces (front the delegated backend's own API)

These faces exist to drive a backend the plan delegates; the backend's
own UI or API covers most of the surface — the residue is the seam.

| Face (lines) | Delegates to | What stays |
|---|---|---|
| `governance` (481) | Decidim | the door/session glue (~50); Decidim ships ballots+admin |
| `plan` (503) | OR-Tools + Temporal | the plan-of-record viewer over solver answers |
| `calendar` (1331) | Radicale | FullCalendar already the lib; CalDAV wire replaces door reads |
| `web` (1067) + `web-draft` (232) | Jena (graph) | recipe-graph viz over SPARQL |
| `family` (841) | cc-node + hREA | the purse view over the ledger |
| `shop` (958) | hREA orders + cc-node | order book over ledger |
| `ecology` (253) | agents as hREA | agent registry view |
| `social/` | ActivityPub | presence over the outbox |
| `onboard`'s walk data | — | covered above |

## The honest residue estimate

- ~3 faces stay bespoke (~850 lines): lend, onboard, map/calrail.
- ~8 faces become a shared adapter-face helper (~300): one `list-face`
  wrapper that takes (resource, columns, row→record) — the repeated
  pattern in the Tier-2a table.
- ~10 faces shrink to delegate calls through the ~1k adapter residue
  the inventory already budgets.
- Everything else is upstream UI: Decidim's ballot UI, Fuseki's
  query UI, Odoo's stock UI — the member doesn't need our face at all
  for admin tasks.

## Order

P6 lands per-face, gated the same way as module shrinks: a face
recomposes only after its upstream answers (the parity env vars) and
the face's wire calls route through the delegate — never directly at
the door the upstream now owns.
