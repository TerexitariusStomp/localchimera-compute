;;; event-log-store.scm — the ^event-log-store actor: a scope's portable,
;;; self-certifying economic event stream (gap #18).
;;;
;;; Wraps the pure (playnet planner observation event-log) value in a Goblins
;;; actor living in the scope vat. The DURABLE DIRECTORY is the persistence —
;;; each append write-throughs to `<dir>/<said-prefix>/<said>.scm` and updates
;;; `<dir>/_head`; on respawn the actor restores by loading + verifying the
;;; directory. No syrup: the canonical record is the on-disk, content-addressed,
;;; SAID-chained stream itself, copyable to any gateway.
;;;
;;; The observer's `log-sink` callback (observer.scm record-event) forwards each
;;; <economic-event> here as an opaque payload — this actor is oblivious to the
;;; record type. The wiring (scope-root / governance scope spawn) builds the
;;; sink as e.g. (lambda (ev) ($ store 'append (economic-event->json ev))).
;;;
;;; Methods:
;;;   (append payload)   → SAID of the new entry (write-through)
;;;   (head)             → head SAID ("" when empty)
;;;   (seq)              → next sequence number (== count)
;;;   (export-since n)   → entries from seq n (cross-vat pull)
;;;   (import entries)   → fold foreign entries in (verifying), → new seq
;;;   (payloads)         → chronological event payloads (for observer replay)
;;;   (legacy-payloads) / (current-payloads) → the payloads of v1 / v2 entries
;;;   (verify)           → #t or raises (full chain + SAID check)

(define-module (playnet planner observation event-log-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet planner observation event-log)
  #:export (^event-log-store spawn-event-log-store))

;; ld:  the in-memory <event-log> value
;; dir: durable directory (#f = pure in-memory, e.g. tests)
(define-actor (^event-log-store bcom ld dir)
  (methods
    ((append payload)
     (call-with-values (lambda () (event-log-append ld payload))
       (lambda (new-ld entry)
         (durable-write-entry! dir entry)
         (bcom (^event-log-store bcom new-ld dir) (entry-said entry)))))

    ((head)            (event-log-head ld))
    ((seq)             (event-log-seq ld))
    ((export-since n)  (event-log-export-since ld n))
    ((payloads)        (event-log-payloads ld))
    ((legacy-payloads)  (event-log-legacy-payloads ld))    ; v1 entries: corrections that replace
    ((current-payloads) (event-log-current-payloads ld))   ; v2 entries: corrections are signed events
    ((verify)          (event-log-verify-chain ld))

    ;; compaction: fold everything below the head into a checkpoint carrying
    ;; the opaque BLOB (the observer's serialized state), prune the pruned
    ;; prefix from disk, and return the checkpoint SAID (for KEL anchoring).
    ((checkpoint blob)
     (call-with-values (lambda () (event-log-checkpoint ld blob))
       (lambda (new-ld ck)
         (durable-write-checkpoint! dir ck)
         (durable-prune! dir (event-log-base-seq new-ld))
         (bcom (^event-log-store bcom new-ld dir) (ck-said ck)))))
    ((checkpoint-seq)  (event-log-base-seq ld))      ; seq through which compacted
    ((checkpoint-blob) (event-log-checkpoint-blob ld))
    ;; the precise committed frontier given the SAIDs sealed into the scope KEL
    ((frontier anchored-saids) (event-log-frontier ld anchored-saids))

    ;; Fold foreign entries in (idempotent + verifying), write the new ones
    ;; through to disk, return the resulting seq.
    ((import entries)
     (let ((new-ld (event-log-import ld entries)))
       (for-each (lambda (e) (durable-write-entry! dir e))
                 (event-log-export-since new-ld (event-log-seq ld)))
       (bcom (^event-log-store bcom new-ld dir) (event-log-seq new-ld))))

    ;; Offline split-brain reconcile (in-trust-domain operator tool, not a peer
    ;; service): merge a forked custodian's ENTRIES, rebasing their un-committed
    ;; tail above FRONTIER (one past the highest KEL-anchored entry — see
    ;; governance `kel-anchored-saids` / `event-log-frontier`). Persists the
    ;; rebased entries and returns the new seq.
    ((merge entries frontier)
     (let ((new-ld (event-log-merge ld entries #:frontier frontier)))
       (for-each (lambda (e) (durable-write-entry! dir e))
                 (event-log-export-since new-ld (event-log-seq ld)))
       (bcom (^event-log-store bcom new-ld dir) (event-log-seq new-ld))))))

;; Spawn a store for SCOPE (the stream identity / scope AID). With #:dir it
;; restores + verifies any existing on-disk stream first; without, it is a
;; fresh in-memory log.
(define* (spawn-event-log-store scope #:key (dir #f))
  (spawn ^event-log-store
         (if dir (durable-load-event-log dir scope) (empty-event-log scope))
         dir))
