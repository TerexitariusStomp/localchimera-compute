;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federation-live.scm — a SEEDED federation of real scope-roots, composed
;;; by the decomposition across vats, one pull per crossing good — the live path end to end.
;;;
;;; Two sovereign communes, each a real ^scope-root with its own stores:
;;;   • Commune A (Granary) — holds flour, has a bakery.
;;;   • Commune B (Table)   — no flour, wants bread.
;;; Each is seeded with a bake recipe, a worker, a NESTED spatial tree
;;; (federation ⊃ commune ⊃ venue, the same tree the earth-map overlay draws),
;;; and its inventory. We then run exactly what the service's `federated-plan`
;;; method does: gather each commune's live records from its stores, build a
;;; solve-decomposed scope-record for each with flour crossing, and let the
;;; ADMM settle. B's bread demand is met by A's flour — the commune that holds
;;; flour supplies it and the one that holds none draws it, as the solve finds.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/federation/test-federation-live.scm

(use-modules (playnet solve federation-solve))
(use-modules (playnet knowledge recipes federation-demo) (playnet federation store-registry) (playnet scope root)
             (playnet scope live)
             (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define scope-root-env-full
  ;; each env names its own actor; a new slot on ^scope-root needs no edit here
  (make-persistence-env '() #:extends (list scope-root-env store-registry-env)))

;; seed a commune's real stores: bake recipe (flour+work→bread), a worker, a
;; NESTED spatial tree (federation ⊃ commune ⊃ venue), and inventory.
;; seeding is the reusable `seed-fed-commune!` from (playnet boot prelude) — the same
;; helper the gateway's demo path calls to stand up a federation of communes.

;; gather a commune's live records — the four pulls the service method does.
(define (commune-records vat scope)
  (with-vat vat
    (let ((obs ($ scope 'observer)) (as ($ scope 'agent-store))
          (sts ($ scope 'spatial-thing-store)) (rs ($ scope 'recipe-store)))
      (call-with-values (lambda () (gather-recipes rs))
        (lambda (procs flows)
          (list (cons 'resources ($ obs 'all-resources))
                (cons 'agents    ($ as 'all-agents))
                (cons 'spatials  ($ sts 'all-locations))
                (cons 'procs procs) (cons 'flows flows)))))))

;; ── spin up two sovereign communes ──
(define store (make-memory-store))
(define-values (vat scopeA registry)
  (spawn-persistent-vat scope-root-env-full
    (lambda () (values (spawn-scope-root "Granary") (spawn ^store-registry (hashmap)))) store))
(define scopeB (with-vat vat (spawn-scope-root "Table")))

(with-vat vat (seed-fed-commune! scopeA "fed" "commune-a" "Granary" "venue-a" 42.70 23.32 300.0))  ; flour-rich
(with-vat vat (seed-fed-commune! scopeB "fed" "commune-b" "Table"   "venue-b" 42.75 23.40 0.0))    ; flour-poor

;; ── compose them: flour crosses; which way is what the solve answers ──
(define ra (commune-records vat scopeA))
(define rb (commune-records vat scopeB))

(define sA (commune->scope-record (assq-ref ra 'resources) (assq-ref ra 'agents) (assq-ref ra 'spatials)
             (assq-ref ra 'procs) (assq-ref ra 'flows) #:id "Granary"
             #:demand (list (cons (lg "bread" (cell "venue-a" 0)) 5.0)) #:never-raw '("flour")
             #:crossing '("flour")))
(define sB (commune->scope-record (assq-ref rb 'resources) (assq-ref rb 'agents) (assq-ref rb 'spatials)
             (assq-ref rb 'procs) (assq-ref rb 'flows) #:id "Table"
             #:demand (list (cons (lg "bread" (cell "venue-b" 0)) 40.0)) #:never-raw '("flour")
             #:crossing '("flour")))

;; the location-slacks computation (service.scm), replicated to check the overlay
;; data: per-place want (from demand tuples) vs met (produce material at-location).
(define (place-slack per-scope place)
  (let ((want 0.0) (met 0.0))
    (for-each (lambda (ps)
      (for-each (lambda (d) (when (equal? (list-ref d 1) place)
                              (set! want (+ want (list-ref d 3))))) (cadr ps))
      (for-each (lambda (m) (when (and (eq? (assq-ref m 'action) 'produce)
                                       (equal? (assq-ref m 'at-location) place))
                              (set! met (+ met (or (assq-ref m 'quantity) 0)))))
                (assq-ref (caddr ps) 'material)))
      per-scope)
    (if (> want 0) (min 1.0 (/ met want)) 1.0)))

(call-with-values (lambda () (federated-solve (list sA sB)))
  (lambda (plans met rounds pulls)
    (define pull (hash-ref pulls "flour" 0.0))
    ;; decode each commune's post-ADMM plan → the per-location fill the overlay reads
    (define per-scope (federated-per-scope plans (list sA sB)))
    (define venue-b-slack (place-slack per-scope "venue-b"))
    (format #t "~%── LIVE FEDERATION: two seeded scope-roots, composed through one pull ──~%")
    (format #t "   met = ~,1f%%   rounds = ~a   pull λ(flour) = ~,4f~%" met rounds pull)
    (format #t "   venue-b per-location slack (overlay colour) = ~,3f  (1 = green/whole)~%" venue-b-slack)
    (define flour-a (assoc-ref (federated-flows sA (car plans)) "flour"))
    (define flour-b (assoc-ref (federated-flows sB (cadr plans)) "flour"))
    (format #t "   flour: Granary ~,2f   Table ~,2f   (supplied above nothing, drawn below)~%" flour-a flour-b)
    (let ((ok (and (> met 98.0) (> (abs pull) 1e-5) (> venue-b-slack 0.9)
                   (> flour-a 39.0) (< flour-b -39.0))))
      (format #t "~%   [~a] B's demand met by A's flour AND venue-b reads whole — the overlay greens~%~%"
              (if ok "OK" "XX"))
      (exit (if ok 0 1)))))
