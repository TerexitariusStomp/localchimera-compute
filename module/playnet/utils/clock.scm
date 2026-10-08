;;; clock.scm — the one clock: time-of-day arithmetic on strings, and the
;;; timescale every numeric instant is counted on.
;;;
;;; Two layers, one module. The FIRST is what "HH:MM to HH:MM" means; the
;;; SECOND (── the timescale ──, below) is what a NUMBER meaning a moment
;;; means — seconds since 1970-01-01T00:00:00 UTC as counted by the clock the
;;; `timescale` parameter names: 'gps (default), 'tai, or 'unix. GPS and TAI
;;; are continuous — no leap seconds, no DST — so interval arithmetic on
;;; instants is exact; civil ISO strings exist only at the boundary, via
;;; `civil->instant` and `instant->civil`, and a naive string means UTC on
;;; every host (planner-coherence-open-threads §3.5). Records keep civil ISO
;;; strings (scale-free labels); anything numeric is an instant on this scale.
;;;
;;; ── the law, in one line ───────────────────────────────────────────────────
;;; Instants inside, civil UTC at the boundary, a person's own clock only where
;;; a person reads or paints it. Every module reads the wall clock through `now`
;;; here — `(instant->unix (now))` where a unix number is what a record or a
;;; protocol wants, `(instant->civil (now))` where a label is — so one door
;;; answers "when is it" and a pinned or shifted clock reaches everything at
;;; once. The browser is the UX side: its ring is painted in the person's local
;;; time, and what it ships (ui/app/day/mytime.ts `av_sync`) is converted to UTC
;;; with the offset in force, weekday and all, before it becomes a window here.
;;; What is NOT settled by this: a recurring local week is exact in UTC only
;;; within one DST regime (the app re-syncs on every edit and load, so the
;;; offset self-heals after a change), and `planner/solve/routing.scm` classes a trip
;;; by the SERVER's local clock where it means the trip's own place — the one
;;; site that wants a timezone at a location rather than a person's browser.
;;;
;;; ONE statement of what "HH:MM to HH:MM" means, shared by everything that has
;;; an opinion about it. Before this there were three: `matching/availability.scm`
;;; for deciding whether two people can meet, `algorithms/resource-filters.scm`
;;; for filtering offers, and `planner.scm` for turning availability into
;;; capacity. They agreed on the easy cases and disagreed on the real one.
;;;
;;; A 22:00–02:00 shift, measured three ways:
;;;   matching   −1200 minutes, and NO overlap with 00:00–06:00 (it overlaps by 2 h)
;;;   planner    0 minutes, clamped — the shift silently vanishes
;;; Both wrong, differently, which is worse than either being wrong alone.
;;;
;;; ── why strings ────────────────────────────────────────────────────────────
;;; The obvious home for this is beside `<time-range>`. It stays here, and the
;;; reason has changed: record identity used to be the obstacle — the planner and
;;; the matching layer evaluated the same definition twice and got two types —
;;; and `utils/records.scm` settled that, so a `<time-range>` is now one kind of
;;; thing everywhere.
;;;
;;; What remains is direction. `<time-range>` lives in `(playnet planner)`, which
;;; reaches this module; a clock that read records would have to reach back, and
;;; the cycle is worse than the duplication it would remove.
;;;
;;; So the arithmetic sits at the string layer, which depends on nothing, and each
;;; side keeps a thin wrapper that reads its own records — which is where the
;;; difference between them actually belongs.
;;;
;;; ── midnight ───────────────────────────────────────────────────────────────
;;; A range whose end is not after its start crosses midnight: 22:00–02:00 is
;;; 22:00–24:00 together with 00:00–02:00, four hours in two pieces. Everything
;;; here is expressed over that piece list, so no caller has to remember the case
;;; and no caller can forget it.

(define-module (playnet utils clock)
  #:use-module (srfi srfi-1)
  #:export (stand-clock! clock-stood?
            hhmm->minutes minutes->hhmm
            clock-pieces union-minutes clock-ranges-minutes
            clock-length-minutes
            clock-overlap-minutes
            clock-overlaps?
            clock-contains?
            timescale now
            civil->instant instant->civil instant->weekday
            unix->instant instant->unix window-close-epoch
            civil->epoch epoch->civil iso->epoch iso-now month-now
            days->seconds seconds->days
            gps-epoch gps-seconds tai-utc-at))

