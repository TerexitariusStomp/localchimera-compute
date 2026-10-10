;;; skills/dev-skills.scm — the catalogue's own entries for playnet's own development.
;;;
;;; One skill per `area:` docs/radicle-issues.md's taxonomy names, plus the
;;; bare `skill:dev` (development labour in general, the skill a work flow
;;; naming no area asks for). Ids match `module/playnet/knowledge/
;;; recipes/dev.scm`'s `dev-skill` exactly, so nothing that already reads a
;;; `skill:dev:<area>` id needs to change.
;;;
;;; The law is a FIRST CUT, uniform across every area — skill:decay:0.02,
;;; skill:regen:1.0, per playnet.typ: "a surgeon who does not operate
;;; degrades... exercising a skill in production keeps it sharp" — every
;;; value stated explicitly, none of it tuned per area; a stewardship scope
;;; revisits these the same way catalogues/skill-interaction.scm's own cross-training
;;; coefficients are marked DRAFT until one ratifies its own.

(define-module (playnet knowledge skills dev-skills)
  #:use-module ((playnet knowledge skills skill-shorthand) #:select (skill*))
  #:export (%dev-skills))

(define %dev-skills
  (list
   (skill* "skill:dev" "Development labour"
           "work a recipe names no area for")

   (skill* "skill:dev:planner" "Planner competence"
           "the VF economic planning engine: recipes, the solve, live plan-scope")
   (skill* "skill:dev:governance" "Governance competence"
           "scope hierarchy, credentials, personhood, legal-gate, liquid-democracy")
   (skill* "skill:dev:keri" "KERI competence"
           "Signify, ACDC credentials, witness enrollment, device keys, RFC 9421")
   (skill* "skill:dev:federation" "Federation competence"
           "cross-vat signed price solves, async-peer ADMM, the federation's DESK")
   (skill* "skill:dev:fleet" "Fleet competence"
           "host provisioning, the reconciler, bootstrap automation")
   (skill* "skill:dev:reticulum" "Reticulum competence"
           "mesh networking, the OCapN netlayer, the Rust bridge")
   (skill* "skill:dev:browser" "Browser competence"
           "the browser-resident face: Hoot/WASM, the seam, the app's faces")
   (skill* "skill:dev:gateway" "Gateway competence"
           "OCapN capability routing, the lobby, signup and session doors")
   (skill* "skill:dev:nlp" "NLP competence"
           "underspecified demand, surface text to a holey logical form")
   (skill* "skill:dev:infra" "Infra competence"
           "Guix deployment, the box, Shepherd services")
   (skill* "skill:dev:calendar" "Calendar competence"
           "VF process context on the calendar face, availability windows")
   (skill* "skill:dev:docs" "Docs competence"
           "the corpus pipeline, provenance tags, the spec itself")
   (skill* "skill:dev:upstream" "Upstream competence"
           "filing and tracking bugs in Guix, Hoot, Goblins")
   (skill* "skill:dev:eco-barrier" "Eco-barrier competence"
           "ecological tensions, the observation and QGIS pipeline")
   (skill* "skill:dev:legal" "Legal competence"
           "the legal-gate, compliance lifecycle, law and chemistry")
   (skill* "skill:dev:money" "Money competence"
           "consume-grant credit, claims, the wallet and payout pipeline")
   (skill* "skill:dev:outbox" "Outbox competence"
           "the offline outbox, dedupe, recovery-friends")
   (skill* "skill:dev:voice" "Voice competence"
           "the voice field, demand-weighting, consumer voice")
   (skill* "skill:dev:audit" "Audit competence"
           "triage and re-attribution of swept findings to their real area")))
