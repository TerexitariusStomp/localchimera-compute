;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; compute/envelope.scm — the job envelope: what a node pulls and runs.
;;;
;;; WHAT THE FILE HOLDS. The <job-envelope> record — the self-describing
;;; unit of work a machine node fetches under a dispatch claim — and the
;;; one structural rule the spec makes load-bearing: AN ENVELOPE CARRIES
;;; NO AMOUNT. Pricing is never in the job; what a lender earns is decided
;;; by the commune's settlement, not by bytes the node executes. The
;;; validator refuses any envelope that names price-like keys, loudly —
;;; an envelope that says what it pays is not an envelope, it is a leak
;;; of the settlement layer into the execution layer.
;;;
;;; KINDS. An envelope declares one of *envelope-kinds* — 'exec (the
;;; original shape: image + entrypoint), 'store (hold contentHash for
;;; ttlSeconds; answer challenges), 'relay (pass traffic; params name
;;; the measured shape), 'sense (emit readings on an interval), and
;;; 'bundle (a job whose legs are sub-envelopes). Kind-specific fields
;;; ride in PARAMS — a free alist under the same no-amount rule, checked
;;; recursively so a nested leg cannot smuggle price either.

(define-module (playnet machine envelope)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:export (<job-envelope> make-job-envelope job-envelope?
            job-envelope-kind job-envelope-bridge-job-id job-envelope-image
            job-envelope-entrypoint job-envelope-input-hash
            job-envelope-caps job-envelope-network? job-envelope-params
            envelope-kind? *envelope-kinds*
            params-ref model-descriptor? envelope-model envelope-model-seed
            egress-profile? caps-grant?
            availability-descriptor? envelope-availability
            sense-profile?
            swarm-descriptor? envelope-swarm *swarm-roles*
            alist->job-envelope job-envelope->alist envelope-no-amount?))


;;; The keys an envelope may never carry — in any spelling a bridge might
;;; reach for. Checked on both construction and parse, so a hand-written
;;; alist cannot smuggle the field past a struct.
(define *price-keys* '(amount price cost fee payment payout rate tip
                              unit-price currency))

