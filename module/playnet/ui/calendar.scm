;;; calendar.scm — Notion-style week calendar in SXML
;;;
;;; All functions are pure: data in, SXML out. No DOM mutation.
;;; Hoot/WASM compatible.

(define-module (playnet ui calendar)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils alist)
  #:export (;; Date utilities
            epoch-ms->day-of-week
            epoch-ms->date-parts
            week-start-ms
            day-start-ms
            add-months-ms
            date-string
            date-parts->date-string
            day-offset-date-parts
            fmt-time
            day-names
            month-names
            epoch-ms->hour-min

            ;; View modes
            view-mode-range
            step-anchor
            format-range-label

            ;; Layout
            compute-event-columns
            person-color

            ;; Rendering
            render-header
            render-view-picker
            render-day-headers
            render-time-column
            render-day-column
            render-event-block
            render-availability-overlay
            render-person-legend
            render-event-editor
            render-availability-editor
            render-event-detail-panel
            render-current-time-line
            render-capacity-bar
            render-allday-strip
            render-intents-sidebar
            render-plan-bar
            render-month-view
            render-schedule-view
            event->ical
            ical-line->pair
            split-on-newlines
            parse-ical-events
            availability->ical
            parse-ical-availability
            avail-slot->ical

            ;; Composed page
            calendar-page))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  CONSTANTS
;;; ═══════════════════════════════════════════════════════════════════════════════

(define *hour-height* 60)   ;; pixels per hour
(define *day-ms* 86400000)  ;; ms in a day
(define *week-ms* 604800000)

(define day-names '#("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))

(define month-names
  '#("January" "February" "March" "April" "May" "June"
     "July" "August" "September" "October" "November" "December"))

;;; Playnet palette — kept in sync with browser/assets/css/calendar.css.
;;; Using named accessors instead of inline hex strings makes intent
;;; obvious and the next palette change a single edit.
(define *palette-mint*    "#a8e6cf")  ;; matched / yours / fulfilled
(define *palette-amber*   "#d69e2e")  ;; unmatched / volunteer needed
(define *palette-purple*  "#9f7aea")  ;; VF accent / process context
(define *palette-grey*    "#8b7b96")  ;; muted / hint / neutral
(define *palette-blue*    "#63b3ed")  ;; default event
(define *palette-red*     "#fc8181")  ;; danger / delete

(define *person-colors*
  (vector *palette-blue* "#f6ad55" "#b794f4" "#4fd1c5" "#f687b3"
          "#7ee8a2" *palette-red* "#d6bcfa" "#90cdf4" "#fbd38d"))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  DATE UTILITIES (hand-rolled, no SRFI-19 in Hoot)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (epoch-ms->day-of-week ms)
  "Day of week from epoch ms. 0=Mon, 6=Sun.
   Unix epoch (Jan 1 1970) was a Thursday = day 3."
  (modulo (+ (quotient (inexact->exact (floor ms)) *day-ms*) 3) 7))

(define (leap-year? y)
  (and (zero? (modulo y 4))
       (or (not (zero? (modulo y 100)))
           (zero? (modulo y 400)))))

(define (days-in-month y m)
  (case m
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    ((2) (if (leap-year? y) 29 28))
    (else 30)))

(define (epoch-ms->date-parts ms)
  "Returns (year month day) from epoch ms (UTC)."
  (let* ((total-days (quotient (inexact->exact (floor ms)) *day-ms*))
         ;; Start from 1970-01-01
         (days (if (< total-days 0) 0 total-days)))
    (let y-loop ((y 1970) (rem days))
      (let ((dy (if (leap-year? y) 366 365)))
        (if (< rem dy)
            (let m-loop ((m 1) (rem rem))
              (let ((dm (days-in-month y m)))
                (if (< rem dm)
                    (list y m (+ rem 1))
                    (m-loop (+ m 1) (- rem dm)))))
            (y-loop (+ y 1) (- rem dy)))))))

(define (week-start-ms ms)
  "Rewind to Monday 00:00 UTC of the week containing MS."
  (let ((dow (epoch-ms->day-of-week ms)))
    (inexact->exact (* (- (quotient (inexact->exact (floor ms)) *day-ms*) dow)
                       *day-ms*))))

(define (pad2 n)
  "Zero-pad integer to 2 digits."
  (if (< n 10)
      (string-append "0" (number->string n))
      (number->string n)))

(define (date-string y m d)
  "Format as YYYY-MM-DD."
  (string-append (number->string y) "-" (pad2 m) "-" (pad2 d)))

(define (date-parts->date-string parts)
  (date-string (car parts) (cadr parts) (caddr parts)))

(define (fmt-time hour min)
  "Format as '9:00 AM'."
  (let* ((ampm (if (< hour 12) "AM" "PM"))
         (h12 (cond ((= hour 0) 12) ((> hour 12) (- hour 12)) (else hour))))
    (string-append (number->string h12) ":" (pad2 min) " " ampm)))

(define (day-offset-date-parts week-start-ms offset)
  "Date parts for week-start + offset days."
  (epoch-ms->date-parts (+ week-start-ms (* offset *day-ms*))))

(define (day-start-ms ms)
  "Floor MS to the start of its UTC day."
  (let ((d (quotient (inexact->exact (floor ms)) *day-ms*)))
    (* d *day-ms*)))

(define (date-parts->epoch-ms parts)
  "Inverse of epoch-ms->date-parts (UTC, day-aligned)."
  (let ((y (car parts)) (m (cadr parts)) (d (caddr parts)))
    (let y-loop ((cy 1970) (acc-days 0))
      (if (= cy y)
          (let m-loop ((cm 1) (acc acc-days))
            (if (= cm m)
                (* (+ acc (- d 1)) *day-ms*)
                (m-loop (+ cm 1) (+ acc (days-in-month y cm)))))
          (y-loop (+ cy 1) (+ acc-days (if (leap-year? cy) 366 365)))))))

(define (add-months-ms ms n)
  "Advance MS by N calendar months (clamping day to month length)."
  (let* ((parts (epoch-ms->date-parts ms))
         (y (car parts)) (m (cadr parts)) (d (caddr parts))
         (total (+ (* y 12) (- m 1) n))
         (ny (quotient total 12))
         (nm (+ (modulo total 12) 1))
         (nd (min d (days-in-month ny nm))))
    (date-parts->epoch-ms (list ny nm nd))))

;;; ── View modes ────────────────────────────────────────────────────────────

(define (view-mode-range view-mode anchor-ms)
  "Return (range-start-ms . day-count) for the given view mode and anchor."
  (case view-mode
    ((day)      (cons (day-start-ms anchor-ms) 1))
    ((3day)     (cons (day-start-ms anchor-ms) 3))
    ((week)     (cons (week-start-ms anchor-ms) 7))
    ((schedule) (cons (day-start-ms anchor-ms) 14))
    (else       (cons (week-start-ms anchor-ms) 7))))

(define (step-anchor view-mode anchor-ms direction)
  "Advance ANCHOR-MS by one unit (in DIRECTION = -1 or +1) appropriate
   for VIEW-MODE."
  (case view-mode
    ((day)      (+ anchor-ms (* direction *day-ms*)))
    ((3day)     (+ anchor-ms (* direction 3 *day-ms*)))
    ((month)    (add-months-ms anchor-ms direction))
    ((schedule) (+ anchor-ms (* direction 7 *day-ms*)))
    (else       (+ anchor-ms (* direction *week-ms*)))))

(define (format-range-label view-mode anchor-ms)
  "Header label suited to the view mode (Google-Calendar style)."
  (define (month-of p) (vector-ref month-names (- (cadr p) 1)))
  (define (year y)    (number->string y))
  (define (long p)    ;; \"May 18, 2026\"
    (string-append (month-of p) " " (number->string (caddr p))
                   ", " (year (car p))))
  (define (range a b) ;; \"May 17–23, 2026\" / cross-month / cross-year
    (cond ((not (= (car a) (car b)))
           (string-append (long a) " – " (long b)))
          ((not (= (cadr a) (cadr b)))
           (string-append (month-of a) " " (number->string (caddr a))
                          " – " (month-of b) " " (number->string (caddr b))
                          ", " (year (car a))))
          (else
           (string-append (month-of a) " " (number->string (caddr a))
                          "–" (number->string (caddr b))
                          ", " (year (car a))))))
  (let* ((rng (view-mode-range view-mode anchor-ms))
         (start (car rng))
         (count (cdr rng))
         (a (epoch-ms->date-parts start)))
    (case view-mode
      ((day)            (long a))
      ((month schedule) (string-append (month-of a) " " (year (car a))))
      (else
       (range a (epoch-ms->date-parts (+ start (* (- count 1) *day-ms*))))))))

