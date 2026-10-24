;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/keys/keria-store.scm — the credential store with KERIA as the store of record
;;;
;;; ^acdc-store (keri/acdc-store.scm) holds the credentials, their typed claim
;;; indexes and the durable directory; this actor stands in front of it and
;;; adds the three effects KERIA brings: an issue goes to KERIA first and the
;;; credential is kept under the SAID KERIA answers, an IPEX grant reaches the
;;; holder (or waits in ^pending-grants), a revoke deletes in KERIA. Every
;;; other door is the inner store's, so the two modes of a gateway answer one
;;; method set, and `sync!` is an import of what KERIA lists.
;;;
;;; Usage:
;;;   (use-modules (localchimera keys keria-store))
;;;   (with-vat vat
;;;     (define store (spawn-keria-acdc-store "governance" #:durable-dir dir)))
;;;
;;; The issuer-aid-name is the local KERIA AID name (e.g. "governance").
;;; KERIA must be booted (keri-boot! or keri-connect!) before issuing.

(define-module (localchimera keys keria-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera keri credentials)
  #:use-module (localchimera keri bridge)
  #:use-module (localchimera utils paths)
  #:use-module (localchimera keri acdc)
  #:use-module ((localchimera keri acdc-store) #:select (spawn-acdc-store))
  #:use-module (localchimera keys pending-grants)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((localchimera utils clock) #:select ((now . clock-now)))   ; the one clock: instants inside
  #:use-module ((localchimera utils paths) #:select (scope-state-dir))
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
   KEL at /oobi/{aid} — the same self-hosted base LOCALCHIMERA_SCHEMA_SERVER
   names for schemas). #t on a completed resolve; #f when the env is
   unset, the AID is unknown to the oobi-host, or the resolve times out.

   The oobi-host is asked first (one round trip) and KERIA only when it
   serves the KEL: a resolve of a URL the host answers 404 to stays open
   in KERIA until the timeout below, and the founder and commune AIDs
   (KELs held in the browser and the scope store, mirrored to no host
   entry) had a gateway waiting 15 s apiece, 136 times a pass. A miss
   is remembered per holder for %holder-oobi-miss-ttl seconds."
  (let ((server (getenv "LOCALCHIMERA_SCHEMA_SERVER")))
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

(define-actor (^keria-acdc-store bcom inner issuer-aid-name)
  ;; inner:           the ^acdc-store that holds the credentials
  ;; issuer-aid-name: local KERIA AID name for issuance
  ;;
  ;; Failed grants are enqueued to the unified ^pending-grants actor
  ;; (see module/localchimera/keys/pending-grants.scm) rather than
  ;; carried in-actor — that queue is persisted to disk and drained
  ;; by the gateway, so umbrella-grant deliveries survive a KERIA
  ;; outage that bridges a gateway restart.
  #:version 2
  #:portrait (lambda () (list inner issuer-aid-name))
  #:restore (lambda (version . args)
              (case version
                ((2) (apply spawn ^keria-acdc-store args))
                (else (error "^keria-acdc-store: a cache-shaped portrait does not restore" version))))

  ;; KERIA first: the credential stands under the SAID KERIA answers
  (define (issue-through-keria! cred)
    (let ((keria-said (%issue-to-keria! issuer-aid-name cred)))
      (%try-grant issuer-aid-name keria-said (cred-holder cred))
      ;; idempotent under KERIA's SAID: KERIA dedupes by SAID server-side
      ($ inner 'issue-idempotent (%cred-with-overrides cred keria-said #f))))

  (lambda (method . args)
    (case method
      ((issue) (issue-through-keria! (car args)))
      ((issue-idempotent)
       ;; KERIA dedupes by SAID server-side; the inner store first
       (let ((said (cred-said (car args))))
         (if ($ inner 'get said) said (issue-through-keria! (car args)))))
      ((revoke)
       (let ((said (car args)))
         (unless ($ inner 'get said) (error "Cannot revoke unknown SAID" said))
         (keri-delete-credential said)
         ($ inner 'revoke said)))
      ;; --- KERIA-specific ---
      ((sync!)
       ;; what KERIA lists, imported; answers how many it holds
       (let loop ((skip 0) (n 0))
         (let ((batch (keri-list-credentials #:skip skip #:limit 100)))
           (if (or (not batch) (null? batch) (and (vector? batch) (= 0 (vector-length batch))))
               n
               (let ((creds (if (vector? batch) (vector->list batch) batch)))
                 (for-each (lambda (kc) ($ inner 'issue-idempotent (keria-cred->governance-cred kc)))
                           creds)
                 (loop (+ skip (length creds)) (+ n (length creds))))))))
      ((issuer-aid-name) issuer-aid-name)
      ((inner-store) inner)
      (else (apply $ inner method args)))))


(define* (spawn-keria-acdc-store issuer-aid-name #:key (durable-dir #f))
  "Spawn the credential store with KERIA as its store of record over an
   ^acdc-store, durable under DURABLE-DIR when given. ISSUER-AID-NAME is
   the local AID name in KERIA used for credential issuance."
  (spawn ^keria-acdc-store (spawn-acdc-store #:durable-dir durable-dir) issuer-aid-name))


(define keria-acdc-store-env
  (make-persistence-env
    `((((localchimera keys keria-store) ^keria-acdc-store)
       ,^keria-acdc-store))))
