;;; dev-plan.scm — the development scope's week, planned and read.
;;;
;;; The scope's open issues are wants, its people hold the skills and state
;;; their hours, and the plan is the ordinary one: plan-scope over the scope's
;;; stores. This module states the week's demand, runs the solve, and reads
;;; the result issue by issue — who carries it, or why it waits.
;;;
;;;   week-wants        every want of the week — the ready issues and the
;;;                     meeting — each with the process it runs, the recipe
;;;                     it is made by, the spec it delivers, its weight and
;;;                     its work, all read off the world once
;;;   dev-week-span     the period the plan stands on: seven days from a date
;;;   seed-dev-scope!   the scope's world into a scope-root's stores
;;;   plan-dev-week     the solve; returns plan-scope->alist's result
;;;   read-dev-plan     the result, one row per open issue and the meeting
;;;   rows-led-by       the planned rows one agent leads, first want first
;;;   dev-plan-totals   hours stated, planned and asked, by person and skill
;;;
;;; A week is ONE period: development is an hours-in-the-week budget, so the
;;; people of the scope state hours (recipes/dev.scm dev-hours-of) and the
;;; plan places each whole act in the week. The order of acts inside the
;;; week belongs to the people doing them.

(define-module (playnet dev plan)
  #:use-module (playnet vf formulas flows)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet scope live) #:select (plan-scope->alist))
  #:use-module ((playnet solve engine) #:select (priority-weight))
  #:use-module (playnet knowledge dsl world)
  #:use-module (playnet dev recipes)
  #:use-module ((playnet knowledge recipes meeting) #:select (seed-meeting-recipe))
  #:use-module (playnet dev priorities)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:export (dev-week-span
            week-wants want-work want-ref want-hours
            dev-demand dev-weights week-recipes prio->weight
            seed-dev-scope! plan-dev-week read-dev-plan
            rows-led-by rows-for dev-plan-totals row-ref
            pack-week seed-decision
            read-dev-people person-for-did
            %meeting-spec %meeting-proc %meeting-recipe))

;; ── the scope's people, as the scope states them ─────────────────────────

