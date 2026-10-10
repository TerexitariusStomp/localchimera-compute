;;; test-comms-recipes.scm — the two production recipes for social posting.
;;;
;;; A post is digital production on the infrastructure.scm lineage: compose
;;; `use`s inference + `cite`s the announced fact → a draft; publish `use`s a
;;; channel + `cite`s the draft → a published post. Proves the recipes are
;;; well-formed VF, that the inference cost is accounted (exactly one completion
;;; used), that the fact is cited (the provenance link), and that a campaign
;;; fans one draft across N channels — one carrying the "rented" tag, one
;;; "owned", so the fragility contrast is visible in the store.
;;; Pure data (no observer, no solve) ⇒ no blake3.
;;;
;;; Run: guile -L module tests/knowledge/test-comms-recipes.scm

(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet vf schemas)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(define (pl p) (load (string-append root "/module/playnet/planner/" p)))
(use-modules (playnet knowledge recipes comms-processes))

(define (empty-rs)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
(define (flat-flows rs rp) (let ((fp ($ rs 'flows-for-process rp)))
                             (append (if (list? (car fp)) (car fp) '())
                                     (if (list? (cdr fp)) (cdr fp) '()))))
(define (action-of flows act)
  (filter (lambda (f) (eq? (recipe-flow-action f) act)) flows))
(define (spec-of f) (recipe-flow-resource-conforms-to f))
(define (classified-of rs spec-id)
  (resource-specification-resource-classified-as ($ rs 'get-resource-spec spec-id)))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((rs (empty-rs)))
      (define seeded (seed-comms-campaign rs))     ; compose + publish×2 (x, reticulum)
      (list seeded
            (flat-flows rs "rp:compose")
            (flat-flows rs "rp:publish:spec:channel-x")
            (classified-of rs "spec:channel-x")
            (classified-of rs "spec:channel-reticulum")))))

(define seeded    (list-ref out 0))
(define compose-f (list-ref out 1))
(define publish-f (list-ref out 2))
(define x-tags    (list-ref out 3))
(define retic-tags (list-ref out 4))

;;; ─── 1. the campaign is compose + one publish per channel ──────────────────
(display "\n── a campaign fans one draft across the channels ──\n")
(check "seed-comms-campaign yields compose + one publish per channel"
       seeded
       '("rp:compose" "rp:publish:spec:channel-x" "rp:publish:spec:channel-reticulum"))

;;; ─── 2. compose accounts the AI cost and cites the fact ────────────────────
(display "\n── compose: use(inference) + cite(announced-fact) → draft ──\n")
(check "compose USEs exactly one inference completion (AI cost accounted)"
       (map spec-of (action-of compose-f 'use)) '("spec:inference"))
(check "the used inference quantity is one completion"
       (measure-has-numerical-value
        (recipe-flow-resource-quantity (car (action-of compose-f 'use)))) 1)
(check "compose CITEs the announced fact (the provenance link)"
       (map spec-of (action-of compose-f 'cite)) '("spec:announced-fact"))
(check "compose PRODUCEs the draft"
       (map spec-of (action-of compose-f 'produce)) '("spec:post-draft"))

;;; ─── 3. publish USES a channel (scarcity gate) + cites the draft ───────────
(display "\n── publish: use(channel) + cite(draft) → published post ──\n")
(check "publish USEs the channel resource (occupied then released)"
       (map spec-of (action-of publish-f 'use)) '("spec:channel-x"))
(check "publish CITEs the draft it sends"
       (map spec-of (action-of publish-f 'cite)) '("spec:post-draft"))
(check "publish PRODUCEs the published post"
       (map spec-of (action-of publish-f 'produce)) '("spec:published-post"))

;;; ─── 4. channel specs are generic — ownership is a RESOURCE fact ───────────
;;; Rented-vs-sovereign is not a spec tag; it is the held resource's
;;; primary-accountable/custodian split (see comms/fragility.scm). So the specs
;;; stay generic infrastructure — the fragility reads the held account, not the kind.
(display "\n── channel specs are generic; ownership lives on the held resource ──\n")
(check "the X channel spec is generic infrastructure (no ownership tag)"
       (and (member "channel" x-tags) (not (member "rented" x-tags)) #t) #t)
(check "the Reticulum channel spec is generic too — ownership is a resource fact"
       (and (member "channel" retic-tags) (not (member "owned" retic-tags)) #t) #t)

(display "\n")
(test-summary!)
