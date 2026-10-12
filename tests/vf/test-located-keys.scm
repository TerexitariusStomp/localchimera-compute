;;; test-located-keys.scm — every column key the program lays reads back as what it was laid as.
;;;
;;; vf/facts/located.scm holds one constructor per kind of column key and the one
;;; reader of every key (key-terms). This holds the two to each other: a key built
;;; by a constructor reads back its fields, including the fields that carry a `|`
;;; of their own (a hold's process, a carried bar good, a pool's supplier id) and
;;; the kinds the reader once left at their prefix alone (mv|, T|, r| over a pool,
;;; acq| over a labour row).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/vf/test-located-keys.scm
(use-modules (playnet test harness) (playnet vf facts located) (srfi srfi-1))

(define (terms key) (key-terms key))
(define (field key k) (assq-ref (terms key) k))

(display "\n── a process at a cell, a process over an arc, a hold through a container ──\n")
(check "a process column reads its process" (field (process-col "bake" "town@0") 'process) "bake")
(check "…its place and period" (list (field (process-col "bake" "town@0") 'place) (field (process-col "bake" "town@0") 'period)) '("town" 0))
(check "an arc column reads its arc" (field (arc-col "haul" "a@0" "b@0") 'arc) '("a@0" . "b@0"))
(check "a hold's process carries a | and still reads whole" (field (arc-col "keep|K~bread" "a@0" "a@1") 'process) "keep|K~bread")
(check "a crossing's draw column is read by its process, not its spelling"
       (and (crossing-col? (process-col "cross-flour" "a@0")) (not (crossing-col? (process-col "bake" "a@0")))) #t)

(display "\n── a carry, with a bare good and with a bar good ──\n")
(check "a carry reads its good and arc" (list (field (carry-col "bread" "a@0" "b@0") 'good) (field (carry-col "bread" "a@0" "b@0") 'arc)) '("bread" ("a@0" . "b@0")))
(check "a carried presence (Pres|w) reads whole" (field (carry-col (pres-good "ada") "a@0" "b@0") 'good) "Pres|ada")
(check "a carried service (Svc|spec) reads whole" (field (carry-col (svc-good "van") "a@0" "a@1") 'good) "Svc|van")
(check "a carry is a carry" (and (carry-col? (carry-col "bread" "a@0" "b@0")) (not (carry-col? (process-col "bake" "a@0")))) #t)

(display "\n── the supplies: a worker, a refresh, a mobile means, a supplier, a pool ──\n")
(check "a worker column" (map (lambda (k) (field (worker-col "ada" "baker" "a@0") k)) '(worker skill place period)) '("ada" "baker" "a" 0))
(check "a refresh column reads as the worker's" (field (refresh-col "ada" "baker" "a@0") 'worker) "ada")
(check "a mobile means' service column reads its means and service" (list (field (means-col "van1" "Svc|van" "a@0") 'worker) (field (means-col "van1" "Svc|van" "a@0") 'skill)) '("van1" "Svc|van"))
(check "a supplier's draw" (list (field (supply-col "s1" "flour" "a@0") 'supplier) (field (supply-col "s1" "flour" "a@0") 'means)) '("s1" "flour"))
(check "a pool's draw: the supplier id carries a | and reads whole"
       (list (field (supply-col (pool-id "cp" "r9" 2) "flour" "a@2") 'supplier) (field (supply-col (pool-id "bg" "r9") "flour" "a@0") 'supplier))
       '("cp|r9|2" "bg|r9"))
(check "the kinds tell apart" (map (lambda (p) (p (means-col "v" "Svc|v" "a@0"))) (list worker-col? refresh-col? means-col?)) '(#f #f #t))

(display "\n── a training, a row bought in, a floor's own row ──\n")
(check "a training reads its worker, skill and period" (map (lambda (k) (field (train-col "ada" "baker" 3) k)) '(worker skill period)) '("ada" "baker" 3))
(check "a bought row reads whole, a labour row included" (list (field (acquire-col "bread#a@0") 'row) (field (acquire-col (lab-good "" "a@0")) 'row)) '("bread#a@0" "Lab||a@0"))
(check "a floor's row reads its floor, source and cell" (map (lambda (k) (field (floor-col "p" "bread" "a@0" "d") k)) '(floor source place period)) '("bread" "d" "a" 0))

(display "\n── the travel table's arc, a key dated ──\n")
(check "an arc of the table reads its ends and manner" (arc-key-parts (arc-table-key "a" "b" "walk")) '("a" "b" "walk"))
(check "a period-less key dated gains its period, a dated one is retimed"
       (list (key-dated "Svc|van#a" 2) (key-dated "bread#a@0" 2)) '("Svc|van#a@2" "bread#a@2"))
(check "a labour good reads its skill and cell" (list (lab-good-skill (lab-good "baker" "a@0")) (lab-good-cell (lab-good "baker" "a@0"))) '("baker" "a@0"))
(test-summary!)