;;; keys arrive symbol-normalized on the wire, but a hand-written alist
;;; may spell them as strings — the refusal must not depend on the type.
(define (price-key? k)
  (or (memq k *price-keys*)
      (and (string? k)
           (member k '("amount" "price" "cost" "fee" "payment" "payout"
                       "rate" "tip" "unit-price" "currency"))
           #t)))

;;; the kind vocabulary — the wire the offer/jobs shape names
(define *envelope-kinds* '(exec store relay sense bundle))

(define (envelope-kind? x) (and (memq x *envelope-kinds*) #t))

(define-record-type <job-envelope>
  (%make-job-envelope kind bridge-job-id image entrypoint input-hash caps
                      network? params)
  job-envelope?
  (kind          job-envelope-kind)        ; 'exec | 'store | 'relay | 'sense | 'bundle
  (bridge-job-id job-envelope-bridge-job-id) ; string — the claim's job
  (image         job-envelope-image)         ; string | #f — exec kind only
  (entrypoint    job-envelope-entrypoint)    ; string | #f — exec kind only
  (input-hash    job-envelope-input-hash)    ; string — content hash for 'store
  (caps          job-envelope-caps)          ; alist: mem-mb, cpu-seconds
  (network?      job-envelope-network?)      ; bool — egress allowed or not
  (params        job-envelope-params))       ; alist — kind fields, price-free

;;; ── the inference profile ──────────────────────────────────────────────
;;; params.model names the model artifact an inference envelope runs: the
;;; bytes the engine decodes, committed so the executor caches by hash and
;;; a challenge replays the SAME artifact — never a similar one. uri
;;; fetches under the envelope's own network grant; sha256 is the commit
;;; the fetched bytes are checked against before the engine sees them.
;;; context and seed are the decode the receipt's repro reruns — a
;;; 'deterministic spec under the envelope's committed seed.

(define (params-ref params key)
  "A params value by symbol name, tolerating the string key a raw wire
   form may carry."
  (cond ((assq-ref params key))
        ((assoc (symbol->string key) params) => cdr)
        (else #f)))

(define (model-descriptor? m)
  "The params.model shape: uri+sha256+format are the commit the executor
   verifies before the engine sees a byte; context/seed are the decode
   knobs a 'deterministic replay reruns. Extra keys pass through — an
   engine's own tuning rides uninspected."
  (and (list? m)
       (string? (assq-ref m 'uri))
       (string? (assq-ref m 'sha256))
       (or (symbol? (assq-ref m 'format))
           (string? (assq-ref m 'format)))
       (or (not (assq 'context m))
           (and (integer? (assq-ref m 'context))
                (positive? (assq-ref m 'context))))
       (or (not (assq 'seed m))
           (number? (assq-ref m 'seed)))))

(define (envelope-model e)
  "The envelope's model descriptor, or #f — an exec envelope without one
   is ordinary compute, not inference."
  (params-ref (job-envelope-params e) 'model))

(define (envelope-model-seed e)
  "The decode seed the model commits, or #f — the receipt's repro records
   it so replay reruns the same decode."
  (params-ref (or (envelope-model e) '()) 'seed))

;;; ── the egress profile ─────────────────────────────────────────────────
;;; A 'relay envelope carrying params.profile 'egress asks the node to be
;;; the borrower's exit to the open internet: params.destination names the
;;; URL the node fetches on the borrower's behalf. The shape is refused
;;; early rather than failing inside the node's executor — an egress leg
;;; without a destination is not a job, and one without the fetch grant
;;; could never run.

(define (egress-profile? params)
  (let ((p (params-ref params 'profile)))
    (or (eq? p 'egress) (equal? p "egress"))))

(define (caps-grant? caps name)
  "Does CAPS grant NAME (a grant string like \"fetch\")? caps crosses as a
   list or vector mixing grant strings with limit alists — either shape
   answers."
  (let ((items (if (vector? caps) (vector->list caps) (or caps '()))))
    (and (member name items) #t)))

;;; ── the availability profile ───────────────────────────────────────────
;;; params.availability on a 'bundle declares durable serving: the legs
;;; hold (store) and serve (relay) for availability.lease-hours, and the
;;; claim meters 'node-hours delivered — the honest fraction of the lease
;;; the tab actually stood, not the promise. availability.replicas names
;;; the redundancy the borrower fans: this claim IS one replica, and
;;; correlating claims is the borrower's orchestration — an envelope
;;; describes a job, not a fleet.

(define (availability-descriptor? a)
  "The params.availability shape: lease-hours is the commitment the
   node-hours meter is read against (required, positive); replicas names
   the borrower's intended fan-out (≥1); replica-index marks which claim
   this is (≥0, optional)."
  (and (list? a)
       (let ((lh (params-ref a 'lease-hours))
             (r (params-ref a 'replicas))
             (i (params-ref a 'replica-index)))
         (and (and (number? lh) (positive? lh))
              (or (not r) (and (integer? r) (>= r 1)))
              (or (not i) (and (integer? i) (>= i 0)))))))

(define (envelope-availability e)
  "The envelope's availability descriptor, or #f."
  (params-ref (job-envelope-params e) 'availability))

;;; ── the sense profile ─────────────────────────────────────────────────
;;; A 'sense envelope turns the tab into an instrument: params.sources
;;; names the sensors to sample, intervalMs the tick, count|durationMs the
;;; session bound. A stream is not an open-ended promise — it is a bounded
;;; sampling session (the tab is ephemeral; the claim's deadline is the
;;; outer bound), so every knob the session is measured by is a positive
;;; number or the descriptor is refused at submit, not inside the node's
;;; sampler.

(define (sense-profile? params)
  "The 'sense params shape: sources is a non-empty list (or vector — JSON
   decodes arrays to vectors) naming sensors; intervalMs, count, and
   durationMs are the session knobs — each optional, each a positive
   number when named (a zero count samples nothing; a negative interval
   is not a tick)."
  (let ((sources (params-ref params 'sources)))
    (and (or (pair? sources) (and (vector? sources) (positive? (vector-length sources))))
         (every (lambda (s) (or (string? s) (symbol? s)))
                (if (vector? sources) (vector->list sources) sources))
         (let ((pos? (lambda (k)
                       (let ((v (params-ref params k)))
                         (or (not v) (and (number? v) (positive? v)))))))
           (and (pos? 'intervalMs) (pos? 'count) (pos? 'durationMs))))))

;;; ── the swarm profile ─────────────────────────────────────────────────
;;; params.swarm marks this envelope as one shard of a task no single tab
;;; could run: group names the swarm (the id the borrower opened with
;;; machine-swarm-open), shards the expected fan-out, shard-index which
;;; claim this envelope feeds. The role names the shard's place in the
;;; decomposition — and the role must fit the kind: the swarm is a
;;; coordination shape, not a new kind.
;;;
;;;   stage  — an exec shard of a pipeline (a model's layer range):
;;;            activations arrive from shard-index-1, results flow to
;;;            shard-index+1 over swarm-signalled channels
;;;   map    — a data-parallel exec shard: an input slice in, a result
;;;            slice out, replayable shard by shard
;;;   merge  — the exec claim that consumes the siblings' outputs and
;;;            emits the aggregate receipt
;;;   stripe — a store shard: content wider than one tab's quota, one
;;;            stripe per claim, challenged like any store claim
;;;   hop    — a relay shard: one link of a chained datachannel path;
;;;            the last hop egresses; params.swarm.link names which
;;;            adjacent pair of shards this claim's channel joins
;;;   fleet  — a sense shard: one member of a sampling fleet whose
;;;            readings the merge leg aggregates to a quorum answer
;;;
;;; One job still mints one claim — the claim stays the accounting atom;
;;; the swarm is coordination over claims, never a new billing entity.

(define *swarm-roles* '(stage map merge stripe hop fleet))

(define (swarm-role-for-kind? role kind)
  (or (and (memq role '(stage map merge)) (eq? kind 'exec))
      (and (eq? role 'stripe) (eq? kind 'store))
      (and (eq? role 'hop) (eq? kind 'relay))
      (and (eq? role 'fleet) (eq? kind 'sense))))

(define (swarm-descriptor? s kind)
  "The params.swarm shape for KIND: group is the swarm's name (a string —
   the borrower's swarm-open id), shards the expected fan-out (≥2 — a
   one-shard swarm is a job), shard-index which claim this feeds
   (0..shards-1), role one of the decomposition roles the kind can run."
  (and (list? s)
       (let ((group (params-ref s 'group))
             (shards (params-ref s 'shards))
             (index (params-ref s 'shard-index))
             (role (params-ref s 'role)))
         (and (string? group)
              (integer? shards) (>= shards 2)
              (integer? index) (>= index 0) (< index shards)
              (swarm-role-for-kind? role kind)
              (let ((link (params-ref s 'link)))
                (or (not link) (string? link)))))))

(define (envelope-swarm e)
  "The envelope's swarm descriptor, or #f."
  (params-ref (job-envelope-params e) 'swarm))

(define* (make-job-envelope #:key (kind 'exec) bridge-job-id (image #f)
                            (entrypoint #f) input-hash
                            (caps '()) (network? #f) (params '()))
  (unless (envelope-kind? kind)
    (error "envelope: not an envelope kind" kind))
  (when (eq? kind 'exec)
    (unless (and (string? image) (string? entrypoint))
      (error "envelope: an exec envelope needs image and entrypoint")))
  (unless (envelope-no-amount? params)
    (error "envelope: params carry no amount"))
  (let ((m (params-ref params 'model)))
    (when m
      (unless (model-descriptor? m)
        (error "envelope: params.model is not a model descriptor" m))))
  (when (and (eq? kind 'relay) (egress-profile? params))
    (unless (string? (params-ref params 'destination))
      (error "envelope: an egress relay needs params.destination"))
    (unless network?
      (error "envelope: an egress relay needs network:true"))
    (unless (caps-grant? caps "fetch")
      (error "envelope: an egress relay needs the fetch cap")))
  (let ((a (params-ref params 'availability)))
    (when a
      (unless (eq? kind 'bundle)
        (error "envelope: availability rides a bundle, not" kind))
      (unless (availability-descriptor? a)
        (error "envelope: params.availability is not an availability descriptor" a))))
  (when (eq? kind 'sense)
    (unless (sense-profile? params)
      (error "envelope: a sense envelope needs params.sources and positive session knobs" params)))
  (let ((s (params-ref params 'swarm)))
    (when s
      (unless (swarm-descriptor? s kind)
        (error "envelope: params.swarm is not a swarm descriptor for this kind" s))))
  (%make-job-envelope kind bridge-job-id image entrypoint input-hash caps
                      network? params))

(define (envelope-no-amount? fields)
  "No key in FIELDS (an alist or a list of symbols) is a price key —
   checked recursively, so a params value or bundle leg that is itself an
   alist (or a vector of alists, the shape JSON decodes to) is walked too."
  (every (lambda (f)
           (cond ((and (pair? f) (pair? (car f)))
                  ;; f is itself an alist — walk every pair in it, first
                  ;; included, or a leg's leading (price . n) walks free
                  (envelope-no-amount? f))
                 ((pair? f)
                  (and (not (price-key? (car f)))
                       (cond ((list? (cdr f)) (envelope-no-amount? (cdr f)))
                             ((vector? (cdr f))
                              (envelope-no-amount? (vector->list (cdr f))))
                             (else #t))))
                 (else (not (price-key? f)))))
         fields))

(define (alist->job-envelope a)
  "Parse the wire alist. Refuses any envelope carrying a price key.
   'kind' and 'params' are optional — an envelope that names neither is the
   original exec shape, so every pre-kind wire form still parses."
  (unless (envelope-no-amount? a)
    (error "envelope: a job envelope carries no amount"))
  (let ((kind (cond ((assq-ref a 'kind) => string->symbol)
                    (else 'exec)))
        (params (or (assq-ref a 'params) '()))
        (jid (assq-ref a 'bridgeJobId))
        (image (assq-ref a 'image))
        (entry (assq-ref a 'entrypoint))
        (input-hash (assq-ref a 'inputHash))
        (caps (assq-ref a 'caps))
        (network? (assq-ref a 'network)))
    (unless (string? jid) (error "envelope: bridgeJobId must be a string" a))
    (unless (string? input-hash)
      (error "envelope: inputHash must be a string" a))
    (unless (boolean? network?)
      (error "envelope: network must be a boolean" a))
    (make-job-envelope #:kind kind #:bridge-job-id jid #:image image
                       #:entrypoint entry #:input-hash input-hash
                       #:caps (or caps '()) #:network? network?
                       #:params params)))

(define (job-envelope->alist e)
  `(("kind"        . ,(symbol->string (job-envelope-kind e)))
    ("bridgeJobId" . ,(job-envelope-bridge-job-id e))
    ("image"       . ,(job-envelope-image e))
    ("entrypoint"  . ,(job-envelope-entrypoint e))
    ("inputHash"   . ,(job-envelope-input-hash e))
    ;; a vector on the wire decodes to a vector in the browser — a bare '()
    ;; here would cross as one too, but as the tagged record the JSON
    ;; writer can't carry
    ("caps"        . ,(let ((c (job-envelope-caps e)))
                        (if (vector? c) c (list->vector (or c '())))))
    ("network"     . ,(job-envelope-network? e))
    ("params"      . ,(job-envelope-params e))))
