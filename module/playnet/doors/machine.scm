;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/doors/machine.scm — the machine doors of the governance
;;; service: lane offers, job intents, dispatch claims, receipts, and the
;;; settlement statements a ring-3 bridge lands.
;;;
;;; A fragment of the governance service (playnet doors governance): a
;;; procedure from the actor's context to the doors it serves, composed in
;;; by (playnet boot governance). `with-governance-ctx` binds the actor's
;;; cells and helpers; the commune's ^machine-registry is spawned lazily
;;; per commune and memoized in this closure (matching half of
;;; spec/playnet-compute.md — the solver is not in this path).
;;;
;;; WHOSE ACT. Offers, jobs, claims, preemptions and withdrawals are member
;;; acts: IDENTITY-KEY is the caller's AID, the session forwards it, and
;;; the registry checks the record's own field — only the lender retracts
;;; an offer, only the borrower accepts a dispatch. machine-settle is a
;;; COMMUNE act — a bridge lands a statement through the commune's own
;;; governance, gov-cap gated like accept-reimbursement.

(define-module (playnet doors machine)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins abstract-types)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet machine specs)
  #:use-module (playnet machine receipt)
  #:use-module (playnet machine registry)
  #:use-module (playnet machine settlement)
  #:use-module (playnet machine envelope)
  #:use-module (playnet machine replay)
  #:use-module (playnet machine dispute)
  #:use-module (playnet machine challenge)
  #:use-module (playnet machine binding)
  #:use-module (playnet machine binding-verifiers)
  #:use-module (playnet machine payout)
  #:use-module (playnet machine swarm)
  #:use-module (playnet machine providers)
  #:use-module (playnet machine executors)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:use-module ((playnet keri citizen-sig) #:select (verify-said-signature))
  #:use-module ((playnet utils time) #:select (current-epoch-seconds))
  #:use-module ((playnet delegates) #:select (make-opa-delegate))
  #:use-module (json)
  #:export (governance-machine-doors *machine-clock* *machine-send-rail*
            *machine-authz* commune-act-allowed?))


;;; *machine-clock* — the "now" the compute doors read, as a parameter so a
;;; test can walk a dispute timeline without waiting days. Defaults to the
;;; wall clock; nothing outside a test rebinds it.
(define *machine-clock* (make-parameter current-epoch-seconds))

;;; *machine-send-rail* — the treasury payout rail, parameterized like the
;;; clock. Production reads %payout-unavailable (fail closed — a commune
;;; without a Safe rail answers an error, never a phantom payment); a test
;;; injects its (lambda (to amount asset) → tx-hash).
(define *machine-send-rail* (make-parameter %payout-unavailable))

