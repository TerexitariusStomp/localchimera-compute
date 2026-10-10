;;; dev.scm — playnet's own development, as a <world>.
;;;
;;; The work of developing this codebase is ValueFlows economic activity the
;;; planner schedules beside any other: an open Radicle issue is a WANT for
;;; one unit of its deliverable, its `kind:` label names the RECIPE the work
;;; follows, and its `est:` label states the hours. Development labour is
;;; ONE skill — the recipe abstracts over which area an issue happens to
;;; touch, the same way a person's stated hours are one weekly budget, not
;;; one per area. `area:` still names the area on every row this plans, and
;;; still feeds the (informational, world-independent) "does anyone here
;;; work in this area" read — bridge/dev-plan's holders/'unheld — it just no
;;; longer picks which recipe a want runs against or which skill it draws.
;;; The people of the scope state the hours they give in a week; the week's
;;; meeting is a want in the same scope, drawing on the same hours.
;;;
;;; The recipe/process/spec catalog stays as small as the week's own real
;;; diversity of work — one per (kind, hours) SHAPE actually open this week,
;;; the way any other scope's catalog is one per crop or one per chore: an
;;; issue is a DEMAND INSTANCE against its shape's recipe, never a recipe of
;;; its own, so two issues of the same kind sharing an hours figure (the
;;; common case) share the one recipe that shape names — the solve then
;;; decides how many whole UNITS of that shape the week affords, the same
;;; way a farm's plan decides how many units of one crop it affords rather
;;; than minting one recipe per harvest. bridge/dev-plan's read-dev-plan
;;; recovers which SPECIFIC issues of a shape that count covers — priority
;;; order among a shape's own ready issues, deterministic once the solve
;;; states how many units it made.
;;;
;;;   dev-knowledge-world   the standing knowledge: one recipe per kind of
;;;                         work (a fix, a feature, a study, …) at its own
;;;                         standing-hours shape, each an act of development
;;;                         labour making one deliverable — plus one extra
;;;                         recipe per (kind, hours) shape an open issue's
;;;                         own `est:` asks for beyond that
;;;                         (issue-variant-worlds)
;;;   issues->world         every open issue of a list of facts: any
;;;                         (kind, hours) variant they ask beyond their
;;;                         kind's own
;;;   dev-people->world     the scope's people: each an agent at the scope's
;;;                         place, holding development labour and a role per
;;;                         meeting role
;;;   dev-world             issues, people and the meeting: the scope's week
;;;   dev-whole-acts        the acts of a dev world that happen whole: every
;;;                         kind (and variant), and the meeting
;;;   dev-hours-of          people → (agent period → hours), the hours each
;;;                         states for the period
;;;   seed-dev-knowledge!   dev-knowledge-world into a recipe-store
;;;
;;; The facts are (playnet planner dev priorities) issue-facts: the
;;; one reader of Radicle's shape. An issue is COUNTABLE the way a meeting
;;; is: half a fix is no fix, so each issue's act is a whole-count process.
;;;
;;; A need (`needs:<issue>`) gates an issue's own readiness — dev-priorities'
;;; ready-facts/needs-open reads this straight off Radicle issue STATE
;;; ('solved vs 'open), before a want is ever built, so nothing here needs to
;;; re-state it: the week's wants are already only the issues whose needs
;;; are solved.

(define-module (playnet planner dev recipes)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner knowledge dsl shorthand)
  #:use-module (playnet planner knowledge dsl world)
  #:use-module (playnet planner knowledge recipes meeting)
  #:use-module ((playnet planner knowledge skills skill-catalogue)
                #:select (catalogue-skill))
  #:use-module ((playnet planner dev priorities)
                #:select (fact-ref open-facts))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (%dev-place %dev-kinds %dev-default-kind
            dev-kind-hours dev-skill dev-skill-spec dev-process-id
            kind-spec kind-process kind-recipe
            kind-spec* kind-process* kind-recipe*
            issue-kind issue-hours issue-skill
            dev-knowledge-world issues->world issue-areas
            dev-people->world dev-world dev-whole-acts dev-hours-of
            person-ref person-lookup person-skills
            seed-dev-knowledge!))

;; where the work happens: one place, the repository
(define %dev-place "playnet-dev")

;; the kinds of work, each with the deliverable one run makes and the hours
;; a run takes where the issue states none — the scope's standing estimate,
;; which an `est:` label on the issue replaces
(define %dev-kinds
  '(("bug"       "A fix"              3.0)
    ("chore"     "A chore done"       2.0)
    ("hardening" "A hardening"        4.0)
    ("feature"   "A feature"          8.0)
    ("research"  "A study"            6.0)))
(define %dev-default-kind "chore")

(define (dev-kind-hours kind)
  (caddr (or (assoc kind %dev-kinds) (assoc %dev-default-kind %dev-kinds))))

(define (dev-skill area)
  "The skill an AREA's work asks for; work naming no area asks for
   development labour in general."
  (if area (string-append "skill:dev:" area) "skill:dev"))

