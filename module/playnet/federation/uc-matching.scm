;;; federation/uc-matching.scm — UC-level labour matching.
;;;
;;;   Score(P,M) = -Σ_d w_d · u_d(P)² - Σ_p u_p(M)²
;;;
;;; Subgradient dual decomposition: pulls λ_(k,t,c) coordinate
;;; leaf-local scale decisions. Deployment produces VF Commitments.

(define-module (playnet federation uc-matching)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf formulas flows) #:select (make-work-commitment))
  #:use-module (playnet vf beyond schedules)
  #:use-module (srfi srfi-1)
  #:use-module (playnet federation plan-bundle)
  #:use-module (playnet pools availability-pool)
  #:use-module ((playnet vf facts availability) #:select (iso-dates-through))
  #:use-module (playnet algorithms pulls)
  #:export (solve-uc-matching
            make-labour-commitment
            greedy-deploy seed-deployment
            *max-iterations* *convergence-epsilon* *initial-step-size*))


(define *max-iterations*      50)
(define *convergence-epsilon*  0.01)
(define *initial-step-size*    1.0)


;;; ── Helpers ─────────────────────────────────────────────────────────────────

(define (alist-get alist key) (let ((p (assoc key alist equal?))) (and p (cdr p))))

(define (window-time-bucket tw)
  (and tw (let ((ds (availability-window-day-schedules tw)))
            (and (pair? ds)
                 (let ((days (day-schedule-days (car ds))))
                   (and (pair? days) (symbol->string (car days))))))))

(define (tkey skill cell window)
  (string-append (or skill "") "|" (or cell "remote") "|"
                 (or (window-time-bucket window) "any")))

(define (snap-to-atomic hours unit)
  (if (or (not unit) (<= unit 0)) hours (* unit (floor (/ hours unit)))))


;;; ── VF Commitment ───────────────────────────────────────────────────────────

