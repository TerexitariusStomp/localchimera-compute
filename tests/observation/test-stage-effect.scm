;;; test-stage-effect.scm — a resource's stage is the specification of the process that made it.
;;;
;;; ValueFlows (concepts/actions.md, stageEffect): "if the process which the event is
;;; output of is based on a process specification, set the `stage` of the
;;; resourceInventoriedAs, or of the new resource if one is created, to the process
;;; specification." A process is known to the observer by the specification it is based
;;; on (`register-process`, the way a commitment is known by its target); a process that
;;; is based on none sets no stage. The planner then reads the stock at that stage
;;; wherever a recipe flow names it.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/observation/test-stage-effect.scm

(use-modules (playnet test harness)
             (playnet test events)
             (playnet observation observer) (playnet vf schemas) (playnet utils store-utils) (srfi srfi-1)
             (playnet solve engine)
             (playnet solve compile)
             (playnet observation observer)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define (process id based-on) (make-process #:id id #:name id #:based-on based-on))
(define (stage-of st rid) (economic-resource-stage (resource st rid)))
(define (with-processes st . pairs)
  (fold (lambda (p st) (with-process st (process (car p) (cdr p)))) st pairs))

(display "\n── the stage is the process's specification, not the process ──\n")
(let* ((st (with-processes (empty-observer-state) '("proof" . "proofed")))
       (st (call-with-values (lambda () (observer-record-event st (ev "m" 'produce #:rid "d1" #:spec "dough" #:q 5.0 #:output "proof")))
             (lambda (s _) s))))
  (check "a produce that is the output of a process based on a specification sets it" (stage-of st "d1") "proofed"))

(display "\n── a process based on no specification sets no stage ──\n")
(let* ((st (call-with-values (lambda () (observer-record-event (empty-observer-state) (ev "m" 'produce #:rid "d1" #:spec "dough" #:q 5.0 #:output "proof")))
             (lambda (s _) s))))
  (check "an unregistered process leaves the stage unset" (stage-of st "d1") #f))

(display "\n── a snapshot keeps what the processes are based on ──\n")
(let* ((st (with-processes (empty-observer-state) '("proof" . "proofed")))
       (st (deserialize-observer-state (serialize-observer-state st))))
  (check "the loaded observer names the same specification" (process-spec-of st "proof") "proofed"))

(display "\n── the next plan finds the staged stock where a recipe names the stage ──\n")
(let* ((st (with-processes (empty-observer-state) '("proof" . "proofed")))
       (st (call-with-values (lambda () (observer-record-event st (ev "m" 'produce #:rid "d1" #:spec "dough" #:q 5.0 #:output "proof" #:at "town")))
             (lambda (s _) s))))
  (declare-world! #:spans '((0 "2026-03-03" "2026-03-03"))
                  #:templates (list (list "proof" '(("flour" . 1.0)) '(("dough/proofed" . 1.0)) 0.0 '() '() '() '() '())
                                    (list "bake" '(("dough/proofed" . 1.0)) '(("bread" . 1.0)) 0.0 '() '() '() '() '())))
  (ingest-stock! (hashmap-values (os-resources st)))
  (let ((g (lg "dough/proofed" (cell "town" 0))))
    (check "5 proofed dough are on hand for the bake" (+ (hash-ref *init* g 0.0) (hash-ref *cap* g 0.0)) 5.0)))

(test-summary!)
