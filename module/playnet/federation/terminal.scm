;;; federation/terminal.scm — Terminal states, agreements, lifecycle tracking.
;;;
;;; Closes the VF lifecycle for labour matching:
;;;
;;;   Intent (rises in Proposal)
;;;     → registered with observer → SatisfactionState auto-created
;;;   Commitment (descends from UC matching)
;;;     → registered with observer → FulfillmentState auto-created
;;;     → grouped into Agreement per (plan, producer) pair
;;;
;;; The observer's existing register-commitment / register-intent
;;; machinery creates FulfillmentState and SatisfactionState
;;; automatically. This module only needs to call registration and
;;; group commitments into Agreements.

(define-module (playnet federation terminal)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)                ; $ — was missing entirely, so every
                                        ; actor call here was unbound; harmless
                                        ; only because nothing calls this
                                        ; module yet (see emit-labour-commitments)
  #:use-module (playnet vf schemas)
  #:use-module (playnet federation plan-bundle)
  #:export (classify-terminal-state
            emit-labour-commitments
            emit-labour-agreements
            register-rising-intents
            emit-descending-signals))


(define *scale-threshold* 0.01)

(define (assoc-ref alist key)
  (let ((p (assoc key alist equal?))) (if p (cdr p) #f)))


;;; ── Classification ──────────────────────────────────────────────────────────

(define (classify-terminal-state proposal scale proposal-list)
  (cond
    ((< scale *scale-threshold*) 'returned)
    ((and proposal-list
          (member (proposal-id proposal)
                  (or (proposal-list-lists proposal-list) '())))
     'adopted-variant)
    (else 'run-at-scale)))


;;; ── Rising intent registration ──────────────────────────────────────────────
;;; Register rising work-intents with the observer so SatisfactionState
;;; is created. The observer's register-intent creates the initial state
;;; (total-desired from effort-quantity, total-satisfied = 0).

(define (register-rising-intents proposals plan-store observer)
  "Register each rising work-intent with the observer. This seeds
   SatisfactionState tracking — the observer handles the rest."
  (for-each
   (lambda (prop)
     (for-each (lambda (wi) ($ observer 'register-intent wi))
               (proposal-work-intents prop plan-store)))
   proposals))


;;; ── Commitment emission + registration ──────────────────────────────────────
;;; Register descending commitments with both plan-store and observer.
;;; The observer's register-commitment creates FulfillmentState
;;; (total-committed from effort-quantity, total-fulfilled = 0).

(define (emit-labour-commitments matching-result plan-store observer)
  "Write VF commitments into PLAN-STORE and register with OBSERVER.
   Observer auto-creates FulfillmentState for each. Returns commitments."
  (let ((deployment (or (assoc-ref matching-result 'deployment) '())))
    (for-each (lambda (cmt)
                ($ plan-store 'add-commitment cmt)
                ;; guarded — register-commitment RESETS a tracked state to
                ;; zero fulfilled, so a re-run of matching through this door
                ;; must never wipe recorded progress. (No live caller today;
                ;; the guard is here so the first future caller doesn't arm
                ;; the trap.)
                (unless ($ observer 'get-fulfillment (commitment-id cmt))
                  ($ observer 'register-commitment cmt)))
              deployment)
    deployment))


;;; ── Agreement emission ──────────────────────────────────────────────────────
;;; Each (plan, producer) pair gets an Agreement stipulating the
;;; descending commitments.

(define (group-by-plan-agent commitments)
  (let loop ((cmts commitments) (groups '()))
    (if (null? cmts) groups
        (let* ((c (car cmts))
               (key (cons (commitment-planned-within c)
                          (commitment-provider c)))
               (existing (assoc key groups equal?)))
          (loop (cdr cmts)
                (if existing
                    (map (lambda (g)
                           (if (equal? (car g) key)
                               (cons key (cons c (cdr g)))
                               g))
                         groups)
                    (cons (cons key (list c)) groups)))))))

(define (emit-labour-agreements commitments plan-store)
  "Create a VF Agreement for each (plan, producer) pair. Returns
   the list of Agreements."
  (let ((groups (group-by-plan-agent commitments)))
    (map (lambda (group)
           (let* ((key (car group))
                  (cmts (cdr group))
                  (plan-id (car key))
                  (agent-id (cdr key))
                  (agr-id (string-append "la:" plan-id ":"
                                         (or agent-id "?")))
                  (agr (make-agreement #:id agr-id
                         #:name (string-append "Labour: " (or agent-id "?")
                                        " → " plan-id)
                         #:stipulates (map commitment-id cmts) #:stipulates-reciprocal '())))
             ($ plan-store 'add-agreement agr)
             agr))
         groups)))


;;; ── Descending signals ──────────────────────────────────────────────────────

(define (emit-descending-signals proposals plan-store scales)
  (filter-map
   (lambda (prop)
     (let* ((pid   (proposal-id prop))
            (scale (or (assoc-ref scales pid) 0)))
       (cond
         ((< scale *scale-threshold*)
          `((kind . deficit)
            (scope-id . ,(car (or (proposal-in-scope-of prop) '(""))))
            (spec-id . ,pid)
            (qty . ,(proposal-total-hours prop plan-store))
            (source . labour-returned)))
         ((< scale 1)
          `((kind . partial)
            (scope-id . ,(car (or (proposal-in-scope-of prop) '(""))))
            (spec-id . ,pid)
            (qty . ,(proposal-total-hours prop plan-store (- 1 scale)))
            (scale . ,scale)
            (source . labour-scaled)))
         (else #f))))
   proposals))
