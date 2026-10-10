;;; test-skill-refresher.scm — a dedicated refresher channel keeps a skill warm WITHOUT wasteful output.
;;;
;;; The defect (see docs/planning/identity/skill-maintenance-recipes.md): the only way for a TRAINABLE worker to
;;; maintain a skill was to WORK it, and in a demand-lull the only skill-consuming recipe is the productive
;;; one — so the trainee kept sharp by over-supplying productive labour (treating, toward output nobody
;;; asked for). The fix is a dedicated refresher channel: hours a worker spends keeping the skill warm
;;; directly (recertification/drills), with its own maintenance yield (set-skill-spec! #:refresh), producing
;;; NO output. In a lull the plan shifts the trainee's upkeep off wasteful productive practice and onto the
;;; clean refresher — and, the refresher being the more efficient upkeep, the skill ends up WARMER.
;;;
;;; We watch the TRAINABLE worker (Nov) — the one the competence dynamics govern. (Doc is an established
;;; doctor with no skill dynamics, so its idle-period output is outside the refresher's scope and not the
;;; subject here.) Same scenario, solved with refresh OFF vs ON.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-skill-refresher.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine))
(define PER '(0 1 2 3))

(define (setup refresh?)
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods PER
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doctor" 1.0))))
                  #:workers
                    (append-map (lambda (t) (list (list "Doc" '("doctor") (cell "town" t) 40.0)
                                                  (list "Nov" (if (= t 0) '() '("doctor")) (cell "town" t) 40.0))) PER))
  ;; doctor skill: decays in idle periods; regen 0.6 from on-the-job practice; a dedicated refresher
  ;; (when ON) maintains at 2.0/hr — dedicated drills hold a skill more efficiently than incidental practice.
  (set-skill-spec! "doctor" #:decay 0.4 #:regen 0.6 #:yield 1.0 #:lag 1 #:teacher 0.3 #:trainee 1.0 #:endow 0.0
                   #:refresh (if refresh? 2.0 0.0))
  (add-trainable! "Nov" "doctor" 0)
  ;; LULL: period 2 has NO care demand — the idle period that used to force wasteful practice.
  (for-each (lambda (pq) (hash-set! *demand* (lg "care" (cell "town" (car pq))) (cdr pq)))
            '((0 . 20) (1 . 70) (3 . 70))))

(define (run refresh?)
  (setup refresh?)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (define (V k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
      (list (cons 'care (map (lambda (t) (V (string-append "p|treat|" (cell "town" t)))) PER))
            (cons 'refr (map (lambda (t) (+ (V (string-append "wr|Nov|doctor|" (cell "town" t)))
                                            (V (string-append "wr|Doc|doctor|" (cell "town" t))))) PER))
            (cons 'nov  (map (lambda (t) (V (string-append "w|Nov|doctor|" (cell "town" t)))) PER))))))

(define (g k r)(cdr (assq k r)))
(define off (run #f))
(define on  (run #t))
(define nov2-off (list-ref (g 'nov off) 2))   ; Nov's idle-period productive practice (over-supply), OFF
(define nov2-on  (list-ref (g 'nov on)  2))   ; …and ON
(define refr-on  (list-ref (g 'refr on)  2))   ; refresher hours in the idle period, ON
(define nov3-off (list-ref (g 'nov off) 3))   ; Nov doctors in period 3 — the skill held through the lull
(define nov3-on  (list-ref (g 'nov on)  3))

(format #t "~%── a dedicated refresher channel — the trainee's idle-period upkeep (period 2) ──~%")
(format #t "  refresh OFF:  Nov productive-practice@2 = ~,2f   refresher@2 = 0    Nov doctors@3 = ~,2f~%" nov2-off nov3-off)
(format #t "  refresh ON :  Nov productive-practice@2 = ~,2f   refresher@2 = ~,2f   Nov doctors@3 = ~,2f~%" nov2-on refr-on nov3-on)

;; THRESHOLD NOTE. This was a bare constant twice over — `4.0` against the old
;; central-path floor (0.02), then `2.5` against the corrected one (0.005) where
;; the same defect measured 3.8. It is now 2.17, because the floor is derived
;; from the certified gap and no longer leaves every column a residue. A number
;; recalibrated once per floor change is measuring the floor, not the defect.
;;
;; The claim is the CONTRAST — without a refresher channel the upkeep is dumped
;; into productive practice — and c2 states it relatively already. So c1 says
;; "materially present" on the plan's own scale: the practice being dumped into
;; period 2 is a real fraction of the upkeep that REPLACES it once the channel
;; exists. Both quantities are hours of the same trainee's time in the same
;; period, so the ratio is meaningful and carries no calibration of its own.
(let* ((c1 (> nov2-off (* 0.25 refr-on)))          ; OFF: the defect — Nov over-supplies productive practice to stay sharp
       (c2 (< nov2-on (* 0.6 nov2-off)))           ; ON: that wasteful practice drops sharply (the refresher replaces it)
       (c3 (> refr-on 1.0))                         ; ON: the clean refresher channel carries the shifted upkeep
       (c4 (>= nov3-on nov3-off))                   ; ON: the skill stays AT LEAST as warm (more efficient upkeep ⇒ ≥)
       (c5 (> nov3-on 10.0))                        ; ON: and genuinely warm — Nov still doctors after the lull
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] OFF: the trainee over-supplies productive practice to stay sharp (~,1f hrs)~%" (if c1 "✓" "✗") nov2-off)
  (format #t "  [~a] ON: that wasteful practice drops sharply (~,1f → ~,1f) — shifted off production~%" (if c2 "✓" "✗") nov2-off nov2-on)
  (format #t "  [~a] ON: the clean refresher channel carries the upkeep instead (~,1f hrs, no output)~%" (if c3 "✓" "✗") refr-on)
  (format #t "  [~a] ON: the skill stays at least as warm — more efficient upkeep (Nov@3 ~,1f ≥ ~,1f)~%" (if c4 "✓" "✗") nov3-on nov3-off)
  (format #t "  [~a] ON: and genuinely warm — Nov still doctors after the lull (~,1f)~%" (if c5 "✓" "✗") nov3-on)
  (format #t "~%  ~a upkeep flows through a clean refresher, not wasteful production — the paper's distinct refresher recipe~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
