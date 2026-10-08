;;; test-haul-work.scm — the driver's work on a haul is one need per recipe, and an accept of it
;;; pins nothing the solve cannot place.
;;;
;;; A haul between two places is one RUN of its recipe per arc (`p|<recipe>|<origin>|<destination>`),
;;; and the driver's `work` row names the recipe (`input-of` = the recipe's process): VF's need
;;; "process P wants E hours of skill s at c" is stated once per process, skill and cell. Two runs
;;; of one recipe from one origin to two destinations ask the same need twice over; the need
;;; states their sum. An accept of that work is a commitment that names the recipe and the origin
;;; place and no destination, so it names no column of the solve (a haul's column is the arc): the
;;; accept is not pinned, and the log says why.
;;;
;;;   ONE NEED    two runs of one recipe from one origin: one need intent, whose hours are the runs' sum
;;;   UNIQUE IDS  every intent and commitment the work side emits has an id of its own
;;;   ASKED       the need's hours are the labour the haul's runs ask of the skill, summed
;;;   CONSERVED   the hours committed are the hours the worker offers
;;;   HAUL ACCEPT a work accept on a haul recipe pins nothing, and does not raise
;;;   ORDINARY    a work accept on an ordinary recipe pins as before
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-haul-work.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes transport) (playnet planner solve compile) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver)
             (playnet planner vf schemas)
             ((playnet planner plan accepts) #:select (accepts->pins))
             (playnet planner knowledge dsl shorthand)
             (playnet planner knowledge recipes transport)
             (srfi srfi-1) (srfi srfi-13))

(define E (resolve-module '(playnet planner solve engine)))
(define haul (relocation-recipe "haul" "Haul" "crates" #:payload 25.0 #:unit "kg" #:work '("courier" . 0.06)))

(define (sum xs) (fold + 0.0 xs))
(define (unique? ids) (= (length ids) (length (delete-duplicates ids))))

(display "\n── the work side of two runs of one recipe from one origin ──\n")
(declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.045) ("C" 0.045 0.0)) #:periods '(0)
                #:templates (compile-recipe (list (car haul)) (cadr haul))
                #:movable '("crates")
                #:workers (list (list "w" '("courier") (cell "A" 0) 100.0)))
(hash-set! *init* (lg "crates" (cell "A" 0)) 100.0)
(hash-set! *demand* (lg "crates" (cell "B" 0)) 25.0)
(hash-set! *demand* (lg "crates" (cell "C" 0)) 25.0)
(define-values (ints coms asked)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x0 ((module-ref E 'located-warm) cols ncol idx))
             (x (call-with-values (lambda () (solve-native forms labform x0)) (lambda (x . _) x))))
        (check-pred "both arcs are run"
                    (every (lambda (arc) (> ((module-ref E 'col-value) x idx (string-append "p|haul|A@0|" arc "@0")) 1e-4))
                           '("B" "C")))
        (call-with-values (lambda () (plan->work x cols idx))
          (lambda (ints coms . _)
            (values ints coms
                    (sum (append-map (lambda (c)
                                       (let ((v ((module-ref E 'col-value) x idx (col-key c))))
                                         (filter-map (lambda (fc) (and (string-prefix? "Lab|" (car fc)) (> v 1e-4)
                                                                       (string-prefix? "p|haul|" (col-key c))
                                                                       (* (- (cdr fc)) v)))
                                                     ((module-ref E 'col-flows) c))))
                                     cols)))))))))
(define needs  (filter (lambda (i) (not (intent-provider i))) ints))
(define offers (filter intent-provider ints))
(check "one need for the recipe at the origin cell" (map intent-id needs) '("ni|haul|courier|A@0"))
(check-pred "every intent has an id of its own" (unique? (map intent-id ints)))
(check-pred "every commitment has an id of its own" (unique? (map commitment-id coms)))
(check-pred "the hours committed are the hours the worker offers"
            (< (abs (- (sum (map (lambda (c) (measure-has-numerical-value (commitment-effort-quantity c))) coms))
                       (sum (map (lambda (o) (measure-has-numerical-value (intent-effort-quantity o))) offers))))
               1e-6))
(check-pred "…and the need's hours are what the runs ask, summed"
            (< (abs (- (sum (map (lambda (n) (measure-has-numerical-value (intent-effort-quantity n))) needs)) asked)) 1e-6))
(check "every commitment names the recipe" (delete-duplicates (map commitment-input-of coms)) '("haul"))

(display "\n── an accept of the driver's work ──\n")
(define (accept id proc)
  (make-commitment #:id id #:action 'work #:input-of proc #:resource-conforms-to "courier"
                   #:effort-quantity (make-measure 0.5 "hours") #:provider "w" #:at-location "A"))
(define ordinary (list (wk* "oW" "courier" 2.0 "dig") (out* "oF" "hole" 1.0 "dig")))
(check "a work accept on a haul recipe pins nothing"
       (accepts->pins (list (accept "c-haul" "haul")) (cadr haul)) '())
(check-pred "a work accept on an ordinary recipe pins as before"
            (= 1 (length (accepts->pins (list (accept "c-dig" "dig")) ordinary))))

(test-summary!)
