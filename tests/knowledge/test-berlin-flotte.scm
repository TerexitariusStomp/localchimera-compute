;;; test-berlin-flotte.scm — the fLotte loan pool reaches a scope as held resources.
;;;
;;; flotte-berlin-resources called bt-cargo-bike-resource with a lender and a loan
;;; window it has no keywords for, so every call raised. A bike drawn from the
;;; pool is custody without rights: the lender is accountable, the scope holds it,
;;; and it is bookable on the loan window's days.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/knowledge/test-berlin-flotte.scm

(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet vf beyond schedules)
             (playnet knowledge recipes berlin-flotte)
             (srfi srfi-1))

(define bikes (flotte-berlin-resources "org:kiez" #:count 3 #:at "place:kiez"))

(display "\n── the pool as held resources ──\n")
(check "one resource per bike asked for" (length bikes) 3)
(check "ids are distinct" (length (delete-duplicates (map economic-resource-id bikes))) 3)
(check "the scope holds them" (delete-duplicates (map economic-resource-custodian-scope bikes)) '("org:kiez"))
(check "the lender is accountable, so the scope borrows and owns none"
       (delete-duplicates (map economic-resource-primary-accountable bikes)) '("org:flotte-berlin"))
(check "they stand at the place given" (delete-duplicates (map economic-resource-current-location bikes)) '("place:kiez"))

(display "\n── the loan window ──\n")
(check-pred "each is bookable on the loan window"
            (every (lambda (b) (availability-window? (economic-resource-availability-window b))) bikes))
(check "its days are the window's"
       (day-schedule-days (car (availability-window-day-schedules (economic-resource-availability-window (car bikes)))))
       '(monday tuesday wednesday))

(display "\n── a district's own pool, and the spread ──\n")
(let ((kommunal (flotte-berlin-resources "org:kiez" #:bezirk "mitte")))
  (check "a Bezirk's bikes come from its kommunal lender"
         (economic-resource-primary-accountable (car kommunal)) (flotte-kommunal-lender "mitte")))
(let ((spread (flotte-spread-resources "org:kiez" '("mitte" "pankow") #:per-bezirk 2)))
  (check "the spread draws per-bezirk from each district" (length spread) 4)
  (check "…from two different lenders"
         (length (delete-duplicates (map economic-resource-primary-accountable spread))) 2))

(test-summary!)