(define %day 1440)

(define (hhmm->minutes s)
  "\"HH:MM\" → minutes past midnight. Accepts a single-digit hour (\"9:00\")."
  (and (string? s)
       (let ((colon (string-index s #\:)))
         (and colon
              (let ((h (string->number (substring s 0 colon)))
                    (m (string->number (substring s (+ colon 1)))))
                (and (number? h) (number? m) (+ (* 60 h) m)))))))

(define (minutes->hhmm m)
  (format #f "~2,'0d:~2,'0d" (quotient m 60) (remainder m 60)))

(define (clock-pieces start end)
  "A range as a list of (start-min . end-min) pieces within one day.

   A range that does not end after it starts CROSSES MIDNIGHT and is two pieces.
   This is the case every hand-rolled version got wrong, in a different way each
   time, so it is stated once here and nowhere else."
  (let ((s (hhmm->minutes start)) (e (hhmm->minutes end)))
    (cond
     ((or (not s) (not e)) '())
     ((= s e) '())                          ; zero-length, not a whole day
     ((< s e) (list (cons s e)))
     (else    (list (cons s %day) (cons 0 e))))))

(define (union-minutes pieces)
  "The minutes PIECES ((start-min . end-min) …) cover together: overlapping
   pieces are one stretch of the day, counted once."
  (let loop ((ps (sort pieces (lambda (a b) (< (car a) (car b)))))
             (cs #f) (ce #f) (acc 0))
    (cond ((null? ps) (if cs (+ acc (- ce cs)) acc))
          ((not cs) (loop (cdr ps) (caar ps) (cdar ps) acc))
          ((<= (caar ps) ce) (loop (cdr ps) cs (max ce (cdar ps)) acc))
          (else (loop (cdr ps) (caar ps) (cdar ps) (+ acc (- ce cs)))))))

(define* (clock-ranges-minutes ranges #:optional (within #f))
  "Minutes the clock RANGES, ((start . end) …) in \"HH:MM\", cover together on
   one day, each stretch once, correct across midnight. WITHIN, a (start . end)
   range, keeps only what falls inside it. The one reading of how long a
   person's stated ranges are, for the roster and the solve alike."
  (let* ((pieces (append-map (lambda (r) (clock-pieces (car r) (cdr r))) ranges))
         (kept (if (not within) pieces
                   (let ((qs (clock-pieces (car within) (cdr within))))
                     (append-map (lambda (p)
                                   (filter-map (lambda (q)
                                                 (let ((s (max (car p) (car q))) (e (min (cdr p) (cdr q))))
                                                   (and (< s e) (cons s e))))
                                               qs))
                                 pieces)))))
    (union-minutes kept)))

(define (clock-length-minutes start end)
  "Minutes a range covers, correct across midnight."
  (fold + 0 (map (lambda (p) (- (cdr p) (car p))) (clock-pieces start end))))

(define (clock-overlap-minutes s1 e1 s2 e2)
  "Minutes two ranges share, correct when either crosses midnight."
  (let ((ps (clock-pieces s1 e1)) (qs (clock-pieces s2 e2)))
    (fold + 0
          (append-map
           (lambda (p)
             (map (lambda (q) (max 0 (- (min (cdr p) (cdr q)) (max (car p) (car q)))))
                  qs))
           ps))))

(define (clock-contains? start end hhmm)
  "Does a range contain a moment? Half-open: the start is in, the end is not, so
   adjacent ranges do not both claim the boundary. Correct across midnight —
   compared as bare strings, 23:00 read as OUTSIDE a 22:00–02:00 shift."
  (let ((m (hhmm->minutes hhmm)))
    (and m (any (lambda (p) (and (>= m (car p)) (< m (cdr p))))
                (clock-pieces start end)))))

(define (clock-overlaps? s1 e1 s2 e2)
  "Do two ranges share any time at all?"
  (> (clock-overlap-minutes s1 e1 s2 e2) 0))

;; ── the timescale ────────────────────────────────────────────────────────────
;; The scales are anchored so an instant equals the Unix epoch count wherever
;; their clocks agreed: TAI runs ahead of Unix by ΔAT (the leap total, 37 s
;; today), GPS by ΔAT − 19 (18 s today, ZERO at the GPS epoch 1980-01-06 —
;; which is why true GPS seconds are `(- instant gps-epoch)` and nothing more).

;; 'gps | 'tai | 'unix — set ONCE at boot if not the default; flipping it
;; mid-flight re-labels every held instant, which is exactly the drift this
;; module exists to end.
(define timescale (make-parameter 'gps))

;; ΔAT: TAI − UTC after each leap, keyed by the Unix epoch second it took
;; effect. Announced ~6 months ahead by IERS Bulletin C; none since 2017, and
;; the CGPM resolved to stop adding them by 2035 — append here if one lands.
(define *leaps*
  '((63072000 . 10) (78796800 . 11) (94694400 . 12) (126230400 . 13)
    (157766400 . 14) (189302400 . 15) (220924800 . 16) (252460800 . 17)
    (283996800 . 18) (315532800 . 19) (362793600 . 20) (394329600 . 21)
    (425865600 . 22) (489024000 . 23) (567993600 . 24) (631152000 . 25)
    (662688000 . 26) (709948800 . 27) (741484800 . 28) (773020800 . 29)
    (820454400 . 30) (867715200 . 31) (915148800 . 32) (1136073600 . 33)
    (1230768000 . 34) (1341100800 . 35) (1435708800 . 36) (1483228800 . 37)))

(define (tai-utc-at unix)
  "ΔAT (TAI − UTC, whole seconds) in force at Unix second UNIX."
  (let loop ((rest *leaps*) (off 10))
    (cond ((null? rest) off)
          ((<= (caar rest) unix) (loop (cdr rest) (cdar rest)))
          (else off))))

(define (scale-offset unix)                 ; chosen scale − unix, at that moment
  (case (timescale)
    ((unix) 0)
    ((tai)  (tai-utc-at unix))
    ((gps)  (- (tai-utc-at unix) 19))
    (else (error "unknown timescale" (timescale)))))

(define (unix->instant u) (+ u (scale-offset u)))

;; the one day-length: a day of wall-clock seconds, both ways — so no
;; caller spells 86400 and no two spell it differently
(define (days->seconds d) (* d 86400))
(define (seconds->days s) (/ s 86400.0))

(define (instant->unix i)
  "Inverse of unix->instant. The offset moves only at leap boundaries, so one
   corrective pass lands it exactly."
  (let* ((u1 (- i (scale-offset i)))
         (u2 (- i (scale-offset u1))))
    u2))

;; The clock stands on the present, or on one unix second a recorder stood it on
;; (tools/demo-emit.scm), so a recording reads the same on every run.
(define %stood #f)
(define (stand-clock! unix) (set! %stood unix))
(define (clock-stood?) (and %stood #t))
(define (now) (unix->instant (or %stood (current-time))))

(define gps-epoch (unix->instant 315964800))  ; 1980-01-06T00:00:00 UTC
(define (gps-seconds i)
  "True GPS seconds (since the GPS epoch) of instant I, valid under 'gps."
  (- i gps-epoch))

;; ── the civil boundary ───────────────────────────────────────────────────────
(cond-expand
 (guile
  (define (%civil->unix s)
    "Naive ISO date or datetime string S as unix seconds, read as UTC civil, or #f.
     Accepts \"YYYY-MM-DD\" and \"YYYY-MM-DDTHH:MM[:SS]\"."
    (and (string? s) (>= (string-length s) 10)
         (false-if-exception
          (let* ((datetime? (and (> (string-length s) 11)
                                 (>= (string-length s) 16)))
                 (padded (cond ((not datetime?) (string-append (substring s 0 10) "T00:00:00"))
                               ((< (string-length s) 19) (string-append (substring s 0 16) ":00"))
                               (else (substring s 0 19)))))
            (car (mktime (car (strptime "%Y-%m-%dT%H:%M:%S" padded)) "UTC"))))))

  (define* (instant->civil i #:optional (fmt "%Y-%m-%dT%H:%M:%SZ"))
    "Instant → civil UTC label. FMT defaults to full ISO; pass \"%Y-%m-%d\" for a
     date."
    (strftime fmt (gmtime (instant->unix i))))

  (define (instant->weekday i)
    "0=Sunday … 6=Saturday, of the civil UTC day holding instant I."
    (tm:wday (gmtime (instant->unix i)))))
 (else
  (define (%days-from-civil y m d)          ; days since 1970-01-01 (proleptic Gregorian)
    (let* ((y (if (<= m 2) (- y 1) y))
           (era (quotient (if (>= y 0) y (- y 399)) 400))
           (yoe (- y (* era 400)))
           (doy (+ (quotient (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (- d 1)))
           (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
      (+ (* era 146097) doe -719468)))
  (define (%civil-from-days z)              ; → (list year month day)
    (let* ((z (+ z 719468))
           (era (quotient (if (>= z 0) z (- z 146096)) 146097))
           (doe (- z (* era 146097)))
           (yoe (quotient (- (+ (- doe (quotient doe 1460)) (quotient doe 36524)) (quotient doe 146096)) 365))
           (doy (- doe (- (+ (* 365 yoe) (quotient yoe 4)) (quotient yoe 100))))
           (mp (quotient (+ (* 5 doy) 2) 153))
           (d (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
           (m (if (< mp 10) (+ mp 3) (- mp 9))))
      (list (+ yoe (* era 400) (if (<= m 2) 1 0)) m d)))
  (define (%digits s a b)                   ; the integer in S[a,b), or #f
    (let ((n (string->number (substring s a b))))
      (and n (exact-integer? n) (>= n 0) n)))
  (define (%civil->unix s)
    "Naive ISO date or datetime string S as unix seconds, read as UTC civil, or #f.
   Accepts \"YYYY-MM-DD\" and \"YYYY-MM-DDTHH:MM[:SS]\"."
    (and (string? s) (>= (string-length s) 10)
         (let* ((datetime? (and (> (string-length s) 11) (>= (string-length s) 16)))
                (p (cond ((not datetime?) (string-append (substring s 0 10) "T00:00:00"))
                         ((< (string-length s) 19) (string-append (substring s 0 16) ":00"))
                         (else (substring s 0 19))))
                (y (%digits p 0 4)) (mo (%digits p 5 7)) (d (%digits p 8 10))
                (h (%digits p 11 13)) (mi (%digits p 14 16)) (sec (%digits p 17 19)))
           (and y mo d h mi sec
                (char=? (string-ref p 4) #\-) (char=? (string-ref p 7) #\-)
                (char=? (string-ref p 10) #\T) (char=? (string-ref p 13) #\:) (char=? (string-ref p 16) #\:)
                (<= 1 mo 12) (<= 1 d 31) (< h 24) (< mi 60) (<= sec 60)
                (+ (* 86400 (%days-from-civil y mo d)) (* 3600 h) (* 60 mi) sec)))))
  (define (%pad2 n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))
  (define* (instant->civil i #:optional (fmt "%Y-%m-%dT%H:%M:%SZ"))
    "Instant → civil UTC label. FMT defaults to full ISO; pass \"%Y-%m-%d\" for a
   date. Directives: %Y %m %d %H %M %S %%."
    (let* ((u (inexact->exact (floor (instant->unix i))))
           (days (floor-quotient u 86400)) (rem (- u (* days 86400)))
           (ymd (%civil-from-days days)))
      (let loop ((cs (string->list fmt)) (acc '()))
        (cond ((null? cs) (apply string-append (reverse acc)))
              ((and (char=? (car cs) #\%) (pair? (cdr cs)))
               (loop (cddr cs)
                     (cons (case (cadr cs)
                             ((#\Y) (number->string (car ymd)))
                             ((#\m) (%pad2 (cadr ymd)))
                             ((#\d) (%pad2 (caddr ymd)))
                             ((#\H) (%pad2 (quotient rem 3600)))
                             ((#\M) (%pad2 (quotient (remainder rem 3600) 60)))
                             ((#\S) (%pad2 (remainder rem 60)))
                             ((#\%) "%")
                             (else (string #\% (cadr cs))))
                           acc)))
              (else (loop (cdr cs) (cons (string (car cs)) acc)))))))
  (define (instant->weekday i)
    "0=Sunday … 6=Saturday, of the civil UTC day holding instant I."
    (modulo (+ 4 (floor-quotient (inexact->exact (floor (instant->unix i))) 86400)) 7))))

;; ── the zone a stamp states ──────────────────────────────────────────────────
;; A stamp is naive (UTC), or ends in the offset its writer's clock stood at: "Z",
;; "+HH:MM", "-HHMM", "+HH", after the seconds and any fraction of one. The offset
;; moves the civil reading to the one UTC moment the stamp names.
(define (%zone-split s)
  "S as (BODY . OFFSET-SECONDS): BODY is the stamp without its zone, OFFSET the
   seconds the stamp's clock ran ahead of UTC. #f when the tail is no zone."
  (let ((n (string-length s)))
    (let loop ((i 10))
      (if (>= i n)
          (cons s 0)
          (let ((c (string-ref s i)))
            (cond ((char=? c #\Z) (and (= i (- n 1)) (cons (substring s 0 i) 0)))
                  ((or (char=? c #\+) (char=? c #\-))
                   (let* ((raw (substring s (+ i 1) n))
                          (d   (if (and (= (string-length raw) 5) (char=? (string-ref raw 2) #\:))
                                   (string-append (substring raw 0 2) (substring raw 3 5))
                                   raw))
                          (hh  (and (memv (string-length d) '(2 4)) (string->number (substring d 0 2))))
                          (mm  (and hh (if (= (string-length d) 4) (string->number (substring d 2 4)) 0))))
                     (and hh mm (exact-integer? hh) (exact-integer? mm) (<= hh 14) (< mm 60)
                          (cons (substring s 0 i)
                                (* (if (char=? c #\-) -1 1) (+ (* 3600 hh) (* 60 mm)))))))
                  (else (loop (+ i 1)))))))))

(define (civil->instant s)
  "ISO date or datetime string → instant. A stamp with no zone is UTC civil; one
   that states its offset (\"…Z\", \"…+02:00\") is that moment in UTC. #f when
   unparseable. Accepts \"YYYY-MM-DD\" and \"YYYY-MM-DDTHH:MM[:SS[.fff]]\"."
  (let ((z (and (string? s) (>= (string-length s) 10) (%zone-split s))))
    (and z
         (let ((u (%civil->unix (let ((b (car z))) (if (> (string-length b) 19) (substring b 0 19) b)))))
           (and u (not (and (> (string-length (car z)) 19)
                            (not (char=? (string-ref (car z) 19) #\.))))
                (unix->instant (- u (cdr z))))))))

(define (civil->epoch s)
  "A civil UTC ISO 8601 string (a datetime to the second, or a bare date: its
   midnight) as unix seconds, or #f when it is no such thing: epoch->civil's
   inverse, on the same scale as (instant->unix (now))."
  (let ((i (civil->instant s)))
    (and i (instant->unix i))))

(define (iso-now)
  "The current instant as a civil UTC ISO 8601 string."
  (instant->civil (now)))

(define (month-now)
  "The month the clock stands in, 1 to 12, of the civil UTC day."
  (string->number (substring (iso-now) 5 7)))

(define (epoch->civil u)
  "Unix seconds, whole or fractional, as a civil UTC ISO 8601 string."
  (instant->civil (unix->instant (inexact->exact (floor u)))))

;; The one temporal law for a window boundary: a timed boundary ("…T17:00")
;; closes at its minute, a bare date at the END of its day. Plan-store records
;; and credential validity windows both read it here.
(define (window-close-epoch e)
  "When a window boundary E closes, as unix seconds — a number verbatim, a
   numeric string verbatim, an ISO datetime at its minute, an ISO date at the
   end of its day; #f when unreadable (an unreadable window never closes)."
  (cond ((number? e) e)
        ((not (string? e)) #f)
        ((string->number e) => (lambda (n) n))
        (else (let ((i (civil->instant e)))
                (and i (let ((u (instant->unix i)))
                         (if (> (string-length e) 11) u (+ u 86400))))))))

;; A naive ISO string is a civil UTC label; the NUMBER it becomes is an
;; instant on the one clock — GPS scale by default, so interval arithmetic is
;; over a continuous count with no leap seconds and no DST, and stepping a span
;; by 86400 s stays on midnight. Reads the date; a time-of-day suffix is the
;; caller's to add.
(define (iso->epoch s)
  (or (civil->instant (substring s 0 (min 10 (string-length s))))
      (error "iso->epoch: unparseable date" s)))