(define (dev-skill-spec id fallback-name)
  "The catalogue's own resource-specification for skill ID
   (knowledge/skills/dev-skills.scm), carrying the real skill-law the
   catalogue states — or, for an area the catalogue has not yet caught up
   with, a bare identity-law spec built the old way, so an unanticipated
   area still plans rather than silently losing its skill."
  (or (catalogue-skill id) (spec* id fallback-name %effort-unit)))

;; dev-process-id once named the world's own per-issue process; the world no
;; longer mints one (issues->world, below). It survives as dev-ledger.scm's
;; own private bookkeeping id — a commitment/event's input-of/output-of,
;; indexed there, never registered in or validated against a recipe store —
;; so an issue keeps one stable ledger identity independent of which (kind,
;; hours) recipe its want actually runs against.
(define (dev-process-id oid) (string-append "rp-dev-issue-" oid))

(define (kind-spec kind) (string-append "spec-dev-" kind))
(define (kind-process kind) (string-append "rp-dev-" kind))
(define (kind-recipe kind) (string-append "recipe-dev-" kind))

;; a recipe's real shape is (kind, hours), not kind alone: the common case —
;; no est: override — collapses to the kind's own standing id; an issue
;; asking its own hours shares a recipe with every OTHER issue of the same
;; kind asking the same hours, rather than minting one of its own. AREA
;; plays no part here — development labour is one skill, so a browser bug
;; and a keri bug run the same recipe (see the module header).
(define (variant-suffix hours default-hours)
  (if (= hours default-hours) "" (string-append "-" (number->string hours) "h")))
(define (kind-spec* kind hours) (string-append (kind-spec kind) (variant-suffix hours (dev-kind-hours kind))))
(define (kind-process* kind hours) (string-append (kind-process kind) (variant-suffix hours (dev-kind-hours kind))))
(define (kind-recipe* kind hours) (string-append (kind-recipe kind) (variant-suffix hours (dev-kind-hours kind))))

;; ── the standing knowledge: a recipe per (kind, hours) shape ─────────────

