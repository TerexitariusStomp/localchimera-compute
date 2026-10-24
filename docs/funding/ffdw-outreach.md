# FFDW — partnership outreach draft

> **Status: DRAFT for user review → outreach email**
> Filecoin Foundation for the Decentralized Web funds dweb development
> via partnerships/RFPs rather than a rolling open form — the move is a
> warm introduction email, not a form. Their funded projects include
> **Spritely — Christine Lemmer-Webber's project, which wrote the
> Goblins actor library this codebase runs on**. That connection is the
> honest hook: their portfolio is our substrate.
> Contact: via <https://ffdweb.org/> → their programs/contact page
> (confirm current contact path before sending; also reachable through
> DWeb community channels).

## Email draft

Subject: localchimera — machine-resource commons on the
Spritely/Goblins stack (FFDW intro)

Hello FFDW team —

I'm building localchimera, an AGPL machine-resource commons:
browser tabs act as accountable nodes contributing compute, storage,
relay, and sensing — jobs are content-addressed envelopes, results are
signed replayable receipts, settlement is mutual credit with optional
sat payout. The actor substrate is Goblins (the same object-capability
runtime FFDW supports via Spritely), and the capability-door protocol
that exposes every commons operation is built directly on it.

Where FFDW's mission and the roadmap intersect:

- **Decentralized infrastructure people actually consume:** demand
  enters through wire shapes buyers already speak — OpenAI-style HTTP,
  S3 PUT/GET — and through Reticulum mesh for off-grid users, so the
  commons is usable without adopting new tooling.
- **Content-addressed work:** helia is already vendored for the
  IPFS-facing fetch/pin legs; envelopes, images, and results are all
  hash-addressed and receipt-bound.
- **Resilience over centralization:** supply is pooled across
  communities rather than a provider; external networks exist only as
  explicit fallback legs, never as the gate.

489 commits, ~720 green test checks, spec'd in the open
(`spec/localchimera.md`), Radicle-hosted
(<https://github.com/TerexitariusStomp/localchimera-compute>). The next work — a public
gateway, the demand-API launch, and mesh GA — is what a development
partnership would fund.

Would this fit FFDW's development portfolio, and is an exploratory
conversation possible?

— terex

## Notes

- FFDW is a 501(c)(3) *nonprofit* — distinct from Filecoin
  Foundation's dev-grants (which require MIT/Apache dual-license;
  FFDW's partnership model has no such stated requirement — verify in
  conversation).
- If they respond, the strongest artifact is a live demo — flag M1
  (public deploy) as the accelerant.

## Sources

- <https://ffdweb.org/> · <https://ffdweb.org/faqs>
