;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; knowledge/recipe-library.scm — an in-memory library of VF recipes.
;;;
;;; A small Goblins actor that holds recipe definitions and serves them through
;;; the SAME read protocol the recipe-store exposes (all-recipes,
;;; get-process-chain, flows-for-process, get-recipe, get-recipe-process), so it
;;; drops straight in wherever a recipe-store is expected — in particular as the
;;; recipe-store a scope-root hands to (localchimera scope live)'s plan-scope.
;;;
;;; Two uses:
;;;   • SIMULATIONS / TESTS — seed it with a handful of recipes and plan over them
;;;     with no event-sourcing or persistence scaffolding;
;;;   • the seed of an "open recipe COMMONS" — a curated, browsable catalogue of
;;;     recipes grouped by economic function, which organisations draw from to
;;;     bootstrap a plan rather than authoring every recipe (the data-commons
;;;     future: contribute-to and draw-from a shared technology library).
;;;
;;; A recipe DEFINITION is (recipe-record processes flows): the <recipe>, its
;;; ordered list of <recipe-process>, and the flat list of <recipe-flow>.

(define-module (localchimera knowledge dsl recipe-library)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera utils store-utils)
  #:use-module (srfi srfi-1)
  #:export (^recipe-library spawn-recipe-library recipe-def))

;; build a definition tuple (light validation: the recipe id is the key)
(define (recipe-def recipe processes flows) (list recipe processes flows))
(define (def-recipe d) (car d)) (define (def-procs d) (cadr d)) (define (def-flows d) (caddr d))

(define (lib-all-flows lib)
  (append-map def-flows (hashmap-values lib)))
(define (lib-all-procs lib)
  (append-map def-procs (hashmap-values lib)))

(define-actor (^recipe-library bcom lib)   ; lib :: hashmap recipe-id -> (recipe procs flows)

  #:portrait (lambda () (list lib))
  #:version 1
  #:restore (lambda (version data)
              (case version ((1) (spawn ^recipe-library (car data)))
                            (else (error "unknown ^recipe-library version" version))))

  (methods

    ;; ── recipe-store READ protocol (so plan-scope/gather-recipes can read us) ──
    ((all-recipes)            (map def-recipe (hashmap-values lib)))
    ((get-recipe id)          (let ((d (hashmap-ref lib id #f))) (and d (def-recipe d))))
    ((get-process-chain recipe-id)
     (let ((d (hashmap-ref lib recipe-id #f))) (if d (def-procs d) '())))
    ((get-recipe-process pid)
     (find (lambda (p) (equal? (recipe-process-id p) pid)) (lib-all-procs lib)))
    ((flows-for-process pid)  ; (inputs . outputs): inputs = consume+work, outputs = produce
     (let ((fs (lib-all-flows lib)))
       (cons (filter (lambda (f) (equal? (recipe-flow-recipe-input-of f) pid)) fs)
             (filter (lambda (f) (equal? (recipe-flow-recipe-output-of f) pid)) fs))))

    ;; ── library: seed + browse ────────────────────────────────────────────────
    ((add-recipe recipe processes flows)        ; register / replace a recipe; returns its id
     (bcom (^recipe-library bcom (hashmap-set lib (recipe-id recipe) (recipe-def recipe processes flows)))
           (recipe-id recipe)))
    ((remove-recipe id)
     (bcom (^recipe-library bcom (hashmap-remove lib id))))
    ((catalog)                                  ; ((id . name) …) for browsing
     (map (lambda (d) (cons (recipe-id (def-recipe d)) (recipe-name (def-recipe d)))) (hashmap-values lib)))
    ((count) (length (hashmap-keys lib)))))

;; spawn a library pre-seeded from a list of (recipe procs flows) definitions.
(define (spawn-recipe-library defs)
  (spawn ^recipe-library
    (fold (lambda (d hm) (hashmap-set hm (recipe-id (def-recipe d)) d)) (hashmap) defs)))
