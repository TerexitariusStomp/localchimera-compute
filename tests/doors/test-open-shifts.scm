;;; test-open-shifts.scm — an open shift is the plan's own need, carried, not rebuilt.
;;;
;;; plan->work lays one NEED intent per process, skill and cell with the hours
;;; summed over the workers it placed, and one work commitment per worker. The
;;; landing persists the open shifts off the needs: two workers sharing a
;;; process lay ONE shift of the whole need, where a rebuild off the work rows
;;; keyed by the same id kept only the last worker's share (measured 2026-10-12).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-open-shifts.scm
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas)
             ((playnet vf formulas flows) #:select (make-work-intent make-work-commitment))
             ((playnet doors offers) #:select (persist-open-shifts!))
             (goblins) (srfi srfi-1))

(define (ni-intents ps)
  (filter (lambda (i) (string-prefix? "ni|" (intent-id i))) ($ ps 'all-intents)))

(define vat (spawn-vat #:name "open-shifts"))
(with-vat vat
  (let* ((root (spawn-scope-root "S"))
         (ps   ($ root 'plan-store))
         (need (make-work-intent #:id "ni|bake|baker|A@0" #:skill "baker" #:hours 5.0 #:input-of "bake"
                                 #:has-beginning "2099-01-01T09:00:00Z" #:has-end "2099-01-01T17:00:00Z"
                                 #:at-location "A"))
         (offer (make-work-intent #:id "oi|ada|baker|A@0" #:skill "baker" #:hours 8.0 #:provider "ada" #:offered? #t
                                  #:has-beginning "2099-01-01T09:00:00Z" #:has-end "2099-01-01T17:00:00Z"
                                  #:at-location "A"))
         (w1 (make-work-commitment #:id "wc|ada" #:provider "ada" #:skill "baker" #:hours 3.0 #:input-of "bake"
                                   #:has-beginning "2099-01-01T09:00:00Z" #:has-end "2099-01-01T17:00:00Z" #:at-location "A"
                                   #:satisfies '("ni|bake|baker|A@0" "oi|ada|baker|A@0")))
         (w2 (make-work-commitment #:id "wc|bob" #:provider "bob" #:skill "baker" #:hours 2.0 #:input-of "bake"
                                   #:has-beginning "2099-01-01T09:00:00Z" #:has-end "2099-01-01T17:00:00Z" #:at-location "A"
                                   #:satisfies '("ni|bake|baker|A@0" "oi|bob|baker|A@0")))
         (cached (cons '() `((intend . ,(list need offer)) (work . ,(list w1 w2)) (material . ())))))
    (persist-open-shifts! root cached)
    (let ((laid (ni-intents ps)))
      (check "one open shift per need, not one per worker" (length laid) 1)
      (check "…the whole need's hours, not the last worker's share"
             (measure-has-numerical-value (intent-effort-quantity (car laid))) 5.0)
      (check "…the need itself, carried: its id" (intent-id (car laid)) "ni|bake|baker|A@0")
      (check "an offer is no shift" (find (lambda (i) (string-prefix? "oi|" (intent-id i))) ($ ps 'all-intents)) #f))
    ;; a closed window lays nothing
    (let ((closed (make-work-intent #:id "ni|bake|baker|A@1" #:skill "baker" #:hours 5.0 #:input-of "bake"
                                    #:has-beginning "2020-01-01T09:00:00Z" #:has-end "2020-01-01T17:00:00Z"
                                    #:at-location "A")))
      (persist-open-shifts! root (cons '() `((intend . ,(list closed)) (work . ()) (material . ()))))
      (check "a closed window is never an open shift" (length (ni-intents ps)) 0))))
(test-summary!)