;;; *machine-authz* — the commune-act policy engine, an OPA delegate or #f.
;;; When set, machine-settle/machine-payout consult
;;; playnet/doors/machine: an answered allow:#f refuses even after the
;;; local gov-cap check passes; 'unavailable falls through to the local
;;; gate (a commune runs its doors without a policy engine — OPA is an
;;; augmentation, not a dependency). Deployed by
;;; (make-opa-delegate (%env-transport "PLAYNET_OPA_URL")).
(define *machine-authz* (make-parameter #f))

(define (json-ref parsed key)
  "KEY lookup in a guile-json alist, string and symbol keys both."
  (cond ((assoc key parsed) => cdr)
        ((assoc (string->symbol key) parsed) => cdr)
        (else #f)))

(define (commune-act-allowed? identity-key commune-aid action)
  "Consult *machine-authz* for ACTION on COMMUNE-AID by IDENTITY-KEY.
   #t when unset or the engine is 'unavailable; the engine's own allow
   field decides otherwise."
  (let ((d (*machine-authz*)))
    (or (not d)
        (let ((a (d "playnet/doors/machine"
                    `(("citizen" . ,identity-key)
                      ("action" . ,action)
                      ("commune" . ,commune-aid)
                      ("door" . "machine-treasury")))))
          (if (eq? a 'unavailable)
              #t
              (let* ((body (and (pair? a) (cdr a)))
                     (parsed (and (string? body)
                                  (catch #t
                                    (lambda () (json-string->scm body))
                                    (lambda _ #f))))
                     (result (and parsed (json-ref parsed "result"))))
                (and (pair? result)
                     (json-ref result "allow")
                     #t)))))))

(define (governance-machine-doors ctx)
  ;; one ^machine-registry per commune, spawned on first touch
  (let ((registries (make-hash-table)))
    (with-governance-ctx ctx

      (define (registry-for commune-aid)
        (or (hash-ref registries commune-aid)
            (let ((r (spawn ^machine-registry (hashmap) (hashmap)
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

      ;; the challenge shelf — <store-challenge> records by challenge id,
      ;; the storage kind's counterpart to replay: the proof the node
      ;; still holds the bytes.
      (define (challenges-for commune-aid)
        (let ((k (string-append "challenge:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-challenge-store)))
                (hash-set! registries k s)
                s))))

      ;; the signal shelf — per-claim ordered blobs, the rendezvous a
      ;; browser pair needs to relay because neither end can listen.
      (define (signals-for commune-aid)
        (let ((k (string-append "signal:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-signal-store)))
                (hash-set! registries k s)
                s))))

      ;; the swarm shelf — the coordination record beside the claims:
      ;; which jobs compose a fan-out. The bus itself reuses the signal
      ;; shelf under "swarm:<id>"; this shelf is just the membership book.
      (define (swarms-for commune-aid)
        (let ((k (string-append "swarm:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-swarm-store)))
                (hash-set! registries k s)
                s))))

      ;; the bus's authorization: the swarm's borrower, or a lender
      ;; holding a live claim on one of the swarm's jobs — a settled
      ;; claim's holder has no more to say than a settled claim's signals.
      (define (swarm-member? swarm commune-aid caller)
        (or (equal? caller (swarm-borrower-did swarm))
            (let ((job-ids (swarm-job-ids swarm))
                  (claims ($ (registry-for commune-aid) 'claims commune-aid)))
              (any (lambda (c)
                     (and (member (dispatch-claim-job-id c) job-ids)
                          (equal? caller (dispatch-claim-lender-did c))
                          (memq (dispatch-claim-state c)
                                '(claimed accepted))))
                   claims))))

      ;; the bridge ledger — which jobs crossed to which provider network
      ;; and what came back; the settlement edge's payments name rows here.
      (define (bridges-for commune-aid)
        (let ((k (string-append "bridge:" commune-aid)))
          (or (hash-ref registries k)
              (let ((s (spawn-bridge-store)))
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
      ;; A browser-side vector crosses CapTP as a <user-record> envelope and
      ;; the session's unmarshall unwraps ONE level — arriving here still a
      ;; <tagged 'vec> (and dotted pairs likewise as <tagged 'pair>); reduce
      ;; them the rest of the way or they store as opaque records (found
      ;; live: an envelope's "caps" landed as a record and every read of it
      ;; failed the JSON write).
      (define (wire-normalize v)
        (cond
         ((and (tagged? v) (eq? 'vec (tagged-label v)))
          (map wire-normalize (tagged-data v)))
         ((and (tagged? v) (eq? 'pair (tagged-label v)))
          (let ((d (tagged-data v)))
            (cons (wire-normalize (car d)) (wire-normalize (cadr d)))))
         ((vector? v) (map wire-normalize (vector->list v)))
         ((and (list? v) (not (null? v))
               (every (lambda (e) (and (pair? e) (string? (car e)))) v))
          (map (lambda (e) (cons (string->symbol (car e))
                                 (wire-normalize (cdr e))))
               v))
         ((list? v) (map wire-normalize v))
         ((pair? v) (cons (car v) (wire-normalize (cdr v))))
         (else v)))

      ;; a resources/needs alist over the wire arrives symbol-keyed
      ;; ({"storageGB":4} → ((storageGB . 4))); the record's contract is
      ;; string keys. One local lookup both directions.
      (define (res-normalize v)
        (map (lambda (p)
               (cons (if (symbol? (car p)) (symbol->string (car p)) (car p))
                     (cdr p)))
             (wire-normalize (or v '()))))

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
          ("usageUnit" . ,(lane-offer-usage-unit o))
          ;; an alist of string-keyed pairs crosses as a JSON object —
          ;; {"storageGB":4}, symmetric with res-normalize on the way in
          ("resources" . ,(lane-offer-resources o))))

      (define (job-row j)
        `(("id" . ,(machine-job-id j))
          ("borrower" . ,(machine-job-borrower-did j))
          ("commune" . ,(machine-job-commune-aid j))
          ("taskClass" . ,(symbol->string (machine-job-task-class j)))
          ("lane" . ,(machine-job-lane j))
          ("reproMode" . ,(symbol->string (machine-job-repro-mode j)))
          ("inputHash" . ,(machine-job-input-hash j))
          ("envelopeHash" . ,(machine-job-envelope-hash j))
          ("ring" . ,(machine-job-ring j))
          ("state" . ,(symbol->string (machine-job-state j)))
          ("specId" . ,(machine-job-spec-id j))
          ("needs" . ,(machine-job-needs j))))

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

      ;; a store challenge over the wire — the nonce travels so the node can
      ;; compute sha256(nonce ∥ held bytes); expected/answer stay private to
      ;; the record, the row carries only whether they're set.
      (define (challenge-row c now)
        `(("id" . ,(store-challenge-id c))
          ("claimId" . ,(store-challenge-claim-id c))
          ("issuer" . ,(store-challenge-issuer c))
          ("nonce" . ,(store-challenge-nonce c))
          ("state" . ,(symbol->string (store-challenge-state c)))
          ("expected" . ,(and (store-challenge-expected c) #t))
          ("answer" . ,(and (store-challenge-answer c) #t))
          ("issuedAt" . ,(store-challenge-issued-at c))
          ("deadline" . ,(store-challenge-deadline c))
          ("expired" . ,(challenge-expired? c now))
          ("verdict" . ,(and (store-challenge-verdict-field c)
                             (symbol->string (store-challenge-verdict-field c))))))

      ;; a receipt over the wire is the JSON object the lender's node
      ;; produced — symbol-keyed alist here, the same field names the
      ;; canonical digest hashes. usage/repro are alist sub-objects.
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

      ;; digest first, signature where resolvable — a did:key lender's
      ;; key travels inside the DID, an AID lender's resolves through the
      ;; KEL/device path; the answer is 'verified | 'unverifiable | 'bad,
      ;; never a silent pass.
      (define (sig-verdict r)
        (let ((d (receipt-digest r))
              (sig (receipt-lender-sig r))
              (lender (receipt-lender-did r)))
          (cond
           ((not (and (string? sig) (string? lender))) 'unverifiable)
           ;; a did:key lender's key is the DID itself — no resolver needed
           ((string-prefix? "did:key:" lender)
            (if (verify-did-key-sig lender d sig) 'verified 'bad))
           ((verify-said-signature d sig lender) 'verified)
           (else 'bad))))

      (declared-doors governance

        ;; ── offers ──────────────────────────────────────────────────────
        ;; IDENTITY-KEY offers its machines: LANE the lane name, CLASSES a
        ;; comma list of task classes over the wire, HEADROOM units/second
        ;; kept for inner-ring work, REPRO the lender's own replay claim.
        ((machine-offer identity-key commune-aid lane classes headroom repro . opts)
         (let ((classes (filter-map (lambda (s)
                                     (let ((sym (string->symbol (string-trim-both s))))
                                       (and (task-class? sym) sym)))
                                   (if (string? classes)
                                       (string-split classes #\,)
                                       classes)))
               (usage-unit (or (opt-ref opts 'usageUnit #f) "seconds"))
               (resources (res-normalize (opt-ref opts 'resources '())))
               (repro-sym (if (symbol? repro) repro (string->symbol repro))))
           (catch #t
             (lambda ()
               (when (null? classes)
                 (error "machine-offer: no valid task classes"))
               (cons 'ok ($ (registry-for commune-aid) 'offer
                            identity-key commune-aid lane classes
                            headroom repro-sym usage-unit resources)))
             (lambda (k . a) (list 'error (format #f "machine-offer: ~a" a))))))

        ((machine-retract identity-key commune-aid offer-id)
         (catch #t
           (lambda ()
             ($ (registry-for commune-aid) 'retract offer-id identity-key)
             (cons 'ok #t))
           (lambda (k . a) (list 'error (format #f "machine-retract: ~a" a)))))

        ((machine-offers commune-aid)
         (cons 'ok (map offer-row
                        ($ (registry-for commune-aid) 'offers commune-aid))))

        ;; ── jobs ────────────────────────────────────────────────────────
        ;; IDENTITY-KEY submits: the intent side. RING defaults 1 — the job
        ;; enters at its own commune and walks outward only by preemption.
        ((machine-submit identity-key commune-aid task-class lane repro input-hash . opts)
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
                               (opt-ref opts 'specId #f)
                               (res-normalize (opt-ref opts 'needs '())))))
               (when parsed
                 ($ (shelf-for commune-aid) 'put! job-id parsed))
               (cons 'ok job-id)))
           (lambda (k . a) (list 'error (format #f "machine-submit: ~a" a)))))

        ((machine-withdraw identity-key commune-aid job-id)
         (catch #t
           (lambda ()
             ($ (registry-for commune-aid) 'withdraw job-id identity-key)
             (cons 'ok #t))
           (lambda (k . a) (list 'error (format #f "machine-withdraw: ~a" a)))))

        ((machine-jobs commune-aid)
         (cons 'ok (map job-row
                        ($ (registry-for commune-aid) 'jobs commune-aid))))

        ((machine-match commune-aid job-id)
         (cons 'ok (map offer-row
                        ($ (registry-for commune-aid) 'match job-id))))

        ;; ── claims ──────────────────────────────────────────────────────
        ;; IDENTITY-KEY (a lender) takes the job under its own offer;
        ;; DEADLINE-MS is the countersign-by time — the spec's no-receipt-
        ;; no-payment window. Default 72h, the challenge window's length.
        ((machine-claim identity-key commune-aid job-id offer-id . opts)
         (catch #t
           (lambda ()
             (let ((deadline (or (opt-ref opts 'deadline #f)
                                 (* (+ ((*machine-clock*))
                                       (* 72 3600)) 1000))))
               (cons 'ok ($ (registry-for commune-aid) 'claim
                            identity-key job-id offer-id deadline))))
           (lambda (k . a) (list 'error (format #f "machine-claim: ~a" a)))))

        ((machine-accept identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             ($ (registry-for commune-aid) 'accept claim-id identity-key)
             (cons 'ok #t))
           (lambda (k . a) (list 'error (format #f "machine-accept: ~a" a)))))

        ((machine-preempt identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (let ((c ($ (registry-for commune-aid) 'claim-of claim-id)))
               (cond
                ((not c) (error "machine-preempt: no such claim"))
                ;; the lender preempts its own claim; a commune governor
                ;; preempts any (inner work reclaiming capacity)
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))
                          (governor? identity-key)))
                 (error "machine-preempt: lender, borrower or governor only"))
                (else ($ (registry-for commune-aid) 'preempt claim-id)
                      (cons 'ok #t)))))
           (lambda (k . a) (list 'error (format #f "machine-preempt: ~a" a)))))

        ((machine-claims commune-aid)
         (cons 'ok (map claim-row
                        ($ (registry-for commune-aid) 'claims commune-aid))))

        ;; IDENTITY-KEY (the claim's lender) fetches the envelope it's meant
        ;; to run. Borrowers already have their own envelope; anyone else
        ;; gets refused — the envelope is the job's payload, not a broadcast.
        ((machine-fetch-envelope identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (let ((c ($ (registry-for commune-aid) 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "machine-fetch-envelope: no such claim"))
                ((not (equal? identity-key (dispatch-claim-lender-did c)))
                 (list 'error "machine-fetch-envelope: the claim's lender only"))
                ((not (memq (dispatch-claim-state c) '(claimed accepted)))
                 (list 'error "machine-fetch-envelope: claim no longer live"))
                (else
                 (let ((env ($ (shelf-for commune-aid) 'get
                               (dispatch-claim-job-id c))))
                   (if env
                       (cons 'ok (job-envelope->alist env))
                       (list 'error "machine-fetch-envelope: not on the shelf")))))))
           (lambda (k . a) (list 'error (format #f "machine-fetch-envelope: ~a" a)))))

        ;; ── replay ───────────────────────────────────────────────────────
        ;; PoI replay is authoritative: the borrower, the lender, or the
        ;; commune's governance asks the question again and the replay's
        ;; counter-hash is the evidence. The executor arrives injected —
        ;; absent one the door answers 'no-executor, fail-closed, and a
        ;; 'none job answers 'unverifiable (never a verdict against the
        ;; lender). The reply carries the challenge fields: receipt digest,
        ;; reproduced, the claimed attestation hash, the replay's counter.
        ((machine-replay identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (let* ((reg (registry-for commune-aid))
                    (c ($ reg 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "machine-replay: no such claim"))
                ((not (dispatch-claim-receipt c))
                 (list 'error "machine-replay: claim has no receipt yet"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))))
                 (list 'error "machine-replay: the claim's parties only"))
                (else
                 (let* ((r (dispatch-claim-receipt c))
                        (env ($ (shelf-for commune-aid) 'get
                                (dispatch-claim-job-id c)))
                        (repro (receipt-repro r)))
                   (cond
                    ((not env)
                     (list 'error "machine-replay: envelope not on the shelf"))
                    ((not repro)
                     (list 'error "machine-replay: receipt has no repro spec"))
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
           (lambda (k . a) (list 'error (format #f "machine-replay: ~a" a)))))

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
        ((machine-dispute identity-key commune-aid claim-id kind-str)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((reg (registry-for commune-aid))
                    (c ($ reg 'claim-of claim-id))
                    (kind (and kind-str (string->symbol kind-str))))
               (cond
                ((not c) (list 'error "machine-dispute: no such claim"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))))
                 (list 'error "machine-dispute: the claim's parties only"))
                ((not (memq kind '(non-delivery wrong-result)))
                 (list 'error "machine-dispute: kind is non-delivery or wrong-result"))
                ;; one dispute per claim — reopening is a new claim's story
                ((not (null? ($ (disputes-for commune-aid) 'by-claim claim-id)))
                 (list 'error "machine-dispute: claim already disputed"))
                ((and (eq? kind 'non-delivery)
                      (or (dispatch-claim-receipt c)
                          (<= (* ((*machine-clock*)) 1000)
                              (dispatch-claim-deadline c))))
                 (list 'error "machine-dispute: receipt landed or deadline still open"))
                ((eq? kind 'wrong-result)
                 (let* ((r (dispatch-claim-receipt c))
                        (env ($ (shelf-for commune-aid) 'get
                                (dispatch-claim-job-id c)))
                        (repro (and r (receipt-repro r))))
                   (cond
                    ((not r) (list 'error "machine-dispute: no receipt to contest"))
                    ((not env) (list 'error "machine-dispute: envelope not on the shelf"))
                    ((not repro) (list 'error "machine-dispute: receipt has no repro spec"))
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
                           (list 'error "machine-dispute: replay reproduced the receipt")
                           (let ((d* (dispute-open->review
                                      (make-dispute
                                       #:id (format #f "dispute-~a-~a" claim-id
                                                    (random 1000000))
                                       #:claim-id claim-id
                                       #:challenger identity-key
                                       #:kind kind #:challenge ch
                                       #:raised-at ((*machine-clock*)))
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
                             #:raised-at ((*machine-clock*)))
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
           (lambda (k . a) (list 'error (format #f "machine-dispute: ~a" a)))))

        ((machine-dispute-verdict identity-key commune-aid dispute-id verdict-str)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((d ($ (disputes-for commune-aid) 'get dispute-id))
                    (verdict (and verdict-str (string->symbol verdict-str))))
               (cond
                ((not d) (list 'error "machine-dispute-verdict: no such dispute"))
                (else
                 (let ((d* (dispute-vote d identity-key verdict)))
                   ($ (disputes-for commune-aid) 'put! dispute-id d*)
                   (cons 'ok (dispute->wire d*)))))))
           (lambda (k . a)
             (list 'error (format #f "machine-dispute-verdict: ~a" a)))))

        ((machine-disputes identity-key commune-aid)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (cons 'ok (map dispute->wire
                           ($ (disputes-for commune-aid) 'all))))
           (lambda (k . a) (list 'error (format #f "machine-disputes: ~a" a)))))

        ;; anyone may prod the clock: a review past the closure window
        ;; lapses closed. The outcome is arithmetic, not authority.
        ((machine-dispute-close identity-key commune-aid dispute-id)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let ((d ($ (disputes-for commune-aid) 'get dispute-id)))
               (cond
                ((not d) (list 'error "machine-dispute-close: no such dispute"))
                (else
                 (let ((d* (dispute-close d #:current-time (*machine-clock*))))
                   (cond
                    ((eq? (dispute-state d*) 'closed)
                     ($ (disputes-for commune-aid) 'put! dispute-id d*)
                     (cons 'ok (dispute->wire d*)))
                    (else (list 'error "machine-dispute-close: still within its window"))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-dispute-close: ~a" a)))))

        ;; ── storage challenges ───────────────────────────────────────────
        ;; machine/challenge.scm — the store kind's replay: 'exact by
        ;; construction, the answer a pure function of a fresh nonce and
        ;; the committed bytes, answer = sha256(nonce ∥ content). The
        ;; ISSUER is the claim's borrower (the content holder) or a
        ;; governor; the ANSWERER is the claim's lender — the node being
        ;; probed; the VERIFIER is the issuer again. A challenge binds to
        ;; a 'storage job's committed inputHash, so an issuer cannot
        ;; frame an honest node: expected is checked against the same
        ;; content hash the job committed. Fail-closed like replay: no
        ;; claim, no challenge; the wrong party, a refusal.
        ((machine-challenge identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((reg (registry-for commune-aid))
                    (c ($ reg 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "machine-challenge: no such claim"))
                ((not (or (equal? identity-key (dispatch-claim-borrower-did c))
                          (governor? identity-key)))
                 (list 'error "machine-challenge: borrower or governor only"))
                (else
                 (let ((j ($ reg 'job-of (dispatch-claim-job-id c))))
                   (cond
                    ((not (eq? (machine-job-task-class j) 'storage))
                     (list 'error "machine-challenge: a storage claim only"))
                    ((not (memq (dispatch-claim-state c) '(claimed accepted)))
                     (list 'error "machine-challenge: claim no longer live"))
                    (else
                     (let ((ch (make-store-challenge
                                #:id (format #f "chal-~a-~a" claim-id
                                             (random 1000000))
                                #:claim-id claim-id #:issuer identity-key
                                #:nonce (challenge-nonce)
                                #:issued-at ((*machine-clock*)))))
                       ($ (challenges-for commune-aid)
                          'put! (store-challenge-id ch) ch)
                       (cons 'ok (challenge-row ch ((*machine-clock*))))))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-challenge: ~a" a)))))

        ;; the lender's half: sha256(nonce ∥ held bytes), posted back. Only
        ;; the claim's lender may answer — an answer is the node's word on
        ;; itself. Silence past the deadline reads 'failed; a late answer
        ;; lands on a closed-by-time record and is refused.
        ((machine-challenge-answer identity-key commune-aid challenge-id answer)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((shelf (challenges-for commune-aid))
                    (ch ($ shelf 'get challenge-id))
                    (now ((*machine-clock*))))
               (cond
                ((not ch) (list 'error "machine-challenge-answer: no such challenge"))
                ((challenge-expired? ch now)
                 (list 'error "machine-challenge-answer: window has closed"))
                (else
                 (let ((c ($ (registry-for commune-aid)
                             'claim-of (store-challenge-claim-id ch))))
                   (cond
                    ((not (equal? identity-key (dispatch-claim-lender-did c)))
                     (list 'error "machine-challenge-answer: the claim's lender only"))
                    ((not (and (string? answer) (= (string-length answer) 64)))
                     (list 'error "machine-challenge-answer: answer is a sha256 hex"))
                    (else
                     (let ((ch* (challenge-answer! ch answer)))
                       ($ shelf 'put! challenge-id ch*)
                       (cons 'ok (challenge-row ch* now))))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-challenge-answer: ~a" a)))))

        ;; the issuer closes: EXPECTED is sha256(nonce ∥ content) over the
        ;; bytes IT holds; CONTENT-HASH is sha256(those bytes) and must
        ;; equal the job's inputHash — the binding that keeps expected
        ;; honest. Verdict lands on the record: 'reproduced | 'mismatch |
        ;; 'failed (no answer).
        ((machine-challenge-verify identity-key commune-aid challenge-id
                                   expected content-hash)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((shelf (challenges-for commune-aid))
                    (ch ($ shelf 'get challenge-id)))
               (cond
                ((not ch) (list 'error "machine-challenge-verify: no such challenge"))
                ((not (equal? identity-key (store-challenge-issuer ch)))
                 (list 'error "machine-challenge-verify: the issuer only"))
                ((eq? (store-challenge-state ch) 'closed)
                 (list 'error "machine-challenge-verify: already closed"))
                (else
                 (let* ((c ($ (registry-for commune-aid)
                              'claim-of (store-challenge-claim-id ch)))
                        (j ($ (registry-for commune-aid)
                              'job-of (dispatch-claim-job-id c))))
                   (if (not (equal? content-hash (machine-job-input-hash j)))
                       (list 'error "machine-challenge-verify: content-hash is not the job's committed inputHash")
                       (let ((ch* (challenge-verify! ch expected)))
                         ($ shelf 'put! challenge-id ch*)
                         (cons 'ok (challenge-row ch* ((*machine-clock*)))))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-challenge-verify: ~a" a)))))

        ;; the node's poll surface — challenges the claim's lender must
        ;; answer, or the issuer may audit. Borrower, lender, governor.
        ((machine-challenges identity-key commune-aid claim-id)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((c ($ (registry-for commune-aid) 'claim-of claim-id))
                    (now ((*machine-clock*))))
               (cond
                ((not c) (list 'error "machine-challenges: no such claim"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))
                          (governor? identity-key)))
                 (list 'error "machine-challenges: the claim's parties only"))
                (else
                 (cons 'ok
                   (map (lambda (ch) (challenge-row ch now))
                        ($ (challenges-for commune-aid) 'by-claim claim-id)))))))
           (lambda (k . a)
             (list 'error (format #f "machine-challenges: ~a" a)))))

        ;; ── relay signaling ──────────────────────────────────────────────
        ;; The relay kind's rendezvous: neither browser end can listen, so
        ;; the claim itself is the mailbox — SDP offers/answers, ICE
        ;; candidates, the handshake the two ends exchange through the
        ;; shelf. Only the claim's parties post or read, and only while the
        ;; claim is live: a settled claim's signals are a dead letter.
        ;; A signal row crosses as (seq . ((from . did) (at . epoch)
        ;; (body . v))) — the shelf assigns seq; the door stamps from/at,
        ;; so a body can neither spoof its sender nor predate its post.
        ((machine-signal identity-key commune-aid claim-id body)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let ((c ($ (registry-for commune-aid) 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "machine-signal: no such claim"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))))
                 (list 'error "machine-signal: the claim's parties only"))
                ((not (memq (dispatch-claim-state c) '(claimed accepted)))
                 (list 'error "machine-signal: claim no longer live"))
                (else
                 (let ((seq ($ (signals-for commune-aid) 'append! claim-id
                               `((from . ,identity-key)
                                 (at . ,((*machine-clock*)))
                                 (body . ,(wire-normalize body))))))
                   (cons 'ok seq))))))
           (lambda (k . a)
             (list 'error (format #f "machine-signal: ~a" a)))))

        ;; the counterparty's read — rows strictly after SEQ (0 starts at
        ;; the beginning). Borrower, lender, governor may listen; a
        ;; stranger's claim signals are not their business.
        ((machine-signals identity-key commune-aid claim-id . opts)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let ((c ($ (registry-for commune-aid) 'claim-of claim-id)))
               (cond
                ((not c) (list 'error "machine-signals: no such claim"))
                ((not (or (equal? identity-key (dispatch-claim-lender-did c))
                          (equal? identity-key (dispatch-claim-borrower-did c))
                          (governor? identity-key)))
                 (list 'error "machine-signals: the claim's parties only"))
                (else
                 (cons 'ok
                   (map (lambda (r)
                          `(("seq" . ,(car r))
                            ("from" . ,(assq-ref (cdr r) 'from))
                            ("at" . ,(assq-ref (cdr r) 'at))
                            ("body" . ,(assq-ref (cdr r) 'body))))
                        ($ (signals-for commune-aid) 'after claim-id
                           (or (opt-ref opts 'after 0) 0))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-signals: ~a" a)))))

        ;; ── swarms ────────────────────────────────────────────────────
        ;; A swarm is the coordination record over N shard claims — one
        ;; job per shard (the claim stays the accounting atom), the record
        ;; binding the fan-out's shape. machine-swarm-open is a BORROWER
        ;; act: the caller must own every job it groups. The signal bus is
        ;; the N-party rendezvous: only the borrower or a lender holding a
        ;; live claim on a swarm job may post or read — the same
        ;; stamped-from/at, same dead-letter rule as a claim's log.
        ((machine-swarm-open identity-key commune-aid swarm-id job-ids)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((reg (registry-for commune-aid))
                    (jobs (map (lambda (jid) ($ reg 'job-of jid))
                               (or job-ids '()))))
               (cond
                ((not (and (pair? jobs) (every (lambda (j) j) jobs)))
                 (list 'error "machine-swarm-open: every shard job must exist"))
                ((not (every (lambda (j)
                               (and (equal? (machine-job-commune-aid j) commune-aid)
                                    (equal? (machine-job-borrower-did j) identity-key)))
                             jobs))
                 (list 'error "machine-swarm-open: the caller's own jobs only"))
                (else
                 (cons 'ok (swarm->list
                            ($ (swarms-for commune-aid) 'open!
                               (make-swarm #:id swarm-id
                                           #:borrower-did identity-key
                                           #:commune-aid commune-aid
                                           #:job-ids job-ids
                                           #:created-at ((*machine-clock*))))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-swarm-open: ~a" a)))))

        ;; the member's read — the fan-out's shape plus each job's state,
        ;; so a stage learns whether its siblings are claimed yet.
        ((machine-swarm-of identity-key commune-aid swarm-id)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((s ($ (swarms-for commune-aid) 'of swarm-id))
                    (reg (registry-for commune-aid)))
               (cond
                ((not s) (list 'error "machine-swarm-of: no such swarm"))
                ((not (swarm-member? s commune-aid identity-key))
                 (list 'error "machine-swarm-of: the swarm's members only"))
                (else
                 (cons 'ok
                   (list (cons "swarm" (swarm->list s))
                         (cons "jobs"
                           (map (lambda (jid)
                                  (let ((j ($ reg 'job-of jid)))
                                    `(("jobId" . ,jid)
                                      ("state" . ,(and j (symbol->string
                                                          (machine-job-state j)))))))
                                (swarm-job-ids s)))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-swarm-of: ~a" a)))))

        ((machine-swarm-signal identity-key commune-aid swarm-id body)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let ((s ($ (swarms-for commune-aid) 'of swarm-id)))
               (cond
                ((not s) (list 'error "machine-swarm-signal: no such swarm"))
                ((not (swarm-member? s commune-aid identity-key))
                 (list 'error "machine-swarm-signal: the swarm's members only"))
                (else
                 (let ((seq ($ (signals-for commune-aid) 'append!
                               (swarm-bus-key swarm-id)
                               `((from . ,identity-key)
                                 (at . ,((*machine-clock*)))
                                 (body . ,(wire-normalize body))))))
                   (cons 'ok seq))))))
           (lambda (k . a)
             (list 'error (format #f "machine-swarm-signal: ~a" a)))))

        ((machine-swarm-signals identity-key commune-aid swarm-id . opts)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let ((s ($ (swarms-for commune-aid) 'of swarm-id)))
               (cond
                ((not s) (list 'error "machine-swarm-signals: no such swarm"))
                ((not (swarm-member? s commune-aid identity-key))
                 (list 'error "machine-swarm-signals: the swarm's members only"))
                (else
                 (cons 'ok
                   (map (lambda (r)
                          `(("seq" . ,(car r))
                            ("from" . ,(assq-ref (cdr r) 'from))
                            ("at" . ,(assq-ref (cdr r) 'at))
                            ("body" . ,(assq-ref (cdr r) 'body))))
                        ($ (signals-for commune-aid) 'after
                           (swarm-bus-key swarm-id)
                           (or (opt-ref opts 'after 0) 0))))))))
           (lambda (k . a)
             (list 'error (format #f "machine-swarm-signals: ~a" a)))))

        ;; ── the bridge — ring 3's legs ───────────────────────────────
        ;; Only the job's borrower sends it out, only a job that declared
        ;; ring:3 may cross (INTERNAL/SECRET work never carries one), only
        ;; while it is still 'open — and only when the commune's own 'match
        ;; returns nothing: OUR capacity always wins, the provider is the
        ;; fallback, never the preferred route. The provider gets the
        ;; envelope's refs and caps — credentials and prices never ride.
        ((machine-bridge-submit identity-key commune-aid job-id provider-name)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((reg (registry-for commune-aid))
                    (j ($ reg 'job-of job-id))
                    (env (and j ($ (shelf-for commune-aid) 'get job-id))))
               (cond
                ((not j) (list 'error "machine-bridge-submit: no such job"))
                ((not (equal? identity-key (machine-job-borrower-did j)))
                 (list 'error "machine-bridge-submit: the borrower's job only"))
                ((not (eq? (machine-job-state j) 'open))
                 (list 'error "machine-bridge-submit: only an open job crosses"))
                ((< (machine-job-ring j) 3)
                 (list 'error "machine-bridge-submit: the job's ring forbids ring-3 routing"))
                ((not env)
                 (list 'error "machine-bridge-submit: envelope not on the shelf"))
                ((not (provider-serves? provider-name (job-envelope-kind env)))
                 (list 'error "machine-bridge-submit: provider doesn't serve this kind"))
                ;; local-first: an inner offer is capacity we already own —
                ;; claim it there rather than paying the outside for it
                ((pair? ($ reg 'match job-id))
                 (list 'error "machine-bridge-submit: inner rings have capacity"))
                (else
                 (let* ((t (or (provider-transport provider-name)
                               %provider-unavailable))
                        (result (provider-call provider-name t env))
                        (a (make-bridge-attempt
                            #:id (format #f "br-~a-~a" job-id (random 1000000))
                            #:job-id job-id
                            #:provider (if (symbol? provider-name) provider-name
                                           (string->symbol provider-name))
                            #:ref (assoc-ref result "ref")
                            #:output-hash (assoc-ref result "outputHash")
                            #:state 'answered
                            #:at ((*machine-clock*)))))
                   ($ (bridges-for commune-aid) 'put! a)
                   (cons 'ok (bridge-attempt->list a)))))))
           (lambda (k . a)
             (list 'error (format #f "machine-bridge-submit: ~a" a)))))

        ((machine-bridge-attempts identity-key commune-aid job-id)
         (catch #t
           (lambda ()
             (ensure-citizen identity-key)
             (let* ((reg (registry-for commune-aid))
                    (j ($ reg 'job-of job-id)))
               (cond
                ((not j) (list 'error "machine-bridge-attempts: no such job"))
                ((not (equal? identity-key (machine-job-borrower-did j)))
                 (list 'error "machine-bridge-attempts: the borrower's job only"))
                (else
                 (cons 'ok (map bridge-attempt->list
                                ($ (bridges-for commune-aid) 'by-job job-id)))))))
           (lambda (k . a)
             (list 'error (format #f "machine-bridge-attempts: ~a" a)))))

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
        ((machine-bind identity-key commune-aid w)
         (catch #t
           (lambda ()
             (let* ((w (wire-normalize w))
                    (purpose-str (assq-ref w 'purpose))
                    (purpose (and purpose-str (string->symbol purpose-str)))
                    (account (assq-ref w 'account)))
               (cond
                ((not (assq-ref w 'didKey))
                 (list 'error "machine-bind: a didKey is required"))
                ((not account)
                 (list 'error "machine-bind: an account is required"))
                ((and (keri-account? account)
                      (not (equal? account (string-append "keri:" identity-key))))
                 (list 'error "machine-bind: a keri: binding is your own AID only"))
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
           (lambda (k . a) (list 'error (format #f "machine-bind: ~a" a)))))

        ;; Either side unlinks. The caller may end their own keri:-account
        ;; bindings (the session is the account side); signer-side unlink
        ;; arrives with the did:key's signature over the statement — the
        ;; injected verifier speaks, %sig-unverified refuses.
        ((machine-unbind identity-key commune-aid key side)
         (catch #t
           (lambda ()
             (let* ((b ($ (binds-for commune-aid) 'get key))
                    (side-sym (and side (string->symbol side))))
               (cond
                ((not b) (list 'error "machine-unbind: no such binding"))
                ((not (memq side-sym '(signer account)))
                 (list 'error "machine-unbind: side is signer or account"))
                ((and (eq? side-sym 'account)
                      (keri-account?
                       (account-link-account (account-binding-link b)))
                      (not (equal? (account-link-account (account-binding-link b))
                                   (string-append "keri:" identity-key))))
                 (list 'error "machine-unbind: not your binding"))
                (else
                 (let ((b2 (binding-unlink b side-sym)))
                   ($ (binds-for commune-aid) 'put! key b2)
                   (cons 'ok (symbol->string (account-binding-status b2))))))))
           (lambda (k . a) (list 'error (format #f "machine-unbind: ~a" a)))))

        ((machine-bindings identity-key commune-aid)
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
           (lambda (k . a) (list 'error (format #f "machine-bindings: ~a" a)))))

        ;; ── ring-3 payout ────────────────────────────────────────────────
        ;; The commune's act, gov-cap gated like machine-settle: a
        ;; SettlementStatement's sends, all to the bound treasury Safe and
        ;; nowhere else. The send rail is injected — %payout-unavailable
        ;; refuses, so a commune without a Safe rail answers an error, never
        ;; a phantom payment. W is {statement, bindingKey}.
        ((machine-payout identity-key commune-aid w)
         (let ((sc (scope-for commune-aid)))
           (if (not sc)
               (list 'error "machine-payout: no scope reachable here for that commune")
               (catch #t
                 (lambda ()
                   ($ sc 'mint-gov-cap identity-key)   ; refuses non-governors
                   (let* ((w (wire-normalize w))
                          (s-wire (assq-ref w 'statement))
                          (bkey (assq-ref w 'bindingKey))
                          (b (and bkey ($ (binds-for commune-aid) 'get bkey))))
                     (cond
                      ((not (commune-act-allowed?
                             identity-key commune-aid "administer"))
                       (list 'error "machine-payout: denied by policy"))
                      ((not s-wire)
                       (list 'error "machine-payout: a statement is required"))
                      ((not b) (list 'error "machine-payout: no such binding"))
                      ((not (binding-live? b))
                       (list 'error "machine-payout: binding is not live"))
                      (else
                       (let* ((sw (wire-normalize s-wire))
                              (st (make-settlement-statement
                                    #:period (assq-ref sw 'period)
                                    #:entries (or (assq-ref sw 'entries) '())
                                    #:payments (or (assq-ref sw 'payments) '())
                                    #:bridge-sig (assq-ref sw 'bridgeSig)))
                              (rows (execute-payout st b #:send (*machine-send-rail*))))
                         (cons 'ok (map (lambda (r)
                                          `(("txHash" . ,(payout-row-tx-hash r))
                                            ("asset" . ,(payout-row-asset r))
                                            ("amount" . ,(payout-row-amount r))
                                            ("to" . ,(payout-row-to r))))
                                        rows)))))))
                 (lambda (k . a)
                   (list 'error (format #f "machine-payout: ~a" a)))))))

        ;; ── receipts ────────────────────────────────────────────────────
        ;; W is the wire alist the lender's node emitted. The door rebuilds
        ;; the record, recomputes the digest (the claimed digest must match
        ;; the body), checks the lender's signature where resolvable, then
        ;; records — and folds the event into the scope's observer as a
        ;; `use` event, the VF truth of the borrow.
        ((machine-receipt identity-key commune-aid w)
         (catch #t
           (lambda ()
             (let* ((r (wire->receipt w))
                    (claim-id (receipt-bridge-job-id r))
                    (verdict (sig-verdict r)))
               (cond
                ((not (receipt-digest-ok? r))
                 (list 'error "machine-receipt: digest does not match the body"))
                ((eq? verdict 'bad)
                 (list 'error "machine-receipt: lender signature does not verify"))
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
                                                (machine-job-spec-id
                                                  ($ reg 'job-of
                                                     (dispatch-claim-job-id claim))))
                                 #:commitment-id claim-id
                                 #:intent-id (and claim
                                                  (dispatch-claim-job-id claim)))))
                         (lambda _ #t))))
                   (cons 'ok (list digest verdict)))))))
           (lambda (k . a) (list 'error (format #f "machine-receipt: ~a" a)))))

        ;; dry-run: what would this receipt answer — digest ok, sig verdict
        ((machine-verify w)
         (catch #t
           (lambda ()
             (let ((r (wire->receipt w)))
               (cons 'ok (list (receipt-digest-ok? r) (sig-verdict r)))))
           (lambda (k . a) (list 'error (format #f "machine-verify: ~a" a)))))

        ;; ── settlement — a commune act, gov-cap gated ────────────────────
        ;; W is the bridge's statement as an alist: period, entries,
        ;; payments, bridgeSig. Gov-cap via mint-gov-cap — the same gate
        ;; accept-reimbursement runs. Reconciliation answers (ok matched
        ;; missing held claimed paid): a matched entry whose claim sits
        ;; under a live or upheld dispute is HELD — money does not move
        ;; on a contested receipt; a dismissed dispute releases it.
        ((machine-settle identity-key commune-aid w)
         (let ((sc (scope-for commune-aid)))
           (if (not sc)
               (list 'error "machine-settle: no scope reachable here for that commune")
               (catch #t
                 (lambda ()
                   ($ sc 'mint-gov-cap identity-key)   ; refuses non-governors
                   (if (not (commune-act-allowed?
                             identity-key commune-aid "administer"))
                       (list 'error "machine-settle: denied by policy")
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
                            result))))
                 (lambda (k . a)
                   (list 'error (format #f "machine-settle: ~a" a)))))))

        ((machine-statements commune-aid)
         (cons 'ok ($ (registry-for commune-aid) 'statements)))

        ;; the envelope contract — validates a job envelope a node would
        ;; run; refuses any envelope carrying a price key
        ((machine-envelope w)
         (catch #t
           (lambda ()
             (let ((e (alist->job-envelope (wire-normalize w))))
               (cons 'ok (job-envelope-bridge-job-id e))))
           (lambda (k . a) (list 'error (format #f "machine-envelope: ~a" a)))))))))
