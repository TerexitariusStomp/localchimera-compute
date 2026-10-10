;;; test-crossing-set.scm — which goods cross is read off the records.
;;;
;;; Nobody declares a supply: the stock a scope holds, the recipes it runs and
;;; the demand it states are its records, and a good crosses when at least two
;;; scopes deal in it (planner/federation/crossing-set.scm). Labour (a `work` flow's skill,
;;; and the resource that records someone holding it) is not a good that changes
;;; hands. federated-plan with no boundary named derives the set; a good named
;;; restricts it.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-crossing-set.scm

(use-modules (playnet test harness)
             (playnet knowledge recipes federation-demo) (playnet scope root) (playnet vf schemas)
             ((playnet solve engine) #:select (commune->scope-record))
             (playnet doors service)
             (playnet federation crossing-set)
             ((playnet solve compile) #:select (rp out in wrk))
             ((playnet knowledge dsl shorthand) #:select (use* wk*))
             ((playnet test planner federation-wire-fixture)
              #:select (fx-res fx-place fx-worker fx-bake-p fx-bake-f))
             (playnet knowledge recipes federation-demo)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))

(define (res id spec)
  (make-economic-resource #:id id #:name id #:conforms-to spec
                          #:accounting-quantity (make-measure 1 "kg")
                          #:onhand-quantity (make-measure 1 "kg")))

(display "\n── commune-goods: what a scope deals in ──\n")
(let ((bake  (list (out "o" "bread" 1.0 "bake") (in "i" "flour" 1.0 "bake") (wk* "w" "baking" 0.1 "bake")))
      (mill  (list (out "mo" "flour" 1.0 "mill") (in "mi" "wheat" 1.0 "mill")))
      (other (list (out "xo" "jam" 1.0 "jam") (in "xi" "fruit" 1.0 "jam")
                   (use* "u" "oven" "bake" 2.0))))
  (check "holds what it holds and asks for what it asks, with what the asking needs to the raw"
         (commune-goods (list (res "r1" "salt")) (append bake mill) '("bread"))
         '("bread" "flour" "salt" "wheat"))
  (check "a recipe in the catalogue says nothing of the scope that carries it"
         (commune-goods '() (append bake mill other) '("bread"))
         '("bread" "flour" "wheat"))
  (check "labour is not a good that changes hands, nor is the capacity a use flow draws on"
         (commune-goods (list (res "sk" "baking")) (append bake (list (use* "u2" "oven" "bake" 1.0))) '("bread"))
         '("bread" "flour"))
  (check "a spec only a use flow draws on stays out even when held"
         (commune-goods (list (res "ov" "oven")) (append bake (list (use* "u3" "oven" "bake" 1.0))) '())
         '()))

(display "\n── crossing-goods: at least two scopes ──\n")
(check "a good one scope deals in alone does not cross"
       (crossing-goods '(("a" "flour" "salt") ("b" "flour" "bread") ("c" "bread")))
       '("bread" "flour"))
(check "a scope listing a good twice counts once"
       (crossing-goods '(("a" "flour" "flour") ("b" "bread")))
       '())

(define vat (spawn-vat))

(with-vat vat
  (let* ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
         (svc (spawn ^planner-service (hashmap))))
    (seed-fed-commune! a "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
    (seed-fed-commune! b "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table"   b)
    ;; a good only the granary holds: it has nobody to cross to
    ($ ($ a 'observer) 'seed-resource (res "salt-1" "salt"))
    (let* ((demand (list (list "Granary" (cons "bread#venue-granary@0" 5.0))
                         (list "Table"   (cons "bread#venue-table@0" 40.0))))
           (derived (lambda () ($ svc 'federated-plan #f demand)))
           (named   ($ svc 'federated-plan "flour" demand)))
      (display "\n── federated-plan with no boundary named ──\n")
      (check "the census of the granary"
             ($ svc 'census "Granary" (cons "bread#venue-granary@0" 5.0))
             '(ok "bread" "flour" "salt"))
      (let ((r (derived)))
        (check "ok" (car r) 'ok)
        (check "the crossing set is what both deal in"
               (assq-ref (cdr r) 'boundary) '("bread" "flour"))
        (check "a pull stands on each good that crosses"
               (map car (assq-ref (cdr r) 'pulls)) '("bread" "flour"))
        (check "the table's bread is met without anyone naming the flour"
               (> (assq-ref (cdr r) 'met) 99.0) #t))
      (display "\n── a good named restricts the set ──\n")
      (check "named: the boundary is the good" (assq-ref (cdr named) 'boundary) "flour")
      (check "and met agrees with the derived set to the solver's tolerance"
             (< (abs (- (assq-ref (cdr named) 'met) (assq-ref (cdr (derived)) 'met))) 0.1) #t))))

;; A derived set can reach a good nobody capped. A commune that makes one
;; without bound (a recipe that returns more than it takes) has no measure to
;; cross it by: the column leaves its program and the record names it, where it
;; used to refuse the whole record.
(display "\n── a good the commune makes without bound stays out of its record ──\n")
(let ((rec (commune->scope-record
            (list (fx-res "flour" "a-home" 20.0) (fx-res "water" "a-home" 5.0))
            (list (fx-worker "wa" "a-home")) (list (fx-place "a-home" 42.70 23.32))
            (append fx-bake-p (list (rp "grow" "Grow")))
            (append fx-bake-f (list (in "gi" "water" 1.0 "grow") (out "go" "water" 2.0 "grow")))
            #:id "Granary" #:never-raw '("flour" "water") #:crossing '("flour" "water"))))
  (check "the water is named, with the column that makes it without bound"
         (assq-ref rec 'unbounded) '(("water" . "p|grow|a-home@0")))
  (check "and measured goods still cross" (map car (assq-ref rec 'gives)) '("flour")))

(test-summary!)
