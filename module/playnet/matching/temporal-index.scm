;;; matching/temporal-index.scm — Time-bucketed index over intent-bindings.
;;;
;;; Three buckets: one-time (by YYYY-MM), recurring (by pattern),
;;; timeless (no temporal info). All operations are pure — insert,
;;; remove, and query return new index values.

(define-module (playnet matching temporal-index)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond schedules)
  #:use-module (srfi srfi-1)
  #:use-module (playnet matching schemas)
  #:export (make-temporal-index
            temporal-index?
            temporal-index-insert
            temporal-index-remove
            temporal-index-query
            temporal-index-all
            temporal-index-size))


(define-record-type <temporal-index>
  (%make-temporal-index one-time recurring timeless)
  temporal-index?
  (one-time  ti-one-time)
  (recurring ti-recurring)
  (timeless  ti-timeless))

(define (make-temporal-index)
  (%make-temporal-index (hashmap) (hashmap) '()))


;;; ── Classification ──────────────────────────────────────────────────────────

(define (non-empty? accessor record)
  (let ((v (accessor record))) (and v (not (null? v)))))

(define (recurrence-key aw)
  "Recurrence bucket key from an availability-window, or #f if not recurring."
  (and aw
       (cond
         ((non-empty? availability-window-month-schedules aw) "monthly")
         ((non-empty? availability-window-week-schedules aw)  "weekly")
         ((non-empty? availability-window-day-schedules aw)   "daily")
         (else #f))))

(define (month-key date-str)
  (and date-str (string? date-str) (>= (string-length date-str) 7)
       (substring date-str 0 7)))

(define (classify-binding b)
  "Returns (bucket . key) — one-time, recurring, or timeless."
  (let* ((i  (intent-binding-intent b))
         (rk (recurrence-key (intent-availability-window i)))
         (mk (month-key (or (intent-has-beginning i)
                            (intent-has-point-in-time i)))))
    (cond (rk (cons 'recurring rk))
          (mk (cons 'one-time  mk))
          (else '(timeless . #f)))))


;;; ── Hashmap helpers ─────────────────────────────────────────────────────────

(define (hm-prepend hm key val)
  (hashmap-set hm key (cons val (hashmap-ref hm key '()))))

(define (hm-filter-out hm key pred)
  (let ((kept (filter pred (hashmap-ref hm key '()))))
    (if (null? kept) (hashmap-remove hm key) (hashmap-set hm key kept))))

(define (hm-values hm)
  (hashmap-fold (lambda (_ v acc) (append v acc)) '() hm))


;;; ── Insert / Remove ─────────────────────────────────────────────────────────

(define (temporal-index-insert idx b)
  (let* ((class (classify-binding b))
         (kind  (car class))
         (key   (cdr class))
         (ot (ti-one-time idx)) (rc (ti-recurring idx)) (tl (ti-timeless idx)))
    (case kind
      ((one-time)  (%make-temporal-index (hm-prepend ot key b) rc tl))
      ((recurring) (%make-temporal-index ot (hm-prepend rc key b) tl))
      ((timeless)  (%make-temporal-index ot rc (cons b tl))))))

(define (temporal-index-remove idx b)
  (let* ((bid   (intent-id (intent-binding-intent b)))
         (keep? (lambda (x) (not (equal? (intent-id (intent-binding-intent x)) bid))))
         (class (classify-binding b))
         (kind  (car class))
         (key   (cdr class))
         (ot (ti-one-time idx)) (rc (ti-recurring idx)) (tl (ti-timeless idx)))
    (case kind
      ((one-time)  (%make-temporal-index (hm-filter-out ot key keep?) rc tl))
      ((recurring) (%make-temporal-index ot (hm-filter-out rc key keep?) tl))
      ((timeless)  (%make-temporal-index ot rc (filter keep? tl))))))


;;; ── Query ───────────────────────────────────────────────────────────────────

(define (months-in-range start end)
  "Enumerate YYYY-MM keys between START and END (ISO strings), inclusive."
  (let ((sk (month-key start)) (ek (month-key end)))
    (if (or (not sk) (not ek) (string>? sk ek)) '()
        (let loop ((y (string->number (substring sk 0 4)))
                   (m (string->number (substring sk 5 7)))
                   (acc '()))
          (let ((key (string-append (number->string y) "-"
                                    (if (< m 10) "0" "")
                                    (number->string m))))
            (if (string>? key ek) (reverse acc)
                (loop (if (= m 12) (+ y 1) y)
                      (if (= m 12) 1 (+ m 1))
                      (cons key acc))))))))

(define (temporal-index-query idx time-range)
  "One-time slots from matching months + ALL recurring + ALL timeless."
  (let ((ot (ti-one-time idx)))
    (append (append-map (lambda (mk) (hashmap-ref ot mk '()))
                        (months-in-range (car time-range) (cdr time-range)))
            (hm-values (ti-recurring idx))
            (ti-timeless idx))))

(define (temporal-index-all idx)
  (append (hm-values (ti-one-time idx))
          (hm-values (ti-recurring idx))
          (ti-timeless idx)))

(define (temporal-index-size idx)
  (+ (length (hm-values (ti-one-time idx)))
     (length (hm-values (ti-recurring idx)))
     (length (ti-timeless idx))))
