;;; module/playnet/identity/oobi-host.scm — server-hosted OOBI store
;;;
;;; In playnet's browser-resident-Signify flow, the user creates an AID
;;; in the browser (Phase B) and ships the inception event + signatures
;;; to the server. The server doesn't custody keys; it just stores the
;;; signed events so that:
;;;
;;;   1. server/serve-static.scm can expose `/oobi/{aid}` (CESR text
;;;      stream) and `/.well-known/keri/oobi/{aid}` for any KERI
;;;      resolver to fetch the AID's KEL.
;;;   2. signup-agent has prior-state for validating subsequent
;;;      rotation events submitted by the controller.
;;;
;;; The store is content-addressed by AID. Each entry holds the
;;; inception event and an ascending list of rotation events with
;;; their signatures. Optional `#:durable-dir` mirrors the acdc-store
;;; pattern: each `(aid → entry)` becomes a file.
;;;
;;; Entry shape (stored as alist):
;;;
;;;   ((aid           . "Dxx...")              ; AID prefix (44 chars)
;;;    (icp           . ((..."v" . str)...))   ; inception event alist
;;;    (sigs          . #("AA..." ...))        ; CESR indexed sigs over icp
;;;    (rotations     . ((rot-alist . sigs-vec) ...))  ; ascending sn
;;;    (replies       . #("<rpy>-FAB..." ...)) ; framed OKEA endpoint replies
;;;    (registered-at . "1745539200"))         ; epoch seconds, decimal
;;;
;;; `replies` holds fully-framed CESR reply messages (/end/role/add +
;;; /loc/scheme, built by signify-portable's oobi-endpoint-replies and
;;; endorsed by the AID's own keys at registration time — the host never
;;; custodies keys). serve-static appends them after the KEL so resolvers
;;; register the AID's service endpoint (OOBI §3.4 OKEA); without them an
;;; OOBI conveys key state but no address, and e.g. KERIA's witness
;;; receiptor has nowhere to submit events for receipts.
;;;
;;; Future: add `(receipts . (...))` once witness receipts attach.

(define-module (playnet identity oobi-host)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils store-utils) #:select (hashmap-count))
  #:use-module ((srfi srfi-13) #:select (string-suffix?))
  #:use-module ((playnet keri signify-portable) #:select (event-first-key))
  #:export (^oobi-host
            oobi-host-spawn-from-dir
            oobi-entry-path
            read-oobi-entry-from-dir
            read-oobi-entries-from-dir
            oobi-entry-last-event
            oobi-current-key-from-dir
            oobi-write-entry-to-dir!))

;;; ── Durable-dir helpers ─────────────────────────────────────────────────────

(define (aid-prefix-bucket aid)
  (if (>= (string-length aid) 2) (substring aid 0 2) "_"))

(define (entry-path dir aid)
  (string-append dir "/" (aid-prefix-bucket aid) "/" aid ".scm"))

(define (oobi-entry-path dir aid)
  "Public alias of entry-path: serve-static.scm and other readers must
   use the same path layout the actor writes to. Re-exporting prevents
   the layout from drifting between writer and reader."
  (entry-path dir aid))

