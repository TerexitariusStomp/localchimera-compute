;;; brief.scm — pure projection for the browser orb (planner → narration).
;;;
;;; Two pure functions, no Goblins / no engine, so they unit-test in isolation:
;;;
;;;   parse-overrides   — a what-if spec (a JSON string from the browser, or a
;;;                       Scheme alist) → a symbol-keyed alist of plan-scope
;;;                       inputs (demand / eco-caps / reserve / tau). Hoot has no
;;;                       JSON reader, so the browser ships the raw string and we
;;;                       parse it HERE, where json-string->scm lives.
;;;   plan-brief->string — a plan-results alist (met / social / prices /
;;;                       certificate) → a compact prose brief the orb narrates.
;;;                       Numbers ride as-is (~a) — the orb reads, never computes.
;;;
;;; The convex JSON writer in day-boot emits integers only and the report carries
;;; non-string keys, so a STRING brief sidesteps serialization entirely.

(define-module (playnet planner doors service brief)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)            ; string-join
  #:use-module (ice-9 format)
  #:use-module ((playnet utils common) #:select (take-up-to))
  ;; json-string->scm lives in (json parser); guile-json's (json) only
  ;; re-exports it via module-use!, so a #:select from (json) fails to resolve.
  #:use-module ((json parser) #:select (json-string->scm))
  #:export (parse-overrides plan-brief->string))


(define (parse-overrides overrides)
  "Normalize OVERRIDES — a JSON string (browser) or an alist (Scheme) — to a
   symbol-keyed alist. Unparseable / non-alist input yields '()."
  (let ((o (cond ((string? overrides)
                  (catch #t (lambda () (json-string->scm overrides)) (lambda _ '())))
                 ((pair? overrides) overrides)
                 (else '()))))
    (if (list? o)
        (filter-map
          (lambda (kv)
            (and (pair? kv)
                 (cons (if (string? (car kv)) (string->symbol (car kv)) (car kv))
                       (cdr kv))))
          o)
        '())))

(define (plan-brief->string full)
  "Render a plan-results alist (met / social / prices / certificate) as a
   compact prose brief for the orb to narrate."
  (let ((s (or (assq-ref full 'social) '())))
    (string-append
      (format #f "satisfaction (met): ~a~%" (assq-ref full 'met))
      (format #f "free time f: ~a   (free ~a h of ~a h available)~%"
              (assq-ref s 'free-time) (assq-ref s 'free) (assq-ref s 'available))
      (format #f "labour: direct ~a h · transport ~a h · training ~a h~%"
              (assq-ref s 'direct-labour) (assq-ref s 'transport) (assq-ref s 'training))
      "loudest pulls λ(skill@cell):\n"
      (string-join
        (map (lambda (p) (format #f "  ~a: ~a" (car p) (cdr p)))
             ;; a result may carry (labour-pulls . #f) — a multi-period solve with
             ;; no binding pulls — and a brief renders every legal result
             (take-up-to (or (assq-ref full 'labour-pulls) '()) 6))
        "\n")
      (format #f "~%certificate: ~a" (assq-ref full 'certificate)))))
