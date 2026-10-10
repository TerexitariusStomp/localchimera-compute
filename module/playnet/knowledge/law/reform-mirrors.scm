;;; law/reform-mirrors.scm — the (L, I, D) mirror beside each spec-bearing demand,
;;; so reform.scm can derive the four cells and the move (legal-crossings
;;; §8). L/I/D are now fully DERIVED from real ValueFlows recipes (legal-aspects):
;;;
;;;   L (legal)    = the demand's own spec               ← the REGISTRY (derived)
;;;   kind         = entity→permit / person→licence      ← the demand's ride
;;;   D (desired)  = our DESIRED recipe's aspects ∩ L     ← *desired-aspects* (the
;;;                                                         genuine functions, no shell)
;;;   I (internal) = the aspects our running ways perform ∩ L ← `practised?` (what we DO)
;;;
;;; L is written in the law's own words. A clause enters the diff when it is
;;; MAPPED onto a federation aspect (law/aspects.scm `clause-aspect`): D and I
;;; are questions about the aspect. A clause nobody has mapped stays out of all
;;; four regions and is reported as `unmapped` — nothing is yet said of it.
;;;
;;; No hand-typed duress table any more: an aspect carries its own `shell?` flag
;;; (law/aspects.scm), so the duress falls out of the diff as transform = L − D.
;;; Loaded after reform.scm + legal-aspects + legal-registry (+ the rule library).

;;; build a <spec-mirror> for any spec-bearing obtain — L from the registry, I/D
;;; read off the federation's actual/desired recipe aspect-sets (legal-aspects).
(define-module (playnet knowledge law reform-mirrors)
  #:use-module (srfi srfi-1)
  #:use-module (playnet legal registry)
  #:use-module (playnet legal reform)
  #:use-module (playnet knowledge law aspects)
  #:export (demand->mirror demand-unmapped demand-reform))

(define (clauses-under aspects L)       ; the clauses of L whose aspect is among ASPECTS
  (filter (lambda (c) (memq (clause-aspect c) aspects)) L))

(define (demand-unmapped d)             ; the clauses of the spec nobody has mapped
  (remove clause-aspect (or (demand-spec d) '())))

(define (demand->mirror d)
  (let ((spec (demand-spec d)))
    (and (pair? spec) (eq? (demand-kind d) 'obtain)
         (let* ((L    (filter clause-aspect spec))                    ; the mapped clauses
                (D    (clauses-under *desired-aspects* L))            ; what we want, of L
                (I    (filter (lambda (c) (practised? (clause-aspect c))) L)) ; what we do, of L
                (kind (if (eq? (demand-rides d) 'person) 'licence 'permit)))
           (spec-mirror (demand-name d) #:kind kind #:legal L #:internal I #:desired D)))))

;;; the reform stance of one demand (for the panel): regions + index, or #f.
(define (demand-reform d)
  (let ((m (demand->mirror d)))
    (and m (cons (cons 'unmapped (demand-unmapped d)) (reform-entry m)))))
