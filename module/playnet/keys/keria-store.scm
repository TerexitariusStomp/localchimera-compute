;;; module/playnet/keys/keria-store.scm — KERIA-backed ACDC store
;;;
;;; Phase-2 implementation of the ^acdc-store interface. Same methods as
;;; the in-memory ^acdc-store in acdc-store.scm, but persists credentials
;;; through KERIA via (playnet keri credentials) and (playnet keri bridge).
;;;
;;; Maintains a local cache (hashmap SAID → credential alist) for fast
;;; reads. Writes go to both the cache and KERIA. The cache is the
;;; primary read path; `sync!` repopulates it from KERIA on recovery.
;;;
;;; Usage:
;;;   (use-modules (playnet keys keria-store))
;;;   (with-vat vat
;;;     (define store (spawn-keria-acdc-store "governance" "E_holder_aid")))
;;;
;;; The issuer-aid-name is the local KERIA AID name (e.g. "governance").
;;; KERIA must be booted (keri-boot! or keri-connect!) before issuing.

(define-module (playnet keys keria-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet keri credentials)
  #:use-module (playnet keri bridge)
  #:use-module (playnet utils paths)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keys pending-grants)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((playnet utils clock) #:select ((now . clock-now)))   ; the one clock: instants inside
  #:use-module ((playnet utils paths) #:select (scope-state-dir))
  #:export (^keria-acdc-store
            spawn-keria-acdc-store
            keria-acdc-store-env
            keria-cred->governance-cred))

;; Replay fn for umbrella-grant entries. Registered at load time so
;; the unified pending-grants queue's drain can retry an `acdc-grant`
;; call that originally failed because KERIA was unreachable.
(define (%home-holder? holder)
  "Whether HOLDER is a scope this gateway runs durably: its state dir
   is on disk. Such a scope's credentials are issued into its own
   acdc-store, and no scope of ours reads a KERIA mailbox, so an IPEX
   grant to it addresses nobody — delivery is complete at issue. The
   founding commune and the universal commune are the standing cases."
  (and (string? holder)
       (let ((dir (scope-state-dir holder)))
         (and (file-exists? dir) (file-is-directory? dir)))))

