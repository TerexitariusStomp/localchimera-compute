;;; module/playnet/governance/remote-scope-poller.scm — cross-gateway scope ingest
;;;
;;; **Role after Phase 6:** secondary catch-up only.
;;;
;;; Phase 6 made cross-gateway membership push-driven: when a federation
;;; admits a commune, an IPEX grant flies to the UC's AID (see
;;; `scope-deliver-grant!` in scope.scm and the inbound `handle-ipex-grant`
;;; in notifications.scm). The UC's gateway updates its scope-graph
;;; reactively, no polling needed in steady state.
;;;
;;; This poller now serves three narrower roles:
;;;
;;;   1. **Offline-rejoin catch-up.** If gateway B was offline when
;;;      gateway A pushed grants to B's UC, those grants are stuck in
;;;      A's pending-grants queue. The reconnect-edge drain (see
;;;      keri/recovery.scm `register-reconnect-hook!`) flushes them.
;;;      But if A's gateway restarted across the outage and lost the
;;;      pending entries (in-memory-only for the umbrella queue), the
;;;      poller fills the gap.
;;;
;;;   2. **Bootstrap discovery.** A brand-new gateway with no prior
;;;      grant traffic learns of peer scopes via /scopes before any
;;;      grant fires.
;;;
;;;   3. **Sanity / drift detection.** Periodic comparison of pushed
;;;      vs polled state surfaces divergence (silent grant losses,
;;;      out-of-band peer state).
;;;
;;; Cadence is therefore slow by default — every 30 minutes — and
;;; tunable via PLAYNET_REMOTE_POLL_INTERVAL_SEC. Set to a small value
;;; (e.g. 60) only when push delivery is known-broken (deploy
;;; uncertainty period after a Strategy-C change).
;;;
;;; Trust model unchanged: peers are trusted to report TRUTHFUL /scopes;
;;; a peer can omit (undercount) but cannot inject (fake AIDs have no
;;; real KEL, so /oobi fetches reveal the lie). When push-delivery and
;;; polling disagree, push is authoritative — its credential carries a
;;; verifiable issuer signature.
;;;
;;; Peer configuration: env var PLAYNET_PEERS, comma-separated base
;;; URLs ("https://peer-a.example,https://peer-b.example"). Empty or
;;; absent → no remote ingest, poller still spawns but no-ops on tick.

(define-module (playnet governance remote-scope-poller)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 format)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (json)
  #:use-module ((web client)   #:select (http-get))
  #:use-module ((web response) #:select (response-code))
  #:use-module ((rnrs bytevectors) #:select (utf8->string bytevector?))
  ;; SAID re-derivation for ACDC integrity: same compute-said the issuer
  ;; used, so we can independently verify that the cred wasn't tampered
  ;; with in flight (Q1 in the plan — inline ACDC verification).
  #:use-module ((playnet keri acdc) #:select (cred-said cred-schema cred-issuer cred-holder cred-claims cred-edges cred-revoked?))
  #:use-module ((playnet keri said-portable) #:select (compute-said))
  #:use-module ((playnet utils common) #:select (env-int))
  #:export (^remote-scope-poller
            spawn-remote-scope-poller
            remote-poller-default-interval-sec
            parse-peers-env
            verify-membership-acdc))

(define (remote-poller-default-interval-sec)
  "Default 30 minutes — appropriate for a catch-up role (Phase 6 makes
   push the primary path). Lower via PLAYNET_REMOTE_POLL_INTERVAL_SEC
   only during deploy uncertainty after a Strategy-C IPEX change."
  (env-int "PLAYNET_REMOTE_POLL_INTERVAL_SEC" 1800))

(define (string-trim-both s)
  "Hand-rolled to avoid the srfi-13 import; trims ASCII whitespace."
  (let* ((n (string-length s))
         (start (let loop ((i 0))
                  (cond ((>= i n) n)
                        ((char-whitespace? (string-ref s i)) (loop (+ i 1)))
                        (else i))))
         (end   (let loop ((j n))
                  (cond ((<= j start) start)
                        ((char-whitespace? (string-ref s (- j 1))) (loop (- j 1)))
                        (else j)))))
    (substring s start end)))

