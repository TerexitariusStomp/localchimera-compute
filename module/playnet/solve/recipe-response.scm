;;; solve/recipe-response.scm — a recipe's response, read off its runs.
;;;
;;; docs/planning/solve/recipe-metabolism-barbell.md, "The mechanism". Under common
;;; property the solve believes coefficients and coefficients command universal
;;; means, so what a recipe yields has to be READ from what its runs actually
;;; did — never stored, never self-declared: "the comparator's output is a
;;; response profile, not a verdict."
;;;
;;; THE RESPONSE IS A CURVE, AND THE PLAN READS IT (docs/playnet.typ, "every
;;; wall in the solve is approached on a curve"; "observed fulfillment ratios
;;; become the next scenario forecasts"). Per channel — each of its own flows:
;;; its output, each input, the skill it works — a recipe's runs trace how
;;; much of the achievable it captured at each stress the weather delivered
;;; there:
;;;
;;;   the CURVE   one reading per stress level observed; between two levels,
;;;               in proportion; lighter than the record, the lightest
;;;               reading holds; heavier than the record, harm continues at
;;;               the last observed rate and a gain holds where it stood
;;;   the SHOCKS  in each future, the recipe's own processes yield what the
;;;               curve says at that future's stress (`response-shocks`) —
;;;               one more shock, composed with the weather's by the one
;;;               matcher (shocks.scm branch-flow-factor)
;;;   the REACH   a record is a proof up to the heaviest stress it has met
;;;               (`curve-reach`, `response-coverage`)
;;;   the MARGIN  in the future a floor is defended in without a forecast,
;;;               a recipe yields by how far its record covers that future,
;;;               against the best-covered recipe for the same output
;;;               (`margin-shocks`): needs rest on what has been proven
;;;
;;; The solve does the responding. Floors hold in every future, so a plan
;;; leans on a recipe in each future by what the recipe delivers there, and
;;; each future is read on its own, never at the mean of them: a response
;;; that bends is felt as it bends (docs/antifragile/DarwinCollege.pdf §VII).
;;;
;;; WHICH READING, where several runs witnessed one stress level, is the
;;; regime's (science.html's licensing rule, the barbell's principle 4):
;;;   'probability-free  the most adverse capture witnessed — the default,
;;;                      for the unknown and for honest ignorance, because
;;;                      the error is asymmetric and a small sample hides its
;;;                      bad runs ("the empirical distribution is not
;;;                      empirical", docs/antifragile/statistics.pdf §3.4)
;;;   'statistical       their mean — licensed by a witnessed claim of thin
;;;                      tails AND a stable process; capture is a bounded
;;;                      ratio, where a mean is a sound reading (§3.4, Remark
;;;                      3.1), and every run counts in it
;;;
;;; THE WORDS DESCRIBE. Fragile, antifragile, robust, proportional are read
;;; off the three stress levels that bend the most — the gap between the
;;; middle reading and the straight line joining the outer two, in points of
;;; capture — and are shown; the solve reads the curve.
;;;
;;;   fragile       harm that accelerates: capture falls over the heavier
;;;                 step, faster than over the lighter one
;;;   antifragile   a gain that accelerates
;;;   robust        no bend, and capture holds across the stress observed
;;;   proportional  no bend, and capture moves with the stress
;;;   unobserved    fewer than three stress levels: no three runs to read
;;;
;;; A RUN is (capture . ((channel . stress) …)), read by `run-reading` off
;;; its claims (action spec intended realized):
;;;   capture   what it made of what its weather allowed, in points
;;;             (0..100): its outputs against their claims scaled by the
;;;             day's sky on them and by the scarcest input that reached it
;;;   stress    on the channels the run is FILED under (`file-run`): the
;;;             channel its weather pressed hardest, each of them on a tie,
;;;             and every channel at 0 for a calm run. An input's stress is
;;;             its own shortfall, an output's the day's sky on it, so a
;;;             shortage of hands that cut the output shows on the work
;;;             channel, and a recipe alone under its sky still has one
;;;
;;; A flow the weather has never pressed has no curve of its own. Pressed for
;;; the first time, in a future, it reads the most adverse response the recipe
;;; has shown at that stress on any flow: ignorance reads as the dangerous
;;; case, and the first run under that weather replaces the borrowed reading.
;;;
;;; A CHANNEL is (action . spec), one of the recipe's own flows, and STRESS
;;; IS ONE QUESTION ASKED OF ONE FUNCTION (shocks.scm flows-stress): a run's
;;; sky and a future's forecast are both shock lists, each read as what it
;;; does to those flows. A record therefore reaches every future that touches
;;; the recipe, whatever the shocks are keyed on: its own flows are the key.
;;;
;;; A RESPONSE is what a solve takes of one recipe, an alist:
;;;   procs     its acts
;;;   flows     its own flows ((action proc spec) …)
;;;   curves    ((channel . curve) …), '() before any run
;;;   position  experimental (every run calm, or none) | observed
;;;   output    the spec it exists to make
;;;
;;; Pure — no observer reference, no vat: the live adapter that assembles runs
;;; from `events-for-process` + fulfillment links is
;;; governance/recipe-standing.scm.

(define-module (playnet solve recipe-response)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf formulas shocks) #:select (more-adverse scenario-shocks scenario-with-shocks shock-action
                           flows-factor factor-stress flows-stress tail-scenario? %stress-band))
  #:use-module ((playnet vf formulas actions) #:select (action-input-output))
  #:use-module ((playnet vf beyond scenario) #:select (make-planning-scenario))
  #:export (%word-tolerance
            observed-capture file-run run-reading
            response-curve capture-at response-factor response-shocks
            curve-reach response-coverage standing-position
            response-margin margin-shocks futures-under-record
            triple-reading loudest-bend response-word response-fit
            recipe-response-report))

