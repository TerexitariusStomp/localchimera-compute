;;; catalogue.scm — the ONE compiler behind every governed frag catalogue.
;;;
;;; A governed limit — a planetary boundary, a conformance-freshness margin, any
;;; future fragility a stewardship scope registers — is authored the same way: a
;;; list of entries `(spec kind lo hi alpha w src label group unit)` (or
;;; `(couple target driver coeff)` for a driven agent), the shape `tension-
;;; registry.scm`'s catalogue rows already take. What differs between a carbon
;;; budget and a verification margin is only the entries; the two things every
;;; such catalogue is asked — split it into the solver's policy, and render it
;;; for a wire — are these two pure functions, read through here by every
;;; catalogue rather than reimplemented beside its own data.
;;;
;;; `eco-catalogue.scm` (the planetary catalogue) and `conformance-catalogue.scm`
;;; (the verification catalogue) are its two callers today, both re-exporting so
;;; nothing importing either module noticed the move; a third catalogue asks
;;; here directly, never rewrites this pair beside its own table.

(define-module (playnet planner knowledge catalogues compiler)
  #:use-module (srfi srfi-1)
  #:export (catalogue->wire catalogue->policy))

;; ── the fragility WIRE: the catalogue as the browser's wheel reads it. Given a
;; draw-of (spec → the federation's current draw toward the tip, from a solve),
;; each display-carrying agent becomes an alist {spec control group unit w source
;; current tip s}, where s is the normalized slack 1−draw/tip (1 healthy, 0 at the
;; tip) — the SAME s the `frag` barrier consumes (tension-kinds.scm). A `couple`
;; lets a driven agent (warming) read its driver's draw (co2 × coeff). Agents
;; without display fields (length < 10) are skipped. Registering a new agent —
;; (register-agent! (spec kind lo hi alpha w src label group unit)) — makes it
;; appear on the wheel with no other change: the registry is the source of truth.
(define (catalogue->wire entries draw-of)
  (define couples
    (filter-map (lambda (e) (and (pair? e) (eq? (car e) 'couple)
                                 (list (cadr e) (caddr e) (cadddr e)))) entries))  ; (target driver coeff)
  (filter-map
   (lambda (e)
     (and (pair? e) (not (eq? (car e) 'couple)) (>= (length e) 10)
          (let* ((spec (car e)) (lo (list-ref e 2)) (hi (list-ref e 3)) (alpha (list-ref e 4))
                 (w (list-ref e 5)) (src (list-ref e 6)) (label (list-ref e 7))
                 (group (list-ref e 8)) (unit (list-ref e 9))
                 (tip (+ lo (* alpha (- hi lo))))                 ; s_tip = quantile_alpha[lo,hi]
                 (cp  (assoc spec couples))                        ; is this agent driven by another's draw?
                 (draw (if cp (* (draw-of (cadr cp)) (caddr cp)) (draw-of spec)))
                 (s   (max 1e-3 (min 1.0 (if (> tip 0) (/ (- tip draw) tip) 1.0)))))
            (list (cons 'spec spec) (cons 'control label) (cons 'group group)
                  (cons 'unit unit) (cons 'w w) (cons 'source src)
                  (cons 'current draw) (cons 'tip tip) (cons 's s)))))
   entries))

;; Split a catalogue into the planner's (values spec-frag budget couple) — a
;; solve's own read of any governed catalogue, eco or conformance alike.
(define (catalogue->policy entries)
  (let loop ((es entries) (rates '()) (budgets '()) (couples '()))
    (if (null? es)
        (values (reverse rates) (reverse budgets) (reverse couples))
        (let* ((e (car es)) (rest (cdr es)))
          (cond ((eq? (car e) 'couple)                                          ; (couple k j c src)
                 (loop rest rates budgets (cons (list (cadr e) (caddr e) (cadddr e)) couples)))
                ((eq? (cadr e) 'budget)                                         ; (spec budget lo hi alpha w src) → (spec . (lo hi alpha w))
                 (loop rest rates (cons (cons (car e) (list (list-ref e 2) (list-ref e 3) (list-ref e 4) (list-ref e 5))) budgets) couples))
                ((eq? (cadr e) 'rate)
                 (loop rest (cons (cons (car e) (list (list-ref e 2) (list-ref e 3) (list-ref e 4) (list-ref e 5))) rates) budgets couples))
                (else (error "catalogue->policy: bad entry" e)))))))
