;;; federation/plan-bundle.scm — Rising plan proposals.
;;;
;;; A rising plan is a VF Proposal with purpose='request: the leaf
;;; publishes work-intents (Intents with action='work) requesting
;;; labour from the UC. A scale menu is a ProposalList grouping
;;; variant Proposals at different scales.
;;;
;;; No custom record types — uses VF Proposal, ProposalList, and
;;; Intent directly.

(define-module (playnet federation plan-bundle)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (srfi srfi-1)
  #:use-module (goblins)                 ; $ — the plan-store reads below
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:export (work-intent?
            intent-hours
            intent-skill

            make-rising-proposal
            proposal-work-intents
            proposal-total-hours
            scale-proposal-intents
            make-scale-variant
            make-proposal-scale-menu

            extract-rising-proposals))


;;; ── Work-intent predicates (on real VF Intents) ─────────────────────────────

(define (work-intent? intent)
  (and (intent? intent) (eq? (intent-action intent) 'work)))

(define (intent-hours intent)
  (let ((eq (intent-effort-quantity intent)))
    (if eq (measure-has-numerical-value eq) 0)))

(define (intent-skill intent)
  (intent-resource-conforms-to intent))


;;; ── Rising proposals ────────────────────────────────────────────────────────

(define* (make-rising-proposal id plan-id scope-id work-intent-ids
                                #:key (location #f) (beginning #f) (end #f))
  "Create a VF Proposal representing a rising plan. The leaf publishes
   its work-intents as a request for labour from the UC."
  (make-proposal #:id id
                 #:name (string-append "plan:" plan-id)                       ;; note
                 #:has-beginning beginning #:has-end end                       ;; unit-based
                       ;; created
                 #:purpose 'request                 ;; purpose
                 #:eligible-location location                 ;; eligible-location
                 #:in-scope-of (list scope-id)          ;; in-scope-of
                 #:publishes work-intent-ids          ;; publishes
                 #:reciprocal '()                      ;; reciprocal
                 #:proposed-to '()))                    ;; proposed-to

(define (proposal-work-intents proposal plan-store)
  "Resolve the published intent-ids to actual VF Intent records,
   filtered to action='work."
  (filter work-intent?
          (filter-map (lambda (iid)
                        (and plan-store ($ plan-store 'get-intent iid)))
                      (or (proposal-publishes proposal) '()))))

(define (proposal-total-hours proposal plan-store . maybe-scale)
  "Total hours across all published work-intents."
  (let ((s (if (pair? maybe-scale) (car maybe-scale) 1)))
    (* s (fold (lambda (wi acc) (+ (intent-hours wi) acc))
               0 (proposal-work-intents proposal plan-store)))))


;;; ── Scale variants ──────────────────────────────────────────────────────────

(define (scale-proposal-intents intents scale)
  "Return new intents with effort-quantity multiplied by SCALE.
   Preserves all VF fields."
  (map (lambda (i)
         (let* ((eq (intent-effort-quantity i))
                (hrs (if eq (measure-has-numerical-value eq) 0))
                (unit (if eq (measure-has-unit eq) %effort-unit)))
           (copy-intent i #:id (string-append (intent-id i) ":s" (number->string scale))
                        #:effort-quantity (make-measure (* scale hrs) unit))))
       intents))

(define (make-scale-variant base-proposal-id plan-id scope-id
                             scale intent-ids)
  "One variant Proposal at a given scale factor."
  (make-rising-proposal
   (string-append base-proposal-id ":v" (number->string scale))
   plan-id scope-id intent-ids))

(define (make-proposal-scale-menu id variants)
  "A ProposalList grouping scale variants. Each variant is a Proposal
   at a different scale."
  (make-proposal-list #:id id
                      #:name (string-append "scale-menu:" id)
                      #:lists (map proposal-id variants)))


;;; ── Extraction from plan-for-unit results ───────────────────────────────────

(define* (extract-rising-proposals plan-result plan-store
                                    #:key (scope-id #f))
  "Extract work-intents from a plan-for-unit result and wrap as a
   rising Proposal. Returns a list of VF Proposals (usually one)."
  (let* ((plan-id (assq-ref plan-result 'plan-id))
         (all-intents (if (and plan-store plan-id)
                          (or ($ plan-store 'intents-for-plan plan-id) '())
                          '()))
         (wis (filter work-intent? all-intents)))
    (if (null? wis) '()
        (list (make-rising-proposal
               (string-append "rp:" plan-id)
               plan-id (or scope-id plan-id)
               (map intent-id wis))))))
