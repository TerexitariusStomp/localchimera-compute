;;; matching/feasibility.scm — 7-dimensional feasibility scoring.
;;;
;;; The matcher asks: given two <intent-binding>s — one carrying an
;;; intent with an input-action (the "in side": consume/use/accept)
;;; and one with an output-action (the "out side": produce /
;;; deliver-service) — how well does the out-side fulfill the in-side?
;;;
;;; Each binding references VF records directly:
;;;   - spatial facts → <spatial-thing> on intent-binding-location
;;;   - prior commitment → <commitment> on intent-binding-prior plus
;;;     its <spatial-thing> on intent-binding-prior-location
;;;
;;; Every scorer returns a number in [0, 1]; aggregate confidence is
;;; the product ("chain is as strong as weakest link").

(define-module (playnet planner matching feasibility)
  #:use-module ((playnet planner formulas actions) #:select (input-action?))
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner beyond schedules)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner matching schemas)
  #:use-module (playnet planner facts availability)
  #:use-module (playnet planner matching spatial)
  #:use-module ((playnet planner matching filter-rule) #:select (rule-passes? context))
  #:export (side-agent-key
            score-time
            score-location
            score-skills
            score-travel
            score-resources
            score-affinity
            score-continuity
            calculate-feasibility
            *skill-resolver*))


;;; ── Derived accessors on <intent-binding> ──────────────────────────────────

(define (binding-window b)
  (intent-availability-window (intent-binding-intent b)))

(define (binding-qty b)
  (let ((m (intent-resource-quantity (intent-binding-intent b))))
    (if (and m (measure? m)) (measure-has-numerical-value m) 0)))

(define (criterion b accessor)
  (let ((c (intent-binding-criteria b))) (and c (accessor c))))

(define (location-of b)
  "Return (lat . lng) or #f if B has no usable spatial-thing."
  (let ((loc (intent-binding-location b)))
    (and loc (spatial-thing-lat loc) (spatial-thing-long loc)
         (cons (spatial-thing-lat loc) (spatial-thing-long loc)))))

