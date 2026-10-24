;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; event-log.scm — a portable, self-certifying log of the observer's events.
;;;
;;; The observer is event-sourced (observer.scm:<observer-state>.events), but
;;; its log only ever persists as gateway-local Goblins syrup — not portable,
;;; not verifiable off-box (docs/planning/books/portable-event-log.md, gap #18).
;;;
;;; This module is the portable canonical record that sits ALONGSIDE syrup:
;;; an append-only, SAID-chained log of economic-event payloads. Each entry
;;; carries a deterministic blake3 SAID (CESR "E", the same recipe as
;;; governance/credentials.scm `compute-said`) over its content INCLUDING the
;;; previous entry's SAID — so the log is a hash-linked chain. Mutating,
;;; dropping or reordering any entry breaks every SAID downstream. Authorship
;;; comes from anchoring the chain HEAD into the scope KEL (the integration's
;;; job, via scope `'anchor-acdc`); this module proves only chain integrity.
;;;
;;; Decoupled by design: it deals in OPAQUE event payloads (alists), never the
;;; <economic-event> record nor governance. The observer hook converts records
;;; ↔ payloads via bridge/codec.scm; replay folds payloads back through
;;; observer-record-event. Depends only on the low-level keri primitives.
;;;
;;; On-disk layout via the shared (localchimera utils said-store) — content-addressed,
;;; so two copies of a dir union cleanly by file copy WITHIN a trust domain (the
;;; log is a LOCAL artifact; it is never served to peers — see
;;; docs/planning/books/portable-event-log.md §9–§10):
;;;   <dir>/<said-prefix>/<said>.scm   one entry per file
;;;   <dir>/_checkpoint                compaction cut (observer snapshot + prev)
;;;   <dir>/_head                      head SAID + seq (a convenience pointer)
;;;
;;; Run the suite:  guix shell -m deploy/manifests/dev-test-manifest.scm -- \
;;;                   guile --no-auto-compile -q -L module \
;;;                     tests/observation/test-event-log.scm

(define-module (localchimera observation event-log)
  #:use-module (localchimera keri blake3)
  #:use-module (localchimera keri cesr)
  #:use-module (localchimera utils said-store)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:re-export (said-prefix)
  #:export (empty-event-log
            event-log?
            event-log-head
            event-log-seq
            event-log-base-seq
            event-log-append
            event-log-list
            event-log-payloads
            event-log-legacy-payloads
            event-log-current-payloads
            event-log-export-since
            event-log-import
            event-log-rebase
            event-log-merge
            event-log-frontier
            event-log-verify-chain
            ;; checkpoints / compaction
            event-log-checkpoint
            event-log-checkpoint-blob
            ck-said ck-upto ck-prev ck-blob verify-checkpoint
            ;; entry accessors
            entry-version entry-scope entry-seq entry-prev entry-event entry-said
            verify-entry
            ;; durable
            durable-write-entry!
            durable-write-checkpoint!
            durable-checkpoint
            durable-prune!
            durable-load-event-log))

;; v2: a correction is an event of its own, with a signed quantity. v1 entries hold
;; corrections that REPLACE the event they name; replay reads those once, at the
;; seam (observer `legacy-corrections->canonical`), and every v2 entry as it stands.
(define +entry-version+ "PEL2")    ; localchimera event log, v2
(define +legacy-entry-version+ "PEL1")
(define +checkpoint-version+ "PELCK1")

