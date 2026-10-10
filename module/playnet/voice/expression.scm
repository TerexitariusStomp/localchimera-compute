;;; voice/expression.scm — labor-weighted distribution over any per-scope per-domain question
;;;
;;; Generalizes the original ^plan-expression: citizens distribute their
;;; (labor-proportional) voice fractionally across N targets in some
;;; DOMAIN. Domain is just a tag — the math is identical regardless. A
;;; plan-relevance expression is `domain='plan`; a demand-prioritization
;;; expression is `domain='demand`; a resource-preference expression is
;;; `domain='resource`. New domains require no new actor.
;;;
;;; A "distribution" is a hashmap target-id → fraction (sum ≤ 1;
;;; remainder abstains). The cleartext cast carries:
;;;   (list 'expression domain expression-id distribution
;;;          citizen-id keri-aid).
;;;
;;; Mandate semantics: mandate is a predicate over the distribution
;;; (not a single position). e.g. (lambda (d)
;;;   (>= (hashmap-ref d "target-A" 0) 0.5)). If mandate fails, the
;;;   delegated voice fraction is abstained (must-act).
;;;

(define-module (playnet voice expression)
  #:use-module (playnet voice ballot)
  #:use-module (playnet voice delegation-map)
  #:use-module (goblins utils hashmap)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (distribution-sum validate-distribution tally-expression-snapshot
            ^expression open-expression express expression-env))

;; =========================================================================
;; Distribution validation
;; =========================================================================

(define (distribution-sum dist)
  (hashmap-fold (lambda (_k v acc) (+ v acc)) 0 dist))

