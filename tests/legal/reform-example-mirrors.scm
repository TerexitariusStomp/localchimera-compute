;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; reform-example-mirrors.scm — seven worked mirrors, one of each kind, and
;;; the program they sort into.
;;;
;;; Examples of the form (a permit part safety and part exclusion, a licence we
;;; fully share, a levy we accept, one we contest, an existence wrapper). The
;;; federation's own mirrors are knowledge/reform-mirrors.scm.
;;;
;;;   guile -L module tests/legal/reform-example-mirrors.scm      ; prints the program

(use-modules (localchimera legal reform) (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define *example-mirrors*
  (list
   ;; the homeless-housing case: a permit PART safety (absorbed), PART exclusion.
   (spec-mirror "Building Permit" #:kind 'permit
     #:legal    '(fire-egress structural ventilation min-unit-size parking-minimum)
     #:internal '(fire-egress structural ventilation)
     #:desired  '(fire-egress structural ventilation))
   ;; competence licence we fully share — recognise our clinicians.
   (spec-mirror "CA Medical License" #:kind 'licence
     #:legal '(competence ethics scope-of-practice)
     #:internal '(competence ethics scope-of-practice)
     #:desired  '(competence ethics scope-of-practice))
   ;; ecological permit: we want it (and MORE) and already verify it.
   (spec-mirror "Discharge Permit" #:kind 'permit
     #:legal '(within-envelope monitoring reporting)
     #:internal '(within-envelope monitoring reporting)
     #:desired  '(within-envelope monitoring reporting stricter-cap))
   ;; levy we accept (we sell to the public, so we collect the tax).
   (spec-mirror "Sales Tax" #:kind 'levy
     #:legal '(sales-tax) #:desired '(sales-tax))
   ;; levy we contest: a self-provisioning commune funding the state's services.
   (spec-mirror "Property Tax" #:kind 'levy
     #:legal '(property-tax) #:desired '())
   ;; disclosure we contest (the pseudonymity duress-gap).
   (spec-mirror "Beneficial-Ownership Report" #:kind 'disclosure
     #:legal '(controller-name controller-id) #:desired '())
   ;; existence wrapper: no spec — the doorkeeper floor.
   (spec-mirror "DEA Registration" #:kind 'registration #:legal #f)))

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (set->str s) (if (null? s) "·" (string-join (map symbol->string s) " ")))
(define (reform-demo)
  (format #t "~%reform program (the move we can make now first):~%~%")
  (for-each
   (lambda (e)
     (let ((stance (assq-ref e 'stance)))
       (cond
        ((eq? stance 'interface-floor)
         (format #t "~28a [~a]  interface floor — not a reform target~%"
                 (assq-ref e 'name) (assq-ref e 'kind)))
        ((memq (assq-ref e 'kind) '(permit licence))
         (format #t "~28a [~a]  move: ~a~%"
                 (assq-ref e 'name) (assq-ref e 'kind) (reform-move e))
         (let ((red (assq-ref e 'redundant)) (ab (assq-ref e 'absorb-first))
               (tr (assq-ref e 'transform-law)))
           (when (pair? red)
             (format #t "    REDUNDANT-CHECK  ~a   (demand recognition)~%" (set->str red)))
           (when (pair? ab)
             (format #t "    ABSORB-FIRST     ~a   (build internal inspection)~%" (set->str ab)))
           (when (pair? tr)
             (format #t "    TRANSFORM-LAW    ~a   (duress-gap → advocate L→D)~%" (set->str tr)))))
        (else                                   ; levy / disclosure
         (format #t "~28a [~a]~%" (assq-ref e 'name) (assq-ref e 'kind))
         (let ((ac (assq-ref e 'accept)) (tr (assq-ref e 'transform-law)))
           (when (pair? ac) (format #t "    KEEP             ~a   (accepted)~%" (set->str ac)))
           (when (pair? tr) (format #t "    TRANSFORM-LAW    ~a   (duress-gap → advocate L→D)~%"
                                    (set->str tr))))))))
   (reform-program *example-mirrors*)))

(when (and (pair? (command-line))
           (string-suffix? "reform-example-mirrors.scm" (car (command-line))))
  (reform-demo))
