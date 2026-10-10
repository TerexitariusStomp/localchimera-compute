;;; compile.scm — THE COMPILE BOUNDARY: ValueFlows records → sparse activity matrix.
;;;
;;; The merge's first real step. The convex program the Newton solver consumes is
;;; activity analysis; the VF KNOWLEDGE LAYER already IS activity analysis:
;;;
;;;   RecipeProcess   = an ACTIVITY     (a column of the technology matrix)
;;;   RecipeFlow      = a COEFFICIENT   (a nonzero entry — its sign/role read off
;;;                                      the action via *action-definitions*)
;;;   ResourceSpecification = a GOOD    (a row)
;;;
;;; So we don't invent a model — we COMPILE the records. This file reads real VF
;;; records (make-recipe-process / make-recipe-flow / make-measure) for the
;;; bread<-flour<-grain<-soil chain and emits the sparse structure the solver
;;; wants: per-process flow vectors, the good/raw partition, index maps, and the
;;; technology matrix whose sparsity pattern IS the RecipeFlow incidence (free).
;;;
;;; KEY INSIGHT the data forces: the activity is the PROCESS, not the good. The
;;; prototype indexed production by good (one recipe per good); VF indexes by
;;; RecipeProcess, which carries a whole flow VECTOR. So co-products, by-products,
;;; and ALTERNATIVE recipes (several columns touching one good-row = recipe choice)
;;; all fall out for free — the good-indexed model was the degenerate one-col case.
;;;
;;; Run:  guile -L module module/playnet/solve/compile.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet vf schemas))

;; ── the COMPILER: a RecipeProcess + its RecipeFlows → one activity column ────
;; Each flow's ROLE is read from the standard VF action table, not hard-coded:
;;   action-definition-input-output  : 'input | 'output | …
;;   action-definition-onhand-effect : 'increment (produce) | 'decrement (consume) | …
;;   action 'work  → effort-quantity is LABOUR (ℓ); 'use → means-of-production (depreciation)
(define (qty m)  (if m (measure-has-numerical-value m) 0.0))
(define (action-def a) (let ((p (assq a *action-definitions*))) (and p (cdr p))))

