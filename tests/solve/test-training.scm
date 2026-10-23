;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-training.scm — a skill is labour-power, not a storable good.
;;;
;;; The engine PRICES a scarce skill (the dual λ on its Lab|skill|cell balance)
;;; but cannot yet ACT on it: skill supply is a fixed endowment (*workers*),
;;; never an OUTPUT of any activity, so "one doctor, many demands" produces a
;;; pull that dead-ends. The fix is a TRAINING activity. But the right ontology
;;; matters: a skill is NOT a means of production. A MoP is depleted by use and
;;; storable (grain: used once, or sits in a silo). A skill is NOT depleted by
;;; use (a doctor treating patients does not use up her doctoring) and CANNOT be
;;; stored apart from its bearer. It is labour-power — a persistent attribute of
;;; a located PERSON. "Carrying forward" is the person persisting, not a stock;
;;; what renews each period is the person's TIME (the N·T budget). In Hegel's
;;; terms the skill is a CONCRETE UNIVERSAL: the abstract universal is the social
;;; need / category (the pull λ is on abstract doctor-SNLT); the skill lives only
;;; in concrete bearers and grows by particularising itself — training more
;;; individuals. So training is a STATE-CHANGE of an agent's skill-set, and the
;;; trained person's hours reappear in EVERY later period for free.
;;;
;;; This makes the claim measurable. Two persons over four periods, one place,
;;; one scarce skill "doctor": Doc (a doctor, present all periods, H hrs each)
;;; and Nov (a novice, present all periods). In period 0, Doc mentors (b hrs/unit)
;;; and Nov trains (fraction `train`∈[0,1]); from period 1 on, a trained Nov
;;; supplies H·train doctor-hours EACH period. Demand is light in period 0 then
;;; high and sustained (D1=D2=D3). Two readings of the same training:
;;;
;;;   PERSON-BOUND (correct): cap_t = H + H·train  for every t≥1   — renews.
;;;        One training serves periods 1,2,3; care is equal across them; the
;;;        plan trains only as much as one period's shortfall needs (< full),
;;;        because the graduate keeps practising. No re-storage.
;;;   STORABLE (the MoP error): training fills a one-off POOL H·train that the
;;;        treating DRAWS DOWN — Σ_{t≥1} e_t ≤ H·train, cap_t = H + e_t. The
;;;        novice's "capacity" is a stock of hours, exhausted over the horizon.
;;;
;;; Result: treating the skill as storable makes the plan train MORE (it maxes
;;; the novice out) and serve LESS (the pool can't cover three periods) — the
;;; signature of wrongly assuming a doctor's skill is consumed each time she uses
;;; it. The pull funds training in both; only the person-bound reading relaxes it.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-training.scm

(use-modules (srfi srfi-1) (ice-9 format))
;; resolve planner.scm by finding the sibling that exists (current-filename is
;; #f under some run modes, so scan the script-path candidates as well).
(use-modules (playnet solve engine)
             (playnet solve solver))

;; ── parameters ───────────────────────────────────────────────────────────────
(define H   40.0)    ; each person's hours per period (the renewable time budget)
(define a   1.0)     ; doctor-hours per unit of care delivered
(define b   10.0)    ; teacher (Doc) hours consumed per unit of training, in period 0
(define trn 20.0)    ; novice hours consumed per unit of training (free-time cost)
(define D0  20.0)    ; care demanded in period 0 (one doctor covers it, with hours to spare)
(define Dhi 70.0)    ; care demanded in periods 1,2,3 (≈1.75 doctors — high & sustained)
(define wt  1000.0)  ; desire weight
(define PERIODS '(1 2 3))

;; activity layout.  treat0..treat3 = indices 0..3 ; train = 4 ; (stock only) e1..e3 = 5..7
(define TR 4)
(define (treat-idx t) t)                     ; treat in period t lives at index t (T0=0…T3=3)

(define (build mode)                         ; mode ∈ {person, stock}
  (let* ((na   (if (eq? mode 'stock) 8 5))
         (cap0 (mk-bar H (list (cons (treat-idx 0) (- a)) (cons TR (- b)))))  ; Doc: treat@0 + mentoring
         (caps (map (lambda (t)                                              ; the skilled-supply balance @ t≥1
                 (cons t (if (eq? mode 'stock)
                             (mk-bar H (list (cons (+ 4 t) 1.0)        (cons (treat-idx t) (- a))))   ; H + e_t − a·treat_t
                             (mk-bar H (list (cons TR H)               (cons (treat-idx t) (- a))))))) ; H + H·train − a·treat_t
               PERIODS))
         (pool   (and (eq? mode 'stock)                                      ; one depletable stock of hours
                      (mk-bar 0.0 (list (cons TR H) (cons 5 -1.0) (cons 6 -1.0) (cons 7 -1.0)))))
         (tbound (mk-bar 1.0 (list (cons TR -1.0))))                         ; train ≤ 1 (only one novice)
         (nns    (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) (iota na)))  ; x ≥ 0
         (dems   (cons (mk-des (mk-bar 0.0 (list (cons (treat-idx 0) 1.0))) D0 wt)
                       (map (lambda (t) (mk-des (mk-bar 0.0 (list (cons (treat-idx t) 1.0))) Dhi wt)) PERIODS)))
         (forms  (append (list cap0) (map cdr caps) (if pool (list pool) '()) (list tbound) nns dems))
         (labform (cons (cons TR (+ b trn)) (map (lambda (i) (cons (treat-idx i) a)) (iota 4)))))
    (values forms labform caps na)))

(define (form-slack f x)                     ; s(x) = const + Σ coeff·x for a bar form
  (fold (lambda (ic s) (+ s (* (cdr ic) (vector-ref x (car ic))))) (cadr f) (caddr f)))

(define (run mode)
  (call-with-values (lambda () (build mode))
    (lambda (forms labform caps na)
      (let* ((res (solve* forms labform (make-vector na 0.0)))
             (x   (car res)) (tf (cadr res)))
        (list (vector-ref x TR)                                   ; training run in period 0
              (map (lambda (pc)                                   ; per period ≥1: (period care met λ)
                     (let* ((p (car pc)) (cap (cdr pc))
                            (care (vector-ref x (treat-idx p)))
                            (lam  (/ tf (max (form-slack cap x) 1e-12))))
                       (list p care (/ care Dhi) lam)))
                   caps))))))

;; ── run both readings of the same training ───────────────────────────────────
(define person (run 'person))
(define stock  (run 'stock))
(define (train-of r) (first r))
(define (rows-of  r) (second r))
(define (mets r)  (map third  (rows-of r)))
(define (cares r) (map second (rows-of r)))
(define (lams r)  (map fourth (rows-of r)))

(define (show tag r)
  (format #t "  ~a train@0=~5,3f | care 1,2,3 = ~5,1f ~5,1f ~5,1f | met = ~4,0f% ~4,0f% ~4,0f% | pull = ~6,3f ~6,3f ~6,3f~%"
          tag (train-of r)
          (first (cares r)) (second (cares r)) (third (cares r))
          (* 100 (first (mets r))) (* 100 (second (mets r))) (* 100 (third (mets r)))
          (first (lams r)) (second (lams r)) (third (lams r))))

(format #t "~%── one novice, sustained demand (D0=~a, D1..3=~a, 1 person=~a hrs) ──~%" D0 Dhi H)
(show "person-bound" person)
(show "storable    " stock)

;; ── assertions: person-bound is correct; storable mis-models the skill ───────
(let* ((p-train (train-of person)) (s-train (train-of stock))
       (p-min (apply min (mets person))) (s-min (apply min (mets stock)))
       (p-spread (- (apply max (cares person)) (apply min (cares person))))
       (p-total (apply + (cares person))) (s-total (apply + (cares stock)))
       (c1 (and (> p-train 0.5) (< p-train 0.95)))   ; the pull funds it — but less than full
       (c2 (> p-min 0.95))                            ; one training serves ALL three periods
       (c3 (< p-spread 2.0))                          ; care equal across periods: persistence, no re-storage
       (c4 (< s-min 0.85))                            ; depletion: the stock can't keep up even maxed
       (c5 (and (> s-train p-train) (> p-total s-total)))  ; storable trains MORE yet serves LESS
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] the period-1+ pull funds training, below full          (person train@0 = ~,3f)~%" (if c1 "✓" "✗") p-train)
  (format #t "  [~a] ONE training serves periods 1,2,3                       (min met = ~,0f%)~%"       (if c2 "✓" "✗") (* 100 p-min))
  (format #t "  [~a] care is equal across periods — persists, no re-storage  (spread = ~,2f hrs)~%"     (if c3 "✓" "✗") p-spread)
  (format #t "  [~a] storable reading cannot keep up (skill ‘used up’)       (min met = ~,0f%)~%"       (if c4 "✓" "✗") (* 100 s-min))
  (format #t "  [~a] storable trains MORE (~,2f vs ~,2f) yet serves LESS (~,0f vs ~,0f care)~%"
          (if c5 "✓" "✗") s-train p-train s-total p-total)
  (format #t "~%  ~a a skill is labour-power: borne by a persisting person, it renews — it is not a storable good~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
