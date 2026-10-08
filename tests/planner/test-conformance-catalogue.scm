;;; test-conformance-catalogue.scm — the conformance fragility is a GOVERNED datum.
;;;
;;; playnet.typ §2.0.8: which fragilities the federation tracks, and how steeply their
;;; curves rise, are governance choices custodied by the tension-registry, compiled to
;;; solver math — "a governance object, not a hard-coded table." Slices 1–2 priced the
;;; conformance confidence barrier −w·log(V−Q) with a hard-coded weight in the test.
;;; This registers that barrier as a governed profile in conformance-catalogue.scm and
;;; proves it flows through the SAME registry/catalogue machinery as the eco envelopes —
;;; the same `frag` kind, the same catalogue->policy compiler, the same actor custody.
;;;
;;; Run:  guile -L module/playnet/planner tests/planner/test-conformance-catalogue.scm

(use-modules (srfi srfi-1) (ice-9 format) (goblins) (goblins vat) (goblins actor-lib facet))
(define (sibling f) (or (find file-exists? (filter-map (lambda (p) (and (string? p) (string-append (dirname p) "/" f)))
                                                       (cons (current-filename) (command-line))))
                        (string-append "module/playnet/planner/" f)))
(use-modules (playnet planner knowledge catalogues tension-registry)    ; ^tension-registry, check-kind, fd, rel
             (playnet planner formulas tension-kinds)       ; *kind-library*
             (playnet planner knowledge catalogues compiler))          ; catalogue->policy / catalogue->wire — the shared compiler, not eco-specific
(setenv "CONFORMANCE_LIB" "1")
(use-modules (playnet planner knowledge catalogues conformance)) ; *conformance-catalogue*, conformance-frag-weight

(format #t "~%── the conformance confidence barrier is a governed fragility, not a hard-coded weight ──~%")

;; P1 — the profile compiles through the SAME catalogue->policy as the eco envelopes,
;; landing as a per-period frag-spec seed (spec . (lo hi alpha w)) the planner consumes.
(define-values (rates budgets couples) (catalogue->policy *conformance-catalogue*))
(define seed (assoc "conformance-confidence" rates))
(format #t "  catalogue->policy → frag-spec seed: ~a~%" seed)
(define p1 (and seed (equal? (cdr seed) '(0.15 1.0 0.5 0.5))))
(format #t "  [~a] P1 the conformance profile compiles to a frag-spec seed (same compiler as eco)~%" (if p1 "✓" "✗"))

;; P2 — the barrier it invokes is the `frag` kind, and its (φ, φ′, φ″) are self-consistent
;; (the registry's finite-difference discipline — the same check every eco kind passes).
(define frag-table (list (cons 'frag ((cdr (assq 'frag *kind-library*))))))
(define w (conformance-frag-weight))
(define p2 (check-kind 'frag frag-table 0.5 2.0 w '(0.20 0.50 0.80 1.00)))
(format #t "  [~a] P2 the confidence barrier is the governed `frag` shape; φ′,φ″ invert φ (FD-checked)~%" (if p2 "✓" "✗"))

;; P3 — governance custody: register the profile into a live registry, and it round-trips
;; through the actor's portrait (persistence), like any ratified fragility agent.
(define vat (spawn-vat #:name "conformance-catalogue"))
(define p3
  (with-vat vat
    (let* ((reg  (spawn ^tension-registry '(frag) '()))
           (_    ($ reg 'register-agent! (car *conformance-catalogue*)))
           (pol  ($ reg 'eco-policy))                       ; attenuated solver view: (rates budgets couples)
           (seen (assoc "conformance-confidence" (car pol)))
           (revived (restore-registry ($ reg 'portrait)))
           (rt   (equal? ($ reg 'eco-catalogue) ($ revived 'eco-catalogue))))
      (format #t "  registry eco-policy sees profile: ~a ; portrait round-trips: ~a~%" (and seen #t) rt)
      (and seen rt))))
(format #t "  [~a] P3 a stewardship scope registers the profile; it persists + attenuates to the solver~%" (if p3 "✓" "✗"))

;; P4 — governance visibility: it appears on the fragility wheel via the SAME wire the
;; eco boundaries use — here at a freshness margin drawn 0.6 of the way toward the tip.
(define wire (catalogue->wire *conformance-catalogue* (lambda (spec) 0.6)))
(define entry (and (pair? wire) (car wire)))
(format #t "  catalogue->wire → ~a~%" (and entry (map car entry)))
(define p4 (and entry (equal? (assq-ref entry 'control) "conformance freshness")
                (assq-ref entry 's)))
(format #t "  [~a] P4 the profile surfaces on the governance wheel (control/group/unit/s), like any fragility~%" (if p4 "✓" "✗"))

;; P5 — the governed steepness IS the barrier weight: one ratified datum, not a constant
;; buried in the solve. (docs/planning/legal/inspection-in-plan.md's WCONF now reads from here.)
(define p5 (and (number? w) (= w 0.5)))
(format #t "~%  governed confidence-barrier steepness w = ~a  (the in-plan −w·log(V−Q) reads this)~%" w)
(format #t "  [~a] P5 the barrier weight is a governed datum — one row, ratifiable, not hard-coded~%" (if p5 "✓" "✗"))

(define ok (and p1 p2 p3 p4 p5))
(format #t "~%  ~a the conformance fragility is governance-set: same `frag` kind, same catalogue machinery,~%" (if ok "✓" "✗"))
(format #t "    same actor custody as the planetary boundaries — inspection's barrier enters as one datum~%~%")
(exit (if ok 0 1))
