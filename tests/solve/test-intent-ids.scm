;;; test-intent-ids.scm — the work-intent id grammar is written once.
;;;
;;; A need (ni|), an offer (oi|) and a materialized suggestion (mi|) are told
;;; apart by their id, so the constructors, the prefix and the membership test
;;; live together in solve/report.scm and no caller spells a prefix. Properties:
;;;
;;;   OWN      each constructor's id is a member of its own family and no other
;;;   PREFIX   a family's prefix is what its ids start with
;;;   WILLING  a worker's willingness is kept under the offer intent's id
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/solve/test-intent-ids.scm

(use-modules (playnet test harness)
             ((playnet solve report) #:select (need-intent-id offer-intent-id materialized-intent-id
                                               intent-family-prefix intent-family?))
             ((playnet doors assignments) #:select (willing-key))
             (srfi srfi-1))

(define families '(need offer materialized))
(define ids (list (cons 'need (need-intent-id "bake" "baking" "A@0"))
                  (cons 'offer (offer-intent-id "ana" "baking" "A@0"))
                  (cons 'materialized (materialized-intent-id "ana" "baking" "A@0"))))

(display "\n── OWN: an id belongs to its family alone ──\n")
(for-each (lambda (pr)
            (check (format #f "the ~a id is a ~a id and no other" (car pr) (car pr))
                   (filter (lambda (f) (intent-family? f (cdr pr))) families)
                   (list (car pr))))
          ids)

(display "\n── PREFIX: a family's prefix is where its ids begin ──\n")
(check "need ids begin ni|" (intent-family-prefix 'need) "ni|")
(check "offer ids begin oi|" (intent-family-prefix 'offer) "oi|")
(check "materialized ids begin mi|" (intent-family-prefix 'materialized) "mi|")
(check "a non-id is no family's" (any (lambda (f) (intent-family? f #f)) families) #f)

(display "\n── WILLING: a willingness is kept under the offer intent's id ──\n")
(check "willing-key is offer-intent-id" (willing-key "ana" "baking" "A@0") (offer-intent-id "ana" "baking" "A@0"))

(test-summary!)
