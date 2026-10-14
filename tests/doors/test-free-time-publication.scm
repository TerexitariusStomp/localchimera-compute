;;; test-free-time-publication.scm — f is the federation's, read off the fold.
;;;
;;; Every plan that lands states its people's time, and the service counts each
;;; person once, at the scope they are at home in. The scopes' nameless sums
;;; rise through the fold, and the UC's total is the f credit and consumer voice
;;; read. So:
;;;   • a plan that lands states the time of the people at home in its scope;
;;;   • a person a plan places who is at home elsewhere is counted at their home,
;;;     once, however many plans place them; a person with no home counts nowhere;
;;;   • two roots are one federation: their people add;
;;;   • a child's plan counts, whether or not its root has planned;
;;;   • a question (a what-if) never lands, and moves nothing;
;;;   • a plan landing again restates its scope's sums, and re-delivery of the
;;;     same plan changes nothing;
;;;   • refederation moves a scope in the tree and leaves the federation's f
;;;     whole: nothing lost, nothing counted twice;
;;;   • no plan reply names a person's time, and a restarted service stands on
;;;     what its stores hold.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-free-time-publication.scm
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas)
             (playnet doors service)
             (playnet algorithms elastic)
             ((playnet vf facts person-facts) #:select (home-row))
             ((playnet utils keywords) #:select (kw-ref))
             (goblins) (goblins vat) (goblins utils hashmap))

(define (near? a b) (< (abs (- a b)) 1e-9))

;; who is at home where: ada and bo at R, dan at R2, cy at C; eve nowhere
(define homes '(("ada" . "R") ("bo" . "R") ("dan" . "R2") ("cy" . "C")))

;; what each scope's plan places, naming people from other homes too: R's plan
;; places cy, who is at home in C, and eve, who has no home; C's plan places ada.
;; R's planned hours for ada are a variable so a plan can land again with new ones.
(define r-planned 6.0)
(define (people-of sid what-if?)
  (cond ((equal? sid "R")  (if what-if? '(("ada" 8.0 8.0) ("bo" 8.0 8.0))
                               `(("ada" ,r-planned 8.0) ("bo" 2.0 8.0) ("cy" 7.0 8.0) ("eve" 8.0 8.0))))
        ((equal? sid "R2") '(("dan" 8.0 8.0)))
        (else              '(("cy" 1.0 8.0) ("ada" 3.0 8.0)))))       ; C

(define (stub-plan-fn root sid . kw)
  `((met . 1.0) (feasible . #t) (x . #(1.0 2.0 3.0)) (intend) (work) (material)
    (social . ((by-person . ,(people-of sid (pair? (kw-ref kw #:demand))))))))

(define (home! root aid) ($ ($ root 'plan-store) 'set-meta (home-row aid) '((home . #t))))

(set-social-free-time! 0)
(define roots '())                         ; ((id . scope-root) …), spawned in the vat below
(with-vat (spawn-vat #:name "free-time-publication")
  (let* ((svc   (spawn ^planner-service (hashmap) stub-plan-fn))
         (root  (lambda (sid) (assoc-ref roots sid)))
         (f     current-social-free-time))
    (set! roots (map (lambda (sid) (cons sid (spawn-scope-root sid))) '("R" "R2" "C")))
    (for-each (lambda (h) (home! (root (cdr h)) (car h))) homes)
    (for-each (lambda (sid) ($ svc 'add-scope! sid (root sid))) '("R" "R2" "C"))
    ($ svc 'move-scope! "C" "R")
    (check "before any plan lands f is 0" (near? (f) 0))

    (display "\n── a plan lands: it states the time of the people at home here ──\n")
    (let ((r ($ svc 'solve "R" '())))
      (check "R counts ada and bo, not cy (at home in C) nor eve (at home nowhere): f = 1 − 8/16" (near? (f) 0.5))
      (check "the reply names no person's time"
             (not (assq 'by-person (assq-ref (cdr r) 'social)))))

    (display "\n── a question stands for nothing ──\n")
    ($ svc 'solve-brief "R" '((demand . (("soup" "town" 0 5.0)))))
    (check "a what-if brief leaves f where the landed plan put it" (near? (f) 0.5))

    (display "\n── two roots are one federation ──\n")
    ($ svc 'solve "R2" '())
    (check "R2's dan adds to R's people: f = 1 − 16/24" (near? (f) (- 1.0 (/ 16.0 24.0))))

    (display "\n── a child's plan counts, and a person is counted once ──\n")
    ($ svc 'solve "C" '())
    (check "cy at C adds, and ada, placed by C but at home in R, is not counted twice: f = 1 − 17/32"
           (near? (f) (- 1.0 (/ 17.0 32.0))))

    (display "\n── refederation leaves f whole ──\n")
    ($ svc 'move-scope! "C" "R2")
    (check "C moved under R2: nothing lost, nothing counted twice" (near? (f) (- 1.0 (/ 17.0 32.0))))
    ($ svc 'move-scope! "C" #f)
    (check "C moved to the top: the same" (near? (f) (- 1.0 (/ 17.0 32.0))))

    (display "\n── a plan landing again restates its scope's sums ──\n")
    ($ svc 'solve "R" '())
    (check "the same plan re-delivered changes nothing" (near? (f) (- 1.0 (/ 17.0 32.0))))
    (set! r-planned 2.0)
    ($ svc 'solve "R" '())
    (check "R's new plan places 2 h on ada: f = 1 − 13/32" (near? (f) (- 1.0 (/ 13.0 32.0))))

    (display "\n── a restarted service stands on what its stores hold ──\n")
    (set-social-free-time! 0)
    (let ((svc2 (spawn ^planner-service (hashmap) stub-plan-fn)))
      (for-each (lambda (sid) ($ svc2 'add-scope! sid (root sid))) '("R" "R2" "C"))
      (check "the landed plans' sums seed f again, no solve run" (near? (f) (- 1.0 (/ 13.0 32.0)))))))

(test-summary!)
