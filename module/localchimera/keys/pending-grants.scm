;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/keys/pending-grants.scm — durable retry queue
;;;
;;; Generic at-least-once delivery for outbound work that can't be
;;; recovered from elsewhere (i.e. KERIA was unreachable when we tried
;;; to issue + grant a credential; the local store has the credential
;;; but the destination doesn't yet). Two enqueue sources today:
;;;
;;;   - ^keria-acdc-store's failed `acdc-grant` (umbrella-signed
;;;     governance grants) — kind = 'umbrella-grant
;;;   - scope-exchange's failed `scope-issue-grant!` (scope-AID-signed
;;;     IPEX grants for cross-gateway federation membership and
;;;     similar) — kind = 'scope-grant
;;;
;;; Each enqueued entry is a `<pending-grant>` record: an opaque
;;; kind-tag plus an alist of payload fields. A replay-fn table maps
;;; kind → (lambda (payload) → bool) that knows how to retry that kind.
;;; Modules register their replay fn at load time.
;;;
;;; Persistence: optional `#:persist-file PATH` makes the actor write
;;; the queue to PATH on every mutation. Survives gateway restart. The
;;; format is a single S-expression per entry (one (kind . payload)
;;; pair per line) so the file is grep/cat-friendly for operators.
;;;
;;; Goblins note: this is a `define*` constructor (returns a methods
;;; bundle directly) rather than `define-actor`, because `define-actor`
;;; doesn't accept #:optional / #:key args — same pattern as
;;; ^scope-graph and ^keria-acdc-store.

(define-module (localchimera keys pending-grants)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module ((localchimera utils common) #:select (read-all-sexps-file))
  #:use-module ((localchimera utils boot-cell) #:select (make-boot-cell))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 rdelim)
  #:export (make-pending-grant
            pending-grant?
            pending-grant-kind
            pending-grant-payload
            register-replay-fn!
            replay-pending-grant
            ^pending-grants
            spawn-pending-grants
            current-pending-grants))

;; ─────────────────────────────────────────────────────────────────────────
;; Record
;; ─────────────────────────────────────────────────────────────────────────

(define-record-type <pending-grant>
  (make-pending-grant kind payload)
  pending-grant?
  (kind    pending-grant-kind)      ; symbol
  (payload pending-grant-payload))  ; serializable alist

(define (pending-grant->sexp pg)
  (cons (pending-grant-kind pg) (pending-grant-payload pg)))

(define (sexp->pending-grant sexp)
  (and (pair? sexp) (symbol? (car sexp))
       (make-pending-grant (car sexp) (cdr sexp))))

;; ─────────────────────────────────────────────────────────────────────────
;; Replay dispatch table — modules register at load time
;; ─────────────────────────────────────────────────────────────────────────

(define %replay-fns '())

(define (register-replay-fn! kind fn)
  "Register FN as the replayer for entries of KIND. FN takes a payload
   alist and returns #t on success / #f on transient failure (keep in
   queue). Idempotent — replaces any prior fn for KIND."
  (set! %replay-fns
        (cons (cons kind fn)
              (filter (lambda (p) (not (eq? kind (car p))))
                      %replay-fns))))

