# FUTO — introduction email draft

> **Status: DRAFT for user review → email to grantapps@futo.org**
> Rolling. Three lanes: Legendary (established projects — we're early),
> Microgrants ($1–5k, mostly unsolicited — an introduction is the right
> move), **Fellows** ($40k + flights + housing for ~3 months at their
> Austin TX campus — conditional on residency feasibility).
> No published AI policy; FUTO's whole thesis — "computers belong to
> you", challenging the tech oligopoly — is playnet's story almost
> verbatim.

## Email draft

Subject: playnet-compute — a browser-native machine-resource commons
(FUTO intro)

Hi —

I'm building playnet-compute, an AGPL-licensed commons where a browser
tab is an accountable machine-resource node: no daemon, no install, no
datacenter. Members lend spare compute/storage/bandwidth as
content-addressed job envelopes; every result is a signed replayable
receipt; settlement is mutual credit by default with optional sats
payout at the treasury edge.

What's shipped and test-covered (~720 checks, 489 commits,
`rad:z2xjyuu4adoo1x88is8xtRz2tYwhu` on Radicle):

- The commons core: lane offers → dispatch claims → signed receipts,
  KERI identity, ValueFlows accounting, federation.
- Swarm coordination across tabs (work bigger than any one node) and a
  member-first governor (your machine is yours — claims preempt
  honestly).
- The demand edge: `POST /api/demand/*` translates the wire shapes
  buyers already use (OpenAI-style chat, fetch, checks, load-test, S3)
  into commons jobs, against prepaid/postpaid customer books.
- A NIP-90 DVM so tabs earn sats for compute over nostr — the payer
  rail that needs no corporate stack at all.
- Reticulum mesh intake: off-WiFi users submit jobs and receive signed
  receipts through store-and-forward mailboxes.

It's the shape of the problem FUTO funds: machine capacity shouldn't be
rented back to us by three clouds. A tab is a node, credit is the
default, and the oligopoly networks appear only as fallback providers —
never as the gate.

Two things I'd value:

1. Whether a microgrant or early relationship makes sense for work at
   this stage.
2. If there's interest in the Fellows program — a quarter at the Austin
   campus to take the demand edge to a production launch.

(Full disclosure: development uses an AI software agent under my
direction; commits carry provenance.)

— terex

## Notes

- Legendary grants need "established entities we trust" — the intro is
  the relationship start, not a direct ask.
- Fellows: confirm 3-month Austin residency feasibility before
  mentioning it as more than "if there's interest."
- Repo is Radicle — include the explorer link in the email so they can
  browse: <https://app.radicle.xyz/> + RID
  `rad:z2xjyuu4adoo1x88is8xtRz2tYwhu`.

## Sources

- <https://futo.tech/grants> · <https://futo.tech/grants/fellows>
