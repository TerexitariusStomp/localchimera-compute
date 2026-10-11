;;; test-training-located.scm — skill dynamics through the REAL located engine.
;;;
;;; Exercises the build-located / solve-located path with a skill that declares
;;; lifecycle dynamics on its ResourceSpecification (set-skill-spec!): it DECAYS
;;; if unused, REGENERATES through practice, and GROWS by training. One place
;;; (town), four periods, two persons:
;;;   Doc — an existing doctor, present every period, 40 hrs (endowment in the person)
;;;   Nov — a novice, present every period; may train as a doctor (Doc mentors)
;;; Care is produced by a `treat` process needing doctor-hours. Demand is light in
;;; period 0 then high. The pull λ on doctoring should fund Nov's training; once
;;; trained, Nov's competence persists and is renewed by practice — but an idle
;;; period decays it, forcing re-investment.
;;;
;;; Two demand schedules isolate the mechanisms:
;;;   sustained: 20,70,70,70 — Nov practises every period; regen sustains L; one
;;;              early training carries all later periods.
;;;   lull:      20,70, –,70 — period 2 has no demand → Nov idle → L decays →
;;;              the plan must RE-train to serve period 3.  Σtrain(lull) > Σtrain(sustained)
;;;              is decay made measurable.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-training-located.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world))

(define PER '(0 1 2 3))
(define (setup demand)                         ; demand: ((period . qty) …)
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods PER
                  #:templates (list (list "treat" (list (cons "care" 1.0)) '() 1.0 (list (cons "doctor" 1.0))))
                  #:workers
                    (append-map (lambda (t) (list (list "Doc" '("doctor") (cell "town" t) 40.0)
                                                  (list "Nov" (if (= t 0) '() '("doctor")) (cell "town" t) 40.0)))  ; Nov can doctor only once trained (≥ period 1)
                                PER))
  ;; the doctor skill's ResourceSpecification — labour-power lifecycle:
  (set-skill-spec! "doctor" #:decay 0.4 #:regen 0.6 #:yield 1.0 #:lag 1
                            #:teacher 0.3 #:trainee 1.0 #:endow 0.0)
  (add-trainable! "Nov" "doctor" 0)            ; Nov may train as a doctor from period 0; mentor = a doctor
  (for-each (lambda (pq) (hash-set! *demand* (lg "care" (cell "town" (car pq))) (cdr pq))) demand))

(define (run demand)
  (setup demand)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (define (V key) (let ((i (hash-ref idx key #f))) (if i (vector-ref x i) 0.0)))
      (list (cons 'train (map (lambda (t) (V (Tkey "Nov" "doctor" t))) PER))
            (cons 'nov   (map (lambda (t) (V (string-append "w|Nov|doctor|" (cell "town" t)))) PER))
            (cons 'doc   (map (lambda (t) (V (string-append "w|Doc|doctor|" (cell "town" t)))) PER))
            (cons 'care  (map (lambda (t) (V (string-append "p|treat|" (cell "town" t)))) PER))))))

(define (g k r) (cdr (assq k r)))
(define (showrow tag xs) (format #t "  ~a ~{~6,1f ~}~%" tag xs))
(define (report tag r)
  (format #t "~%── ~a ──~%" tag)
  (format #t "  period          0      1      2      3~%")
  (showrow "train (T)     " (g 'train r))
  (showrow "Nov doctors   " (g 'nov r))
  (showrow "Doc doctors   " (g 'doc r))
  (showrow "care delivered" (g 'care r)))

(define sustained (run '((0 . 20) (1 . 70) (2 . 70) (3 . 70))))
(define lull      (run '((0 . 20) (1 . 70)          (3 . 70))))
(report "SUSTAINED demand 20,70,70,70" sustained)
(report "LULL demand 20,70,-,70 (period 2 idle)" lull)
(format #t "~%  Σtrain sustained = ~,2f | Σtrain lull = ~,2f~%"
        (apply + (g 'train sustained)) (apply + (g 'train lull)))

;; ── assertions: the three mechanisms, through the real located solver ─────────
(let* ((ts (g 'train sustained)) (ns (g 'nov sustained))
       (tl (g 'train lull))      (nl (g 'nov lull))
       (sumS (apply + ts)) (sumL (apply + tl))
       (c1 (> (first ts) 10.0))                              ; the pull funds initial training
       (c2 (and (> (second ns) 10.0) (> (fourth ns) 10.0)))  ; Nov then doctors across later periods (persists)
       (c3 (< (apply + (cdr ts)) 2.0))                       ; sustained: ONE training, practice regenerates the rest
       (c4 (> sumL (+ sumS 2.0)))                            ; decay: the idle period forces clearly-measurable re-investment
       (c5 (and (< (third nl) (* 0.5 (second nl))) (> (fourth nl) 10.0)))  ; lull: Nov's idle period clearly suppresses doctoring (< half an active period), recovered by p3
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] the pull funds training in period 0                (T0 = ~,1f)~%"            (if c1 "✓" "✗") (first ts))
  (format #t "  [~a] the graduate then doctors across later periods       (Nov@1=~,1f Nov@3=~,1f)~%" (if c2 "✓" "✗") (second ns) (fourth ns))
  (format #t "  [~a] sustained: one training, practice REGENERATES it     (Σtrain after p0 = ~,2f)~%" (if c3 "✓" "✗") (apply + (cdr ts)))
  (format #t "  [~a] DECAY: the idle period forces re-investment          (Σtrain ~,1f → ~,1f)~%"   (if c4 "✓" "✗") sumS sumL)
  (format #t "  [~a] lull: Nov idle in period 2, retrained for period 3   (Nov@2=~,1f Nov@3=~,1f)~%" (if c5 "✓" "✗") (third nl) (fourth nl))
  (format #t "~%  ~a skill as labour-power, wired into the located engine: trained by pull, kept by practice, lost to idleness~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
