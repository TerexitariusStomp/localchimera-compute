;;; test-limit-roster.scm — the form each ecological limit is carried in, against
;;; the form its reversibility implies.
;;;
;;; A natural limit lives in this engine in one of two forms, differing in exactly
;;; the respect that matters — whether headroom can be REGAINED:
;;;
;;;   FRAGILITY  headroom = tip − prior, and the prior only ever rises.
;;;   STOCK      headroom IS a level: S[t+1] = S[t] − draw + restore.
;;;
;;; Only the second can express recovery, so restoration labour (see
;;; restoration-recipe-test) buys headroom there and nowhere else.
;;;
;;; Which form a limit BELONGS in is a physical question, and it is answered by
;;; witness table 3 (*limit-reversibility*) — cited, DRAFT, ratifiable — NOT by α.
;;; eco-catalogue.scm calls the α values "political-economic choices, NOT
;;; engineering constants": α says where in a range the operative tip stands.
;;; Reading it as a physical property conflates the two categories the file
;;; separates, and the entries show why — "warming" carries α=0 annotated
;;; "irreversible", yet what is irreversible are the ELEMENTS crossing 1.5 °C
;;; commits us to, while warming itself tracks cumulative CO2.
;;;
;;; So this suite checks the two facts against each other: every constrained limit
;;; has a cited reversibility, and no limit is carried in a form its physics
;;; contradicts.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/planner/test-limit-roster.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner formulas stocks))
(use-modules (playnet planner knowledge catalogues eco))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

;; the live registry answers which specs are carried as regenerating stocks
(define (stock? spec) (and (regenerating-stock-ref spec) #t))
(define roster (limit-roster *planetary-catalogue* stock?))

(format #t "~%── the federation's ecological limits, by representation ──~%~%")
(format #t "  ~20a ~6a ~11a ~24a ~a~%" "spec" "alpha" "carried as" "reversibility" "implies / verdict")
(format #t "  ~20a ~6a ~11a ~24a ~a~%" "────" "─────" "──────────" "────────────────────────" "────────────────")
(for-each (lambda (r)
            (format #t "  ~20a ~6a ~11a ~24a ~a / ~a~%"
                    (list-ref r 0) (list-ref r 1) (list-ref r 3) (list-ref r 4)
                    (list-ref r 5) (list-ref r 6)))
          roster)

(define migrate    (roster-of-verdict roster 'migrate))
(define overstated (roster-of-verdict roster 'overstated))
(define unjudged   (roster-of-verdict roster 'unjudged))
(define witnessed  (witnessed-tipping-characters))
(define irreversible-elements (filter (lambda (w) (eq? (cadr w) 'irreversible)) witnessed))

(format #t "~%")
(check "every constrained limit is carried in one of the two forms"
       (every (lambda (r) (memq (list-ref r 3) '(stock fragility))) roster))

;; The gap this table was added to close.
(check "every constrained limit now has a CITED reversibility"
       (null? unjudged))

(check "each recorded reversibility carries a source and a note"
       (every (lambda (r) (and (= (length r) 5)
                               (string? (list-ref r 3)) (string? (list-ref r 4))
                               (> (string-length (list-ref r 3)) 40)))
              *limit-reversibility*))

;; The hard invariant: nothing may be carried as a restorable level unless its
;; physics says it returns within reach. Otherwise the plan could schedule labour
;; against a fact.
(check "no limit is carried as a stock that its physics does not support"
       (null? overstated))

;; α stays a precaution dial and is reported as one — both postures in use, and
;; NOT read as a reversibility claim.
;; α rides through as the governed number it is. No threshold buckets it, so
;; there is no invented constant here to assert about — only that the catalogue
;; really does set it per limit rather than uniformly.
(check "α is carried per-limit, as the governed dial it is"
       (> (length (delete-duplicates (map (lambda (r) (list-ref r 1)) roster))) 1))

;; The correction that motivated the table: the two α=0 limits are NOT absorbing.
(check "warming is recorded reversible-with-removal, not irreversible"
       (eq? 'reversible-with-removal (reversibility-character "warming")))
(check "ocean-acidification likewise — surface Ω recovers as CO2 falls"
       (eq? 'reversible-with-removal (reversibility-character "ocean-acidification")))

;; …while the genuinely absorbing objects remain witnessed, not constrained.
(check "the irreversible tipping elements are witnessed, never solver barriers"
       (and (pair? irreversible-elements)
            (every (lambda (w) (not (assoc (car w) roster))) irreversible-elements)))

(format #t "~%── outstanding: the raw→stock migration ──~%")
(if (null? migrate)
    (format #t "  none — every limit that returns is carried where it can be seen to.~%")
    (for-each (lambda (r)
                (format #t "  ~a — ~a (~a yr): returns, yet its prior only rises,~%"
                        (list-ref r 0) (list-ref r 4) (reversibility-years (list-ref r 0)))
                (format #t "     so restoration labour cannot buy headroom back.~%"))
              migrate))

(format #t "~%── the sources, for ratification ──~%")
(for-each (lambda (r) (format #t "  ~a — ~a~%     ~a~%" (car r) (list-ref r 1) (list-ref r 3)))
          *limit-reversibility*)

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — reversibility is WITNESSED and cited, α stays a~%  governed dial, and the roster reads each limit against its own physics.~%  ~a limit(s) await the raw→stock migration.~%"
            *pass* (length migrate))
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
