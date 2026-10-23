;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; skills/skill-shorthand.scm — a skill's resource specification, spelled once.
;;;
;;; playnet.typ's own catalogue of skills, $\mathcal{K}$ (§Labour, skills,
;;; and free time): each skill $k$ carries a stock — the people trained in
;;; it — and a law of how that stock forms, decays and is kept warm by
;;; practice (skill-law.scm's `competence-fold`: decay, regen, yield, read
;;; off `skill:<key>:<number>` classification tags). `spec*`
;;; (../shorthand.scm) cannot state this: it takes one unit and no tags. A
;;; skill needs two units — the STOCK, counted in people, and the EFFORT a
;;; `work` flow draws from it, counted in hours (both fields already exist
;;; on `<resource-specification>`, unused until this catalogue) — and the
;;; law, stated explicitly so a reader never has to wonder whether the
;;; identity law (no decay, every hour kept) was intended or merely unstated.

(define-module (playnet knowledge skills skill-shorthand)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (playnet vf schemas)
  #:export (skill*))

(define* (skill* id name note #:key (decay 0.02) (regen 1.0)
                                    (resource-unit "person") (effort-unit %effort-unit))
  "A skill's resource specification: ID/NAME/NOTE, its stock in
   RESOURCE-UNIT, a work flow's draw in EFFORT-UNIT, and its law —
   DECAY/REGEN as skill-law.scm's own `skill:decay:N`/`skill:regen:N` tags."
  (make-resource-specification
   #:id id #:name name #:note note
   #:resource-classified-as (list (string-append "skill:decay:" (number->string decay))
         (string-append "skill:regen:" (number->string regen)))
   #:default-unit-of-resource resource-unit #:default-unit-of-effort effort-unit))
