;;; acdc-store.scm — accumulator for issued credentials with typed indexes
;;;
;;; In-memory hashmap SAID → credential, plus typed claim indexes for
;;; O(1) hot-path lookups. Each schema layer declares which claims to index
;;; through register-schema-claims! in (playnet keri acdc).
;;;
;;; The KERIA-backed variant (^keria-acdc-store) implements the same
;;; method interface — actors talk to whichever is wired in.
;;;
;;; A "no-op" acdc-store accepts issue/revoke calls but stores nothing.
;;;
;;; **Durability**: when spawned with `#:durable-dir <path>`, every
;;; mutation also writes through to disk under a content-addressed
;;; layout (`<dir>/<said-prefix>/<said>.scm` for credentials,
;;; `<dir>/_revoked.log` append-only for revocations). On respawn, the
;;; directory is replayed via `issue-idempotent` + revoke. This makes
;;; the store survive process death without changing the in-memory hot
;;; path. Files are SAID-keyed, so the store is locally verifiable and
;;; rsync/Syncthing/Radicle replicable. See test-fp-portability.scm.
;;;
;;; **Sync**: `'export-since` returns `(cred . revoked?)` pairs for
;;; cross-vat replication; `'import` is a fold of issue-idempotent +
;;; revoke. SAID collisions are no-ops (idempotent), so re-importing
;;; the same credentials is safe.
;;;
;;; The persistence env that names this actor in a deployment's durable state
;;; belongs to the deployment.

(define-module (playnet keri acdc-store)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (playnet keri acdc)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet utils said-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (index-add-cred hashmap-count index-lookup durable-revoked-path
            durable-ensure-dir! durable-write-cred! durable-append-revoke!
            durable-load-creds apply-import-pair durable-load-revokes ^acdc-store
            credentials-of-schema in-ts-range? timestamp-sorted non-revoked-by-schema
            spawn-acdc-store))

;; =========================================================================
;; Index helpers
;; =========================================================================

