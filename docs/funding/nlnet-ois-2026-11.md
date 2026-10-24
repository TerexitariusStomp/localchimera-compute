# NLnet Open Internet Stack — Restack — deadline Nov 3 2026, 12:00 CET

> **Status: RESEARCH BRIEF — eligibility in question, user decision required.**
> This is not a paste-ready application. Two independent eligibility
> problems must be resolved before anything is submitted.

## Why it was the top pick

Restack funds "operational internet commons … from middleware without
vendor lock-in to 'local-first' infrastructure … collective pooling of
resources and capabilities" — a near-verbatim description of
playnet-compute. €5k–50k, ~9–12 months, rolling every two months after
Nov 3 (next ~Jan 3, Mar 3…). First proposals cap at €50k; >€50k
triggers an independent security audit.

## The two eligibility problems

### 1. GenAI policy v2.0 (published Oct 20, 2026 — covers this deadline)

<https://nlnet.nl/news/2026/20261020-AI-policy.html>

- "Generative AI can no longer be used for **writing** proposals"
  (accessibility exception only). → **The application text must be
  human-written.** I cannot draft it.
- "For **project development** the use of LLMs and diffusion models is
  confined to read-only usage." → This codebase is substantially
  agent-written; every commit carries `Generated with Devin`
  provenance. Unless NLnet reads "development" narrowly (the *funded
  work* rather than the existing codebase), the project itself appears
  ineligible. Their office hours exist for exactly this question
  (next: Oct 28 — passed; they recur).

### 2. Scope clause

"AI-related projects are not within scope" unless widely used (>1M
users). playnet-compute is infrastructure, not an AI project — but it
*does* run inference envelopes, so the application must frame
accurately: resource-commons plumbing where inference is one envelope
kind among exec/store/relay/sense. Frameable, but combined with (1) the
odds lengthen.

## The honest options

1. **Ask NLnet directly** (info@nlnet.nl or office hour): "project
   developed with AI-agent assistance under human direction, disclosed
   in commits — eligible under v2.0?" If yes → human-written proposal
   for the Jan 3 cycle, no sprint needed.
2. **Skip NLnet** and put the effort into OpenSats/HRF/OTF, none of
   which ban this.
3. **Apply anyway without addressing it** — not recommended; reviewers
   verify provenance and a discovered concealment ends the
   relationship, not just the application.

## If eligible: the proposal skeleton (for human authorship)

- **Title:** playnet-compute — a browser-native machine-resource commons
- **Summary:** tabs are accountable nodes; envelopes in, signed
  receipts out; mutual-credit settlement; demand enters through
  OpenAI-shaped HTTP, nostr NIP-90, and Reticulum mesh.
- **Strategic fit:** local-first infrastructure, collective pooling,
  no-vendor-lock-in middleware — cite Restack's own wording back.
- **Milestones:** M1 deploy €9k → M2 billing €7k → M3 DVM €10k →
  M4 mesh €10k → M5 security €7k ≈ **€43k over ~10 months** (under the
  €50k first-proposal cap).
- **Value for money:** 489 commits + ~720 checks already green before
  funding starts; the ask is hardening + shipping, not greenfield.
- **Sustainability:** demand-side revenue is already wired
  (demand desk, payer ledger); mutual credit sustains non-fiat exchange.

## Sources

- Call: <https://nlnet.nl/news/2026/20260903-call.html>
- Theme: <https://nlnet.nl/restack/>
- GenAI v2.0: <https://nlnet.nl/news/2026/20261020-AI-policy.html> ·
  policy text <https://nlnet.nl/foundation/policies/generativeAI/>
