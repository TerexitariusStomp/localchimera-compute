;;; test-solve-standing.scm — the standing a solve is given is one record, and
;;; the plain solve's settings are read off it.
;;;
;;; (doors/planner/ctx.scm solve-standing, standing->settings): every fact a
;;; scope stands on when it solves — its admit gate, its warm start and the
;;; decided discrete state, where its people are, the solver it solves with,
;;; whether it reproduces its labour-power, the governed dials — is a field of
;;; one record, and the settings alist the plain solve lays under the caller's
;;; keywords is read off the record's fields: a path that takes a fact reads
;;; it here and nowhere else.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-solve-standing.scm

(use-modules (playnet test harness)
             ((playnet doors planner ctx) #:select (make-solve-standing standing->settings
                                                    solve-standing-admit? solve-standing-backend
                                                    solve-standing-reproduce? solve-standing-decided)))

(display "\n── the record's defaults ──\n")
(define bare (make-solve-standing))
(check "the solver is native-c unless stated" (solve-standing-backend bare) 'native-c)
(check "a scope reproduces its labour-power unless stated" (solve-standing-reproduce? bare) #t)
(check "no admit gate admits every recipe" (solve-standing-admit? bare) #f)
(check "no search has left a decided state" (solve-standing-decided bare) #f)

(display "\n── the settings are the record's fields ──\n")
(define where (lambda (aid period) "home"))
(define st (make-solve-standing #:warm-x #(1 2) #:decided '((k . 1)) #:agent-position where
                                #:backend 'native #:reproduce? #f #:dials '(#:emp-rho 0.2)))
(define settings (standing->settings st))
(check "the warm start" (assq-ref settings 'warm-x) #(1 2))
(check "the decided state the last search left, the next search's seed" (assq-ref settings 'decided) '((k . 1)))
(check "where the scope's people are" (assq-ref settings 'agent-position) where)
(check "the solver" (assq-ref settings 'backend) 'native)
(check "reproduction, a word laid even when false" (assq 'reproduce? settings) '(reproduce? . #f))
(check "the governed dials, as symbol keys" (assq-ref settings 'emp-rho) 0.2)
(check "a field standing empty lays no key" (assq 'warm-x (standing->settings bare)) #f)
(check "…so the engine's own default stands, except the words always laid"
       (map car (standing->settings (make-solve-standing)))
       '(backend reproduce? practice-peers agent-of scope-path))

(test-summary!)
