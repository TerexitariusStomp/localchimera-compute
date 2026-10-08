;;; test-family-local.scm — the household solve, asked as JSON, answers what the solve answers.
;;;
;;; The face and the page's solve worker speak JSON (family-local.scm reads the
;;; rows, family-wire.scm shapes the reply). This holds that round trip against
;;; the solve it wraps: the same week through the JSON door and through
;;; `family-split` itself must spend the same euros and meet every need to the
;;; same degree, and a malformed week is refused by name. "The same" is to the
;;; barrier's residue: two solves of one program stop a few thousandths of a euro
;;; apart, and nothing here asks for closer than that.
;;;
;;; Run: guile -L module tests/planner/test-family-local.scm

(use-modules (playnet test planner prelude)
             (playnet planner doors family solve)
             (playnet planner doors family local)
             (playnet utils json-portable)
             (srfi srfi-1) (ice-9 format))

(define (needs->json ns)               ; the face's rows
  (scm->json-canonical
   (list->vector (map (lambda (n) `(("person" . ,(list-ref n 0)) ("what" . ,(list-ref n 1))
                                    ("cost" . ,(list-ref n 2)) ("want" . ,(list-ref n 3))
                                    ("voice" . ,(list-ref n 4)) ("kind" . ,(symbol->string (list-ref n 5)))))
                      ns))))
(define (rows r) (vector->list (assoc-ref r "needs")))

(display "\n── the JSON door and the solve, one week ──\n")
(for-each
 (lambda (purse)
   (let* ((direct (family-split %family-demo-needs purse))
          (wire   (json-read-ordered (family-split-json (needs->json %family-demo-needs) purse 20.0 #t "[]" 40.0))))
     (format #t "  purse ~a: direct ~,4f  through JSON ~,4f~%" purse (assq-ref direct 'spent) (assoc-ref wire "spent"))
     (check (format #f "€~a: the same euros spent" purse)
            (< (abs (- (assq-ref direct 'spent) (assoc-ref wire "spent"))) 0.05))
     (check (format #f "€~a: every need met to the same degree" purse)
            (every (lambda (d w) (< (abs (- (assq-ref d 'met) (assoc-ref w "met"))) 0.01))
                   (assq-ref direct 'needs) (rows wire)))
     (check (format #f "€~a: feasible as the solve says" purse)
            (eq? (assq-ref direct 'feasible?) (equal? (assoc-ref wire "feasible") "yes")))))
 '(250 400))

(display "\n── a week the solve cannot serve, and a week that is not one ──\n")
(let ((wire (json-read-ordered (family-split-json (needs->json %family-demo-needs) 40.0 20.0 #t "[]" 40.0))))
  (check "a purse below the floors says so, and offers the best it can"
         (and (equal? (assoc-ref wire "feasible") "no") (assoc-ref wire "bestEffort") #t)))
(check "a malformed week is refused by name"
       (let ((r (family-split-json "not json" 100.0 20.0 #t "[]" 40.0)))
         (and (string? r) (string-prefix? "err:" r))))
(check "the three bills come back as three tiers"
       (let ((r (json-read-ordered (family-bills-json (needs->json %family-demo-needs) 250.0 20.0 #t 15.0 "[]" 40.0))))
         (equal? (map (lambda (t) (assoc-ref t "tier")) (vector->list (assoc-ref r "tiers")))
                 '("rights" "needs" "wants"))))
