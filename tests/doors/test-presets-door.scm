;;; test-presets-door.scm — a scope starts from a preset through the planner's doors.
;;;
;;; `presets` lists the worlds the tree ships as data (knowledge/presets.scm);
;;; `adopt-preset!` seeds one into a registered scope. A fresh scope adopting
;;; "bread-town" then plans the bread demand the suites plan — the preset IS
;;; the fixture — and an unknown id is refused, not silently empty.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-presets-door.scm

(use-modules (playnet test harness)
             (playnet scope root) (srfi srfi-1)
             (playnet scope live)
             (playnet doors service)
             (playnet knowledge dsl world)
             (playnet knowledge worlds presets)
             (playnet test planner bread)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "presets"))
(define svc (with-vat vat (spawn ^planner-service (hashmap))))
(define root (with-vat vat (spawn-scope-root "fresh")))
(with-vat vat ($ svc 'add-scope! "E_fresh" root))

(define listed (with-vat vat ($ svc 'presets)))
(define ids (map (lambda (p) (assq-ref p 'id)) listed))

(display "\n── the presets door ──\n")
(check "every preset the registry holds is listed with an id, a name and a doc"
       (and (= (length listed) (length %presets))
            (every (lambda (p) (and (string? (assq-ref p 'id)) (string? (assq-ref p 'name)) (string? (assq-ref p 'doc)))) listed)))
(check "the bread town is among them" (member "bread-town" ids))
(check "every preset builds a world" (every (lambda (id) (world? (preset-ref id))) ids))

(display "\n── adopting the bread town ──\n")
(define reply (with-vat vat ($ svc 'adopt-preset! "E_fresh" "bread-town")))
(check "adopt-preset! replies ok with the counts seeded"
       (and (pair? reply) (eq? (car reply) 'ok)
            (= (assq-ref (cdr reply) 'recipes) (length (world-recipes bread-world)))))
(check "the scope's stores now hold the preset's resources"
       (= (length (with-vat vat ($ ($ root 'observer) 'all-resources)))
          (length (world-resources bread-world))))
(define result (with-vat vat (plan-scope->alist root #:demand '(("bread#town@0" . 10.0)))))
(check "…and the scope plans the suites' demand over it: bread is baked"
       (> (bread-hours result "bake") 0))

(display "\n── refusals ──\n")
(define bad (with-vat vat ($ svc 'adopt-preset! "E_fresh" "no-such-preset")))
(check "an unknown preset is an error reply, not an empty seed" (and (pair? bad) (eq? (car bad) 'error)))
(define nowhere (with-vat vat ($ svc 'adopt-preset! "E_nowhere" "bread-town")))
(check "an unknown scope is an error reply" (and (pair? nowhere) (eq? (car nowhere) 'error)))

(test-summary!)
