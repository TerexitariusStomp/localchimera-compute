;;; module/playnet/doors/skills.scm — a skill is an EconomicResource per (agent, skill), declared, lowered and revoked by events.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the scope root and the arguments; the door is the gate and one call.

(define-module (playnet doors skills)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet observation adjustment) #:select (adjustment-event count-difference))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet utils store-utils) #:select (generate-id))
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet vf facts person-facts) #:select (skill-id skill-spec))
  #:use-module ((playnet vf schemas) #:select (economic-resource-conforms-to economic-resource-id economic-resource-onhand-quantity make-economic-event make-economic-resource make-measure measure-has-numerical-value measure-has-unit))
  #:export (revoke-skill! lower-resource! declare-skill!))

;; Raise a skill resource for AGENT-ID — the declare-skill door's own
;; first-declaration/re-declaration logic (VF's raise, concepts/actions.md),
;; factored out so a new agent's bootstrap defaults (set-profile's first-time
;; branch, below) share the identical lifecycle rather than a second copy of
;; it: a default skill IS a declared skill, raised once here the same way the
;; RPC door raises one on request.
(define (revoke-skill! obs agent-id skill-spec-id)
  "Lower every skill resource AGENT-ID holds for SKILL-SPEC-ID to zero — the
   declared `skill:AID:spec` and the `skill-AID-labor` an offer of time seeds
   alike (the resources stay, carrying both events); → the declared id."
  (let ((now (iso-now)))
    (for-each
     (lambda (r)
       (when (equal? (economic-resource-conforms-to r) skill-spec-id)
         (let ((rid (economic-resource-id r))
               (qty (measure-has-numerical-value (economic-resource-onhand-quantity r))))
           ($ obs 'record-event
              (adjustment-event (generate-id (string-append "revoke:" rid ":" now ":")) rid skill-spec-id
                                (count-difference qty 0) %count-unit
                                #:provider agent-id #:receiver agent-id
                                #:when now #:created now #:counted 0
                                #:note "skill revoked")))))
     ($ obs 'skills-of agent-id)))
  (skill-id agent-id skill-spec-id))
;; Lower a held resource R of AGENT-ID to zero: the one record of "no longer
;; held here", whether the means was retired or the person moved on.
(define (lower-resource! obs agent-id r note)
  (let ((q (measure-has-numerical-value (economic-resource-onhand-quantity r)))
        (now (iso-now)))
    (when (> q 0)
      ($ obs 'record-event
         (make-economic-event
          #:id (generate-id (string-append "retire:" (economic-resource-id r) ":" now ":")) #:action 'lower #:resource-inventoried-as (economic-resource-id r) #:resource-conforms-to (economic-resource-conforms-to r)
          #:provider agent-id #:receiver agent-id
          #:resource-quantity (make-measure q (measure-has-unit (economic-resource-onhand-quantity r))) #:has-point-in-time now #:created now
          #:note note)))))
(define (declare-skill! root agent-id skill-spec-id)
  "AGENT-ID holds the skill SKILL-SPEC-ID at ROOT: the resource raised to held,
   and the spec declared as worked where the store has none of that id — what
   makes the resource read as a skill (formulas/actions labour-specs)."
  (let* ((obs ($ root 'observer))
         (rs  ($ root 'recipe-store))
         (rid (skill-id agent-id skill-spec-id))
         (r   ($ obs 'get-resource rid))
         (qty (and r (measure-has-numerical-value
                      (economic-resource-onhand-quantity r)))))
    (unless ($ rs 'get-resource-spec skill-spec-id)
      ($ rs 'add-resource-spec (skill-spec skill-spec-id)))
    (cond
      ;; first declaration: the resource enters with its balance
      ((not r)
       ($ obs 'record-resource
          (make-economic-resource
           #:id rid #:name (string-append agent-id " " skill-spec-id)
           #:conforms-to skill-spec-id
           #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable agent-id)))
      ;; re-declaration after a revoke: raise it back to held
      ((<= qty 0)
       (let ((now (iso-now)))
         ($ obs 'record-event
            (adjustment-event (generate-id (string-append "declare:" rid ":" now ":")) rid skill-spec-id
                              (count-difference qty 1) %count-unit
                              #:provider agent-id #:receiver agent-id
                              #:when now #:created now #:counted 1
                              #:note "skill re-declared")))))
      ;; already held: nothing to record
    rid))