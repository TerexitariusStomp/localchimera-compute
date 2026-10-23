;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; compute/registry.scm — a commune's compute dispatch book.
;;;
;;; WHAT THE FILE HOLDS. One ^machine-registry actor per commune: the lane
;;; offers members publish, the jobs borrowers submit, the dispatch claims
;;; that bind the two, the receipts that close a claim, and the settlement
;;; statements a bridge lands against the book. Everything here is the
;;; matching half of spec/playnet-compute.md §4 — offers, jobs and claims
;;; are transient dispatch state; the settled side folds into the scope's
;;; observer as `use` events (compute/receipt.scm receipt->event), where
;;; the commons' record layer is the truth.
;;;
;;; THE RINGS. A job carries the ring it may route at: 0 own devices,
;;; 1 own commune, 2 peer communes, 3 the anonymous market. An inner ring
;;; always wins — `match` prefers the lowest ring an offer answers at and
;;; `preempt` bumps the job outward one ring, per the spec's requeue rule.
;;; The anonymous market is a ring, not a parallel demand system: the same
;;; job object walks outward, it is never copied.

(define-module (playnet machine registry)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module ((playnet utils store-utils)
                #:select (generate-id hashmap-filter hashmap-find
                          serialize-hashmap deserialize-hashmap))
  #:use-module ((playnet utils time) #:select (current-epoch-seconds))
  #:use-module (playnet machine specs)
  #:use-module (playnet machine receipt)
  #:use-module ((playnet machine dispute) #:select (dispute-claim-id))
  #:use-module ((playnet machine challenge) #:select (store-challenge-claim-id))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (<lane-offer> make-lane-offer lane-offer?
            lane-offer-id lane-offer-lender-did lane-offer-commune-aid
            lane-offer-lane lane-offer-task-classes lane-offer-headroom
            lane-offer-repro-mode lane-offer-usage-unit lane-offer-retracted?
            lane-offer-resources
            lane-offer->list list->lane-offer
            resource-alist? resources-cover?
            <machine-job> make-machine-job machine-job?
            machine-job-id machine-job-borrower-did machine-job-commune-aid
            machine-job-task-class machine-job-lane machine-job-repro-mode
            machine-job-input-hash machine-job-envelope-hash machine-job-ring
            machine-job-state machine-job-created-at machine-job-spec-id
            machine-job-needs
            machine-job->list list->machine-job
            <dispatch-claim> make-dispatch-claim dispatch-claim?
            dispatch-claim-id dispatch-claim-job-id dispatch-claim-offer-id
            dispatch-claim-lender-did dispatch-claim-borrower-did
            dispatch-claim-state dispatch-claim-deadline dispatch-claim-receipt
            dispatch-claim->list list->dispatch-claim
            lane-offer-answers?
            ^machine-registry machine-registry-env
            ^envelope-store spawn-envelope-store
            ^binding-store spawn-binding-store binding-key
            ^dispute-store spawn-dispute-store
            ^challenge-store spawn-challenge-store
            ^signal-store spawn-signal-store))


;;; ── the records ─────────────────────────────────────────────────────────

(define-record-type <lane-offer>
  (%make-lane-offer id lender-did commune-aid lane task-classes headroom
                    repro-mode usage-unit retracted? resources)
  lane-offer?
  (id            lane-offer-id)
  (lender-did    lane-offer-lender-did)    ; AID or did:key of the member
  (commune-aid   lane-offer-commune-aid)
  (lane          lane-offer-lane)          ; string — the lane name
  (task-classes  lane-offer-task-classes)  ; list of task-class symbols
  (headroom      lane-offer-headroom)      ; number — units/second it can lend
  (repro-mode    lane-offer-repro-mode)    ; 'exact | 'deterministic | 'none
  (usage-unit    lane-offer-usage-unit)    ; one of *machine-usage-units*
  (retracted?    lane-offer-retracted?)
  (resources     lane-offer-resources))    ; alist — what the node has:
                                         ; cores, memGB, storageGB, netKbps, gpu