(define (compile-process rp-id flows)
  "flows = the RecipeFlows whose recipe-input-of OR recipe-output-of is rp-id.
   Returns (id outputs inputs labour uses), each of outputs/inputs/uses an
   alist (resource-spec-id . quantity)."
  (let ((outputs '()) (inputs '()) (uses '()) (labour 0.0))
    (for-each
     (lambda (rf)
       (let* ((action (recipe-flow-action rf))
              (spec   (recipe-flow-resource-conforms-to rf))
              (rq     (qty (recipe-flow-resource-quantity rf)))
              (eff    (qty (recipe-flow-effort-quantity rf)))
              (ad     (action-def action)))
         (cond
          ((eq? action 'work) (set! labour (+ labour eff)))                ; living labour
          ((eq? action 'use)  (set! uses (acons spec rq uses)))            ; means of production (wears)
          ((and ad (eq? (action-definition-onhand-effect ad) 'increment))  ; produce / raise
           (set! outputs (acons spec rq outputs)))
          ((and ad (eq? (action-definition-onhand-effect ad) 'decrement))  ; consume
           (set! inputs (acons spec rq inputs)))
          (else #t))))                                                     ; cite/move/… handled elsewhere
     flows)
    (list rp-id outputs inputs labour uses)))

(define (proc-id c)      (list-ref c 0))
(define (proc-outputs c) (list-ref c 1))
(define (proc-inputs c)  (list-ref c 2))
(define (proc-labour c)  (list-ref c 3))
(define (proc-uses c)    (list-ref c 4))

;; ── compile a whole recipe set: flows grouped by process, specs partitioned ──
(define (group-flows-by-process flows procs)
  (map (lambda (rp)
         (let ((pid (recipe-process-id rp)))
           (compile-process pid
             (filter (lambda (rf) (or (equal? (recipe-flow-recipe-input-of rf) pid)
                                      (equal? (recipe-flow-recipe-output-of rf) pid)))
                     flows))))
       procs))

(define (compile-recipe procs flows)
  "Returns (columns goods raws specs) where columns are compiled processes, and
   a spec is a GOOD iff some process outputs it, else a RAW (only ever consumed)."
  (let* ((columns (group-flows-by-process flows procs))
         (out-specs (delete-duplicates (append-map (lambda (c) (map car (proc-outputs c))) columns)))
         (all-specs (delete-duplicates
                     (append-map (lambda (c) (append (map car (proc-outputs c))
                                                     (map car (proc-inputs c))
                                                     (map car (proc-uses c)))) columns)))
         (raws (filter (lambda (s) (not (member s out-specs))) all-specs)))
    (list columns out-specs raws all-specs)))

;; net technology coefficient of spec s in process column c  (Σ out − Σ in)
(define (tech c s)
  (- (fold (lambda (oq a) (if (equal? (car oq) s) (+ a (cdr oq)) a)) 0.0 (proc-outputs c))
     (fold (lambda (iq a) (if (equal? (car iq) s) (+ a (cdr iq)) a)) 0.0 (proc-inputs c))))

;; ── the bread chain, as REAL ValueFlows records ─────────────────────────────
;; grow: soil → grain (0.5h) ; mill: grain → flour (0.3h) ; bake: flour → bread (0.5h)
(define (rp id name) (make-recipe-process #:id id #:name name))
(define (out id spec q proc)                ; a produce flow: output-of `proc`
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (make-measure q "kg") #:recipe-output-of proc
                    #:is-primary #t))
(define (in  id spec q proc)                ; a consume flow: input-of `proc`
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec
                    #:resource-quantity (make-measure q "kg") #:recipe-input-of proc))
(define (wrk id hrs proc)                   ; a work flow: living labour, input-of `proc`
  (make-recipe-flow #:id id #:action 'work #:effort-quantity (make-measure hrs "hours")
                    #:recipe-input-of proc))

(define *procs*
  (list (rp "grow" "Grow grain") (rp "mill" "Mill flour") (rp "bake" "Bake bread")))
(define *flows*
  (list (out "f1" "grain" 1.0 "grow") (in "f2" "soil"  1.0 "grow") (wrk "f3" 0.5 "grow")
        (out "f4" "flour" 1.0 "mill") (in "f5" "grain" 1.2 "mill") (wrk "f6" 0.3 "mill")
        (out "f7" "bread" 1.0 "bake") (in "f8" "flour" 1.0 "bake") (wrk "f9" 0.5 "bake")))

;; ── run: compile and show the sparse matrix the solver would consume ─────────
(define (report)
  (call-with-values (lambda () (apply values (compile-recipe *procs* *flows*)))
    (lambda (columns goods raws specs)
      (format #t "~%compiled ~a processes (activity columns), ~a goods, ~a raws~%"
              (length columns) (length goods) (length raws))
      (format #t "  goods (output by some process): ~a~%" goods)
      (format #t "  raws  (only ever consumed):      ~a~%" raws)
      (format #t "~%per-process flow vectors (the activity columns):~%")
      (for-each (lambda (c)
                  (format #t "  ~6a  out ~a  in ~a  labour ~,1fh~a~%"
                          (proc-id c) (proc-outputs c) (proc-inputs c) (proc-labour c)
                          (if (null? (proc-uses c)) "" (format #f "  use ~a" (proc-uses c)))))
                columns)
      (format #t "~%TECHNOLOGY MATRIX  (rows = goods/raws, cols = processes; net Σout−Σin):~%")
      (format #t "         ~a~%" (string-concatenate (map (lambda (c) (format #f "~8a" (proc-id c))) columns)))
      (for-each (lambda (s)
                  (format #t "  ~6a ~a~%" s
                          (string-concatenate
                           (map (lambda (c) (let ((v (tech c s))) (if (= v 0.0) (format #f "~8a" ".")
                                                                      (format #f "~8,1f" v)))) columns))))
                (append goods raws))
      (format #t "  ~6a ~a   <- the work row (living labour ℓ)~%" "labour"
              (string-concatenate (map (lambda (c) (format #f "~8,1f" (proc-labour c))) columns)))
      ;; the sparsity pattern IS the RecipeFlow incidence — count nonzeros
      (let ((nnz (fold (lambda (c a) (+ a (length (proc-outputs c)) (length (proc-inputs c)))) 0 columns)))
        (format #t "~%sparsity: ~a nonzeros over ~ax~a = ~a cells (the Hessian inherits exactly this pattern)~%"
                nnz (length (append goods raws)) (length columns)
                (* (length (append goods raws)) (length columns))))
      ;; cross-check against the hand-written prototype model
      (format #t "~%cross-check vs spacetime-newton's hand-built bom/ell:~%")
      (let ((bake (find (lambda (c) (equal? (proc-id c) "bake")) columns))
            (mill (find (lambda (c) (equal? (proc-id c) "mill")) columns))
            (grow (find (lambda (c) (equal? (proc-id c) "grow")) columns)))
        (format #t "  bake: bread+~,1f flour-~,1f labour ~,1f   [expect +1 -1 0.5]~%"
                (tech bake "bread") (- (tech bake "flour")) (proc-labour bake))
        (format #t "  mill: flour+~,1f grain-~,1f labour ~,1f   [expect +1 -1.2 0.3]~%"
                (tech mill "flour") (- (tech mill "grain")) (proc-labour mill))
        (format #t "  grow: grain+~,1f soil-~,1f labour ~,1f   [expect +1 -1 0.5]~%"
                (tech grow "grain") (- (tech grow "soil")) (proc-labour grow))))))

(report)
(newline)
