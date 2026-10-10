;;; process-multipliers.scm — per-scenario crop yield MULTIPLIERS from the bioregion's
;;; OWN rainfall scenarios (bioclim.scm) × FAO Ky (agronomy.scm). Guile-native.
;;;
;;;   guile process-multipliers.scm [PRECIP_JSON] [CROPS] [WET_MONTHS]
;;;   guile process-multipliers.scm raw/doon/precip.json rice,maize,ragi,pulses

(add-to-load-path (dirname (current-filename)))
(define here (dirname (current-filename)))
(use-modules (bioclim) (agronomy) (ice-9 format) (srfi srfi-1))
(define (rnd x) (inexact->exact (round x)))

(define args (cdr (command-line)))
(define path  (if (> (length args) 0) (list-ref args 0) "raw/doon/precip.json"))
(define crops (if (> (length args) 1) (string-split (list-ref args 1) #\,) '("rice" "maize" "ragi" "pulses")))
(define arg   (and (> (length args) 2) (list-ref args 2)))
(define S     (scenarios path arg))
(define rain  (scen-rain-by-class S))
(define mult  (multipliers rain crops))
(define label (basename (dirname path)))

(format #t "[~a] scenario rainfall (mm): drought ~a / normal ~a / flood ~a~%"
        label (rnd (assoc-ref rain "drought")) (rnd (assoc-ref rain "normal")) (rnd (assoc-ref rain "flood")))
(format #t ";; per-scenario yield multipliers from FAO Ky × the local rainfall record:~%")
(for-each (lambda (scen)
            (format #t "  ;; ~a:  ~a~%" scen
                    (string-join (map (lambda (cm) (format #f "(~s . ~,2f)" (car cm) (cdr cm)))
                                      (assoc-ref mult scen)) " ")))
          '("normal" "drought" "flood"))
(format #t "→ replaces worlds/doon-valley.scm's [ESTIMATE] multipliers (crop names → your recipe ids).~%")