(define (replay-pending-grant pg)
  "Try to replay PG. Returns #t on success, #f if the fn errored or
   returned #f, #f also if no replay fn is registered for that kind
   (logged so we notice misconfigurations)."
  (let ((fn (assoc-ref %replay-fns (pending-grant-kind pg))))
    (cond
     ((not fn)
      (format (current-error-port)
              "[pending-grants] no replay fn for kind ~a; entry stuck~%"
              (pending-grant-kind pg))
      #f)
     (else
      (catch #t
        (lambda () (and (fn (pending-grant-payload pg)) #t))
        (lambda (key . args)
          (format (current-error-port)
                  "[pending-grants] replay failed for ~a: ~a ~a~%"
                  (pending-grant-kind pg) key args)
          #f))))))

;; ─────────────────────────────────────────────────────────────────────────
;; Disk persistence
;; ─────────────────────────────────────────────────────────────────────────

(define (write-pending-file! path items)
  "Atomic-ish write: tmp + rename. ITEMS is a list of pending-grant
   records. Format is one S-expression per line."
  (let ((tmp (string-append path ".tmp")))
    (call-with-output-file tmp
      (lambda (port)
        (for-each (lambda (pg)
                    (pretty-print (pending-grant->sexp pg) port)
                    (newline port))
                  items)))
    (rename-file tmp path)))

(define (read-pending-file path)
  "Returns the list of pending-grant records persisted at PATH, or '()
   if the file doesn't exist / is empty / contains garbage.
   Built on read-all-sexps-file + sexp->pending-grant; invalid entries
   are silently dropped (filter-map's #f-elision)."
  (filter-map sexp->pending-grant (read-all-sexps-file path)))

;; ─────────────────────────────────────────────────────────────────────────
;; Actor
;; ─────────────────────────────────────────────────────────────────────────

(define* (^pending-grants bcom
                          #:optional
                          (items        '())
                          (persist-file #f))

  (define (persist! xs)
    (when persist-file (write-pending-file! persist-file xs)))

  (methods

    ((enqueue pg)
     (unless (pending-grant? pg)
       (error "^pending-grants: enqueue expects a <pending-grant>"))
     (let ((new (cons pg items)))
       (persist! new)
       (bcom (^pending-grants bcom new persist-file))))

    ((all)         items)
    ((count)       (length items))

    ((drain!)
     "Retry every entry. Returns (cons drained still-pending) and
      rebuilds with the reduced list. Order-preserving: oldest first."
     (let loop ((todo (reverse items)) (kept '()) (drained 0))
       (cond
        ((null? todo)
         (let ((remaining (reverse kept)))
           (persist! remaining)
           (bcom (^pending-grants bcom remaining persist-file)
                 (cons drained (length remaining)))))
        (else
         (cond
          ((replay-pending-grant (car todo))
           (loop (cdr todo) kept (+ drained 1)))
          (else
           (loop (cdr todo) (cons (car todo) kept) drained)))))))

    ((clear!)
     "Drop every pending entry without retrying. Operator escape hatch."
     (persist! '())
     (bcom (^pending-grants bcom '() persist-file)))

    ((confirm-delivered! cred-said)
     "Remove any entry whose payload carries `cred-said = CRED-SAID`.
      Called by the inbound admit handler when the recipient
      acknowledges a grant: we know it landed, so the pending entry
      is moot. Eager cleanup is an optimisation — the next drain
      would also discard a successfully-retried entry — but it keeps
      the queue small in steady state."
     (let* ((kept    (remove (lambda (pg)
                               (equal? cred-said
                                       (assoc-ref (pending-grant-payload pg)
                                                  'cred-said)))
                             items))
            (removed (- (length items) (length kept))))
       (when (> removed 0) (persist! kept))
       (bcom (^pending-grants bcom kept persist-file) removed)))))

(define* (spawn-pending-grants #:key (persist-file #f))
  "Spawn an ^pending-grants actor. When PERSIST-FILE is given, the queue
   is read from disk at startup and written back on every mutation —
   so the queue survives gateway restarts spanning a KERIA outage."
  (let ((restored (if persist-file (read-pending-file persist-file) '())))
    (spawn ^pending-grants restored persist-file)))

;; The gateway sets this at boot to the shared queue ref. Modules that
;; produce deferred grants (keria-store on `acdc-grant` failure,
;; scope-exchange on `scope-issue-grant!` failure) consult it and
;; enqueue. Unbound → caller's catch-and-log path runs and the entry
;; is dropped (acceptable for tests; production gateways always set it).
;; A boot cell, NOT a parameter: vats spawned before the boot-time set
;; would never see a parameter's value (per-dynamic-state inheritance
;; — the spawn-order landmine boot-cell.scm documents).
(define current-pending-grants (make-boot-cell))
