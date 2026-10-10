;;; module/playnet/boot/grants.scm — the pending-grants vat: outbound IPEX grants that wait for KERIA, and the finders an inbound apply or agree reads.

(define-module (playnet boot grants)
  #:use-module ((playnet boot site) #:select (data-path log!))
  #:use-module ((playnet federation scope-graph) #:select (current-scope-graph in-graph-vat))
  #:use-module ((playnet keri acdc) #:select (cred-holder cred-revoked?))
  #:use-module ((playnet keri keria-reconnect) #:select (register-reconnect-hook!))
  #:use-module ((playnet federation ipex-policy) #:select (current-credential-finder current-credential-finder-by-said))
  #:use-module ((playnet keys pending-grants) #:select (current-pending-grants spawn-pending-grants))
  #:use-module ((playnet utils paths) #:select (playnet-state-dir))
  #:use-module (fibers)
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((srfi srfi-1) #:select (any find))
  #:export (start-pending-grants!))

;; ── Pending-grants queue (durable scope-side retry) ────────────
;; Holds outbound scope-AID-signed IPEX grants that failed
;; delivery (KERIA was momentarily unreachable, OOBI not yet
;; resolved, etc.). Persisted to disk so a gateway restart
;; mid-outage doesn't drop deliveries on the floor. The drain
;; fiber replays entries every 60s and on KERIA-reconnect.
(define (start-pending-grants! planner-vat store)
  "The queue in its vat, the credential finders over STORE and every scope's
store, the drain fiber and the reconnect-edge drain."
  (define pending-grants-vat (spawn-vat #:name "pending-grants"))
  ;; Same PLAYNET_DATA_DIR convention as every other gateway-owned
  ;; file (this was the one straggler in the XDG state dir). A queue
  ;; persisted at the old location migrates in once — retry entries
  ;; must survive the path change the same way they survive restarts.
  (define pending-grants-file (data-path "keys/pending-grants.scm"))
  (let ((old (string-append (playnet-state-dir) "/pending-grants.scm")))
    (when (and (file-exists? old) (not (file-exists? pending-grants-file)))
      (catch #t
        (lambda ()
          (copy-file old pending-grants-file)
          (delete-file old)
          (log! "  [gateway] pending-grants queue migrated from ~a~%" old))
        (lambda (k . a)
          (log! "  [gateway] pending-grants migration failed: ~a ~a~%" k a)))))
  (define pending-grants-ref
    (with-vat pending-grants-vat
      (spawn-pending-grants #:persist-file pending-grants-file)))
  (current-pending-grants pending-grants-ref)
  (log! "  [gateway] pending-grants: ~a entries restored from ~a~%"
         (with-vat pending-grants-vat ($ pending-grants-ref 'count))
         pending-grants-file)

  ;; ── Credential finders for inbound /exn/ipex/{apply,agree} ─────
  ;; Both finders search the same stores in the same order — the
  ;; gateway's governance store first, then every scope's store via
  ;; the scope graph — and differ only in what they ask of each
  ;; store. ONE walk, two lookups. Graph reads enter the graph's own
  ;; vat (in-graph-vat); the refs it returns are commune scopes
  ;; living in planner-vat, read there. #f (nothing found, or any
  ;; store unreachable) means spurn/refuse — refusal is the default.
  (define (find-in-credential-stores lookup)
    ;; lookup: acdc-store ref → cred | #f, called inside planner-vat
    (catch #t
      (lambda ()
        (or (with-vat planner-vat (lookup store))
            (let ((g (current-scope-graph)))
              (and g
                   (any (lambda (aid)
                          (let ((ref (in-graph-vat
                                      (lambda () ($ g 'find-ref aid)))))
                            (and ref
                                 (let ((store (with-vat planner-vat
                                                ($ ref 'acdc-store))))
                                   (and store
                                        (with-vat planner-vat
                                          (lookup store)))))))
                        (in-graph-vat (lambda () ($ g 'all-aids))))))))
      (lambda _ #f)))

  ;; apply-side: "a non-revoked credential matching SCHEMA where
  ;; REQUESTER could plausibly be the holder" (first hit, FIFO
  ;; by-schema order). agree-side: the exact credential by SAID —
  ;; the grant must produce what the apply-side offered, and a
  ;; locally-issued governance credential is not in KERIA's
  ;; registry to export.
  (current-credential-finder
   (lambda (schema requester)
     (find-in-credential-stores
      (lambda (store)
        (find (lambda (c)
                (and (not (cred-revoked? c))
                     (or (equal? requester (cred-holder c))
                         (not (cred-holder c)))))
              ($ store 'by-schema schema))))))
  (current-credential-finder-by-said
   (lambda (cred-said)
     (find-in-credential-stores (lambda (store) ($ store 'get cred-said)))))
  (log! "  [gateway] credential-finder wired for inbound apply + agree~%")

  ;; Single drain entry point — called by the periodic fiber AND
  ;; by the post-reconnect hook so a KERIA outage is followed by
  ;; an immediate retry pass instead of waiting up to 60s. The
  ;; unified ^pending-grants queue covers BOTH scope-AID-signed
  ;; grants (enqueued by scope-deliver-grant!) and umbrella-AID-
  ;; signed grants (enqueued by ^keria-acdc-store's %try-grant)
  ;; — one drain call, one persistence layer.
  (define (drain-all-pending!)
    (catch #t
      (lambda ()
        (let ((result (with-vat pending-grants-vat
                        ($ pending-grants-ref 'drain!))))
          (when (and (pair? result) (> (car result) 0))
            (log! "  [gateway] drained ~a pending-grants (~a still pending)~%"
                  (car result) (cdr result)))))
      (lambda (key . args)
        (log! "  [gateway] drain error: ~a ~a~%" key args))))

  ;; Periodic drain: catches steady-state deferred deliveries.
  (spawn-fiber
   (lambda ()
     (let loop () (sleep 60) (drain-all-pending!) (loop))))

  ;; Reconnect-edge drain: when KERIA recovers from an outage,
  ;; retry queued deliveries immediately rather than waiting for
  ;; the next periodic tick.
  (register-reconnect-hook! drain-all-pending!))
