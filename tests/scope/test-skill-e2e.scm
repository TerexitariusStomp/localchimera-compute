;;; test-skill-e2e.scm — composition through the live planner (Stage 6)
;;;
;;; A spec's satisfied-by lets a worker who holds the COMPONENT skills supply the
;;; composite via the effective-skills closure wired into plan-scope. One person
;;; holding {electrician, surgeon} fills an electrosurgery slot without holding
;;; "electrosurgeon" directly; a worker missing a component cannot.
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/scope/test-skill-e2e.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness))
(use-modules (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet scope live))
(use-modules (goblins) (goblins vat) (srfi srfi-1))
(use-modules ((playnet solve engine) #:select (set-period-length!)))
;; A period here is a WEEK: the roster's Monday–Friday 09:00–17:00 is a working week of hours, on any date.
(set-period-length! 1.0 "week")

;; treat: 0.5h of "electrosurgeon" labour → 1 "treated"
(define procs (list (rp* "treat" "Treat")))
(define flows (list (out* "f1" "treated" 1.0 "treat") (wk* "f2" "electrosurgeon" 0.5 "treat")))
(define recipes (list (make-recipe #:id "treat-recipe" #:name "Treatment" #:primary-output "treated"
                                   #:recipe-processes '() #:recipe-exchanges '())))
;; the catalogue: electrosurgeon is satisfied-by holding electrician AND surgeon
(define specs (list (make-resource-specification
                      #:id "electrosurgeon" #:name "Electrosurgeon" #:resource-classified-as '() #:default-unit-of-effort %effort-unit
                      #:satisfied-by '((("electrician" . 0) ("surgeon" . 0))))))
(define win (all-week-window "09:00" "17:00"))
;; doc holds BOTH components ⇒ electrosurgeon via substitute; tech holds only electrician
(define resources (list (er "d1" "electrician" "doc" #:qty 1.0) (er "d2" "surgeon" "doc" #:qty 1.0)
                        (er "t1" "electrician" "tech" #:qty 1.0)))
(define agents (list (make-agent #:id "doc" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "tech" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define vat (spawn-vat))
(define result
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (skill-hours-of . ,(lambda (aid) '()))  ; threshold-0 ⇒ empty ledger ok
                               (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (all-resource-specs . ,(lambda () specs))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process
                                . ,(lambda (pid)
                                     (cons (filter (lambda (f)
                                                     (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                         (equal? (recipe-flow-recipe-output-of f) pid)))
                                                   flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (call-with-values
        (lambda () (plan-scope scope #:demand '(("treated#town@0" . 10.0)) #:backend 'native-c))
        (lambda (intents commitments material fill x ntot report) (list fill commitments))))))

(define fill (car result))
(define commitments (cadr result))
(define (providers-for skill)
  (delete-duplicates
   (filter-map (lambda (c) (and (equal? (commitment-resource-conforms-to c) skill)
                                (commitment-provider c)))
               commitments)))

(display "\n── Composite conformance fills the electrosurgery demand ──\n")
(check-pred "demand substantially met" (> fill 0.9))
(check-pred "doc supplies electrosurgeon (via electrician+surgeon)"
            (member "doc" (providers-for "electrosurgeon")))
(check-pred "tech (electrician only) does NOT supply electrosurgeon"
            (not (member "tech" (providers-for "electrosurgeon"))))

(display "\n")
(test-summary!)
