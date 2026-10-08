;;; event-log-test.scm — the portable observer event log (gap #18).
;;;
;;; Pure module, depends only on the keri primitives — needs libblake3.so, so
;;; run under the dev-test manifest:
;;;
;;;   guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
;;;     guile --no-auto-compile -q -L module \
;;;       module/playnet/planner/observation/event-log-test.scm

(use-modules (playnet planner observation event-log)
             (srfi srfi-1)
             (srfi srfi-11)
             (ice-9 ftw))

(define *fails* 0)
(define (ok? name v) (if v (format #t "  ok  ~a~%" name)
                         (begin (set! *fails* (+ *fails* 1))
                                (format #t " FAIL ~a~%" name))))
(define (raises? thunk)
  (catch #t (lambda () (thunk) #f) (lambda _ #t)))

;; A handful of opaque event payloads (the shape bridge/codec produces:
;; string keys, nested measure alists, omitted #f fields).
(define (ev action provider qty)
  `(("action" . ,action) ("provider" . ,provider)
    ("effortQuantity" . (("hasNumericalValue" . ,qty) ("hasUnit" . "hour")))))
(define scope "EScopeAidExamplePrefix0000000000000000000000")
(define payloads
  (list (ev "work" "alice" 2.0) (ev "consume" "bob" 1.0)
        (ev "transfer" "alice" 3.5) (ev "work" "carol" 0.25)))

;; Build a log by appending all payloads. (event-log-append returns 2 values.)
(define (build-log)
  (fold (lambda (p l) (call-with-values (lambda () (event-log-append l p))
                        (lambda (nl _e) nl)))
        (empty-event-log scope) payloads))

(define L (build-log))

(format #t "== chain construction ==~%")
(ok? "seq advances to N"        (= (event-log-seq L) (length payloads)))
(ok? "head is non-empty SAID"   (and (string? (event-log-head L))
                                      (string-prefix? "E" (event-log-head L))))
(ok? "verify-chain passes"      (event-log-verify-chain L))
(ok? "payloads replay in order" (equal? (event-log-payloads L) payloads))
(ok? "genesis prev is empty"    (string=? (entry-prev (first (event-log-list L))) ""))
(ok? "each prev links to head"
     (let loop ((es (event-log-list L)) (prev "") (good #t))
       (if (null? es) good
           (loop (cdr es) (entry-said (car es))
                 (and good (string=? (entry-prev (car es)) prev))))))

(format #t "== determinism (content address) ==~%")
(ok? "same events ⇒ same head"  (string=? (event-log-head L) (event-log-head (build-log))))
(ok? "distinct SAIDs per entry"
     (= (length payloads)
        (length (delete-duplicates (map entry-said (event-log-list L))))))

(format #t "== tamper detection ==~%")
(let* ((es (event-log-list L))
       (mid (second es))
       ;; forge the payload but keep the original SAID — verify must reject
       (forged (map (lambda (kv) (if (string=? (car kv) "e")
                                     (cons "e" (ev "work" "mallory" 999.0)) kv))
                    mid)))
  (ok? "good entry verifies"     (verify-entry mid))
  (ok? "forged entry fails SAID" (not (verify-entry forged))))

(format #t "== entry versions: v1 corrections replace, v2 corrections are signed events ==~%")
(let* ((make-entry (@@ (playnet planner observation event-log) make-entry))
       (old (make-entry "PEL1" scope 0 "" (ev "work" "alice" 2.0)))
       (l1  (event-log-import (empty-event-log scope) (list old)))
       (l2  (call-with-values (lambda () (event-log-append l1 (ev "work" "bob" 1.0))) (lambda (nl _e) nl))))
  (ok? "a new entry is v2"                     (equal? "PEL2" (entry-version (car (event-log-list L)))))
  (ok? "a v1 entry still verifies and chains"  (and (verify-entry old) (event-log-verify-chain l2)))
  (ok? "the legacy payloads are the v1 entries'" (equal? (event-log-legacy-payloads l2) (list (ev "work" "alice" 2.0))))
  (ok? "the current payloads are the rest"       (equal? (event-log-current-payloads l2) (list (ev "work" "bob" 1.0)))))

(format #t "== merge and rebase keep each entry's version ==~%")
(let* ((make-entry (@@ (playnet planner observation event-log) make-entry))
       (old   (make-entry "PEL1" scope 0 "" (ev "work" "alice" 2.0)))
       (ff    (event-log-merge (empty-event-log scope) (list old)))
       (base  (call-with-values (lambda () (event-log-append (empty-event-log scope) (ev "work" "bob" 1.0)))
                (lambda (nl _e) nl)))
       (rb    (event-log-merge base (list old))))
  (ok? "a v1 entry fast-forwarded in stays v1"      (equal? (event-log-legacy-payloads ff) (list (ev "work" "alice" 2.0))))
  (ok? "a v1 entry rebased onto a log stays v1"     (equal? (event-log-legacy-payloads rb) (list (ev "work" "alice" 2.0))))
  (ok? "…and the log's own v2 entry stays v2"       (equal? (event-log-current-payloads rb) (list (ev "work" "bob" 1.0))))
  (ok? "…and the merged chain verifies"             (event-log-verify-chain rb)))

(format #t "== import: idempotent / chain / fork ==~%")
(let ((all (event-log-list L)))
  (ok? "import full chain onto empty"
       (let ((l2 (event-log-import (empty-event-log scope) all)))
         (and (= (event-log-seq l2) (length payloads))
              (string=? (event-log-head l2) (event-log-head L)))))
  (ok? "re-import is idempotent"
       (let ((l2 (event-log-import (event-log-import (empty-event-log scope) all) all)))
         (= (event-log-seq l2) (length payloads))))
  (ok? "incremental import (export-since)"
       (let* ((half (event-log-import (empty-event-log scope)
                                      (event-log-export-since L 0)))
              (more (event-log-import half (event-log-export-since L 2))))
         (string=? (event-log-head more) (event-log-head L))))
  (ok? "fork is rejected"
       (raises?
        (lambda ()
          ;; a second, different log over the SAME scope diverges at seq 0
          (let-values (((forked _e)
                        (event-log-append (empty-event-log scope) (ev "work" "x" 1.0))))
            (event-log-import L (event-log-list forked)))))))

(format #t "== durable round-trip ==~%")
(let* ((dir (string-append "/tmp/pel-test-"
                           (number->string (getpid)) "-" (number->string (random 1000000)))))
  (mkdir dir)
  (for-each (lambda (e) (durable-write-entry! dir e)) (event-log-list L))
  (let ((loaded (durable-load-event-log dir scope)))   ; head/seq recovered by scan
    (ok? "loaded chain verifies"  (event-log-verify-chain loaded))
    (ok? "loaded head matches"    (string=? (event-log-head loaded) (event-log-head L)))
    (ok? "loaded payloads match"  (equal? (event-log-payloads loaded) payloads)))
  ;; tamper a file on disk → load must fail loudly
  (let* ((victim (first (event-log-list L)))
         (path   (string-append dir "/" (substring (entry-said victim) 0 2)
                                "/" (entry-said victim) ".scm")))
    (call-with-output-file path
      (lambda (p) (write (map (lambda (kv) (if (string=? (car kv) "e")
                                               (cons "e" (ev "work" "evil" 0.0)) kv))
                              victim) p)))
    (ok? "tampered file fails load" (raises? (lambda () (durable-load-event-log dir scope)))))
  ;; clean up
  (system* "rm" "-rf" dir))

(format #t "== multi-custody: a forked durable stream loads loudly ==~%")
;; single-writer is the invariant; if two custodians append independently and
;; their files later sync into one dir, the divergence MUST surface on load
;; (no silent merge). Build a second writer's divergent entry at an existing
;; seq and drop it alongside the honest chain.
(let ((dir (string-append "/tmp/pel-fork-" (number->string (getpid))
                          "-" (number->string (random 1000000)))))
  (mkdir dir)
  (for-each (lambda (e) (durable-write-entry! dir e)) (event-log-list L))
  (let* ((L2 (fold (lambda (p l) (call-with-values (lambda () (event-log-append l p))
                                   (lambda (nl _e) nl)))
                   (empty-event-log scope)
                   (list (ev "consume" "x" 9.0) (ev "work" "y" 8.0) (ev "use" "z" 7.0))))
         (fork-entry (list-ref (event-log-list L2) 2)))   ; seq 2, divergent content
    (durable-write-entry! dir fork-entry))
  (ok? "forked durable stream rejected on load"
       (raises? (lambda () (durable-load-event-log dir scope))))
  (system* "rm" "-rf" dir))

(format #t "== multi-custody: rebase resolution (KEL frontier) ==~%")
(let* ((ap (lambda (l p) (call-with-values (lambda () (event-log-append l p))
                           (lambda (nl _e) nl))))
       (shared (fold (lambda (p l) (ap l p)) (empty-event-log scope)
                     (list (ev "work" "s0" 1.0) (ev "work" "s1" 1.0))))
       (base  (fold (lambda (p l) (ap l p)) shared
                    (list (ev "work" "A" 2.0) (ev "work" "B" 3.0))))
       (other (fold (lambda (p l) (ap l p)) shared
                    (list (ev "consume" "C" 4.0) (ev "consume" "D" 5.0)))))
  ;; diverge at seq 2; frontier 2 ⇒ un-committed ⇒ rebase the foreign tail
  (let ((merged (event-log-merge base (event-log-list other) #:frontier 2)))
    (ok? "rebase merges to 6 entries"  (= (event-log-seq merged) 6))
    (ok? "rebased chain verifies"      (event-log-verify-chain merged))
    (ok? "base tail preserved"         (and (member (ev "work" "A" 2.0)
                                                    (event-log-payloads merged)) #t))
    (ok? "foreign tail preserved"      (and (member (ev "consume" "C" 4.0)
                                                    (event-log-payloads merged)) #t)))
  ;; fast-forward: foreign = base + one more ⇒ plain append, SAID preserved
  (let* ((ahead  (ap base (ev "work" "E" 6.0)))
         (merged (event-log-merge base (event-log-list ahead) #:frontier 0)))
    (ok? "fast-forward appends"        (= (event-log-seq merged) 5))
    (ok? "fast-forward preserves SAID" (string=? (event-log-head merged) (event-log-head ahead))))
  ;; committed fork below the frontier ⇒ raise (a real KEL-level fork)
  (ok? "committed fork below frontier raises"
       (raises? (lambda () (event-log-merge base (event-log-list other) #:frontier 4)))))

(format #t "== KEL frontier (precise committed bound) ==~%")
(let ((es (event-log-list L)))
  (ok? "no anchors ⇒ frontier = base"
       (= (event-log-frontier L '()) (event-log-base-seq L)))
  (ok? "anchored entry ⇒ frontier = its seq + 1"
       (= (event-log-frontier L (list (entry-said (list-ref es 2)))) 3))
  (ok? "anchored head ⇒ frontier = next (whole chain committed)"
       (= (event-log-frontier L (list (event-log-head L))) (event-log-seq L))))

(format #t "== compaction (checkpoint + prune + resume) ==~%")
(let* ((blob "OPAQUE-OBSERVER-STATE-AS-OF-seq4"))
  (call-with-values (lambda () (event-log-checkpoint L blob))
    (lambda (Lc ck)
      (ok? "checkpoint subsumes upto=next" (= (ck-upto ck) (length payloads)))
      (ok? "checkpoint prev = old head"    (string=? (ck-prev ck) (event-log-head L)))
      (ok? "checkpoint verifies"           (verify-checkpoint ck))
      (ok? "compacted base advances"       (= (event-log-base-seq Lc) (length payloads)))
      (ok? "compacted holds no entries"    (null? (event-log-list Lc)))
      (ok? "compacted head unchanged"      (string=? (event-log-head Lc) (event-log-head L)))
      (ok? "blob recoverable"              (string=? (event-log-checkpoint-blob Lc) blob))
      ;; append past the cut — the chain still verifies across the boundary
      (let-values (((Lc2 e5) (event-log-append Lc (ev "work" "post" 1.0))))
        (ok? "post-checkpoint seq continues" (= (entry-seq e5) (length payloads)))
        (ok? "post-checkpoint prev = head"   (string=? (entry-prev e5) (event-log-head L)))
        (ok? "chain verifies across cut"     (event-log-verify-chain Lc2))
        (ok? "tail payload is the new one"   (equal? (event-log-payloads Lc2)
                                                     (list (ev "work" "post" 1.0))))))))

(format #t "== compaction durable round-trip + prune ==~%")
(let ((dir (string-append "/tmp/pel-ck-" (number->string (getpid))
                          "-" (number->string (random 1000000))))
      (blob "OPAQUE-OBSERVER-STATE-AS-OF-seq4"))
  (mkdir dir)
  ;; write all 5 entries, then checkpoint at the head + prune the prefix
  (for-each (lambda (e) (durable-write-entry! dir e)) (event-log-list L))
  (call-with-values (lambda () (event-log-checkpoint L blob))
    (lambda (Lc ck)
      (durable-write-checkpoint! dir ck)
      (durable-prune! dir (event-log-base-seq Lc))
      ;; one post-checkpoint event lands on disk
      (let-values (((Lc2 e5) (event-log-append Lc (ev "work" "post" 1.0))))
        (durable-write-entry! dir e5)
        (let ((loaded (durable-load-event-log dir scope)))
          (ok? "loaded resumes at base"      (= (event-log-base-seq loaded) (length payloads)))
          (ok? "loaded next is base+1"       (= (event-log-seq loaded) (+ 1 (length payloads))))
          (ok? "loaded blob preserved"       (string=? (event-log-checkpoint-blob loaded) blob))
          (ok? "loaded chain verifies"       (event-log-verify-chain loaded))
          (ok? "loaded tail = post only"     (equal? (event-log-payloads loaded)
                                                     (list (ev "work" "post" 1.0))))
          (ok? "pruned files are gone"
               (let ((victim (first (event-log-list L))))
                 (not (file-exists? (string-append dir "/" (substring (entry-said victim) 0 2)
                                                   "/" (entry-said victim) ".scm")))))))))
  (system* "rm" "-rf" dir))

(format #t "~%~a~%" (if (zero? *fails*) "ALL PASS" (format #f "~a FAILURE(S)" *fails*)))
(exit (if (zero? *fails*) 0 1))
