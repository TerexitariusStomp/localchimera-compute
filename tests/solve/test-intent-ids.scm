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
             ((playnet vf facts work-ids) #:select (need-intent-id offer-intent-id materialized-intent-id bounded-offer-id
                                                    intent-family-prefix intent-family? work-intent-id-terms))
             ((playnet solve report) #:select ((need-intent-id . report-need-intent-id)))
             ((playnet doors assignments) #:select (willing-key))
             (srfi srfi-1))

(define families '(need offer materialized bounded))
(define ids (list (cons 'need (need-intent-id "bake" "baking" "A@0"))
                  (cons 'offer (offer-intent-id "ana" "baking" "A@0"))
                  (cons 'materialized (materialized-intent-id "ana" "baking" "A@0"))
                  (cons 'bounded (bounded-offer-id "ana" "bake" "2026-10-02"))))

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
(check "a bounded offer's id begins offer:" (intent-family-prefix 'bounded) "offer:")
(check "a non-id is no family's" (any (lambda (f) (intent-family? f #f)) families) #f)

(display "\n── READER: an id taken apart by its ends ──\n")
(check "a need: its process, skill and cell" (work-intent-id-terms (need-intent-id "bake" "baking" "A@0"))
       '((family . need) (subject . "bake") (skill . "baking") (cell . "A@0")))
(check "an offer: its worker, skill and cell" (work-intent-id-terms (offer-intent-id "ana" "cook" "B@2"))
       '((family . offer) (subject . "ana") (skill . "cook") (cell . "B@2")))
(check "a process with a bar in it is the subject whole" (assq-ref (work-intent-id-terms "ni|a|b|c|d@1") 'subject) "a|b")
(check "an id of no family, a bounded offer and a non-id are read as none"
       (map work-intent-id-terms (list "claim|x|y|z|w" (bounded-offer-id "ana" "bake" "w") "ni|a" #f)) '(#f #f #f #f))
(check "solve/report.scm still names the same constructor" (report-need-intent-id "p" "s" "c") (need-intent-id "p" "s" "c"))

(display "\n── WILLING: a willingness is kept under the offer intent's id ──\n")
(check "willing-key is offer-intent-id" (willing-key "ana" "baking" "A@0") (offer-intent-id "ana" "baking" "A@0"))

(test-summary!)
