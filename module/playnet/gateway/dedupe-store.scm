;;; dedupe-store.scm — gateway-side idempotency for queued client writes
;;;
;;; Phase 1 of docs/planning/faces/offline-outbox.md: "Every queued write carries
;;; a client-minted opId, and the gateway records the ids it has already
;;; applied per AID, returning the original result on a replay." Without
;;; this, a flush over a flaky link double-applies — the same failure class
;;; this codebase has hit twice before (payout reconcile double-settle;
;;; record-purchase's timestamp-only id — see
;;; [[project_payout_reconcile_double_settle]]). Those were both bespoke
;;; id-minting fixes (a counter-suffixed id disambiguates two same-instant
;;; events); this is a different shape of problem — caching a prior
;;; RESULT, not minting a unique id — so it gets its own small store rather
;;; than reusing that pattern.
;;;
;;; Modeled on ^kel-store (module/playnet/governance/kel-store.scm):
;;; content-addressed via (playnet utils said-store), #:portrait/#:restore,
;;; durable disk writes so a replay stays deduped across a gateway restart,
;;; not just within one process's lifetime. Unlike a KEL, dedupe entries
;;; have no ordering requirement — said-store-scan's "unspecified order" is
;;; fine here, never a bug.
;;;
;;; Phase 1 is this mechanism alone, proven correct in Guile — see
;;; tests/gateway/test-dedupe-store.scm. Routing the gateway's Class-A
;;; write doors through it is phase 3 ("the seam") in the outbox doc, a
;;; separate, later piece of work: those doors are declared in (playnet
;;; protocol) and declared-methods (playnet protocol dispatch) refuses to
;;; boot on any drift between a door's code arity and its declaration, so
;;; wiring opId through them touches the protocol declarations for each
;;; one — deliberately out of scope for the correctness foundation itself.

(define-module (playnet gateway dedupe-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils said-store)
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module ((playnet keri cesr) #:select (bytevector-append))
  #:use-module (rnrs bytevectors)
  #:export (^dedupe-store spawn-dedupe-store dedupe-store-env))

;; A shard-friendly, unambiguous key for (AID . OP-ID): hex-encode the two
;; byte-strings joined by a NUL byte (not a string separator), so neither
;; string's content — an AID or a client-chosen opId, both arbitrary from
;; this module's point of view — can forge a collision with a different
;; pair by containing the separator itself. No hashing (and so no
;; dependency on a KERI crypto backend being installed) — a dedupe key
;; only needs to be unambiguous, not collision-resistant against an
;; adversary; the longer on-disk filename is a fine trade for that.
(define (op-key aid op-id)
  (bv->hex (bytevector-append (string->utf8 aid) #vu8(0) (string->utf8 op-id))))

(define (load-seen-from-disk dir)
  "Every {key . result} record under DIR, as a hashmap. said-store-scan's
   order is unspecified, which is fine — dedupe only needs presence and
   the cached value, never replay order."
  (fold (lambda (rec h) (hashmap-set h (car rec) (cdr rec)))
        (hashmap)
        (said-store-scan dir)))

(define %not-found (list 'dedupe-store-not-found))

(define-actor (^dedupe-store bcom
                             seen          ;; hashmap op-key → cached result
                             durable-dir)  ;; #f, or a directory path

  #:portrait
  (lambda () (list seen durable-dir))

  #:version 1

  #:restore
  (lambda (version _seen dir)
    (case version
      ;; Re-derive SEEN from disk rather than trusting the portrait's own
      ;; snapshot of it — durable-dir is the source of truth once it
      ;; exists, and a portrait taken between a write's disk flush and its
      ;; next snapshot could otherwise lag it.
      ((1) (spawn ^dedupe-store (load-seen-from-disk dir) dir))
      (else (error "Unknown ^dedupe-store version" version))))

  (methods
   ((check-or-record! aid op-id thunk)
    ;; If (AID . OP-ID) was seen before, return the cached result WITHOUT
    ;; calling THUNK again — the whole point: a flush that replays a
    ;; write must never re-apply it. Otherwise call THUNK once, cache and
    ;; persist its result, and return it.
    (let* ((key    (op-key aid op-id))
           (cached (hashmap-ref seen key %not-found)))
      (if (not (eq? cached %not-found))
          cached
          (let ((result (thunk)))
            (said-store-write! durable-dir key (cons key result))
            (bcom (^dedupe-store bcom (hashmap-set seen key result) durable-dir)
                  result)))))

   ;; Read-only: has (AID . OP-ID) already been recorded? Lets a caller
   ;; check without risking a THUNK side effect (e.g. a dry-run flush).
   ((seen? aid op-id)
    (not (eq? %not-found (hashmap-ref seen (op-key aid op-id) %not-found))))))

(define* (spawn-dedupe-store #:key (durable-dir #f))
  "Create a dedupe-store. Must be called within a vat. DURABLE-DIR, when
   given, makes dedup survive a gateway restart; #f is a pure in-memory
   store (fine for tests)."
  (spawn ^dedupe-store (load-seen-from-disk durable-dir) durable-dir))

(define dedupe-store-env
  (make-persistence-env
    `((((playnet gateway dedupe-store) ^dedupe-store) ,^dedupe-store))))
