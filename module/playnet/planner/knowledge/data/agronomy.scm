;;; agronomy.scm — crop constants + the water-response model, ONE source of truth for
;;; process-multipliers.scm and emit-derived.scm. FAO Irrigation & Drainage Paper 33:
;;; relative yield loss (1 − Ya/Ym) = Ky · (1 − ETa/ETm). Guile-native (no Python).

(define-module (agronomy)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 rdelim)
  #:export (crop-multiplier multipliers national-yields))

;; crop → (Ky . waterlogging-penalty). Rice's effective rainfed Ky > its tabulated ~1.0
;; (paddy is acutely water-dependent); legumes hate standing water.
(define *KY*
  '(("rice" 1.20 . 0.00) ("maize" 1.25 . 0.10) ("wheat" 1.05 . 0.10)
    ("ragi" 0.90 . 0.05) ("millet" 0.90 . 0.05) ("pulses" 0.90 . 0.20)
    ("bean" 1.15 . 0.20) ("pea" 1.15 . 0.20) ("sorghum" 0.90 . 0.05)
    ("soybean" 0.85 . 0.15) ("potato" 1.10 . 0.10) ("groundnut" 0.70 . 0.10)
    ("sunflower" 0.95 . 0.05) ("cotton" 0.85 . 0.05)))
(define *mult-floor* 0.10)    ; a scenario multiplier never drops below this (the tail)

;; yield multiplier for a crop at relative water = rain_scenario / rain_normal.
;; deficit → Ky-scaled loss; surplus → waterlogging penalty (0 for rice).
(define (crop-multiplier crop rel-water)
  (let* ((e (or (assoc crop *KY*) '(#f 1.0 . 0.10)))
         (ky (cadr e)) (wlog (cddr e)))
    (max *mult-floor*
         (if (< rel-water 1.0)
             (- 1.0 (* ky (- 1.0 rel-water)))
             (- 1.0 (* wlog (- rel-water 1.0)))))))

;; ((scenario (crop . mult) …) …) from per-class rainfall + a crop list.
(define (multipliers rain-by-class crops)
  (let ((ref (let ((n (assoc-ref rain-by-class "normal"))) (if (and n (> n 0)) n 1.0))))
    (map (lambda (scen)
           (cons scen (map (lambda (c) (cons c (crop-multiplier c (/ (assoc-ref rain-by-class scen) ref))))
                           crops)))
         '("normal" "drought" "flood"))))

;; ((crop . kg/ha) …) from OWID yield CSVs — mean of the last `recent` years for
;; `country`. Crop name = file slug (yield-rice.csv → rice); OWID is t/ha (×1000).
(define* (national-yields country csv-paths #:optional (recent 5))
  (filter-map
   (lambda (path)
     (let* ((rows (call-with-input-file path
                    (lambda (p) (let loop ((acc '()))
                                  (let ((l (read-line p))) (if (eof-object? l) (reverse acc)
                                                               (loop (cons (string-split l #\,) acc))))))))
            (crop (let ((b (basename path)))
                    (substring b (string-length "yield-") (- (string-length b) (string-length ".csv")))))
            (ycol (if (> (length (car rows)) 3) 3 (- (length (car rows)) 1)))
            (ser (sort (filter-map
                        (lambda (r) (and (> (length r) ycol) (equal? (car r) country)
                                         (string->number (list-ref r ycol))
                                         (cons (string->number (list-ref r 2))
                                               (string->number (list-ref r ycol)))))
                        (cdr rows))
                       (lambda (a b) (< (car a) (car b))))))
       (and (pair? ser)
            (cons crop (* 1000.0 (/ (apply + (map cdr (take-right ser (min recent (length ser)))))
                                    (min recent (length ser))))))))
   csv-paths))
