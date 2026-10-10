;;; test-event-log-integration.scm — the portable event log, wired to a live
;;; observer (gap #18). Two parts:
;;;   A. the ^event-log-store actor in a vat (opaque payloads): append, head,
;;;      export-since, import, verify, durable respawn, replay.
;;;   B. a live scope: the observer's log-sink callback forwards real recorded
;;;      EconomicEvents into the store — proving record-event fires the sink and
;;;      the stream captures the scope's economic history self-certifyingly.
;;;
;;;   guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module tests/planner/test-event-log-integration.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet observation observer) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service)
             (playnet observation event-log)
             (playnet observation event-log-store)
             (playnet governance acdc-bridge) (playnet keys kel-store)
             (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 ftw))

(define tmp (string-append "/tmp/pel-int-" (number->string (getpid))))

;; ─────────────────────────────────────────────────────────────────────────
;; Part A — the store actor, opaque payloads, in a vat
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── A: ^event-log-store actor ──\n")
(define vatA (spawn-vat))            ; durability is the store's own disk dir, not syrup

(define scope-aid "EScopeAidExampleAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define dirA (string-append tmp "-A"))
(define (pay i) `(("action" . "work") ("provider" . ,(string-append "w" (number->string i)))
                  ("effortQuantity" . (("hasNumericalValue" . ,(* 0.5 i)) ("hasUnit" . "hour")))))

(with-vat vatA
  (define st (spawn-event-log-store scope-aid #:dir dirA))
  (for-each (lambda (i) ($ st 'append (pay i))) (iota 5 1))
  (check "seq advances to 5" ($ st 'seq) 5)
  (check-pred "head is a SAID" (let ((h ($ st 'head))) (and (string? h) (string-prefix? "E" h))))
  (check "chain verifies" ($ st 'verify) #t)
  (check "payloads replay in order" ($ st 'payloads) (map pay (iota 5 1)))

  ;; durable respawn: a fresh store over the SAME dir restores identically
  (define st2 (spawn-event-log-store scope-aid #:dir dirA))
  (check "respawn restores seq" ($ st2 'seq) 5)
  (check "respawn restores head" ($ st2 'head) ($ st 'head))
  (check "respawn chain verifies" ($ st2 'verify) #t)

  ;; cross-vat import: a third store imports the exported tail
  (define st3 (spawn-event-log-store "EScopeAidExampleAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
  ($ st3 'import ($ st 'export-since 0))
  (check "imported seq matches" ($ st3 'seq) 5)
  (check "imported head matches" ($ st3 'head) ($ st 'head)))

;; ─────────────────────────────────────────────────────────────────────────
;; Part B — wired to a live observer via the log-sink callback
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── B: observer log-sink → store ──\n")
(define store-B (make-memory-store))
(define-values (vatB scope)
  (spawn-persistent-vat scope-root-env
                        (lambda () (spawn-scope-root "Event Log Test")) store-B))

(define dirB (string-append tmp "-B"))

;; A 'work EconomicEvent, built directly — so the test exercises the
;; observer → sink → stream path without going through the service layer.
(define (mk-work id provider hours)
  (make-economic-event
    #:id id #:action 'work #:provider provider
    #:effort-quantity (make-measure hours %effort-unit)
    #:in-scope-of '()))

(with-vat vatB
  (define obs ($ scope 'observer))
  (define log (spawn-event-log-store "org:test" #:dir dirB))
  ;; THE WIRING: every recorded EconomicEvent mirrors into the portable stream
  ($ obs 'set-callback 'log-sink
     (lambda (ev) ($ log 'append (economic-event->list ev))))

  (check "log starts empty" ($ log 'seq) 0)

  ;; record two events straight into the observer; the sink mirrors them
  ($ obs 'record-event (mk-work "ev-1" "alice" 2.0))
  ($ obs 'record-event (mk-work "ev-2" "bob"   1.5))
  (check "both events logged" ($ log 'seq) 2)
  (check "logged chain verifies" ($ log 'verify) #t)

  ;; replay: fold the stream's payloads into a FRESH observer and confirm it
  ;; reconstructs the same recorded events (portability end-to-end)
  (define replayed (map list->economic-event ($ log 'payloads)))
  (check-pred "replay yields the EconomicEvents"
              (and (= 2 (length replayed)) (every economic-event? replayed)))
  (check "replayed action is work"
         (economic-event-action (car replayed)) 'work)

  ;; ── C: cross-gateway restore (the install-credentialing! discipline) ──
  ;; a FRESH scope's observer comes up empty; folding the portable stream back
  ;; in rebuilds its event-sourced state — and because no sink is wired on the
  ;; fresh observer during replay, the stream is NOT re-appended.
  (define payloads ($ log 'payloads))
  (define scope2 (spawn-scope-root "Restore Test"))
  (define obs2 ($ scope2 'observer))
  (check "fresh observer is empty" ($ obs2 'event-count) 0)
  (when (and (zero? ($ obs2 'event-count)) (pair? payloads))   ; replay-if-empty
    (for-each (lambda (p) ($ obs2 'record-event (list->economic-event p))) payloads))
  (check "observer rebuilt from stream" ($ obs2 'event-count) (length payloads))
  (check "rebuilt action is work"
         (economic-event-action (car ($ obs2 'all-events))) 'work)
  (check "stream not re-appended during replay" ($ log 'seq) (length payloads))

  ;; ── D: DURABLE compaction with REAL observer state ──
  ;; checkpoint folds the observer's (write-safe) snapshot to disk + prunes;
  ;; a fresh store resumes at the cut and a fresh observer restores from it.
  (define prior-seq ($ log 'seq))
  (define blob ($ obs 'serialize))
  (define ck-said ($ log 'checkpoint blob))            ; writes _checkpoint, prunes
  (check-pred "checkpoint returns a SAID"
              (and (string? ck-said) (string-prefix? "E" ck-said)))
  (check "checkpoint-seq advanced to the head" ($ log 'checkpoint-seq) prior-seq)
  (check "tail pruned (no live entries)" ($ log 'payloads) '())
  (check "chain still verifies after compaction" ($ log 'verify) #t)
  ;; durable reload from disk resumes at the checkpoint (blob round-tripped)
  (define log2 (spawn-event-log-store "org:test" #:dir dirB))
  (check "durable reload resumes at checkpoint" ($ log2 'checkpoint-seq) prior-seq)
  ;; a fresh observer restores fully from the reloaded checkpoint blob
  (define obs3 ($ (spawn-scope-root "Compact Restore") 'observer))
  ($ obs3 'load-snapshot ($ log2 'checkpoint-blob))
  (check "restored-from-durable-checkpoint event-count matches"
         ($ obs3 'event-count) ($ obs 'event-count)))

;; ─────────────────────────────────────────────────────────────────────────
;; Part E — multi-custody reconcile with the KEL-anchored frontier
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── E: reconcile via KEL frontier ──\n")
(define rscope "EScopeReconcileAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
;; a minimal KEL ixn body that seals SAID into the scope's KEL
(define (ixn-sealing said tag)
  (list (cons "name" (string-append "scope-" rscope))
        (cons "ixn" (list (cons "d" (string-append "Eixn" tag "00000000000000000000000000000000000000"))
                          (cons "a" (vector (list (cons "d" said))))))
        (cons "sigs" (vector))))

(with-vat vatA
  (define local (spawn-event-log-store rscope))
  (for-each (lambda (p) ($ local 'append p)) (map pay (iota 4 1)))   ; seqs 0..3
  ;; a peer custodian that shares seqs 0,1 then diverges at seq 2
  (define foreign
    (let loop ((l (empty-event-log rscope))
               (ps (list (pay 1) (pay 2) (pay 90) (pay 91))))
      (if (null? ps) l
          (call-with-values (lambda () (event-log-append l (car ps)))
            (lambda (nl _e) (loop nl (cdr ps)))))))
  (define foreign-entries (event-log-list foreign))
  (define said@1 (entry-said (car ($ local 'export-since 1))))    ; SAID of entry at seq 1

  ;; KEL anchors seq 1 → committed through 1 → frontier 2 → the divergent tail
  ;; (seq ≥ 2) is un-committed and rebases
  (define kel (spawn-kel-store))
  ($ kel 'append (ixn-sealing said@1 "a"))
  (check "kel-anchored-saids surfaces the seal"
         (and (member said@1 (kel-anchored-saids kel)) #t) #t)
  (check "frontier from KEL = anchored seq + 1" ($ local 'frontier (kel-anchored-saids kel)) 2)
  (event-log-reconcile! local kel foreign-entries)
  (check "reconcile rebased the divergent tail" ($ local 'seq) 6)
  (check "reconcile chain verifies" ($ local 'verify) #t)
  (check "foreign divergent event preserved"
         (and (member (pay 90) ($ local 'payloads)) #t) #t)

  ;; raise the frontier past the divergence (anchor seq 3) → a committed fork
  (define local2 (spawn-event-log-store rscope))
  (for-each (lambda (p) ($ local2 'append p)) (map pay (iota 4 1)))
  (define kel2 (spawn-kel-store))
  ($ kel2 'append (ixn-sealing (entry-said (car ($ local2 'export-since 3))) "b"))
  (check "committed fork (anchored past divergence) is rejected"
         (catch #t (lambda () (event-log-reconcile! local2 kel2 foreign-entries) #f)
                   (lambda _ #t))
         #t))

(system* "rm" "-rf" dirA dirB)
(display "\n✔ event-log integration OK\n")
