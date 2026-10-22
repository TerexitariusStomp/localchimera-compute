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
  #:use-module (playnet compute replay)
  #:use-module (playnet compute dispute)
  #:use-module (playnet compute binding)
  #:use-module (playnet compute binding-verifiers)
  #:use-module (playnet compute payout)
  #:use-module (playnet compute executors)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:use-module ((playnet keri citizen-sig) #:select (verify-said-signature))
  #:use-module ((playnet utils time) #:select (current-epoch-seconds))
  #:export (governance-compute-doors *compute-clock*))


;;; *compute-clock* — the "now" the compute doors read, as a parameter so a
;;; test can walk a dispute timeline without waiting days. Defaults to the
;;; wall clock; nothing outside a test rebinds it.
(define *compute-clock* (make-parameter current-epoch-seconds))

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

      ;; the envelope shelf beside the registry — same laziness, same map,
      ;; a distinct key so one never shadows the other
      (define (shelf-for commune-aid)
        (let ((k (string-append "envelope:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-envelope-store)))
                (hash-set! registries k s)
                s))))

      ;; the binding shelf — account-links beside the registry, same laziness
      (define (binds-for commune-aid)
        (let ((k (string-append "binding:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-binding-store)))
                (hash-set! registries k s)
                s))))

      ;; the dispute shelf — <dispute> records by dispute id, beside the
      ;; receipts they contest. Retention is the registry's promise: a
      ;; disputed receipt lives in full until the dispute closes.
      (define (disputes-for commune-aid)
        (let ((k (string-append "dispute:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-dispute-store)))
                (hash-set! registries k s)
                s))))

      ;; the hive's review pool: every citizen the service has met, minus
      ;; the dispute's parties — sortition scores and picks from this list.
      (define (review-pool exclude)
        (hashmap-fold (lambda (aid _ acc)
                        (if (member aid exclude) acc (cons aid acc)))
                      '() (registry-snapshot)))

      ;; a door's `. opts` arrive as a symbol-pair list ('key value …);
      ;; one local lookup keeps the fragment self-contained
      (define (opt-ref opts key default)
        (let ((m (memq key opts)))
          (if (and m (pair? (cdr m))) (cadr m) default)))

      ;; the wire arrives as JSON (json-read-ordered): objects are lists of
      ;; ("key" . val) entries, arrays are vectors. Everything below reads
      ;; symbol keys and Scheme lists — normalize at the boundary so no
      ;; reader downstream carries the distinction (a JSON "amount" must
      ;; hit the envelope's priced-key refusal exactly like 'amount does).
      ;; A list whose every element is a string-keyed pair is an object;
      ;; any other list is just a list.
      (define (wire-normalize v)
        (cond
         ((vector? v) (map wire-normalize (vector->list v)))
         ((and (list? v) (not (null? v))
               (every (lambda (e) (and (pair? e) (string? (car e)))) v))
          (map (lambda (e) (cons (string->symbol (car e))
                                 (wire-normalize (cdr e))))
               v))
         ((list? v) (map wire-normalize v))
         ((pair? v) (cons (car v) (wire-normalize (cdr v))))
         (else v)))

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

      ;; a dispute over the wire: the record plus its evidence — the
      ;; challenge fields ride nested, verdicts as {aid: verdict}.
      (define (dispute->wire d)
        (let ((ch (dispute-challenge d)))
          `(("id" . ,(dispute-id d))
            ("claimId" . ,(dispute-claim-id d))
            ("challenger" . ,(dispute-challenger d))
            ("kind" . ,(symbol->string (dispute-kind d)))
            ("state" . ,(symbol->string (dispute-state d)))
            ("raisedAt" . ,(dispute-raised-at d))
            ("reviewers" . ,(list->vector (dispute-reviewers d)))
            ("verdicts" . ,(map (lambda (p)
                                  (cons (car p) (symbol->string (cdr p))))
                                (dispute-verdicts d)))
            ("outcome" . ,(and (dispute-outcome d)
                               (symbol->string (dispute-outcome d))))
            ("challenge" . ,(and ch
                                 `(("receiptDigest" . ,(challenge-receipt-digest ch))
                                   ("reproduced" . ,(challenge-reproduced ch))
                                   ("attestationHash" . ,(challenge-attestation-hash ch))
                                   ("counterHash" . ,(challenge-counter-hash ch))))))))

      ;; a receipt over the wire is the JSON object the lender's node
      ;; produced — symbol-keyed alist here, the same field names the
      ;; canonical digest hashes. usage/repro are alist sub-objects.
      (define (wire->receipt w0)
        (define w (wire-normalize w0))
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
             ;; an 'envelope opt means the wire is carrying the body — the
             ;; shelf keeps it for the claim's lender. It must be a clean
             ;; job envelope: alist->job-envelope refuses priced ones.
             (let* ((env (opt-ref opts 'envelope #f))
                    (parsed (and env (alist->job-envelope (wire-normalize env))))
                    (job-id ($ (registry-for commune-aid) 'submit
                               identity-key commune-aid
                               (string->symbol task-class) lane
                               (string->symbol repro) input-hash
                               (opt-ref opts 'envelopeHash #f)
                               (opt-ref opts 'ring 1)
                               (opt-ref opts 'specId #f))))
               (when parsed
                 ($ (shelf-for commune-aid) 'put! job-id parsed))
               (cons 'ok job-id)))
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
                                 (* (+ ((*compute-clock*))
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

        ;; IDENTITY-KEY (the claim's lender) fetches the envelope it's meant
        ;; to run. Borrowers already have their own envelope; anyone else
        ;; gets refused — the envelope is the job's payload, not a broadcast.
        ((compute-fetch-envelope identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (let ((c ($ (registry-for commune-aid) 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "compute-fetch-envelope: no such claim"))
                ((not (equal? identity-key (dispatch-claim-lender-did c)))
                 (list 'error "compute-fetch-envelope: the claim's lender only"))
                ((not (memq (dispatch-claim-state c) '(claimed accepted)))
                 (list 'error "compute-fetch-envelope: claim no longer live"))
                (else
                 (let ((env ($ (shelf-for commune-aid) 'get
                               (dispatch-claim-job-id c))))
                   (if env
                       (cons 'ok (job-envelope->alist env))
                       (list 'error "compute-fetch-envelope: not on the shelf")))))))
           (lambda (k . a) (list 'error (format #f "compute-fetch-envelope: ~a" a)))))

        ;; ── replay ───────────────────────────────────────────────────────
        ;; PoI replay is authoritative: the borrower, the lender, or the
        ;; commune's governance asks the question again and the replay's
        ;; counter-hash is the evidence. The executor arrives injected —
        ;; absent one the door answers 'no-executor, fail-closed, and a
        ;; 'none job answers 'unverifiable (never a verdict against the
        ;; lender). The reply carries the challenge fields: receipt digest,
        ;; reproduced, the claimed attestation hash, the replay's counter.
        ((compute-replay identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (let* ((reg (registry-for commune-aid))
                    (c ($ reg 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "compute-replay: no such claim"))
                ((not (dispatch-claim-receipt c))
                 (list 'error "compute-replay: claim has no receipt yet"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))))
                 (list 'error "compute-replay: the claim's parties only"))
                (else
                 (let* ((r (dispatch-claim-receipt c))
                        (env ($ (shelf-for commune-aid) 'get
                                (dispatch-claim-job-id c)))
                        (repro (receipt-repro r)))
                   (cond
                    ((not env)
                     (list 'error "compute-replay: envelope not on the shelf"))
                    ((not repro)
                     (list 'error "compute-replay: receipt has no repro spec"))
                    (else
                     (let* ((x (executor-for commune-aid))
                            (result (replay-job env repro
                                                (receipt-output-hash r)
                                                #:executor (if x (%executor-run x)
                                                               %replay-unavailable)))
                            (ch (make-challenge
                                 #:receipt-digest (receipt-digest r)
                                 #:reproduced (replay-verdict result)
                                 #:attestation-hash (receipt-output-hash r)
                                 #:counter-hash (and (eq? (car result) 'ok)
                                                     (list-ref result 2)))))
                       (cons 'ok `(("receiptDigest" . ,(challenge-receipt-digest ch))
                                   ("reproduced"     . ,(challenge-reproduced ch))
                                   ("attestationHash" . ,(challenge-attestation-hash ch))
                                   ("counterHash"    . ,(challenge-counter-hash ch))))))))))))
           (lambda (k . a) (list 'error (format #f "compute-replay: ~a" a)))))

        ;; ── disputes ─────────────────────────────────────────────────────
        ;; Spec §5: two kinds. 'non-delivery — the countersign deadline
        ;; passed with no receipt; no receipt by the deadline is no
        ;; payment, and the dispute is that fact's record. 'wrong-result —
        ;; the receipt exists but the result is wrong; PoI replay is
        ;; authoritative, so the door re-runs the challenge and the
        ;; dispute carries its fields (receipt digest, verdict,
        ;; attestation, counter-hash) as the evidence. Either party may
        ;; raise; three sortition-selected citizens review — the hive
        ;; weighs the prover's answer, it never replaces the prover.
        ((compute-dispute identity-key commune-aid claim-id kind-str)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((reg (registry-for commune-aid))
                    (c ($ reg 'claim-of claim-id))
                    (kind (and kind-str (string->symbol kind-str))))
               (cond
                ((not c) (list 'error "compute-dispute: no such claim"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))))
                 (list 'error "compute-dispute: the claim's parties only"))
                ((not (memq kind '(non-delivery wrong-result)))
                 (list 'error "compute-dispute: kind is non-delivery or wrong-result"))
                ;; one dispute per claim — reopening is a new claim's story
                ((not (null? ($ (disputes-for commune-aid) 'by-claim claim-id)))
                 (list 'error "compute-dispute: claim already disputed"))
                ((and (eq? kind 'non-delivery)
                      (or (dispatch-claim-receipt c)
                          (<= (* ((*compute-clock*)) 1000)
                              (dispatch-claim-deadline c))))
                 (list 'error "compute-dispute: receipt landed or deadline still open"))
                ((eq? kind 'wrong-result)
                 (let* ((r (dispatch-claim-receipt c))
                        (env ($ (shelf-for commune-aid) 'get
                                (dispatch-claim-job-id c)))
                        (repro (and r (receipt-repro r))))
                   (cond
                    ((not r) (list 'error "compute-dispute: no receipt to contest"))
                    ((not env) (list 'error "compute-dispute: envelope not on the shelf"))
                    ((not repro) (list 'error "compute-dispute: receipt has no repro spec"))
                    (else
                     (let* ((x (executor-for commune-aid))
                            (result (replay-job env repro
                                                (receipt-output-hash r)
                                                #:executor (if x (%executor-run x)
                                                               %replay-unavailable)))
                            (ch (make-challenge
                                 #:receipt-digest (receipt-digest r)
                                 #:reproduced (replay-verdict result)
                                 #:attestation-hash (receipt-output-hash r)
                                 #:counter-hash (and (eq? (car result) 'ok)
                                                     (list-ref result 2)))))
                       ;; a reproduced verdict fails the dispute's premise —
                       ;; the prover says the receipt stands
                       (if (eq? (replay-verdict result) 'reproduced)
                           (list 'error "compute-dispute: replay reproduced the receipt")
                           (let ((d* (dispute-open->review
                                      (make-dispute
                                       #:id (format #f "dispute-~a-~a" claim-id
                                                    (random 1000000))
                                       #:claim-id claim-id
                                       #:challenger identity-key
                                       #:kind kind #:challenge ch
                                       #:raised-at ((*compute-clock*)))
                                      (review-pool
                                       (list identity-key
                                             (dispatch-claim-lender-did c)
                                             (dispatch-claim-borrower-did c)))
                                      #:exclude
                                      (list identity-key
                                            (dispatch-claim-lender-did c)
                                            (dispatch-claim-borrower-did c)))))
                             ($ (disputes-for commune-aid) 'put! (dispute-id d*) d*)
                             (cons 'ok (dispute->wire d*)))))))))
                (else
                 ;; non-delivery: no replay to run — the absence IS the
                 ;; evidence. The record carries no challenge.
                 (let ((d* (dispute-open->review
                            (make-dispute
                             #:id (format #f "dispute-~a-~a" claim-id
                                          (random 1000000))
                             #:claim-id claim-id
                             #:challenger identity-key
                             #:kind kind #:challenge #f
                             #:raised-at ((*compute-clock*)))
                            (review-pool
                             (list identity-key
                                   (dispatch-claim-lender-did c)
                                   (dispatch-claim-borrower-did c)))
                            #:exclude
                            (list identity-key
                                  (dispatch-claim-lender-did c)
                                  (dispatch-claim-borrower-did c)))))
                   ($ (disputes-for commune-aid) 'put! (dispute-id d*) d*)
                   (cons 'ok (dispute->wire d*)))))))
           (lambda (k . a) (list 'error (format #f "compute-dispute: ~a" a)))))

        ((compute-dispute-verdict identity-key commune-aid dispute-id verdict-str)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((d ($ (disputes-for commune-aid) 'get dispute-id))
                    (verdict (and verdict-str (string->symbol verdict-str))))
               (cond
                ((not d) (list 'error "compute-dispute-verdict: no such dispute"))
                (else
                 (let ((d* (dispute-vote d identity-key verdict)))
                   ($ (disputes-for commune-aid) 'put! dispute-id d*)
                   (cons 'ok (dispute->wire d*)))))))
           (lambda (k . a)
             (list 'error (format #f "compute-dispute-verdict: ~a" a)))))

        ((compute-disputes identity-key commune-aid)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (cons 'ok (map dispute->wire
                           ($ (disputes-for commune-aid) 'all))))
           (lambda (k . a) (list 'error (format #f "compute-disputes: ~a" a)))))

        ;; anyone may prod the clock: a review past the closure window
        ;; lapses closed. The outcome is arithmetic, not authority.
        ((compute-dispute-close identity-key commune-aid dispute-id)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let ((d ($ (disputes-for commune-aid) 'get dispute-id)))
               (cond
                ((not d) (list 'error "compute-dispute-close: no such dispute"))
                (else
                 (let ((d* (dispute-close d #:current-time (*compute-clock*))))
                   (cond
                    ((eq? (dispute-state d*) 'closed)
                     ($ (disputes-for commune-aid) 'put! dispute-id d*)
                     (cons 'ok (dispute->wire d*)))
                    (else (list 'error "compute-dispute-close: still within its window"))))))))
           (lambda (k . a)
             (list 'error (format #f "compute-dispute-close: ~a" a)))))

        ;; ── bindings ─────────────────────────────────────────────────────
        ;; The AccountLink ceremony (spec §1): a did:key binds an account —
        ;; a CAIP-10 payout address, or `keri:<aid>` which IS the AID↔did:key
        ;; binding — dual-signed over the same statement. Either side
        ;; unlinks; the record stays, its status saying who ended it.
        ;; W is the wire alist {didKey, account, purpose, nonce, expiry,
        ;; signerSig, accountSig}. keri:-form binds the caller's own AID —
        ;; the session is already that identity's signature; foreign
        ;; accounts verify through the signature seam (payout re-verifies
        ;; before it pays), and the verdict rides the reply.
        ((compute-bind identity-key commune-aid w)
         (catch #t
           (lambda ()
             (let* ((w (wire-normalize w))
                    (purpose-str (assq-ref w 'purpose))
                    (purpose (and purpose-str (string->symbol purpose-str)))
                    (account (assq-ref w 'account)))
               (cond
                ((not (assq-ref w 'didKey))
                 (list 'error "compute-bind: a didKey is required"))
                ((not account)
                 (list 'error "compute-bind: an account is required"))
                ((and (keri-account? account)
                      (not (equal? account (string-append "keri:" identity-key))))
                 (list 'error "compute-bind: a keri: binding is your own AID only"))
                (else
                 (let* ((link (make-account-link
                               #:did-key (assq-ref w 'didKey)
                               #:scope-aid commune-aid
                               #:account account
                               #:purpose purpose
                               #:nonce (or (assq-ref w 'nonce) "")
                               #:expiry (or (assq-ref w 'expiry) 0)))
                        (b (make-account-binding link
                             (or (assq-ref w 'signerSig) "")
                             (or (assq-ref w 'accountSig) "")))
                        (key (binding-key (account-link-did-key link) account))
                        ;; the verifiers are real: did:key decodes to its
                        ;; own Ed25519 pubkey; keri: rides the session
                        ;; signature path; eip155 is ECDSA recovery. An
                        ;; unreadable account form stays 'unverifiable —
                        ;; the binding we can't read is the binding that
                        ;; doesn't settle.
                        (verdict (verify-binding
                                  b #:verify-signer verify-did-key-sig
                                  #:verify-account
                                  (or (account-verifier-for account)
                                      %sig-unverified))))
                   ($ (binds-for commune-aid) 'put! key b)
                   (cons 'ok `(("key" . ,key) ("verdict" . ,verdict))))))))
           (lambda (k . a) (list 'error (format #f "compute-bind: ~a" a)))))

        ;; Either side unlinks. The caller may end their own keri:-account
        ;; bindings (the session is the account side); signer-side unlink
        ;; arrives with the did:key's signature over the statement — the
        ;; injected verifier speaks, %sig-unverified refuses.
        ((compute-unbind identity-key commune-aid key side)
         (catch #t
           (lambda ()
             (let* ((b ($ (binds-for commune-aid) 'get key))
                    (side-sym (and side (string->symbol side))))
               (cond
                ((not b) (list 'error "compute-unbind: no such binding"))
                ((not (memq side-sym '(signer account)))
                 (list 'error "compute-unbind: side is signer or account"))
                ((and (eq? side-sym 'account)
                      (keri-account?
                       (account-link-account (account-binding-link b)))
                      (not (equal? (account-link-account (account-binding-link b))
                                   (string-append "keri:" identity-key))))
                 (list 'error "compute-unbind: not your binding"))
                (else
                 (let ((b2 (binding-unlink b side-sym)))
                   ($ (binds-for commune-aid) 'put! key b2)
                   (cons 'ok (symbol->string (account-binding-status b2))))))))
           (lambda (k . a) (list 'error (format #f "compute-unbind: ~a" a)))))

        ((compute-bindings identity-key commune-aid)
         (catch #t
           (lambda ()
             (cons 'ok
               (map (lambda (b)
                      (let ((l (account-binding-link b)))
                        `(("didKey" . ,(account-link-did-key l))
                          ("account" . ,(account-link-account l))
                          ("purpose" . ,(symbol->string (account-link-purpose l)))
                          ("nonce" . ,(account-link-nonce l))
                          ("expiry" . ,(account-link-expiry l))
                          ("status" . ,(symbol->string (account-binding-status b))))))
                    ($ (binds-for commune-aid) 'all))))
           (lambda (k . a) (list 'error (format #f "compute-bindings: ~a" a)))))

        ;; ── ring-3 payout ────────────────────────────────────────────────
        ;; The commune's act, gov-cap gated like compute-settle: a
        ;; SettlementStatement's sends, all to the bound treasury Safe and
        ;; nowhere else. The send rail is injected — %payout-unavailable
        ;; refuses, so a commune without a Safe rail answers an error, never
        ;; a phantom payment. W is {statement, bindingKey}.
        ((compute-payout identity-key commune-aid w)
         (let ((sc (scope-for commune-aid)))
           (if (not sc)
               (list 'error "compute-payout: no scope reachable here for that commune")
               (catch #t
                 (lambda ()
                   ($ sc 'mint-gov-cap identity-key)   ; refuses non-governors
                   (let* ((w (wire-normalize w))
                          (s-wire (assq-ref w 'statement))
                          (bkey (assq-ref w 'bindingKey))
                          (b (and bkey ($ (binds-for commune-aid) 'get bkey))))
                     (cond
                      ((not s-wire)
                       (list 'error "compute-payout: a statement is required"))
                      ((not b) (list 'error "compute-payout: no such binding"))
                      ((not (binding-live? b))
                       (list 'error "compute-payout: binding is not live"))
                      (else
                       (let* ((sw (wire-normalize s-wire))
                              (st (make-settlement-statement
                                    #:period (assq-ref sw 'period)
                                    #:entries (or (assq-ref sw 'entries) '())
                                    #:payments (or (assq-ref sw 'payments) '())
                                    #:bridge-sig (assq-ref sw 'bridgeSig)))
                              (rows (execute-payout st b #:send %payout-unavailable)))
                         (cons 'ok (map (lambda (r)
                                          `(("txHash" . ,(payout-row-tx-hash r))
                                            ("asset" . ,(payout-row-asset r))
                                            ("amount" . ,(payout-row-amount r))
                                            ("to" . ,(payout-row-to r))))
                                        rows)))))))
                 (lambda (k . a)
                   (list 'error (format #f "compute-payout: ~a" a)))))))

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
        ;; missing held claimed paid): a matched entry whose claim sits
        ;; under a live or upheld dispute is HELD — money does not move
        ;; on a contested receipt; a dismissed dispute releases it.
        ((compute-settle identity-key commune-aid w)
         (let ((sc (scope-for commune-aid)))
           (if (not sc)
               (list 'error "compute-settle: no scope reachable here for that commune")
               (catch #t
                 (lambda ()
                   ($ sc 'mint-gov-cap identity-key)   ; refuses non-governors
                   (let* ((w (wire-normalize w))
                          (stmt (make-settlement-statement
                                  #:period (assq-ref w 'period)
                                  #:entries (or (assq-ref w 'entries) '())
                                  #:payments (or (assq-ref w 'payments) '())
                                  #:bridge-sig (assq-ref w 'bridgeSig)))
                          (reg (registry-for commune-aid))
                          (result (reconcile-statement
                                    stmt (lambda (d) ($ reg 'receipt-of d))))
                          (disputes ($ (disputes-for commune-aid) 'all))
                          (held? (lambda (e)
                                   (any (lambda (d)
                                          (and (equal? (dispute-claim-id d)
                                                       (statement-entry-bridge-job-id e))
                                               (or (memq (dispute-state d)
                                                         '(open in-review))
                                                   (memq (dispute-outcome d)
                                                         '(upheld lapsed)))))
                                        disputes))))
                     ($ reg 'settle stmt)
                     (apply (lambda (matched missing claimed paid)
                              (let* ((held-m (length (filter held? matched)))
                                     (held-x (length (filter held? missing)))
                                     (held   (+ held-m held-x)))
                                ;; disputed entries leave both columns —
                                ;; a contested claim is neither paid nor
                                ;; simply absent: it is HELD.
                                (cons 'ok (list (- (length matched) held-m)
                                                (- (length missing) held-x)
                                                held claimed paid))))
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
             (let ((e (alist->job-envelope (wire-normalize w))))
               (cons 'ok (job-envelope-bridge-job-id e))))
           (lambda (k . a) (list 'error (format #f "compute-envelope: ~a" a)))))))))
