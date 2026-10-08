;;; skill-law.scm — a skill's law, read off its spec and folded over the record.
;;;
;;; The engine carries one law for a skill's competence (engine.scm, SKILL
;;; DYNAMICS): it DECAYS when idle, REGENERATES through practice, GROWS through
;;; training, and the plan may deliver no more of a skill than the competence
;;; stands —
;;;
;;;     C_t = (1−decay)·C_{t−1} + regen·practice_{t−1} + yield·train_{t−lag}
;;;
;;; This module is the same law on the RECORD side. A skill's parameters live on
;;; its ResourceSpecification as typed tags (`skill:decay:0.4`, the idiom a
;;; person's `diet:vegan` and a food's `vf:food-class:dairy` already use), and
;;; the observer's dated, satisfaction-weighted practice (`skill-practice`) is
;;; folded through them to where competence STANDS today. That figure is what a
;;; profile shows for a skill, and what the live solve opens from
;;; (engine set-competence!), so the plan continues from the record.
;;;
;;; A skill with no declared law has the law's identity — no decay, regen 1 —
;;; under which the fold IS the validated ledger (practiced-hours), exactly as
;;; every reader had it before a law was declared. Hours are the one measure:
;;; what the observer validates, what the engine's gate delivers, what a
;;; conformance threshold asks — and what a profile shows.

(define-module (playnet planner formulas skill-law)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils clock) #:select (iso->epoch))
  #:export (skill-law-of *skill-law-identity* law-ref competence-fold effective-skills))

;; the law's identity: no decay, every practiced hour kept — the validated ledger
(define *skill-law-identity*
  '((decay . 0.0) (regen . 1.0) (yield . 1.0) (lag . 1) (teacher . 0.0) (trainee . 0.0)
    (endow . 0.0) (refresh . 0.0)))

(define (law-ref law key) (or (and law (assq-ref law key)) (assq-ref *skill-law-identity* key)))

(define (skill-law-of tags)
  "The law a skill's spec declares, off its classification TAGS: every
   `skill:<key>:<number>` tag, KEY one of the engine's set-skill-spec!
   keywords. #f when the spec declares none — the identity then holds."
  (let ((law (filter-map
              (lambda (t)
                (and (string? t) (string-prefix? "skill:" t)
                     (let* ((rest (substring t 6)) (i (string-index rest #\:)))
                       (and i
                            (let ((key (string->symbol (substring rest 0 i)))
                                  (val (string->number (substring rest (+ i 1)))))
                              (and val (assq key *skill-law-identity*)
                                   (cons key (if (eq? key 'lag) (inexact->exact (round val)) (exact->inexact val)))))))))
              (or tags '()))))
    (and (pair? law) law)))

(define* (competence-fold practice law #:key today (period-days 1))
  "Where competence stands at TODAY (an instant, or its ISO text), folding
   PRACTICE ((instant . validated-hours) …) through LAW period by period: from
   the first practice to today, C ← (1−decay)·C + regen·practice_p, opening at
   the endowment. Under the identity law this is Σ practice — the ledger.
   Training the record holds as work in the skill is practice; a dedicated
   refresher, likewise. No practice ⇒ the endowment."
  (let* ((decay (law-ref law 'decay)) (regen (law-ref law 'regen)) (endow (law-ref law 'endow))
         (secs  (* 86400.0 period-days))
         (at    (lambda (x) (if (string? x) (iso->epoch x) x)))
         (rows  (filter-map (lambda (p) (and (car p) (cons (at (car p)) (cdr p)))) practice)))
    (if (null? rows)
        endow
        (let* ((t0    (apply min (map car rows)))
               (tnow  (if today (at today) (apply max (map car rows))))
               (pnow  (max 0 (inexact->exact (floor (/ (- tnow t0) secs)))))
               (by-p  (make-hash-table)))
          (for-each (lambda (r)
                      (let ((p (inexact->exact (floor (/ (- (car r) t0) secs)))))
                        (hash-set! by-p p (+ (cdr r) (hash-ref by-p p 0.0)))))
                    rows)
          (let loop ((p 0) (c endow))
            (if (>= p pnow)
                ;; today's own practice has not yet become tomorrow's competence;
                ;; it stands beside it, as the engine's gate reads practice_t
                (+ c (hash-ref by-p pnow 0.0))
                (loop (+ p 1) (+ (* (- 1.0 decay) c) (* regen (hash-ref by-p p 0.0))))))))))

;;; ── a worker's conformance closure ─────────────────────────────────────────

(define (effective-skills held catalogue practiced-hours-of)
  "A worker's CONFORMANCE closure — the skills they may supply.

   held               : list of directly-held skill ids (from holds-skill facts).
   catalogue          : list of (spec . satisfied-by-DNF) for specs with substitutes.
   practiced-hours-of : (lambda (skill) → validated hours) for THIS worker.

   Returns held ∪ the transitive closure of specs whose satisfied-by is met."
  (let loop ((have held))
    (let ((added
           (filter-map
            (lambda (entry)
              (let ((spec (car entry)) (dnf (or (cdr entry) '())))
                (and (not (member spec have))
                     (any (lambda (clause)
                            (every (lambda (comp)
                                     (let ((cs (car comp)) (minh (or (cdr comp) 0)))
                                       (and (member cs have)
                                            (>= (practiced-hours-of cs) minh))))
                                   clause))
                          dnf)
                     spec)))
            catalogue)))
      (if (null? added) have (loop (append added have))))))