(register-replay-fn!
 'umbrella-grant
 (lambda (payload)
   (let ((issuer (assoc-ref payload 'issuer-aid-name))
         (said   (assoc-ref payload 'said))
         (holder (assoc-ref payload 'holder)))
     ;; A holder whose OOBI missed within the TTL cannot take a grant
     ;; yet (KERIA refuses an AID it has never seen), so the entry waits
     ;; for the next pass at no cost — a pass over a hundred such entries
     ;; is one skipped read each, not one KERIA exchange each. A holder
     ;; that is home already leaves the queue as delivered.
     (and issuer said holder
          (or (%home-holder? holder)
              (and (not (%holder-oobi-missed? holder))
          (catch #t
            (lambda () (acdc-grant issuer said holder) #t)
            ;; Same first-contact rule as %try-grant: an unknown-AID
            ;; refusal means KERIA has never seen the holder — resolve
            ;; their OOBI from our own static tier and retry once.
            (lambda _
              (and (%resolve-holder-oobi! holder)
                   (begin (acdc-grant issuer said holder) #t))))))))))


(define (%edges-with-keria-schemas edges)
  "Map each edge spec's `s` (governance version-string label) to its
   saidified KERIA schema SAID — ACDC requires an edge's `s` to be the
   far credential's schema SAID. Labels with no KERIA schema pass
   through unchanged (same rule as the credential's own `s`)."
  (map (lambda (entry)
         (cons (car entry)
               (map (lambda (p)
                      (if (and (eq? (car p) 's) (string? (cdr p)))
                          (cons 's (or (governance-schema->keria-said (cdr p))
                                       (cdr p)))
                          p))
                    (cdr entry))))
       edges))

(define (%issue-to-keria! issuer-aid-name cred)
  "Translate CRED across the governance→KERIA boundary and issue it:
   version-string schema labels become saidified schema SAIDs (on the
   credential's own `s` and on every edge's `s` — ACDC requires both to
   be SAIDs), symbol claim keys become strings. Returns the
   KERIA-authoritative credential SAID. The ONE translation site — both
   issue methods go through here, so they cannot drift."
  (let ((schema (or (governance-schema->keria-said (cred-schema cred))
                    (cred-schema cred)))
        (claims (map (lambda (p) (cons (symbol->string (car p)) (cdr p)))
                     (cred-claims cred)))
        (edges  (%edges-with-keria-schemas (cred-edges cred))))
    (acdc-issue issuer-aid-name (cred-holder cred) schema claims
                #:edges edges)))

(define (%keria-edges->governance-edges e-block)
  "Convert a KERIA-shaped `e` block (string-keyed) back to the governance
   edge alist (symbol-keyed). Strips the block-level `d` SAID."
  (cond
    ((or (not e-block) (null? e-block)) '())
    (else
     (filter-map
       (lambda (p)
         (and (string? (car p))
              (not (equal? "d" (car p)))
              (let ((spec (cdr p)))
                (cons (string->symbol (car p))
                      (filter-map
                        (lambda (q)
                          (case (string->symbol (car q))
                            ((n) (cons 'n (cdr q)))
                            ;; re-label edge schemas symmetrically with the
                            ;; credential's own `s` (see keria-cred->governance-cred)
                            ((s) (cons 's (or (keria-said->governance-schema (cdr q))
                                              (cdr q))))
                            ((o) (cons 'o (if (string? (cdr q))
                                              (string->symbol (cdr q))
                                              (cdr q))))
                            (else #f)))
                        spec)))))
       e-block))))

(define (%cred-with-overrides cred said revoked?)
  "Override SAID and revoked? on an already-constructed credential. Used
   when the authoritative SAID comes from a KERIA round-trip and differs
   from our locally computed one (they *should* match once compute-said
   and build-acdc share serialization, but until then we defer to KERIA)."
  (map (lambda (entry)
         (case (car entry)
           ((said)     (cons 'said said))
           ((revoked?) (cons 'revoked? revoked?))
           (else entry)))
       cred))

(define (keria-cred->governance-cred keria-cred)
  "Convert a KERIA credential alist to the governance credential format.
   Preserves edges from the ACDC `e` block."
  (let* ((sad      (assoc-ref keria-cred "sad"))
         (said     (or (assoc-ref sad "d") (assoc-ref keria-cred "said")))
         ;; sad.s is the schema SAID on the KERIA side; governance
         ;; predicates query by version-string label, so re-label on the
         ;; way in (SAIDs with no label — role credentials — stay as-is).
         (schema   (let ((s (assoc-ref sad "s")))
                     (or (keria-said->governance-schema s) s)))
         (issuer   (assoc-ref sad "i"))
         (attrs    (assoc-ref sad "a"))
         (holder   (and attrs (assoc-ref attrs "i")))
         (e-block  (assoc-ref sad "e"))
         (edges    (%keria-edges->governance-edges e-block))
         (status   (assoc-ref keria-cred "status"))
         (claims   (if attrs
                       (filter (lambda (p)
                                 (not (member (car p) '("d" "i" "dt"))))
                               attrs)
                       '()))
         (cred     (make-credential schema issuer holder claims edges)))
    (%cred-with-overrides cred said (equal? status "revoked"))))


(define %holder-oobi-miss-ttl 600)
(define %holder-oobi-misses '())   ; holder → the instant its miss expires

(define (%holder-oobi-missed? holder)
  "Whether HOLDER's controller OOBI came back unresolvable within the
   last %holder-oobi-miss-ttl seconds. A drain pass retries every
   deferred grant, and one holder can own a hundred of them; the first
   miss answers for the whole pass and the next ten minutes of passes."
  (let ((until (assoc-ref %holder-oobi-misses holder)))
    (and until (< (clock-now) until))))

(define (%note-holder-oobi-miss! holder why)
  "Record that HOLDER's OOBI is unresolvable for now, saying WHY once."
  (format (current-error-port)
          "[keria-store] holder OOBI unresolvable for ~as (~a): ~a~%"
          %holder-oobi-miss-ttl holder why)
  (set! %holder-oobi-misses
        (cons (cons holder (+ (clock-now) %holder-oobi-miss-ttl))
              (filter (lambda (p) (not (equal? (car p) holder)))
                      %holder-oobi-misses)))
  #f)

(define (%resolve-holder-oobi! holder)
  "Make HOLDER kev-known to KERIA by resolving its controller OOBI from
   our own static tier (the oobi-host serves every registered citizen's
   KEL at /oobi/{aid} — the same self-hosted base PLAYNET_SCHEMA_SERVER
   names for schemas). #t on a completed resolve; #f when the env is
   unset, the AID is unknown to the oobi-host, or the resolve times out.

   The oobi-host is asked first (one round trip) and KERIA only when it
   serves the KEL: a resolve of a URL the host answers 404 to stays open
   in KERIA until the timeout below, and the founder and commune AIDs
   (KELs held in the browser and the scope store, mirrored to no host
   entry) had a gateway waiting 15 s apiece, 136 times a pass. A miss
   is remembered per holder for %holder-oobi-miss-ttl seconds."
  (let ((server (getenv "PLAYNET_SCHEMA_SERVER")))
    (and server
         (not (%holder-oobi-missed? holder))
         (let ((url (string-append server "/oobi/" holder)))
           (if (eqv? 200 (keri-url-status url))
               (catch #t
                 (lambda ()
                   (keri-wait-operation (keri-resolve-oobi url) #:timeout 15)
                   #t)
                 (lambda _ (%note-holder-oobi-miss! holder "resolve timed out")))
               (%note-holder-oobi-miss! holder "no KEL at the oobi-host"))))))

(define (%try-grant issuer-aid-name said holder)
  "Attempt acdc-grant. KERIA refuses a grant to an AID it has never
   seen — first time a citizen receives anything, resolve their OOBI
   from our own static tier and retry once. On remaining failure,
   enqueue to the unified ^pending-grants queue (if bound) so the
   gateway's drain machinery retries on the next tick or KERIA
   reconnect. Errors are intentionally swallowed — the issue itself
   succeeded locally; only delivery to the holder's mailbox failed.
   A holder that is a scope of this gateway (%home-holder?) is home at
   issue and takes no mailbox delivery at all."
  (or (%home-holder? holder)
  (catch #t
    (lambda () (acdc-grant issuer-aid-name said holder) #t)
    (lambda (_key . _args)
      (catch #t
        (lambda ()
          (unless (%resolve-holder-oobi! holder)
            (error "holder OOBI unresolved" holder))
          (acdc-grant issuer-aid-name said holder)
          #t)
        (lambda (key . args)
          (format (current-error-port)
                  "[keria-store] grant deferred (~a → ~a): ~a ~a~%"
                  said holder key args)
          (let ((q (current-pending-grants)))
            (when q
              (<- q 'enqueue
                  (make-pending-grant
                   'umbrella-grant
                   `((issuer-aid-name . ,issuer-aid-name)
                     (said            . ,said)
                     (holder          . ,holder))))))
          #f))))))

(define-actor (^keria-acdc-store bcom cache issuer-aid-name)
  ;; cache:           hashmap SAID → governance credential alist (local mirror)
  ;; issuer-aid-name: local KERIA AID name for issuance
  ;;
  ;; Failed grants are enqueued to the unified ^pending-grants actor
  ;; (see module/playnet/keys/pending-grants.scm) rather than
  ;; carried in-actor — that queue is persisted to disk and drained
  ;; by the gateway, so umbrella-grant deliveries survive a KERIA
  ;; outage that bridges a gateway restart.
  (methods

    ;; --- Writes ---

    ((issue cred)
     (let ((keria-said (%issue-to-keria! issuer-aid-name cred)))
       (%try-grant issuer-aid-name keria-said (cred-holder cred))
       (let ((updated-cred (%cred-with-overrides cred keria-said #f)))
         (bcom (^keria-acdc-store bcom
                                  (hashmap-set cache keria-said updated-cred)
                                  issuer-aid-name)
               keria-said))))

    ((revoke said)
     (let ((existing (hashmap-ref cache said #f)))
       (unless existing
         (error "Cannot revoke unknown SAID" said))
       (keri-delete-credential said)
       (bcom (^keria-acdc-store bcom
                                (hashmap-set cache said
                                             (cred-with-revoked existing #t))
                                issuer-aid-name))))

    ;; --- Reads (from local cache) ---

    ((get said) (hashmap-ref cache said #f))

    ((all)
     (hashmap-fold (lambda (_k v acc) (cons v acc)) '() cache))

    ((by-schema schema)
     (hashmap-fold
       (lambda (_k v acc)
         (if (equal? schema (cred-schema v)) (cons v acc) acc))
       '() cache))

    ((by-holder aid)
     (hashmap-fold
       (lambda (_k v acc)
         (if (equal? aid (cred-holder v)) (cons v acc) acc))
       '() cache))

    ((by-issuer aid)
     (hashmap-fold
       (lambda (_k v acc)
         (if (equal? aid (cred-issuer v)) (cons v acc) acc))
       '() cache))

    ((non-revoked)
     (hashmap-fold
       (lambda (_k v acc)
         (if (cred-revoked? v) acc (cons v acc)))
       '() cache))

    ;; --- Indexed reads (linear scan over cache; fine since cache is local) ---
    ;; Production scale would mirror in-memory store's typed indexes.
    ;; Current implementation: filter cache by (schema, claim-key, value).

    ((by-claim schema claim-key value)
     (hashmap-fold
       (lambda (_k cred acc)
         (if (and (equal? schema (cred-schema cred))
                  (equal? value (cred-claim cred claim-key)))
             (cons cred acc)
             acc))
       '() cache))

    ((by-claim-1 schema claim-key value)
     (hashmap-fold
       (lambda (_k cred found)
         (or found
             (and (not (cred-revoked? cred))
                  (equal? schema (cred-schema cred))
                  (equal? value (cred-claim cred claim-key))
                  cred)))
       #f cache))

    ((issue-idempotent cred)
     ;; KERIA dedupes by SAID server-side. Local cache check first.
     (let ((said (cred-said cred)))
       (cond
         ((hashmap-ref cache said #f) said)
         (else
          (let ((keria-said (%issue-to-keria! issuer-aid-name cred)))
            (%try-grant issuer-aid-name keria-said (cred-holder cred))
            (let ((updated (%cred-with-overrides cred keria-said #f)))
              (bcom (^keria-acdc-store bcom
                                       (hashmap-set cache keria-said updated)
                                       issuer-aid-name)
                    keria-said)))))))

    ((no-op?) #f)

    ;; --- KERIA-specific ---

    ((sync!)
     "Repopulate cache from KERIA. Call after recovery-reconnect!."
     (let loop ((skip 0) (acc (hashmap)))
       (let ((batch (keri-list-credentials #:skip skip #:limit 100)))
         (if (or (not batch) (null? batch) (and (vector? batch) (= 0 (vector-length batch))))
             (bcom (^keria-acdc-store bcom acc issuer-aid-name)
                   (hashmap-fold (lambda (_k _v n) (+ n 1)) 0 acc))
             (let* ((creds (if (vector? batch) (vector->list batch) batch))
                    (new-acc (fold (lambda (kc a)
                                    (let ((gc (keria-cred->governance-cred kc)))
                                      (hashmap-set a (cred-said gc) gc)))
                                  acc creds)))
               (loop (+ skip (length creds)) new-acc))))))

    ((issuer-aid-name) issuer-aid-name)))


(define (spawn-keria-acdc-store issuer-aid-name)
  "Spawn a KERIA-backed ^acdc-store. issuer-aid-name is the local AID
   name in KERIA used for credential issuance."
  (spawn ^keria-acdc-store (hashmap) issuer-aid-name))


(define keria-acdc-store-env
  (make-persistence-env
    `((((playnet keys keria-store) ^keria-acdc-store)
       ,^keria-acdc-store))))