(define (epoch-ms->hour-min ms)
  "Returns (hour minute) from epoch ms (UTC, time-of-day only)."
  (let* ((total-secs (quotient (modulo (inexact->exact (floor ms)) *day-ms*) 1000))
         (hour (quotient total-secs 3600))
         (min (quotient (modulo total-secs 3600) 60)))
    (list hour min)))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  PERSON COLORS
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (person-color id people)
  "Get color for person ID from people list, or deterministic fallback."
  (let ((p (find (lambda (pe) (equal? (alist-ref pe 'id) id)) people)))
    (if p
        (alist-ref p 'color "#63b3ed")
        ;; Deterministic color from string hash
        (let loop ((i 0) (h 0))
          (if (>= i (string-length id))
              (vector-ref *person-colors* (modulo h (vector-length *person-colors*)))
              (loop (+ i 1)
                    (modulo (+ (* h 31) (char->integer (string-ref id i))) 65536)))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  OVERLAP / COLUMN COMPUTATION
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (events-overlap? a b)
  "Do two events overlap in time?"
  (let ((a-start (+ (* (alist-ref a 'sh 0) 60) (alist-ref a 'sm 0)))
        (a-end   (+ (* (alist-ref a 'eh 0) 60)   (alist-ref a 'em 0)))
        (b-start (+ (* (alist-ref b 'sh 0) 60) (alist-ref b 'sm 0)))
        (b-end   (+ (* (alist-ref b 'eh 0) 60)   (alist-ref b 'em 0))))
    (and (< a-start b-end) (< b-start a-end))))

(define (event-start-minutes evt)
  (+ (* (alist-ref evt 'sh 0) 60) (alist-ref evt 'sm 0)))

(define (compute-event-columns day-events)
  "Assign columns to overlapping events. Returns list of (event column total-cols)."
  (if (null? day-events) '()
      (let* ((sorted (sort day-events
                           (lambda (a b) (< (event-start-minutes a)
                                            (event-start-minutes b)))))
             ;; Greedy column assignment
             (assignments
              (let loop ((evts sorted) (placed '()))
                (if (null? evts) (reverse placed)
                    (let* ((evt (car evts))
                           ;; Find overlapping already-placed events
                           (overlapping (filter (lambda (p)
                                                 (events-overlap? evt (car p)))
                                               placed))
                           ;; Used columns
                           (used-cols (map cadr overlapping))
                           ;; Find first free column
                           (col (let find-col ((c 0))
                                  (if (member c used-cols) (find-col (+ c 1)) c))))
                      (loop (cdr evts) (cons (list evt col) placed)))))))
        ;; Now compute total-cols for each overlap group
        (map (lambda (a)
               (let* ((evt (car a))
                      (col (cadr a))
                      ;; All events overlapping with this one
                      (group (filter (lambda (b) (events-overlap? evt (car b)))
                                    assignments))
                      (max-col (fold (lambda (g acc) (max (cadr g) acc)) 0 group))
                      (total (+ max-col 1)))
                 (list evt col total)))
             assignments))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  POSITION HELPERS
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (time->px hour min)
  "Convert hour:min to pixel offset from top of day column."
  (inexact->exact (round (+ (* hour *hour-height*) (* (/ min 60) *hour-height*)))))

(define (event-top evt)
  (time->px (alist-ref evt 'sh 0) (alist-ref evt 'sm 0)))

(define (event-height evt)
  (max 20 (- (time->px (alist-ref evt 'eh 0) (alist-ref evt 'em 0))
             (event-top evt))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: EVENT BLOCK
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (status-dot status)
  "Status indicator: open/committed/fulfilled."
  (cond ((eq? status 'fulfilled) "\u25cf")   ;; ●
        ((eq? status 'committed) "\u25d0")   ;; ◐
        (else "\u25cb")))                     ;; ○

(define (render-event-block evt col total-cols on-click on-cycle stop-prop)
  "Render a single event as an absolute-positioned colored block.
   on-click: opens detail panel. on-cycle: cycles VF status (on the dot)."
  (let* ((pct-left  (inexact->exact (round (* (/ col total-cols) 100))))
         (pct-width (inexact->exact (round (/ 100 total-cols))))
         (top-px    (event-top evt))
         (h-px      (event-height evt))
         (color     (alist-ref evt 'color "#63b3ed"))
         (title     (alist-ref evt 'title ""))
         (loc       (alist-ref evt 'location ""))
         (person    (alist-ref evt 'person ""))
         (status    (alist-ref evt 'status 'open))
         (source    (alist-ref evt 'source 'event))
         (is-vf     (or (eq? source 'intent) (eq? source 'commitment)))
         (sh        (alist-ref evt 'sh 0))
         (sm        (alist-ref evt 'sm 0))
         (eh        (alist-ref evt 'eh 0))
         (em        (alist-ref evt 'em 0))
         ;; Status-driven visual style
         (status-class
          (cond ((and is-vf (eq? status 'open))      " cal-event-intent")
                ((and is-vf (eq? status 'committed)) " cal-event-committed")
                ((and is-vf (eq? status 'fulfilled)) " cal-event-fulfilled")
                (else "")))
         (bg-color
          (cond ((and is-vf (eq? status 'open))      (hex->rgba color "0.15"))
                ((and is-vf (eq? status 'committed)) (hex->rgba color "0.55"))
                (else color)))
         (border-style
          (if (and is-vf (eq? status 'open)) "dashed" "solid")))
    `(div (@ (class ,(string-append "cal-event" status-class
                                    (if (< h-px 35) " cal-event-compact" "")))
             (style ,(string-append
                      "top:" (number->string top-px) "px;"
                      "height:" (number->string h-px) "px;"
                      "left:" (number->string pct-left) "%;"
                      "width:calc(" (number->string pct-width) "% - 2px);"
                      "background:" bg-color ";"
                      "border-left:3px " border-style " " color ";"))
             (click ,on-click))
          (div (@ (class "cal-event-title"))
               ,@(if (and is-vf on-cycle)
                     (list `(span (@ (class "cal-status-dot cal-status-btn")
                                     (click ,(lambda (e) (stop-prop e) (on-cycle evt))))
                                  ,(status-dot status)))
                     (list `(span (@ (class "cal-status-dot")) ,(status-dot status))))
               ,title
               ,@(if is-vf
                     (list `(span (@ (class "cal-vf-badge")) "VF"))
                     '()))
          (div (@ (class "cal-event-time"))
               ,(string-append (fmt-time sh sm) " - " (fmt-time eh em)))
          ,@(if (string=? loc "")
                '()
                (list `(div (@ (class "cal-event-loc")) ,loc)))
          ,@(if (string=? person "")
                '()
                (list `(div (@ (class "cal-event-person")) ,person))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: AVAILABILITY OVERLAY
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (hex-digit ch)
  (let ((c (char->integer ch)))
    (cond ((<= 48 c 57)  (- c 48))        ;; 0-9
          ((<= 65 c 70)  (- c 55))        ;; A-F
          ((<= 97 c 102) (- c 87))        ;; a-f
          (else 0))))

(define (hex2->int s pos)
  (+ (* (hex-digit (string-ref s pos)) 16)
     (hex-digit (string-ref s (+ pos 1)))))

(define (hex->rgba hex alpha)
  "Convert hex color like '#63b3ed' to rgba string."
  (if (< (string-length hex) 7) (string-append "rgba(100,100,100," alpha ")")
      (string-append "rgba("
        (number->string (hex2->int hex 1)) ","
        (number->string (hex2->int hex 3)) ","
        (number->string (hex2->int hex 5)) ","
        alpha ")")))

(define (fmt-hhmm hour min)
  (let* ((h12 (let ((m (modulo hour 12))) (if (= m 0) 12 m)))
         (ap  (if (< hour 12) "a" "p")))
    (string-append (number->string h12)
                   (if (= min 0) "" (string-append ":" (if (< min 10) "0" "") (number->string min)))
                   ap)))

(define (render-availability-overlay avail color edit-mode?
                                     on-resize-start on-move-start
                                     on-spread-start on-delete stop-prop)
  "Per-person colored dashed overlay for an availability slot.
   In EDIT-MODE? the overlay sprouts vertical resize grips (top/bottom),
   horizontal spread grips (left/right edges), a body drag region for moving,
   and a delete X.
   ON-RESIZE-START is (lambda (mouse-evt edge)) where edge is 'top|'bot.
   ON-SPREAD-START is (lambda (mouse-evt edge)) where edge is 'left|'right.
   ON-DELETE is (lambda (mouse-evt))."
  (let* ((sh (alist-ref avail 'sh 9))
         (sm (alist-ref avail 'sm 0))
         (eh (alist-ref avail 'eh 17))
         (em (alist-ref avail 'em 0))
         (top-px (time->px sh sm))
         (bot-px (time->px eh em))
         (h-px   (- bot-px top-px))
         (c (or color "#48bb78")))
    `(div (@ (class ,(string-append "cal-avail"
                                    (if edit-mode? " cal-avail-editing" "")))
             (style ,(string-append
                      "top:" (number->string top-px) "px;"
                      "height:" (number->string h-px) "px;"
                      "background:" (hex->rgba c "0.08") ";"
                      "border-color:" (hex->rgba c "0.35") ";"))
             ,@(if edit-mode?
                   `((mousedown ,(lambda (e)
                                   (stop-prop e)
                                   (on-move-start e))))
                   '()))
          ,@(if edit-mode?
                `((div (@ (class "cal-avail-label"))
                       ,(string-append (fmt-hhmm sh sm) "–" (fmt-hhmm eh em)))
                  (div (@ (class "cal-avail-handle cal-avail-handle-top")
                          (mousedown ,(lambda (e)
                                        (stop-prop e)
                                        (on-resize-start e 'top)))))
                  (div (@ (class "cal-avail-handle cal-avail-handle-bot")
                          (mousedown ,(lambda (e)
                                        (stop-prop e)
                                        (on-resize-start e 'bot)))))
                  (div (@ (class "cal-avail-edge cal-avail-edge-left")
                          (mousedown ,(lambda (e)
                                        (stop-prop e)
                                        (on-spread-start e 'left)))))
                  (div (@ (class "cal-avail-edge cal-avail-edge-right")
                          (mousedown ,(lambda (e)
                                        (stop-prop e)
                                        (on-spread-start e 'right)))))
                  (div (@ (class "cal-avail-delete")
                          (mousedown ,stop-prop)
                          (click ,(lambda (e)
                                    (stop-prop e)
                                    (on-delete e))))
                       "×"))
                '()))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: WEEK HEADER
;;; ═══════════════════════════════════════════════════════════════════════════════

(define *view-modes*
  '((day      . "Day")
    (3day     . "3 days")
    (week     . "Week")
    (month    . "Month")
    (schedule . "Schedule")))

(define (render-view-picker view-mode on-set-view-mode)
  "Compact, mobile-friendly view-mode picker — chips that toggle the view."
  `(div (@ (class "cal-view-picker"))
        ,@(map (lambda (entry)
                 (let ((sym (car entry)) (label (cdr entry)))
                   `(span (@ (class ,(string-append
                                      "cal-view-chip"
                                      (if (eq? sym view-mode)
                                          " cal-view-chip-active" "")))
                             (click ,(lambda (e) (on-set-view-mode sym))))
                          ,label)))
               *view-modes*)))

(define (render-header view-mode anchor-ms
                       on-prev on-next on-today
                       on-set-view-mode on-export)
  "Header bar: prev / today / next, range label, view picker, export."
  `(div (@ (class "cal-header"))
        (div (@ (class "cal-nav"))
             (span (@ (class "cal-nav-btn cal-today-btn") (click ,on-today))
                   "Today")
             (span (@ (class "cal-nav-btn cal-nav-arrow") (click ,on-prev))
                   "\u25c0")
             (span (@ (class "cal-nav-btn cal-nav-arrow") (click ,on-next))
                   "\u25b6")
             (span (@ (class "cal-range-label"))
                   ,(format-range-label view-mode anchor-ms))
             (span (@ (class "cal-header-spacer")) "")
             ,(render-view-picker view-mode on-set-view-mode)
             ,@(if on-export
                   (list `(span (@ (class "cal-nav-btn cal-export-btn")
                                   (click ,on-export))
                                "\u21e9 .ics"))
                   '()))))

(define (iota-list n)
  (let build ((i 0) (acc '()))
    (if (= i n) (reverse acc) (build (+ i 1) (cons i acc)))))

(define (take-up-to lst n)
  "First N elements of LST, or all of LST if shorter."
  (cond ((or (null? lst) (= n 0)) '())
        (else (cons (car lst) (take-up-to (cdr lst) (- n 1))))))

(define (group-by-key lst key-of)
  "Group adjacent items in LST sharing the same (key-of x). Returns a
   list of (key . items) preserving order. LST should already be sorted
   by key."
  (let loop ((xs lst) (cur-key #f) (cur-group '()) (acc '()))
    (define (flush)
      (if (null? cur-group) acc
          (cons (cons cur-key (reverse cur-group)) acc)))
    (cond ((null? xs) (reverse (flush)))
          ((or (null? cur-group) (equal? cur-key (key-of (car xs))))
           (loop (cdr xs) (key-of (car xs))
                 (cons (car xs) cur-group) acc))
          (else
           (loop xs #f '() (flush))))))

(define (render-day-headers range-start day-count today-date-str)
  "Day column headers — rendered inside the grid area for alignment.
   Spans DAY-COUNT days starting at RANGE-START."
  `(div (@ (class "cal-day-headers"))
        (div (@ (class "cal-time-spacer")) "")
        ,@(map (lambda (offset)
                 (let* ((dp (day-offset-date-parts range-start offset))
                        (d  (caddr dp))
                        ;; Day-of-week for this absolute date (0=Mon..6=Sun)
                        (dow (epoch-ms->day-of-week
                              (+ range-start (* offset *day-ms*))))
                        (dn (vector-ref day-names dow))
                        (ds (date-parts->date-string dp))
                        (is-today (and today-date-str
                                       (string=? ds today-date-str))))
                   `(div (@ (class ,(string-append "cal-day-header"
                                                   (if is-today " cal-day-header-today" ""))))
                         (span (@ (class "cal-day-name")) ,dn)
                         (span (@ (class ,(string-append "cal-day-num"
                                                          (if is-today " cal-day-num-today" ""))))
                               ,(number->string d)))))
               (iota-list day-count))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: TIME COLUMN (left gutter)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-time-column)
  "24 hour labels."
  `(div (@ (class "cal-time-col"))
        ,@(map (lambda (h)
                 `(div (@ (class "cal-hour-label"))
                       ,(if (= h 0) ""
                            (fmt-time h 0))))
               (let build ((i 0))
                 (if (= i 24) '() (cons i (build (+ i 1))))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: DAY COLUMN
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-day-column date-str day-events availability people dow
                          on-slot-click on-event-click on-cycle-status
                          time-line-sxml is-today stop-prop
                          edit-mode? on-create-start on-resize-start on-move-start
                          on-spread-start on-delete on-day-hover)
  "One day column: hour cells (click targets) + availability + events + time line.
   When EDIT-MODE? is true, mousedown on a cell starts a create-drag for a new
   availability slot on this day-of-week; the slot body can be dragged to move,
   and each overlay shows resize/delete grips."
  (let ((positioned (compute-event-columns day-events)))
    `(div (@ (class ,(string-append "cal-day-col"
                                    (if is-today " cal-day-today" "")
                                    (if edit-mode? " cal-day-col-edit" "")))
             ,@(if edit-mode?
                   `((mouseenter ,(lambda (e) (on-day-hover e dow))))
                   '()))
          ;; Fixed 24 hour cells as click targets
          ,@(map (lambda (h)
                   `(div (@ (class "cal-hour-cell")
                            ,@(if edit-mode?
                                  `((mousedown ,(lambda (e)
                                                  (stop-prop e)
                                                  (on-create-start e dow h))))
                                  `((click ,(lambda (e) (on-slot-click date-str h)))))
                            )
                         ""))
                 (let build ((i 0))
                   (if (= i 24) '() (cons i (build (+ i 1))))))
          ;; Availability overlays (absolute positioned, per-person colored)
          ,@(map (lambda (a)
                   (let ((sid (alist-ref a 'id #f)))
                     (render-availability-overlay
                      a (person-color (alist-ref a 'person "") people)
                      edit-mode?
                      (lambda (e edge) (on-resize-start e sid edge))
                      (lambda (e) (on-move-start e sid))
                      (lambda (e edge) (on-spread-start e sid edge))
                      (lambda (e) (on-delete e sid))
                      stop-prop)))
                 availability)
          ;; (Mutual-free overlay disabled: its math conflated "me" slots
          ;; with the visible-person list, and it defaulted to 9–5 on empty
          ;; days. Re-enable once per-person availability is wired through.)
          ;; Current time line (if this is today)
          ,@(if time-line-sxml (list time-line-sxml) '())
          ;; Events (absolute positioned)
          ,@(map (lambda (triple)
                   (let ((evt (car triple))
                         (col (cadr triple))
                         (total (caddr triple)))
                     (render-event-block evt col total
                                        (lambda (e) (on-event-click evt))
                                        on-cycle-status stop-prop)))
                 positioned))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: PERSON LEGEND
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-person-legend people on-toggle)
  "Colored dots with names, click to toggle visibility."
  `(div (@ (class "cal-legend"))
        ,@(map (lambda (p)
                 (let ((id    (alist-ref p 'id ""))
                       (name  (alist-ref p 'name ""))
                       (color (alist-ref p 'color "#63b3ed"))
                       (vis   (alist-ref p 'visible #t)))
                   `(div (@ (class ,(string-append "cal-legend-item"
                                                   (if vis "" " cal-legend-hidden")))
                            (click ,(lambda (e) (on-toggle id))))
                         (span (@ (class "cal-legend-dot")
                                  (style ,(string-append "background-color:" color ";")))
                               "")
                         (span (@ (class "cal-legend-name")) ,name))))
               people)))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: EVENT EDITOR MODAL
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-event-editor evt on-save on-delete on-cancel stop-prop)
  "Modal overlay for creating/editing an event."
  (let ((title   (alist-ref evt 'title ""))
        (sh      (alist-ref evt 'sh 9))
        (sm      (alist-ref evt 'sm 0))
        (eh      (alist-ref evt 'eh 10))
        (em      (alist-ref evt 'em 0))
        (loc     (alist-ref evt 'location ""))
        (person  (alist-ref evt 'person ""))
        (desc    (alist-ref evt 'description "")))
    `(div (@ (class "cal-modal-overlay") (click ,on-cancel))
          (div (@ (class "cal-modal") (click ,stop-prop))
               (div (@ (class "cal-modal-title")) "Event")
               (div (@ (class "cal-field"))
                    (label "Title")
                    (input (@ (id "cal-evt-title") (type "text") (value ,title)
                              (placeholder "Event title"))))
               (div (@ (class "cal-field"))
                    (label "Person")
                    (input (@ (id "cal-evt-person") (type "text") (value ,person)
                              (placeholder "Person name"))))
               (div (@ (class "cal-field"))
                    (label "Location")
                    (input (@ (id "cal-evt-location") (type "text") (value ,loc)
                              (placeholder "Location"))))
               (div (@ (class "cal-field"))
                    (label "Description")
                    (input (@ (id "cal-evt-desc") (type "text") (value ,desc)
                              (placeholder "Notes..."))))
               (div (@ (class "cal-field cal-time-fields"))
                    (label "Start")
                    (select (@ (id "cal-evt-sh"))
                            ,@(map (lambda (h)
                                     `(option (@ (value ,(number->string h))
                                                 ,@(if (= h sh) '((selected "selected")) '()))
                                              ,(fmt-time h 0)))
                                   (let build ((i 0))
                                     (if (= i 24) '() (cons i (build (+ i 1)))))))
                    (select (@ (id "cal-evt-sm"))
                            ,@(map (lambda (m)
                                     `(option (@ (value ,(number->string m))
                                                 ,@(if (= m sm) '((selected "selected")) '()))
                                              ,(pad2 m)))
                                   '(0 15 30 45))))
               (div (@ (class "cal-field cal-time-fields"))
                    (label "End")
                    (select (@ (id "cal-evt-eh"))
                            ,@(map (lambda (h)
                                     `(option (@ (value ,(number->string h))
                                                 ,@(if (= h eh) '((selected "selected")) '()))
                                              ,(fmt-time h 0)))
                                   (let build ((i 0))
                                     (if (= i 24) '() (cons i (build (+ i 1)))))))
                    (select (@ (id "cal-evt-em"))
                            ,@(map (lambda (m)
                                     `(option (@ (value ,(number->string m))
                                                 ,@(if (= m em) '((selected "selected")) '()))
                                              ,(pad2 m)))
                                   '(0 15 30 45))))
               (div (@ (class "cal-modal-actions"))
                    (span (@ (class "cal-btn cal-btn-primary") (click ,on-save)) "Save")
                    ,@(if (string=? (alist-ref evt 'id "") "")
                          '()
                          (list `(span (@ (class "cal-btn cal-btn-danger") (click ,on-delete))
                                       "Delete")))
                    (span (@ (class "cal-btn") (click ,on-cancel)) "Cancel"))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: AVAILABILITY EDITOR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-availability-editor availability on-save on-cancel)
  "Panel for editing weekly availability slots with functional dropdowns."
  `(div (@ (class "cal-avail-editor"))
        (div (@ (class "cal-modal-title")) "Availability")
        ,@(map (lambda (day-idx)
                 (let* ((dn (vector-ref day-names day-idx))
                        (slot (find (lambda (a) (= (alist-ref a 'day 0) day-idx))
                                    availability))
                        (sh (if slot (alist-ref slot 'sh 9) 9))
                        (eh (if slot (alist-ref slot 'eh 17) 17)))
                   `(div (@ (class "cal-avail-row"))
                         (span (@ (class "cal-avail-day")) ,dn)
                         (select (@ (id ,(string-append "avail-sh-" (number->string day-idx))))
                                 ,@(map (lambda (h)
                                          `(option (@ (value ,(number->string h))
                                                      ,@(if (= h sh) '((selected "selected")) '()))
                                                   ,(fmt-time h 0)))
                                        (let build ((i 5)) (if (= i 23) '() (cons i (build (+ i 1)))))))
                         (span (@ (class "cal-avail-sep")) "\u2192")
                         (select (@ (id ,(string-append "avail-eh-" (number->string day-idx))))
                                 ,@(map (lambda (h)
                                          `(option (@ (value ,(number->string h))
                                                      ,@(if (= h eh) '((selected "selected")) '()))
                                                   ,(fmt-time h 0)))
                                        (let build ((i 5)) (if (= i 23) '() (cons i (build (+ i 1))))))))))
               (list 0 1 2 3 4 5 6))
        (div (@ (class "cal-modal-actions"))
             (span (@ (class "cal-btn cal-btn-primary") (click ,on-save)) "Save")
             (span (@ (class "cal-btn") (click ,on-cancel)) "Cancel"))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: ALL-DAY EVENTS STRIP
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-allday-strip range-dates allday-events on-event-click)
  "Horizontal strip above grid for all-day / untimed events.
   Spans one cell per entry in RANGE-DATES (list of YYYY-MM-DD)."
  (if (null? allday-events) `(div)
      `(div (@ (class "cal-allday"))
            (div (@ (class "cal-allday-label")) "all day")
            ,@(map (lambda (ds)
                     (let ((day-evts (filter (lambda (e)
                                               (equal? (alist-ref e 'date "") ds))
                                             allday-events)))
                       `(div (@ (class "cal-allday-cell"))
                             ,@(map (lambda (evt)
                                      `(div (@ (class "cal-allday-event")
                                               (style ,(string-append
                                                        "background-color:"
                                                        (alist-ref evt 'color "#63b3ed") ";"))
                                               (click ,(lambda (e) (on-event-click evt))))
                                            ,(alist-ref evt 'title "")))
                                    day-evts))))
                   range-dates))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: CAPACITY BAR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-capacity-bar events availability people on-toggle-avail edit-mode?)
  "Toolbar trailer: just the availability-edit toggle.
   (The committed/available capacity readout was removed — it only reflected
   per-person availability that isn't yet wired through the visible legend.)"
  (let ()
    `(div (@ (class "cal-capacity"))
          (span (@ (class ,(string-append "cal-btn cal-capacity-btn"
                                          (if edit-mode? " cal-btn-primary" "")))
                   (click ,on-toggle-avail))
                ,(if edit-mode? "done" "edit availability")))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: SCOPE / PLAN / ACTING-AS BAR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-plan-bar plans current-plan on-select-plan)
  "Plan strip for the view header \u2014 a horizontally-scrollable row of
   chips, one per plan in the current scope, with an 'All plans' chip
   first. Selection is a click on a chip.

   Scope and acting-as live at the session level (rendered in the
   action-bar by repl.scm); plan is finer-grained \u2014 a query refinement
   within the current scope \u2014 so it stays in-view.

   PLANS is a list of alists with 'id and 'name; CURRENT-PLAN is the
   selected id or #f. ON-SELECT-PLAN is called with the plan-id string
   (or \"\" for All plans)."
  (define (chip id label active?)
    `(div (@ (class ,(string-append "plan-chip"
                                    (if active? " plan-chip-active" "")))
             (click ,(lambda (e) (on-select-plan id))))
          ,label))
  `(div (@ (class "plan-bar"))
        (span (@ (class "plan-bar-label")) "Plan")
        (div (@ (class "plan-strip"))
             ,(chip "" "All plans" (not current-plan))
             ,@(map (lambda (plan)
                      (let ((id (alist-ref plan 'id ""))
                            (name (alist-ref plan 'name "")))
                        (chip id (if (string=? name "") id name)
                              (equal? id current-plan))))
                    plans))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: UNSCHEDULED INTENTS SIDEBAR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (willing-chip wkr people)
  "One willing-worker dot+name chip — a face in the candidate 'race'."
  (let* ((wid    (alist-ref wkr 'id ""))
         (wname  (alist-ref wkr 'name wid))
         (status (alist-ref wkr 'willing-status 'invited))   ; willing | invited | declined
         (dot    (cond ((eq? status 'willing)  "●")     ; ● opted in
                       ((eq? status 'declined) "◌")     ; ◌ withdrew
                       (else "○"))))                     ; ○ invited, not yet answered
    `(span (@ (class ,(string-append "cal-willing-chip cal-willing-" (symbol->string status))))
           (span (@ (class "cal-legend-dot cal-willing-dot")
                    (style ,(string-append "background-color:" (person-color wid people) ";")))
                 ,dot)
           (span (@ (class "cal-willing-name")) ,wname))))

(define* (render-intent-card intent
                             #:key on-select-intent selected-intent-id
                                   (people '()) on-accept on-decline
                                   (stop-prop (lambda (e) #f))
                                   (show-accept? #f)
                                   (show-willing? #f) (on-express-willingness #f)
                                   (my-willing-status #f))
  "Render one intent card. SHOW-ACCEPT? enables accept/decline buttons.
   SHOW-WILLING? enables the offer-side willingness toggle + the candidate
   'race' (the workers who've marked themselves willing for this need).
   MY-WILLING-STATUS is the acting-as user's status here: 'willing | #f."
  (let* ((id   (alist-ref intent 'id ""))
         (proc (alist-ref intent 'proc-name ""))
         (spec (alist-ref intent 'spec ""))
         (qty  (alist-ref intent 'effort 0))
         (unit (alist-ref intent 'effort-unit "hr"))
         (scope (alist-ref intent 'scope ""))
         (selected (and selected-intent-id
                        (equal? id selected-intent-id)))
         (match (alist-ref intent 'match 'unassigned))
         (sp-name (alist-ref intent 'suggested-name #f))
         (sp-id (alist-ref intent 'suggested #f))
         ;; The candidate 'race: workers who've marked willing for this need.
         (willing-workers (alist-ref intent 'willing '()))
         (n-willing (length (filter (lambda (w) (eq? (alist-ref w 'willing-status 'invited) 'willing))
                                     willing-workers)))
         (i-am-willing (eq? my-willing-status 'willing))
         (match-class
          (cond ((eq? match 'matched) " cal-intent-matched")
                ((eq? match 'unmatched) " cal-intent-unmatched-card")
                (else ""))))
    `(div (@ (class ,(string-append "cal-intent-card" match-class
                                    (if selected " cal-intent-selected" "")))
             (click ,(lambda (e) (on-select-intent intent))))
          (div (@ (class "cal-intent-proc")) ,proc)
          (div (@ (class "cal-intent-detail"))
               (span ,(string-append (n->s qty) " " unit))
               (span (@ (class "cal-intent-spec")) ,spec))
          ,@(if (string=? scope "") '()
                (list `(div (@ (class "cal-intent-scope")) ,scope)))
          ;; Suggested provider badge or unmatched warning
          ,@(cond
              ((eq? match 'matched)
               (list `(div (@ (class "cal-intent-suggested"))
                           (span (@ (class "cal-legend-dot cal-intent-dot")
                                    (style ,(string-append
                                             "background-color:"
                                             (person-color (or sp-id "") people)
                                             ";")))
                                 "")
                           (span ,(string-append
                                   "Suggested: " (or sp-name "?"))))))
              ((eq? match 'unmatched)
               (list `(div (@ (class "cal-intent-suggested cal-intent-unmatched"))
                           "\u26a0 Needs volunteer")))
              (else '()))
          ;; The candidate 'race \u2014 who's marked willing for this need (redundancy/
          ;; optionality made visible: several can express interest, limits bind
          ;; only at materialization). Shown whenever anyone has signalled.
          ,@(if (and show-willing? (pair? willing-workers))
                (list `(div (@ (class "cal-willing-race"))
                            ,@(map (lambda (w) (willing-chip w people)) willing-workers)
                            ,@(if (> n-willing 0)
                                  (list `(span (@ (class "cal-willing-count"))
                                               ,(string-append (number->string n-willing) " willing")))
                                  '())))
                '())
          ;; The offer-side opt-in: "you'd be helpful here \u2014 willing?" An option,
          ;; not a commitment; over-subscribable. Withdraw flips it back.
          ,@(if (and show-willing? on-express-willingness)
                (list `(div (@ (class "cal-intent-actions"))
                            (span (@ (class ,(string-append
                                              "cal-btn cal-intent-willing"
                                              (if i-am-willing " cal-btn-primary" "")))
                                     (click ,(lambda (e)
                                               (stop-prop e)
                                               (on-express-willingness intent (not i-am-willing)))))
                                  ,(if i-am-willing "\u2713 Willing \u2014 withdraw" "\u25c7 I'm willing"))))
                '())
          ;; Accept / Decline buttons (only when explicitly enabled)
          ,@(if (and show-accept? on-accept on-decline)
                (list `(div (@ (class "cal-intent-actions"))
                            (span (@ (class "cal-btn cal-btn-primary cal-intent-accept")
                                     (click ,(lambda (e)
                                               (stop-prop e)
                                               (on-accept intent))))
                                  "\u2713 Accept")
                            (span (@ (class "cal-btn cal-intent-decline")
                                     (click ,(lambda (e)
                                               (stop-prop e)
                                               (on-decline intent))))
                                  "\u2717 Decline")))
                '()))))

(define (intent-my-willing-status intent acting-as)
  "The acting-as user's willingness on this need: 'willing | #f, read from the
   intent's willing-workers race (so it survives a refresh — status lives in meta)."
  (and acting-as
       (let ((me (find (lambda (w) (equal? (alist-ref w 'id "") acting-as))
                       (alist-ref intent 'willing '()))))
         (and me (alist-ref me 'willing-status #f)))))

(define (intent-candidate? intent acting-as)
  "Is the acting-as user a candidate for this need — i.e. could they help?
   True when they hold the skill (in 'candidates) OR already signalled willing."
  (and acting-as
       (or (member acting-as (alist-ref intent 'candidates '()))
           (and (intent-my-willing-status intent acting-as) #t))))

(define* (render-intents-sidebar intents on-select-intent selected-intent-id
                                 #:key (people '()) (on-accept #f) (on-decline #f)
                                       (on-express-willingness #f)
                                       (stop-prop (lambda (e) #f))
                                       (acting-as #f))
  "Sidebar listing pending work intents split into sections:
     - Awaiting your acceptance: a materialized assignment suggested to ACTING-AS
     - You'd be helpful here: needs ACTING-AS is a candidate for — the solver's
       OFFER. A Willing toggle opts in (an option, not a commitment); the
       candidate 'race shows who else has signalled.
     - Needs a volunteer: unmatched intents
     - Others' pending: matched to someone else, or unassigned
   Only 'awaiting your acceptance' gets accept/decline; only 'you'd be helpful'
   gets the willingness toggle."
  (define (classify intent)
    (let ((match (alist-ref intent 'match 'unassigned))
          (sp    (alist-ref intent 'suggested #f)))
      (cond
        ;; You've been materialized/suggested → confirm it.
        ((and (eq? match 'matched) acting-as (equal? sp acting-as)) 'yours)
        ;; You could help and haven't been picked yet → the OFFER (willing toggle).
        ((and on-express-willingness (intent-candidate? intent acting-as)
              (not (eq? match 'matched)))
         'offers)
        ((eq? match 'unmatched) 'unmatched)
        (else 'others))))
  (let* ((yours     (filter (lambda (i) (eq? (classify i) 'yours)) intents))
         (offers    (filter (lambda (i) (eq? (classify i) 'offers)) intents))
         (unmatched (filter (lambda (i) (eq? (classify i) 'unmatched)) intents))
         (others    (filter (lambda (i) (eq? (classify i) 'others)) intents))
         (render-card
          (lambda (accept? willing?)
            (lambda (i)
              (render-intent-card i
                #:on-select-intent on-select-intent
                #:selected-intent-id selected-intent-id
                #:people people
                #:on-accept on-accept
                #:on-decline on-decline
                #:stop-prop stop-prop
                #:show-accept? accept?
                #:show-willing? willing?
                #:on-express-willingness (and willing? on-express-willingness)
                #:my-willing-status (intent-my-willing-status i acting-as)))))
         (section
          (lambda (title cls items accept? willing?)
            (if (null? items) '()
                (list `(div (@ (class ,(string-append "cal-intents-section " cls)))
                            (div (@ (class "cal-intents-subtitle")) ,title)
                            ,@(map (render-card accept? willing?) items)))))))
    `(div (@ (class "cal-intents-sidebar"))
          (div (@ (class "cal-intents-title")) "Pending Work")
          ,@(if (null? intents)
                (list `(div (@ (class "cal-intents-empty")) "No pending intents"))
                (append
                  (section "Awaiting your acceptance"
                           "cal-intents-yours" yours #t #f)
                  (section "You'd be helpful here"
                           "cal-intents-offers" offers #f #t)
                  (section "Needs a volunteer"
                           "cal-intents-unmatched" unmatched #f #f)
                  (section "Others' pending"
                           "cal-intents-others" others #f #f))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  ICALENDAR EXPORT
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (event->ical evt)
  "Convert a calendar event alist to an iCalendar VEVENT string."
  (let* ((id    (alist-ref evt 'id ""))
         (title (alist-ref evt 'title ""))
         (date  (alist-ref evt 'date ""))
         (sh    (alist-ref evt 'sh 0))
         (sm    (alist-ref evt 'sm 0))
         (eh    (alist-ref evt 'eh 0))
         (em    (alist-ref evt 'em 0))
         (loc   (alist-ref evt 'location ""))
         (desc  (alist-ref evt 'description ""))
         (person (alist-ref evt 'person ""))
         ;; Format date as YYYYMMDD (strip dashes)
         (y (if (> (string-length date) 3) (substring date 0 4) "2026"))
         (m (if (> (string-length date) 6) (substring date 5 7) "01"))
         (d (if (> (string-length date) 9) (substring date 8 10) "01"))
         (dtstart (string-append y m d "T" (pad2 sh) (pad2 sm) "00"))
         (dtend   (string-append y m d "T" (pad2 eh) (pad2 em) "00"))
         ;; VF metadata as X-properties
         (vf-proc  (alist-ref evt 'vf-process-id #f))
         (vf-act   (alist-ref evt 'vf-action #f))
         (vf-scope (alist-ref evt 'vf-scope #f)))
    (string-append
     "BEGIN:VEVENT\r\n"
     "UID:" id "@playnet\r\n"
     "DTSTART:" dtstart "\r\n"
     "DTEND:" dtend "\r\n"
     "SUMMARY:" title "\r\n"
     (if (string=? loc "") "" (string-append "LOCATION:" loc "\r\n"))
     (if (string=? desc "") "" (string-append "DESCRIPTION:" desc "\r\n"))
     (if (string=? person "") "" (string-append "ATTENDEE:" person "\r\n"))
     (if vf-proc (string-append "X-PLAYNET-VF-PROCESS:" vf-proc "\r\n") "")
     (if vf-act (string-append "X-PLAYNET-VF-ACTION:" (symbol->string vf-act) "\r\n") "")
     (if vf-scope (string-append "X-PLAYNET-VF-SCOPE:" vf-scope "\r\n") "")
     "END:VEVENT\r\n")))

(define (ical-line->pair line)
  "Parse 'KEY:VALUE' into (key . value). Returns #f if malformed."
  (let ((colon (let find ((i 0))
                 (cond ((>= i (string-length line)) #f)
                       ((char=? (string-ref line i) #\:) i)
                       (else (find (+ i 1)))))))
    (if colon
        (cons (substring line 0 colon)
              (substring line (+ colon 1)))
        #f)))

(define (parse-dtstring dt)
  "Parse YYYYMMDDTHHMMSS into (date-str hour min). Returns #f on failure."
  (if (< (string-length dt) 15) #f
      (let ((y (substring dt 0 4))
            (m (substring dt 4 6))
            (d (substring dt 6 8))
            (hh (substring dt 9 11))
            (mm (substring dt 11 13)))
        (list (string-append y "-" m "-" d)
              (safe-string->number hh)
              (safe-string->number mm)))))

(define (safe-string->number s)
  (or (string->number s) 0))

(define (parse-ical-events ical-text next-id-start)
  "Parse iCalendar text into list of event alists. Returns (events . next-id)."
  (let* ((lines (split-on-newlines ical-text))
         (in-event #f)
         (current '())
         (events '())
         (next-id next-id-start))
    (for-each
     (lambda (line)
       ;; Strip \r
       (let ((l (if (and (> (string-length line) 0)
                         (char=? (string-ref line (- (string-length line) 1)) #\return))
                    (substring line 0 (- (string-length line) 1))
                    line)))
         (cond
          ((string=? l "BEGIN:VEVENT")
           (set! in-event #t)
           (set! current '()))
          ((string=? l "END:VEVENT")
           (when in-event
             (let* ((uid (or (assoc-ref current "UID") ""))
                    (summary (or (assoc-ref current "SUMMARY") ""))
                    (dtstart (or (assoc-ref current "DTSTART") ""))
                    (dtend (or (assoc-ref current "DTEND") ""))
                    (location (or (assoc-ref current "LOCATION") ""))
                    (description (or (assoc-ref current "DESCRIPTION") ""))
                    (start-parts (parse-dtstring dtstart))
                    (end-parts (parse-dtstring dtend))
                    (id (string-append "ics-" (number->string next-id))))
               (when (and start-parts end-parts)
                 (set! events
                       (cons (list (cons 'id id)
                                   (cons 'title summary)
                                   (cons 'date (car start-parts))
                                   (cons 'sh (cadr start-parts))
                                   (cons 'sm (caddr start-parts))
                                   (cons 'eh (cadr end-parts))
                                   (cons 'em (caddr end-parts))
                                   (cons 'person "imported")
                                   (cons 'location location)
                                   (cons 'description description)
                                   (cons 'color "#8b7b96")
                                   (cons 'source 'event)
                                   (cons 'status 'open))
                             events))
                 (set! next-id (+ next-id 1)))))
           (set! in-event #f))
          (in-event
           (let ((pair (ical-line->pair l)))
             (when pair
               (set! current (cons pair current))))))))
     lines)
    (cons (reverse events) next-id)))

;;; ── VF AvailabilityWindow ↔ iCal VFREEBUSY ──────────────────────────────────

(define (avail-slot->ical slot)
  "Export one availability slot as an iCal VFREEBUSY. The slot carries
   day-symbol and start-time/end-time (HH:MM) in VF style."
  (let ((day-sym (or (alist-ref slot 'day-symbol) "monday"))
        (start   (or (alist-ref slot 'start-time) "09:00"))
        (end     (or (alist-ref slot 'end-time) "17:00"))
        (id      (alist-ref slot 'id 0)))
    (string-append
     "BEGIN:VFREEBUSY\r\n"
     "UID:avail-" (number->string id) "@playnet\r\n"
     "X-PLAYNET-DAY:" (if (symbol? day-sym) (symbol->string day-sym)
                          (if (string? day-sym) day-sym "monday")) "\r\n"
     "X-PLAYNET-START:" start "\r\n"
     "X-PLAYNET-END:" end "\r\n"
     "FBTYPE:FREE\r\n"
     "END:VFREEBUSY\r\n")))

(define (availability->ical slots)
  "Export all availability slots as iCal VCALENDAR with VFREEBUSY entries."
  (string-append
   "BEGIN:VCALENDAR\r\n"
   "VERSION:2.0\r\n"
   "PRODID:-//playnet//availability//EN\r\n"
   (apply string-append (map avail-slot->ical slots))
   "END:VCALENDAR\r\n"))

(define (parse-ical-availability ical-text)
  "Parse iCal VFREEBUSY entries back into availability slot alists.
   Reads X-PLAYNET-DAY/START/END for VF-compatible round-tripping."
  (let* ((lines (split-on-newlines ical-text))
         (in-fb #f) (current '()) (slots '()) (next-id 1))
    (for-each
     (lambda (line)
       (let ((l (if (and (> (string-length line) 0)
                         (char=? (string-ref line (- (string-length line) 1)) #\return))
                    (substring line 0 (- (string-length line) 1))
                    line)))
         (cond
          ((string=? l "BEGIN:VFREEBUSY") (set! in-fb #t) (set! current '()))
          ((string=? l "END:VFREEBUSY")
           (when in-fb
             (let ((day-str (or (assoc-ref current "X-PLAYNET-DAY") "monday"))
                   (start   (or (assoc-ref current "X-PLAYNET-START") "09:00"))
                   (end     (or (assoc-ref current "X-PLAYNET-END") "17:00")))
               (set! slots (cons (list (cons 'id next-id)
                                       (cons 'person "me")
                                       (cons 'day-symbol (string->symbol day-str))
                                       (cons 'start-time start)
                                       (cons 'end-time end)
                                       (cons 'day (day-sym->dow
                                                   (string->symbol day-str)))
                                       (cons 'sh (hh-of start))
                                       (cons 'sm (mm-of start))
                                       (cons 'eh (hh-of end))
                                       (cons 'em (mm-of end)))
                                 slots))
               (set! next-id (+ next-id 1))))
           (set! in-fb #f))
          (in-fb
           (let ((pair (ical-line->pair l)))
             (when pair (set! current (cons pair current))))))))
     lines)
    (reverse slots)))

(define (day-sym->dow sym)
  (case sym
    ((monday) 0) ((tuesday) 1) ((wednesday) 2) ((thursday) 3)
    ((friday) 4) ((saturday) 5) ((sunday) 6) (else 0)))

(define (hh-of hhmm)
  (if (>= (string-length hhmm) 2) (safe-string->number (substring hhmm 0 2)) 9))

(define (mm-of hhmm)
  (if (>= (string-length hhmm) 3) (safe-string->number (substring hhmm 3 5)) 0))


(define (split-on-newlines s)
  "Split string on newline characters."
  (let loop ((s s) (acc '()))
    (let ((nl (let find ((i 0))
               (cond ((>= i (string-length s)) #f)
                     ((char=? (string-ref s i) #\newline) i)
                     (else (find (+ i 1)))))))
      (if nl
          (loop (substring s (+ nl 1))
                (cons (substring s 0 nl) acc))
          (reverse (cons s acc))))))

(define (assoc-ref alist key)
  "Look up KEY (string) in alist using equal?. Returns value or #f."
  (let ((pair (find (lambda (p) (equal? (car p) key)) alist)))
    (if pair (cdr pair) #f)))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: CURRENT TIME LINE
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-current-time-line current-ms range-start day-count)
  "Red line at current time. Returns (column-offset . sxml) or #f if the
   current time falls outside the visible date range."
  (let* ((cur-day (day-start-ms current-ms))
         (range-end (+ range-start (* day-count *day-ms*)))
         (hm (epoch-ms->hour-min current-ms))
         (hour (car hm))
         (min (cadr hm))
         (top-px (time->px hour min)))
    (if (and (>= cur-day range-start) (< cur-day range-end))
        (cons (quotient (- cur-day range-start) *day-ms*)
              `(div (@ (class "cal-current-time")
                       (style ,(string-append "top:" (number->string top-px) "px;")))
                    ""))
        #f)))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: EVENT DETAIL PANEL (right sidebar)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (n->s n)
  (number->string (if (= n (floor n)) (inexact->exact (floor n)) n)))

(define (action-color act)
  (cond ((eq? act 'work) *palette-purple*)
        ((eq? act 'produce) "#38a169")   ; verb-meant: a display choice per action
        ((eq? act 'consume) "#e53e3e")   ; verb-meant: a display choice per action
        ((eq? act 'use) *palette-amber*)
        (else *palette-grey*)))

(define* (render-event-detail-panel evt on-close on-edit on-delete people
                                    process-commitments on-record-effort
                                    process-flows supply-chain
                                    #:key (on-accept-assignment #f)
                                          (on-decline-assignment #f)
                                          (on-express-willingness #f)
                                          (acting-as #f)
                                          (stop-prop (lambda (e) #f)))
  "Right sidebar showing full event detail + VF process context.
   For an offered (intent) event the panel carries the three-way
   response: WILLING (the over-subscribable opt-in — anyone acting),
   COMMIT (promote to commitment — the suggested person), REJECT
   (decline the suggestion and stamp declined willingness)."
  (let* ((title   (alist-ref evt 'title ""))
         (sh      (alist-ref evt 'sh 0))
         (sm      (alist-ref evt 'sm 0))
         (eh      (alist-ref evt 'eh 0))
         (em      (alist-ref evt 'em 0))
         (date    (alist-ref evt 'date ""))
         (loc     (alist-ref evt 'location ""))
         (person  (alist-ref evt 'person ""))
         (color   (alist-ref evt 'color "#63b3ed"))
         (desc    (alist-ref evt 'description ""))
         (status  (alist-ref evt 'status 'open))
         (source  (alist-ref evt 'source 'event))
         (is-vf   (or (eq? source 'intent) (eq? source 'commitment)))
         (vf-proc (alist-ref evt 'vf-process-id #f))
         (vf-act  (alist-ref evt 'vf-action #f))
         (vf-spec (alist-ref evt 'vf-resource-spec #f))
         (vf-qty  (alist-ref evt 'vf-effort-qty #f))
         (vf-unit (alist-ref evt 'vf-effort-unit "hr"))
         (vf-scope (alist-ref evt 'vf-scope #f))
         (vf-fulfilled (alist-ref evt 'vf-fulfilled-qty 0))
         ;; Assignment metadata
         (match-st (alist-ref evt 'match 'unassigned))
         (sp-id    (alist-ref evt 'suggested #f))
         (sp-name  (alist-ref evt 'suggested-name #f))
         ;; The acting-as user's standing in this need's candidate race.
         (my-willing (intent-my-willing-status evt acting-as))
         (i-am-willing (eq? my-willing 'willing))
         ;; Duration in minutes
         (dur-min (- (+ (* eh 60) em) (+ (* sh 60) sm)))
         (dur-h (quotient dur-min 60))
         (dur-m (modulo dur-min 60)))
    `(div (@ (class "cal-detail-panel"))
          ;; Header
          (div (@ (class "cal-detail-header"))
               (span (@ (class "cal-detail-title")) ,title)
               (span (@ (class "cal-detail-close") (click ,on-close)) "\u2715"))
          ;; Time
          (div (@ (class "cal-detail-row"))
               (span (@ (class "cal-detail-icon")) "\u23f0")
               (span (@ (class "cal-detail-val"))
                     ,(string-append (fmt-time sh sm) " \u2192 " (fmt-time eh em)
                                     "  " (number->string dur-h) "h"
                                     (if (> dur-m 0)
                                         (string-append (number->string dur-m) "m")
                                         ""))))
          ;; Date
          (div (@ (class "cal-detail-row"))
               (span (@ (class "cal-detail-icon")) "\u2611")
               (span (@ (class "cal-detail-val")) ,date))
          ;; Person
          (div (@ (class "cal-detail-row"))
               (span (@ (class "cal-detail-icon")) "\u263a")
               (span (@ (class "cal-legend-dot cal-detail-dot")
                        (style ,(string-append "background-color:" color ";"))) "")
               (span (@ (class "cal-detail-val")) ,person))
          ;; Location
          ,@(if (string=? loc "")
                '()
                (list `(div (@ (class "cal-detail-row"))
                            (span (@ (class "cal-detail-icon")) "\u2302")
                            (span (@ (class "cal-detail-val")) ,loc))))
          ;; Description
          ,@(if (string=? desc "")
                '()
                (list `(div (@ (class "cal-detail-row cal-detail-desc"))
                            (span (@ (class "cal-detail-val")) ,desc))))
          ;; Status
          (div (@ (class "cal-detail-row"))
               (span (@ (class "cal-detail-icon")) ,(status-dot status))
               (span (@ (class "cal-detail-val"))
                     ,(cond ((eq? status 'fulfilled) "Fulfilled")
                            ((eq? status 'committed) "Committed")
                            (else "Open"))))
          ;; Assignment context (work-assignment metadata)
          ,@(if (and is-vf (not (eq? match-st 'unassigned)))
                (let ((yours? (and acting-as sp-id (equal? acting-as sp-id))))
                  `((div (@ (class "cal-detail-section cal-assignment-section"))
                         (div (@ (class "cal-detail-section-title")) "Assignment")
                         ,(if (eq? match-st 'matched)
                              `(div (@ (class "cal-assignment-row"))
                                    (span (@ (class "cal-legend-dot cal-detail-dot")
                                             (style ,(string-append
                                                      "background-color:"
                                                      (person-color (or sp-id "") people) ";")))
                                          "")
                                    (span (@ (class "cal-assignment-name"))
                                          ,(string-append "Suggested: " (or sp-name sp-id "")))
                                    ,@(if (and (not acting-as) (eq? source 'intent))
                                          `((span (@ (class "cal-assignment-hint")
                                                     (style "margin-left:auto;font-size:9px;opacity:0.6;"))
                                                  "Pick an 'Acting as' user to respond"))
                                          '()))
                              `(div (@ (class "cal-assignment-row cal-assignment-unmatched"))
                                    (span "\u26a0 No agent matched for this role"))))))
                '())
          ;; ── Your response (offered events) ─────────────────────────
          ;; Three expressions, in escalating strength:
          ;;   WILLING — the offer-side opt-in (an option, not a bind;
          ;;             over-subscribable; anyone acting can raise it)
          ;;   COMMIT  — promote the intent to a Commitment (the
          ;;             suggested person; the hour budget binds here)
          ;;   REJECT  — decline the suggestion AND stamp declined
          ;;             willingness so a gated re-solve skips you
          ,@(if (and acting-as (eq? source 'intent)
                     (or on-express-willingness on-accept-assignment
                         on-decline-assignment))
                (let ((yours? (and sp-id (equal? acting-as sp-id))))
                  `((div (@ (class "cal-detail-section cal-response-section"))
                         (div (@ (class "cal-detail-section-title")) "Your response")
                         (div (@ (class "cal-intent-actions"))
                              ,@(if on-express-willingness
                                    `((span (@ (class ,(string-append
                                                        "cal-btn cal-intent-willing"
                                                        (if i-am-willing " cal-btn-primary" "")))
                                               (click ,(lambda (e)
                                                         (stop-prop e)
                                                         (on-express-willingness
                                                          evt (not i-am-willing)))))
                                            ,(if i-am-willing
                                                 "\u2713 Willing \u2014 withdraw"
                                                 "\u25c7 Willing")))
                                    '())
                              ,@(if (and yours? on-accept-assignment)
                                    `((span (@ (class "cal-btn cal-btn-primary")
                                               (click ,(lambda (e)
                                                         (stop-prop e)
                                                         (on-accept-assignment evt))))
                                            "\u25cf Commit"))
                                    '())
                              ,@(if on-decline-assignment
                                    `((span (@ (class "cal-btn cal-btn-danger")
                                               (click ,(lambda (e)
                                                         (stop-prop e)
                                                         (on-decline-assignment evt))))
                                            "\u2717 Reject"))
                                    '()))
                         ,@(if (eq? my-willing 'declined)
                               `((div (@ (class "cal-assignment-hint")
                                         (style "font-size:9px;opacity:0.6;"))
                                     "You've declined this need \u2014 'Willing' re-opens it"))
                               '()))))
                '())
          ;; VF Process Context
          ,@(if (and is-vf vf-proc)
                (let* ((pct (if (and vf-qty (> vf-qty 0))
                               (min 100 (inexact->exact (round (* (/ vf-fulfilled vf-qty) 100))))
                               0))
                       (fill-color (cond ((>= pct 100) "#38a169")
                                        ((>= pct 50) *palette-amber*)
                                        (else "#e53e3e")))
                       (act-color (cond ((eq? vf-act 'work) *palette-purple*)
                                       ((eq? vf-act 'produce) "#38a169")   ; verb-meant: a display choice per action
                                       (else "#e53e3e"))))
                  `((div (@ (class "cal-detail-section"))
                         (div (@ (class "cal-detail-section-title")) "Process Context")
                         ;; Breadcrumb
                         (div (@ (class "cal-vf-breadcrumb"))
                              (span (@ (class "cal-vf-proc")) ,(or vf-proc ""))
                              (span (@ (class "cal-vf-sep")) "\u203a")
                              (span (@ (class "cal-vf-action")
                                       (style ,(string-append "color:" act-color)))
                                    ,(if vf-act (symbol->string vf-act) ""))
                              (span (@ (class "cal-vf-sep")) "\u203a")
                              (span (@ (class "cal-vf-spec")) ,(or vf-spec "")))
                         ;; Scope
                         ,@(if vf-scope
                               (list `(div (@ (class "cal-vf-scope"))
                                           ,(string-append "Scope: " vf-scope)))
                               '())
                         ;; Progress bar
                         ,@(if (and vf-qty (> vf-qty 0))
                               `((div (@ (class "cal-vf-progress"))
                                      (div (@ (class "cal-vf-track"))
                                           (div (@ (class "cal-vf-fill")
                                                   (style ,(string-append
                                                            "width:" (n->s pct) "%;"
                                                            "background:" fill-color ";")))
                                                ""))
                                      (span (@ (class "cal-vf-pct"))
                                            ,(string-append
                                              (n->s vf-fulfilled) " / "
                                              (n->s vf-qty) " " vf-unit
                                              " (" (n->s pct) "%)"))))
                               '())
                         ;; Record effort
                         ,@(if on-record-effort
                               `((div (@ (class "cal-vf-record"))
                                      (input (@ (id "cal-effort-qty") (type "number")
                                                (value "1") (placeholder "hrs")))
                                      (span (@ (class "cal-btn cal-btn-primary cal-record-btn")
                                               (click ,on-record-effort))
                                            ,(string-append "+ " vf-unit))))
                               '())
                         ;; Process inputs/outputs
                         ,@(if (null? process-flows) '()
                               (let* ((inputs (filter (lambda (f)
                                                        (alist-ref f 'is-input #f))
                                                      process-flows))
                                      (outputs (filter (lambda (f)
                                                         (not (alist-ref f 'is-input #f)))
                                                       process-flows)))
                                 `(,@(if (null? inputs) '()
                                         `((div (@ (class "cal-vf-flows-title")) "This process needs")
                                           ,@(map (lambda (f)
                                                    (let ((spec (alist-ref f 'spec ""))
                                                          (qty (alist-ref f 'qty 0))
                                                          (unit (alist-ref f 'unit ""))
                                                          (act (alist-ref f 'action 'consume)))
                                                      `(div (@ (class "cal-vf-flow"))
                                                            (span (@ (class "cal-vf-flow-arrow")) "\u25b8")
                                                            (span (@ (class "cal-vf-flow-spec")) ,spec)
                                                            (span (@ (class "cal-vf-flow-qty"))
                                                                  ,(string-append (n->s qty) " " unit))
                                                            (span (@ (class "cal-vf-flow-action")
                                                                     (style ,(string-append
                                                                              "color:" (action-color act))))
                                                                  ,(symbol->string act)))))
                                                  inputs)))
                                   ,@(if (null? outputs) '()
                                         `((div (@ (class "cal-vf-flows-title")) "This process produces")
                                           ,@(map (lambda (f)
                                                    (let ((spec (alist-ref f 'spec ""))
                                                          (qty (alist-ref f 'qty 0))
                                                          (unit (alist-ref f 'unit ""))
                                                          (act (alist-ref f 'action 'produce)))
                                                      `(div (@ (class "cal-vf-flow"))
                                                            (span (@ (class "cal-vf-flow-arrow")) "\u25b8")
                                                            (span (@ (class "cal-vf-flow-spec")) ,spec)
                                                            (span (@ (class "cal-vf-flow-qty"))
                                                                  ,(string-append (n->s qty) " " unit))
                                                            (span (@ (class "cal-vf-flow-action")
                                                                     (style ,(string-append
                                                                              "color:" (action-color act))))
                                                                  ,(symbol->string act)))))
                                                  outputs))))))
                         ;; Supply chain (upstream/downstream)
                         ,@(if (null? supply-chain) '()
                               `((div (@ (class "cal-vf-flows-title")) "Supply chain")
                                 ,@(map (lambda (link)
                                          (let ((dir (alist-ref link 'direction 'up))
                                                (proc-name (alist-ref link 'process ""))
                                                (spec (alist-ref link 'spec ""))
                                                (scope (alist-ref link 'scope "")))
                                            `(div (@ (class "cal-vf-chain"))
                                                  (span (@ (class "cal-vf-chain-arrow"))
                                                        ,(if (eq? dir 'up) "\u2191" "\u2193"))
                                                  (span (@ (class "cal-vf-chain-proc")) ,proc-name)
                                                  (span (@ (class "cal-vf-chain-sep")) "\u2192")
                                                  (span (@ (class "cal-vf-chain-spec")) ,spec)
                                                  ,@(if (string=? scope "")
                                                        '()
                                                        (list `(span (@ (class "cal-vf-chain-scope"))
                                                                     ,(string-append "(" scope ")")))))))
                                        supply-chain)))
                         ;; Other commitments in this process
                         ,@(if (null? process-commitments) '()
                               `((div (@ (class "cal-vf-others-title"))
                                      "Other commitments")
                                 ,@(map (lambda (c)
                                          (let ((cp (alist-ref c 'person ""))
                                                (cq (alist-ref c 'vf-effort-qty 0))
                                                (cu (alist-ref c 'vf-effort-unit "hr"))
                                                (cs (alist-ref c 'status 'open)))
                                            `(div (@ (class "cal-vf-other"))
                                                  (span (@ (class "cal-status-dot"))
                                                        ,(status-dot cs))
                                                  (span ,cp)
                                                  (span (@ (class "cal-vf-other-qty"))
                                                        ,(string-append
                                                          (n->s cq) " " cu)))))
                                        process-commitments))))))
                '())
          ;; Actions
          (div (@ (class "cal-detail-actions"))
               (span (@ (class "cal-btn cal-btn-primary") (click ,on-edit)) "Edit")
               (span (@ (class "cal-btn cal-btn-danger") (click ,on-delete)) "Delete")))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: TIME GRID (day / 3-day / week — generic by day-count)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-time-grid range-start day-count events availability people
                          today-date-str current-time-ms
                          on-slot-click on-event-click on-cycle-status stop-prop
                          edit-mode? on-create-start on-resize-start on-move-start
                          on-spread-start on-delete on-day-hover
                          on-drag-move on-drag-end)
  "The shared time grid used by day / 3-day / week views. Number of day
   columns = DAY-COUNT; the time gutter is sized by CSS via --cal-cols."
  (let* ((range-dates  (map (lambda (off)
                              (date-parts->date-string
                               (day-offset-date-parts range-start off)))
                            (iota-list day-count)))
         (allday-evts  (filter (lambda (e) (alist-ref e 'all-day #f)) events))
         (timed-evts   (filter (lambda (e) (not (alist-ref e 'all-day #f))) events))
         (line         (and current-time-ms
                            (render-current-time-line current-time-ms
                                                      range-start day-count)))
         (line-col     (if line (car line) -1))
         (line-sxml    (if line (cdr line) #f)))
    `(div (@ (class "cal-grid-col"))
          ,(render-day-headers range-start day-count today-date-str)
          ,(render-allday-strip range-dates allday-evts on-event-click)
          (div (@ (class ,(string-append "cal-grid-wrapper"
                                         (if edit-mode? " cal-edit-mode" "")))
                  (id "cal-grid-wrap")
                  ,@(if edit-mode?
                        `((mousemove ,on-drag-move)
                          (mouseup ,on-drag-end)
                          (mouseleave ,on-drag-end))
                        '()))
               (div (@ (class "cal-grid"))
                    ,(render-time-column)
                    ,@(map (lambda (off)
                             (let* ((ds      (list-ref range-dates off))
                                    (day-evts (filter (lambda (e)
                                                        (equal? (alist-ref e 'date "") ds))
                                                      timed-evts))
                                    (abs-dow (epoch-ms->day-of-week
                                              (+ range-start (* off *day-ms*))))
                                    (day-avail (filter (lambda (a)
                                                         (= (alist-ref a 'day 0) abs-dow))
                                                       availability))
                                    (day-line (and (= off line-col) line-sxml))
                                    (today?  (and today-date-str
                                                  (string=? ds today-date-str))))
                               (render-day-column ds day-evts day-avail people abs-dow
                                                  on-slot-click on-event-click
                                                  on-cycle-status day-line
                                                  today? stop-prop
                                                  edit-mode? on-create-start
                                                  on-resize-start on-move-start
                                                  on-spread-start on-delete
                                                  on-day-hover)))
                           (iota-list day-count)))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: MONTH VIEW
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (month-grid-start-ms anchor-ms)
  "First Monday on or before the 1st of ANCHOR's month."
  (let* ((parts (epoch-ms->date-parts anchor-ms))
         (first-of-month (date-parts->epoch-ms (list (car parts) (cadr parts) 1))))
    (week-start-ms first-of-month)))

(define (render-month-view anchor-ms events people today-date-str
                           on-event-click on-day-click)
  "6-row × 7-col month grid with event chips per day. Click a day to
   drill into the day view; click a chip to open the event detail."
  (let* ((parts (epoch-ms->date-parts anchor-ms))
         (this-month (cadr parts))
         (grid-start (month-grid-start-ms anchor-ms))
         (visible-ids (map (lambda (p) (alist-ref p 'id ""))
                           (filter (lambda (p) (alist-ref p 'visible #t)) people)))
         (event-visible?
          (lambda (e)
            (or (null? people)
                (member (alist-ref e 'person "") visible-ids))))
         (cells
          (map (lambda (i)
                 (let* ((ms (+ grid-start (* i *day-ms*)))
                        (dp (epoch-ms->date-parts ms))
                        (ds (date-parts->date-string dp))
                        (in-month? (= (cadr dp) this-month))
                        (is-today (and today-date-str (string=? ds today-date-str)))
                        (day-evts
                         (filter (lambda (e)
                                   (and (equal? (alist-ref e 'date "") ds)
                                        (event-visible? e)))
                                 events))
                        (max-chips 3)
                        (visible (take-up-to day-evts max-chips))
                        (extra   (max 0 (- (length day-evts) max-chips))))
                   `(div (@ (class ,(string-append
                                     "cal-month-cell"
                                     (if in-month? "" " cal-month-cell-out")
                                     (if is-today " cal-month-cell-today" "")))
                            (click ,(lambda (e) (on-day-click ms))))
                         (div (@ (class ,(string-append
                                          "cal-month-daynum"
                                          (if is-today " cal-month-daynum-today" ""))))
                              ,(number->string (caddr dp)))
                         ,@(map (lambda (evt)
                                  `(div (@ (class "cal-month-chip")
                                           (style ,(string-append
                                                    "background:"
                                                    (alist-ref evt 'color "#63b3ed") ";"))
                                           (click ,(lambda (e)
                                                     (on-event-click evt))))
                                        ,(alist-ref evt 'title "")))
                                visible)
                         ,@(if (> extra 0)
                               (list `(div (@ (class "cal-month-more"))
                                           ,(string-append "+" (number->string extra)
                                                           " more")))
                               '()))))
               (iota-list 42))))
    `(div (@ (class "cal-month"))
          (div (@ (class "cal-month-dow"))
               ,@(map (lambda (i)
                        `(div (@ (class "cal-month-dow-cell"))
                              ,(vector-ref day-names i)))
                      (iota-list 7)))
          (div (@ (class "cal-month-grid")) ,@cells))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: SCHEDULE VIEW (chronological list, mobile-first)
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-schedule-view anchor-ms events people today-date-str
                              on-event-click)
  "Vertical list of events grouped by date, starting at ANCHOR. Ideal
   for narrow viewports."
  (let* ((visible-ids (map (lambda (p) (alist-ref p 'id ""))
                           (filter (lambda (p) (alist-ref p 'visible #t)) people)))
         (start-day (day-start-ms anchor-ms))
         (horizon-days 30)
         (end-day (+ start-day (* horizon-days *day-ms*)))
         (in-range?
          (lambda (e)
            (let ((d (alist-ref e 'date "")))
              ;; lexicographic comparison works for YYYY-MM-DD
              (let ((sd (date-parts->date-string
                         (epoch-ms->date-parts start-day)))
                    (ed (date-parts->date-string
                         (epoch-ms->date-parts end-day))))
                (and (string>=? d sd) (string<? d ed))))))
         (event-visible?
          (lambda (e)
            (or (null? people)
                (member (alist-ref e 'person "") visible-ids))))
         (in-events (filter (lambda (e)
                              (and (in-range? e) (event-visible? e)))
                            events))
         (sorted
          (sort in-events
                (lambda (a b)
                  (let ((da (alist-ref a 'date ""))
                        (db (alist-ref b 'date "")))
                    (cond ((string<? da db) #t)
                          ((string>? da db) #f)
                          (else (< (+ (* (alist-ref a 'sh 0) 60)
                                      (alist-ref a 'sm 0))
                                   (+ (* (alist-ref b 'sh 0) 60)
                                      (alist-ref b 'sm 0)))))))))
         (groups (group-by-key sorted
                                (lambda (e) (alist-ref e 'date "")))))
    `(div (@ (class "cal-schedule"))
          ,@(if (null? groups)
                (list `(div (@ (class "cal-schedule-empty"))
                            "No events in the next 30 days."))
                (map (lambda (g)
                       (let* ((ds (car g))
                              (evts (cdr g))
                              (dp (let ((p (string->date-parts ds)))
                                    (or p (list 0 0 0))))
                              (dow (epoch-ms->day-of-week
                                    (date-parts->epoch-ms dp)))
                              (dn (vector-ref day-names dow))
                              (is-today (and today-date-str
                                             (string=? ds today-date-str))))
                         `(div (@ (class "cal-schedule-day"))
                               (div (@ (class ,(string-append
                                                "cal-schedule-date"
                                                (if is-today
                                                    " cal-schedule-date-today"
                                                    ""))))
                                    (span (@ (class "cal-schedule-dow")) ,dn)
                                    (span (@ (class "cal-schedule-dnum"))
                                          ,(number->string (caddr dp))))
                               (div (@ (class "cal-schedule-events"))
                                    ,@(map (lambda (evt)
                                             (let ((color (alist-ref evt 'color "#63b3ed"))
                                                   (title (alist-ref evt 'title ""))
                                                   (sh (alist-ref evt 'sh 0))
                                                   (sm (alist-ref evt 'sm 0))
                                                   (eh (alist-ref evt 'eh 0))
                                                   (em (alist-ref evt 'em 0)))
                                               `(div (@ (class "cal-schedule-event")
                                                        (click ,(lambda (e)
                                                                  (on-event-click evt))))
                                                     (span (@ (class "cal-schedule-dot")
                                                              (style ,(string-append
                                                                       "background:" color ";")))
                                                           "")
                                                     (span (@ (class "cal-schedule-time"))
                                                           ,(string-append
                                                             (fmt-time sh sm) " – "
                                                             (fmt-time eh em)))
                                                     (span (@ (class "cal-schedule-title"))
                                                           ,title))))
                                           evts)))))
                     groups)))))

(define (string->date-parts s)
  "Parse YYYY-MM-DD into (y m d) or #f."
  (if (or (not s) (< (string-length s) 10)) #f
      (let ((y (string->number (substring s 0 4)))
            (m (string->number (substring s 5 7)))
            (d (string->number (substring s 8 10))))
        (and y m d (list y m d)))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  COMPOSED PAGE
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (calendar-page #:key (anchor-ms 0)
                              (view-mode 'week)
                              on-set-view-mode
                              on-pick-day
                              (events '()) (people '())
                              (availability '()) on-event-click on-slot-click
                              on-prev on-next on-today
                              on-toggle-person on-toggle-avail-editor
                              (editing-event #f) (editing-availability #f)
                              (selected-event #f) (process-commitments '())
                              on-save-event on-delete-event on-cancel-edit
                              on-close-detail on-edit-from-detail
                              on-delete-from-detail
                              on-create-avail-start on-resize-avail-start
                              on-move-avail-start on-spread-avail-start
                              on-delete-avail on-day-hover
                              on-avail-drag-move on-avail-drag-end
                              (stop-prop (lambda (e) #f))
                              (current-time-ms #f)
                              (unscheduled-intents '())
                              on-select-intent
                              (selected-intent-id #f)
                              on-export
                              on-record-effort
                              on-cycle-status
                              (process-flows '())
                              (supply-chain '())
                              (on-accept-assignment #f)
                              (on-decline-assignment #f)
                              (on-express-willingness #f)
                              ;; Scope, plan, and acting-as are session-level
                              ;; (rendered above the view in repl.scm). They
                              ;; flow in here as read-only context for query
                              ;; filtering and event highlighting.
                              (current-scope #f)
                              (current-plan #f)
                              (current-acting-as #f))
  "Compose the full calendar page.

   The view mode determines the visible range and layout:
     - day      → one column (today by default)
     - 3day     → three columns starting at ANCHOR
     - week     → seven columns starting at ANCHOR's Monday
     - month    → 6×7 month grid (no time gutter)
     - schedule → chronological list, 30-day horizon (mobile-friendly)

   ANCHOR-MS is a day-aligned epoch ms identifying the focused date;
   ON-PREV / ON-NEXT step by one unit appropriate for VIEW-MODE."
  (let* ((today-date-str (if current-time-ms
                             (date-parts->date-string
                              (epoch-ms->date-parts current-time-ms))
                             #f))
         ;; Visible-person filter
         (visible-ids (map (lambda (p) (alist-ref p 'id ""))
                           (filter (lambda (p) (alist-ref p 'visible #t)) people)))
         (visible-event?
          (lambda (e)
            (or (null? people)
                (member (alist-ref e 'person "") visible-ids))))
         (visible-events (filter visible-event? events))
         (header (render-header view-mode anchor-ms
                                on-prev on-next on-today
                                on-set-view-mode on-export))
         (toolbar (if (null? people) '()
                      (list `(div (@ (class "cal-toolbar"))
                                  ,(render-person-legend people on-toggle-person)
                                  ,(render-capacity-bar visible-events availability
                                                        people on-toggle-avail-editor
                                                        editing-availability)))))
         (intents-sidebar
          (if (null? unscheduled-intents) '()
              (list (render-intents-sidebar
                     unscheduled-intents on-select-intent
                     selected-intent-id
                     #:people people
                     #:on-accept on-accept-assignment
                     #:on-decline on-decline-assignment
                     #:on-express-willingness on-express-willingness
                     #:stop-prop stop-prop
                     #:acting-as current-acting-as))))
         (detail-panel
          (if selected-event
              (list (render-event-detail-panel
                     selected-event on-close-detail
                     on-edit-from-detail on-delete-from-detail
                     people process-commitments on-record-effort
                     process-flows supply-chain
                     #:on-accept-assignment on-accept-assignment
                     #:on-decline-assignment on-decline-assignment
                     #:on-express-willingness on-express-willingness
                     #:acting-as current-acting-as
                     #:stop-prop stop-prop))
              '()))
         (modals
          (if editing-event
              (list (render-event-editor editing-event
                                         on-save-event on-delete-event on-cancel-edit
                                         stop-prop))
              '()))
         (root-class (string-append "cal-view"
                                    (if selected-event " cal-view-with-detail" "")
                                    " cal-view-" (symbol->string view-mode)))
         ;; Each branch yields the inner content sitting between the
         ;; intents sidebar and the detail panel.
         (inner
          (case view-mode
            ((month)
             `(div (@ (class "cal-grid-col"))
                   ,(render-month-view anchor-ms visible-events people
                                       today-date-str on-event-click
                                       (or on-pick-day (lambda (ms) #f)))))
            ((schedule)
             `(div (@ (class "cal-grid-col"))
                   ,(render-schedule-view anchor-ms visible-events people
                                          today-date-str on-event-click)))
            (else
             (let* ((rng (view-mode-range view-mode anchor-ms))
                    (range-start (car rng))
                    (day-count   (cdr rng)))
               (render-time-grid range-start day-count visible-events
                                 availability people today-date-str
                                 current-time-ms on-slot-click on-event-click
                                 on-cycle-status stop-prop
                                 editing-availability
                                 on-create-avail-start on-resize-avail-start
                                 on-move-avail-start on-spread-avail-start
                                 on-delete-avail on-day-hover
                                 on-avail-drag-move on-avail-drag-end)))))
         (body
          `(div (@ (class ,(string-append "cal-body cal-body-"
                                          (symbol->string view-mode))))
                ,@intents-sidebar
                ,inner
                ,@detail-panel)))
    `(div (@ (class ,root-class)
             (style ,(string-append
                      "--cal-cols:"
                      (number->string
                       (case view-mode
                         ((day) 1) ((3day) 3) ((week) 7) (else 7))))))
          ,header
          ,@toolbar
          ,body
          ,@modals)))