(define* (make-labour-commitment plan-id agent skill window hours intent-id
                                 #:optional process place scope)
  "PROCESS, PLACE and SCOPE are the work-intent's own input-of, at-location and
   in-scope-of: a commitment carries the terms of the work it places, so the
   event that fulfils it does too (live.scm make-work-event) and the fold of
   hours by part reads them off the event alone."
  (make-work-commitment
   ;; keyed by the ASSIGNMENT, not just (plan, agent): a multi-skill agent
   ;; deployed onto two work-intents in one plan produced two commitments
   ;; sharing one id — the plan-store's hashmap-set silently replaced the
   ;; first (its hours vanished) while the per-plan index listed the
   ;; survivor twice. The intent-id is unique per assignment and already
   ;; in hand — the (process . spec)/work-coeffs keying lesson again.
   #:id (string-append "lc:" plan-id ":" (or agent "?") ":" (or intent-id "?"))
   #:input-of process #:skill skill
   #:hours hours #:provider agent #:at-location place #:in-scope-of scope
   #:satisfies intent-id #:independent-demand-of plan-id #:planned-within plan-id #:availability-window window))


;;; ── Leaf-local problem ──────────────────────────────────────────────────────

(define (pull-cost intents tensor)
  (fold (lambda (wi acc)
          (+ acc (* (intent-hours wi)
                    (tensor-ref tensor (or (intent-skill wi) "")
                                (or (intent-at-location wi) "remote")
                                (or (window-time-bucket (intent-availability-window wi))
                                    "any")))))
        0 intents))

(define (optimal-scale intents weight tensor variants)
  (cond
    (variants
     (let ((best (fold (lambda (v best)
                         (let ((val (* (- weight (pull-cost intents tensor))
                                       (car v))))
                           (if (or (not best) (> val (cdr best)))
                               (cons (car v) val) best)))
                       #f variants)))
       (if best (car best) 0)))
    (else
     (let ((c (pull-cost intents tensor)))
       (if (zero? c) 1 (min 1 (max 0 (/ weight (* 2 c)))))))))


;;; ── Greedy deployment ───────────────────────────────────────────────────────

(define (best-candidate entries wi rank-fn)
  "Pick the best candidate from ENTRIES for work-intent WI.
   RANK-FN: (entry intent → score), higher = better. #f = first available."
  (cond
    ((null? entries) #f)
    ((not rank-fn) (car entries))
    (else (car (sort entries (lambda (a b)
                               (> (rank-fn a wi) (rank-fn b wi))))))))

(define (budget-key aid) (cons (quote hours) aid))   ; a pair, which no time bucket "aid|bucket" string can equal
(define (person-budget pool aid dates)
  "The hours AID offers on DATES (the week when none are named): the fullest of
   their entries' readings, since each skill entry carries the same body's window."
  (pool-agent-hours pool aid dates))

(define* (deploy-one-intent wi pid scale pool booked #:key (rank-fn #f) (admit? #f) (dates '()))
  "Try to assign one work-intent. Returns (commitment pool booked) or #f.
   ADMIT? (entry wi pid → bool), when given, is a HARD filter beside the
   booking check — the steward gate: may this person draw the means the
   intent's process uses. RANK-FN only orders what ADMIT? lets through.
   A body has one budget: the hours it offers on DATES (its week when none are
   named) less the hours already assigned it in BOOKED, whatever the skill, so
   a person with several skills is not assigned more than they have."
  (let* ((tb  (or (window-time-bucket (intent-availability-window wi)) "any"))
         (hrs (snap-to-atomic (* scale (intent-hours wi))
                              (let ((mq (intent-minimum-quantity wi)))
                                (and mq (measure-has-numerical-value mq)))))
         (candidates (pool-query pool
                       #:skill (intent-skill wi)
                       #:cell (intent-at-location wi)
                       #:radius 50))
         (free (filter (lambda (e)
                         (and (not (hashmap-ref booked
                                     (string-append (entry-agent e) "|" tb) #f))
                              (<= hrs (+ 1e-9 (- (person-budget pool (entry-agent e) dates)
                                                 (hashmap-ref booked (budget-key (entry-agent e)) 0))))
                              (or (not admit?) (admit? e wi pid))))
                       candidates))
         (pick (best-candidate free wi rank-fn)))
    (and pick (> hrs 0)
         (list (make-labour-commitment pid (entry-agent pick) (intent-skill wi)
                                       (intent-availability-window wi) hrs
                                       (intent-id wi)
                                       (intent-input-of wi) (intent-at-location wi)
                                       (intent-in-scope-of wi))
               (pool-remove pool (entry-agent pick) (entry-skill pick))
               (hashmap-set (hashmap-set booked (string-append (entry-agent pick) "|" tb) #t)
                            (budget-key (entry-agent pick))
                            (+ hrs (hashmap-ref booked (budget-key (entry-agent pick)) 0)))))))

;; ── Seeding: standing commitments enter before any new assignment ───────────
;; docs/planning/solve/commitment-horizon.md — the deployment half of an accept, and
;; the tentative half of a hold. An ACCEPT consumes its provider's pool entry
;; and books the slot: the mirror of what deploy-one-intent does when it
;; assigns, so a person already committed is never assigned twice. A HOLD (an
;; offer under live consideration) books the slot only — the pool entry stays,
;; so the person remains assignable in other time buckets while they decide.
(define (seed-deployment pool booked coms consume?)
  (fold (lambda (c pb)
          (let ((agent (commitment-provider c))
                (skill (commitment-resource-conforms-to c))
                (tb    (or (window-time-bucket (commitment-availability-window c)) "any")))
            (unless (and agent skill)
              (error "seed-deployment: a seeded commitment needs a provider and a skill"
                     (commitment-id c)))
            (cons (if consume? (pool-remove (car pb) agent skill) (car pb))
                  (let ((bk (hashmap-set (cdr pb) (string-append agent "|" tb) #t)))
                    ;; an accepted commitment spends the body's hours; a hold only keeps the slot
                    (if consume?
                        (hashmap-set bk (budget-key agent)
                                     (+ (hashmap-ref bk (budget-key agent) 0)
                                        (let ((q (commitment-effort-quantity c)))
                                          (or (and q (measure-has-numerical-value q)) 0))))
                        bk)))))
        (cons pool booked) coms))

(define* (greedy-deploy proposals wi-by-prop scales pool
                        #:key (rank-fn #f) (seed '()) (tentative '()) (admit? #f))
  (let* ((s1 (seed-deployment pool (hashmap) seed #t))
         (s2 (seed-deployment (car s1) (cdr s1) tentative #f))
         (dates (demand-dates wi-by-prop)))
  (let loop ((ps proposals) (cmts '()) (p (car s2)) (bk (cdr s2)))
    (if (null? ps) (cons (reverse cmts) p)
        (let* ((prop (car ps))
               (scale (or (alist-get scales (proposal-id prop)) 0))
               (wis (or (alist-get wi-by-prop (proposal-id prop)) '()))
               (pid (let ((n (proposal-name prop)))
                      (if (and n (> (string-length n) 5)
                               (string=? "plan:" (substring n 0 5)))
                          (substring n 5) (proposal-id prop)))))
          (if (zero? scale) (loop (cdr ps) cmts p bk)
              (let wi-loop ((wis wis) (cmts cmts) (p p) (bk bk))
                (if (null? wis) (loop (cdr ps) cmts p bk)
                    (let ((r (deploy-one-intent (car wis) pid scale p bk
                                                #:rank-fn rank-fn #:admit? admit? #:dates dates)))
                      (if r
                          (wi-loop (cdr wis) (cons (car r) cmts)
                                   (cadr r) (caddr r))
                          (wi-loop (cdr wis) cmts p bk)))))))))))


;;; ── Score ───────────────────────────────────────────────────────────────────

(define* (score proposals voice-weights scales deployment
                #:key (affinity-fn #f) (continuity-fn #f))
  (+ (fold (lambda (prop acc)
             (let* ((w (or (alist-get voice-weights (proposal-id prop)) 1))
                    (x (or (alist-get scales (proposal-id prop)) 0))
                    (u (max 0 (- 1 x))))
               (- acc (* w u u))))
           0 proposals)
     (if (or affinity-fn continuity-fn)
         (fold (lambda (c acc)
                 (let ((a (if affinity-fn (affinity-fn (commitment-provider c)
                                                       (commitment-planned-within c)) 0))
                       (k (if continuity-fn (continuity-fn (commitment-provider c)
                                                            (commitment-availability-window c)) 0)))
                   (- acc (+ (* a a) (* k k)))))
               0 deployment)
         0)))


;;; ── Demand / supply keys ────────────────────────────────────────────────────

(define (demand-keys proposals wi-by-prop scales)
  (hm->alist
   (fold (lambda (prop hm)
           (let ((x (or (alist-get scales (proposal-id prop)) 0)))
             (fold (lambda (wi hm)
                     (let ((k (tkey (intent-skill wi) (intent-at-location wi)
                                    (intent-availability-window wi))))
                       (hashmap-set hm k (+ (hashmap-ref hm k 0) (* x (intent-hours wi))))))
                   hm (or (alist-get wi-by-prop (proposal-id prop)) '()))))
         (hashmap) proposals)))

(define (demand-dates wi-by-prop)
  "The dates the work-intents ask for, as a set of ISO days — every intent's
   own [beginning, end]. Empty where no intent names a day."
  (delete-duplicates
   (append-map (lambda (pr)
                 (append-map (lambda (wi)
                               (let ((b (intent-has-beginning wi)) (e (intent-has-end wi)))
                                 (if (and (string? b) (string? e)) (iso-dates-through b e) '())))
                             (cdr pr)))
               wi-by-prop)))

;; Supply in the demand's own denomination. An entry carries a WEEK of hours
;; (the recurring window's one date-free measure); a demand asks for hours
;; on the days its intents name. So the supply that meets it is the window
;; read on those days — the roster's twin of the solver's period
;; intersection — and only a demand naming no day meets the whole week.
(define (supply-keys pool dates)
  (hm->alist
   (fold (lambda (e hm)
           (let ((k (tkey (entry-skill e) (entry-cell e) (entry-window e)))
                 (h (if (null? dates) (entry-hours e) (entry-hours-on e dates))))
             (hashmap-set hm k (+ (hashmap-ref hm k 0) h))))
         (hashmap) (pool-entries pool))))

(define (hm->alist hm) (hashmap-fold (lambda (k v a) (cons (cons k v) a)) '() hm))


;;; ── Solver ──────────────────────────────────────────────────────────────────

(define* (solve-uc-matching proposals plan-store pool
                            #:key (voice-weight-fn #f)
                                  (affinity-fn #f) (continuity-fn #f)
                                  (rank-fn #f) (seed '()) (tentative '())
                                  (plan-store-of #f) (admit? #f))
  ;; #:plan-store-of resolves each proposal to the plan-store that published
  ;; it — a federation-wide call carries proposals from many scopes' stores
  ;; through one solve, so the pulls coordinate every scope's scale
  ;; decision against the one pool.
  (if (null? proposals)
      `((plan-scales . ()) (deployment . ()) (score . 0) (iterations . 0))
      (let* ((store-of (or plan-store-of (lambda (_) plan-store)))
             (wi-by (map (lambda (p) (cons (proposal-id p)
                                           (proposal-work-intents p (store-of p))))
                         proposals))
             (vw (map (lambda (p) (cons (proposal-id p)
                                        (if voice-weight-fn (voice-weight-fn p) 1)))
                      proposals))
             (sk (supply-keys pool (demand-dates wi-by))))
        (let loop ((λ (make-pull-tensor)) (n 0)
                   (best -inf.0) (best-s '()) (best-d '()))
          (if (>= n *max-iterations*)
              `((plan-scales . ,best-s) (deployment . ,best-d)
                (score . ,best) (iterations . ,n) (pulls . ,λ))
              (let* ((scales (map (lambda (p)
                                   (cons (proposal-id p)
                                         (optimal-scale
                                          (or (alist-get wi-by (proposal-id p)) '())
                                          (or (alist-get vw (proposal-id p)) 1) λ #f)))
                                 proposals))
                     (dep (car (greedy-deploy proposals wi-by scales pool
                                              #:rank-fn rank-fn #:admit? admit?
                                              #:seed seed #:tentative tentative)))
                     (s (score proposals vw scales dep
                           #:affinity-fn affinity-fn #:continuity-fn continuity-fn))
                     (dk (demand-keys proposals wi-by scales))
                     (g (compute-subgradient dk sk))
                     (λ* (subgradient-step λ g (/ *initial-step-size* (sqrt (+ n 1)))))
                     (better? (> s best))
                     (done? (and (> n 0) (< (abs (- s best)) *convergence-epsilon*))))
                (if done?
                    `((plan-scales . ,(if better? scales best-s))
                      (deployment . ,(if better? dep best-d))
                      (score . ,(max s best))
                      (iterations . ,(+ n 1))
                      (pulls . ,λ*))
                    (loop λ* (+ n 1)
                          (if better? s best)
                          (if better? scales best-s)
                          (if better? dep best-d)))))))))
