;;; test-key-terms-shapes.scm — key-terms reads every column the build lays.
;;;
;;; A column's key is the one grammar the plan's rows are read off (vf/facts/located.scm):
;;; p|<process>|<cell> and p|<process>|<a>|<b> for a run and a haul, m|… for a carry,
;;; w|… for a worker. Two shapes went unread: a hold through a container, whose process
;;; id carries a `|` of its own (p|keep|K~spec|a|b, read as a bare prefix), and a
;;; budgeted floor's cover column p|spec|d#cell, read as a run of a process named after
;;; the spec. The reader now takes the cells off the END of a p| key and names a floor
;;; by its own term, so plan->material writes a row for a process and for nothing else.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/solve/test-key-terms-shapes.scm

(use-modules (playnet test harness)
             (playnet vf facts located)
             (playnet solve engine) (playnet solve world) (playnet solve compile)
             (srfi srfi-1) (ice-9 format))

(display "\n── the two shapes that went unread ──\n")
(let ((kt (key-terms "p|keep|K~bread|town@0|town@1")))
  (check "a hold through a container names its process whole" (assq-ref kt 'process) "keep|K~bread")
  (check "…and its arc" (assq-ref kt 'arc) '("town@0" . "town@1"))
  (check "…so key-process reads it" (key-process "p|keep|K~bread|town@0|town@1") "keep|K~bread"))
(let ((kt (key-terms "p|bread|farm#town@0")))
  (check "a budgeted floor's cover column is a floor, not a run" (assq-ref kt 'process) #f)
  (check "…of its spec" (assq-ref kt 'floor) "bread")
  (check "…from its source" (assq-ref kt 'source) "farm")
  (check "…at its cell" (assq-ref kt 'cell) "town@0"))
(check "a plain run reads as before" (key-process "p|bake|town@0") "bake")
(check "a haul reads as before" (key-arc "p|haul|a@0|b@0") '("a@0" . "b@0"))
(check "a carry reads as before" (assq-ref (key-terms "m|bread|a@0|b@0") 'good) "bread")

(display "\n── every column of a located world parses ──\n")
(define (spec i) (format #f "s~a" i))
(define places '(("P0" 0.0 0.0) ("P1" 0.0 0.05)))
(define pn (map car places))
(define templates
  (map (lambda (k) (list (format #f "t~a" k) (list (cons (spec (+ k 1)) 1.0)) (list (cons (spec k) 1.0)) 0.1)) '(0 1 2)))
(reset!)
(declare-world! #:places places #:templates templates
                #:workers (map (lambda (p) (list (format #f "w~a" p) '("sk") (cell p 0) 100.0)) pn)
                #:movable (list (spec 1)) #:tau 0.5
                #:neighbours (map (lambda (p) (cons p (filter (lambda (q) (not (equal? p q))) pn))) pn))
(for-each (lambda (t) (hash-set! *proc-skill* (car t) "sk")) *templates*)
(hash-set! *init* (lg (spec 0) (cell "P0" 0)) 50.0)
(hash-set! *demand* (lg (spec 3) (cell "P1" 0)) 5.0)
(call-with-values build-located
  (lambda (forms labform ncol cols goods raws idx)
    (let* ((keys (map col-key cols))
           (unread (filter (lambda (k) (null? (cdr (key-terms k)))) keys))
           (runs (filter (lambda (k) (string-prefix? "p|" k)) keys)))
      (check-pred "the world lays columns" (pair? keys))
      (check "every column's key reads to terms beyond its prefix" unread '())
      (check-pred "every p| column names a process" (every key-process runs))
      (check-pred "and no other column does" (every (lambda (k) (not (key-process k))) (lset-difference equal? keys runs))))))

(test-summary!)
