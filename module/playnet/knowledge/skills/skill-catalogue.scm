;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; skills/skill-catalogue.scm — the catalogue $\mathcal{K}$, whole.
;;;
;;; docs/playnet.typ's own theory names this: "the federation's stock of
;;; skilled people... the catalogue of skills the federation sustains. For
;;; each skill $k$ in the catalogue $\mathcal{K}$..." (§Labour, skills, and
;;; free time). Every domain file under knowledge/skills/ contributes its
;;; entries; this module is the one union, the door a seeder reads instead
;;; of building its own skill specs inline.
;;;
;;;   %skill-catalogue    every skill's resource-specification, once
;;;   catalogue-skill      one skill by id, or #f — a gap to fill in the
;;;                        domain file, not silently patched at the call site

(define-module (playnet knowledge skills skill-catalogue)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet vf schemas) #:select (resource-specification-id))
  #:use-module ((playnet knowledge skills dev-skills) #:select (%dev-skills))
  #:use-module ((playnet knowledge skills meeting-skills) #:select (%meeting-skills))
  #:export (%skill-catalogue catalogue-skill))

(define %skill-catalogue (append %dev-skills %meeting-skills))

(define (catalogue-skill id)
  "The catalogue's own resource-specification for skill ID, or #f when
   $\\mathcal{K}$ holds none by that id."
  (find (lambda (s) (equal? id (resource-specification-id s))) %skill-catalogue))
