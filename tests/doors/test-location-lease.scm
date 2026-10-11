;;; test-location-lease.scm — live location is a consented lease.
;;;
;;; A person who shares where they are declares it: `set-location-sharing`
;;; states the mode (live, here, off) in a row at their home, and every device
;;; reads the same one. A fix is a lease — it counts while it is fresh and ends
;;; by itself when the page that sent it is gone — and a declared future place
;;; counts for its own period. Off ends the fix and refuses the next. The home
;;; carries all of it: sharing through any scope lands at the home, and a move
;;; takes the declaration with the person.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/doors/test-location-lease.scm

(use-modules (playnet test harness)
             (playnet knowledge recipes federation-demo) (playnet scope root)
             (playnet doors service) (playnet doors position)
             (playnet knowledge recipes federation-demo)
             ((playnet utils clock) #:select (now))
             (goblins) (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat))

(define (world)
  (let ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table"))
        (svc (spawn ^planner-service (hashmap))))
    (seed-fed-commune! a "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 300.0)
    (seed-fed-commune! b "fed" "commune-table" "Table" "venue-table" 42.75 23.40 0.0)
    ($ svc 'add-scope! "Granary" a)
    ($ svc 'add-scope! "Table" b)
    (values svc a b)))

(define (pos-of root aid period)
  (let ((f (agent-position-predicate root))) (and f (f aid period))))

(with-vat vat
  (call-with-values world
    (lambda (svc a b)
      (define place "venue-granary")
      (display "\n── a fix is a lease ──\n")
      ($ svc 'set-position "Granary" "ada" 0 place)
      (check "a fresh fix counts" (pos-of a "ada" 0) place)
      ;; the page that sent it is gone: its fix is an hour old
      (let ((row ($ ($ a 'plan-store) 'get-meta "pos|ada|0")))
        ($ ($ a 'plan-store) 'set-meta "pos|ada|0" (acons 'at (- (now) 3600) (alist-delete 'at row))))
      (check "an hour old, it ends by itself" (pos-of a "ada" 0) #f)
      ($ svc 'set-position "Granary" "ada" 0 place)
      (check "sent again, it counts again" (pos-of a "ada" 0) place)
      ($ svc 'set-position "Granary" "ada" 1 place)
      (let ((row ($ ($ a 'plan-store) 'get-meta "pos|ada|1")))
        ($ ($ a 'plan-store) 'set-meta "pos|ada|1" (acons 'at (- (now) 86400) (alist-delete 'at row))))
      (check "a place declared for a later period counts for that period, however old the word"
             (pos-of a "ada" 1) place)

      (display "\n── the mode is declared, at the home, and read back ──\n")
      (check "nothing declared yet" (cdr ($ svc 'location-sharing "Granary" "ada")) 'undeclared)
      (check "declared through the other scope, it lands at the home"
             (list (car ($ svc 'set-location-sharing "Table" "ada" "live"))
                   (and ($ ($ a 'plan-store) 'get-meta "location-share:ada") #t)
                   (and ($ ($ b 'plan-store) 'get-meta "location-share:ada") #t))
             '(ok #t #f))
      (check "and read back from either scope" (cdr ($ svc 'location-sharing "Table" "ada")) 'live)
      (check "a mode that is none of the three is refused"
             (car ($ svc 'set-location-sharing "Granary" "ada" "always")) 'error)

      (display "\n── off ends the fix and refuses the next ──\n")
      ($ svc 'set-location-sharing "Granary" "ada" "off")
      (check "the fix is gone" (pos-of a "ada" 0) #f)
      (check "a fix sent while off is refused" (car ($ svc 'set-position "Granary" "ada" 0 place)) 'error)
      (check "and so is a raw one" (car ($ svc 'set-position-latlon "Granary" "ada" 0 42.70 23.32)) 'error)
      (check "a place for a later period is not a fix, and is taken"
             (car ($ svc 'set-position "Granary" "ada" 1 place)) 'ok)
      ($ svc 'set-location-sharing "Granary" "ada" "here")
      (check "turned on again, the next fix is taken" (car ($ svc 'set-position "Granary" "ada" 0 place)) 'ok)

      (display "\n── a move takes the declaration with the person ──\n")
      ($ svc 'set-profile "Granary" "ada" "[]")
      ($ svc 'move-home "ada" "Table")
      (check "the mode is read at the new home"
             (list (cdr ($ svc 'location-sharing "Granary" "ada"))
                   (and ($ ($ b 'plan-store) 'get-meta "location-share:ada") #t))
             '(here #t))
      (check "and no longer stands at the old"
             (let ((m ($ ($ a 'plan-store) 'get-meta "location-share:ada")))
               (or (not m) (null? m)))
             #t))))

(test-summary!)
