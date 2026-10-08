;;; scope-probe.scm — a whole scope, run by the browser build.
;;;
;;; The page's own scope ((playnet planner doors page-scope)): a scope root with its
;;; observer and stores, the demo neighbourhood seeded into it and its acts
;;; played, then the page's doors asked. `make check-hoot-scope` proves the scope
;;; still compiles for Hoot; `make hoot-probe-scope` runs it under node.
;;;
;;; Then the planner's solve over a scope root, on the reference core a page has:
;;; the bread town seeded into a second root and planned for ten loaves.
;;;
;;; Logs, in order: the length of what `open` answers; the length of the snapshot's
;;; JSON; 1 when a count through the door is answered and 0 when it is refused;
;;; how many counts the counted stock's history then holds; then 1 when the plan
;;; is feasible, how far its demand is met, and the milliseconds the solve took.

(use-modules (hoot ffi)
             (goblins)
             (playnet planner doors page-scope)
             ((playnet planner scope root) #:select (spawn-scope-root))
             ((playnet planner knowledge dsl world) #:select (seed-world!))
             ((playnet planner knowledge recipes bread-commune-seed) #:select (bread-world))
             ((playnet planner scope live) #:select (plan-scope->alist))
             ((playnet utils json-portable) #:select (json-read-ordered)))

(define-foreign %log "console" "log" f64 -> none)

;; 2026-01-05T12:00:00Z
(define opened (page-door "open" '("1767614400")))
(%log (exact->inexact (string-length opened)))
(%log (exact->inexact (string-length (page-door "snapshot" '()))))
(define landed (page-door "countStock" '("demo:tea" "7" "box" "stated" "place:teahouse" "" "" "" "")))
(%log (if (and (> (string-length landed) 4) (not (string=? "err:" (substring landed 0 4)))) 1.0 0.0))
(%log (exact->inexact
       (vector-length (cdr (assoc "rows" (json-read-ordered (page-door "countHistory" '("demo:tea" ""))))))))

;; the solve: then log 1 when the plan is feasible, how far the demand is met, and the milliseconds it took
(define-foreign %now "performance" "now" -> f64)
(define town-vat (spawn-vat))
(define town (with-vat town-vat (let ((root (spawn-scope-root "town"))) (seed-world! root bread-world) root)))
(define t0 (%now))
(define plan (with-vat town-vat (plan-scope->alist town #:demand '(("bread#town@0" . 10.0)))))
(%log (if (assq-ref plan 'feasible) 1.0 0.0))
(%log (exact->inexact (or (assq-ref plan 'met) 0)))
(%log (- (%now) t0))
