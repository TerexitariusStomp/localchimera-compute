;;; tests/governance/test-universal-commune-kind.scm
;;; UC promoted to a first-class 'universal-commune kind.

(use-modules (playnet test harness)
             (playnet governance scope) (playnet governance scope-graph)
             (playnet governance scope-graph)
             (playnet governance universal-commune)
             (playnet governance uc-curator)
             (goblins) (goblins utils hashmap)
             ((srfi srfi-13) #:select (string-contains)))

(define vat (spawn-vat))

(display "\n── 1. UC spawns with 'universal-commune kind ──\n")
(define uc
  (with-vat vat (spawn-universal-commune)))
(with-vat vat
  (check-pred "uc kind tag" (eq? 'universal-commune ($ uc 'kind)))
  (check-pred "uc has scope-aid" (string? ($ uc 'scope-aid))))

(display "\n── 2. Commune-only methods error on UC ──\n")
(with-vat vat
  (let ((gov-cap ($ uc 'mint-gov-cap 'tester)))
    (check-pred "admit-member errors on UC"
      (catch #t
        (lambda () ($ uc 'admit-member gov-cap "did:keri:Eperson") #f)
        (lambda _ #t)))
    (check-pred "exclude-member errors on UC"
      (catch #t
        (lambda () ($ uc 'exclude-member gov-cap "did:keri:Eperson") #f)
        (lambda _ #t)))))

(display "\n── 3. Federation-like methods accept UC ──\n")
(define com
  (with-vat vat
    (spawn-scope "test-commune" #:kind 'commune)))
(with-vat vat
  (let ((gov-cap ($ uc 'mint-gov-cap 'tester)))
    ;; admit-commune passes the kind check and succeeds.
    (check-pred "admit-commune works on UC"
      (let ((res (catch #t
                   (lambda () ($ uc 'admit-commune gov-cap
                                  ($ com 'scope-aid) com) 'ok)
                   (lambda args (cons 'error args)))))
        (eq? res 'ok)))))

(display "\n── 4. Singularity: second spawn errors when graph reports existing UC ──\n")
(with-vat vat
  (define g (spawn ^scope-graph))
  ($ g 'note-spawn ($ uc 'scope-aid) 'universal-commune '())
  (reset-universal-commune!)
  (check-pred "second spawn errors"
    (catch #t
      (lambda () (spawn-universal-commune #:scope-graph g) #f)
      (lambda _ #t))))

(display "\n── 5. member-set-anchor is deterministic + order-independent ──\n")
;; The curator passes this anchor to (rotate-keys #:anchors ...). The
;; rotate-keys + anchors wiring on ^scope is exercised in production
;; on every UC tick; here we just lock in the digest's contract:
;; (a) same UC + same member-set → same SAID,
;; (b) different order of members → same SAID (sort-stable),
;; (c) different member-set → different SAID,
;; (d) different UC AID → different SAID.
(let* ((uc-aid "E_uc")
       (m1     '("E_b" "E_a" "E_c"))
       (m2     '("E_c" "E_a" "E_b"))
       (m3     '("E_a" "E_b" "E_d"))
       (a1     (member-set-anchor uc-aid m1))
       (a2     (member-set-anchor uc-aid m2))
       (a3     (member-set-anchor uc-aid m3))
       (a4     (member-set-anchor "E_other_uc" m1)))
  (check-pred "same set, different order → same SAID"
    (equal? (assq-ref a1 'd) (assq-ref a2 'd)))
  (check-pred "different member set → different SAID"
    (not (equal? (assq-ref a1 'd) (assq-ref a3 'd))))
  (check-pred "different UC AID → different SAID"
    (not (equal? (assq-ref a1 'd) (assq-ref a4 'd))))
  (check-pred "carries schema tag"
    (equal? "playnet-uc-membership/v1" (assq-ref a1 's))))

(display "\n── 6. rotate-keys accepts #:anchors keyword ──\n")
;; Synthetic-mode scope errors on the rotation body itself ("no
;; keypair"), but the arity check happens FIRST. If #:anchors weren't
;; in the method signature, we'd get "Wrong number of arguments".
(with-vat vat
  (let ((s (spawn-scope "anchor-arity-test" #:kind 'commune)))
    (check-pred "rotate-keys #:anchors parses (no arity error)"
      (catch #t
        (lambda () ($ s 'rotate-keys #:anchors '()) #t)
        (lambda (key . args)
          ;; Synthetic-mode "no keypair" is fine; arity errors are not.
          (let ((msg (if (pair? args) (format #f "~s" args) "")))
            (not (string-contains msg "Wrong number of arguments"))))))))

(display "\n=== test-universal-commune-kind PASSED ===\n")
