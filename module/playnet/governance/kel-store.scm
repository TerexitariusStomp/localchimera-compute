;;; module/playnet/governance/kel-store.scm — durable KEL event store
;;;
;;; A scope's KEL (Key Event Log) is an append-only sequence of signed
;;; events: inception (icp), rotation (rot), interaction (ixn), and
;;; dissolution rotations on recomposition. Each event is content-
;;; addressed by its SAID (the `d` field) and ordered by the sequence
;;; number (`s` field).
;;;
;;; This actor mirrors `^acdc-store` (which see for the reference
;;; pattern):
;;;   <dir>/
;;;     index.log         ← SAIDs in insertion order; replay-friendly
;;;     <2-said-prefix>/
;;;       <said>.scm      ← signed event body alist, one per event
;;;
;;; Unlike ACDCs, KEL events have no revocation concept — rotation and
;;; dissolution are themselves new events appended to the chain. So
;;; no `_revoked.log` is needed.
;;;
;;; The signed body at this layer is the alist returned by
;;; `governance-create-scope-aid!`:
;;;
;;;   ((name . "scope-AID") (icp . icp-alist) (sigs . #(sig0))).
;;;
;;; For rot/ixn events the inner key is `rot` / `ixn` instead of `icp`.
;;; Helpers below extract SAID, sequence, type without committing to
;;; one key.

(define-module (playnet governance kel-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils said-store)
  #:use-module (playnet utils paths)
  #:export (^kel-store
            spawn-kel-store
            kel-store-env
            kel-event-said
            kel-event-seq
            kel-event-type
            kel-event-aid))

;;; ── Event introspection ─────────────────────────────────────────────────────

(define %known-event-keys '("icp" "rot" "ixn" "dip" "drt"))

(define (kel-event-body-inner body)
  "Return the inner event alist (the part keyed by `icp`, `rot`, etc.)
   from a signed BODY, or #f if BODY is not a recognisable KEL body."
  (and (list? body)
       (any (lambda (k) (assoc-ref body k)) %known-event-keys)))

(define (kel-event-said body)
  (let ((inner (kel-event-body-inner body)))
    (and inner (assoc-ref inner "d"))))

(define (kel-event-seq body)
  (let* ((inner (kel-event-body-inner body))
         (s     (and inner (assoc-ref inner "s"))))
    (cond
     ((not s) 0)
     ;; KERI sequence numbers are hex strings ("0", "1", "a", etc.)
     ((string? s) (or (string->number s 16) 0))
     ((number? s) s)
     (else 0))))

(define (kel-event-type body)
  (let ((inner (kel-event-body-inner body)))
    (and inner (assoc-ref inner "t"))))

(define (kel-event-aid body)
  (let ((inner (kel-event-body-inner body)))
    (and inner (assoc-ref inner "i"))))

;;; ── Disk layout helpers ────────────────────────────────────────────────────
;;; The content-addressed body (`<dir>/<said[0:2]>/<said>.scm`) is the shared
;;; (playnet utils said-store); kel-store adds an `index.log` sidecar recording
;;; append order, which `load-events-from-disk` replays then sorts by seq.

(define (index-path dir)
  (string-append dir "/index.log"))

(define (ensure-store-dir! dir)
  (when dir (ensure-directory! dir)))

(define (write-event! dir body)
  (when dir
    (let ((said (kel-event-said body)))
      (unless said
        (error "kel-store: body has no SAID" body))
      (said-store-write! dir said body)
      (let ((port (open-file (index-path dir) "a")))
        (write said port) (newline port)
        (close-port port)))))

(define (read-index dir)
  (let ((p (index-path dir)))
    (if (not (file-exists? p)) '()
        (call-with-input-file p
          (lambda (port)
            (let loop ((acc '()))
              (let ((d (read port)))
                (if (eof-object? d) (reverse acc)
                    (loop (cons d acc))))))))))

(define (load-events-from-disk dir)
  "Replay events in the order they were appended, then sort by sequence
   number (events with smaller `s` field come first). Equal s-fields
   keep insertion order via stable sort."
  (let* ((said-list (read-index dir))
         (events (filter-map
                  (lambda (said)
                    (let ((p (said-store-path dir said)))
                      (and (file-exists? p)
                           (call-with-input-file p read))))
                  said-list)))
    (stable-sort events
                 (lambda (a b) (< (kel-event-seq a) (kel-event-seq b))))))

;;; ── ^kel-store actor ───────────────────────────────────────────────────────

(define-actor (^kel-store bcom events durable-dir aid subscribers)
  ;; subscribers :: list of (^scope-witness) refs that mirror this AID's KEL.
  ;; aid: the scope-AID this kel-store belongs to (used in async broadcast).

  ;; events/durable-dir/aid are plain data; subscribers is a list of actor
  ;; refs, which Goblins serializes natively as graph refs when they're in
  ;; the same persistence env — no closures here, unlike voice-signer/
  ;; audit-scheduler/etc., so a straight #:portrait is safe. Without this,
  ;; any Goblins-native portrait-take over a scope's object graph (a ^scope
  ;; holds a live kel-store ref) aborts the WHOLE checkpoint with "Don't
  ;; know how to persist object" the moment it reaches this actor — this
  ;; was previously the only persistence path missing that guarantee.
  ;; Production recovery still primarily runs through DURABLE-DIR replay
  ;; (see spawn-kel-store below); this triple makes the actor also safe to
  ;; reach from a native portrait-take, e.g. of a non-durable scope's graph.
  #:portrait
  (lambda () (list events durable-dir aid subscribers))

  #:version 1

  #:restore
  (lambda (version . args)
    (case version
      ((1) (apply spawn ^kel-store args))
      (else (error "Unknown ^kel-store version" version))))

  (define (rebuild new-events new-subscribers)
    (^kel-store bcom new-events durable-dir aid new-subscribers))
  (methods
   ((durable-dir) durable-dir)
   ((aid)         aid)
   ((subscribers) subscribers)

   ;; Append a signed KEL event body. SAID-keyed dedup: re-appending an
   ;; event already present is a no-op. After committing, broadcasts
   ;; the event asynchronously to every subscribed witness.
   ((append body)
    (let* ((said (kel-event-said body)))
      (unless said
        (error "kel-store/append: body has no SAID" body))
      (cond
       ((find (lambda (e) (equal? said (kel-event-said e))) events)
        'ok)
       (else
        (write-event! durable-dir body)
        ;; Async-broadcast to every witness. Each `<-` is fire-and-forget;
        ;; subscribers handle the message in their own vat.
        (when (and aid (pair? subscribers))
          (for-each (lambda (w) (<- w 'mirror aid body)) subscribers))
        (bcom (rebuild (append events (list body)) subscribers)
              'ok)))))

   ((subscribe witness-ref)
    "Add WITNESS-REF to the broadcast set. Idempotent. Future events
     will be mirrored to it."
    (cond
     ((member witness-ref subscribers) 'already-subscribed)
     (else (bcom (rebuild events (cons witness-ref subscribers)) 'ok))))

   ;; A witness joins and is brought up to date: every event already
   ;; in the log goes to it now, every later one as it lands. The same
   ;; act for a store minted this turn (the log is empty, the icp is
   ;; about to arrive) and for a store read back from disk (the log is
   ;; whole, the witness may be younger than the scope). Replays are
   ;; safe: a witness files by SAID, so an event it holds is a no-op.
   ((witness! witness-ref)
    (when aid
      (for-each (lambda (e) (<- witness-ref 'mirror aid e)) events))
    (if (member witness-ref subscribers)
        'ok
        (bcom (rebuild events (cons witness-ref subscribers)) 'ok)))

   ((all) events)
   ((by-said said)
    (find (lambda (e) (equal? said (kel-event-said e))) events))
   ((first) (and (pair? events) (car events)))
   ((latest) (and (pair? events) (last events)))
   ((count) (length events))))

(define kel-store-env
  (make-persistence-env
    `((((playnet governance) ^kel-store) ,^kel-store))))

(define* (spawn-kel-store #:key (durable-dir #f) (aid #f) (subscribers '()))
  "Spawn a KEL event store. When DURABLE-DIR is provided, the store
   replays existing events from that directory at startup and writes
   every subsequent append synchronously to disk.

   AID — the owning scope's AID (used in async-broadcast to subscribers
     so witnesses know which AID they're mirroring).
   SUBSCRIBERS — list of ^scope-witness refs that should receive
     async copies of every append. New subscribers can be added later
     via the 'subscribe method."
  (when durable-dir (ensure-store-dir! durable-dir))
  (let ((events (if durable-dir (load-events-from-disk durable-dir) '())))
    (spawn ^kel-store events durable-dir aid subscribers)))
