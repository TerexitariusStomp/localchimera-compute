;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; dsl/shorthand.scm — the ValueFlows records, spelled short, once.
;;;
;;; A recipe process, a produce / consume / work / use flow, a resource spec,
;;; a held resource, a person, a place and a working window are each one
;;; positional constructor with a long #f tail. Seeders under knowledge/recipes/
;;; and the suites under tests/ spell them the same way, so
;;; the spelling lives here — below the test modules ((localchimera test scope)
;;; re-exports it) and beside the seeders — and a record built by a fixture is
;;; the record a seeder writes.
;;;
;;; The positional arguments are the common case; a keyword names the field a
;;; suite reads beyond it (a stage, a batch minimum, a window on a resource, the
;;; place a resource is contained in). A record with a field none of these
;;; name is spelled with its constructor.

(define-module (localchimera knowledge dsl shorthand)
  #:use-module ((localchimera utils units) #:select (%count-unit %effort-unit))
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera vf beyond schedules)
  #:use-module ((localchimera vf formulas actions) #:select (input-action? output-action?))
  #:use-module (ice-9 format)
  #:export (rp* flow* out* consume* wk* use* spec* er holding
            person* org* place*
            weekday-window all-week-window hours-of
            rp out in wrk out/u in/u wrk/u))

;; a recipe process; DURATION in hours when a run has a stated length. TAGS is
;; its classification (a "whole-count" process, a mode), MBQ a minimum batch
;; in MBQ-UNIT, CONFORMS-TO its process specification.
(define* (rp* id nm #:optional (duration #f)
              #:key (tags #f) (mbq #f) (mbq-unit "kg") (conforms-to #f))
  (make-recipe-process #:id id #:name nm #:process-conforms-to conforms-to #:process-classified-as tags
                       #:has-duration (and duration (make-duration duration %effort-unit))
                       #:minimum-batch-quantity (and mbq (make-measure mbq mbq-unit))))
;; the flows: what a process produces (marked primary unless said otherwise),
;; consumes, works, uses. STAGE / STATE name the stage the flow's end of the
;; act requires or leaves; TAGS classify the flow itself.
;; a flow of ACTION: it stands on the side of PROC the action table gives the action
;; (vf/formulas/actions.scm), so what generates flows names the action and the process
;; and never which of input-of and output-of to fill
(define* (flow* id action spec q proc #:optional (unit "kg") #:key (primary #f) (tags #f))
  (make-recipe-flow #:id id #:action action #:resource-conforms-to spec #:resource-classified-as tags #:resource-quantity (make-measure q unit)
                    #:recipe-input-of (and (input-action? action) proc) #:recipe-output-of (and (output-action? action) proc) #:is-primary primary))
(define* (out* id spec q proc #:optional (unit "kg")
               #:key (stage #f) (state #f) (primary #t) (tags #f))
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-classified-as tags #:resource-quantity (make-measure q unit)
                    #:recipe-output-of proc #:stage stage #:state state #:is-primary primary))
(define* (consume* id spec q proc #:optional (unit "kg")
                   #:key (stage #f) (state #f) (tags #f))
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec
                    #:resource-classified-as tags #:resource-quantity (make-measure q unit)
                    #:recipe-input-of proc #:stage stage #:state state))
(define* (wk* id skill hrs proc #:optional (unit %effort-unit))
  (make-recipe-flow #:id id #:action 'work #:resource-conforms-to skill
                    #:effort-quantity (make-measure hrs unit) #:recipe-input-of proc))
;; a use draws HRS of the service; with #:qty it draws QTY units of it, for HRS
;; when HRS is a number and for the period's length when HRS is #f
(define* (use* id spec proc #:optional (hrs 1.0) #:key (qty #f) (unit %count-unit))
  (if qty
      (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec #:resource-quantity (make-measure qty unit)
                        #:effort-quantity (and hrs (make-measure hrs %effort-unit)) #:recipe-input-of proc)
      (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec
                        #:resource-quantity (make-measure hrs %effort-unit) #:recipe-input-of proc)))
;; a resource specification counted in UNIT
(define* (spec* id nm unit #:key (keep-in-place #f))
  (make-resource-specification #:id id #:name nm #:default-unit-of-resource unit
                               #:keep-in-place keep-in-place))
;; a resource of SPEC held at PLACE, accounted to ACCT (a person's skill, a commune's
;; tool); CUSTODIAN is the custodian-scope, for the suites that read custody;
;; WINDOW when the thing itself keeps hours; CONTAINED-IN the resource it sits
;; inside (a pool's container); TAGS its classification.
(define* (er id spec acct #:key (place "town") (qty 1.0) (unit "x") (custodian #f) (name #f)
                                (window #f) (contained-in #f) (tags '()))
  (make-economic-resource #:id id #:name name #:conforms-to spec #:classified-as tags
    #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit) #:current-location place #:primary-accountable acct #:custodian-scope custodian
    #:contained-in contained-in #:availability-window window))
(define holding er)

;; a person at PLACE, tagged (a skill, a mobility), keeping WINDOW; an
;; organization there; a place at LAT LON, hanging under PARENT
(define* (person* id #:key (place "town") (tags '()) (window #f) (name id))
  (make-agent #:id id #:type 'person #:name name #:primary-location place #:classified-as tags
              #:availability-window window))
(define* (org* id #:key (place "town") (tags '()) (name id))
  (make-agent #:id id #:type 'organization #:name name #:primary-location place #:classified-as tags))
(define* (place* id #:key (lat 0.0) (lon 0.0) (parent #f) (name #f))
  (make-spatial-thing #:id id #:name name #:lat lat #:long lon #:contained-in parent))

;; a working week; every day of the week; and a single day of H hours.
;; A world that declares no partition stands on the standing one, laid from
;; TODAY, so a suite that must read the same economy on a Saturday gives its
;; people the all-week window.
(define* (weekday-window #:optional (from "09:00") (to "17:00")
                         (days '(monday tuesday wednesday thursday friday)))
  (make-availability-window #f #f (list (make-day-schedule days (list (make-time-range from to)))) #f))
(define* (all-week-window #:optional (from "00:00") (to "23:59"))
  (weekday-window from to '(monday tuesday wednesday thursday friday saturday sunday)))
(define (hours-of h)
  (make-availability-window #f #f
    (list (make-day-schedule '(monday) (list (make-time-range "00:00" (format #f "~2,'0d:00" h))))) #f))

;; The short spelling the engine suites and the long recipes read, over the
;; starred constructors above.
;; `wrk` names no skill — the work is general labour.
(define (rp id name) (rp* id name))
(define (out id spec q proc) (out* id spec q proc))
(define (in  id spec q proc) (consume* id spec q proc))
(define (wrk id hrs proc)    (wk* id #f hrs proc))
;; The same three, with the unit given rather than assumed. `out`/`in` above read
;; in kilograms because the bread chain is a mass chain, but a recipe measured in
;; acres, pounds, cubic metres or hectares is not an exception. The unit is a
;; string the planner carries and never interprets.
(define (out/u id spec q unit proc) (out* id spec q proc unit))
(define (in/u  id spec q unit proc) (consume* id spec q proc unit))
(define (wrk/u id hrs unit proc)    (wk* id #f hrs proc unit))