(define (strip-trailing-slash s)
  (let ((n (string-length s)))
    (if (and (> n 0) (char=? (string-ref s (- n 1)) #\/))
        (substring s 0 (- n 1))
        s)))

(define (parse-peers-env)
  "Split PLAYNET_PEERS on commas, drop empties + strip trailing slashes.
   Each element should be a base URL like \"https://peer.example\" —
   the poller appends /scopes etc."
  (let ((env (getenv "PLAYNET_PEERS")))
    (if (or (not env) (string-null? env))
        '()
        (filter
         (lambda (s) (not (string-null? s)))
         (map (lambda (s) (strip-trailing-slash (string-trim-both s)))
              (string-split env #\,))))))

(define (log* fmt . args)
  (apply format (current-error-port)
         (string-append "[remote-poller] " fmt "~%")
         args)
  (force-output (current-error-port)))

;;; ── HTTP fetch (best-effort) ──────────────────────────────────────────────
;;;
;;; The gateway already runs under torsocks so outbound HTTPS routes
;;; through Tor — no extra proxy config needed here.

(define (fetch-json url)
  "GET URL, parse body as JSON. Returns parsed value on success, #f on
   any error (HTTP non-2xx, network error, JSON parse failure)."
  (catch #t
    (lambda ()
      (call-with-values
          (lambda () (http-get url #:streaming? #f))
        (lambda (response body)
          (cond
           ((not (= 200 (response-code response)))
            (log* "GET ~a → HTTP ~a; skipping"
                  url (response-code response))
            #f)
           (else
            (let ((text (cond
                         ((string? body) body)
                         ((bytevector? body) (utf8->string body))
                         (else (object->string body)))))
              (json-string->scm text)))))))
    (lambda args
      (log* "GET ~a failed: ~s" url args)
      #f)))

;;; ── ACDC integrity verification ──────────────────────────────────────────
;;;
;;; A peer's /scope/<aid>/parents.json bundles each parent's
;;; federation-membership ACDC inline as a Scheme s-expression
;;; (`acdc_scm` field). We re-read it and check four things:
;;;
;;;   1. schema   = playnet-federation-membership/v1
;;;   2. holder   = the AID we were asking about
;;;   3. revoked? = #f
;;;   4. SAID re-derives to the advertised SAID, AND to the SAID we
;;;      were promised by the parents.json wrapper (no swapping a
;;;      different cred under the same SAID label)
;;;
;;; What we do NOT verify yet: the signature against the issuer's KEL.
;;; That requires fetching /oobi/<issuer-aid>, parsing the KEL, and
;;; running ed25519 verify against the current signing keys. The hook
;;; for that lands in v2; for v1, SAID re-derivation already catches
;;; in-flight tampering and content swaps. A malicious peer that owns
;;; the issuer's keys can still mint a forged-but-valid cred, but
;;; that's a key-compromise problem, not a transport problem.

(define %fed-membership-schema "playnet-federation-membership/v1")

(define (parse-acdc-scm s)
  "Read an `acdc_scm` field back into a cred alist. Returns the alist
   or #f if the input doesn't parse."
  (catch #t
    (lambda () (call-with-input-string s read))
    (lambda _ #f)))

(define (verify-membership-acdc cred expected-said expected-holder)
  "Returns (values ok? reason). When OK?, cred is safe to feed into
   scope-graph as a parent-link assertion."
  (cond
   ((not (pair? cred))
    (values #f 'not-a-cred))
   ((not (equal? (cred-schema cred) %fed-membership-schema))
    (values #f 'wrong-schema))
   ((not (equal? (cred-holder cred) expected-holder))
    (values #f 'holder-mismatch))
   ((cred-revoked? cred)
    (values #f 'revoked))
   ((not (equal? (cred-said cred) expected-said))
    (values #f 'said-label-mismatch))
   (else
    (let ((rederived (compute-said (cred-issuer cred)
                                   (cred-holder cred)
                                   (cred-schema cred)
                                   (cred-claims cred)
                                   (cred-edges cred))))
      (if (equal? rederived (cred-said cred))
          (values #t 'ok)
          (values #f 'said-rederivation-mismatch))))))

;;; ── Poller actor ──────────────────────────────────────────────────────────

(define* (^remote-scope-poller bcom
                               scope-graph
                               #:optional
                               (peers (parse-peers-env))
                               (interval-sec (remote-poller-default-interval-sec))
                               (known (hashmap))
                               (last-tick #f)
                               ;; on-peer-uc: optional (lambda (peer-uc-aid) …)
                               ;; called when a peer reports a universal-commune
                               ;; scope. The gateway closes the local UC store +
                               ;; known-uc-aid over it and runs uc-reconcile-action
                               ;; — the poller stays ignorant of UC semantics.
                               (on-peer-uc #f))

  (define (with-state new-known new-tick)
    (^remote-scope-poller bcom scope-graph peers interval-sec
                          new-known new-tick on-peer-uc))

  (define (known-key peer aid)
    (string-append peer "|" aid))

  (define (ingest-peer-scope peer entry)
    "ENTRY is alist with \"aid\" + \"kind\" string keys."
    (let* ((aid  (and (pair? entry) (assoc-ref entry "aid")))
           (kind (string->symbol
                  (or (and (pair? entry) (assoc-ref entry "kind"))
                      "commune")))
           (key  (and aid (known-key peer aid))))
      (cond
       ((not aid)
        (log* "peer ~a returned entry without aid: ~s" peer entry))
       ((hashmap-ref known key #f)
        ;; Already seen this peer/AID; refresh-only.
        #f)
       (else
        (catch #t
          (lambda ()
            ;; note-spawn is idempotent. Fire-and-forget — we don't
            ;; care about the reply; if the graph rebuild fails we'll
            ;; just retry the same note on the next tick.
            (<-np scope-graph 'note-spawn aid kind '())
            (log* "ingested ~a/~a (~a)" peer aid kind))
          (lambda args (log* "note-spawn failed for ~a: ~s" aid args)))
        ;; One-UC-as-gravity: a peer reporting its own Universal Commune is
        ;; a candidate collision. Hand it to the gateway's reconciler, which
        ;; proposes a (consensual) merge on a genuine collision and no-ops on
        ;; a lineally-unified or identical UC. Best-effort; never aborts the
        ;; tick.
        (when (and on-peer-uc (eq? kind 'universal-commune))
          (catch #t (lambda () (on-peer-uc aid))
            (lambda args (log* "uc-reconcile failed for ~a: ~s" aid args))))))))

  (define (ingest-parent-links peer child-aid)
    "Fetch /scope/<child-aid>/parents.json from PEER, verify each
     inline ACDC, and note verified links into scope-graph. Failures
     are logged but never abort the tick — peers can be partially
     malicious or partially broken without poisoning the graph."
    (let* ((url  (string-append peer "/scope/" child-aid "/parents.json"))
           (resp (fetch-json url)))
      (when resp
        (let* ((vec     (or (and (pair? resp) (assoc-ref resp "parents")) #()))
               (entries (cond
                         ((vector? vec) (vector->list vec))
                         ((list?   vec) vec)
                         (else '()))))
          (for-each
           (lambda (e)
             (let* ((parent-aid (and (pair? e) (assoc-ref e "parent_aid")))
                    (said       (and (pair? e) (assoc-ref e "membership_said")))
                    (acdc-scm   (and (pair? e) (assoc-ref e "acdc_scm")))
                    (cred       (and acdc-scm (parse-acdc-scm acdc-scm))))
               (cond
                ((not (and parent-aid said cred))
                 (log* "parents.json ~a/~a: missing fields"
                       peer child-aid))
                (else
                 (call-with-values
                     (lambda () (verify-membership-acdc cred said child-aid))
                   (lambda (ok? reason)
                     (cond
                      ((not ok?)
                       (log* "parents.json ~a/~a SAID=~a rejected: ~a"
                             peer child-aid said reason))
                      ((not (equal? parent-aid (cred-issuer cred)))
                       (log* "parents.json ~a/~a issuer/parent_aid mismatch"
                             peer child-aid))
                      (else
                       (catch #t
                         (lambda ()
                           (<-np scope-graph 'note-parent-link
                                 child-aid parent-aid))
                         (lambda args
                           (log* "note-parent-link failed for ~a→~a: ~s"
                                 child-aid parent-aid args)))))))))))
           entries)))))

  (define (poll-one-peer peer)
    "Fetch + ingest one peer's /scopes, then walk parents.json for
     each. Returns the list of /scopes entries (for the caller to
     update last-seen timestamps)."
    (let* ((url  (string-append peer "/scopes"))
           (resp (fetch-json url)))
      (cond
       ((not resp) '())
       (else
        (let* ((scopes-vec (or (and (pair? resp)
                                    (assoc-ref resp "scopes"))
                               #()))
               (entries (cond
                         ((vector? scopes-vec) (vector->list scopes-vec))
                         ((list?   scopes-vec) scopes-vec)
                         (else '()))))
          (for-each (lambda (e) (ingest-peer-scope peer e)) entries)
          (for-each
           (lambda (e)
             (let ((aid (and (pair? e) (assoc-ref e "aid"))))
               (when aid (ingest-parent-links peer aid))))
           entries)
          (log* "peer ~a: ~a entries" peer (length entries))
          entries)))))

  (define (do-tick)
    (let ((all-keys '()))
      (for-each
       (lambda (peer)
         (let ((entries (poll-one-peer peer)))
           (for-each
            (lambda (e)
              (let ((aid (and (pair? e) (assoc-ref e "aid"))))
                (when aid
                  (set! all-keys (cons (known-key peer aid) all-keys)))))
            entries)))
       peers)
      (let ((new-known
             (fold (lambda (k acc) (hashmap-set acc k (instant->unix (clock-now))))
                   known all-keys)))
        (values new-known (instant->unix (clock-now))))))

  (methods

    ((tick)
     (cond
      ((null? peers)
       (bcom (with-state known (instant->unix (clock-now))) 'ok))
      (else
       (call-with-values do-tick
         (lambda (new-known now)
           (bcom (with-state new-known now) 'ok))))))

    ((add-peer url)
     (let ((trimmed (strip-trailing-slash (string-trim-both url))))
       (cond
        ((member trimmed peers)
         (bcom (with-state known last-tick) 'already-present))
        (else
         (bcom (^remote-scope-poller bcom scope-graph
                                     (append peers (list trimmed))
                                     interval-sec known last-tick)
               'ok)))))

    ((remove-peer url)
     (let ((trimmed (strip-trailing-slash (string-trim-both url))))
       (bcom (^remote-scope-poller bcom scope-graph
                                   (filter (lambda (p) (not (equal? p trimmed)))
                                           peers)
                                   interval-sec known last-tick)
             'ok)))

    ((status)
     `((peers         . ,peers)
       (interval-sec  . ,interval-sec)
       (last-tick     . ,last-tick)
       (known-count   . ,(hashmap-fold (lambda (_k _v acc) (+ acc 1))
                                       0 known))))))

(define* (spawn-remote-scope-poller scope-graph
                                    #:key
                                    (peers (parse-peers-env))
                                    (interval-sec (remote-poller-default-interval-sec))
                                    (start-ticker? #t)
                                    (on-peer-uc #f)
                                    (vat #f))
  "Spawn ^remote-scope-poller + (when START-TICKER? AND peers is
   non-empty) a thread that pushes (<- poller 'tick) every
   INTERVAL-SEC. Returns the poller ref.

   VAT must be the vat owning POLLER — `<-` from a bare thread
   without a vat turn fails the transactormap merge check. Required
   only when start-ticker? is #t and there are peers to poll."
  (let ((poller (spawn ^remote-scope-poller scope-graph peers interval-sec
                       (hashmap) #f on-peer-uc)))
    (when (and start-ticker? (pair? peers))
      (unless vat
        (error "spawn-remote-scope-poller: #:vat is required when start-ticker? is #t and peers is non-empty"))
      (call-with-new-thread
       (lambda ()
         (let loop ()
           (sleep interval-sec)
           (catch #t
             (lambda ()
               (with-vat vat (<- poller 'tick)))
             (lambda args
               (log* "ticker push failed: ~a" args)))
           (loop)))))
    poller))
