;;; compute/registry.scm — a commune's compute dispatch book.
;;;
;;; WHAT THE FILE HOLDS. One ^compute-registry actor per commune: the lane
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

(define-module (playnet compute registry)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module ((playnet utils store-utils)
                #:select (generate-id hashmap-filter hashmap-find
                          serialize-hashmap deserialize-hashmap))
  #:use-module ((playnet utils time) #:select (current-epoch-seconds))
  #:use-module (playnet compute specs)
  #:use-module (playnet compute receipt)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (<lane-offer> make-lane-offer lane-offer?
            lane-offer-id lane-offer-lender-did lane-offer-commune-aid
            lane-offer-lane lane-offer-task-classes lane-offer-headroom
            lane-offer-repro-mode lane-offer-usage-unit lane-offer-retracted?
            lane-offer->list list->lane-offer
            <compute-job> make-compute-job compute-job?
            compute-job-id compute-job-borrower-did compute-job-commune-aid
            compute-job-task-class compute-job-lane compute-job-repro-mode
            compute-job-input-hash compute-job-envelope-hash compute-job-ring
            compute-job-state compute-job-created-at compute-job-spec-id
            compute-job->list list->compute-job
            <dispatch-claim> make-dispatch-claim dispatch-claim?
            dispatch-claim-id dispatch-claim-job-id dispatch-claim-offer-id
            dispatch-claim-lender-did dispatch-claim-borrower-did
            dispatch-claim-state dispatch-claim-deadline dispatch-claim-receipt
            dispatch-claim->list list->dispatch-claim
            lane-offer-answers?
            ^compute-registry compute-registry-env))


;;; ── the records ─────────────────────────────────────────────────────────

(define-record-type <lane-offer>
  (%make-lane-offer id lender-did commune-aid lane task-classes headroom
                    repro-mode usage-unit retracted?)
  lane-offer?
  (id            lane-offer-id)
  (lender-did    lane-offer-lender-did)    ; AID or did:key of the member
  (commune-aid   lane-offer-commune-aid)
  (lane          lane-offer-lane)          ; string — the lane name
  (task-classes  lane-offer-task-classes)  ; list of task-class symbols
  (headroom      lane-offer-headroom)      ; number — units/second it can lend
  (repro-mode    lane-offer-repro-mode)    ; 'exact | 'deterministic | 'none
  (usage-unit    lane-offer-usage-unit)    ; "tokens" | "seconds"
  (retracted?    lane-offer-retracted?))

