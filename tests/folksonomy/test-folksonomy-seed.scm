;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-folksonomy-seed.scm — seed-folksonomy! gathers specs → a real cut.
;;;
;;; Proves the gateway's boot seed: a scope's resource-spec classifications
;;; (legacy slash-paths, mixed with control-plane tags) become a filtered,
;;; flattened cut contributed to the folksonomy. Uses mock scope-root +
;;; recipe-store actors over real <resource-specification> records.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/folksonomy/test-folksonomy-seed.scm

(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet folksonomy actor)
             (playnet folksonomy graph)
             (playnet folksonomy seed)
             (playnet vf schemas) (srfi srfi-1)                 ; make-resource-specification
             (goblins)
             (goblins actor-lib methods)
             (srfi srfi-1))

(define (assq-ref alist key) (let ((p (assq key alist))) (and p (cdr p))))
(define (child-of node label)
  (and node (find (lambda (c) (equal? (assq-ref c 'label) label))
                  (or (assq-ref node 'children) '()))))

;; A spec with a given classified-as list (the 11 positional fields).
(define (spec id . cats)
  (make-resource-specification #:id id #:name id #:resource-classified-as cats
                               #:default-unit-of-resource "unit"))

(define vat (spawn-vat))

(with-vat vat

  ;; Mock recipe-store + scope-root: only the methods seed-folksonomy! touches.
  (define (^mock-recipe-store bcom specs)
    (methods ((all-resource-specs) specs)))
  (define (^mock-scope-root bcom rs)
    (methods ((recipe-store) rs)))

  (define rs (spawn ^mock-recipe-store
                    (list (spec "s1" "Food/Grain")
                          (spec "s2" "Food/Vegetable" "tag:plan:deficit")  ; control-plane mixed in
                          (spec "s3" "Staples/Grain")                       ; competing nesting
                          (spec "s4"))))                                    ; no categories
  (define root (spawn ^mock-scope-root rs))
  (define fol  (spawn ^folksonomy (make-folksonomy) '()))

  (display "\n── seed-folksonomy! from a scope's specs ──\n")

  (define contributed? (seed-folksonomy! fol root))
  (check "seed reported it contributed" contributed? #t)

  (check "Food→Grain edge seeded from spec s1"
         ($ fol 'edge-count "Food" "Grain") 1)
  (check "Staples→Grain seeded from s3 (competing nesting of flat Grain)"
         ($ fol 'edge-count "Staples" "Grain") 1)
  (check "Grain is ONE flat term with two parents across specs"
         (length ($ fol 'parents "Grain")) 2)
  (check "control-plane tag:plan:deficit was filtered out"
         ($ fol 'edge-count "tag:plan:deficit" "Food") 0)

  (define tpl ($ fol 'template))
  (check "seeded cut renders Grain under Food"
         (and (child-of (child-of tpl "Food") "Grain") #t) #t)
  (check "seeded cut renders Vegetable under Food"
         (and (child-of (child-of tpl "Food") "Vegetable") #t) #t)

  (display "\n── a scope with no classifications leaves it empty ──\n")

  (define rs0  (spawn ^mock-recipe-store (list (spec "x"))))
  (define root0 (spawn ^mock-scope-root rs0))
  (define fol0 (spawn ^folksonomy (make-folksonomy) '()))
  (check "seed reports #f when there are no categories"
         (seed-folksonomy! fol0 root0) #f)

  (display "\n── a broken store is tolerated (best-effort) ──\n")
  (define (^bad-scope-root bcom) (methods ((recipe-store) (error "no store"))))
  (define badroot (spawn ^bad-scope-root))
  (define folb (spawn ^folksonomy (make-folksonomy) '()))
  (check "seed swallows a store error and returns #f"
         (seed-folksonomy! folb badroot) #f))

(test-summary!)
