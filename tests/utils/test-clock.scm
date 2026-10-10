;;; test-clock.scm — one clock, three scales, civil only at the boundary.
;;;
;;; (playnet utils clock) is the single place a numeric instant is made or
;;; read (open-threads §3.5): the `timescale` parameter names the canonical
;;; scale ('gps default — continuous, no leap seconds), and civil ISO strings
;;; exist only at the edges. These checks pin the scale arithmetic to known
;;; constants (ΔAT = 37 s since 2017, GPS = TAI − 19), prove round-trips are
;;; exact in every scale, and prove the whole module is host-zone-independent
;;; by construction (nothing in it consults the environment's zone).
;;;
;;; Run:  guile -L module -L tests tests/utils/test-clock.scm

(use-modules (playnet test harness)
             (playnet utils clock)
             (ice-9 format))

(format #t "~%── §1 scale anchors: the published constants ──~%")

;; ΔAT through history: 10 at inception, 19 at the GPS epoch, 37 since 2017.
(check "ΔAT at 1972"           (tai-utc-at 63072000) 10)
(check "ΔAT at the GPS epoch"  (tai-utc-at 315964800) 19)
(check "ΔAT after 2017-01-01"  (tai-utc-at 1483228800) 37)
(check "ΔAT today"             (tai-utc-at 1772409600) 37)

;; GPS − Unix = ΔAT − 19: zero at the GPS epoch (the anchoring), 18 today.
(parameterize ((timescale 'gps))
  (check "gps instant = unix at the GPS epoch" (unix->instant 315964800) 315964800)
  (check "gps runs 18 s ahead of unix today"   (- (unix->instant 1772409600) 1772409600) 18)
  (check "gps-seconds of the epoch is zero"    (gps-seconds gps-epoch) 0))

(parameterize ((timescale 'tai))
  (check "tai runs 37 s ahead of unix today"   (- (unix->instant 1772409600) 1772409600) 37))

(parameterize ((timescale 'unix))
  (check "unix scale is the identity"          (unix->instant 1772409600) 1772409600))

(format #t "~%── §2 round-trips are exact in every scale ──~%")

(for-each
 (lambda (scale)
   (parameterize ((timescale scale))
     ;; across the whole table, including both sides of a leap boundary
     (for-each
      (lambda (u)
        (check (format #f "~a: unix ~a survives the round trip" scale u)
               (instant->unix (unix->instant u)) u))
      (list 100000000 315964799 315964800 1483228799 1483228800 1772409600))
     (check (format #f "~a: civil date round-trips" scale)
            (instant->civil (civil->instant "2026-03-02") "%Y-%m-%d") "2026-03-02")
     (check (format #f "~a: civil datetime round-trips" scale)
            (instant->civil (civil->instant "2026-03-02T09:30:00"))
            "2026-03-02T09:30:00Z")))
 '(gps tai unix))

(format #t "~%── §3 the civil boundary ──~%")

(check "a date-only string reads as UTC midnight"
       (- (civil->instant "2026-03-03") (civil->instant "2026-03-02")) 86400)
(check "an HH:MM string gets its seconds"
       (- (civil->instant "2026-03-02T00:01") (civil->instant "2026-03-02")) 60)
(check "2026-03-02 is a Monday on every host"
       (instant->weekday (civil->instant "2026-03-02")) 1)
(check "garbage is #f, not a wrong instant" (civil->instant "soon") #f)
(check "a non-string is #f"                 (civil->instant 42) #f)

;; A stamp that states its offset names one instant: the civil time minus the offset.
(define (at s) (civil->instant s))
(check "a Z stamp is the naive stamp"            (at "2026-03-02T09:30:00Z") (at "2026-03-02T09:30:00"))
(check "a +02:00 stamp is two hours earlier in UTC"
       (- (at "2026-03-02T09:30:00") (at "2026-03-02T09:30:00+02:00")) 7200)
(check "a -05:00 stamp is five hours later in UTC"
       (- (at "2026-03-02T09:30:00-05:00") (at "2026-03-02T09:30:00")) 18000)
(check "an offset without the colon reads"       (at "2026-03-02T09:30:00+0530") (at "2026-03-02T04:00:00"))
(check "an hour-only offset reads"               (at "2026-03-02T09:30:00+02") (at "2026-03-02T07:30:00"))
(check "minutes-only precision keeps its offset" (at "2026-03-02T09:30+02:00") (at "2026-03-02T07:30:00"))
(check "fractional seconds keep the offset"      (at "2026-03-02T09:30:00.250+02:00") (at "2026-03-02T07:30:00"))
(check "two spellings of one moment are one instant"
       (at "2026-03-02T09:30:00+02:00") (at "2026-03-02T07:30:00Z"))
(check "a date alone has no offset to read"      (at "2026-03-02") (at "2026-03-02T00:00:00"))
(check "an offset past the clock is garbage"     (at "2026-03-02T09:30:00+99:99") #f)
(check "a stray suffix is garbage"               (at "2026-03-02T09:30:00 later") #f)

;; The interval that motivates a continuous scale: across the 2016-12-31 leap
;; second, one civil day held 86401 SI seconds. GPS and TAI count what a clock
;; counted; Unix drops the second so every day divides evenly. Both are facts
;; about the SCALE, visible through the same civil labels.
(parameterize ((timescale 'gps))
  (check "gps: the leap day counts 86401 SI seconds — the second unix drops"
         (- (civil->instant "2017-01-01") (civil->instant "2016-12-31")) 86401))
(parameterize ((timescale 'unix))
  (check "unix: the same day counts 86400 — every day divides evenly"
         (- (civil->instant "2017-01-01") (civil->instant "2016-12-31")) 86400))

(test-summary!)