(define (oobi-entry-last-event entry)
  "Return the latest KEL event alist in ENTRY: the last rotation if any
   exist, else the inception. ENTRY is the alist shape documented at
   the top of this file. Returns #f if ENTRY has no icp."
  (and (pair? entry)
       (let ((rots (or (assq-ref entry 'rotations) '())))
         (if (null? rots)
             (assq-ref entry 'icp)
             (car (last rots))))))

(define (read-oobi-entry-from-dir dir aid)
  "Read the durable entry alist for AID under DIR, or #f if absent
   or unreadable. Pure file reader — does not touch the actor."
  (let ((path (entry-path dir aid)))
    (and (file-exists? path)
         (catch #t
           (lambda () (call-with-input-file path read))
           (lambda _ #f)))))

(define (oobi-current-key-from-dir dir aid)
  "The current signing key (qb64 D-prefix) for AID, read from DIR's
   durable entries — the actor's `current-key` derivation over the disk
   mirror instead of the in-memory table. Pure file read, so it is
   callable from ANY vat's turn: verifiers that live in another vat
   than the ^oobi-host actor (the work-witness ceremony attest runs in
   the planner vat) resolve a browser AID's post-inception key through
   this rather than a cross-vat `$`. #f when the AID is unregistered."
  (event-first-key
   (oobi-entry-last-event (read-oobi-entry-from-dir dir aid))))

(define (ensure-dir! path)
  (unless (file-exists? path)
    (mkdir path)))

(define (oobi-write-entry-to-dir! dir entry)
  "Land ENTRY (the alist shape above) under DIR atomically — the pure
   file-write twin of read-oobi-entry-from-dir, for a verified KEL that
   arrives in a vat where the ^oobi-host actor is out of reach (a
   credential bundle presented in the planner vat). The dir is what both
   key resolvers read, so a signature under this AID verifies at once;
   the actor's own table learns the entry when it next replays the dir."
  (let* ((aid    (assq-ref entry 'aid))
         (bucket (string-append dir "/" (aid-prefix-bucket aid)))
         (file   (entry-path dir aid))
         (tmp    (string-append file ".tmp")))
    (let mk ((d bucket))                       ; every missing level, root first
      (unless (file-exists? d) (mk (dirname d)) (mkdir d)))
    (call-with-output-file tmp
      (lambda (p) (write entry p) (newline p)))
    (rename-file tmp file)
    'ok))

(define (write-entry! dir entry)
  (let* ((aid    (assq-ref entry 'aid))
         (bucket (string-append dir "/" (aid-prefix-bucket aid)))
         (file   (entry-path dir aid)))
    (ensure-dir! dir)
    (ensure-dir! bucket)
    (call-with-output-file file
      (lambda (p) (write entry p) (newline p)))))

;; Exported as read-oobi-entries-from-dir: like read-oobi-entry-from-dir
;; this is a pure file reader other processes (serve-static) use — the
;; actor owns the layout, so its readers live here.
(define (read-entries dir)
  "Walk DIR and return all stored entry alists. Tolerates absent dir."
  (if (not (and (file-exists? dir) (eq? 'directory (stat:type (stat dir)))))
      '()
      (let loop ((buckets (or (scandir dir) '())) (acc '()))
        (if (null? buckets)
            acc
            (let* ((b (car buckets)))
              (cond
               ((or (string=? b ".") (string=? b "..")) (loop (cdr buckets) acc))
               (else
                (let* ((bp (string-append dir "/" b))
                       (files (or (scandir bp) '())))
                  (loop (cdr buckets)
                        (fold-right
                         (lambda (f acc2)
                           (cond
                            ((or (string=? f ".") (string=? f "..")) acc2)
                            ((string-suffix? ".scm" f)
                             (let ((entry (call-with-input-file
                                            (string-append bp "/" f)
                                            read)))
                               (cons entry acc2)))
                            (else acc2)))
                         acc files))))))))))

;;; ── ^oobi-host ──────────────────────────────────────────────────────────────

(define (entry-carries-key? entry key)
  "#t when the inception or any rotation in ENTRY carries KEY as its signing key."
  (or (equal? key (event-first-key (assq-ref entry 'icp)))
      (any (lambda (r) (equal? key (event-first-key (car r))))
           (or (assq-ref entry 'rotations) '()))))

(define (registered-at entry)
  "When ENTRY was registered, as epoch seconds; 0 for an entry that carries none."
  (let ((at (assq-ref entry 'registered-at)))
    (or (and (string? at) (string->number at)) 0)))

(define* (^oobi-host bcom #:optional (entries (hashmap)) #:key (durable-dir #f))
  ;; entries: hashmap of aid-prefix → entry alist (shape documented
  ;; at the top of this file).

  (define (entry-set existing key val)
    ;; Replace KEY's value in the entry alist, or append it for entries
    ;; written before the field existed (durable-dir backward compat).
    (if (assq key existing)
        (map (lambda (p) (if (eq? key (car p)) (cons key val) p)) existing)
        (append existing (list (cons key val)))))

  (define (store-entry! entry)
    (when durable-dir (write-entry! durable-dir entry))
    ;; bcom must be the *returned value* for the behavior swap to apply.
    (bcom (^oobi-host bcom (hashmap-set entries (assq-ref entry 'aid) entry)
                      #:durable-dir durable-dir)
          'ok))

  (define (put-entry! aid icp-alist sigs)
    (store-entry! `((aid           . ,aid)
                    (icp           . ,icp-alist)
                    (sigs          . ,sigs)
                    (rotations     . ())
                    (replies       . #())
                    (registered-at . ,(number->string (instant->unix (clock-now)))))))

  (define (do-append-rotation! aid rot-alist sigs)
    (let ((existing (hashmap-ref entries aid #f)))
      (if (not existing)
          (list 'error "AID not registered")
          (store-entry!
           (entry-set existing 'rotations
                      (append (or (assq-ref existing 'rotations) '())
                              (list (cons rot-alist sigs))))))))

  (define (do-set-replies! aid replies)
    (let ((existing (hashmap-ref entries aid #f)))
      (if (not existing)
          (list 'error "AID not registered")
          (store-entry! (entry-set existing 'replies replies)))))

  (define (do-set-receipts! aid receipts)
    (let ((existing (hashmap-ref entries aid #f)))
      (if (not existing)
          (list 'error "AID not registered")
          (store-entry! (entry-set existing 'receipts receipts)))))

  (methods

    ;; ── put! ──────────────────────────────────────────────────────────────────
    ;; Idempotent: re-putting an AID overwrites its entry. Returns 'ok or
    ;; (list 'error reason). Signature/SAID validation is the caller's
    ;; responsibility (signup-agent does it).
    ((put! aid icp-alist sigs)
     (cond
      ((not (string? aid))           (list 'error "aid must be a string"))
      ((not (pair? icp-alist))       (list 'error "icp must be an alist"))
      ((not (vector? sigs))          (list 'error "sigs must be a vector"))
      (else (put-entry! aid icp-alist sigs))))

    ;; ── append-rotation! ───────────────────────────────────────────────────
    ;; Append a verified rotation event to AID's entry. Caller (signup-agent)
    ;; is responsible for validation; this just persists.
    ((append-rotation! aid rot-alist sigs)
     (cond
      ((not (string? aid))           (list 'error "aid must be a string"))
      ((not (pair? rot-alist))       (list 'error "rot must be an alist"))
      ((not (vector? sigs))          (list 'error "sigs must be a vector"))
      (else (do-append-rotation! aid rot-alist sigs))))

    ;; ── set-replies! ──────────────────────────────────────────────────────────
    ;; Attach the framed OKEA endpoint replies (/end/role/add + /loc/scheme)
    ;; for AID — a vector of fully-framed CESR strings, endorsed by the
    ;; AID's own keys (see signify-portable's oobi-endpoint-replies).
    ;; Idempotent: replaces any prior replies. Caller is responsible for
    ;; having signed them correctly; the host just persists and serves.
    ((set-replies! aid replies)
     (cond
      ((not (string? aid))     (list 'error "aid must be a string"))
      ((not (vector? replies)) (list 'error "replies must be a vector"))
      (else (do-set-replies! aid replies))))

    ;; ── set-receipts! ─────────────────────────────────────────────────────────
    ;; Attach witness receipt streams for AID — a vector of rct message
    ;; strings exactly as the witnesses returned them (POST /receipts).
    ;; Served verbatim after the KEL so resolvers store the wigs and a
    ;; bt>0 inception exits escrow. Idempotent.
    ((set-receipts! aid receipts)
     (cond
      ((not (string? aid))      (list 'error "aid must be a string"))
      ((not (vector? receipts)) (list 'error "receipts must be a vector"))
      (else (do-set-receipts! aid receipts))))

    ;; ── get ───────────────────────────────────────────────────────────────────
    ;; Returns the entry alist, or #f when the AID isn't known.
    ((get aid)
     (hashmap-ref entries aid #f))

    ;; ── by-event-key ──────────────────────────────────────────────────────────
    ;; The entry one of whose establishment events carries KEY (qb64) as its
    ;; signing key, or #f. A passcode's FIRST key is such a key: the
    ;; inception's, for the passcode an identity was made with; a rotation's,
    ;; for a passcode it was changed to. So a device that holds only a
    ;; passcode derives that key and finds its own log by it. One key can
    ;; open several logs (a passcode incepted twice, under different
    ;; anchors): the earliest registered answers.
    ((by-event-key key)
     (and (string? key)
          (hashmap-fold
           (lambda (_aid entry best)
             (if (and (entry-carries-key? entry key)
                      (or (not best)
                          (< (registered-at entry) (registered-at best))))
                 entry
                 best))
           #f entries)))

    ;; ── known? ────────────────────────────────────────────────────────────────
    ((known? aid)
     (and (hashmap-ref entries aid #f) #t))

    ;; ── all ───────────────────────────────────────────────────────────────────
    ((all)
     (hashmap-fold (lambda (_k v acc) (cons v acc)) '() entries))

    ;; ── count ─────────────────────────────────────────────────────────────────
    ((count) (hashmap-count entries))

    ;; ── current-key ──────────────────────────────────────────────────────────
    ;; Return the qb64 of the *current* signing key for AID — i.e. the
    ;; latest rotation's k[0], or the inception's k[0] if no rotations.
    ;; Returns #f if the AID isn't registered. Critical for verification:
    ;; after a rotation, the AID prefix no longer encodes the current key,
    ;; so verifiers must consult this rather than decoding the prefix.
    ((current-key aid)
     (event-first-key
      (oobi-entry-last-event (hashmap-ref entries aid #f))))))

;;; ── Bootstrap helper: replay a durable-dir on respawn ──────────────────────

(define read-oobi-entries-from-dir read-entries)

(define (oobi-host-spawn-from-dir dir)
  "Spawn a fresh ^oobi-host pre-populated from DIR's stored entries."
  (let ((existing (fold (lambda (e acc)
                          (hashmap-set acc (assq-ref e 'aid) e))
                        (hashmap)
                        (read-entries dir))))
    (spawn ^oobi-host existing #:durable-dir dir)))

;; (No goblins persistence-env: ^oobi-host carries no #:portrait, so
;; durability is via the optional disk write-through in #:durable-dir
;; rather than the goblins serialization path. oobi-host-spawn-from-dir
;; replays a directory at startup.)
