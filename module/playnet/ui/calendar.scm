;;; calendar.scm — Notion-style week calendar in SXML
;;;
;;; All functions are pure: data in, SXML out. No DOM mutation.
;;; Hoot/WASM compatible.

(define-module (playnet ui calendar)
  #:use-module (srfi srfi-1)
  #:use-module (playnet ddmrp)
  #:export (;; Date utilities
            epoch-ms->day-of-week
            epoch-ms->date-parts
            week-start-ms
            date-string
            date-parts->date-string
            day-offset-date-parts
            fmt-time
            day-names
            epoch-ms->hour-min

            ;; Layout
            compute-event-columns
            person-color

            ;; Rendering
            render-week-header
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
            event->ical
            ical-line->pair
            parse-ical-events

            ;; Composed page
            calendar-page))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  CONSTANTS
;;; ═══════════════════════════════════════════════════════════════════════════════

(define *hour-height* 60)   ;; pixels per hour
(define *day-ms* 86400000)  ;; ms in a day
(define *week-ms* 604800000)

(define day-names '#("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))

(define *person-colors*
  '#("#63b3ed" "#f6ad55" "#b794f4" "#4fd1c5" "#f687b3"
     "#7ee8a2" "#fc8181" "#d6bcfa" "#90cdf4" "#fbd38d"))


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
  (let ((a-start (+ (* (alist-ref a 'start-hour 0) 60) (alist-ref a 'start-min 0)))
        (a-end   (+ (* (alist-ref a 'end-hour 0) 60)   (alist-ref a 'end-min 0)))
        (b-start (+ (* (alist-ref b 'start-hour 0) 60) (alist-ref b 'start-min 0)))
        (b-end   (+ (* (alist-ref b 'end-hour 0) 60)   (alist-ref b 'end-min 0))))
    (and (< a-start b-end) (< b-start a-end))))

(define (event-start-minutes evt)
  (+ (* (alist-ref evt 'start-hour 0) 60) (alist-ref evt 'start-min 0)))

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
  (time->px (alist-ref evt 'start-hour 0) (alist-ref evt 'start-min 0)))

(define (event-height evt)
  (max 20 (- (time->px (alist-ref evt 'end-hour 0) (alist-ref evt 'end-min 0))
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
         (sh        (alist-ref evt 'start-hour 0))
         (sm        (alist-ref evt 'start-min 0))
         (eh        (alist-ref evt 'end-hour 0))
         (em        (alist-ref evt 'end-min 0))
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

(define (render-availability-overlay avail color)
  "Render a per-person colored dashed overlay for an availability slot."
  (let* ((top-px (time->px (alist-ref avail 'start-hour 9) (alist-ref avail 'start-min 0)))
         (bot-px (time->px (alist-ref avail 'end-hour 17) (alist-ref avail 'end-min 0)))
         (h-px   (- bot-px top-px))
         (c (or color "#48bb78")))
    `(div (@ (class "cal-avail")
             (style ,(string-append
                      "top:" (number->string top-px) "px;"
                      "height:" (number->string h-px) "px;"
                      "background:" (hex->rgba c "0.08") ";"
                      "border-color:" (hex->rgba c "0.35") ";"))))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: WEEK HEADER
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-week-header ws on-prev on-next on-today on-export)
  "Navigation bar only (month label + prev/today/next + export)."
  (let* ((parts (epoch-ms->date-parts ws))
         (y (car parts)) (m (cadr parts)))
    `(div (@ (class "cal-header"))
          (div (@ (class "cal-nav"))
               (span (@ (class "cal-nav-btn") (click ,on-prev)) "\u25c0")
               (span (@ (class "cal-nav-btn") (click ,on-today)) "today")
               (span (@ (class "cal-nav-btn") (click ,on-next)) "\u25b6")
               ,@(if on-export
                     (list `(span (@ (class "cal-nav-btn cal-export-btn") (click ,on-export))
                                  "\u21e9 .ics"))
                     '()))
          (span (@ (class "cal-month-label"))
                ,(string-append (number->string y) "-" (pad2 m))))))

(define (render-day-headers ws today-date-str)
  "Day column headers (Mon 6, Tue 7, ...) — rendered inside the grid area for alignment."
  `(div (@ (class "cal-day-headers"))
        (div (@ (class "cal-time-spacer")) "")
        ,@(map (lambda (offset)
                 (let* ((dp (day-offset-date-parts ws offset))
                        (d  (caddr dp))
                        (dn (vector-ref day-names offset))
                        (ds (date-parts->date-string dp))
                        (is-today (and today-date-str
                                       (string=? ds today-date-str))))
                   `(div (@ (class ,(string-append "cal-day-header"
                                                   (if is-today " cal-day-header-today" ""))))
                         (span (@ (class "cal-day-name")) ,dn)
                         (span (@ (class ,(string-append "cal-day-num"
                                                          (if is-today " cal-day-num-today" ""))))
                               ,(number->string d)))))
               (list 0 1 2 3 4 5 6))))


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

(define (render-day-column date-str day-events availability people
                          on-slot-click on-event-click on-cycle-status
                          time-line-sxml is-today stop-prop)
  "One day column: hour cells (click targets) + availability + events + time line."
  (let ((positioned (compute-event-columns day-events)))
    `(div (@ (class ,(string-append "cal-day-col"
                                    (if is-today " cal-day-today" ""))))
          ;; Fixed 24 hour cells as click targets
          ,@(map (lambda (h)
                   `(div (@ (class "cal-hour-cell")
                            (click ,(lambda (e) (on-slot-click date-str h))))
                         ""))
                 (let build ((i 0))
                   (if (= i 24) '() (cons i (build (+ i 1))))))
          ;; Availability overlays (absolute positioned, per-person colored)
          ,@(map (lambda (a)
                   (render-availability-overlay
                    a (person-color (alist-ref a 'person "") people)))
                 availability)
          ;; Mutual free time overlay (when 2+ people visible)
          ,@(let* ((visible-people (filter (lambda (p) (alist-ref p 'visible #t)) people))
                   (n-visible (length visible-people)))
              (if (< n-visible 2) '()
                  ;; Find intersection of all visible people's availability
                  (let* ((starts (map (lambda (a) (alist-ref a 'start-hour 9)) availability))
                         (ends (map (lambda (a) (alist-ref a 'end-hour 17)) availability))
                         (latest-start (if (null? starts) 9 (fold max 0 starts)))
                         (earliest-end (if (null? ends) 17 (fold min 24 ends))))
                    (if (< latest-start earliest-end)
                        (let* ((top-px (time->px latest-start 0))
                               (bot-px (time->px earliest-end 0))
                               (h-px (- bot-px top-px)))
                          (list `(div (@ (class "cal-mutual-free")
                                        (style ,(string-append
                                                 "top:" (number->string top-px) "px;"
                                                 "height:" (number->string h-px) "px;")))
                                     "")))
                        '()))))
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
        (sh      (alist-ref evt 'start-hour 9))
        (sm      (alist-ref evt 'start-min 0))
        (eh      (alist-ref evt 'end-hour 10))
        (em      (alist-ref evt 'end-min 0))
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
                        (sh (if slot (alist-ref slot 'start-hour 9) 9))
                        (eh (if slot (alist-ref slot 'end-hour 17) 17)))
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

(define (render-allday-strip week-dates allday-events on-event-click)
  "Horizontal strip above grid for all-day / untimed events."
  (if (null? allday-events) `(div)
      `(div (@ (class "cal-allday"))
            (div (@ (class "cal-allday-label")) "all day")
            ,@(map (lambda (offset)
                     (let* ((ds (list-ref week-dates offset))
                            (day-evts (filter (lambda (e)
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
                   (list 0 1 2 3 4 5 6)))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: CAPACITY BAR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (render-capacity-bar events availability people on-toggle-avail)
  "Capacity bar: total available vs committed hours for visible people."
  (let* ((visible (filter (lambda (p) (alist-ref p 'visible #t)) people))
         (visible-ids (map (lambda (p) (alist-ref p 'id "")) visible))
         ;; Total available hours (sum all availability slots * visible people)
         (total-avail
          (fold (lambda (a acc)
                  (if (member (alist-ref a 'person "") visible-ids)
                      (let* ((sh (alist-ref a 'start-hour 0))
                             (sm (alist-ref a 'start-min 0))
                             (eh (alist-ref a 'end-hour 0))
                             (em (alist-ref a 'end-min 0))
                             (mins (- (+ (* eh 60) em) (+ (* sh 60) sm))))
                        (+ acc (inexact->exact (floor (/ mins 60)))))
                      acc))
                0 availability))
         ;; Total committed hours (sum event durations for visible people)
         (total-committed
          (fold (lambda (evt acc)
                  (if (member (alist-ref evt 'person "") visible-ids)
                      (let* ((sh (alist-ref evt 'start-hour 0))
                             (sm (alist-ref evt 'start-min 0))
                             (eh (alist-ref evt 'end-hour 0))
                             (em (alist-ref evt 'end-min 0))
                             (mins (- (+ (* eh 60) em) (+ (* sh 60) sm))))
                        (+ acc (inexact->exact (floor (/ mins 60)))))
                      acc))
                0 events))
         (pct (if (> total-avail 0)
                  (min 100 (inexact->exact (round (* (/ total-committed total-avail) 100))))
                  0))
         (fill-color (cond ((> pct 90) "#e53e3e")
                           ((> pct 70) "#d69e2e")
                           (else "#38a169"))))
    `(div (@ (class "cal-capacity"))
          (div (@ (class "cal-capacity-bar"))
               (div (@ (class "cal-capacity-fill")
                       (style ,(string-append "width:" (n->s pct) "%;"
                                              "background:" fill-color ";")))
                    ""))
          (span (@ (class "cal-capacity-label"))
                ,(string-append (n->s total-committed) " / "
                                (n->s total-avail) " hr ("
                                (n->s pct) "%)"))
          (span (@ (class "cal-btn cal-capacity-btn") (click ,on-toggle-avail))
                "availability"))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  RENDER: UNSCHEDULED INTENTS SIDEBAR
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (render-intents-sidebar intents on-select-intent selected-intent-id
                                 #:key (people '()) (on-accept #f) (on-decline #f)
                                       (stop-prop (lambda (e) #f)))
  "Sidebar listing unscheduled work intents from the org planner.
   When work-assignments metadata is present, shows suggested provider
   and accept/decline buttons for the consent flow."
  `(div (@ (class "cal-intents-sidebar"))
        (div (@ (class "cal-intents-title")) "Unscheduled Work")
        ,@(if (null? intents)
              (list `(div (@ (class "cal-intents-empty")) "No pending intents"))
              (map (lambda (intent)
                     (let* ((id   (alist-ref intent 'id ""))
                            (proc (alist-ref intent 'process-name ""))
                            (spec (alist-ref intent 'resource-spec ""))
                            (qty  (alist-ref intent 'effort-qty 0))
                            (unit (alist-ref intent 'effort-unit "hr"))
                            (scope (alist-ref intent 'scope ""))
                            (selected (and selected-intent-id
                                           (equal? id selected-intent-id)))
                            (match (alist-ref intent 'match-status 'unassigned))
                            (sp-name (alist-ref intent 'suggested-provider-name #f))
                            (sp-id (alist-ref intent 'suggested-provider #f))
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
                                              "\u26a0 No match")))
                                 (else '()))
                             ;; Accept / Decline buttons for matched intents
                             ,@(if (and (eq? match 'matched) on-accept on-decline)
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
                   intents))))


;;; ═══════════════════════════════════════════════════════════════════════════════
;;;  ICALENDAR EXPORT
;;; ═══════════════════════════════════════════════════════════════════════════════

(define (event->ical evt)
  "Convert a calendar event alist to an iCalendar VEVENT string."
  (let* ((id    (alist-ref evt 'id ""))
         (title (alist-ref evt 'title ""))
         (date  (alist-ref evt 'date ""))
         (sh    (alist-ref evt 'start-hour 0))
         (sm    (alist-ref evt 'start-min 0))
         (eh    (alist-ref evt 'end-hour 0))
         (em    (alist-ref evt 'end-min 0))
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
                                   (cons 'start-hour (cadr start-parts))
                                   (cons 'start-min (caddr start-parts))
                                   (cons 'end-hour (cadr end-parts))
                                   (cons 'end-min (caddr end-parts))
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

(define (render-current-time-line current-ms ws)
  "Red line at current time. Returns (day-offset . sxml) or #f if not this week."
  (let* ((dow (epoch-ms->day-of-week current-ms))
         (current-week (week-start-ms current-ms))
         (hm (epoch-ms->hour-min current-ms))
         (hour (car hm))
         (min (cadr hm))
         (top-px (time->px hour min)))
    (if (= current-week ws)
        (cons dow
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
  (cond ((eq? act 'work) "#9f7aea")
        ((eq? act 'produce) "#38a169")
        ((eq? act 'consume) "#e53e3e")
        ((eq? act 'use) "#d69e2e")
        (else "#8b7b96")))

(define* (render-event-detail-panel evt on-close on-edit on-delete people
                                    process-commitments on-record-effort
                                    process-flows supply-chain
                                    #:key (on-accept-assignment #f)
                                          (on-decline-assignment #f))
  "Right sidebar showing full event detail + VF process context.
   When work-assignment metadata is present, shows assignment section
   with suggested provider and accept/decline actions."
  (let* ((title   (alist-ref evt 'title ""))
         (sh      (alist-ref evt 'start-hour 0))
         (sm      (alist-ref evt 'start-min 0))
         (eh      (alist-ref evt 'end-hour 0))
         (em      (alist-ref evt 'end-min 0))
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
         (match-st (alist-ref evt 'match-status 'unassigned))
         (sp-id    (alist-ref evt 'suggested-provider #f))
         (sp-name  (alist-ref evt 'suggested-provider-name #f))
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
                                  ,@(if (and on-accept-assignment (eq? source 'intent))
                                        `((span (@ (class "cal-btn cal-btn-primary")
                                                   (style "margin-left:auto;font-size:10px;padding:2px 8px;")
                                                   (click ,(lambda (e) (on-accept-assignment evt))))
                                                "Accept")
                                          (span (@ (class "cal-btn")
                                                   (style "font-size:10px;padding:2px 8px;")
                                                   (click ,(lambda (e) (on-decline-assignment evt))))
                                                "Decline"))
                                        '()))
                            `(div (@ (class "cal-assignment-row cal-assignment-unmatched"))
                                  (span "\u26a0 No agent matched for this role")))))
                '())
          ;; VF Process Context
          ,@(if (and is-vf vf-proc)
                (let* ((pct (if (and vf-qty (> vf-qty 0))
                               (min 100 (inexact->exact (round (* (/ vf-fulfilled vf-qty) 100))))
                               0))
                       (fill-color (cond ((>= pct 100) "#38a169")
                                        ((>= pct 50) "#d69e2e")
                                        (else "#e53e3e")))
                       (act-color (cond ((eq? vf-act 'work) "#9f7aea")
                                       ((eq? vf-act 'produce) "#38a169")
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
;;;  COMPOSED PAGE
;;; ═══════════════════════════════════════════════════════════════════════════════

(define* (calendar-page #:key (week-start-ms 0) (events '()) (people '())
                              (availability '()) on-event-click on-slot-click
                              on-prev-week on-next-week on-today
                              on-toggle-person on-toggle-avail-editor
                              (editing-event #f) (editing-availability #f)
                              (selected-event #f) (process-commitments '())
                              on-save-event on-delete-event on-cancel-edit
                              on-close-detail on-edit-from-detail
                              on-delete-from-detail
                              on-save-availability on-cancel-availability
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
                              (on-decline-assignment #f))
  "Compose the full calendar page."
  (let* ((ws week-start-ms)
         ;; Filter events to this week
         (week-dates (map (lambda (offset)
                           (date-parts->date-string
                            (day-offset-date-parts ws offset)))
                         (list 0 1 2 3 4 5 6)))
         ;; Filter by visible people
         (visible-ids (map (lambda (p) (alist-ref p 'id ""))
                           (filter (lambda (p) (alist-ref p 'visible #t)) people)))
         (week-events
          (filter (lambda (evt)
                    (and (member (alist-ref evt 'date "") week-dates)
                         (or (null? people)
                             (member (alist-ref evt 'person "") visible-ids))))
                  events))
         ;; Split into timed and all-day
         (allday-events (filter (lambda (e) (alist-ref e 'all-day #f)) week-events))
         (filtered-events (filter (lambda (e) (not (alist-ref e 'all-day #f))) week-events))
         ;; Today's date string
         (today-date-str (if current-time-ms
                             (date-parts->date-string
                              (epoch-ms->date-parts current-time-ms))
                             #f))
         ;; Current time line
         (time-line (if current-time-ms
                        (render-current-time-line current-time-ms ws)
                        #f))
         (time-line-dow (if time-line (car time-line) -1))
         (time-line-sxml (if time-line (cdr time-line) #f)))
    `(div (@ (class ,(string-append "cal-view"
                                    (if selected-event " cal-view-with-detail" ""))))
          ;; Header with navigation
          ,(render-week-header ws on-prev-week on-next-week on-today on-export)
          ;; Person legend + capacity bar
          ,@(if (null? people) '()
                (list `(div (@ (class "cal-toolbar"))
                            ,(render-person-legend people on-toggle-person)
                            ,(render-capacity-bar filtered-events availability
                                                  people on-toggle-avail-editor))))
          ;; Main body: intents sidebar + (day headers + allday + grid) + detail panel
          (div (@ (class "cal-body"))
               ;; Unscheduled intents sidebar (when in org mode)
               ,@(if (null? unscheduled-intents) '()
                     (list (render-intents-sidebar
                            unscheduled-intents on-select-intent
                            selected-intent-id
                            #:people people
                            #:on-accept on-accept-assignment
                            #:on-decline on-decline-assignment
                            #:stop-prop stop-prop)))
               ;; Grid column: headers + allday + scrollable grid
               (div (@ (class "cal-grid-col"))
                    ;; Day headers (aligned with grid columns)
                    ,(render-day-headers ws today-date-str)
                    ;; All-day events strip
                    ,(render-allday-strip week-dates allday-events on-event-click)
                    ;; Scrollable grid
                    (div (@ (class "cal-grid-wrapper") (id "cal-grid-wrap"))
                    (div (@ (class "cal-grid"))
                         ;; Time column
                         ,(render-time-column)
                         ;; 7 day columns
                         ,@(map (lambda (offset)
                                  (let* ((ds (list-ref week-dates offset))
                                         (day-evts (filter (lambda (e)
                                                             (equal? (alist-ref e 'date "") ds))
                                                           filtered-events))
                                         (dow offset)
                                         (day-avail (filter (lambda (a)
                                                              (= (alist-ref a 'day 0) dow))
                                                            availability))
                                         (day-time-line (if (= offset time-line-dow)
                                                            time-line-sxml #f))
                                         (is-today (and today-date-str
                                                        (string=? ds today-date-str))))
                                    (render-day-column ds day-evts day-avail people
                                                       on-slot-click on-event-click
                                                       on-cycle-status
                                                       day-time-line is-today stop-prop)))
                                (list 0 1 2 3 4 5 6)))))
               ;; Detail panel (right sidebar)
               ,@(if selected-event
                     (list (render-event-detail-panel
                            selected-event on-close-detail
                            on-edit-from-detail on-delete-from-detail
                            people process-commitments on-record-effort
                            process-flows supply-chain
                            #:on-accept-assignment on-accept-assignment
                            #:on-decline-assignment on-decline-assignment))
                     '()))
          ;; Modal overlays
          ,@(if editing-event
                (list (render-event-editor editing-event
                                           on-save-event on-delete-event on-cancel-edit
                                           stop-prop))
                '())
          ,@(if editing-availability
                (list (render-availability-editor availability
                                                  on-save-availability
                                                  on-cancel-availability))
                '()))))
