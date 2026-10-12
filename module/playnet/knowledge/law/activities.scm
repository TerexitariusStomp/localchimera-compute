;;; law/activities.scm — the GENERIC layer. An ACTION is met by alternative MODES
;;; (modes of production / distribution); each mode is a recipe that trips
;;; crossings; the legal requirement of any (action, mode, jurisdiction) is one
;;; fold over the shared rule library. The engine (legal/registry.scm) never
;;; changes — only this catalogue grows. Free food distribution is one action;
;;; sheltering people another. "Pick an action, compare its modes, read the
;;; legal exterior of each, anywhere."
;;;
;;; Loads AFTER legal/registry.scm and worlds/free-food-distribution.scm (it reuses
;;; their places, parent-of, and rule library, and adds a second action).

;;; ─── a MODE : a strategy for an action — a recipe that trips crossings ────
;;; kind ∈ production | distribution  (how the good is made / how it reaches a
;;; person). crossings are the placeless facts the mode trips; the fold prices
;;; them per jurisdiction.
(define-module (playnet knowledge law activities)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet vf schemas)
  #:use-module (playnet legal crossings)
  #:use-module (playnet legal registry)
  #:use-module (playnet legal reform)
  #:use-module (playnet vf facts places)
  #:use-module ((playnet knowledge law context-pack) #:select (bill-at))
  #:use-module (playnet knowledge catalogues us-states-fips)
  #:use-module (playnet knowledge law aspects)
  #:use-module (playnet knowledge law reform-mirrors)
  #:use-module (playnet knowledge law structural-demands)
  #:use-module (playnet knowledge worlds free-food-distribution)
  #:use-module ((playnet knowledge law way-recipes) #:select (way-recipe-crossings way-recipe-channel))
  #:export (mode ffd-recipe->mode *housing-modes* *activities* %ffd-activity activity-ref activity-modes activity-act acting mode-bill activity-headline))

;;; `performs` : the federation aspects the mode's own steps carry out
;;; (law/aspects.scm) — what a member running it adds to the federation's
;;; actual practice.
;;; `recipe` : the ValueFlows recipe that IS this way (recipes/ways.scm,
;;; recipes/dwelling.scm). What the way trips and the channel it hands its good
;;; on by are read off that recipe's own records (way-recipes.scm); the way
;;; states its name, its steps and what it performs.
;;; `act` : what kind of act the way is — the fact a rule reads with `act-is`
;;; ("forbidden here unless the act is farming"). Every way of one activity is
;;; the same act, so the activity states it and its ways carry it (`acting`).
(define* (mode id name kind recipe steps note #:optional (performs '()))
  `((id . ,id) (name . ,name) (kind . ,kind) (recipe . ,recipe)
    (crossings . ,(way-recipe-crossings recipe))
    (channel . ,(way-recipe-channel recipe))
    (steps . ,steps) (note . ,note) (performs . ,performs)))
(define (acting act modes)
  (map (lambda (m) (cons (cons 'act act) m)) modes))

;; free food's existing recipes ARE its modes — adapt them (add a kind tag).
(define (ffd-recipe->mode r)
  (let ((cr (assq-ref r 'crossings)))
    (mode (assq-ref r 'id) (assq-ref r 'name)
          (if (or (memq 'recover-surplus cr) (memq 'home-kitchen cr)) 'production 'distribution)
          (assq-ref r 'recipe) (assq-ref r 'steps) (assq-ref r 'note)
          (or (assq-ref r 'performs) '()))))

;;; ─── ACTION 2 : sheltering people ────────────────────────────────────────
;;; The same shape as free food: alternative modes, each tripping crossings the
;;; jurisdiction prices. Crossings reused from the open catalogue (built-
;;; structure, own-property) plus housing-specific ones, registered here so one
;;; symbol carries its kind and gloss to every reader.
;;; (symbol             kind       gloss  [what the records lack, when a tag must say it])
(for-each
 (lambda (row) (apply register-crossing! row))
 '((occupancy          mirrored   "houses a person in an existing dwelling")
   (land-use           by-choice  "puts land to a use the jurisdiction zones" where)
   (congregate-shelter mirrored   "shelters people together on one site" handover)
   (occupy-property    avoidable  "occupies property without the owner's title" whose)))
(define *housing-modes*
  (acting 'habitation
  (list
   (mode "mode-host-home" "Host in a spare room" 'distribution
         "recipe-shelter"                              ; recipes/dwelling.scm
         '("offer a spare room" "share the household" "no separate dwelling created")
         "Lightest: sheltering a person in your own home rarely trips a code.")
   (mode "mode-community-land-trust" "Community land trust housing" 'production
         "recipe-way-land-trust"
         '("acquire land into a CLT (ownerless purpose)" "build/rehab to code" "lease homes at cost")
         "Owns by purpose, builds to code — legal everywhere, needs permits."
         '(building-code fire-safety habitability))
   (mode "mode-tiny-home-village" "Sanctioned tiny-home village" 'production
         "recipe-way-tiny-homes"
         '("secure a site + use permit" "place code-compliant tiny homes" "shared services on-site")
         "A sanctioned encampment; turns on whether the jurisdiction permits the land use."
         '(building-code))
   (mode "mode-new-coop-build" "Build new cooperative housing" 'production
         "recipe-way-coop-build"
         '("assemble the parcel" "obtain building + zoning approvals" "build, then co-own")
         "Heaviest where zoning is restrictive; lightest under by-right reform."
         '(building-code fire-safety habitability))
   (mode "mode-occupy-vacant" "Occupy a vacant building" 'production
         "recipe-way-occupy-vacant"
         '("identify a long-vacant building" "move people in" "press for legalization")
         "Unpermitted occupation — trespass in most places; a few recognise adverse possession / squatters."))))

;;; ─── the catalogue + the generic fold ────────────────────────────────────
;;; The folds here read the law in force: `current-legal-rules`
;;; (law/context-pack.scm), every rule a steward has encoded in a pack on disk.

;;; the activity the free-food federation, its arcs and its shields belong to
(define %ffd-activity "free-food-distribution")

(define *activities*
  (list
   `((id . ,%ffd-activity) (name . "Free food distribution")
     (verb . "give out free food")
     (modes . ,(acting 'free-food-distribution (map ffd-recipe->mode *ffd-recipes*))))
   `((id . "shelter-people") (name . "Sheltering people")
     (verb . "shelter people")
     (modes . ,*housing-modes*))))

(define (activity-ref id) (find (lambda (a) (equal? id (assq-ref a 'id))) *activities*))
(define (activity-modes a) (assq-ref a 'modes))
(define (activity-act a) (assq-ref (car (activity-modes a)) 'act))   ; its ways' one act

;;; the legal exterior of a MODE at a PLACE — the generic fold (any action).
(define (mode-bill place-id mode)
  (bill-at place-id (assq-ref mode 'crossings)
           #:act (assq-ref mode 'act) #:channel (assq-ref mode 'channel)))

;;; the lightest legal mode for an action at a place — its headline burden.
(define (activity-headline place-id activity)
  (let loop ((modes (activity-modes activity)) (best #f))
    (if (null? modes)
        best
        (call-with-values (lambda () (mode-bill place-id (car modes)))
          (lambda (bill hits)
            (let* ((w (bill-weight bill)) (forb (stance-forbids? (bill-stance bill hits)))
                   (cand (list (assq-ref (car modes) 'id) w forb)))
              (loop (cdr modes)
                    (if (and (not forb)
                             (or (not best) (< w (cadr best)))) cand best))))))))
