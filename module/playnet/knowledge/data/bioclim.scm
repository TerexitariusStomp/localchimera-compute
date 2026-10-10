;;; bioclim.scm — a bioregion's rainfall SCENARIOS from its precipitation record.
;;; ONE source of truth, shared by process.scm / process-multipliers.scm / emit-derived.scm.
;;; GENERAL: any location; reproducible: same raw ⇒ same numbers. Guile-native (guile-json
;;; + SRFI) — the same language as the planner it feeds; no Python.
;;;
;;; monthly totals → climatology → growing season (auto | given | annual) → each year's
;;; growing-season rainfall → the IMD ±1σ classification (drought/normal/flood), local.

(define-module (bioclim)
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module (srfi srfi-1)
  #:export (scenarios scen-ref scen-counts scen-rain-by-class temp-climatology warm-quarter-temp annual-mean-temp))

(define (read-json path)
  (json-string->scm (call-with-input-file path get-string-all)))


;;; ─── how warm it is where the work happens ───────────────────────────────
;;; A shed's TEMPERATURE record, reduced to the two figures anything about
;;; working bodies needs. Last decade by default, because a warming trend makes
;;; the sixty-year mean the wrong answer.
;;;
;;; Deliberately NOT the auto-detected growing season: that season is detected
;;; from RAINFALL, and in a Mediterranean shed the wet season is the cold one —
;;; Cascadia's is November–March. Averaging over it would report that nobody
;;; there ever works warm. The warmest quarter (the standard bioclim BIO10, the
;;; warmest three consecutive months) is season-detection-independent and is the
;;; anchor a sweat rate actually wants.
(define (temp-climatology temp-json since)
  "Mean temperature per calendar month (a 12-vector, index 0 = January)."
  (let* ((D  (assoc-ref (read-json temp-json) "daily"))
         (ds (vector->list (assoc-ref D "time")))
         (ts (vector->list (assoc-ref D "temperature_2m_mean")))
         (by (make-vector 12 '())))
    (for-each (lambda (d t)
                (when (and (num? t) (>= (string->number (substring d 0 4)) since))
                  (let ((m (- (string->number (substring d 5 7)) 1)))
                    (vector-set! by m (cons t (vector-ref by m))))))
              ds ts)
    (list->vector (map (lambda (m) (mean (vector-ref by m))) (iota 12)))))

(define* (warm-quarter-temp temp-json #:optional (since 2014))
  "Mean temperature of the warmest three consecutive months (°C) — bioclim BIO10."
  (let ((C (temp-climatology temp-json since)))
    (apply max (map (lambda (m)
                      (mean (map (lambda (k) (vector-ref C (modulo (+ m k) 12)))
                                 '(0 1 2))))
                    (iota 12)))))

(define* (annual-mean-temp temp-json #:optional (since 2014))
  "Mean temperature across the whole year (°C)."
  (mean (vector->list (temp-climatology temp-json since))))


(define (num? x) (and (number? x) (not (nan? x))))
(define (mean xs) (if (null? xs) 0.0 (/ (apply + xs) (length xs))))
(define (pstdev xs)
  (if (< (length xs) 1) 0.0
      (let ((m (mean xs))) (sqrt (mean (map (lambda (x) (expt (- x m) 2)) xs))))))

;; (year . month) → total precipitation; and the climatological mean of each month.
(define (monthly precip)
  (let* ((daily (assoc-ref precip "daily"))
         (times (vector->list (assoc-ref daily "time")))
         (prs   (vector->list (assoc-ref daily "precipitation_sum")))
         (ym    (make-hash-table)))
    (for-each (lambda (t p)
                (when (num? p)
                  (let ((k (cons (string->number (substring t 0 4))
                                 (string->number (substring t 5 7)))))
                    (hash-set! ym k (+ (hash-ref ym k 0.0) p)))))
              times prs)
    ym))

(define (climatology ym)             ; ((month . mean-monthly-total) …) for 1..12
  (let ((all (hash-map->list cons ym)))
    (map (lambda (m)
           (cons m (mean (filter-map (lambda (kv) (and (= (cdar kv) m) (cdr kv))) all))))
         (iota 12 1))))

;; the growing season. arg: #f → AUTO (months above the mean month); "annual" → all 12;
;; "m,m,…" → given. Returns (values months how).
(define (wet-months clim arg)
  (cond ((and arg (not (string=? arg "annual")))
         (values (map string->number (string-split arg #\,)) "given"))
        ((equal? arg "annual") (values (iota 12 1) "annual"))
        (else (let* ((thresh (/ (apply + (map cdr clim)) 12.0))
                     (ms (filter-map (lambda (mc) (and (> (cdr mc) thresh) (car mc))) clim)))
                (values (if (null? ms) (iota 12 1) ms) "auto-detected")))))

;; A bioregion's classified growing-season rainfall — the object process*/emit read.
;; Returns an alist: months how season(year→total) years mean sd n.
(define* (scenarios precip-path #:optional arg)
  (let ((ym (monthly (read-json precip-path))))
    (call-with-values (lambda () (wet-months (climatology ym) arg))
      (lambda (months how)
        (let* ((season (make-hash-table)))
          (hash-for-each (lambda (k v)
                           (when (memv (cdr k) months)
                             (hash-set! season (car k) (+ (hash-ref season (car k) 0.0) v))))
                         ym)
          (let* ((years (sort (hash-map->list (lambda (k v) k) season) <))
                 (vals  (map (lambda (y) (hash-ref season y)) years)))
            (list (cons 'months months) (cons 'how how) (cons 'season season)
                  (cons 'years years) (cons 'mean (mean vals))
                  (cons 'sd (pstdev vals)) (cons 'n (length years)))))))))

(define (scen-ref s k) (assoc-ref s k))
(define (scen-class s y)             ; "drought" | "normal" | "flood" for a year
  (let ((v (hash-ref (scen-ref s 'season) y)) (m (scen-ref s 'mean)) (sd (scen-ref s 'sd)))
    (cond ((< v (- m sd)) "drought") ((> v (+ m sd)) "flood") (else "normal"))))

(define (scen-counts s)              ; (drought normal flood) year counts
  (let* ((years (scen-ref s 'years))
         (d (count (lambda (y) (string=? (scen-class s y) "drought")) years))
         (f (count (lambda (y) (string=? (scen-class s y) "flood")) years)))
    (list d (- (scen-ref s 'n) d f) f)))

(define (scen-rain-by-class s)       ; ((drought . mm) (normal . mm) (flood . mm))
  (let ((years (scen-ref s 'years)))
    (map (lambda (c)
           (let ((vs (filter-map (lambda (y) (and (string=? (scen-class s y) c)
                                                  (hash-ref (scen-ref s 'season) y))) years)))
             (cons c (if (null? vs) (scen-ref s 'mean) (mean vs)))))
         '("drought" "normal" "flood"))))
