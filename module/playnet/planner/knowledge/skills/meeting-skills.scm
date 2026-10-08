;;; skills/meeting-skills.scm — the catalogue's entries for a meeting's roles.
;;;
;;; Migrated out of `knowledge/recipes/meeting.scm`, ids unchanged
;;; (`spec:facilitation`/`spec:note-taking`/`spec:participation`). The
;;; identity law, stated explicitly rather than left implicit: a meeting
;;; role is not a scarce, trained stock the way "keri competence" is —
;;; anyone in the scope can step into it — so no decay applies, and the
;;; unit stays "hours" throughout rather than the catalogue's usual
;;; person/hours split.

(define-module (playnet planner knowledge skills meeting-skills)
  #:use-module ((playnet planner knowledge skills skill-shorthand) #:select (skill*))
  #:export (%meeting-skills))

(define %meeting-skills
  (list
   (skill* "spec:facilitation" "Facilitation" "chairing a meeting's agenda"
           #:decay 0.0 #:regen 1.0 #:resource-unit "hours")
   (skill* "spec:note-taking" "Note Taking" "recording a meeting's minutes"
           #:decay 0.0 #:regen 1.0 #:resource-unit "hours")
   (skill* "spec:participation" "Participation" "attending and contributing to a meeting"
           #:decay 0.0 #:regen 1.0 #:resource-unit "hours")))
