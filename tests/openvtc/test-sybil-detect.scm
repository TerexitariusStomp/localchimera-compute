;;; test-sybil-detect.scm — Sybil-graph anomaly detection (advisory)
;;;
;;; Both heuristics must (a) flag synthetic Sybil topologies, and
;;; (b) NOT flag legitimate community graphs at small sizes.

(use-modules (playnet test harness))
(use-modules (playnet keri acdc) (playnet keri acdc-store)
             (playnet openvtc credentials) (playnet openvtc first-person)
             (playnet openvtc sybil-detect))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1))


(define vat (spawn-vat))


(define* (issue-phc store eco aid #:optional (sponsor #f) (ts 100))
  ($ store 'issue
     (make-personhood-credential eco aid ts
                                  #:sponsor-aid sponsor)))

(define* (issue-vrc store from to phc-said #:optional (ts 200))
  ($ store 'issue
     (make-relationship-credential from to 'trust phc-said ts)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Sponsor fan-out anomaly: one bad sponsor among normal peers
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Sponsor fan-out anomaly ──\n")

(with-vat vat
  (define eco "E_eco_fanout")
  (define store (spawn-acdc-store))

  ;; Founders (no sponsor):
  (issue-phc store eco "alice")
  (issue-phc store eco "bob")
  (issue-phc store eco "carol")

  ;; Each founder invites 1-2 normal newcomers.
  (issue-phc store eco "a-friend1" "alice" 110)
  (issue-phc store eco "b-friend1" "bob" 120)
  (issue-phc store eco "c-friend1" "carol" 130)
  (issue-phc store eco "c-friend2" "carol" 131)

  ;; Mallory: a corrupted sponsor flooding the ecosystem.
  (issue-phc store eco "mallory")
  (for-each
    (lambda (i)
      (issue-phc store eco
                 (string-append "m-spawn-" (number->string i))
                 "mallory" (+ 200 i)))
    (iota 12))

  (let ((flagged (suspicious-sponsors store eco
                                       #:multiple 3
                                       #:floor 3)))
    (check-pred "mallory flagged"
                (assoc "mallory" flagged))
    (check-pred "alice NOT flagged (count=1)"
                (not (assoc "alice" flagged)))
    (check-pred "bob NOT flagged"
                (not (assoc "bob" flagged)))
    (check-pred "carol NOT flagged (count=2 within tolerance)"
                (not (assoc "carol" flagged)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. VRC cluster signature: closed mutual clique vs. legit graph
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. VRC cluster signature ──\n")

(with-vat vat
  (define eco "E_eco_cluster")
  (define store (spawn-acdc-store))

  ;; Two groups: legitimate community (with cross-edges) + closed Sybil cluster.
  (define peers '("alice" "bob" "carol" "dave"))
  (for-each (lambda (a) (issue-phc store eco a)) peers)

  ;; Real community: alice ↔ bob, alice ↔ carol, bob ↔ dave. Some
  ;; reciprocity but also out-edges to non-cluster (nobody is closed off).
  (let ((alice-phc (cred-said (phc-for store eco "alice")))
        (bob-phc   (cred-said (phc-for store eco "bob")))
        (carol-phc (cred-said (phc-for store eco "carol")))
        (dave-phc  (cred-said (phc-for store eco "dave"))))
    (issue-vrc store "alice" "bob"   alice-phc)
    (issue-vrc store "bob"   "alice" bob-phc)
    (issue-vrc store "alice" "carol" alice-phc)
    (issue-vrc store "carol" "alice" carol-phc)
    (issue-vrc store "bob"   "dave"  bob-phc)
    (issue-vrc store "dave"  "bob"   dave-phc))

  ;; Sybil cluster: 3 AIDs mutual pairwise, zero out-edges.
  (define sybils '("s1" "s2" "s3"))
  (for-each (lambda (a) (issue-phc store eco a)) sybils)
  (let ((s1-phc (cred-said (phc-for store eco "s1")))
        (s2-phc (cred-said (phc-for store eco "s2")))
        (s3-phc (cred-said (phc-for store eco "s3"))))
    (issue-vrc store "s1" "s2" s1-phc)
    (issue-vrc store "s2" "s1" s2-phc)
    (issue-vrc store "s2" "s3" s2-phc)
    (issue-vrc store "s3" "s2" s3-phc)
    (issue-vrc store "s1" "s3" s1-phc)
    (issue-vrc store "s3" "s1" s3-phc))

  (let ((clusters (suspicious-clusters store eco #:min-size 3)))
    (check "exactly one suspicious cluster"
           (length clusters) 1)
    (let* ((c (car clusters))
           (members (assoc-ref c 'members)))
      (check-pred "cluster has 3 members"
                  (= 3 (assoc-ref c 'size)))
      (check-pred "s1 in cluster"  (member "s1" members))
      (check-pred "s2 in cluster"  (member "s2" members))
      (check-pred "s3 in cluster"  (member "s3" members))
      (check-pred "alice NOT in cluster" (not (member "alice" members))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Top-level dispatch returns both
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. detect-suspicious-subgraphs combines both ──\n")

(with-vat vat
  (define eco "E_eco_combined")
  (define store (spawn-acdc-store))

  (issue-phc store eco "alice")
  (for-each
    (lambda (i)
      (issue-phc store eco
                 (string-append "m-" (number->string i))
                 "alice" (+ 100 i)))
    (iota 10))

  (let ((report (detect-suspicious-subgraphs store eco
                                              #:sponsor-multiple 1
                                              #:sponsor-floor 1)))
    (check-pred "report has suspicious-sponsors key"
                (assoc 'suspicious-sponsors report))
    (check-pred "report has suspicious-clusters key"
                (assoc 'suspicious-clusters report))
    (check-pred "alice flagged in report"
                (assoc "alice"
                       (assoc-ref report 'suspicious-sponsors)))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
