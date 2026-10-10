;;; test-skill-catalogue.scm — the catalogue $\mathcal{K}$: every area, a real law.
;;;
;;; docs/playnet.typ names the catalogue as theory; knowledge/skills/ is its
;;; code. This suite pins two properties the migration
;;; (knowledge/recipes/dev.scm, recipes/meeting.scm) depends on: every
;;; `area:` docs/radicle-issues.md's taxonomy states has a matching entry —
;;; a property check, not a fixed count, so the catalogue is caught the
;;; moment it drifts from the taxonomy rather than only when a live issue
;;; hits the gap — and every entry's tags actually parse as skill-law.scm
;;; expects, not merely look like they would.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/dev/test-skill-catalogue.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             ((playnet vf schemas)
              #:select (resource-specification-id resource-specification-resource-classified-as
                        resource-specification-default-unit-of-resource
                        resource-specification-default-unit-of-effort))
             ((playnet vf formulas skill-law) #:select (skill-law-of))
             ((playnet knowledge skills skill-catalogue)
              #:select (%skill-catalogue catalogue-skill))
             ((playnet dev recipes) #:select (dev-skill))
             (srfi srfi-1))

;; the taxonomy docs/radicle-issues.md states under `### area:` — read as a
;; fixture here rather than parsed from the doc, so a suite failure always
;; means "these two disagree," never "the doc's own prose shape changed"
(define %areas
  '("planner" "governance" "keri" "federation" "fleet" "reticulum" "browser"
    "gateway" "nlp" "infra" "calendar" "docs" "upstream" "eco-barrier"
    "legal" "money" "outbox" "voice" "audit"))

(display "\n── every area has a catalogue entry ──\n")

(check "the taxonomy's own count" (length %areas) 19)
(check-pred "every area's skill:dev:<area> is in the catalogue"
            (every (lambda (a) (catalogue-skill (dev-skill a))) %areas))
(check-pred "…and the bare skill:dev (no area) too" (catalogue-skill (dev-skill #f)))
(check "a made-up area is a real absence, not a false positive"
       (catalogue-skill "skill:dev:not-a-real-area") #f)

(display "\n── each entry's law parses as skill-law.scm expects ──\n")

(check-pred "every catalogue entry states a law skill-law-of can read"
            (every (lambda (s) (skill-law-of (resource-specification-resource-classified-as s)))
                   %skill-catalogue))
(let* ((s   (catalogue-skill (dev-skill "planner")))
       (law (skill-law-of (resource-specification-resource-classified-as s))))
  (check "the planner skill's decay reads back exactly as declared" (assq-ref law 'decay) 0.02)
  (check "…and its regen" (assq-ref law 'regen) 1.0)
  (check "…the stock counted in people" (resource-specification-default-unit-of-resource s) "person")
  (check "…the effort a work flow draws counted in hours"
         (resource-specification-default-unit-of-effort s) %effort-unit))
(let* ((s   (catalogue-skill "spec:facilitation"))
       (law (skill-law-of (resource-specification-resource-classified-as s))))
  (check "a meeting role states the identity law explicitly" (assq-ref law 'decay) 0.0)
  (check "…every practiced hour kept" (assq-ref law 'regen) 1.0))

(display "\n── ids stand alone, no duplicates ──\n")

(check "every id in the catalogue is unique"
       (length (delete-duplicates (map resource-specification-id %skill-catalogue)))
       (length %skill-catalogue))

(test-summary!)
