;;; module/playnet/doors/compute.scm — the compute doors of the governance
;;; service: lane offers, job intents, dispatch claims, receipts, and the
;;; settlement statements a ring-3 bridge lands.
;;;
;;; A fragment of the governance service (playnet doors governance): a
;;; procedure from the actor's context to the doors it serves, composed in
;;; by (playnet boot governance). `with-governance-ctx` binds the actor's
;;; cells and helpers; the commune's ^compute-registry is spawned lazily
;;; per commune and memoized in this closure (matching half of
;;; spec/playnet-compute.md — the solver is not in this path).
;;;
;;; WHOSE ACT. Offers, jobs, claims, preemptions and withdrawals are member
;;; acts: IDENTITY-KEY is the caller's AID, the session forwards it, and
;;; the registry checks the record's own field — only the lender retracts
;;; an offer, only the borrower accepts a dispatch. compute-settle is a
;;; COMMUNE act — a bridge lands a statement through the commune's own
;;; governance, gov-cap gated like accept-reimbursement.

(define-module (playnet doors compute)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet compute specs)
  #:use-module (playnet compute receipt)
  #:use-module (playnet compute registry)
  #:use-module (playnet compute settlement)
  #:use-module (playnet compute envelope)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:use-module ((playnet keri citizen-sig) #:select (verify-said-signature))
  #:use-module ((playnet utils time) #:select (current-epoch-seconds))
  #:export (governance-compute-doors))


