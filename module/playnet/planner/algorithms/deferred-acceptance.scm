;;; algorithms/deferred-acceptance.scm — Producer-proposing Gale-Shapley.
;;;
;;; After plan scales are committed, assigns specific producers to
;;; work-slots. Each producer proposes to their top-ranked slot
;;; (ranked by affinity + continuity); slots tentatively accept the
;;; best proposer (within-plan tie-breaking by voice weight). Yields
;;; a stable, Pareto-optimal, preference-respecting assignment.

(define-module (playnet planner algorithms deferred-acceptance)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  ;; NB: this matcher is a pure, self-contained algorithm over agent/slot
  ;; strings — it does not reference plan-bundle or uc-matching, so those
  ;; imports were removed (they only pulled in the heavy (playnet planner)
  ;; umbrella). Keeps the matcher loadable on its own.
  #:export (deferred-acceptance assign-slots
            make-producer-prefs producer-prefs?
            pp-agent pp-ranked-slots pp-voice-weight
            build-producer-rankings))


(define-record-type <producer-prefs>
  (make-producer-prefs agent ranked-slots voice-weight)
  producer-prefs?
  (agent        pp-agent)
  (ranked-slots pp-ranked-slots)
  (voice-weight pp-voice-weight))


;;; ── Preference ranking ──────────────────────────────────────────────────────

(define* (build-producer-rankings agents slots
                                  #:key (affinity-fn #f) (continuity-fn #f)
                                        (voice-weight-fn #f))
  "Build <producer-prefs> for each agent. Slots are ranked by
   affinity (worked there before) + continuity (consecutive blocks).
   AFFINITY-FN: (agent-id plan-id → score), higher = preferred.
   CONTINUITY-FN: (agent-id time-window → score), higher = preferred."
  (map (lambda (agent-id)
         (let* ((scored
                 (map (lambda (slot-key)
                        (let ((aff (if affinity-fn
                                       (affinity-fn agent-id slot-key)
                                       0))
                              (cont (if continuity-fn
                                        (continuity-fn agent-id slot-key)
                                        0)))
                          (cons slot-key (+ aff cont))))
                      slots))
                (ranked (map car (sort scored (lambda (a b) (> (cdr a) (cdr b)))))))
           (make-producer-prefs agent-id ranked
                                (if voice-weight-fn
                                    (voice-weight-fn agent-id)
                                    1))))
       agents))


;;; ── Core DA algorithm ───────────────────────────────────────────────────────

(define (deferred-acceptance producer-prefs slots)
  "Producer-proposing deferred acceptance with voice tiebreak.
   PRODUCER-PREFS: list of <producer-prefs>.
   SLOTS: list of slot-key strings (each has capacity 1).
   Returns alist of (slot-key . agent-id)."
  (let loop ((free (map (lambda (p) (cons p (pp-ranked-slots p)))
                        producer-prefs))
             (assigned (hashmap))
             (holder-voice (hashmap))
             (changed? #t))
    (if (or (null? free) (not changed?))
        (hashmap-fold (lambda (k v acc) (cons (cons k v) acc))
                      '() assigned)
        (let propose ((remaining free)
                      (next-free '())
                      (asgn assigned)
                      (hv holder-voice)
                      (any-change? #f))
          (if (null? remaining)
              (loop next-free asgn hv any-change?)
              (let* ((entry (car remaining))
                     (pp    (car entry))
                     (prefs (cdr entry))
                     (agent (pp-agent pp))
                     (voice (pp-voice-weight pp)))
                (if (null? prefs)
                    (propose (cdr remaining) next-free asgn hv any-change?)
                    (let* ((top-slot (car prefs))
                           (rest-prefs (cdr prefs))
                           (current (hashmap-ref asgn top-slot #f))
                           (cur-voice (hashmap-ref hv top-slot 0)))
                      (cond
                        ((not current)
                         (propose (cdr remaining) next-free
                                  (hashmap-set asgn top-slot agent)
                                  (hashmap-set hv top-slot voice)
                                  #t))
                        ((> voice cur-voice)
                         (let ((rejected-pp
                                (find (lambda (p) (equal? (pp-agent p) current))
                                      (map car free))))
                           (propose (cdr remaining)
                                    (if rejected-pp
                                        (cons (cons rejected-pp
                                                    (remaining-prefs
                                                     rejected-pp top-slot))
                                              next-free)
                                        next-free)
                                    (hashmap-set asgn top-slot agent)
                                    (hashmap-set hv top-slot voice)
                                    #t)))
                        (else
                         (propose (cdr remaining)
                                  (cons (cons pp rest-prefs) next-free)
                                  asgn hv any-change?)))))))))))

(define (remaining-prefs pp rejected-slot)
  "Remaining preference list for PP after REJECTED-SLOT."
  (let skip ((slots (pp-ranked-slots pp)))
    (cond ((null? slots) '())
          ((equal? (car slots) rejected-slot) (cdr slots))
          (else (skip (cdr slots))))))


;;; ── MANY-TO-ONE, by seat expansion ──────────────────────────────────────────
;;; `deferred-acceptance` matches one slot to one producer, and a producer to at
;;; most one slot. Real work is many-to-one: a person takes several shifts, and
;;; the classical reduction is to let them propose as several SEATS — id~1, id~2,
;;; … — which the matching then fills independently and which collapse back to
;;; the person on the way out. Stability is preserved because the seats of one
;;; person are indistinguishable to every slot.
;;;
;;; It was written out by hand at the one call site that needed it
;;; (relaxation.scm `assign-labour`), which is the wrong place for it: the
;;; expansion is a property of the ALGORITHM's arity, not of any caller's
;;; domain, and the second caller would have copied it. It lives beside the
;;; matcher it adapts, and takes its domain knowledge as functions:
;;;
;;;   CAPACITY  producer → how many slots they could take (≥ 0)
;;;   ELIGIBLE? producer × slot → may this person do this work at all (skill,
;;;             place, licence — a HARD filter, not a preference)
;;;   RANK      producer × slot → higher is more wanted, ordering that
;;;             producer's proposals. This is where continuity ("I did this
;;;             last week, leave it with me") and its opposite, rotation, live.
;;;   VOICE     producer → the slot's tie-break when two people want it. The
;;;             plan's own fairness belongs here: score a person by how far
;;;             BELOW their planned share they are and the whole-number
;;;             assignment recovers what the fractional one intended.
(define* (assign-slots slots producers
                       #:key (capacity (lambda (p) 1))
                             (eligible? (lambda (p s) #t))
                             (rank (lambda (p s) 0))
                             (voice (lambda (p) 1)))
  "Assign each of SLOTS to at most one of PRODUCERS, a producer taking up to
   (CAPACITY p) of them. → ((slot . producer) …), unfilled slots absent."
  (let* ((seat-sep #\~)
         (seats (append-map
                 (lambda (p)
                   (let ((mine (sort (filter (lambda (s) (eligible? p s)) slots)
                                     (lambda (a b) (> (rank p a) (rank p b)))))
                         (cap (max 0 (inexact->exact (floor (capacity p))))))
                     (if (null? mine) '()
                         (map (lambda (j)
                                (make-producer-prefs
                                 (string-append p (string seat-sep) (number->string (+ j 1)))
                                 mine (voice p)))
                              (iota cap)))))
                 producers)))
    (if (or (null? slots) (null? seats)) '()
        (map (lambda (kv) (cons (car kv) (car (string-split (cdr kv) seat-sep))))
             (deferred-acceptance seats slots)))))
