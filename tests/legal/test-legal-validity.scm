;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-legal-validity.scm — a rule that MATCHES is not always a rule that STANDS.
;;;
;;; The fold used to filter on one thing: does the guard match? So a rule with a
;;; sunset clause, a transitional provision or a start date the future had not
;;; reached yet fired anyway — silently, and in whichever direction the pack
;;; happened to be wrong.
;;;
;;; `as-of` was already carried, serialized and shown on the law face; `until` is
;;; its other half. Both are read by `legal-demands #:as-of`, which the gate now
;;; hands the SAME date it uses to decide whether a held permit has expired.
;;;
;;; Told no date, the whole catalogue stands — the timeless read the law face
;;; wants when it shows what a jurisdiction asks, rather than what it asks today.
;;;
;;; Run: guile -L module tests/legal/test-legal-validity.scm

(use-modules (playnet test harness) (playnet legal registry)
             (playnet legal registry-actor)
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))

(define ctx (legal-context #:crossings '(public-sale) #:place-path '("ville" "pays")))

(define* (permit label #:key (as-of #f) (until #f))
  (rule (all-of (in-jurisdiction "ville") (on-crossing 'public-sale))
        (list (obtain #:rides 'entity #:name label))
        #:label label #:as-of as-of #:until until
        #:confidence 'verified #:steward "scope:test"))

;; three rules over the same guard: one long-standing, one that ended, one that
;; has not begun
(define standing (permit "Licence permanente" #:as-of "2010-01-01"))
(define lapsed   (permit "Régime transitoire" #:as-of "2015-01-01" #:until "2020-01-01"))
(define future   (permit "Régime 2030"        #:as-of "2030-01-01"))
(define rules (list standing lapsed future))

(define (names as-of)
  (call-with-values (lambda () (legal-demands ctx #:rules rules #:as-of as-of))
    (lambda (bill hits) (sort (map legal-rule-label hits) string<?))))

(display "\n── which rules stand, and when ──\n")
(format #t "  no date  : ~a\n" (names #f))
(format #t "  2018     : ~a\n" (names "2018-06-01"))
(format #t "  2026     : ~a\n" (names "2026-08-22"))
(format #t "  2031     : ~a\n" (names "2031-01-01"))
(check "told no date, the whole catalogue stands"
       (names #f) '("Licence permanente" "Régime 2030" "Régime transitoire"))
(check "in 2018 the transitional regime is in force"
       (names "2018-06-01") '("Licence permanente" "Régime transitoire"))
(check "in 2026 it has lapsed and the 2030 regime has not begun"
       (names "2026-08-22") '("Licence permanente"))
(check "in 2031 the future regime stands"
       (names "2031-01-01") '("Licence permanente" "Régime 2030"))

(display "\n── the window is exclusive at its end ──\n")
(check-pred "a rule is in force ON its as-of date" (rule-in-force? lapsed "2015-01-01"))
(check-pred "…and NOT on the day its until names" (not (rule-in-force? lapsed "2020-01-01")))
(check-pred "…but still on the day before" (rule-in-force? lapsed "2019-12-31"))

(display "\n── dates as their sources write them ──\n")
;;; A pack's dates arrive in whatever shape its source uses: the Géoportail de
;;; l'Urbanisme writes "20241212", a statute reference writes "2022-03-10".
;;; Comparison is on digits, so the two orderings agree.
(define gpu-style (permit "Modification n°1" #:as-of "20241212"))
(check-pred "an 8-digit source date orders against an ISO query date"
            (rule-in-force? gpu-style "2026-08-22"))
(check-pred "…and is not yet in force before it"
            (not (rule-in-force? gpu-style "2024-01-01")))

(display "\n── serialization ──\n")
(define round (sexp->rule (rule->sexp lapsed)))
(check "until survives a round-trip through the pack format"
       (legal-rule-until round) "2020-01-01")
(check-pred "…and so does the window it makes"
            (and (rule-in-force? round "2018-06-01")
                 (not (rule-in-force? round "2026-08-22"))))
;; a pack written before `until` existed is 7 elements long
(define old-form (list-head (rule->sexp standing) 7))
(define old (sexp->rule old-form))
(check-pred "a pack written before `until` existed still reads, with no end"
            (and (not (legal-rule-until old)) (rule-in-force? old "2099-01-01")))

(display "\n── through the actor, as the gate asks it ──\n")
(define asked
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let ((reg (spawn ^legal-registry rules)))
        (list (length (cadr ($ reg 'demands ctx)))              ; timeless
              (length (cadr ($ reg 'demands ctx "2026-08-22"))) ; as of today
              (length (cadr ($ reg 'demands ctx "2018-06-01")))))))) ; as of 2018
(format #t "  hits — timeless ~a · 2026 ~a · 2018 ~a\n"
        (car asked) (cadr asked) (caddr asked))
(check-pred "the registry folds only what stands on the day it is given"
            (equal? asked '(3 1 2)))
(test-summary!)
