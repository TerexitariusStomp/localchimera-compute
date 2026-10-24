;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-history-signatures.scm — tests for cryptographic history entry signatures
;;; Run with:  guile -L module tests/test-history-signatures.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (localchimera test harness))
(use-modules (localchimera org gplay)
             (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             ((goblins utils crypto) #:select (generate-key-pair key-pair->public-key))
             (ice-9 receive)
             (ice-9 match)
             (srfi srfi-1))

;;; ── Harness ─────────────────────────────────────────────────────────────────
;;; ── Base bindings ───────────────────────────────────────────────────────────

(define test-base-bindings
  `((+       . ,+)
    (-       . ,-)
    (*       . ,*)
    (>       . ,>)
    (<       . ,<)
    (=       . ,=)
    (equal?  . ,equal?)
    (eqv?    . ,eqv?)
    (not     . ,not)
    (null?   . ,null?)
    (cons    . ,cons)
    (car     . ,car)
    (cdr     . ,cdr)
    (list    . ,list)
    (length  . ,length)
    (generate-key-pair . ,generate-key-pair)))

;;; ── Shared test vat ─────────────────────────────────────────────────────────

(define test-vat (spawn-vat))

(display "\n── History Signature Tests ──────────────────────────────────\n\n")

;;; ── Test 1: defexpressor with keypair stores keypair ────────────────────────

(display "1. defexpressor with keypair stores keypair in expressor-store\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    ;; Pass keypair via local-bindings; reference as symbol 'kp in expression
    (let ((sealer (evaluate '(defexpressor 'alice kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      (let* ((store ($ org 'expressor-store))
             ;; Alice's entry is most recent (at head)
             (alice-data (cdar store)))
        (check "1a: public-key extracted from keypair"
               (assq-ref alice-data 'public-key) pk)
        (check "1b: keypair stored in expressor data"
               (equal? (assq-ref alice-data 'keypair) kp) #t)))))

;;; ── Test 2: modify! by expressor with keypair produces signed entry ─────────

(display "\n2. modify! by expressor with keypair produces signed history entry\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    (let ((sealer (evaluate '(defexpressor 'bob kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      ;; Switch to bob and modify
      (evaluate '(as seal (modify! 'x 42)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      ;; Check latest history entry has a signature (6th element)
      (let* ((history ($ org 'history))
             (latest (car history)))
        (check "2a: history entry has 6 elements"
               (length latest) 6)
        (check "2b: signature is not #f"
               (not (not (list-ref latest 5))) #t)))))

;;; ── Test 3: verify-history-entry returns #t for valid entry ─────────────────

(display "\n3. verify-history-entry returns #t for valid entry\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    (let ((sealer (evaluate '(defexpressor 'carol kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      (evaluate '(as seal (modify! 'y 99)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             (latest (car history)))
        (check "3: verify returns #t"
               (verify-history-entry latest pk) #t)))))

;;; ── Test 4: verify-history-entry returns #f for tampered expression ─────────

(display "\n4. verify-history-entry returns #f for tampered expression\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    (let ((sealer (evaluate '(defexpressor 'dave kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      (evaluate '(as seal (modify! 'z 77)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             (entry (car history))
             ;; Tamper: change the expression (3rd element)
             (tampered (list (list-ref entry 0)
                             (list-ref entry 1)
                             '(modify! 'z 9999)  ;; tampered
                             (list-ref entry 3)
                             (list-ref entry 4)
                             (list-ref entry 5))))
        (check "4: verify returns #f for tampered expression"
               (verify-history-entry tampered pk) #f)))))

;;; ── Test 5: verify-history-entry returns #f for tampered version ────────────

(display "\n5. verify-history-entry returns #f for tampered version\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    (let ((sealer (evaluate '(defexpressor 'eve kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      (evaluate '(as seal (modify! 'w 55)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             (entry (car history))
             ;; Tamper: change the version (1st element)
             (tampered (list 999999
                             (list-ref entry 1)
                             (list-ref entry 2)
                             (list-ref entry 3)
                             (list-ref entry 4)
                             (list-ref entry 5))))
        (check "5: verify returns #f for tampered version"
               (verify-history-entry tampered pk) #f)))))

;;; ── Test 6: expressor without keypair (string key) produces sig=#f ──────────

(display "\n6. modify! by expressor without keypair (string key) produces sig=#f\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings)))
    (let ((sealer (evaluate '(defexpressor 'frank "ssh-ed25519 AAAA...") org
                            '() ($ org 'current-expressor))))
      (evaluate '(as seal (modify! 'a 10)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             (latest (car history)))
        (check "6a: entry has 6 elements"
               (length latest) 6)
        (check "6b: signature is #f for string-key expressor"
               (list-ref latest 5) #f)))))

;;; ── Test 7: verify-history-entry returns #f for unsigned entry ──────────────

(display "\n7. verify-history-entry returns #f for unsigned entry\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    ;; Use string-key expressor
    (let ((sealer (evaluate '(defexpressor 'grace "no-key") org
                            '() ($ org 'current-expressor))))
      (evaluate '(as seal (modify! 'b 20)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let ((entry (car ($ org 'history))))
        (check "7: verify returns #f for unsigned entry"
               (verify-history-entry entry pk) #f)))))

;;; ── Test 8: multiple expressors — each entry signed with own key ────────────

(display "\n8. Multiple expressors — each entry signed with their own key\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp-a (generate-key-pair))
         (pk-a (key-pair->public-key kp-a))
         (kp-b (generate-key-pair))
         (pk-b (key-pair->public-key kp-b)))
    (let* ((seal-a (evaluate '(defexpressor 'hank kp-a) org
                             (list (cons 'kp-a kp-a)) ($ org 'current-expressor)))
           (seal-b (evaluate '(defexpressor 'iris kp-b) org
                             (list (cons 'kp-b kp-b)) ($ org 'current-expressor))))
      ;; hank modifies
      (evaluate '(as seal-a (modify! 'h 100)) org
                (list (cons 'seal-a seal-a)) ($ org 'current-expressor))
      ;; iris modifies
      (evaluate '(as seal-b (modify! 'i 200)) org
                (list (cons 'seal-b seal-b)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             (iris-entry (car history))       ;; most recent
             (hank-entry (cadr history)))     ;; second most recent
        ;; Each verifies with own key
        (check "8a: hank's entry verifies with hank's key"
               (verify-history-entry hank-entry pk-a) #t)
        (check "8b: iris's entry verifies with iris's key"
               (verify-history-entry iris-entry pk-b) #t)
        ;; Cross-key verification fails
        (check "8c: hank's entry fails with iris's key"
               (verify-history-entry hank-entry pk-b) #f)
        (check "8d: iris's entry fails with hank's key"
               (verify-history-entry iris-entry pk-a) #f)))))

;;; ── Test 9: history replay — all entries verify ─────────────────────────────

(display "\n9. History replay: all signed entries verify against expressor's key\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    (let ((sealer (evaluate '(defexpressor 'jane kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      ;; Multiple modifications
      (evaluate '(as seal (modify! 'p 1)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (evaluate '(as seal (modify! 'q 2)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (evaluate '(as seal (modify! 'r 3)) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             ;; Filter to only signed entries (skip genesis and defexpressor-by-genesis)
             (signed (filter (lambda (e)
                               (and (>= (length e) 6)
                                    (list-ref e 5)))
                             history))
             (all-valid (every (lambda (e)
                                (verify-history-entry e pk))
                              signed)))
        (check "9: all signed entries verify"
               all-valid #t)))))

;;; ── Test 10: enact! entry is signed too ─────────────────────────────────────

(display "\n10. enact! entry is signed too\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    (let ((sealer (evaluate '(defexpressor 'karl kp) org
                            (list (cons 'kp kp)) ($ org 'current-expressor))))
      ;; enact! a new validator
      (evaluate '(as seal (enact! (lambda (e n v pre post) #t))) org
                (list (cons 'seal sealer)) ($ org 'current-expressor))
      (let* ((history ($ org 'history))
             (latest (car history)))
        (check "10a: enact! entry has 6 elements"
               (length latest) 6)
        (check "10b: enact! entry is signed"
               (not (not (list-ref latest 5))) #t)
        (check "10c: enact! entry verifies"
               (verify-history-entry latest pk) #t)))))

;;; ── Test 11: defexpressor entry itself is signed by acting expressor ────────

(display "\n11. defexpressor entry itself is signed by the acting expressor\n")
(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (kp-founder (generate-key-pair))
         (pk-founder (key-pair->public-key kp-founder)))
    ;; Create founder with keypair
    (let ((founder-seal (evaluate '(defexpressor 'founder kp) org
                                  (list (cons 'kp kp-founder))
                                  ($ org 'current-expressor))))
      ;; Now founder registers another expressor — this defexpressor entry
      ;; is signed by founder (the acting expressor)
      (let ((kp-new (generate-key-pair)))
        (evaluate '(as seal (defexpressor 'newbie kp-new)) org
                  (list (cons 'seal founder-seal) (cons 'kp-new kp-new))
                  ($ org 'current-expressor))
        (let* ((history ($ org 'history))
               (latest (car history)))
          (check "11a: defexpressor entry has 6 elements"
                 (length latest) 6)
          (check "11b: defexpressor entry is signed"
                 (not (not (list-ref latest 5))) #t)
          (check "11c: defexpressor entry verifies with founder's key"
                 (verify-history-entry latest pk-founder) #t))))))

;;; ── Test 12: genesis entry has sig=#f ───────────────────────────────────────

(display "\n12. Genesis entry has sig=#f (no keypair)\n")
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (let* ((history ($ org 'history))
           (genesis (car history)))
      (check "12a: genesis entry has 6 elements"
             (length genesis) 6)
      (check "12b: genesis sig is #f"
             (list-ref genesis 5) #f))))

;;; ── Test 13: entry->signing-bytes is deterministic ──────────────────────────

(display "\n13. entry->signing-bytes is deterministic\n")
(let ((b1 (entry->signing-bytes 42 'alice-1 '(modify! 'x 10) 41))
      (b2 (entry->signing-bytes 42 'alice-1 '(modify! 'x 10) 41)))
  (check "13: same inputs produce identical bytes"
         (equal? b1 b2) #t))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(display "\n────────────────────────────────────────────────────────────\n")
(test-summary!)
(when (> fail-count 0)
  (exit 1))