;; ── Canonical content → SAID ────────────────────────────────────────────────
;; Identical recipe to governance/credentials.scm `canonical-string` +
;; `compute-said`, so an event SAID is a real KERI SAID a foreign verifier can
;; recompute. (Replicated, not imported, to keep this module off the heavy
;; governance dependency — the algorithm is stable.)
(define (canonical-string x)
  (cond
    ((null? x) "()")
    ((pair? x)
     (string-append "(" (canonical-string (car x))
                    " . " (canonical-string (cdr x)) ")"))
    ((string? x) (string-append "\"" x "\""))
    ((symbol? x) (symbol->string x))
    ((number? x) (number->string x))
    ((boolean? x) (if x "#t" "#f"))
    (else (format #f "~s" x))))

;; The SAID covers (version, scope, seq, prev, payload) — the prev link is
;; folded in, so the chain is tamper-evident end to end.
(define (compute-entry-said version scope seq prev event)
  (let* ((content `(("v" . ,version) ("i" . ,scope) ("s" . ,seq)
                    ("p" . ,prev)    ("e" . ,event)))
         (digest  (blake3-256 (string->utf8 (canonical-string content)))))
    (cesr-bytes->qb64 "E" digest)))

;; ── Entries ─────────────────────────────────────────────────────────────────
;; An entry is a plain alist (string keys), so it round-trips through `write`/
;; `read` on disk and across vats with no record-type coupling.
(define (make-entry version scope seq prev event)
  (let ((said (compute-entry-said version scope seq prev event)))
    `(("v" . ,version) ("i" . ,scope) ("s" . ,seq)
      ("p" . ,prev)    ("e" . ,event) ("d" . ,said))))

(define (entry-ref e k) (assoc-ref e k))
(define (entry-version e) (entry-ref e "v"))
(define (entry-scope   e) (entry-ref e "i"))
(define (entry-seq     e) (entry-ref e "s"))
(define (entry-prev    e) (entry-ref e "p"))
(define (entry-event   e) (entry-ref e "e"))
(define (entry-said    e) (entry-ref e "d"))

;; Recompute the SAID from the entry's own content and compare — catches any
;; tamper to version/scope/seq/prev/payload.
(define (verify-entry e)
  (and (string? (entry-said e))
       (string=? (entry-said e)
                 (compute-entry-said (entry-version e) (entry-scope e)
                                     (entry-seq e) (entry-prev e) (entry-event e)))))

;; ── Checkpoints (compaction) ────────────────────────────────────────────────
;; A checkpoint subsumes every event below `upto` into one signed record that
;; carries an OPAQUE state blob (the observer's serialized state at that point)
;; plus `prev` — the SAID of event `upto`-1, so the chain stays verifiable
;; across the prune boundary. The integration restores observer state from the
;; blob, then folds the post-checkpoint tail; the pruned events can be dropped.
(define (compute-checkpoint-said scope upto prev blob)
  (let* ((content `(("v" . ,+checkpoint-version+) ("i" . ,scope)
                    ("upto" . ,upto) ("prev" . ,prev) ("b" . ,blob)))
         (digest  (blake3-256 (string->utf8 (canonical-string content)))))
    (cesr-bytes->qb64 "E" digest)))

(define (make-checkpoint scope upto prev blob)
  (let ((said (compute-checkpoint-said scope upto prev blob)))
    `(("v" . ,+checkpoint-version+) ("i" . ,scope) ("upto" . ,upto)
      ("prev" . ,prev) ("b" . ,blob) ("d" . ,said))))

(define (ck-scope c) (assoc-ref c "i"))
(define (ck-upto  c) (assoc-ref c "upto"))
(define (ck-prev  c) (assoc-ref c "prev"))
(define (ck-blob  c) (assoc-ref c "b"))
(define (ck-said  c) (assoc-ref c "d"))
(define (verify-checkpoint c)
  (and (string? (ck-said c))
       (string=? (ck-said c)
                 (compute-checkpoint-said (ck-scope c) (ck-upto c) (ck-prev c) (ck-blob c)))))

;; ── The log (immutable value, newest-first like os-events) ──────────────────
;; After compaction `entries` holds only seqs in [base-seq, next); the prefix
;; lives in `ckpt`'s blob. `base-prev` is the SAID linking base-seq into that
;; pruned prefix (== ckpt prev), so verification continues across the cut.
(define-record-type <event-log>
  (mk-event-log scope entries head next base-seq base-prev ckpt)
  event-log?
  (scope     el-scope)      ; stream identity (scope AID string)
  (entries   el-entries)    ; newest-first list of entries, seq ∈ [base-seq, next)
  (head      el-head)       ; head SAID (base-prev when no entries present)
  (next      el-next)       ; next sequence number
  (base-seq  el-base-seq)   ; first seq physically present (0 unless pruned)
  (base-prev el-base-prev)  ; SAID linking base-seq into the pruned prefix
  (ckpt      el-ckpt))      ; active checkpoint record, or #f

(define (empty-event-log scope) (mk-event-log scope '() "" 0 0 "" #f))
;; A log resumed from a checkpoint: no tail yet, base advanced past the prefix.
(define (based-event-log scope ck)
  (if (not ck) (empty-event-log scope)
      (begin
        (unless (verify-checkpoint ck) (error "event-log: checkpoint SAID mismatch"))
        (mk-event-log scope '() (ck-prev ck) (ck-upto ck) (ck-upto ck) (ck-prev ck) ck))))

(define (event-log-head l) (el-head l))
(define (event-log-seq  l) (el-next l))
(define (event-log-base-seq l) (el-base-seq l))
(define (event-log-checkpoint-blob l) (and (el-ckpt l) (ck-blob (el-ckpt l))))

;; Append an opaque event payload. Pure: returns (values new-log entry).
(define* (event-log-append l event #:key (version +entry-version+))
  "L with EVENT appended as a new entry of VERSION (the current one unless a foreign
   entry's own version is being carried over). Returns (values log entry)."
  (let* ((seq   (el-next l))
         (entry (make-entry version (el-scope l) seq (el-head l) event)))
    (values (mk-event-log (el-scope l) (cons entry (el-entries l))
                          (entry-said entry) (+ seq 1)
                          (el-base-seq l) (el-base-prev l) (el-ckpt l))
            entry)))

;; Snapshot the log at its head into a checkpoint carrying BLOB, and prune:
;; the returned log keeps no entries, its base advances to the current next.
;; Pure — returns (values new-log checkpoint). The store does the disk prune.
(define (event-log-checkpoint l blob)
  (let ((ck (make-checkpoint (el-scope l) (el-next l) (el-head l) blob)))
    (values (mk-event-log (el-scope l) '() (el-head l) (el-next l)
                          (el-next l) (el-head l) ck)
            ck)))

(define (event-log-list l) (reverse (el-entries l)))           ; chronological
(define (event-log-payloads l) (map entry-event (event-log-list l)))
(define (legacy-entry? e) (equal? (entry-version e) +legacy-entry-version+))
(define (event-log-legacy-payloads l) (map entry-event (filter legacy-entry? (event-log-list l))))
(define (event-log-current-payloads l) (map entry-event (remove legacy-entry? (event-log-list l))))

;; Entries from sequence FROM onward (chronological) — the cross-vat pull half.
(define (event-log-export-since l from)
  (filter (lambda (e) (>= (entry-seq e) from)) (event-log-list l)))

;; ── Verifying import / replay ───────────────────────────────────────────────
;; Fold incoming entries (chronological) onto L. Idempotent: an entry whose
;; seq is already present must match (same SAID) and is skipped; below the base
;; it's trusted to the checkpoint and skipped; the next new seq must verify and
;; chain onto the current head; a gap or fork raises.
(define (event-log-import l entries)
  (fold
   (lambda (e acc)
     (let ((s (entry-seq e)))
       (unless (verify-entry e)
         (error "event-log import: SAID mismatch (tampered entry)" (entry-said e)))
       (cond
        ((< s (el-base-seq acc)) acc)   ; pruned prefix — covered by the checkpoint
        ((< s (el-next acc))
         ;; already have this seq — must be the identical entry (idempotent)
         (let ((have (list-ref (event-log-list acc) (- s (el-base-seq acc)))))
           (unless (string=? (entry-said have) (entry-said e))
             (error "event-log import: fork at seq" s)))
         acc)
        ((= s (el-next acc))
         (unless (string=? (entry-prev e) (el-head acc))
           (error "event-log import: broken chain at seq" s))
         (mk-event-log (el-scope acc) (cons e (el-entries acc))
                       (entry-said e) (+ s 1)
                       (el-base-seq acc) (el-base-prev acc) (el-ckpt acc)))
        (else (error "event-log import: gap before seq" s)))))
   l entries))

;; ── Multi-custody reconciliation ────────────────────────────────────────────
;; Single-writer is the invariant (the scope KEL is the authority). But if two
;; custodians append independently before syncing, their streams fork. The KEL
;; anchor is the tiebreaker: events below the anchored FRONTIER are committed —
;; both sides MUST agree there (divergence = a KEL-level fork, unresolvable
;; here, so we raise). Above the frontier the appends are un-committed and
;; concurrent: the foreign divergent tail is REBASED onto this chain as fresh
;; entries — no event is lost, the committed history is untouched.

;; Re-append a list of foreign ENTRIES onto L as new entries (new seqs, re-linked,
;; re-SAID'd), each keeping the version it was written in: a v1 payload's
;; corrections replace and are read once at the replay seam, never as a v2 entry's
;; signed deltas. The raw material of a rebase.
(define (event-log-rebase l entries)
  (fold (lambda (e acc) (call-with-values (lambda () (event-log-append acc (entry-event e) #:version (entry-version e)))
                          (lambda (nl _e) nl)))
        l entries))

;; Merge FOREIGN entries (chronological) into BASE. Matching entries are
;; idempotent; the first divergence at seq < FRONTIER raises (committed fork);
;; a divergence (or gap) at/above FRONTIER rebases the foreign tail onto BASE.
;; Returns the merged log.
(define* (event-log-merge base foreign #:key (frontier 0))
  (let loop ((fs foreign) (acc base))
    (if (null? fs) acc
        (let* ((e (car fs)) (s (entry-seq e)))
          (unless (verify-entry e) (error "event-log merge: tampered foreign entry" (entry-said e)))
          (cond
           ((< s (el-base-seq acc)) (loop (cdr fs) acc))    ; pruned/committed prefix
           ((< s (el-next acc))
            (let ((have (list-ref (event-log-list acc) (- s (el-base-seq acc)))))
              (cond
               ((string=? (entry-said have) (entry-said e)) (loop (cdr fs) acc))   ; agree
               ((< s frontier) (error "event-log merge: committed fork below frontier at seq" s))
               (else (event-log-rebase acc fs)))))                                       ; rebase tail
           ((and (= s (el-next acc)) (string=? (entry-prev e) (el-head acc)))       ; fast-forward
            (call-with-values (lambda () (event-log-append acc (entry-event e) #:version (entry-version e)))
              (lambda (nl _e) (loop (cdr fs) nl))))
           (else (event-log-rebase acc fs)))))))                                    ; gap → rebase

;; The committed frontier, given the set of ANCHORED-SAIDS (entry SAIDs sealed
;; into the scope KEL): one past the highest present entry whose SAID is
;; anchored — so anchoring the head commits the whole chain up to it. The pruned
;; prefix (≤ base-seq, folded into an anchored checkpoint) is committed by
;; construction, so it is the floor. Feed the result to `event-log-merge`.
(define (event-log-frontier l anchored-saids)
  (fold (lambda (e acc)
          (if (member (entry-said e) anchored-saids) (max acc (+ 1 (entry-seq e))) acc))
        (el-base-seq l)
        (event-log-list l)))

;; Walk the present chain: every SAID recomputes, every prev links, seqs dense
;; from base-seq, the first link reaching back to base-prev (the checkpoint cut,
;; or "" at genesis). Returns #t or raises.
(define (event-log-verify-chain l)
  (let loop ((es (event-log-list l)) (prev (el-base-prev l)) (i (el-base-seq l)))
    (cond
     ((null? es) #t)
     (else
      (let ((e (car es)))
        (unless (verify-entry e) (error "verify-chain: SAID mismatch at" i))
        (unless (= (entry-seq e) i) (error "verify-chain: seq gap at" i))
        (unless (string=? (entry-prev e) prev) (error "verify-chain: broken link at" i))
        (loop (cdr es) (entry-said e) (+ i 1)))))))

;; ── Durable store ───────────────────────────────────────────────────────────
;; The content-addressed body (`<dir>/<said[0:2]>/<said>.scm`) is the shared
;; (localchimera utils said-store); the event-log adds one sidecar, `_checkpoint`
;; (compaction). The head/seq are recovered by scanning, so no pointer file is
;; kept — nothing would read it.
(define (durable-write-entry! dir entry)
  (said-store-write! dir (entry-said entry) entry))

(define (durable-write-checkpoint! dir ck)
  (when dir
    (said-store-ensure-dir! dir)
    (call-with-output-file (string-append dir "/_checkpoint")
      (lambda (port) (write ck port) (newline port)))))

(define (durable-checkpoint dir)  ; checkpoint record or #f
  (let ((f (string-append dir "/_checkpoint")))
    (and (file-exists? f) (call-with-input-file f read))))

;; Delete entry files whose seq < UPTO — the prefix the checkpoint subsumes.
(define (durable-prune! dir upto)
  (for-each (lambda (e) (when (< (entry-seq e) upto)
                          (said-store-delete! dir (entry-said e))))
            (said-store-scan dir)))

;; Load: resume from the checkpoint (if any), then verifying-import the tail
;; entries (seq ≥ base). A corrupt, forked, or gap-broken store fails loudly.
(define (durable-load-event-log dir scope)
  (if (not (and dir (file-exists? dir)))
      (empty-event-log scope)
      (let* ((ck       (durable-checkpoint dir))
             (base-seq (if ck (ck-upto ck) 0))
             (tail     (filter (lambda (e) (>= (entry-seq e) base-seq)) (said-store-scan dir)))
             (sorted   (sort tail (lambda (a b) (< (entry-seq a) (entry-seq b))))))
        (event-log-import (based-event-log scope ck) sorted))))