;; how large a bend reads as one, in points of capture — a tenth of the
;; achievable. The face's word alone: the solve reads the curve and never this.
(define %word-tolerance 10.0)

;; observed/claimed over one run's observation tuples (action spec intended
;; realized) — the calibrate-shocks shape, read as a capture percentage.
(define (observed-capture tuples)
  (let ((intended (fold (lambda (o a) (+ a (list-ref o 2))) 0.0 tuples))
        (realized (fold (lambda (o a) (+ a (list-ref o 3))) 0.0 tuples)))
    (if (> intended 0.0) (* 100.0 (/ realized intended)) 0.0)))

(define (file-run stresses)
  "STRESSES ((channel . stress) …), what a run's sky delivered to each of its
   flows → those the run is filed under: the heaviest, each of them on a
   tie, and all of them at 0 for a calm run."
  (let ((top (fold max 0.0 (map cdr stresses))))
    (filter (lambda (cs) (= (cdr cs) top)) stresses)))

;; ── a run, read ──────────────────────────────────────────────────────────────
;; What a run draws and what it makes are two readings. Its INPUTS arriving
;; short — hours, seed, a used means — are weather it worked under, whoever
;; else ran that day; its OUTPUT against what that weather allowed is what it
;; captured. So a recipe alone under its sky still has one: the stress is read
;; off what reached it, the capture off what it made of that.
;;
;;   the stress   on an input, its own shortfall (realized under intended);
;;                on an output, what the day's sky did to that output — the
;;                best of the day's runs, as SKY-SHOCKS carry it
;;   the allowed  an output's claim × the sky's factor on it × the scarcest
;;                input's share: independent pressures compose as every
;;                shock does (shocks.scm branch-flow-factor)
;;   the capture  what it made, of that
;;
;; A run that recorded no output is read on what it did record: each claim
;; against what the sky allowed of it, and the sky's stress on its flows.
;; A shortfall is read as weather; where it was the run's own doing, the
;; capture still says what the run made of what it had.
;;
;; Which side of the process a claim stands on is the action table's word
;; (schemas.scm action-input-output). A claim on neither side — a transfer, a
;; move — is no part of what the run drew or made, and is left out of both.
(define (claim-side t)
  (case (action-input-output (car t))
    ((input) 'in) ((output output-input) 'out) (else #f)))

(define (run-reading pid raw sky-shocks)
  "RAW ((action spec intended realized) …), one run's claims as they were
   made, and SKY-SHOCKS, the day's sky in normal form → (capture stresses
   tuples): the run's capture in points, the ((channel . stress) …) it is
   filed under, and its tuples with each intended scaled to what was
   allowed. What the weather allowed of a flow and how hard it pressed on it
   are one reading (shocks.scm flows-factor)."
  (let* ((ins   (filter (lambda (t) (eq? 'in (claim-side t))) raw))
         (outs  (filter (lambda (t) (eq? 'out (claim-side t))) raw))
         (flows (map (lambda (t) (list (car t) pid (cadr t))) (append ins outs)))
         (scale (lambda (t f) (list (car t) (cadr t) (* (caddr t) f) (cadddr t))))
         (read  (lambda (shocks)
                  (let ((factors (flows-factor shocks flows)))
                    (cons (lambda (t) (assoc-ref factors (cons (car t) (cadr t))))
                          (file-run (map (lambda (cf) (cons (car cf) (factor-stress (cdr cf)))) factors)))))))
    (if (null? outs)
        (let* ((r (read sky-shocks))
               (tuples (map (lambda (t) (scale t ((car r) t))) ins)))
          (list (observed-capture tuples) (cdr r) tuples))
        (let* ((short (filter-map (lambda (t)
                                    (and (> (caddr t) 0.0) (< (cadddr t) (caddr t))
                                         (list (car t) (cadr t) #f (/ (cadddr t) (caddr t)))))
                                  ins))
               (share (fold min 1.0 (map cadddr short)))
               (r     (read (append short
                                    (remove (lambda (sh) (eq? 'input (action-input-output (shock-action sh))))
                                            sky-shocks))))
               (made  (map (lambda (t) (scale t (* ((car r) t) share))) outs)))
          (list (observed-capture made) (cdr r) (append made ins))))))

(define (%points runs channel)
  (filter-map (lambda (r)
                (let ((s (assoc-ref (cdr r) channel)))
                  (and s (cons s (car r)))))
              runs))

;; capture is an output: the adverse direction is down
(define (adverse a b) (more-adverse 'produce a b))

;; ── the curve ────────────────────────────────────────────────────────────────
(define* (response-curve pts #:key (regime 'probability-free))
  "PTS ((stress . capture) …) → ((stress . reading) …), one per stress level
   observed, lightest first. REGIME picks the reading where several runs
   witnessed one level: the most adverse, or under 'statistical their mean."
  (let loop ((ps (sort pts (lambda (a b) (< (car a) (car b))))) (out '()))
    (if (null? ps) (reverse out)
        (let* ((s (caar ps))
               (here (map cdr (take-while (lambda (p) (= (car p) s)) ps)))
               (rest (drop-while (lambda (p) (= (car p) s)) ps)))
          (loop rest
                (cons (cons s (if (eq? regime 'statistical)
                                  (/ (fold + 0.0 here) (length here))
                                  (fold adverse (car here) (cdr here))))
                      out))))))

(define (capture-at curve s)
  "What CURVE reads at stress S, or #f for an empty curve: the reading at an
   observed level; in proportion between two; the lightest reading below the
   record; above it, harm continued at the last observed rate (never under
   zero) and a gain held where it stood."
  (cond ((null? curve) #f)
        ((null? (cdr curve)) (cdar curve))
        ((<= s (caar curve)) (cdar curve))
        (else
         (let loop ((c curve))
           (let ((a (car c)) (b (cadr c)))
             (cond ((<= s (car b))                                   ; between a and b
                    (+ (cdr a) (* (- (cdr b) (cdr a)) (/ (- s (car a)) (- (car b) (car a))))))
                   ((pair? (cddr c)) (loop (cdr c)))
                   (else                                             ; past the heaviest level
                    (let ((rate (/ (- (cdr b) (cdr a)) (- (car b) (car a)))))
                      (if (< rate 0.0)
                          (max 0.0 (+ (cdr b) (* rate (- s (car b)))))
                          (cdr b))))))))))

;; ── the shocks a record lays over a future ───────────────────────────────────
(define (response-factor curves stresses)
  "CURVES ((channel . curve) …), STRESSES ((channel . stress) …) → what the
   recipe yields of what the weather allows, in [0, 1]: each channel read at
   the stress delivered there (0 where the weather leaves it calm), and
   across channels the most adverse.

   A channel the weather has pressed before is read off its own curve. One
   it has never pressed — no run filed there above calm (`curve-reach` 0) — has shown nothing
   of itself, and ignorance reads as the dangerous case: it takes the most
   adverse reading, at that stress, among the curves the recipe does have.
   Its first run under that weather gives it a curve of its own.

   A record reading above the whole, and a recipe with no record, leave the
   map where it stands."
  (let* ((pressed? (lambda (curve) (> (curve-reach curve) 0.0)))
         (known (filter pressed? (map cdr curves)))
         (reading (lambda (channel stress)
                    (let ((own (assoc-ref curves channel)))
                      (if (pressed? own)
                          (capture-at own stress)
                          (fold (lambda (curve worst)
                                  (let ((c (capture-at curve stress)))
                                    (if worst (adverse worst c) c)))
                                (and own (capture-at own stress))
                                known))))))
    (fold (lambda (channel f)
            (let ((c (reading channel (or (assoc-ref stresses channel) 0.0))))
              (if c (adverse f (/ c 100.0)) f)))
          1.0
          (delete-duplicates (append (map car stresses) (map car curves))))))

(define (response-shocks responses scenario)
  "RESPONSES, one per recipe, SCENARIO a future → the shocks the records lay
   over it: (produce proc factor) on each of a recipe's acts whose record
   reads under the whole at the stress the future delivers to its flows."
  (let ((shocks (scenario-shocks scenario)))
    (append-map
     (lambda (r)
       (let ((f (response-factor (assq-ref r 'curves)
                                 (flows-stress shocks (assq-ref r 'flows)))))
         (if (< f 1.0)
             (map (lambda (proc) (list 'produce proc f)) (assq-ref r 'procs))
             '())))
     responses)))

;; ── reach: a record is a proof up to the heaviest stress it has met ──────────
;; A calm record says nothing of the storm (the turkey, docs/antifragile/
;; statistics.pdf fig. 5.5), and inference is asymmetric: a run can rule a
;; claim out and never in (§3.4). So a recipe is tried UP TO the heaviest
;; stress it has worked under, flow by flow — a proof load, as a crane is
;; rated to the load it was tested at and an aircraft flies inside the
;; envelope it has cleared.
(define (curve-reach curve)
  "The heaviest stress CURVE has a reading at; 0 for no curve."
  (if (or (not curve) (null? curve)) 0.0 (car (last curve))))

(define (response-reach r)
  "The heaviest stress recipe R has met on any flow of its own."
  (fold (lambda (cc m) (max m (curve-reach (cdr cc)))) 0.0 (assq-ref r 'curves)))

(define (response-coverage r stresses)
  "How far R's record reaches of what STRESSES ((channel . stress) …) ask of
   it, in [0, 1]: on each flow pressed, its reach there over the stress
   delivered, and across them the least. A recipe that has never run covers
   nothing; one that has run covers a calm future whole."
  (let ((curves (assq-ref r 'curves)))
    (if (null? curves) 0.0
        (fold (lambda (cs c)
                (if (> (cdr cs) 0.0)
                    (min c (/ (min (cdr cs) (curve-reach (assoc-ref curves (car cs)))) (cdr cs)))
                    c))
              1.0 stresses))))

(define (standing-position rows)
  "'observed once some channel of ROWS (the profile) has a run under stress —
   the record reaches somewhere; 'experimental while every run was calm, or
   there is none."
  (if (any (lambda (r) (> (curve-reach (assq-ref r 'curve)) 0.0)) rows)
      'observed
      'experimental))

;; ── the margin: needs rest on a recipe by how far its record reaches ─────────
;; "We must not expose ourselves to harm in the presence of fragility, but can
;; still take risky decisions if we are bounded for maximum losses"
;; (statistics.pdf §3.4). The bound is a construction: with the safe part
;; covering the need, the loss is bounded "independent from all possible
;; models" (ch. 30). So in the future a floor is defended in without a
;; forecast, a recipe yields in proportion to how far its record covers that
;; future, measured against the best-covered recipe for the same output: the
;; best-evidenced stands as its curve reads, the rest by their share of its
;; reach, and one that has met no such weather yields nothing beside one that
;; has. Floors hold there, so needs rest on what has been proven; the future
;; carries no weight, so wherever it pays the plan still runs the rest.
;;
;; Where no recipe for an output covers anything, each stands as it is: with
;; nothing proven to stand on there is no bound to lay.
(define (same-output? a b)
  (and (assq-ref a 'output) (equal? (assq-ref a 'output) (assq-ref b 'output))))

(define (margin-shocks responses scenario)
  "The margin's shocks in SCENARIO: (produce proc share) on each act of a
   recipe whose record covers less of that future than the best-covered
   recipe for its output; an act several recipes share takes the largest
   share among them."
  (let* ((shocks (scenario-shocks scenario))
         (covered (map (lambda (r) (response-coverage r (flows-stress shocks (assq-ref r 'flows))))
                       responses))
         (share (map (lambda (r c)
                       (let ((best (fold (lambda (o oc m) (if (or (eq? o r) (same-output? o r)) (max m oc) m))
                                         0.0 responses covered)))
                         (if (> best 0.0) (/ c best) 1.0)))
                     responses covered))
         (acts (delete-duplicates (append-map (lambda (r) (assq-ref r 'procs)) responses))))
    (filter-map
     (lambda (proc)
       (let ((f (fold (lambda (r s m) (if (member proc (assq-ref r 'procs)) (max m s) m))
                      0.0 responses share)))
         (and (< f 1.0) (list 'produce proc f))))
     acts)))

(define (response-margin r responses)
  "Where R stands among the recipes for its output, by reach: 'bare — it has
   met no stress and neither has any other, so the need rests on a record
   yet to be pressed; 'bounded — another reaches further, and needs rest on
   that one first; #f — it is the furthest-reaching."
  (let ((mine (response-reach r))
        (best (fold (lambda (o m) (if (and (not (eq? o r)) (same-output? o r)) (max m (response-reach o)) m))
                    0.0 responses)))
    (cond ((> best mine) 'bounded)
          ((= mine 0.0) 'bare)
          (else #f))))

;; ── the futures a solve plans against, with the record laid over them ────────
(define* (futures-under-record futures responses #:optional (seen '()))
  "FUTURES as a solve takes them: each with SEEN (what has been observed of
   the map, true in every future) and the shocks RESPONSES lay over it; the
   margin's shocks in each future of probability zero — the futures a floor
   is defended in without a forecast. A set with none gains one, calm and at
   no weight, when a recipe that has never run stands beside one that has."
  (let* ((tail? tail-scenario?)
         (bare  (make-planning-scenario "untried" #f 0.0 '() "needs stand on the recipes that have run")))
    (map (lambda (s)
           (scenario-with-shocks
            s (append seen (response-shocks responses s)
                      (if (tail? s) (margin-shocks responses s) '()))))
         (if (or (any tail? futures) (null? (margin-shocks responses bare)))
             futures
             (append futures (list bare))))))

;; ── the words: three stress levels and the gap from proportion ───────────────
(define (triple-reading a b c)
  "Three readings (stress . capture), lightest first → (kind . gap) or #f.
   The gap is the middle reading's distance from the straight line joining
   the outer two, in points of capture. 'harm: capture falls over the
   heavier step, faster than over the lighter. 'gain: it rises over the
   heavier step, faster than over the lighter."
  (let* ((light (/ (- (cdr b) (cdr a)) (- (car b) (car a))))
         (heavy (/ (- (cdr c) (cdr b)) (- (car c) (car b))))
         (line  (+ (cdr a) (* (- (cdr c) (cdr a)) (/ (- (car b) (car a)) (- (car c) (car a))))))
         (gap   (- (cdr b) line)))
    (cond ((and (< heavy 0.0) (< heavy light)) (cons 'harm gap))
          ((and (> heavy 0.0) (> heavy light)) (cons 'gain (- gap)))
          (else #f))))

(define (loudest-bend curve kind)
  "The three levels of CURVE that show KIND ('harm | 'gain) by the largest
   gap → ((kind . k) (gap . g) (from . s) (at . s) (to . s)), or #f."
  (let ((best #f))
    (let outer ((as curve))
      (when (and (pair? as) (pair? (cdr as)) (pair? (cddr as)))
        (let mid ((bs (cdr as)))
          (when (pair? (cdr bs))
            (for-each (lambda (c)
                        (let ((r (triple-reading (car as) (car bs) c)))
                          (when (and r (eq? (car r) kind)
                                     (or (not best) (> (cdr r) (assq-ref best 'gap))))
                            (set! best `((kind . ,kind) (gap . ,(cdr r))
                                         (from . ,(caar as)) (at . ,(caar bs)) (to . ,(car c)))))))
                      (cdr bs))
            (mid (cdr bs))))
        (outer (cdr as))))
    best))

(define (response-word curve)
  "CURVE → (word . bend): the word and the three levels it was read off (#f
   where no three levels bend). Harm is read before gain: a response that
   gains under light stress and breaks under heavy is one that breaks."
  (if (< (length curve) 3)
      (cons 'unobserved #f)
      (let* ((harm (loudest-bend curve 'harm))
             (gain (loudest-bend curve 'gain))
             (loud? (lambda (b) (and b (> (assq-ref b 'gap) %word-tolerance))))
             (caps (map cdr curve))
             (spread (- (apply max caps) (apply min caps))))
        (cond ((loud? harm) (cons 'fragile harm))
              ((loud? gain) (cons 'antifragile gain))
              (else (cons (if (<= spread %word-tolerance) 'robust 'proportional)
                          (or (and harm gain (if (>= (assq-ref harm 'gap) (assq-ref gain 'gap)) harm gain))
                              harm gain)))))))

;; ── the licensed description ─────────────────────────────────────────────────
;; Least squares on c = c̄ + k·u + q·v, u the stress about its mean and v the
;; square of u made orthogonal to 1 and u. Attached to a row under
;; 'statistical alone: least squares asks for thin tails, which is what the
;; regime's claim witnesses. The acceleration is the slope's change across
;; half the stress band, with its standard error.
(define (response-fit pts)
  "PTS ((stress . capture) …) → ((slope . k) (accel . a) (se . e)), or #f
   under four runs or three distinct stress levels."
  (let ((n (length pts)))
    (and (>= n 4)
         (let* ((sum (lambda (f) (fold (lambda (p acc) (+ acc (f p))) 0.0 pts)))
                (ms  (/ (sum car) n)) (mc (/ (sum cdr) n))
                (u   (lambda (p) (- (car p) ms)))
                (suu (sum (lambda (p) (expt (u p) 2)))))
           (and (> suu 0.0)
                (let* ((tilt (/ (sum (lambda (p) (expt (u p) 3))) suu))
                       (v    (lambda (p) (- (expt (u p) 2) (/ suu n) (* tilt (u p)))))
                       (svv  (sum (lambda (p) (expt (v p) 2)))))
                  (and (> svv (* 1e-9 suu suu))
                       (let* ((k    (/ (sum (lambda (p) (* (u p) (cdr p)))) suu))
                              (q    (/ (sum (lambda (p) (* (v p) (cdr p)))) svv))
                              (line (sum (lambda (p) (expt (- (cdr p) mc (* k (u p))) 2))))
                              (left (max 0.0 (- line (* q q svv)))))
                         `((slope . ,k)
                           (accel . ,(* q %stress-band))
                           (se    . ,(* %stress-band (sqrt (/ (/ left (- n 3)) svv)))))))))))))

;; ── the profile ──────────────────────────────────────────────────────────────
;; One row per channel any run is filed under, each an alist:
;;   channel   (action . spec), one of the recipe's own flows
;;   word      unobserved | fragile | antifragile | robust | proportional
;;   n         runs on the channel
;;   curve     ((stress . reading) …) — what the plan reads
;;   bend      the three levels the word was read off, or #f
;;   points    the raw (stress . capture) pairs — a record, under either regime
;;   licensed  ((slope . k) (accel . a) (se . e)) under 'statistical, else #f
(define* (recipe-response-report runs #:key (regime 'probability-free))
  (map (lambda (ch)
         (let* ((pts (%points runs ch))
                (curve (response-curve pts #:regime regime))
                (word (response-word curve)))
           `((channel . ,ch) (word . ,(car word)) (n . ,(length pts))
             (curve . ,curve) (bend . ,(cdr word)) (points . ,pts)
             (licensed . ,(and (eq? regime 'statistical) (response-fit pts))))))
       (delete-duplicates (append-map (lambda (r) (map car (cdr r))) runs))))