(define* (make-lane-offer #:key id lender-did commune-aid lane task-classes
                          headroom repro-mode (usage-unit "seconds")
                          (retracted? #f) (resources '()))
  (unless (and (list? task-classes) (every task-class? task-classes))
    (error "lane-offer: task-classes must be a list of task classes" task-classes))
  (unless (repro-mode? repro-mode)
    (error "lane-offer: not a repro mode" repro-mode))
  (unless (and (number? headroom) (> headroom 0))
    (error "lane-offer: headroom must be a positive number" headroom))
  (unless (usage-unit? usage-unit)
    (error "lane-offer: not a usage unit" usage-unit))
  (unless (resource-alist? resources)
    (error "lane-offer: resources must be an alist of string . number" resources))
  (%make-lane-offer id lender-did commune-aid lane task-classes headroom
                    repro-mode usage-unit retracted? resources))

;;; a resources/needs alist: ((key . amount) …), string keys, number amounts —
;;; "storageGB" . 4, "netKbps" . 800. The same shape on both sides lets
;;; matching be a plain cover test.
(define (resource-alist? a)
  (and (list? a)
       (every (lambda (p) (and (pair? p) (string? (car p))
                               (number? (cdr p))))
              a)))

;;; the offer covers the job's needs when every named need is present in the
;;; offer's resources and at least as large. A job that names nothing is
;;; covered by any offer — needs absent means the lane+class match alone
;;; decides, the same rule as before the alist existed.
(define (resources-cover? resources needs)
  (every (lambda (need)
           (let ((have (assoc-ref resources (car need))))
             (and have (>= have (cdr need)))))
         needs))

(define-record-type <machine-job>
  (%make-machine-job id borrower-did commune-aid task-class lane repro-mode
                     input-hash envelope-hash ring state created-at spec-id
                     needs)
  machine-job?
  (id            machine-job-id)               ; the bridgeJobId
  (borrower-did  machine-job-borrower-did)
  (commune-aid   machine-job-commune-aid)
  (task-class    machine-job-task-class)
  (lane          machine-job-lane)
  (repro-mode    machine-job-repro-mode)
  (input-hash    machine-job-input-hash)
  (envelope-hash machine-job-envelope-hash)  ; hash of the envelope, not the body
  (ring          machine-job-ring)           ; 0..3 — the outermost it may route at
  (state         machine-job-state)          ; 'open | 'claimed | 'settled | 'withdrawn
  (created-at    machine-job-created-at)     ; epoch ms
  (spec-id       machine-job-spec-id)        ; the ResourceSpecification id it names
  (needs         machine-job-needs))         ; alist — what the job requires:
                                           ; storageGB, netKbps, gpu, …

(define* (make-machine-job #:key id borrower-did commune-aid task-class lane
                           repro-mode input-hash (envelope-hash #f)
                           (ring 1) (state 'open) created-at (spec-id #f)
                           (needs '()))
  (unless (task-class? task-class)
    (error "machine-job: not a task class" task-class))
  (unless (repro-mode? repro-mode)
    (error "machine-job: not a repro mode" repro-mode))
  (unless (and (integer? ring) (<= 0 ring 3))
    (error "machine-job: ring must be an integer 0..3" ring))
  (unless (resource-alist? needs)
    (error "machine-job: needs must be an alist of string . number" needs))
  (%make-machine-job id borrower-did commune-aid task-class lane repro-mode
                     input-hash envelope-hash ring state created-at spec-id
                     needs))

(define-record-type <dispatch-claim>
  (%make-dispatch-claim id job-id offer-id lender-did borrower-did
                        state deadline receipt)
  dispatch-claim?
  (id           dispatch-claim-id)
  (job-id       dispatch-claim-job-id)
  (offer-id     dispatch-claim-offer-id)
  (lender-did   dispatch-claim-lender-did)
  (borrower-did dispatch-claim-borrower-did)
  (state        dispatch-claim-state)        ; 'claimed|'accepted|'preempted|'complete|'expired
  (deadline     dispatch-claim-deadline)     ; epoch ms — the countersign deadline
  (receipt      dispatch-claim-receipt))     ; <receipt> | #f

(define* (make-dispatch-claim #:key id job-id offer-id lender-did borrower-did
                              (state 'claimed) deadline (receipt #f))
  (%make-dispatch-claim id job-id offer-id lender-did borrower-did
                        state deadline receipt))


;;; ── matching ────────────────────────────────────────────────────────────
;;; An offer answers a job when its lane names the job's lane, the job's
;;; task class is among the classes it runs, it has headroom left, its
;;; resources cover every need the job names, the lender is not the
;;; borrower, and it is live. Replay mode is not part of the match — a
;;; borrower that needs exact replay reads it off the offer; refusing
;;; 'none offers here would hide capacity a 'none job wants.

(define (lane-offer-answers? offer job)
  (and (not (lane-offer-retracted? offer))
       (equal? (lane-offer-lane offer) (machine-job-lane job))
       (memq (machine-job-task-class job) (lane-offer-task-classes offer))
       (> (lane-offer-headroom offer) 0)
       (resources-cover? (lane-offer-resources offer)
                         (machine-job-needs job))
       (not (equal? (lane-offer-lender-did offer)
                    (machine-job-borrower-did job)))))


;;; ── wire shapes — lists, the way every registry crosses the seam ────────

(define (lane-offer->list o)
  (list (lane-offer-id o) (lane-offer-lender-did o) (lane-offer-commune-aid o)
        (lane-offer-lane o) (lane-offer-task-classes o) (lane-offer-headroom o)
        (symbol->string (lane-offer-repro-mode o)) (lane-offer-usage-unit o)
        (lane-offer-retracted? o) (lane-offer-resources o)))

(define (list->lane-offer l)
  ;; pre-resources portraits carry 9 fields; resources defaults to '()
  (apply make-lane-offer
         #:id (list-ref l 0) #:lender-did (list-ref l 1)
         #:commune-aid (list-ref l 2) #:lane (list-ref l 3)
         #:task-classes (list-ref l 4) #:headroom (list-ref l 5)
         #:repro-mode (string->symbol (list-ref l 6))
         #:usage-unit (list-ref l 7) #:retracted? (list-ref l 8)
         #:resources (if (> (length l) 9) (list-ref l 9) '()) '()))

(define (machine-job->list j)
  (list (machine-job-id j) (machine-job-borrower-did j)
        (machine-job-commune-aid j) (symbol->string (machine-job-task-class j))
        (machine-job-lane j) (symbol->string (machine-job-repro-mode j))
        (machine-job-input-hash j) (machine-job-envelope-hash j)
        (machine-job-ring j) (symbol->string (machine-job-state j))
        (machine-job-created-at j) (machine-job-spec-id j)
        (machine-job-needs j)))

(define (list->machine-job l)
  ;; pre-needs portraits carry 12 fields; needs defaults to '()
  (apply make-machine-job
         #:id (list-ref l 0) #:borrower-did (list-ref l 1)
         #:commune-aid (list-ref l 2)
         #:task-class (string->symbol (list-ref l 3)) #:lane (list-ref l 4)
         #:repro-mode (string->symbol (list-ref l 5))
         #:input-hash (list-ref l 6) #:envelope-hash (list-ref l 7)
         #:ring (list-ref l 8) #:state (string->symbol (list-ref l 9))
         #:created-at (list-ref l 10) #:spec-id (list-ref l 11)
         #:needs (if (> (length l) 12) (list-ref l 12) '()) '()))

(define (dispatch-claim->list c)
  (list (dispatch-claim-id c) (dispatch-claim-job-id c)
        (dispatch-claim-offer-id c) (dispatch-claim-lender-did c)
        (dispatch-claim-borrower-did c) (symbol->string (dispatch-claim-state c))
        (dispatch-claim-deadline c) (dispatch-claim-receipt c)))

(define (list->dispatch-claim l)
  (apply make-dispatch-claim
         #:id (list-ref l 0) #:job-id (list-ref l 1) #:offer-id (list-ref l 2)
         #:lender-did (list-ref l 3) #:borrower-did (list-ref l 4)
         #:state (string->symbol (list-ref l 5)) #:deadline (list-ref l 6)
         #:receipt (list-ref l 7) '()))


;;; ── the actor ───────────────────────────────────────────────────────────
;;; offers, jobs, claims: hashmaps id → record. receipts rides inside the
;;; claim (dispatch-claim-receipt); statements is a list in append order —
;;; a statement is what a bridge LANDS, never what the registry writes.

(define-actor (^machine-registry bcom offers jobs claims statements)
  #:portrait
  (lambda ()
    (list (serialize-hashmap offers lane-offer->list)
          (serialize-hashmap jobs machine-job->list)
          (serialize-hashmap claims dispatch-claim->list)
          statements))
  #:version 1
  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^machine-registry
                  (deserialize-hashmap (car data) list->lane-offer)
                  (deserialize-hashmap (cadr data) list->machine-job)
                  (deserialize-hashmap (caddr data) list->dispatch-claim)
                  (cadddr data)))
      (else (error "Unknown ^machine-registry version" version))))

  (methods

    ;; ── offers ───────────────────────────────────────────────────────────
    ((offer lender-did commune-aid lane task-classes headroom repro-mode
            #:optional (usage-unit "seconds") (resources '()))
     (let* ((id (generate-id "offer-"))
            (o (make-lane-offer #:id id #:lender-did lender-did
                                #:commune-aid commune-aid #:lane lane
                                #:task-classes task-classes #:headroom headroom
                                #:repro-mode repro-mode #:usage-unit usage-unit
                                #:resources resources)))
       (bcom (^machine-registry bcom (hashmap-set offers id o) jobs claims statements)
             id)))

    ((retract offer-id lender-did)
     (let ((o (hashmap-ref offers offer-id #f)))
       (cond
        ((not o) (values))
        ((not (equal? lender-did (lane-offer-lender-did o)))
         (error "machine-registry: only the lender retracts an offer"))
        (else
         (let ((o* (apply make-lane-offer
                          #:id (lane-offer-id o) #:lender-did lender-did
                          #:commune-aid (lane-offer-commune-aid o)
                          #:lane (lane-offer-lane o)
                          #:task-classes (lane-offer-task-classes o)
                          #:headroom (lane-offer-headroom o)
                          #:repro-mode (lane-offer-repro-mode o)
                          #:usage-unit (lane-offer-usage-unit o)
                          #:retracted? #t
                          #:resources (lane-offer-resources o) '())))
           (bcom (^machine-registry bcom (hashmap-set offers offer-id o*)
                                    jobs claims statements)))))))

    ((offers commune-aid)
     (hashmap-filter
       (lambda (o) (and (equal? commune-aid (lane-offer-commune-aid o))
                        (not (lane-offer-retracted? o))))
       offers))

    ((offer-of offer-id) (hashmap-ref offers offer-id #f))

    ;; ── jobs ─────────────────────────────────────────────────────────────
    ((submit borrower-did commune-aid task-class lane repro-mode input-hash
             #:optional (envelope-hash #f) (ring 1) (spec-id #f) (needs '()))
     (let* ((id (generate-id "job-"))
            (j (make-machine-job #:id id #:borrower-did borrower-did
                                 #:commune-aid commune-aid #:task-class task-class
                                 #:lane lane #:repro-mode repro-mode
                                 #:input-hash input-hash #:envelope-hash envelope-hash
                                 #:ring ring #:created-at
                                 (* (current-epoch-seconds) 1000)
                                 #:spec-id spec-id #:needs needs)))
       (bcom (^machine-registry bcom offers (hashmap-set jobs id j)
                                claims statements) id)))

    ((job-of job-id) (hashmap-ref jobs job-id #f))

    ((jobs commune-aid)
     (hashmap-filter
       (lambda (j) (equal? commune-aid (machine-job-commune-aid j))) jobs))

    ((open-jobs commune-aid)
     (hashmap-filter
       (lambda (j) (and (equal? commune-aid (machine-job-commune-aid j))
                        (eq? (machine-job-state j) 'open)))
       jobs))

    ((withdraw job-id borrower-did)
     (let ((j (hashmap-ref jobs job-id #f)))
       (cond
        ((not j) (values))
        ((not (equal? borrower-did (machine-job-borrower-did j)))
         (error "machine-registry: only the borrower withdraws a job"))
        ((not (eq? (machine-job-state j) 'open))
         (error "machine-registry: only an open job withdraws"))
        (else
         (bcom (^machine-registry bcom offers
                                  (hashmap-set jobs job-id
                                               (apply make-machine-job
                                                 #:id job-id #:borrower-did borrower-did
                                                 #:commune-aid (machine-job-commune-aid j)
                                                 #:task-class (machine-job-task-class j)
                                                 #:lane (machine-job-lane j)
                                                 #:repro-mode (machine-job-repro-mode j)
                                                 #:input-hash (machine-job-input-hash j)
                                                 #:envelope-hash (machine-job-envelope-hash j)
                                                 #:ring (machine-job-ring j)
                                                 #:state 'withdrawn
                                                 #:created-at (machine-job-created-at j)
                                                 #:spec-id (machine-job-spec-id j)
                                                 #:needs (machine-job-needs j) '()))
                                  claims statements))))))

    ;; offers answering JOB, inner ring first: an offer answers at ring
    ;; (job's commune == offer's commune ? 1 : 2). Ring-0 and ring-3 are
    ;; resolved elsewhere — ring-0 is the borrower's own device before the
    ;; job ever submits, ring-3 the bridge's anonymous pool.
    ((match job-id)
     (let ((j (hashmap-ref jobs job-id #f)))
       (if (not j) '()
           (hashmap-filter
             (lambda (o) (lane-offer-answers? o j)) offers))))

    ;; ── claims ───────────────────────────────────────────────────────────
    ;; LENDER-DID takes JOB-ID under OFFER-ID; DEADLINE is epoch ms — the
    ;; countersign-by time the spec's no-receipt-no-payment rule reads.
    ((claim lender-did job-id offer-id deadline)
     (let ((j (hashmap-ref jobs job-id #f))
           (o (hashmap-ref offers offer-id #f)))
       (cond
        ((not j) (error "machine-registry: no such job" job-id))
        ((not o) (error "machine-registry: no such offer" offer-id))
        ((not (equal? lender-did (lane-offer-lender-did o)))
         (error "machine-registry: the offer is not the claimants"))
        ((not (eq? (machine-job-state j) 'open))
         (error "machine-registry: job is not open"))
        ((not (lane-offer-answers? o j))
         (error "machine-registry: the offer does not answer the job"))
        (else
         (let* ((cid (generate-id "claim-"))
                (c (make-dispatch-claim #:id cid #:job-id job-id #:offer-id offer-id
                                        #:lender-did lender-did
                                        #:borrower-did (machine-job-borrower-did j)
                                        #:deadline deadline))
                (j* (apply make-machine-job
                      #:id job-id #:borrower-did (machine-job-borrower-did j)
                      #:commune-aid (machine-job-commune-aid j)
                      #:task-class (machine-job-task-class j) #:lane (machine-job-lane j)
                      #:repro-mode (machine-job-repro-mode j)
                      #:input-hash (machine-job-input-hash j)
                      #:envelope-hash (machine-job-envelope-hash j)
                      #:ring (machine-job-ring j) #:state 'claimed
                      #:created-at (machine-job-created-at j)
                      #:spec-id (machine-job-spec-id j)
                      #:needs (machine-job-needs j) '())))
           (bcom (^machine-registry bcom offers (hashmap-set jobs job-id j*)
                                    (hashmap-set claims cid c) statements)
                 cid))))))

    ((claim-of claim-id) (hashmap-ref claims claim-id #f))

    ((claims commune-aid)
     (hashmap-filter
       (lambda (c)
         (let ((j (hashmap-ref jobs (dispatch-claim-job-id c) #f)))
           (and j (equal? commune-aid (machine-job-commune-aid j)))))
       claims))

    ;; the borrower confirms dispatch — the commitment becomes actionable
    ((accept claim-id borrower-did)
     (let ((c (hashmap-ref claims claim-id #f)))
       (cond
        ((not c) (error "machine-registry: no such claim" claim-id))
        ((not (equal? borrower-did (dispatch-claim-borrower-did c)))
         (error "machine-registry: only the borrower accepts the dispatch"))
        ((not (eq? (dispatch-claim-state c) 'claimed))
         (error "machine-registry: the claim is not awaiting acceptance"))
        (else
         (bcom (^machine-registry bcom offers jobs
                                  (hashmap-set claims claim-id
                                               (apply make-dispatch-claim
                                                 #:id claim-id #:job-id (dispatch-claim-job-id c)
                                                 #:offer-id (dispatch-claim-offer-id c)
                                                 #:lender-did (dispatch-claim-lender-did c)
                                                 #:borrower-did borrower-did
                                                 #:state 'accepted
                                                 #:deadline (dispatch-claim-deadline c)
                                                 #:receipt #f '()))
                                  statements))))))

    ;; inner work reclaims the capacity: the claim is recorded preempted —
    ;; never a miss — and the job reopens one ring outward (the spec's
    ;; requeue), capped at ring 3.
    ((preempt claim-id)
     (let ((c (hashmap-ref claims claim-id #f)))
       (cond
        ((not c) (error "machine-registry: no such claim" claim-id))
        ((memq (dispatch-claim-state c) '(complete preempted expired))
         (error "machine-registry: the claim is already closed"))
        (else
         (let* ((j (hashmap-ref jobs (dispatch-claim-job-id c) #f))
                (j* (apply make-machine-job
                      #:id (machine-job-id j)
                      #:borrower-did (machine-job-borrower-did j)
                      #:commune-aid (machine-job-commune-aid j)
                      #:task-class (machine-job-task-class j) #:lane (machine-job-lane j)
                      #:repro-mode (machine-job-repro-mode j)
                      #:input-hash (machine-job-input-hash j)
                      #:envelope-hash (machine-job-envelope-hash j)
                      #:ring (min 3 (+ 1 (machine-job-ring j)))
                      #:state 'open
                      #:created-at (machine-job-created-at j)
                      #:spec-id (machine-job-spec-id j)
                      #:needs (machine-job-needs j) '()))
                (c* (apply make-dispatch-claim
                      #:id claim-id #:job-id (dispatch-claim-job-id c)
                      #:offer-id (dispatch-claim-offer-id c)
                      #:lender-did (dispatch-claim-lender-did c)
                      #:borrower-did (dispatch-claim-borrower-did c)
                      #:state 'preempted
                      #:deadline (dispatch-claim-deadline c)
                      #:receipt (dispatch-claim-receipt c) '())))
           (bcom (^machine-registry bcom offers
                                    (hashmap-set jobs (dispatch-claim-job-id c) j*)
                                    (hashmap-set claims claim-id c*) statements)))))))

    ;; the receipt lands: the claim completes and its job settles. The
    ;; caller verifies the digest and signature BEFORE calling — this only
    ;; records. A preempted-outcome receipt records the same way: state
    ;; "preempted" on the wire, unpaid, not a miss.
    ((receipt! claim-id receipt)
     (let ((c (hashmap-ref claims claim-id #f)))
       (cond
        ((not c) (error "machine-registry: no such claim" claim-id))
        ((not (eq? (dispatch-claim-state c) 'accepted))
         (error "machine-registry: the claim is not running"))
        (else
         (let* ((j (hashmap-ref jobs (dispatch-claim-job-id c) #f))
                (j* (apply make-machine-job
                      #:id (machine-job-id j)
                      #:borrower-did (machine-job-borrower-did j)
                      #:commune-aid (machine-job-commune-aid j)
                      #:task-class (machine-job-task-class j) #:lane (machine-job-lane j)
                      #:repro-mode (machine-job-repro-mode j)
                      #:input-hash (machine-job-input-hash j)
                      #:envelope-hash (machine-job-envelope-hash j)
                      #:ring (machine-job-ring j) #:state 'settled
                      #:created-at (machine-job-created-at j)
                      #:spec-id (machine-job-spec-id j)
                      #:needs (machine-job-needs j) '()))
                (c* (apply make-dispatch-claim
                      #:id claim-id #:job-id (dispatch-claim-job-id c)
                      #:offer-id (dispatch-claim-offer-id c)
                      #:lender-did (dispatch-claim-lender-did c)
                      #:borrower-did (dispatch-claim-borrower-did c)
                      #:state 'complete
                      #:deadline (dispatch-claim-deadline c)
                      #:receipt receipt '())))
           (bcom (^machine-registry bcom offers
                                    (hashmap-set jobs (dispatch-claim-job-id c) j*)
                                    (hashmap-set claims claim-id c*) statements)
                 (receipt-digest receipt)))))))

    ;; receipt lookup by digest — what a settlement entry reconciles against
    ((receipt-of digest)
     (let ((c (hashmap-find
                (lambda (c) (let ((r (dispatch-claim-receipt c)))
                              (and r (equal? digest (receipt-digest r)))))
                claims)))
       (and c (dispatch-claim-receipt c))))

    ;; ── statements — what a bridge lands; reconciliation reads it ─────────
    ((settle statement)
     (bcom (^machine-registry bcom offers jobs claims
                              (cons statement statements))))

    ((statements) statements)))


;;; ── the envelope shelf ──────────────────────────────────────────────────
;;; Job envelopes ride beside the registry, not inside it: the job record
;;; only commits to the envelope's hash. The shelf is a dumb map — the doors
;;; decide who may put and who may fetch; it holds no policy of its own.

(define (^envelope-store bcom envelopes)
  (methods
    ((put! job-id envelope)
     (bcom (^envelope-store bcom (hashmap-set envelopes job-id envelope))))
    ((get job-id)
     (hashmap-ref envelopes job-id #f))
    ((of job-id)
     (hashmap-ref envelopes job-id #f))
    ((portrait) (list 'envelope-store (serialize-hashmap envelopes (lambda (x) x))))))

(define (spawn-envelope-store)
  (spawn ^envelope-store (hashmap)))


;;; ── the binding shelf ───────────────────────────────────────────────────
;;; AccountLinks (compute/binding.scm) ride beside the registry the same
;;; way — keyed "didKey account", a dumb map the doors decide who may put
;;; and unlink. The binding record, signatures and all, is the value; an
;;; unlinked binding stays on the shelf, its status saying who ended it.

(define (^binding-store bcom bindings)
  (methods
    ((put! key binding)
     (bcom (^binding-store bcom (hashmap-set bindings key binding))))
    ((get key)
     (hashmap-ref bindings key #f))
    ((all)
     (hashmap-filter (lambda (v) #t) bindings))
    ((portrait) (list 'binding-store (serialize-hashmap bindings (lambda (x) x))))))

(define (binding-key did-key account)
  (string-append did-key " " account))

(define (spawn-binding-store)
  (spawn ^binding-store (hashmap)))


;;; ── the dispute shelf ────────────────────────────────────────────────────
;;; A dispute's receipt must be retained in full until closure — the shelf
;;; holds <dispute> records keyed by dispute id; the registry holds the
;;; receipts. The lifecycle (open → in-review → closed, sortition, votes,
;;; timelines) lives in compute/dispute.scm; the policy lives in the doors.

(define (^dispute-store bcom disputes)
  (methods
    ((put! key dispute)
     (bcom (^dispute-store bcom (hashmap-set disputes key dispute))))
    ((get key)
     (hashmap-ref disputes key #f))
    ((by-claim claim-id)
     (hashmap-filter
       (lambda (d) (equal? (dispute-claim-id d) claim-id)) disputes))
    ((all)
     (hashmap-filter (lambda (v) #t) disputes))
    ((portrait) (list 'dispute-store (serialize-hashmap disputes (lambda (x) x))))))

(define (spawn-dispute-store)
  (spawn ^dispute-store (hashmap)))


;;; ── the challenge shelf ──────────────────────────────────────────────────
;;; Storage challenges (machine/challenge.scm) beside the claims they probe
;;; — keyed by challenge id, listed by claim so a node finds what its tabs
;;; must answer. The policy (who issues, who answers, who verifies) lives
;;; in the doors; the shelf holds records.

(define (^challenge-store bcom challenges)
  (methods
    ((put! key challenge)
     (bcom (^challenge-store bcom (hashmap-set challenges key challenge))))
    ((get key)
     (hashmap-ref challenges key #f))
    ((by-claim claim-id)
     (hashmap-filter
       (lambda (c) (equal? (store-challenge-claim-id c) claim-id)) challenges))
    ((all)
     (hashmap-filter (lambda (v) #t) challenges))
    ((portrait) (list 'challenge-store (serialize-hashmap challenges (lambda (x) x))))))

(define (spawn-challenge-store)
  (spawn ^challenge-store (hashmap)))


;;; ── the signal shelf ─────────────────────────────────────────────────────
;;; Relay signaling (browser/app/machine-relay.js) beside the claim it
;;; coordinates — per-claim ordered opaque blobs, seq'd as they arrive:
;;; SDP offers and answers, ICE candidates, whatever the two ends must
;;; exchange because neither browser can listen. The policy (who may post,
;;; who may read) lives in the doors; the shelf is a log, and it dies with
;;; the claim's commune the way every shelf here does.

(define (^signal-store bcom signals)
  (methods
    ;; append ROW (an alist minus its seq) to CLAIM-ID's log; the shelf
    ;; assigns the seq so ordering is the shelf's word, not the caller's.
    ;; Seqs start at 1 so 'after 0 reads the whole log.
    ((append! claim-id row)
     (let* ((cur (hashmap-ref signals claim-id '()))
            (seq (+ 1 (length cur))))
       (bcom (^signal-store bcom
               (hashmap-set signals claim-id
                            (append cur (list (cons seq row)))))
             seq)))
    ((by-claim claim-id)
     (hashmap-ref signals claim-id '()))
    ;; the poller's read: rows strictly after SEQ — a fresh reader asks 0
    ((after claim-id seq)
     (drop-while (lambda (r) (<= (car r) seq))
                 (hashmap-ref signals claim-id '())))
    ((all) signals)
    ((portrait) (list 'signal-store (serialize-hashmap signals (lambda (x) x))))))

(define (spawn-signal-store)
  (spawn ^signal-store (hashmap)))


;;; ── persistence ─────────────────────────────────────────────────────────

(define machine-registry-env
  (make-persistence-env
    `((((playnet machine registry) ^machine-registry) ,^machine-registry)
      (((playnet machine registry) ^envelope-store) ,^envelope-store)
      (((playnet machine registry) ^binding-store) ,^binding-store)
      (((playnet machine registry) ^dispute-store) ,^dispute-store)
      (((playnet machine registry) ^challenge-store) ,^challenge-store)
      (((playnet machine registry) ^signal-store) ,^signal-store))))
