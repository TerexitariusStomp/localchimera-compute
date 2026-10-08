;;; test-solve-brief.scm — the orb's pure projection: (playnet planner doors service brief).
;;;
;;; parse-overrides (what-if JSON/alist → plan-scope inputs) and
;;; plan-brief->string (plan-results alist → narration prose) are pure, so they
;;; test with synthetic data — no vat, no scope, no blake3.
;;;
;;; Run:  guile -L module tests/planner/test-solve-brief.scm

(use-modules (playnet test harness)
             (playnet planner doors service brief)
             (srfi srfi-13))          ; string-contains

(format #t "~%── parse-overrides ──~%")
(check "JSON string → symbol-keyed"
       (assq-ref (parse-overrides "{\"tau\":0.1,\"reserve\":3}") 'tau) 0.1)
(check "JSON nested object preserved"
       (parse-overrides "{\"eco-caps\":{\"water\":500}}")
       '((eco-caps ("water" . 500))))
(check "alist passes through"
       (parse-overrides '((demand . 7))) '((demand . 7)))
(check "unparseable JSON → empty" (parse-overrides "not json") '())
(check "non-string non-alist → empty" (parse-overrides 42) '())

(format #t "~%── plan-brief->string ──~%")
(define sample
  '((met . 0.78)
    (social . ((direct-labour . 700.2) (transport . 45.0) (training . 30.0)
               (available . 2100.0) (free . 1234.5) (free-time . 0.58)))
    (labour-pulls . (("surgery@clinic" . 12.3) ("baking@bakery" . 8.1) ("childcare@hall" . 6.4)))
    (certificate . "interior-point t=0.02 gap<=0.1")))
(define brief (plan-brief->string sample))
(format #t "~a~%~%" brief)
(check "brief is a string"       (string? brief))
(check "carries satisfaction"    (string-contains brief "satisfaction (met): 0.78"))
(check "carries free time"       (string-contains brief "free time f: 0.58"))
(check "carries a labour line"   (string-contains brief "direct 700.2 h"))
(check "carries the top pull"    (string-contains brief "surgery@clinic: 12.3"))
(check "carries the certificate" (string-contains brief "gap<=0.1"))
(check "missing social degrades gracefully"
       (string? (plan-brief->string '((met . 1.0) (labour-pulls . ()) (certificate . "x")))))

(test-summary!)
