;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-governed-org.scm — tests for make-governed-org
;;; Run with: guile -L module tests/test-governed-org.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet test harness))
(use-modules (playnet org factories)
             (playnet org gplay)
             (playnet utils endorsement)
             (goblins)
             (ice-9 receive))

;;; ── Harness ─────────────────────────────────────────────────────────────────
(display "== Governed Org Tests ==\n")

;;; ── 1. make-governed-org returns 4 values ───────────────────────────────────

(display "\n-- 1. make-governed-org returns 4 values --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-gov")
  (check "org is an org" (org? org) #t)
  (check "org name" (org-name org) "test-gov")
  (check "gov-seal is not #f" (not (not gov-seal)) #t)
  (check "infra-seal is not #f" (not (not infra-seal)) #t)
  (check "member-seal is not #f" (not (not member-seal)) #t))

;;; ── 2. Ungoverned names: freely modifiable ──────────────────────────────────

(display "\n-- 2. ungoverned names freely modifiable --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-free")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      (evaluate '(modify! 'x 42) ref '() gen)
      (check "set ungoverned name" (evaluate 'x ref '() gen) 42)
      (evaluate '(modify! 'y "hello") ref '() gen)
      (check "set another ungoverned name" (evaluate 'y ref '() gen) "hello")
      (evaluate '(modify! 'x 99) ref '() gen)
      (check "overwrite ungoverned name" (evaluate 'x ref '() gen) 99))))

;;; ── 3. infra-* blocked without infra-seal ───────────────────────────────────

(display "\n-- 3. infra-* blocked without infra-seal --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-infra-block")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      (check-error "infra-deploy blocked without seal"
        (lambda () (evaluate '(modify! 'infra-deploy "my-deployer") ref '() gen)))
      (check-error "infra-server blocked without seal"
        (lambda () (evaluate '(modify! 'infra-server "prod-1") ref '() gen))))))

;;; ── 4. infra-* allowed with infra-seal ──────────────────────────────────────

(display "\n-- 4. infra-* allowed with infra-seal --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-infra-allow")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      ;; Pass infra-seal as a local binding so evaluate can use it
      (evaluate '(modify! 'infra-deploy (endorse "my-deployer" seal-infra))
                ref
                `((seal-infra . ,infra-seal))
                gen)
      (check "infra-deploy set with endorsement"
             (pair? (assq 'infra-deploy ($ ref 'bindings))) #t))))

;;; ── 5. member-* blocked without member-seal ─────────────────────────────────

(display "\n-- 5. member-* blocked without member-seal --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-member-block")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      (check-error "member-alice blocked without seal"
        (lambda () (evaluate '(modify! 'member-alice "alice-key") ref '() gen))))))

;;; ── 6. member-* allowed with member-seal ────────────────────────────────────

(display "\n-- 6. member-* allowed with member-seal --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-member-allow")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      (evaluate '(modify! 'member-alice (endorse "alice-key" seal-member))
                ref
                `((seal-member . ,member-seal))
                gen)
      (check "member-alice set with endorsement"
             (pair? (assq 'member-alice ($ ref 'bindings))) #t))))

;;; ── 7. gov-seal controls enact! ─────────────────────────────────────────────

(display "\n-- 7. gov-seal controls enact! --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-enact")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      ;; enact! without endorsement should fail
      (check-error "enact! blocked without gov-seal"
        (lambda () (evaluate '(enact! (lambda (e n v pre post) #t)) ref '() gen)))
      ;; enact! with endorsement should work
      (evaluate '(enact! (lambda (e n v pre post) #t)
                         (endorse (lambda (e n v pre post) #t) gov-seal))
                ref
                `((gov-seal . ,gov-seal))
                gen)
      (check "enact! with gov-seal succeeds" #t #t))))

;;; ── 8. Cross-domain: infra-seal cannot authorize member-* ───────────────────

(display "\n-- 8. cross-domain isolation --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-cross")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      (check-error "infra-seal cannot authorize member-*"
        (lambda ()
          (evaluate '(modify! 'member-bob (endorse "bob" seal-infra))
                    ref
                    `((seal-infra . ,infra-seal))
                    gen)))
      (check-error "member-seal cannot authorize infra-*"
        (lambda ()
          (evaluate '(modify! 'infra-db (endorse "db" seal-member))
                    ref
                    `((seal-member . ,member-seal))
                    gen))))))

;;; ── 9. Ungoverned names still work alongside governed ones ──────────────────

(display "\n-- 9. governed and ungoverned coexist --\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-coexist")
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      ;; Ungoverned
      (evaluate '(modify! 'budget 50000) ref '() gen)
      (check "ungoverned budget set" (evaluate 'budget ref '() gen) 50000)
      ;; Governed infra
      (evaluate '(modify! 'infra-nginx (endorse "nginx-cap" seal-infra))
                ref
                `((seal-infra . ,infra-seal))
                gen)
      (check "infra-nginx set" (pair? (assq 'infra-nginx ($ ref 'bindings))) #t)
      ;; Ungoverned still works after governed
      (evaluate '(modify! 'budget 60000) ref '() gen)
      (check "ungoverned budget updated" (evaluate 'budget ref '() gen) 60000))))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