(define (governance-compute-doors ctx)
  ;; one ^compute-registry per commune, spawned on first touch
  (let ((registries (make-hash-table)))
    (with-governance-ctx ctx

      (define (registry-for commune-aid)
        (or (hash-ref registries commune-aid)
            (let ((r (spawn ^compute-registry (hashmap) (hashmap)
                            (hashmap) '())))
              (hash-set! registries commune-aid r)
              r)))

      ;; a door's `. opts` arrive as a symbol-pair list ('key value …);
      ;; one local lookup keeps the fragment self-contained
      (define (opt-ref opts key default)
        (let ((m (memq key opts)))
          (if (and m (pair? (cdr m))) (cadr m) default)))

      ;; ── wire shapes ───────────────────────────────────────────────────
      ;; alist rows out — self-describing over the seam, the same shape the
      ;; purchase-claims face reads.

      (define (offer-row o)
        `(("id" . ,(lane-offer-id o))
          ("lender" . ,(lane-offer-lender-did o))
          ("commune" . ,(lane-offer-commune-aid o))
          ("lane" . ,(lane-offer-lane o))
          ("taskClasses" . ,(list->vector
                             (map symbol->string (lane-offer-task-classes o))))
          ("headroom" . ,(lane-offer-headroom o))
          ("reproMode" . ,(symbol->string (lane-offer-repro-mode o)))
          ("usageUnit" . ,(lane-offer-usage-unit o))))

      (define (job-row j)
        `(("id" . ,(compute-job-id j))
          ("borrower" . ,(compute-job-borrower-did j))
          ("commune" . ,(compute-job-commune-aid j))
          ("taskClass" . ,(symbol->string (compute-job-task-class j)))
          ("lane" . ,(compute-job-lane j))
          ("reproMode" . ,(symbol->string (compute-job-repro-mode j)))
          ("inputHash" . ,(compute-job-input-hash j))
          ("envelopeHash" . ,(compute-job-envelope-hash j))
          ("ring" . ,(compute-job-ring j))
          ("state" . ,(symbol->string (compute-job-state j)))
          ("specId" . ,(compute-job-spec-id j))))

      (define (claim-row c)
        `(("id" . ,(dispatch-claim-id c))
          ("jobId" . ,(dispatch-claim-job-id c))
          ("offerId" . ,(dispatch-claim-offer-id c))
          ("lender" . ,(dispatch-claim-lender-did c))
          ("borrower" . ,(dispatch-claim-borrower-did c))
          ("state" . ,(symbol->string (dispatch-claim-state c)))
          ("deadline" . ,(dispatch-claim-deadline c))))

      ;; a receipt over the wire is the JSON object the lender's node
      ;; produced — symbol-keyed alist here, the same field names the
      ;; canonical digest hashes. usage/repro are alist sub-objects.
      (define (wire->receipt w)
        (define (ref k) (assq-ref w k))
        (define (usage-of u)
          (and u (make-usage-meter #:unit (assq-ref u 'unit)
                                   #:amount (assq-ref u 'amount))))
        (define (repro-of r)
          (and r (make-repro-spec
                   #:mode (string->symbol (assq-ref r 'mode))
                   #:seed (assq-ref r 'seed)
                   #:decoding (assq-ref r 'decoding)
                   #:engine-version (assq-ref r 'engineVersion))))
        (make-receipt #:bridge-job-id (ref 'bridgeJobId)
                      #:lender-did (ref 'lenderDid)
                      #:input-hash (ref 'inputHash)
                      #:output-hash (ref 'outputHash)
                      #:engine (ref 'engine)
                      #:usage (usage-of (ref 'usage))
                      #:repro (repro-of (ref 'repro))
                      #:executed-at (ref 'executedAt)
                      #:lender-sig (ref 'lenderSig)
                      #:borrower-sig (ref 'borrowerSig)
                      #:digest-field (ref 'digest)))

      ;; digest first, signature where resolvable — a did:key lender's sig
      ;; verifies only when the resolver can name its key; the answer is
      ;; 'verified | 'unverifiable | 'bad, never a silent pass.
      (define (sig-verdict r)
        (let ((d (receipt-digest r))
              (sig (receipt-lender-sig r))
              (lender (receipt-lender-did r)))
          (cond
           ((not (and (string? sig) (string? lender))) 'unverifiable)
           ((verify-said-signature d sig lender) 'verified)
           (else 'bad))))

      (declared-doors governance

        ;; ── offers ──────────────────────────────────────────────────────
        ;; IDENTITY-KEY offers its machines: LANE the lane name, CLASSES a
        ;; comma list of task classes over the wire, HEADROOM units/second
        ;; kept for inner-ring work, REPRO the lender's own replay claim.
        ((compute-offer identity-key commune-aid lane classes headroom repro . opts)
         (let ((classes (filter-map (lambda (s)
                                     (let ((sym (string->symbol (string-trim-both s))))
                                       (and (task-class? sym) sym)))
                                   (if (string? classes)
                                       (string-split classes #\,)
                                       classes)))
               (usage-unit (or (opt-ref opts 'usageUnit #f) "seconds"))
               (repro-sym (if (symbol? repro) repro (string->symbol repro))))
           (catch #t
             (lambda ()
               (when (null? classes)
                 (error "compute-offer: no valid task classes"))
               (cons 'ok ($ (registry-for commune-aid) 'offer
                            identity-key commune-aid lane classes
                            headroom repro-sym usage-unit)))
             (lambda (k . a) (list 'error (format #f "compute-offer: ~a" a))))))

        ((compute-retract identity-key commune-aid offer-id)
         (catch #t
           (lambda ()
             ($ (registry-for commune-aid) 'retract offer-id identity-key)
             (cons 'ok #t))
           (lambda (k . a) (list 'error (format #f "compute-retract: ~a" a)))))

        ((compute-offers commune-aid)
         (cons 'ok (map offer-row
                        ($ (registry-for commune-aid) 'offers commune-aid))))

        ;; ── jobs ────────────────────────────────────────────────────────
        ;; IDENTITY-KEY submits: the intent side. RING defaults 1 — the job
        ;; enters at its own commune and walks outward only by preemption.
        ((compute-submit identity-key commune-aid task-class lane repro input-hash . opts)
         (catch #t
           (lambda ()
             (cons 'ok
               ($ (registry-for commune-aid) 'submit
                  identity-key commune-aid
                  (string->symbol task-class) lane (string->symbol repro)
                  input-hash
                  (opt-ref opts 'envelopeHash #f)
                  (opt-ref opts 'ring 1)
                  (opt-ref opts 'specId #f))))
           (lambda (k . a) (list 'error (format #f "compute-submit: ~a" a)))))

        ((compute-withdraw identity-key commune-aid job-id)
         (catch #t
           (lambda ()
             ($ (registry-for commune-aid) 'withdraw job-id identity-key)
             (cons 'ok #t))
           (lambda (k . a) (list 'error (format #f "compute-withdraw: ~a" a)))))

        ((compute-jobs commune-aid)
         (cons 'ok (map job-row
                        ($ (registry-for commune-aid) 'jobs commune-aid))))

        ((compute-match commune-aid job-id)
         (cons 'ok (map offer-row
                        ($ (registry-for commune-aid) 'match job-id))))

        ;; ── claims ──────────────────────────────────────────────────────
        ;; IDENTITY-KEY (a lender) takes the job under its own offer;
        ;; DEADLINE-MS is the countersign-by time — the spec's no-receipt-
        ;; no-payment window. Default 72h, the challenge window's length.
        ((compute-claim identity-key commune-aid job-id offer-id . opts)
         (catch #t
           (lambda ()
             (let ((deadline (or (opt-ref opts 'deadline #f)
                                 (* (+ (current-epoch-seconds)
                                       (* 72 3600)) 1000))))
               (cons 'ok ($ (registry-for commune-aid) 'claim
                            identity-key job-id offer-id deadline))))
           (lambda (k . a) (list 'error (format #f "compute-claim: ~a" a)))))

        ((compute-accept identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             ($ (registry-for commune-aid) 'accept claim-id identity-key)
             (cons 'ok #t))
           (lambda (k . a) (list 'error (format #f "compute-accept: ~a" a)))))

        ((compute-preempt identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (let ((c ($ (registry-for commune-aid) 'claim-of claim-id)))
               (cond
                ((not c) (error "compute-preempt: no such claim"))
                ;; the lender preempts its own claim; a commune governor
                ;; preempts any (inner work reclaiming capacity)
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))
                          (governor? identity-key)))
                 (error "compute-preempt: lender, borrower or governor only"))
                (else ($ (registry-for commune-aid) 'preempt claim-id)
                      (cons 'ok #t)))))
           (lambda (k . a) (list 'error (format #f "compute-preempt: ~a" a)))))

        ((compute-claims commune-aid)
         (cons 'ok (map claim-row
                        ($ (registry-for commune-aid) 'claims commune-aid))))

        ;; ── receipts ────────────────────────────────────────────────────
        ;; W is the wire alist the lender's node emitted. The door rebuilds
        ;; the record, recomputes the digest (the claimed digest must match
        ;; the body), checks the lender's signature where resolvable, then
        ;; records — and folds the event into the scope's observer as a
        ;; `use` event, the VF truth of the borrow.
        ((compute-receipt identity-key commune-aid w)
         (catch #t
           (lambda ()
             (let* ((r (wire->receipt w))
                    (claim-id (receipt-bridge-job-id r))
                    (verdict (sig-verdict r)))
               (cond
                ((not (receipt-digest-ok? r))
                 (list 'error "compute-receipt: digest does not match the body"))
                ((eq? verdict 'bad)
                 (list 'error "compute-receipt: lender signature does not verify"))
                (else
                 (let* ((reg (registry-for commune-aid))
                        (claim ($ reg 'claim-of claim-id))
                        (digest ($ reg 'receipt! claim-id r)))
                   ;; the fold — a `use` event on the commune's observer,
                   ;; satisfies the job intent, fulfills the claim
                   (let ((obs (scope-observer commune-aid)))
                     (when obs
                       (catch #t
                         (lambda ()
                           ($ obs 'record-event
                              (receipt->event r
                                 #:scope-id commune-aid
                                 #:spec-id (and claim
                                                (compute-job-spec-id
                                                  ($ reg 'job-of
                                                     (dispatch-claim-job-id claim))))
                                 #:commitment-id claim-id
                                 #:intent-id (and claim
                                                  (dispatch-claim-job-id claim)))))
                         (lambda _ #t))))
                   (cons 'ok (list digest verdict)))))))
           (lambda (k . a) (list 'error (format #f "compute-receipt: ~a" a)))))

        ;; dry-run: what would this receipt answer — digest ok, sig verdict
        ((compute-verify w)
         (catch #t
           (lambda ()
             (let ((r (wire->receipt w)))
               (cons 'ok (list (receipt-digest-ok? r) (sig-verdict r)))))
           (lambda (k . a) (list 'error (format #f "compute-verify: ~a" a)))))

        ;; ── settlement — a commune act, gov-cap gated ────────────────────
        ;; W is the bridge's statement as an alist: period, entries,
        ;; payments, bridgeSig. Gov-cap via mint-gov-cap — the same gate
        ;; accept-reimbursement runs. Reconciliation answers (ok matched
        ;; missing claimed paid).
        ((compute-settle identity-key commune-aid w)
         (let ((sc (scope-for commune-aid)))
           (if (not sc)
               (list 'error "compute-settle: no scope reachable here for that commune")
               (catch #t
                 (lambda ()
                   ($ sc 'mint-gov-cap identity-key)   ; refuses non-governors
                   (let* ((stmt (make-settlement-statement
                                  #:period (assq-ref w 'period)
                                  #:entries (or (assq-ref w 'entries) '())
                                  #:payments (or (assq-ref w 'payments) '())
                                  #:bridge-sig (assq-ref w 'bridgeSig)))
                          (reg (registry-for commune-aid))
                          (result (reconcile-statement
                                    stmt (lambda (d) ($ reg 'receipt-of d)))))
                     ($ reg 'settle stmt)
                     (apply (lambda (matched missing claimed paid)
                              (cons 'ok (list (length matched) (length missing)
                                              claimed paid)))
                            result)))
                 (lambda (k . a)
                   (list 'error (format #f "compute-settle: ~a" a)))))))

        ((compute-statements commune-aid)
         (cons 'ok ($ (registry-for commune-aid) 'statements)))

        ;; the envelope contract — validates a job envelope a node would
        ;; run; refuses any envelope carrying a price key
        ((compute-envelope w)
         (catch #t
           (lambda ()
             (let ((e (alist->job-envelope w)))
               (cons 'ok (job-envelope-bridge-job-id e))))
           (lambda (k . a) (list 'error (format #f "compute-envelope: ~a" a)))))))))