(define (validate-distribution dist target-ids)
  "Reject distributions that:
   - reference unknown target-ids
   - have any negative fraction
   - sum > 1"
  (hashmap-fold
    (lambda (target-id frac _)
      (unless (member target-id target-ids)
        (error "Distribution references unknown target-id" target-id))
      (when (< frac 0)
        (error "Distribution fraction must be ≥ 0" target-id frac)))
    #f dist)
  (when (> (distribution-sum dist) 1)
    (error "Distribution sum > 1" (distribution-sum dist))))


;; =========================================================================
;; Tally: pure function over snapshot + distributions
;; =========================================================================

(define (tally-expression-snapshot voice-snapshot distributions target-ids)
  "Returns (values target-tally abstain) where target-tally is a hashmap
   target-id → total-support-weight. Abstain is voice that didn't reach
   any target (direct fraction not allocated, mandate violations, cycles)."
  (let ((tally    (hashmap))
        (abstain  0))

    (define (add-to-target target-id weight)
      (let ((current (hashmap-ref tally target-id 0)))
        (set! tally (hashmap-set tally target-id (+ current weight)))))

    (define (add-abstention weight)
      (set! abstain (+ abstain weight)))

    (define (distribute-to-targets dist incoming)
      ;; Distribute incoming voice across target-ids per the dist hashmap.
      ;; Direct fraction (1 − sum) is abstained.
      (let ((sum (distribution-sum dist)))
        (hashmap-fold
          (lambda (target-id frac _)
            (add-to-target target-id (* incoming frac)))
          #f dist)
        (add-abstention (* incoming (- 1 sum)))))

    (define (resolve citizen incoming visited depth)
      (cond
        ((member citizen visited) (add-abstention incoming))
        ((>= depth *max-tally-depth*) (add-abstention incoming))
        (else
         (let ((cast (hashmap-ref distributions citizen #f)))
           (cond
             ;; Direct cast: distribute across targets per their distribution.
             (cast
              (distribute-to-targets (cadddr cast) incoming))
             ;; No cast — flow via delegation.
             (else
              (let ((vs (hashmap-ref voice-snapshot citizen #f)))
                (cond
                  ((not vs) (add-abstention incoming))
                  (else
                   (let* ((delegation (voice-snap-delegation vs))
                          (sum-fractions
                            (hashmap-fold (lambda (_k e a)
                                            (+ (entry-fraction e) a))
                                          0 delegation))
                          (next-visited (cons citizen visited))
                          (next-depth   (+ depth 1)))
                     (hashmap-fold
                       (lambda (delegate-id entry _)
                         (let ((fraction (entry-fraction entry))
                               (mandate  (entry-mandate entry))
                               (delegated (* incoming
                                             (entry-fraction entry))))
                           (cond
                             ((mandate-satisfied?
                                mandate
                                (hashmap-ref distributions delegate-id #f))
                              (resolve delegate-id delegated
                                       next-visited next-depth))
                             (else
                              (add-abstention delegated)))))
                       #f delegation)
                     (add-abstention (* incoming (- 1 sum-fractions)))))))))))))

    (hashmap-fold
      (lambda (citizen vs _)
        (resolve citizen (voice-snap-share vs) '() 0))
      #f voice-snapshot)

    (values tally abstain)))


;; =========================================================================
;; ^expression actor
;; =========================================================================

(define-actor (^expression bcom
                           domain                  ;; symbol — 'plan | 'demand | …
                           expression-id
                           franchise
                           description
                           target-ids              ;; list of target-id strings
                           voice-snapshot          ;; hashmap aid → <voice-snap>
                           distributions           ;; hashmap aid → cleartext
                           citizen-registry        ;; hashmap aid → sealed?
                           credential-check        ;; (lambda (aid) bool)
                           close-authority         ;; sealed?-actor or #f
                           status)                 ;; 'open | 'closed
  #:version 1

  (methods

    ((kind)            'expression)
    ((domain)          domain)
    ((expression-id)   expression-id)
    ((id)              expression-id)
    ((franchise)       franchise)
    ((description)     description)
    ((target-ids)      target-ids)
    ((status)          status)
    ((voice-snapshot)  voice-snapshot)
    ((distributions)   distributions)

    ((cast citizen-id stance-bundle)
     (when (eq? status 'closed)
       (error "Expression is closed" expression-id))
     (let ((sealed? (hashmap-ref citizen-registry citizen-id #f)))
       (unless sealed?
         (error "Unknown citizen" citizen-id))
       (unless (pair? stance-bundle)
         (error "Stance bundle must be (cleartext . sealed)" stance-bundle))
       (let ((cleartext (car stance-bundle))
             (sealed    (cdr stance-bundle)))
         (unless ($ sealed? sealed)
           (error "Invalid endorsement" citizen-id))
         (unless (and (pair? cleartext)
                      (eq? (car cleartext) 'expression)
                      (equal? (cadr cleartext) domain)
                      (equal? (caddr cleartext) expression-id)
                      (equal? (list-ref cleartext 4) citizen-id)
                      (= (length cleartext) 6))
           (error "Cleartext shape mismatch" cleartext))
         (let ((dist     (cadddr cleartext))
               (keri-aid (list-ref cleartext 5)))
           (validate-distribution dist target-ids)
           (unless (credential-check keri-aid)
             (error "Credential check failed" citizen-id keri-aid))
           (bcom (^expression bcom domain expression-id franchise description
                              target-ids voice-snapshot
                              (hashmap-set distributions citizen-id
                                            cleartext)
                              citizen-registry credential-check
                              close-authority status))))))

    ((close . rest)
     (when close-authority
       (let ((cap (and (pair? rest) (car rest))))
         (unless (and cap ($ close-authority cap))
           (error "Close requires gov-authority" expression-id))))
     (bcom (^expression bcom domain expression-id franchise description
                        target-ids voice-snapshot distributions
                        citizen-registry credential-check
                        close-authority 'closed)))

    ((tally)
     (call-with-values
       (lambda () (tally-expression-snapshot voice-snapshot distributions
                                              target-ids))
       (lambda (target-tally abstain)
         (list (cons 'tally target-tally)
               (cons 'abstain abstain)))))

    ((result)
     (call-with-values
       (lambda () (tally-expression-snapshot voice-snapshot distributions
                                              target-ids))
       (lambda (target-tally abstain)
         (let* ((entries (hashmap-fold (lambda (k v acc) (cons (cons k v) acc))
                                        '() target-tally))
                (sorted (sort entries (lambda (a b) (> (cdr a) (cdr b))))))
           (list (cons 'ranked sorted)
                 (cons 'tally target-tally)
                 (cons 'abstain abstain))))))))


;; =========================================================================
;; open-expression — convenience constructor
;; =========================================================================

(define* (open-expression domain expression-id franchise description target-ids
                          citizen-registry citizen-voice-data
                          #:key
                          (credential-check (lambda (_aid) #t))
                          (close-authority #f))
  "Open a per-scope per-domain weighted-voice expression over TARGET-IDS.
   DOMAIN is a symbol tagging what the targets are ('plan, 'demand,
   'resource, 'proposal-relevance, …). Math is identical across domains;
   the tag rides on cleartext + ACDC for downstream consumers."
  (let ((voice-snapshot
          (hashmap-fold
            (lambda (cid data acc)
              (let* ((voice-share (car data))
                     (dm-ref      (cdr data))
                     (resolved    (if dm-ref
                                      ($ dm-ref 'resolve-for franchise)
                                      (hashmap))))
                (hashmap-set acc cid (voice-snap voice-share resolved))))
            (hashmap)
            citizen-voice-data)))
    (spawn ^expression domain expression-id franchise description target-ids
           voice-snapshot (hashmap) citizen-registry
           credential-check close-authority 'open)))


;; =========================================================================
;; Citizen-side: build a stance bundle for an expression
;; =========================================================================
;;
;; ^voice-signer's `stance` produces single-position bundles. For an
;; expression we need a distribution-bundle. Helper:

(define (express citizen-voice domain expression-id distribution)
  "Return (cleartext . sealed-bundle) for an expression cast.
   citizen-voice: a ^voice-signer ref (must be in the same vat).
   domain:        the expression's domain symbol.
   distribution:  hashmap target-id → fraction.

   Implementation: invokes `stance-expression` on ^voice-signer."
  ($ citizen-voice 'stance-expression domain expression-id distribution))


;; =========================================================================
;; Persistence
;; =========================================================================

(define expression-env
  (make-persistence-env
    `((((playnet voice expression) ^expression) ,^expression))))
