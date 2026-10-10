;;; test-plan-materialize-opts-door.scm — plan/materialize/federated-plan's
;;; single OPTS alist at the ^planner-service DOOR, the layer nothing tested
;;; before at this door boundary (each door's own solve logic is exercised
;;; heavily elsewhere — test-willingness-service.scm, test-federation-*.scm —
;;; but always by supplying opts as a literal `'()` or one fixed alist; none
;;; of those prove the SHAPE at the boundary itself: that `opts` is now one
;;; named optional argument, not a variadic tail whose first element used to
;;; be hand-extracted with `(car opts)`).
;;;
;;; Run: guile -L module -L tests tests/doors/test-plan-materialize-opts-door.scm

(use-modules (playnet vf schemas) (playnet doors service) (playnet test planner bread)
             (playnet test harness)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat #:name "plan-materialize-opts-door"))
(define-values (scope ps als) (with-vat vat (spawn-bread-scope)))
(define svc (with-vat vat (spawn ^planner-service (hashmap-set (hashmap) "s1" scope))))
(define demand '(("bread" "town" 0 4.0)))

(display "\n── plan: opts omitted entirely — every default applies, not a crash ──\n")
(define r1 (with-vat vat ($ svc 'plan "s1" demand)))
(check "ok" (car r1) 'ok)

(display "\n── plan: opts as a real alist reaches the solve by name ──\n")
(define r2 (with-vat vat ($ svc 'plan "s1" demand '((tau . 0.0) (reproduce . #f)))))
(check "ok" (car r2) 'ok)

(display "\n── materialize: opts omitted — a real plan-id default, not a crash ──\n")
(define r3 (with-vat vat ($ svc 'materialize "s1" demand)))
(check "ok" (car r3) 'ok)
(check-pred "a materialized count comes back" (assq-ref (cdr r3) 'materialized))

(display "\n── materialize: opts' plan-id lands by name ──\n")
(define r4 (with-vat vat ($ svc 'materialize "s1" demand '((plan-id . "custom-plan")))))
(check "ok" (car r4) 'ok)

(display "\n── federated-plan: opts omitted — no displacement-of block, not a crash ──\n")
(define r5 (with-vat vat ($ svc 'federated-plan "bread"
                             (list (list "s1" (cons "bread#town@0" 4.0))))))
(check "ok" (car r5) 'ok)
(check "no scope-displacement without asking for one" (assq-ref (cdr r5) 'scope-displacement) #f)

(display "\n── federated-plan: opts' displacement-of lands by name, not by (car opts) ──\n")
(define r6 (with-vat vat ($ svc 'federated-plan "bread"
                             (list (list "s1" (cons "bread#town@0" 4.0)))
                             '((displacement-of . "s1")))))
(check "ok" (car r6) 'ok)
(check-pred "a scope-displacement block appears when displacement-of is asked for"
            (assq-ref (cdr r6) 'scope-displacement))
(check "the named scope is the one read"
       (assq-ref (assq-ref (cdr r6) 'scope-displacement) 'scope) "s1")

(test-summary!)