(define (binding-required-skills b)
  (or (criterion b intent-matching-criteria-required-skills) '()))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  1. TIME — overlap + minimum atomic block                    [symmetric]
;;; ═══════════════════════════════════════════════════════════════════════════

(define (score-time in-side out-side)
  (let ((iw       (binding-window in-side))
        (ow       (binding-window out-side))
        (min-size (criterion in-side intent-matching-criteria-min-atomic-size)))
    (cond
      ((not (availability-windows-overlap? iw ow))      0.0)
      ((or (not min-size) (<= min-size 0))              1.0)
      ((or (not iw) (not ow))                           1.0)
      ((< (window-max-block-minutes
           (calculate-availability-intersection iw ow))
          min-size)                                     0.0)
      (else                                             1.0))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  2. LOCATION — linear distance decay within search radius    [symmetric]
;;; ═══════════════════════════════════════════════════════════════════════════

(define (score-location in-side out-side)
  (let ((iloc (location-of in-side)) (oloc (location-of out-side)))
    (cond
      ((or (binding-remote? in-side) (binding-remote? out-side))  1.0)
      ((or (not iloc) (not oloc))                                 1.0)
      (else
       (let ((dist   (haversine-distance
                      (car iloc) (cdr iloc) (car oloc) (cdr oloc)))
             (radius (or (criterion in-side intent-matching-criteria-search-radius-km)
                         *default-search-radius-km*)))
         (cond ((> dist radius) 0.0)
               (else (max 0 (- 1.0 (/ dist radius))))))))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  3. SKILLS — required skills present on the other side      [symmetric]
;;; ═══════════════════════════════════════════════════════════════════════════
;;;
;;; Skills are EconomicResources in VF. The check is: does the other
;;; side's agent hold resources conforming to each required spec-id?
;;; Uses *skill-resolver* parameter: (agent-id → (spec-id ...)).
;;; When no resolver is set, falls back to agent-profile-skills for
;;; backward compatibility.

(define *skill-resolver* (make-parameter #f))

(define (agent-has-skills? agent-id required-spec-ids)
  "True if AGENT-ID holds all required skill specs."
  (let ((resolve (*skill-resolver*)))
    (if resolve
        (let ((held (resolve agent-id)))
          (every (lambda (spec) (member spec held)) required-spec-ids))
        #t)))

(define (binding-agent-id b)
  (let ((i (intent-binding-intent b)))
    (if (input-action? (intent-action i))
        (intent-receiver i)
        (intent-provider i))))

(define (binding-meets-skills? requirements b)
  (or (not requirements) (null? requirements)
      (let ((aid (binding-agent-id b)))
        (or (not aid)
            (agent-has-skills? aid requirements)))))

(define (score-skills in-side out-side)
  (let ((in-req (binding-required-skills in-side))
        (out-req (binding-required-skills out-side)))
    (cond
      ((not (binding-meets-skills? in-req out-side)) 0.0)
      ((not (binding-meets-skills? out-req in-side)) 0.0)
      (else 1.0))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  4. TRAVEL — spatio-temporal feasibility vs prior commitment  [out-side only]
;;; ═══════════════════════════════════════════════════════════════════════════

(define *tortuosity-factor* 1.5)
(define *max-speed-kmh*     80)
(define *comfort-speed-kmh* 30)

(define (rush-score req-speed)
  (cond ((> req-speed *max-speed-kmh*)        0.0)
        ((<= req-speed *comfort-speed-kmh*)   1.0)
        (else (let ((r (/ (- req-speed *comfort-speed-kmh*)
                          (- *max-speed-kmh* *comfort-speed-kmh*))))
                (max 0.1 (- 1.0 (* r 0.9)))))))

(define (and=> v f) (if v (f v) #f))

(define (datetime-hhmm s)
  (and s (string? s)
       (let* ((t (or (and=> (string-index s #\T) (lambda (i) (substring s (+ i 1))))
                     s))
              (colon (string-index t #\:)))
         (and colon
              (let ((h (string->number (substring t 0 colon)))
                    (m (string->number (substring t (+ colon 1)
                                                  (min (string-length t) (+ colon 3))))))
                (and h m (+ (* h 60) m)))))))

(define (score-travel out-side)
  (let* ((prev     (intent-binding-prior out-side))
         (prev-loc (intent-binding-prior-location out-side))
         (oloc     (location-of out-side))
         (raw      (and prev prev-loc oloc
                        (spatial-thing-lat  prev-loc)
                        (spatial-thing-long prev-loc)
                        (haversine-distance
                         (spatial-thing-lat  prev-loc)
                         (spatial-thing-long prev-loc)
                         (car oloc) (cdr oloc))))
         (tr       (window-first-time-range (binding-window out-side)))
         (prev-end (and prev (datetime-hhmm (commitment-has-end prev))))
         (out-start (and tr (datetime-hhmm (time-range-start-time tr)))))
    (cond
      ((not raw)             1.0)   ;; no prior or no coords
      ((<= raw 0.1)          1.0)   ;; same place
      ((or (not prev-end) (not out-start)) 1.0)
      (else
       (let ((delta-hr (/ (- out-start prev-end) 60.0)))
         (cond ((<= delta-hr 0) 0.0)
               (else (rush-score (/ (* raw *tortuosity-factor*) delta-hr)))))))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  5. RESOURCES — out-side quantity vs in-side quantity         [asymmetric]
;;; ═══════════════════════════════════════════════════════════════════════════

(define (score-resources in-side out-side)
  (let ((iq (binding-qty in-side)) (oq (binding-qty out-side)))
    (cond ((<= iq 0)  1.0)
          ((>= oq iq) 1.0)
          ((<= oq 0)  0.0)
          (else       (/ oq iq)))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  6. AFFINITY — two-way social trust (min of both directions) [symmetric]
;;; ═══════════════════════════════════════════════════════════════════════════

(define (trust-weight pubkey weights)
  (cond ((or (not pubkey) (not weights)) 1.0)
        (else (let ((p (assoc pubkey weights))) (if p (cdr p) 0.1)))))

(define (side-agent-key b)
  "The public key THIS side presents: provider on output-actions, receiver on input-actions."
  (let ((i (intent-binding-intent b)))
    ((if (input-action? (intent-action i)) intent-receiver intent-provider) i)))

(define* (side-context me other #:optional knows)
  "The context MY eligibility rule reads about the OTHER side: who they are,
   how much I recognize them, where they stand, how far, what they hold.
   KNOWS, when given, is the social reading ((my-key their-key) → alist,
   governance's make-knows): my groups and vouches for them."
  (let* ((key (side-agent-key other)) (i (intent-binding-intent other))
         (a (location-of me)) (b (location-of other))
         (w (intent-binding-weights me)))
    (context #:aid key
             #:recognition (and w key (let ((p (assoc key w))) (and p (cdr p))))
             #:knows (and knows key (knows (side-agent-key me) key))
             #:scopes (intent-in-scope-of i)
             #:skills (criterion other intent-matching-criteria-required-skills)
             #:distance-km (and a b (haversine-distance (car a) (cdr a) (car b) (cdr b))))))

(define* (eligible? in-side out-side #:optional knows)
  "Both eligibility rules admit the other side — the pre-gate every score sits behind."
  (and (rule-passes? (criterion in-side intent-matching-criteria-filter-rule)
                     (side-context in-side out-side knows))
       (rule-passes? (criterion out-side intent-matching-criteria-filter-rule)
                     (side-context out-side in-side knows))))

(define (score-affinity in-side out-side)
  (if (not (eligible? in-side out-side)) 0
      (min (trust-weight (side-agent-key out-side) (intent-binding-weights in-side))
           (trust-weight (side-agent-key in-side)  (intent-binding-weights out-side)))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  7. CONTINUITY — fragmentation penalty                      [symmetric]
;;; ═══════════════════════════════════════════════════════════════════════════

(define (score-continuity in-side out-side)
  (let ((iw (binding-window in-side))
        (ow (binding-window out-side)))
    (cond
      ((or (not iw) (not ow)) 1.0)
      (else
       (let* ((isct   (calculate-availability-intersection iw ow))
              (n      (window-block-count isct))
              (mins   (window-total-minutes isct))
              (target (or (criterion in-side intent-matching-criteria-min-atomic-size)
                          60)))
         (cond ((= n 0)   0.0)
               ((<= n 1)  1.0)
               (else
                (let* ((avg     (/ mins n))
                       (penalty (if (< avg target) (/ avg target) 1.0)))
                  (* (/ 1.0 n) penalty)))))))))


;;; ═══════════════════════════════════════════════════════════════════════════
;;;  MAIN ENTRY
;;; ═══════════════════════════════════════════════════════════════════════════

(define *score-table*
  ;; (dim  reason-when-zero  risk-when-below-threshold)
  `((time       "TIME_MISMATCH"          ,#f)
    (location   "LOCATION_MISMATCH"      ,#f)
    (skills     "SKILL_MISMATCH"         ,#f)
    (travel     "TRAVEL_TIME_VIOLATION"  "TIGHT_TRAVEL_TIME")
    (resources  "OTHER"                  "PARTIAL_QUANTITY")
    (affinity   "OTHER"                  "LOW_TRUST")
    (continuity ,#f                      "FRAGMENTED_TIME")))

(define (calculate-feasibility in-side out-side)
  "Return a <feasibility-status> for the candidate match between
   IN-SIDE (an <intent-binding> whose intent carries an input-action)
   and OUT-SIDE (an <intent-binding> whose intent carries an
   output-action). Conceptually: 'does out-side's commitment-to-be
   satisfy in-side's intent?'"
  (let* ((s-time      (score-time      in-side out-side))
         (s-location  (score-location  in-side out-side))
         (s-skills    (score-skills    in-side out-side))
         (s-travel    (score-travel    out-side))
         (s-resources (score-resources in-side out-side))
         (s-affinity  (score-affinity  in-side out-side))
         (s-cont      (score-continuity in-side out-side))
         (per-dim     `((time       . ,s-time)
                        (location   . ,s-location)
                        (skills     . ,s-skills)
                        (travel     . ,s-travel)
                        (resources  . ,s-resources)
                        (affinity   . ,s-affinity)
                        (continuity . ,s-cont)))
         (scores      (make-feasibility-scores
                       s-time s-location s-skills s-travel
                       s-resources s-affinity s-cont))
         (reasons     (filter-map
                       (lambda (p)
                         (and (zero? (cdr p))
                              (cadr (assq (car p) *score-table*))))
                       per-dim)))
    (cond
      ((pair? reasons)
       (make-feasibility-status 'impossible 0.0 '() reasons scores))
      (else
       (let ((risks
              (filter-map
               (lambda (p)
                 (let* ((dim   (car p))
                        (score (cdr p))
                        (row   (assq dim *score-table*))
                        (label (caddr row))
                        (threshold (if (eq? dim 'affinity) 0.5 1)))
                   (and label (< score threshold) label)))
               per-dim)))
         (make-feasibility-status
          'possible
          (* s-time s-location s-skills s-travel s-resources s-affinity s-cont)
          risks '() scores))))))