(define* (make-lane-offer #:key id lender-did commune-aid lane task-classes
                          headroom repro-mode (usage-unit "seconds")
                          (retracted? #f))
  (unless (and (list? task-classes) (every task-class? task-classes))
    (error "lane-offer: task-classes must be a list of task classes" task-classes))
  (unless (repro-mode? repro-mode)
    (error "lane-offer: not a repro mode" repro-mode))
  (unless (and (number? headroom) (> headroom 0))
    (error "lane-offer: headroom must be a positive number" headroom))
  (unless (member usage-unit '("tokens" "seconds"))
    (error "lane-offer: usage-unit must be tokens or seconds" usage-unit))
  (%make-lane-offer id lender-did commune-aid lane task-classes headroom
                    repro-mode usage-unit retracted?))

(define-record-type <compute-job>
  (%make-compute-job id borrower-did commune-aid task-class lane repro-mode
                     input-hash envelope-hash ring state created-at spec-id)
  compute-job?
  (id            compute-job-id)               ; the bridgeJobId
  (borrower-did  compute-job-borrower-did)
  (commune-aid   compute-job-commune-aid)
  (task-class    compute-job-task-class)
  (lane          compute-job-lane)
  (repro-mode    compute-job-repro-mode)
  (input-hash    compute-job-input-hash)
  (envelope-hash compute-job-envelope-hash)  ; hash of the envelope, not the body
  (ring          compute-job-ring)           ; 0..3 — the outermost it may route at
  (state         compute-job-state)          ; 'open | 'claimed | 'settled | 'withdrawn
  (created-at    compute-job-created-at)     ; epoch ms
  (spec-id       compute-job-spec-id))       ; the ResourceSpecification id it names

(define* (make-compute-job #:key id borrower-did commune-aid task-class lane
                           repro-mode input-hash (envelope-hash #f)
                           (ring 1) (state 'open) created-at (spec-id #f))
  (unless (task-class? task-class)
    (error "compute-job: not a task class" task-class))
  (unless (repro-mode? repro-mode)
    (error "compute-job: not a repro mode" repro-mode))
  (unless (and (integer? ring) (<= 0 ring 3))
    (error "compute-job: ring must be an integer 0..3" ring))
  (%make-compute-job id borrower-did commune-aid task-class lane repro-mode
                     input-hash envelope-hash ring state created-at spec-id))

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
;;; task class is among the classes it runs, it has headroom left, the
;;; lender is not the borrower, and it is live. Replay mode is not part of
;;; the match — a borrower that needs exact replay reads it off the offer;
;;; refusing 'none offers here would hide capacity a 'none job wants.

(define (lane-offer-answers? offer job)
  (and (not (lane-offer-retracted? offer))
       (equal? (lane-offer-lane offer) (compute-job-lane job))
       (memq (compute-job-task-class job) (lane-offer-task-classes offer))
       (> (lane-offer-headroom offer) 0)
       (not (equal? (lane-offer-lender-did offer)
                    (compute-job-borrower-did job)))))


;;; ── wire shapes — lists, the way every registry crosses the seam ────────

(define (lane-offer->list o)
  (list (lane-offer-id o) (lane-offer-lender-did o) (lane-offer-commune-aid o)
        (lane-offer-lane o) (lane-offer-task-classes o) (lane-offer-headroom o)
        (symbol->string (lane-offer-repro-mode o)) (lane-offer-usage-unit o)
        (lane-offer-retracted? o)))

(define (list->lane-offer l)
  (apply make-lane-offer
         #:id (list-ref l 0) #:lender-did (list-ref l 1)
         #:commune-aid (list-ref l 2) #:lane (list-ref l 3)
         #:task-classes (list-ref l 4) #:headroom (list-ref l 5)
         #:repro-mode (string->symbol (list-ref l 6))
         #:usage-unit (list-ref l 7) #:retracted? (list-ref l 8) '()))

(define (compute-job->list j)
  (list (compute-job-id j) (compute-job-borrower-did j)
        (compute-job-commune-aid j) (symbol->string (compute-job-task-class j))
        (compute-job-lane j) (symbol->string (compute-job-repro-mode j))
        (compute-job-input-hash j) (compute-job-envelope-hash j)
        (compute-job-ring j) (symbol->string (compute-job-state j))
        (compute-job-created-at j) (compute-job-spec-id j)))

(define (list->compute-job l)
  (apply make-compute-job
         #:id (list-ref l 0) #:borrower-did (list-ref l 1)
         #:commune-aid (list-ref l 2)
         #:task-class (string->symbol (list-ref l 3)) #:lane (list-ref l 4)
         #:repro-mode (string->symbol (list-ref l 5))
         #:input-hash (list-ref l 6) #:envelope-hash (list-ref l 7)
         #:ring (list-ref l 8) #:state (string->symbol (list-ref l 9))
         #:created-at (list-ref l 10) #:spec-id (list-ref l 11) '()))

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

(define-actor (^compute-registry bcom offers jobs claims statements)
  #:portrait
  (lambda ()
    (list (serialize-hashmap offers lane-offer->list)
          (serialize-hashmap jobs compute-job->list)
          (serialize-hashmap claims dispatch-claim->list)
          statements))
  #:version 1
  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^compute-registry
                  (deserialize-hashmap (car data) list->lane-offer)
                  (deserialize-hashmap (cadr data) list->compute-job)
                  (deserialize-hashmap (caddr data) list->dispatch-claim)
                  (cadddr data)))
      (else (error "Unknown ^compute-registry version" version))))

  (methods

    ;; ── offers ───────────────────────────────────────────────────────────
    ((offer lender-did commune-aid lane task-classes headroom repro-mode
            #:optional (usage-unit "seconds"))
     (let* ((id (generate-id "offer-"))
            (o (make-lane-offer #:id id #:lender-did lender-did
                                #:commune-aid commune-aid #:lane lane
                                #:task-classes task-classes #:headroom headroom
                                #:repro-mode repro-mode #:usage-unit usage-unit)))
       (bcom (^compute-registry bcom (hashmap-set offers id o) jobs claims statements)
             id)))

    ((retract offer-id lender-did)
     (let ((o (hashmap-ref offers offer-id #f)))
       (cond
        ((not o) (values))
        ((not (equal? lender-did (lane-offer-lender-did o)))
         (error "compute-registry: only the lender retracts an offer"))
        (else
         (let ((o* (apply make-lane-offer
                          #:id (lane-offer-id o) #:lender-did lender-did
                          #:commune-aid (lane-offer-commune-aid o)
                          #:lane (lane-offer-lane o)
                          #:task-classes (lane-offer-task-classes o)
                          #:headroom (lane-offer-headroom o)
                          #:repro-mode (lane-offer-repro-mode o)
                          #:usage-unit (lane-offer-usage-unit o)
                          #:retracted? #t '())))
           (bcom (^compute-registry bcom (hashmap-set offers offer-id o*)
                                    jobs claims statements)))))))

    ((offers commune-aid)
     (hashmap-filter
       (lambda (o) (and (equal? commune-aid (lane-offer-commune-aid o))
                        (not (lane-offer-retracted? o))))
       offers))

    ((offer-of offer-id) (hashmap-ref offers offer-id #f))

    ;; ── jobs ─────────────────────────────────────────────────────────────
    ((submit borrower-did commune-aid task-class lane repro-mode input-hash
             #:optional (envelope-hash #f) (ring 1) (spec-id #f))
     (let* ((id (generate-id "job-"))
            (j (make-compute-job #:id id #:borrower-did borrower-did
                                 #:commune-aid commune-aid #:task-class task-class
                                 #:lane lane #:repro-mode repro-mode
                                 #:input-hash input-hash #:envelope-hash envelope-hash
                                 #:ring ring #:created-at
                                 (* (current-epoch-seconds) 1000)
                                 #:spec-id spec-id)))
       (bcom (^compute-registry bcom offers (hashmap-set jobs id j)
                                claims statements) id)))

    ((job-of job-id) (hashmap-ref jobs job-id #f))

    ((jobs commune-aid)
     (hashmap-filter
       (lambda (j) (equal? commune-aid (compute-job-commune-aid j))) jobs))

    ((open-jobs commune-aid)
     (hashmap-filter
       (lambda (j) (and (equal? commune-aid (compute-job-commune-aid j))
                        (eq? (compute-job-state j) 'open)))
       jobs))

    ((withdraw job-id borrower-did)
     (let ((j (hashmap-ref jobs job-id #f)))
       (cond
        ((not j) (values))
        ((not (equal? borrower-did (compute-job-borrower-did j)))
         (error "compute-registry: only the borrower withdraws a job"))
        ((not (eq? (compute-job-state j) 'open))
         (error "compute-registry: only an open job withdraws"))
        (else
         (bcom (^compute-registry bcom offers
                                  (hashmap-set jobs job-id
                                               (apply make-compute-job
                                                 #:id job-id #:borrower-did borrower-did
                                                 #:commune-aid (compute-job-commune-aid j)
                                                 #:task-class (compute-job-task-class j)
                                                 #:lane (compute-job-lane j)
                                                 #:repro-mode (compute-job-repro-mode j)
                                                 #:input-hash (compute-job-input-hash j)
                                                 #:envelope-hash (compute-job-envelope-hash j)
                                                 #:ring (compute-job-ring j)
                                                 #:state 'withdrawn
                                                 #:created-at (compute-job-created-at j)
                                                 #:spec-id (compute-job-spec-id j) '()))
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
        ((not j) (error "compute-registry: no such job" job-id))
        ((not o) (error "compute-registry: no such offer" offer-id))
        ((not (equal? lender-did (lane-offer-lender-did o)))
         (error "compute-registry: the offer is not the claimants"))
        ((not (eq? (compute-job-state j) 'open))
         (error "compute-registry: job is not open"))
        ((not (lane-offer-answers? o j))
         (error "compute-registry: the offer does not answer the job"))
        (else
         (let* ((cid (generate-id "claim-"))
                (c (make-dispatch-claim #:id cid #:job-id job-id #:offer-id offer-id
                                        #:lender-did lender-did
                                        #:borrower-did (compute-job-borrower-did j)
                                        #:deadline deadline))
                (j* (apply make-compute-job
                      #:id job-id #:borrower-did (compute-job-borrower-did j)
                      #:commune-aid (compute-job-commune-aid j)
                      #:task-class (compute-job-task-class j) #:lane (compute-job-lane j)
                      #:repro-mode (compute-job-repro-mode j)
                      #:input-hash (compute-job-input-hash j)
                      #:envelope-hash (compute-job-envelope-hash j)
                      #:ring (compute-job-ring j) #:state 'claimed
                      #:created-at (compute-job-created-at j)
                      #:spec-id (compute-job-spec-id j) '())))
           (bcom (^compute-registry bcom offers (hashmap-set jobs job-id j*)
                                    (hashmap-set claims cid c) statements)
                 cid))))))

    ((claim-of claim-id) (hashmap-ref claims claim-id #f))

    ((claims commune-aid)
     (hashmap-filter
       (lambda (c)
         (let ((j (hashmap-ref jobs (dispatch-claim-job-id c) #f)))
           (and j (equal? commune-aid (compute-job-commune-aid j)))))
       claims))

    ;; the borrower confirms dispatch — the commitment becomes actionable
    ((accept claim-id borrower-did)
     (let ((c (hashmap-ref claims claim-id #f)))
       (cond
        ((not c) (error "compute-registry: no such claim" claim-id))
        ((not (equal? borrower-did (dispatch-claim-borrower-did c)))
         (error "compute-registry: only the borrower accepts the dispatch"))
        ((not (eq? (dispatch-claim-state c) 'claimed))
         (error "compute-registry: the claim is not awaiting acceptance"))
        (else
         (bcom (^compute-registry bcom offers jobs
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
        ((not c) (error "compute-registry: no such claim" claim-id))
        ((memq (dispatch-claim-state c) '(complete preempted expired))
         (error "compute-registry: the claim is already closed"))
        (else
         (let* ((j (hashmap-ref jobs (dispatch-claim-job-id c) #f))
                (j* (apply make-compute-job
                      #:id (compute-job-id j)
                      #:borrower-did (compute-job-borrower-did j)
                      #:commune-aid (compute-job-commune-aid j)
                      #:task-class (compute-job-task-class j) #:lane (compute-job-lane j)
                      #:repro-mode (compute-job-repro-mode j)
                      #:input-hash (compute-job-input-hash j)
                      #:envelope-hash (compute-job-envelope-hash j)
                      #:ring (min 3 (+ 1 (compute-job-ring j)))
                      #:state 'open
                      #:created-at (compute-job-created-at j)
                      #:spec-id (compute-job-spec-id j) '()))
                (c* (apply make-dispatch-claim
                      #:id claim-id #:job-id (dispatch-claim-job-id c)
                      #:offer-id (dispatch-claim-offer-id c)
                      #:lender-did (dispatch-claim-lender-did c)
                      #:borrower-did (dispatch-claim-borrower-did c)
                      #:state 'preempted
                      #:deadline (dispatch-claim-deadline c)
                      #:receipt (dispatch-claim-receipt c) '())))
           (bcom (^compute-registry bcom offers
                                    (hashmap-set jobs (dispatch-claim-job-id c) j*)
                                    (hashmap-set claims claim-id c*) statements)))))))

    ;; the receipt lands: the claim completes and its job settles. The
    ;; caller verifies the digest and signature BEFORE calling — this only
    ;; records. A preempted-outcome receipt records the same way: state
    ;; "preempted" on the wire, unpaid, not a miss.
    ((receipt! claim-id receipt)
     (let ((c (hashmap-ref claims claim-id #f)))
       (cond
        ((not c) (error "compute-registry: no such claim" claim-id))
        ((not (eq? (dispatch-claim-state c) 'accepted))
         (error "compute-registry: the claim is not running"))
        (else
         (let* ((j (hashmap-ref jobs (dispatch-claim-job-id c) #f))
                (j* (apply make-compute-job
                      #:id (compute-job-id j)
                      #:borrower-did (compute-job-borrower-did j)
                      #:commune-aid (compute-job-commune-aid j)
                      #:task-class (compute-job-task-class j) #:lane (compute-job-lane j)
                      #:repro-mode (compute-job-repro-mode j)
                      #:input-hash (compute-job-input-hash j)
                      #:envelope-hash (compute-job-envelope-hash j)
                      #:ring (compute-job-ring j) #:state 'settled
                      #:created-at (compute-job-created-at j)
                      #:spec-id (compute-job-spec-id j) '()))
                (c* (apply make-dispatch-claim
                      #:id claim-id #:job-id (dispatch-claim-job-id c)
                      #:offer-id (dispatch-claim-offer-id c)
                      #:lender-did (dispatch-claim-lender-did c)
                      #:borrower-did (dispatch-claim-borrower-did c)
                      #:state 'complete
                      #:deadline (dispatch-claim-deadline c)
                      #:receipt receipt '())))
           (bcom (^compute-registry bcom offers
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
     (bcom (^compute-registry bcom offers jobs claims
                              (cons statement statements))))

    ((statements) statements)))


;;; ── persistence ─────────────────────────────────────────────────────────

(define compute-registry-env
  (make-persistence-env
    `((((playnet compute registry) ^compute-registry) ,^compute-registry))))
