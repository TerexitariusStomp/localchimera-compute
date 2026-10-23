;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/scope/test-certificate-wall.scm — THE CERTIFICATE IS A STOCK THE SOLVE RESPECTS.
;;;
;;; A citizen's drawable credit enters the solve as a bar over their claim
;;; columns (engine *certificates*, #:certificates): the plan's claims are
;;; affordable by construction, and the ledger's balance check at the event
;;; is a race guard, never the rule. Ten kilos of wheat stand at one hour a
;;; kilo; ada wants four.
;;;   • no certificate stated, no ledger on the root → no bar: the plan claims 4
;;;   • ada holds 2 h                                → the plan claims 2
;;;   • ada holds nothing                            → the plan claims 0, the
;;;     want stands unmet, the plan is still a plan
;;;   • the certificate binds across cells: 2 h split over two places is 2 h
;;;
;;; Run:  guile -L module tests/scope/test-certificate-wall.scm
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define PLACE "town")
(define procs (list (make-recipe-process #:id "grow" #:name "Grow")))
(define flows
  (list (make-recipe-flow #:id "gw" #:action 'work #:resource-conforms-to "skill-grow"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "grow")
        (make-recipe-flow #:id "go" #:action 'produce #:resource-conforms-to "wheat"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "grow"
                          #:is-primary #t)))
(define recipes (list (make-recipe #:id "grow-recipe" #:name "Grow" #:primary-output "wheat"
                                   #:recipe-processes (list "grow"))))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)
                       (make-spatial-thing #:id "field" #:lat 40.01 #:long -74.0)))
(define win (all-week-window "00:00" "23:59"))
(define agents (list (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)))
(define (wheat-at place)
  (make-economic-resource #:id (string-append "r-wheat-" place) #:name "the granary" #:conforms-to "wheat" #:classified-as '()
    #:accounting-quantity (make-measure 10.0 "kg") #:onhand-quantity (make-measure 10.0 "kg") #:current-location place #:primary-accountable "commune"))

(define vat (spawn-vat #:name "certificate-wall"))

(define* (run #:key (certificates 'unstated) (demand (list (cons (format #f "wheat~~ada#~a@0" PLACE) 4.0)))
              (stock (list (wheat-at PLACE))))
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () stock)) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs (mock-recipe-store #:recipes recipes #:procs procs #:flows flows #:split? #t))
           (ps  (mock-plan-store))
           (root (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps)))
      (apply plan-scope->alist root
             #:demand demand #:periods '(0) #:reproduce? #f
             #:eco-caps (list (cons (format #f "wheat#~a@0" PLACE) 0.0) (cons "wheat#field@0" 0.0))
             #:backend 'native-c
             (if (eq? certificates 'unstated) '() (list #:certificates certificates))))))

(define (claimed alist aid spec)
  (fold (lambda (c a) (if (and (equal? (assq-ref c 'claimant) aid) (equal? (assq-ref c 'conforms-to) spec))
                          (+ a (assq-ref c 'quantity)) a))
        0.0 (or (assq-ref alist 'claims) '())))
(define (drawn alist aid) (or (assoc-ref (or (assq-ref alist 'credit-drawn) '()) aid) 0.0))
(define (≈ a b) (< (abs (- a b)) 0.05))

(format #t "~%── ada wants 4 kg of 10, at 1 h/kg ──~%")
(let ((p (run)))
  (format #t "  no certificate: claims ~,2f, drew ~,2f h~%" (claimed p "ada" "wheat") (drawn p "ada"))
  (check "no certificate stated, no ledger: the plan claims her 4" (≈ (claimed p "ada" "wheat") 4.0) #t))

(let ((p (run #:certificates '(("ada" . 2.0)))))
  (format #t "  2 h certificate: claims ~,2f, drew ~,2f h~%" (claimed p "ada" "wheat") (drawn p "ada"))
  (check "2 h: the plan claims 2 — what she can afford, by construction" (≈ (claimed p "ada" "wheat") 2.0) #t)
  (check "…and the tally reads the 2 h drawn"                          (≈ (drawn p "ada") 2.0) #t)
  (check "…and the plan is a plan"  (not (eq? #f (assq-ref p 'feasible))) #t))

(let ((p (run #:certificates '(("ada" . 0.0)))))
  (format #t "  0 h certificate: claims ~,2f~%" (claimed p "ada" "wheat"))
  (check "nothing to draw: the plan claims 0, the want stands unmet" (≈ (claimed p "ada" "wheat") 0.0) #t)
  (check "…and the plan is still a plan"  (not (eq? #f (assq-ref p 'feasible))) #t))

(format #t "~%── the bar spans cells: 2 h over two places is 2 h ──~%")
(let ((p (run #:certificates '(("ada" . 2.0))
              #:demand (list (cons (format #f "wheat~~ada#~a@0" PLACE) 4.0) (cons "wheat~ada#field@0" 4.0))
              #:stock (list (wheat-at PLACE) (wheat-at "field")))))
  (format #t "  two cells: claims ~,2f in all~%" (claimed p "ada" "wheat"))
  (check "one certificate, however many cells" (≈ (claimed p "ada" "wheat") 2.0) #t))

(display "\n")
(test-summary!)
