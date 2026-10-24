;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; legal/policy.scm — the ONE governance datum of the legal arc.
;;;
;;; Everything else the legal layer needs it reads or derives: which crossings a
;;; recipe trips comes off its own specs, which jurisdictions it stands in off
;;; the containment climb, which rules stand off their guards and windows,
;;; whether a permit is held off the observer's event log. One number remains a
;;; CHOICE, and a choice belongs to governance rather than to this file:
;;;
;;;   uncertain-forbid   (lo hi alpha w) — how much legally-UNCERTAIN activity
;;;                      this scope will carry. A prohibition the law is sure of
;;;                      removes the column; one a pack is only unsure of becomes
;;;                      a `frag` barrier, and this profile is its tip and weight.
;;;                      tip = quantile(alpha, lo, hi), in the act's own units.
;;;
;;; `tension-registry.scm` says a fragility's tip and weight are
;;; "political-economic choices, made by stewardship scopes and ratified at the
;;; UC level" — but that registry holds the KINDS (the φ math, federation-wide).
;;; A scope's own tolerance is a scope's own, so it rides the plan-store's meta
;;; rail under its own key, read through one door: a caller's explicit keyword
;;; wins over the row, the row wins over the default, and a store with no
;;; meta rail (a mock, #f) reads the default.
;;;
;;; This LOOKS like the eco-catalogue's fragilities (eco-catalogue.scm) — same
;;; `frag` barrier, same tip/weight/α shape — but the two govern different
;;; UNKNOWNS, and that is what puts them at different custody levels. An
;;; eco-cap is uncertainty about NATURE'S OWN LIMIT: a real threshold, known
;;; imprecisely, but one fact everyone touching it shares — so it is ONE
;;; catalogue, UC-ratified, and no scope gets its own opinion of where a
;;; planetary boundary actually sits. `uncertain-forbid` is uncertainty about
;;; WHAT THE LAW ITSELF SAYS: a pack's coverage that has not resolved a
;;; question, so there is no single fact to ratify — ratifying it would mean
;;; the ambiguity got settled, and it would stop being uncertain-forbid.
;;; What is left is each scope's own risk posture toward a rule its own
;;; reading has not pinned down, which is exactly why this rides a per-scope
;;; row with no UC step, while the eco-catalogue rides a federation actor.
;;;
;;; The row is `(set-meta "legal-policy" '((uncertain-forbid . (0.0 1.0 1.0 100.0))))`.
;;;
;;; On the DEFAULT weight: it is not the old flat 1000.0 cost carried across.
;;; Measured against what the barrier is for — ease off before the limit, do not
;;; merely pay through it — w≤1 runs a plan flat to the tip (a cap, not a
;;; tension) and w=1000 suppresses the act entirely (a prune in disguise). w=100
;;; lands it at 70–85% of what is tolerated. That BEHAVIOUR is pinned in
;;; test-legal-tension.scm rather than the number, so a commune re-weighting this
;;; can see whether it still means what is written here.

(define-module (localchimera legal policy)
  #:use-module (localchimera utils governed-row)
  #:export (legal-policy *legal-policy-defaults*))

(define *legal-policy-defaults*
  '((uncertain-forbid . (0.0 1.0 1.0 100.0))))

(define* (legal-policy plan-store key #:optional (explicit #f))
  "The governed value for KEY: EXPLICIT when given, else the plan-store's
   legal-policy row, else the default."
  (governed-row plan-store "legal-policy" *legal-policy-defaults* key explicit))
