;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; law/product.scm — the product's own acts, stated to the same law.
;;;
;;; The legal layer reads what an activity in the world trips: a kitchen, a
;;; shelter, a border. The product acts too. It holds a member's funds, credits
;;; their work, keeps what they say of their body and where they are, carries
;;; their messages, sends their words to a model. Each is a crossing, and the
;;; bill of a feature at a place is the same fold a food stall gets
;;; (`bill-at`), read the same way (`bill-stance`).
;;;
;;; This module is the one statement of:
;;;   · the crossings the product's features trip          (*product-crossings*)
;;;   · which part of the face each feature is, and its doors  (*product-features*)
;;;   · the notices the product shows about itself         (*product-notices*)
;;;
;;; tools/emit/emit-product-law.scm writes it out as ui/app/legal-product.ts, so the
;;; browser's consent version, licence line and attribution are these, and
;;; `make check-product-law-fresh` holds the copy to its source.
;;;
;;; A feature's stance reads the packs. Where no rule speaks of one of its
;;; crossings at a place, the stance is `unread`; a steward who reads it and
;;; finds the law asks nothing writes a rule with no demands, and it is `open`.

(define-module (localchimera knowledge law product)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera doors protocol) #:select (doors-of-feature door-object door-name))
  #:use-module (localchimera legal crossings)
  #:use-module (localchimera legal registry)
  #:use-module (localchimera knowledge law context-pack)
  #:export (*product-crossings* *product-features* *product-notices*
            product-feature product-feature-ids
            feature-name feature-crossings feature-doors feature-section
            product-notice %product-act product-bill product-stance))

;;; ─── crossings ───────────────────────────────────────────────────────────
;;; `data-processing` is the catalogue's own (legal/crossings.scm); these name the
;;; kinds of it, and the acts beside it, that a jurisdiction rules on apart.
;;; (symbol              kind       gloss  [what the records lack, when a tag must say it])
(define *product-crossings*
  '((hold-funds          by-choice  "holds or pays out funds on a member's behalf")
    (credit-contribution mirrored   "credits a member's work in an internal unit")
    (health-data         by-choice  "keeps what a member states of their health" no-flow)
    (location-data       by-choice  "keeps where a member is or lives" no-flow)
    (communications      mirrored   "carries messages between members" no-flow)
    (ai-processing       by-choice  "sends a member's words or images to a model" no-flow)))
(for-each (lambda (row) (apply register-crossing! row)) *product-crossings*)

;;; ─── features ────────────────────────────────────────────────────────────
;;; (id name crossings section)
;;;   section : where it sits in the face, as face/part
;;; The doors that ARE a feature are declared on the doors (`#:feature`,
;;; doors/protocol.scm) and read from there, so a feature's calls are stated once.
(define *product-features*
  '((account-creation "Account creation"               (data-processing)                "social/id")
    (erasure        "Erasure (forget me)"              (data-processing)                "social/id")
    (payouts        "Payouts in XMR"                   (hold-funds)                     "shop/payouts")
    (credit         "Credit for contribution"          (credit-contribution)            "shop/claims")
    (health-profile "Conditions stated in the profile" (data-processing health-data)    "share/attributes")
    (location       "Position and home"                (data-processing location-data)  "location")
    (contact-points "Contact points"                   (data-processing communications) "social/contacts")
    (chat           "Chat"                             (data-processing communications) "social/chat")
    (ai             "AI at the seat"                   (data-processing ai-processing)  "ai")
    (bodies         "Legal bodies"                     (data-processing organise)       "settings/bodies")))

(define (product-feature id) (assq id *product-features*))
(define (product-feature-ids) (map car *product-features*))
(define (feature-name f)      (list-ref f 1))
(define (feature-crossings f) (list-ref f 2))
(define (feature-section f)   (list-ref f 3))
(define (feature-doors f)                       ; → ((object . name) …), in protocol order
  (map (lambda (d) (cons (door-object d) (door-name d))) (doors-of-feature (car f))))

;;; ─── notices ─────────────────────────────────────────────────────────────
;;; legal-version    : the date the terms and the privacy notice in force took
;;;                    effect. It is what a member's acceptance is of: raise it
;;;                    when either changes materially, and a stored acceptance
;;;                    of an older one stops counting.
;;; document-version : the number the two documents call themselves by.
;;; attribution   : the line LICENSE-ADDITIONAL-TERMS.md §1 asks every
;;;                 user-facing deployment to show.
;;; min-age          : the floor the terms state (§8) — a stated minimum, no
;;;                    hard verification; an operator may set it higher at
;;;                    their own contact, which this constant does not carry.
(define *product-notices*
  '((legal-version    . "2026-10-09")
    (document-version . "1.2.0")
    (licence       . "free software under AGPL-3.0 with additional terms")
    (attribution   . "Powered by LocalChimera — a self-evolving commons and economic planner (rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ)")
    (terms         . "terms.html")
    (privacy       . "privacy.html")
    (accessibility . "accessibility.html")
    (min-age       . 16)
    ;; Figures the notices quote about how the service runs. They are written
    ;; into the pages (tools/emit/emit-notice-facts.scm) so a page never states a
    ;; number this file does not.
    ;; log-rotation        : shepherd's rotation of /var/log/localchimera (deploy/os.scm)
    ;; breach-notice-hours : GDPR Art 33's window to the supervisory authority
    ;; speech-model-mb     : the first-use download of the speech model (browser/lib/asr-worker.js)
    ;; change-notice-days  : how long an unfavourable change to the terms waits
    ;; backup-keep-days    : how long the encrypted daily snapshots stand, and so
    ;;                       how long an erased record lags in them
    ;;                       (LOCALCHIMERA_BACKUP_KEEP, deploy/scripts/backup-state.sh)
    (log-rotation        . "hourly")
    (backup-keep-days    . 30)
    (breach-notice-hours . 72)
    (speech-model-mb     . 80)
    (change-notice-days  . 14)
    ;; What this deployment has actually organized so far, as one sentence —
    ;; the fact a banner, the terms and the privacy notice all quote (§9,
    ;; §1), so it is edited in one place when it stops being true. This is an
    ;; operational-status statement, not a legal one: it does not stand in
    ;; for a record of processing, a DPIA or a named operator (docs/legal/operator.md
    ;; §10 rows 1 and 4) — those are about who runs this and what it holds,
    ;; not about what members have done with it.
    (deployment-status
     . "No real-world exchange of food, shelter, a ride, labour or money has been organized through this deployment yet — it is open today for interface testing.")))
(define (product-notice key) (assq-ref *product-notices* key))

;;; ─── the bill and the stance of a feature at a place ─────────────────────
;;; A feature states its act. An unstated act meets every `act-is` guard, so it
;;; also slips every "unless the act is X" (`negate (act-is X)`) prohibition; a
;;; feature is none of the acts a pack excepts, and says so.
(define %product-act 'product-feature)
(define* (product-bill place-id feature-id #:key (rules (current-legal-rules)) (as-of #f))
  "→ (values bill hits) : what the law asks of FEATURE-ID at PLACE-ID."
  (bill-at place-id (feature-crossings (product-feature feature-id))
           #:act %product-act #:rules rules #:as-of as-of))

(define* (product-stance place-id feature-id #:key (rules (current-legal-rules)) (as-of #f))
  "→ open | notice | unread | soft | off."
  (stance-at place-id (feature-crossings (product-feature feature-id))
             #:act %product-act #:rules rules #:as-of as-of))
