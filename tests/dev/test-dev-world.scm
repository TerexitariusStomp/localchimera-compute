;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-dev-world.scm — playnet's own development, planned by the planner.
;;;
;;; An open Radicle issue is a want, its area label a skill, its kind label a
;;; recipe, its estimate the hours (recipes/dev.scm); the week's plan is the
;;; ordinary solve over the scope's stores (bridge/dev-plan.scm). This suite
;;; walks the whole road on a small scope: `rad cob show` JSON → facts →
;;; world → a real scope-root → the plan → the rows a person reads.
;;;
;;; The scope: ann gives twenty-two hours, the box's agent thirty — a shared
;;; pool of development labour (one skill; `area:` is a label now, not a
;;; gate — see recipes/dev.scm's header), except the week's meeting, which
;;; only ann can hold (the box's agent states no meeting role). Four hours
;;; of ann's own go to the meeting; the rest of both budgets pool for the
;;; week's issues, enough for three of the four ready ones and not the
;;; fourth, so the heavier-weighted three plan and the lightest-weighted
;;; one does not.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/dev/test-dev-world.scm

(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet vf schemas)
             (playnet knowledge dsl world)
             (playnet dev recipes)
             ((playnet knowledge recipes meeting) #:select (meeting-world))
             (playnet dev priorities)
             (playnet dev plan)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define* (fake-issue oid title labels #:optional (status "open") (reason #f))
  (cons oid
        `(("title" . ,title)
          ("state" . (("status" . ,status) ,@(if reason `(("reason" . ,reason)) '())))
          ("labels" . ,(list->vector labels))
          ("assignees" . #())
          ("thread" . (("comments" . ((,oid . (("body" . "the body"))))))))))

(define issues
  (list (fake-issue "aaa111" "The heavy planner want" '("area:planner" "kind:feature" "prio:p0" "est:30h"))
        (fake-issue "bbb222" "The light planner want" '("area:planner,kind:bug,prio:p2,est:20h"))
        (fake-issue "ccc333" "An infra chore"         '("area:infra" "kind:chore" "prio:p1" "est:10h"))
        (fake-issue "ddd444" "Waits on the heavy one" '("area:infra" "kind:bug" "prio:p0" "needs:aaa"))
        (fake-issue "eee555" "Work nobody here holds" '("area:keri" "kind:research" "prio:p0"))
        (fake-issue "fff666" "Solved last week"       '("area:infra" "kind:bug") "closed" "solved")))

(define people
  '(((id . "ann") (hours . 22) (areas . ("planner" "infra")))
    ((id . "box") (hours . 30) (areas . ("infra")) (kind . agent))))

(define facts (issues->facts issues))
(define (fact oid) (find (lambda (f) (equal? oid (fact-ref f 'oid))) facts))

;;; ── the world ────────────────────────────────────────────────────────────────

(display "\n── an issue is a want, a label is a skill ──\n")

(define w (dev-world facts people))
;; an issue's act runs the recipe of its own (kind, hours) shape — shared
;; with every other issue of the same shape, open or ended, since the
;; catalog stands on kinds, not on issues (issue-variant-worlds only adds
;; what an OPEN issue's own est: asks beyond its kind's default)
(define (issue-pid oid) (let ((f (fact oid))) (kind-process* (issue-kind f) (issue-hours f))))
(define (proc-of oid) (find (lambda (p) (equal? (issue-pid oid) (recipe-process-id p))) (world-procs w)))
(define (work-of oid)
  (find (lambda (f) (eq? 'work (recipe-flow-action f))) (world-flows-for w (issue-pid oid))))

(check-pred "every open issue's kind has an act in the world"
            (every (lambda (f) (and (proc-of (fact-ref f 'oid)) #t))
                   (filter (lambda (f) (eq? 'open (fact-ref f 'state))) facts)))
(check "the act asks development labour in general, not its area's own skill"
       (recipe-flow-resource-conforms-to (work-of "aaa111")) (dev-skill #f))
(check "…for the hours the issue states"
       (measure-has-numerical-value (recipe-flow-effort-quantity (work-of "aaa111"))) 30.0)
(check "an issue stating no hours takes its kind's"
       (measure-has-numerical-value (recipe-flow-effort-quantity (work-of "ddd444")))
       (dev-kind-hours "bug"))
(check-pred "every issue's act is whole"
            (every (lambda (f) (member (issue-pid (fact-ref f 'oid)) (dev-whole-acts w)))
                   (filter (lambda (f) (eq? 'open (fact-ref f 'state))) facts)))
(check-pred "the meeting is whole beside them" (member "rp-meeting" (dev-whole-acts w)))
(check "each spec stands once"
       (length (world-specs w))
       (length (delete-duplicates (map resource-specification-id (world-specs w)))))
(check-pred "every flow names a spec the world holds"
            (every (lambda (f) (member (recipe-flow-resource-conforms-to f)
                                       (map resource-specification-id (world-specs w))))
                   (world-flows w)))
(check "the box's agent is a machine: no meeting role unless it states one"
       (filter (lambda (r) (and (equal? "box" (economic-resource-primary-accountable r))
                                (member (economic-resource-conforms-to r)
                                        '("spec:facilitation" "spec:note-taking" "spec:participation"))))
               (world-resources w))
       '())

;;; ── the demand ───────────────────────────────────────────────────────────────

(display "\n── the week's wants ──\n")

(define demand (dev-demand w facts))
(define (issue-spec oid) (let ((f (fact oid))) (kind-spec* (issue-kind f) (issue-hours f))))
(define (wanted? oid) (and (assoc (string-append (issue-spec oid) "#" %dev-place "@0") demand) #t))

(check-pred "a ready issue is wanted" (wanted? "aaa111"))
(check "an issue whose need stands open waits outside the week" (wanted? "ddd444") #f)
(check "an ended issue is no want" (wanted? "fff666") #f)
(check-pred "the meeting is wanted"
            (assoc (string-append %meeting-spec "#" %dev-place "@0") demand))
(check-pred "a p0 want outweighs a p2 want"
            (> (prio->weight 0) (prio->weight 2)))
(check-pred "…and every rank weighs something"
            (every (lambda (r) (> (prio->weight r) 0)) '(0 1 2 3)))

(display "\n── week-wants: the one table every other reader maps over ──\n")

(define wants (week-wants w facts))
(define (want-of pid) (find (lambda (wt) (equal? pid (want-ref wt 'process))) wants))

(check "demand, weights and the recipes admitted all read the same wants"
       (list (length (dev-demand w facts)) (length (dev-weights w facts)) (length (week-recipes w facts)))
       (list (length wants) (length wants) (length wants)))
(check "the meeting's want reads its work off meeting-world's own flows, not a second copy"
       (sort (want-ref (want-of "rp-meeting") 'work) (lambda (a b) (string<? (car a) (car b))))
       (sort (want-work meeting-world "rp-meeting") (lambda (a b) (string<? (car a) (car b)))))
(check "an issue's want carries its recipe and spec"
       (list (want-ref (want-of (issue-pid "aaa111")) 'recipe)
             (want-ref (want-of (issue-pid "aaa111")) 'spec))
       (list (kind-recipe* "feature" 30.0) (issue-spec "aaa111")))

;;; ── the plan ─────────────────────────────────────────────────────────────────

(display "\n── the week, planned over a real scope-root ──\n")

(define vat (spawn-vat #:name "dev-world"))
(define (flow-count scope)
  ;; the flows the store answers for the heavy issue's act, both sides
  (let ((io ($ ($ scope 'recipe-store) 'flows-for-process (issue-pid "aaa111"))))
    (+ (length (car io)) (length (cdr io)))))
(define-values (result recipes-once recipes-twice flows-once flows-twice)
  (with-vat vat
    (let ((scope (spawn-scope-root "playnet development")))
      (seed-dev-scope! scope facts people)
      (let ((once (length ($ ($ scope 'recipe-store) 'all-recipes)))
            (fl   (flow-count scope)))
        (seed-dev-scope! scope facts people)
        (values (plan-dev-week scope facts people)
                once
                (length ($ ($ scope 'recipe-store) 'all-recipes))
                fl
                (flow-count scope))))))

(check "seeding the scope again leaves its recipes as they stand" recipes-twice recipes-once)
(check "…and each act's flows: an issue seeded twice asks its hours once" flows-twice flows-once)
(check "the plan respects every limit it was given" (assq-ref result 'feasible) #t)

(define rows (read-dev-plan result facts people))
(define (row oid) (find (lambda (r) (equal? oid (row-ref r 'oid))) rows))
(define totals (dev-plan-totals result rows people))

(check "one row per open issue"
       (length rows) (count (lambda (f) (eq? 'open (fact-ref f 'state))) facts))
(check "the heavy want is planned" (row-ref (row "aaa111") 'state) 'planned)
(check "…and the light one, asking the same person's remaining hours, is not"
       (row-ref (row "bbb222") 'state) 'unplanned)
(check "the issue whose need stands open waits" (row-ref (row "ddd444") 'state) 'waits)
(check "…on the issue it names" (row-ref (row "ddd444") 'waits-on) '("aaa"))
(check "a cheap want of an area nobody declared still plans — development
        labour is one pool, area is a label" (row-ref (row "eee555") 'state) 'planned)
(check-pred "the meeting is held" (assq-ref totals 'meeting))

;; area no longer gates who carries a row — development labour is one
;; skill (recipes/dev.scm's header), so a row's carrier need not have named
;; its area at all; box (area:infra only) is free to lead planner/keri work
;; too. What the solve still owes: every planned issue's hours genuinely
;; add up, and nobody's credited past what they stated.
(check-pred "a planned issue's shares are its hours"
            (every (lambda (r)
                     (< (abs (- (row-ref r 'hours)
                                (fold (lambda (s a) (+ a (cdr s))) 0.0 (row-ref r 'shares))))
                        (* 0.02 (row-ref r 'hours))))
                   (filter (lambda (r) (eq? 'planned (row-ref r 'state))) rows)))
(check-pred "nobody is planned past the hours they state"
            (every (lambda (p) (<= (caddr p) (* 1.02 (cadr p))))
                   (assq-ref totals 'people)))
(check-pred "rows-for carries every row rows-led-by does, box holding a real share of each"
            (every (lambda (r) (and (member r (rows-for "box" rows))
                                    (assoc-ref (row-ref r 'shares) "box")))
                   (rows-led-by "box" rows)))
(check-pred "…and every row it names, box genuinely shares"
            (every (lambda (r) (assoc "box" (row-ref r 'shares))) (rows-for "box" rows)))
(check "rows stand first want first"
       (map (lambda (r) (row-ref r 'prio)) rows)
       (sort (map (lambda (r) (row-ref r 'prio)) rows) <))

;;; ── a snug week ──────────────────────────────────────────────────────────────

(display "\n── a want that fits the hours stated is planned ──\n")

;; one person, forty hours, one act of thirty-eight: the week holds it, and
;; one of forty-one it does not
(define (alone hours est)
  (let* ((fs (issues->facts
              (list (fake-issue "ace000" "One long act"
                                (list "area:planner" "prio:p0" (string-append "est:" est))))))
         (ps `(((id . "ann") (hours . ,hours) (areas . ("planner")))))
         (r  (with-vat (spawn-vat #:name "snug")
               (let ((scope (spawn-scope-root "snug")))
                 (seed-dev-scope! scope fs ps)
                 (plan-dev-week scope fs ps #:meeting? #f)))))
    (row-ref (car (read-dev-plan r fs ps)) 'state)))
(check "thirty-eight hours of forty are planned" (alone 40 "38h") 'planned)
(check "forty-one hours of forty are not" (alone 40 "41h") 'unplanned)

;; 'unheld is still a real state: not planned (here, for want of hours —
;; area never blocks assignment any more) AND nobody in the scope declared
;; its area — the second half worth stating on its own even though the
;; first already explains why it waited
(let* ((fs (issues->facts
            (list (fake-issue "unh001" "Nobody here works in this"
                              '("area:keri" "kind:research" "prio:p0" "est:20h")))))
       (ps `(((id . "ann") (hours . 5) (areas . ("planner")))))
       (r  (with-vat (spawn-vat #:name "unheld")
             (let ((scope (spawn-scope-root "unheld")))
               (seed-dev-scope! scope fs ps)
               (plan-dev-week scope fs ps #:meeting? #f)))))
  (check "an area nobody declared, and not enough hours regardless, is unheld"
         (row-ref (car (read-dev-plan r fs ps)) 'state) 'unheld))

(display "\n── the seed ──\n")
;; pack-week now counts whole units per shared PROCESS, not per want — 1 for
;; a process every one of its own ready issues could be afforded, 0 for one
;; none could
(check "the seed packs first want first: the heaviest three in, the lightest out"
       (map (lambda (oid) (assoc-ref (pack-week w facts people) (issue-pid oid)))
            '("aaa111" "ccc333" "eee555" "bbb222"))
       '(1 1 1 0))
(check-pred "the seed decides every act the week wants"
            (every (lambda (pid) (assoc (string-append "p|" pid "|" %dev-place "@0")
                                        (assq-ref (seed-decision w facts people) 'fixed)))
                   (delete-duplicates (map (lambda (wt) (want-ref wt 'process)) wants))))

;;; ── the need, solved ─────────────────────────────────────────────────────────

(display "\n── a need solved opens the want ──\n")

(define facts-after
  (issues->facts
   (map (lambda (p)
          (if (equal? "aaa111" (car p))
              (fake-issue "aaa111" "The heavy planner want"
                          '("area:planner" "kind:feature" "prio:p0" "est:30h") "closed" "solved")
              p))
        issues)))
(check-pred "once the heavy one is solved, what waited on it is wanted"
            (assoc (string-append (kind-spec* "bug" (dev-kind-hours "bug")) "#" %dev-place "@0")
                   (dev-demand (dev-world facts-after people) facts-after)))

;;; ── two issues, one recipe ───────────────────────────────────────────────────

(display "\n── two same-shape issues share one recipe, not two ──\n")

;; two default-hours chores, DIFFERENT areas: same kind, same hours, so
;; kind-process*/kind-spec* still resolve to the identical id for both —
;; development labour is one skill, area plays no part in which recipe a
;; want runs against — proving the fix (one small recipe catalog, many
;; issues sharing it regardless of area, read-dev-plan recovering which
;; specific one got done) rather than merely asserting it. ann's hours fit
;; exactly one chore, not both.
(define two-chores
  (issues->facts
   (list (fake-issue "chr001" "First chore" '("area:infra" "kind:chore" "prio:p0"))
         (fake-issue "chr002" "Second chore" '("area:browser" "kind:chore" "prio:p0")))))
(define two-people
  `(((id . "ann") (hours . ,(+ 1.0 (dev-kind-hours "chore"))) (areas . ("infra" "browser")))))
(define two-w (dev-world two-chores two-people))

(define (two-fact oid) (find (lambda (f) (equal? oid (fact-ref f 'oid))) two-chores))
(define (two-pid oid) (let ((f (two-fact oid))) (kind-process* (issue-kind f) (issue-hours f))))
(check "both issues' acts are the identical shared kind-process, despite different areas"
       (two-pid "chr001") (two-pid "chr002"))
(check "…and there is exactly one such process in the world, not two"
       (length (filter (lambda (p) (equal? (two-pid "chr001") (recipe-process-id p))) (world-procs two-w)))
       1)

(define two-result
  (with-vat (spawn-vat #:name "two-chores")
    (let ((scope (spawn-scope-root "two chores")))
      (seed-dev-scope! scope two-chores two-people)
      (plan-dev-week scope two-chores two-people #:meeting? #f))))
(define two-rows (read-dev-plan two-result two-chores two-people))

(check "only the hours-affordable one of two same-shape issues is planned"
       (sort (map (lambda (r) (symbol->string (row-ref r 'state))) two-rows) string<?)
       (sort (list "planned" "unplanned") string<?))

(test-summary!)
