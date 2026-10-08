;;; test-material-rows.scm — a plan row is read the way the engine states it.
;;;
;;; The engine states a plan's material flow as a commitment (`mk-mat-commitment`), the wire
;;; carries it as a row (`planned-row`), and the doors hold it again as a commitment under
;;; the plan's own row id (`held-commitment`). The three readers of a row (its
;;; action, its run, whether it has stock behind it) are each one function, so the doors
;;; cannot differ about a row, and a run is named in one place (`run-id`).
;;;
;;;   ROUND TRIP  a row held again is the commitment the engine stated: its id, action, the
;;;               process it is an input or output of, its spec, quantity and unit, place and
;;;               time, with the scope it is held under
;;;   EDGES       a plan holds records in the process, rows on the wire and serialized records in
;;;               the store; a plan stored as rows reads back as the same flows
;;;   READERS     `row-action` reads a symbol or a string, `row-run` the process a row names,
;;;               `row-ambient?` the ambient tag
;;;   RUN         a run is `run|<recipe or good>|<origin cell>|<destination cell>`
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-material-rows.scm

(use-modules (playnet test harness)
             (playnet planner vf schemas)
             (playnet planner solve engine)
             (playnet planner scope live)
             (playnet planner formulas flows)
             (playnet planner knowledge dsl shorthand)
             (srfi srfi-1))

(define E (resolve-module '(playnet planner solve engine)))
(define mk-mat-commitment (module-ref E 'mk-mat-commitment))
(define run-id (module-ref E (quote run-id)))
(define (never-ambient spec) #f)   ; the engine's ambient test: a spec drawn from the ambient world


(absorb-specs! (list (make-resource-specification #:id "veg" #:name "Vegetables"
                                                  #:default-unit-of-resource "kg")))

(display "\n── ROUND TRIP: the engine's commitment, carried as a row and held again ──\n")
(define stated (mk-mat-commitment never-ambient "mc|c|veg|p1|A|0" 'consume "veg" 2.0 "p1" "A" "2026-10-02T09:00:00" "2026-10-02T10:00:00"))
(define held (held-commitment (planned-row 'material stated) "scope-1"))
(define (fields c)
  (list (commitment-id c) (commitment-action c) (commitment-input-of c) (commitment-output-of c)
        (commitment-resource-conforms-to c) (commitment-resource-classified-as c)
        (measure-has-numerical-value (commitment-resource-quantity c))
        (measure-has-unit (commitment-resource-quantity c))
        (commitment-at-location c)))
(check "a held row is the commitment the engine stated" (fields held) (fields stated))
(check "…counted in the specification's unit" (measure-has-unit (commitment-resource-quantity held)) "kg")
(check "…held under its scope" (commitment-in-scope-of held) '("scope-1"))
(check "…at the time the plan gives it" (commitment-has-point-in-time held) "2026-10-02T09:00:00")
(let ((row (planned-row 'material (mk-mat-commitment never-ambient "mc|d" 'dropoff "veg" 2.0 "run|haul|A@0|B@0" "B" "2026-10-02T09:00:00" #f))))
  (check "a dropoff is the output of its run" (list (row-run row) (assq-ref row 'output-of)) '("run|haul|A@0|B@0" "run|haul|A@0|B@0")))

;; a flow reads the same as the record it is and as the row it crosses the edge as
(let ((row (planned-row 'material stated)))
  (define (reads f) (list (row-id f) (row-action f) (row-spec f) (row-quantity f) (row-unit f)
                          (row-input-of f) (row-output-of f) (row-place f) (row-when f) (row-ambient? f)))
  (check "the record and its row answer every reader alike" (reads stated) (reads row))
  (check "a row states these keys, in this order" (map car row)
         '(id action conforms-to quantity unit output-of input-of classified-as at-location when note)))

(display "\n── THE PLAN AT ITS EDGES: records inside, rows on the wire, serialized in the store ──\n")
(define S (resolve-module '(playnet planner doors service)))
(define solve->stored (module-ref S 'solve->stored))
(define stored->solve (module-ref S 'stored->solve))
(let* ((plan   `((met . 1.0) (work . ()) (material . (,stated)) (runs . ())))
       (rows   (plan->rows plan))
       (stored (solve->stored (cons '() plan)))
       (back   (stored->solve "scope-1" stored)))
  (check "a plan leaving the process carries each flow as its row"
         (map pair? (assq-ref rows 'material)) '(#t))
  (check "…and what is no flow as it stood" (assq-ref rows 'met) 1.0)
  (check "rows cross a second time as they stand" (plan->rows rows) rows)
  (check "the store holds a flow in the form every stored record takes"
         (car (car (assq-ref (cdr stored) 'material))) '@vf)
  (check "a plan read back holds the commitment it stored"
         (fields (car (assq-ref (cdr back) 'material))) (fields stated))
  (check "a plan read twice is one plan" (eq? back (stored->solve "scope-1" stored)) #t)
  ;; a plan stored before its flows were records holds rows; it reads as the same flows
  (let* ((earlier (cons '() rows))
         (read    (stored->solve "scope-2" earlier))
         (m       (car (assq-ref (cdr read) 'material))))
    (check "a plan stored as rows reads back, each row answering the readers"
           (list (row-id m) (row-action m) (row-spec m) (row-quantity m))
           (list (row-id stated) (row-action stated) (row-spec stated) (row-quantity stated)))
    (check "…and is held as the same commitment" (fields (held-commitment m "scope-1")) (fields held))))

(display "\n── READERS: one reading of a row's action, run and ambient tag ──\n")
(check "an action read off the wire is a symbol" (row-action '((action . "pickup"))) 'pickup)
(check "…and one off a commitment stays one" (row-action '((action . pickup))) 'pickup)
(check "a row's run is the process it is an output of, else an input of"
       (list (row-run '((output-of . "r1") (input-of . "p"))) (row-run '((input-of . "p"))) (row-run '())) '("r1" "p" #f))
(check "a row is ambient when it carries the tag"
       (list (row-ambient? '((classified-as . ("ambient")))) (row-ambient? '((classified-as . ("fresh")))) (row-ambient? '()))
       '(#t #f #f))

(display "\n── RUN: one spelling of a run's name ──\n")
(check "a run of a recipe between two cells" (run-id "haul" "A@0" "B@0") "run|haul|A@0|B@0")

(test-summary!)