(define (read-dev-people path)
  "The people of the development scope, read off the file at PATH: one
   datum, a list of people (recipes/dev.scm states a person's shape). Each
   states an id and the hours they give in a week. '() where no file
   stands; a person stating no id or no hours is an error, since a plan over
   hours nobody stated is a plan over nothing."
  (if (not (and path (file-exists? path)))
      '()
      (let ((people (call-with-input-file path read)))
        (unless (list? people)
          (error "dev scope: the file holds one list of people" path))
        (for-each (lambda (p)
                    (unless (and (string? (person-ref p 'id #f))
                                 (real? (person-ref p 'hours #f)))
                      (error "dev scope: a person states an id and hours" p)))
                  people)
        people)))

(define (person-for-did people did)
  "The id of the person of PEOPLE whose Radicle identity is DID, or #f."
  (person-lookup people 'did did 'id))

(define %meeting-spec "spec:meeting-minutes")
(define %meeting-proc "rp-meeting")
(define %meeting-recipe "recipe-meeting")

(define* (dev-week-span #:optional (from (current-date 0)))
  "The week FROM opens, as (first-day . last-day) in ISO dates: the one
   period the plan stands on."
  (let* ((day   (make-date 0 0 0 0 (date-day from) (date-month from) (date-year from) 0))
         (start (date->time-utc day))
         (end   (add-duration start (make-time time-duration 0 (* 6 86400))))
         (iso   (lambda (t) (date->string (time-utc->date t 0) "~Y-~m-~d"))))
    (cons (iso start) (iso end))))

(define (located spec) (string-append spec "#" %dev-place "@0"))

;; a want's weight is the engine's own geometric policy (priority-weight:
;; level 0..9 → 1..1000) read off the `prio:` rank: p0 is the top level, and
;; each rank below it stands two levels down
(define (prio->weight rank)
  (priority-weight (max 0 (- 9 (* 2 rank)))))

;; ── week-wants: the ONE table every other reader maps over ───────────────
;; A want is ((process . pid) (recipe . rid) (spec . spec) (weight . w)
;; (work . ((skill . hours) …))). WORK is read off the world's own `work`
;; flows for the want's process (world-flows-for) — the meeting's four
;; roles and an issue's hours are stated once, in the world the solve
;; itself reads, and every other table here (the demand, the weights, the
;; whole list, the recipes admitted, the seed's packing) is a plain map
;; over this one list. Two issues of the same (kind, hours) shape carry the
;; IDENTICAL process/recipe/spec — engine.scm ingests `demand`/
;; `desire-weights` by overwriting per located key, not summing, so
;; dev-demand/dev-weights below fold same-shape wants into one row rather
;; than emit one each; read-dev-plan recovers which specific issues a
;; shape's produced count covers.

(define (want-work w pid)
  "PID's work flows in world W, as ((skill . hours) …)."
  (filter-map (lambda (f) (and (eq? 'work (recipe-flow-action f))
                               (cons (recipe-flow-resource-conforms-to f)
                                     (measure-has-numerical-value (recipe-flow-effort-quantity f)))))
              (world-flows-for w pid)))

(define (want-ref want key) (assq-ref want key))

(define (want-hours want)
  "The total hours WANT's work asks for."
  (fold (lambda (sh a) (+ a (cdr sh))) 0.0 (want-ref want 'work)))

(define* (week-wants w all-facts #:key (meeting? #t))
  "The week's wants, heaviest first and, among equals, the one asking
   fewest hours first: every ready issue, plus the meeting when MEETING?."
  (define (want pid rid spec weight)
    `((process . ,pid) (recipe . ,rid) (spec . ,spec) (weight . ,weight)
      (work . ,(want-work w pid))))
  (let ((wants (append
                (if meeting? (list (want %meeting-proc %meeting-recipe %meeting-spec (prio->weight 0))) '())
                (map (lambda (f)
                       (let ((kind (issue-kind f)) (hours (issue-hours f)))
                         (want (kind-process* kind hours) (kind-recipe* kind hours)
                               (kind-spec* kind hours) (prio->weight (fact-ref f 'prio)))))
                     (ready-facts all-facts)))))
    (stable-sort wants
                 (lambda (a b) (or (> (want-ref a 'weight) (want-ref b 'weight))
                                   (and (= (want-ref a 'weight) (want-ref b 'weight))
                                        (< (want-hours a) (want-hours b))))))))

(define (fold-by-key wants key combine seed)
  "WANTS folded to one row per distinct located key: COMBINE merges a new
   want's value into what stands, SEED the value a first-seen key starts
   from — the one pattern dev-demand/dev-weights both are."
  (let ((tbl (make-hash-table)))
    (for-each (lambda (wt) (let ((k (located (want-ref wt 'spec))))
                             (hash-set! tbl k (combine (want-ref wt key) (hash-ref tbl k seed)))))
              wants)
    (hash-map->list cons tbl)))

(define* (dev-demand w all-facts #:key (meeting? #t))
  "The week's demand: one located row per distinct shape, its quantity the
   count of ready issues (and the meeting) asking that shape."
  (fold-by-key (week-wants w all-facts #:meeting? meeting?) 'spec
               (lambda (spec acc) (+ 1.0 acc)) 0.0))

(define* (dev-weights w all-facts #:key (meeting? #t))
  "The week's weights: one per distinct shape, the heaviest of its own
   issues' — a shape stands in the solve's tradeoffs as urgent as the most
   urgent issue waiting on it."
  (fold-by-key (week-wants w all-facts #:meeting? meeting?) 'weight max 0.0))

(define* (week-recipes w all-facts #:key (meeting? #t))
  "The ids of the recipes the week's wants are made by."
  (delete-duplicates (map (lambda (want) (want-ref want 'recipe)) (week-wants w all-facts #:meeting? meeting?))))

(define (seed-dev-scope! scope all-facts people)
  "The development world of ALL-FACTS and PEOPLE into SCOPE's stores; every
   add replaces by id, so a scope seeded again stands on today's issues.
   Returns the world."
  (let ((rs ($ scope 'recipe-store)))
    (seed-dev-knowledge! rs)            ; the process specifications the acts conform to
    (seed-meeting-recipe rs))
  (seed-world! scope (dev-world all-facts people)))

;; ── the seed: a decision the solve starts from ───────────────────────────
;; The solve decides each whole act by search, and a search that starts from
;; a standing decision starts from a plan that already holds (engine
;; solve-discrete #:seed: the seed's exact cost is the first incumbent, and
;; the tree looks for better). The seed here is the week packed first want
;; first: each want in the order of its weight takes the hours it asks from
;; the holders of its skill while they have them. The engine prices the
;; seed on the program itself, so a seed the world refuses costs infinity
;; and the search stands alone.

;; the share of the hours a person states that the seed counts on: an act
;; placed by the plan stands strictly inside every budget it draws
(define %seed-share 0.995)

(define (holders people skill areas)
  "The ids of the PEOPLE who hold SKILL."
  (filter-map (lambda (p) (and (member skill (person-skills p areas)) (person-ref p 'id #f)))
              people))

(define* (pack-week w all-facts people #:key (meeting? #t))
  "The week packed first want first, greediest want of a shape first
   within it: ((process . n) …), N the whole units of PROCESS the holders
   of its skill could afford this week out of everything asking for it —
   0 for a process with no ready want, however many its own wants (heaviest
   first) could actually be drawn hours for otherwise. Every distinct
   process among the week's wants gets an entry, seed-decision's fixings
   must cover every one the build declares whole."
  (let* ((wants (week-wants w all-facts #:meeting? meeting?))
         (areas (issue-areas (open-facts all-facts)))
         (left  (map (lambda (p) (cons (person-ref p 'id #f)
                                       (* %seed-share (exact->inexact (person-ref p 'hours 0)))))
                     people))
         (holds? (lambda (id skill) (member id (holders people skill areas))))
         (counts (make-hash-table)))
    (for-each (lambda (wt) (hash-set! counts (want-ref wt 'process) (hash-ref counts (want-ref wt 'process) 0)))
              wants)
    (define (draw left skill hours)
      ;; LEFT after HOURS of SKILL are drawn from its holders, fullest first; #f when they lack them
      (let loop ((left left) (need hours))
        (if (<= need 1e-9)
            left
            (let ((from (fold (lambda (e best)
                                (if (and (holds? (car e) skill) (> (cdr e) 1e-9)
                                         (or (not best) (> (cdr e) (cdr best))))
                                    e best))
                              #f left)))
              (and from
                   (let ((take (min need (cdr from))))
                     (loop (map (lambda (e) (if (eq? e from) (cons (car e) (- (cdr e) take)) e)) left)
                           (- need take))))))))
    (let loop ((wants wants) (left left))
      (if (null? wants)
          (hash-map->list cons counts)
          (let* ((pid   (want-ref (car wants) 'process))
                 (after (fold (lambda (sh l) (and l (draw l (car sh) (cdr sh))))
                              left (want-ref (car wants) 'work))))
            (when after (hash-set! counts pid (1+ (hash-ref counts pid 0))))
            (loop (cdr wants) (or after left)))))))

(define* (seed-decision w all-facts people #:key (meeting? #t))
  "pack-week as the `decided` state the solve takes (engine decided-state):
   every whole-count process of the week fixed at the count it packed."
  `((config . all)
    (cuts)
    (fixed . ,(map (lambda (pc) (cons (string-append "p|" (car pc) "|" %dev-place "@0") (exact->inexact (cdr pc))))
                   (pack-week w all-facts people #:meeting? meeting?)))))

(define* (plan-dev-week scope all-facts people
                        #:key (span (dev-week-span)) (meeting? #t) (node-budget #f) (decided #t))
  "The week's plan over SCOPE, a scope-root holding the development world
   (seed-dev-scope!). Call within SCOPE's vat. Returns plan-scope->alist's
   result. DECIDED, when not #f, seeds the search from pack-week's packing
   (#t, the default) or a decided state the caller already has."
  (let* ((w      (dev-world all-facts people))
         (wants  (week-wants w all-facts #:meeting? meeting?)))
    (apply plan-scope->alist scope
           #:demand (dev-demand w all-facts #:meeting? meeting?)
           #:desire-weights (dev-weights w all-facts #:meeting? meeting?)
           #:period-spans (list span)
           #:agent-hours (dev-hours-of people)
           ;; the week runs the recipes its wants are made by; the scope's
           ;; store also holds the kinds, the issues that wait and the ones
           ;; that ended, which are knowledge and history
           #:admit? (let ((wanted (map (lambda (want) (want-ref want 'recipe)) wants)))
                      (lambda (r) (and (member (recipe-id r) wanted) #t)))
           #:whole (delete-duplicates (map (lambda (want) (want-ref want 'process)) wants))
           ;; the scope is one of work: its people eat and rest in their communes
           #:reproduce? #f #:insure? #f
           (append (if node-budget (list #:node-budget node-budget) '())
                   (cond ((eq? decided #t) (list #:decided (seed-decision w all-facts people #:meeting? meeting?)))
                         (decided (list #:decided decided))
                         (else '()))))))

;; ── reading the plan ─────────────────────────────────────────────────────

(define (row-ref row key) (assq-ref row key))

(define (made result spec)
  "Units of SPEC the plan produces, read off the material commitments."
  (fold (lambda (m acc)
          (if (and (memq (row-action m) creating-actions)
                   (equal? spec (row-spec m)))
              (+ acc (or (row-quantity m) 0.0))
              acc))
        0.0 (or (assq-ref result 'material) '())))

(define (shares result pid hours)
  "Who carries process PID, as ((agent . hours) …) largest first: each
   provider's part of the work the plan places on PID, scaled to the HOURS
   the act takes (the total the plan spent on PID, when several same-shape
   issues share it — see shares-per-unit)."
  (let* ((rows  (filter (lambda (w) (equal? pid (row-input-of w)))
                        (or (assq-ref result 'work) '())))
         (by    (fold (lambda (w acc)
                        (let ((who (row-provider w)) (h (or (row-effort w) 0.0)))
                          (alist-cons who (+ h (or (assoc-ref acc who) 0.0)) (alist-delete who acc))))
                      '() rows))
         (total (fold (lambda (p a) (+ a (cdr p))) 0.0 by)))
    (sort (filter (lambda (p) (> (cdr p) (* 0.01 hours)))
                  (map (lambda (p) (cons (car p)
                                         (if (> total 0.0) (* hours (/ (cdr p) total)) 0.0)))
                       by))
          (lambda (a b) (> (cdr a) (cdr b))))))

(define (shares-per-unit result pid n hours)
  "Who carries ONE of N whole units of shared process PID, each HOURS: the
   plan's own pooled shares of PID's full N*HOURS, divided evenly per unit
   — the fairest reading the solve's result supports once a process serves
   more than one issue, since it cannot say which specific hour went to
   which specific issue, only how each provider split the shape's total."
  (map (lambda (p) (cons (car p) (/ (cdr p) n))) (shares result pid (* n hours))))

(define (read-dev-plan result all-facts people)
  "The plan issue by issue. One row per open issue, first want first:
     ((oid …) (title …) (prio …) (kind …) (skill …) (hours …)
      (state . planned | waits | unheld | unplanned)
      (shares . ((agent . hours) …)) (lead . agent | #f) (waits-on . (need …)))
   planned: the plan makes the deliverable this week, SHARES carry it and
   LEAD carries most. waits: a need stands unsolved. unheld: nobody of the
   scope holds the skill. unplanned: the week's hours went to other wants.

   A shape's recipe is shared by every issue asking it, so the solve states
   only HOW MANY units of a shape it made, never which — the same way a
   farm's plan states how many units of a crop it made. Which specific
   issues those units cover is decided here, deterministically: a shape's
   own ready issues, heaviest want first (week-wants' own order), the first
   N of them (N the shape's made count, rounded) are planned."
  (let* ((open  (open-facts all-facts))
         (areas (issue-areas open))
         (shape (lambda (f) (kind-spec* (issue-kind f) (issue-hours f))))
         (ready (stable-sort (ready-facts all-facts)
                             (lambda (a b) (< (fact-ref a 'prio) (fact-ref b 'prio)))))
         (shapes (delete-duplicates (map shape ready)))
         (done-oids
          (append-map
           (lambda (spec)
             (let* ((members (filter (lambda (f) (equal? (shape f) spec)) ready))
                    (n       (inexact->exact (min (length members) (round (made result spec))))))
               (map (lambda (f) (fact-ref f 'oid)) (list-head members n))))
           shapes)))
    (stable-sort
     (map (lambda (f)
            (let* ((oid    (fact-ref f 'oid))
                   (kind   (issue-kind f))
                   (hours  (issue-hours f))
                   (spec   (shape f))
                   (pid    (kind-process* kind hours))
                   (skill  (issue-skill f))
                   (waits  (needs-open f all-facts))
                   (done?  (and (member oid done-oids) #t))
                   (n      (max 1 (inexact->exact (round (made result spec)))))
                   (who    (if done? (shares-per-unit result pid n hours) '())))
              `((oid . ,oid) (title . ,(fact-ref f 'title)) (prio . ,(fact-ref f 'prio))
                (kind . ,kind) (area . ,(fact-ref f 'area))
                (skill . ,skill) (hours . ,hours)
                (estimated? . ,(and (fact-ref f 'est) #t))
                (state . ,(cond (done? 'planned)
                                ((pair? waits) 'waits)
                                ((null? (holders people skill areas)) 'unheld)
                                (else 'unplanned)))
                (shares . ,who)
                (lead . ,(and (pair? who) (caar who)))
                (waits-on . ,waits))))
          open)
     (lambda (a b) (< (row-ref a 'prio) (row-ref b 'prio))))))

(define (rows-led-by agent rows)
  "The planned rows AGENT leads (the largest of the row's shares is
   theirs), first want first: whole-issue work fit to hand ONE party, such
   as a dispatched coding session."
  (filter (lambda (r) (and (eq? 'planned (row-ref r 'state))
                           (equal? agent (row-ref r 'lead))))
          rows))

(define (rows-for agent rows)
  "The planned rows AGENT carries ANY share of, first want first: everything
   they are committed to this week, whether or not they are the row's
   largest share — a fuller answer than rows-led-by for \"what is AGENT
   doing\", the one a person reading their own week wants."
  (filter (lambda (r) (and (eq? 'planned (row-ref r 'state))
                           (assoc agent (row-ref r 'shares))))
          rows))

(define (dev-plan-totals result rows people)
  "What the week holds:
     ((meeting . #t|#f)
      (people . ((id stated planned) …))
      (asked . hours every open issue asks) (planned . hours the plan places)
      (by-state . ((state . count) …)))"
  (let ((planned-by (lambda (id)
                      (fold (lambda (r acc)
                              (+ acc (or (assoc-ref (row-ref r 'shares) id) 0.0)))
                            0.0 rows))))
    `((meeting . ,(>= (made result %meeting-spec) 0.5))
      (people . ,(map (lambda (p)
                        (let ((id (person-ref p 'id #f)))
                          (list id (exact->inexact (person-ref p 'hours 0)) (planned-by id))))
                      people))
      (asked . ,(fold (lambda (r a) (+ a (row-ref r 'hours))) 0.0 rows))
      (planned . ,(fold (lambda (r a) (if (eq? 'planned (row-ref r 'state))
                                          (+ a (row-ref r 'hours)) a))
                        0.0 rows))
      (by-state . ,(map (lambda (s) (cons s (count (lambda (r) (eq? s (row-ref r 'state))) rows)))
                        '(planned waits unheld unplanned))))))