(define (index-add-cred indexes cred)
  "For each indexed claim of CRED's schema, add (claim-value → SAID)
   to the appropriate sub-hashmap. Returns updated indexes."
  (let ((schema (cred-schema cred))
        (said   (cred-said cred)))
    (fold
      (lambda (claim-key acc)
        (let* ((value (cred-claim cred claim-key))
               (key   (cons schema claim-key))
               (sub   (hashmap-ref acc key (hashmap)))
               (saids (hashmap-ref sub value '())))
          (if value
              (hashmap-set acc key
                           (hashmap-set sub value (cons said saids)))
              acc)))
      indexes
      (indexed-claims-for schema))))

(define (hashmap-count m)
  (hashmap-fold (lambda (_k _v n) (+ n 1)) 0 m))

(define (index-lookup indexes credentials schema claim-key value)
  "Return list of credentials matching (schema, claim-key, value)."
  (let ((sub (hashmap-ref indexes (cons schema claim-key) #f)))
    (if (not sub) '()
        (let ((saids (hashmap-ref sub value '())))
          (filter-map (lambda (s) (hashmap-ref credentials s #f))
                      saids)))))


;; =========================================================================
;; Durable-dir helpers — content-addressed write-through to disk.
;; =========================================================================
;;
;; Layout under <dir>:
;;   <dir>/<said-2-prefix>/<said>.scm   — one credential per file
;;   <dir>/_revoked.log                 — append-only revocation log
;;
;; Both files are S-expressions readable by Guile's (read). Credentials
;; are content-addressed by their SAID — if two stores merge their
;; directories by file copy, the union is still a valid store.

;; The content-addressed body (`<dir>/<said[0:2]>/<said>.scm`) is the shared
;; (playnet utils said-store); acdc-store adds a `_revoked.log` sidecar.
(define (durable-revoked-path dir)
  (string-append dir "/_revoked.log"))

(define (durable-ensure-dir! dir)
  (said-store-ensure-dir! dir)
  ;; touch the revoked-log so append-mode opens cleanly later
  (let ((log (durable-revoked-path dir)))
    (unless (file-exists? log)
      (call-with-output-file log (lambda (p) (display "" p))))))

(define (durable-write-cred! dir cred)
  (said-store-write! dir (cred-said cred) cred))

(define (durable-append-revoke! dir said at)
  (when dir
    (let ((port (open-file (durable-revoked-path dir) "a")))
      (write (cons said at) port)
      (newline port)
      (close-port port))))

(define (durable-load-creds dir)
  "Every credential alist under <dir>/<prefix>/<said>.scm. Order is
   unspecified — callers re-issue idempotently."
  (said-store-scan dir))

;; Single-step folder for `'import`. Threads (creds . idx) and writes
;; through to disk on the actual mutating cases. Three branches:
;;   - new credential        → store + index + maybe-revoke
;;   - revocation escalation → mark existing as revoked
;;   - no-op (already known) → identity
(define (apply-import-pair durable-dir entry state)
  (let* ((creds    (car state))
         (idx      (cdr state))
         (cred     (car entry))
         (revoked? (cdr entry))
         (said     (cred-said cred))
         (existing (hashmap-ref creds said #f)))
    (cond
      ((not existing)
       (durable-write-cred! durable-dir cred)
       (when revoked? (durable-append-revoke! durable-dir said (instant->unix (clock-now))))
       (cons (hashmap-set creds said
                          (if revoked? (cred-with-revoked cred #t) cred))
             (index-add-cred idx cred)))
      ((and revoked? (not (cred-revoked? existing)))
       (durable-append-revoke! durable-dir said (instant->unix (clock-now)))
       (cons (hashmap-set creds said (cred-with-revoked existing #t)) idx))
      (else state))))

(define (durable-load-revokes dir)
  "Read _revoked.log, returning a list of (said . when) pairs."
  (let ((path (durable-revoked-path dir)))
    (if (not (file-exists? path)) '()
        (call-with-input-file path
          (lambda (port)
            (let loop ((acc '()))
              (let ((datum (read port)))
                (if (eof-object? datum) (reverse acc)
                    (loop (cons datum acc))))))))))


;; =========================================================================
;; ^acdc-store
;; =========================================================================

(define-actor (^acdc-store bcom credentials no-op? indexes durable-dir)
  ;; credentials:  hashmap SAID → credential alist
  ;; no-op?:       if #t, mutations succeed but credentials stays empty
  ;; indexes:      hashmap (schema . claim-key) → hashmap (claim-value → list-of-SAIDs)
  ;; durable-dir:  optional filesystem path for write-through; #f = pure memory

  #:version 3

  #:portrait
  (lambda () (list credentials no-op? indexes durable-dir))

  #:restore
  (lambda (version . args)
    (case version
      ((1)
       ;; Old: (credentials no-op?). Rebuild indexes from scratch.
       (let* ((creds (car args))
              (noop  (cadr args))
              (idx (hashmap-fold
                     (lambda (_k cred acc) (index-add-cred acc cred))
                     (hashmap) creds)))
         (spawn ^acdc-store creds noop idx #f)))
      ((2)
       ;; Old: (credentials no-op? indexes). No durable-dir.
       (apply spawn ^acdc-store (append args (list #f))))
      ((3)
       (apply spawn ^acdc-store args))
      (else (error "Unknown ^acdc-store version" version))))

  (methods

    ;; --- Writes ---

    ((issue cred)
     (cond
       (no-op? #f)
       (else
        (let ((said (cred-said cred)))
          (when (hashmap-ref credentials said #f)
            (error "Credential already issued (SAID collision)" said))
          (durable-write-cred! durable-dir cred)
          (bcom (^acdc-store bcom
                             (hashmap-set credentials said cred)
                             no-op?
                             (index-add-cred indexes cred)
                             durable-dir)
                said)))))

    ((issue-idempotent cred)
     ;; Like issue, but no-op (returning existing SAID) if SAID already present.
     ;; Useful during recovery when replaying ACDCs from a witness pool.
     (cond
       (no-op? #f)
       (else
        (let ((said (cred-said cred)))
          (cond
            ((hashmap-ref credentials said #f) said)
            (else
             (durable-write-cred! durable-dir cred)
             (bcom (^acdc-store bcom
                                (hashmap-set credentials said cred)
                                no-op?
                                (index-add-cred indexes cred)
                                durable-dir)
                   said)))))))

    ((strengthen cred)
     ;; The SAME statement, BETTER evidence: a credential's SAID is computed
     ;; over its content and never its signature, so a copy whose signature
     ;; block strictly grows — unsigned → scope-signed → k-of-n multisig, or
     ;; more co-signatures in the block — carries the identical claim with
     ;; more witnesses behind it. Accept it in place (nothing downstream
     ;; re-keys); a copy no stronger than what is held is a no-op, and an
     ;; unknown SAID issues, so callers need no present/absent branch. The
     ;; durable file is SAID-keyed, so the stronger copy overwrites its own.
     (cond
       (no-op? #f)
       (else
        (let* ((said (cred-said cred))
               (weight (lambda (c)
                         (let ((s (assq-ref c 'signature)))
                           (cond ((pair? s) (length s))
                                 ((string? s) 1)
                                 (else 0)))))
               (held (hashmap-ref credentials said #f)))
          (cond
            ((and held (<= (weight cred) (weight held))) said)
            (else
             (durable-write-cred! durable-dir cred)
             (bcom (^acdc-store bcom
                                (hashmap-set credentials said cred)
                                no-op?
                                (if held indexes (index-add-cred indexes cred))
                                durable-dir)
                   said)))))))

    ((revoke said)
     (cond
       (no-op? #f)
       (else
        (let ((existing (hashmap-ref credentials said #f)))
          (cond
            ((not existing) (error "Cannot revoke unknown SAID" said))
            (else
             (durable-append-revoke! durable-dir said (instant->unix (clock-now)))
             (bcom (^acdc-store bcom
                                (hashmap-set credentials said
                                             (cred-with-revoked existing #t))
                                no-op?
                                indexes
                                durable-dir))))))))

    ;; --- Sync (cross-vat / cross-replica replication) ---

    ((export-since when)
     ;; (cred . revoked?) pairs whose timestamp ≥ WHEN (or all when
     ;; WHEN is #f / 0). Revoked-flag is folded back at import time so
     ;; a peer's view converges with ours.
     (let ((since (or when 0)))
       (hashmap-fold
         (lambda (_k cred acc)
           (let ((ts (cred-timestamp cred)))
             (if (or (zero? since) (and ts (>= ts since)))
                 (cons (cons cred (cred-revoked? cred)) acc)
                 acc)))
         '() credentials)))

    ((import pairs)
     ;; Bulk-load (cred . revoked?) pairs from a peer's `export-since`.
     ;; Idempotent — SAID collisions are no-ops, revocation is
     ;; monotonic. Each pair is folded through `apply-import-pair`,
     ;; which threads (creds . idx) and writes through to disk.
     (cond
       (no-op?
        (bcom (^acdc-store bcom credentials no-op? indexes durable-dir) 0))
       (else
        (let* ((start (hashmap-count credentials))
               (final (fold (lambda (entry st)
                              (apply-import-pair durable-dir entry st))
                            (cons credentials indexes)
                            pairs)))
          (bcom (^acdc-store bcom (car final) no-op? (cdr final) durable-dir)
                (- (hashmap-count (car final)) start))))))

    ;; --- Reads ---

    ((get said) (hashmap-ref credentials said #f))

    ((all)
     (hashmap-fold (lambda (_k v acc) (cons v acc)) '() credentials))

    ((by-schema schema)
     (hashmap-fold
       (lambda (_k v acc)
         (if (equal? schema (cred-schema v)) (cons v acc) acc))
       '() credentials))

    ((by-holder aid)
     (hashmap-fold
       (lambda (_k v acc)
         (if (equal? aid (cred-holder v)) (cons v acc) acc))
       '() credentials))

    ((by-issuer aid)
     (hashmap-fold
       (lambda (_k v acc)
         (if (equal? aid (cred-issuer v)) (cons v acc) acc))
       '() credentials))

    ((non-revoked)
     (hashmap-fold
       (lambda (_k v acc)
         (if (cred-revoked? v) acc (cons v acc)))
       '() credentials))

    ;; --- Indexed reads (O(1) hashmap lookup) ---

    ((by-claim schema claim-key value)
     ;; Returns all credentials matching (schema, claim-key, value),
     ;; including revoked ones. Caller filters as needed.
     (index-lookup indexes credentials schema claim-key value))

    ((by-claim-1 schema claim-key value)
     ;; First non-revoked match, or #f.
     (let loop ((cs (index-lookup indexes credentials schema claim-key value)))
       (cond
         ((null? cs) #f)
         ((cred-revoked? (car cs)) (loop (cdr cs)))
         (else (car cs)))))

    ;; --- Time-series reads ---
    ;;
    ;; These answer: "what is the sequence of credentials of SCHEMA
    ;; (optionally filtered) within a timestamp window?" Essential for
    ;; building rolling-window S_t and I_t series. from-ts / to-ts may
    ;; be #f for open ranges. Credentials without a parseable timestamp
    ;; are dropped; revoked credentials are kept so callers can detect
    ;; point-in-time state (filter via cred-revoked? as needed).

    ((series-for-schema schema)
     (timestamp-sorted (credentials-of-schema schema credentials)))

    ((by-schema-in-range schema from-ts to-ts)
     (timestamp-sorted
       (filter (lambda (c) (in-ts-range? c from-ts to-ts))
               (credentials-of-schema schema credentials))))

    ((by-claim-in-range schema claim-key value from-ts to-ts)
     (timestamp-sorted
       (filter (lambda (c) (in-ts-range? c from-ts to-ts))
               (index-lookup indexes credentials schema claim-key value))))

    ((no-op?) no-op?)))


(define (credentials-of-schema schema credentials)
  "All stored credentials matching SCHEMA that carry a parseable
   timestamp. Backs the time-series read methods."
  (hashmap-fold
    (lambda (_k v acc)
      (if (and (equal? schema (cred-schema v)) (cred-timestamp v))
          (cons v acc) acc))
    '() credentials))

(define (in-ts-range? cred from-ts to-ts)
  "True iff CRED has a timestamp within [from-ts, to-ts]. #f bounds
   are treated as open ends."
  (let ((ts (cred-timestamp cred)))
    (and ts
         (or (not from-ts) (>= ts from-ts))
         (or (not to-ts)   (<= ts to-ts)))))

(define (timestamp-sorted creds)
  "Sort ascending by cred-timestamp. Callers must filter out #f
   timestamps first."
  (sort creds (lambda (a b) (< (cred-timestamp a) (cred-timestamp b)))))

;; A query over the STORE, in the store's own vocabulary — so it lives here,
;; beside the other reads, rather than in recovery.scm where it was written.
;; first-person.scm's lineage walk asks the same question, and reaching into
;; recovery.scm for it made two files that each needed the other.
(define (non-revoked-by-schema acdc-store schema)
  "The live credentials of one SCHEMA in the store — every credential of that
   schema that carries no revocation. A store is any actor answering 'all."
  (filter (lambda (c) (and (equal? (cred-schema c) schema)
                           (not (cred-revoked? c))))
          ($ acdc-store 'all)))


(define* (spawn-acdc-store #:key (no-op? #f) (durable-dir #f))
  "Spawn an ^acdc-store. If #:no-op? is #t, calls succeed but nothing is
   stored. If #:durable-dir is a path, the store writes through to disk
   and replays any existing credentials + revocations from that path on
   startup — survives process death."
  (cond
    ((or no-op? (not durable-dir))
     (spawn ^acdc-store (hashmap) no-op? (hashmap) durable-dir))
    (else
     (durable-ensure-dir! durable-dir)
     (let* ((creds-list (durable-load-creds durable-dir))
            (revokes    (durable-load-revokes durable-dir))
            (revoked-saids (map car revokes))
            (creds (fold (lambda (c acc)
                           (let ((said (cred-said c)))
                             (hashmap-set acc said
                                          (if (member said revoked-saids)
                                              (cred-with-revoked c #t)
                                              c))))
                         (hashmap) creds-list))
            (idx (hashmap-fold
                   (lambda (_k c acc) (index-add-cred acc c))
                   (hashmap) creds)))
       (spawn ^acdc-store creds no-op? idx durable-dir)))))