(define (kind-world hours pid rid spec label)
  "One (kind, hours) shape's recipe: the spec of its deliverable, the
   whole-count process that makes it, the work it asks of development
   labour in general at HOURS, and the recipe binding them — reused both
   for a kind's own standing entry (dev-knowledge-world) and for any
   est:-driven variant (issue-variant-worlds)."
  (world
   #:specs (list (spec* spec label %count-unit))
   #:procs (list (rp* pid label #:tags '("tag:dev" "whole-count") #:conforms-to "pspec-code-improvement"))
   #:flows (list (wk* (string-append pid "~work") (dev-skill #f) hours pid)
                 (out* (string-append pid "~out") spec 1 pid %count-unit))
   #:recipes (list (make-recipe #:id rid #:name label #:primary-output spec
                                #:recipe-processes (list pid)))))

(define dev-knowledge-world
  (apply world-append
         (world #:specs (list (dev-skill-spec (dev-skill #f) "Development labour")))
         (map (lambda (k)
                (kind-world (caddr k) (kind-process (car k)) (kind-recipe (car k)) (kind-spec (car k)) (cadr k)))
              %dev-kinds)))

(define (seed-dev-knowledge! rs)
  "Seed the development knowledge into RS: the process specification and a
   recipe per kind of work. RS is a ^recipe-store; call within a vat."
  ($ rs 'add-process-spec
     (make-process-specification
      #:id "pspec-code-improvement" #:name "Code improvement"
      #:note "Implement, test, and merge a development task"))
  (seed-world-recipes! rs dev-knowledge-world)
  'dev-knowledge-seeded)

;; ── the open issues → their world ────────────────────────────────────────

(define (issue-kind facts)
  (let ((k (fact-ref facts 'kind)))
    (if (and k (assoc k %dev-kinds)) k %dev-default-kind)))

(define (issue-hours facts)
  "The hours the issue's act takes: its own estimate, else its kind's."
  (or (fact-ref facts 'est) (dev-kind-hours (issue-kind facts))))

(define (issue-skill facts) (dev-skill (fact-ref facts 'area)))

(define (issue-variant-worlds open)
  "One extra (kind, hours) recipe per distinct hours override among OPEN
   issues beyond its kind's own standing hours — reused by every issue of
   that kind asking that many hours, the same construction
   dev-knowledge-world already uses for each kind's own standing entry."
  (let ((variants (delete-duplicates
                    (filter-map (lambda (f)
                                  (let ((k (issue-kind f)) (h (issue-hours f)))
                                    (and (not (= h (dev-kind-hours k))) (cons k h))))
                                open))))
    (apply world-append
           (map (lambda (kh)
                  (let* ((k (car kh)) (h (cdr kh)) (label (cadr (assoc k %dev-kinds))))
                    (kind-world h (kind-process* k h) (kind-recipe* k h) (kind-spec* k h)
                                (string-append label " (" (number->string h) "h)"))))
                variants))))

(define (issue-areas all-facts)
  "The areas the issues name, each once."
  (delete-duplicates (filter-map (lambda (f) (fact-ref f 'area)) all-facts)))

(define (issues->world all-facts)
  "The open issues of ALL-FACTS as one world: any (kind, hours) variant
   recipe they need beyond their kind's standing one, and the (informational
   — no recipe asks for one) skill of every area they name, so
   dev-people->world's own per-area skill resources still back a registered
   spec."
  (let* ((open (open-facts all-facts))
         (w    (issue-variant-worlds open)))
    (world-with w
      #:specs (append
               (list (dev-skill-spec (dev-skill #f) "Development labour"))
               (map (lambda (a) (dev-skill-spec (dev-skill a) (string-append "Development labour: " a)))
                    (issue-areas open))
               (world-specs w)))))

;; ── the people ───────────────────────────────────────────────────────────
;; A person of the scope is an alist:
;;   ((id . "ops") (hours . 20) (areas . all | ("planner" "infra" …))
;;    (roles . all | ("spec:facilitation" …)) (kind . person | agent))
;; HOURS are the hours they give in a period; AREAS the areas whose work
;; they take (all = every area the period's issues name); ROLES the meeting
;; roles they take. KIND agent is a machine that works (the box's coding
;; agent): it holds area skills and states hours, and it has no body to
;; feed and no seat at the meeting unless it states a role.

(define (person-ref p key default)
  (let ((v (assq key p))) (if v (cdr v) default)))

(define (person-lookup people key val ref)
  "The REF field of the person of PEOPLE whose KEY field is VAL, or #f —
   the one lookup every id<->aid<->did resolution over the scope's people
   reduces to (e.g. (person-lookup people 'did did 'id), (person-lookup
   people 'id id 'aid))."
  (any (lambda (p) (and (equal? val (person-ref p key #f)) (person-ref p ref #f)))
       people))

(define (person-areas p areas)
  (let ((a (person-ref p 'areas 'all)))
    (if (eq? a 'all) areas (filter (lambda (x) (member x areas)) a))))

(define (person-roles p)
  (let ((r (person-ref p 'roles (if (eq? 'agent (person-ref p 'kind 'person)) '() 'all))))
    (if (eq? r 'all) meeting-roles r)))

(define (person-skills p areas)
  "Every skill person P holds, AREAS being the areas the period's issues
   name: development labour in general, the skill of each area they take,
   and their meeting roles. No recipe asks for an area skill (development
   labour is one skill) — this still backs holders/'unheld' in
   bridge/dev-plan.scm, which reads it straight off PEOPLE, world-independent."
  (append (list (dev-skill #f))
          (map dev-skill (person-areas p areas))
          (person-roles p)))

(define (dev-people->world people areas)
  "PEOPLE as agents at the scope's place, each holding the skill of every
   area of AREAS they take, development labour in general, and their
   meeting roles."
  (world
   #:spatials (list (place* %dev-place #:name "coding"))
   #:agents (map (lambda (p)
                   (let ((id (person-ref p 'id #f)))
                     (if (eq? 'agent (person-ref p 'kind 'person))
                         (org* id #:place %dev-place #:tags '("tag:dev" "agent:machine")
                               #:name (person-ref p 'name id))
                         (person* id #:place %dev-place #:tags '("tag:dev")
                                  #:name (person-ref p 'name id)))))
                 people)
   #:resources (append-map
                (lambda (p)
                  (let ((id (person-ref p 'id #f)))
                    (map (lambda (skill)
                           (er (string-append "skill:" id ":" skill) skill id
                               #:place %dev-place #:name (string-append id " " skill)))
                         (person-skills p areas))))
                people)))

(define (dev-hours-of people)
  "(agent period → hours): the hours each of PEOPLE states for a period.
   An agent the scope does not name gives none."
  (lambda (a t)
    (let ((p (find (lambda (p) (equal? (person-ref p 'id #f) (agent-id a))) people)))
      (exact->inexact (if p (person-ref p 'hours 0) 0)))))

;; ── the scope's week ─────────────────────────────────────────────────────

(define (dev-world all-facts people)
  "The development scope's world: the kinds of work, the open issues, the
   people, and the weekly meeting. Each spec stands once."
  (let ((w (world-append dev-knowledge-world
                         (issues->world all-facts)
                         meeting-world
                         (dev-people->world people (issue-areas (open-facts all-facts))))))
    (world-with w
      #:specs (delete-duplicates (world-specs w)
                                 (lambda (a b) (equal? (resource-specification-id a)
                                                       (resource-specification-id b)))))))

(define (dev-whole-acts w)
  "The acts of dev world W that happen a whole number of times."
  (append meeting-whole-acts
          (filter-map (lambda (p)
                        (and (member "whole-count" (or (recipe-process-process-classified-as p) '()))
                             (recipe-process-id p)))
                      (world-procs w))))
