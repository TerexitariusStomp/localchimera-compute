;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; vf/facts/away.scm — a signed declaration, over an away: tag's own text.
;;;
;;; docs/planning/food/reproduction-of-labour-power.md §2c/§7: the declaration
;;; itself needs no proof — a person's word is the floor, and signing raises
;;; trust rather than gating the plan (§2c "the scope's option"). The
;;; declaration's own tag text, "away:FROM..TO:kind" (agent-time.scm's
;;; agent-away-dates parses exactly this), is already the whole statement a
;;; person makes; there is no separate document to construct or hash, so
;;; signing IT directly under the person's own KERI identity — citizen-sig's
;;; sign-said / verify-said-signature, the same primitive a citizen already
;;; signs their own VRCs with — is the whole of what "signed" means here.
;;;
;;; Deliberately OUTSIDE the planner engine's Hoot/WASM closure: citizen-sig
;;; pulls in Ed25519 and CESR, weight the wasm bundle does not need to carry
;;; for a plan that already reads away: unsigned (agent-time.scm, live.scm —
;;; untouched by this module). A scope that wants the raised trust verifies
;;; here, at the gateway or the governance layer, before acting on the
;;; declaration with any elevated confidence; the plan's own reading is the
;;; same whether or not a signature ever exists.
;;;
;;; Resolving a person's agent-id to their KERI AID is the personhood policy's
;;; own question (`keri/first-person/personhood-policy.scm`, `governance/enrollment-
;;; ceremony.scm`) — SIGNER-AID is a parameter here, never looked up.
;;; Producing a signature needs a device that holds the person's key; the
;;; browser side of that is a separate, larger, already-tracked question
;;; (browser-resident Signify) this module does not answer — it only makes
;;; verifying one, once it exists, a two-line call rather than a new design.

(define-module (playnet vf facts away)
  #:use-module ((playnet keri citizen-sig)
                #:select (sign-said verify-said-signature))
  #:export (sign-away-declaration verify-away-declaration))

(define (sign-away-declaration away-tag keypair)
  "Sign AWAY-TAG (the exact \"away:FROM..TO:kind\" text) under KEYPAIR.
   Returns a CESR qb64 Ed25519 signature — the whole of a \"signed
   declaration\", since the statement IS the tag and nothing else need be
   built to carry it."
  (sign-said away-tag keypair))

(define (verify-away-declaration away-tag sig-qb64 signer-aid)
  "#t iff SIG-QB64 is SIGNER-AID's own signature over AWAY-TAG's exact text.
   A scope reads this before raising its trust in a declaration (§2c); the
   plan itself asks for no such thing — a sick day is declared, not proved."
  (verify-said-signature away-tag sig-qb64 signer-aid))
