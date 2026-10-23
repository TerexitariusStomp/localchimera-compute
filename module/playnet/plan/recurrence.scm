;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; recurrence.scm — Per-occurrence fulfillment tracking for recurring commitments

(define-module (playnet plan recurrence)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond schedules)
  #:use-module (playnet utils store-utils)
  #:export (occurrence-date-key group-events-by-occurrence get-occurrence-status
            date-matches-window epoch->iso-date materialize-occurrence-dates
            unfulfilled-occurrences)
  #:use-module (srfi srfi-1))


(define (occurrence-date-key event)
  "Extract YYYY-MM-DD from event timestamps. Returns string or #f."
  (let ((ts (or (economic-event-has-point-in-time event)
                (economic-event-has-beginning event)
                (economic-event-created event))))
    (and ts (>= (string-length ts) 10) (substring ts 0 10))))

(define (group-events-by-occurrence events)
  "Group events by date key. Returns alist of (date . event-list)."
  (let ((groups (make-hash-table)))
    (for-each
      (lambda (e)
        (let ((key (occurrence-date-key e)))
          (when key
            (hash-set! groups key (cons e (hash-ref groups key '()))))))
      events)
    (hash-map->list cons groups)))

(define (get-occurrence-status commitment events-by-occurrence)
  "For each date with events, compare fulfilled vs committed qty.
   Returns alist of (date . ((fulfilled . n) (committed . n) (complete . bool)))."
  (let ((committed-qty (if (commitment-resource-quantity commitment)
                           (measure-has-numerical-value (commitment-resource-quantity commitment))
                           0)))
    (map (lambda (pair)
           (let* ((date (car pair))
                  (events (cdr pair))
                  (fulfilled (fold (lambda (e acc)
                                    (+ acc (if (economic-event-resource-quantity e)
                                               (measure-has-numerical-value
                                                 (economic-event-resource-quantity e))
                                               0)))
                                  0 events)))
             (cons date `((fulfilled . ,fulfilled)
                          (committed . ,committed-qty)
                          (complete . ,(>= fulfilled committed-qty))))))
         events-by-occurrence)))

(define (date-matches-window iso-date window)
  "Check if YYYY-MM-DD falls within an AvailabilityWindow pattern.
   Checks month_schedules > week_schedules > day_schedules > time_ranges."
  ;; Parse date components
  (let* ((year (string->number (substring iso-date 0 4)))
         (month (string->number (substring iso-date 5 7)))
         (day (string->number (substring iso-date 8 10)))
         ;; Day of week (Zeller's algorithm, simplified)
         (dow (let* ((m (if (< month 3) (+ month 12) month))
                     (y (if (< month 3) (- year 1) year))
                     (h (modulo (+ day (quotient (* 13 (+ m 1)) 5)
                                   y (quotient y 4) (- (quotient y 100))
                                   (quotient y 400)) 7)))
                ;; Convert: 0=Sat, 1=Sun, 2=Mon...
                (list-ref '(saturday sunday monday tuesday wednesday thursday friday) h)))
         (week-of-month (+ 1 (quotient (- day 1) 7))))
    ;; Check availability-window levels
    (let ((ms (and (availability-window? window) (availability-window-month-schedules window)))
          (ws (and (availability-window? window) (availability-window-week-schedules window)))
          (ds (and (availability-window? window) (availability-window-day-schedules window)))
          (tr (and (availability-window? window) (availability-window-time-ranges window))))
      (cond
        ;; Level 1: month-specific
        ((and ms (pair? ms))
         (any (lambda (ms-entry)
                (and (= (month-schedule-month ms-entry) month)
                     ;; Check week/day schedules within month
                     (or (let ((wss (month-schedule-week-schedules ms-entry)))
                           (and wss (any (lambda (ws-entry)
                                           (and (member week-of-month (week-schedule-weeks ws-entry))
                                                (any (lambda (ds-entry)
                                                       (member dow (day-schedule-days ds-entry)))
                                                     (week-schedule-day-schedules ws-entry))))
                                         wss)))
                         (let ((dss (month-schedule-day-schedules ms-entry)))
                           (and dss (any (lambda (ds-entry)
                                           (member dow (day-schedule-days ds-entry)))
                                         dss)))
                         (month-schedule-time-ranges ms-entry))))  ;; any day in month
              ms))
        ;; Level 2: week-specific
        ((and ws (pair? ws))
         (any (lambda (ws-entry)
                (and (member week-of-month (week-schedule-weeks ws-entry))
                     (any (lambda (ds-entry) (member dow (day-schedule-days ds-entry)))
                          (week-schedule-day-schedules ws-entry))))
              ws))
        ;; Level 3: day-specific
        ((and ds (pair? ds))
         (any (lambda (ds-entry) (member dow (day-schedule-days ds-entry))) ds))
        ;; Level 4: time-ranges (any day matches)
        ((and tr (pair? tr)) #t)
        (else #f)))))

(define (epoch->iso-date epoch)
  "Convert Unix epoch to YYYY-MM-DD string (Howard Hinnant civil_from_days)."
  (let* ((z (+ (quotient epoch 86400) 719468))
         (era (quotient (if (>= z 0) z (- z 146096)) 146097))
         (doe (- z (* era 146097)))
         (yoe (quotient (- doe (+ (quotient doe 1460)
                                  (- (quotient doe 36524))
                                  (quotient doe 146096)))
                        365))
         (y (+ yoe (* era 400)))
         (doy (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
         (mp (quotient (+ (* 5 doy) 2) 153))
         (d (+ 1 (- doy (quotient (+ (* 153 mp) 2) 5))))
         (m (+ mp (if (< mp 10) 3 -9)))
         (y (if (<= m 2) (+ y 1) y)))
    (format #f "~4,'0d-~2,'0d-~2,'0d" y m d)))

(define (materialize-occurrence-dates window from to)
  "Enumerate all dates in [from, to] matching the window pattern.
   from, to: YYYY-MM-DD strings."
  (let ((from-epoch (iso-datetime->epoch (string-append from "T00:00:00Z")))
        (to-epoch (iso-datetime->epoch (string-append to "T00:00:00Z"))))
    (let loop ((epoch from-epoch) (dates '()))
      (if (> epoch to-epoch) (reverse dates)
          (let ((date-str (epoch->iso-date epoch)))
            (loop (+ epoch 86400)
                  (if (date-matches-window date-str window)
                      (cons date-str dates)
                      dates)))))))

(define (unfulfilled-occurrences window from to events-by-occurrence)
  "Dates that should have events but don't."
  (let ((expected (materialize-occurrence-dates window from to))
        (actual-dates (map car events-by-occurrence)))
    (filter (lambda (d) (not (member d actual-dates))) expected)))
