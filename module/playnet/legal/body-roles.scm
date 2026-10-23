;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; legal/body-roles.scm — the roles a person holds in a legal body, as
;;; ValueFlows <agent-relationship-role> records.
;;;
;;; A body (legal/bodies.scm) is an organization <agent>; who stands behind it is
;;; a set of <agent-relationship>s whose `relationship` names one of these three
;;; roles. The roles are the first <agent-relationship-role> records the planner
;;; mints, so the schema's own vocabulary carries the fact, and the register of
;;; a body is a fold over relationships, never a list kept beside them.
;;;
;;;   role:steward  — a custodian-steward: holds a key of the body's quorum,
;;;                   acts as a fiduciary to its purpose, owns nothing of it
;;;                   (playnet.typ §"Standing: held by key, a mask at the door")
;;;   role:member   — a member of the body, or a body that is a member of a scope
;;;   role:officer  — an officer the law names (a director, a treasurer)
;;;
;;; `seed-body-roles!` puts them in an ^agent-store once; a store that has them
;;; is left as it is.

(define-module (playnet legal body-roles)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:export (*body-roles* role:steward role:member role:officer body-role-ids
            seed-body-roles!))

(define role:steward "role:steward")
(define role:member  "role:member")
(define role:officer "role:officer")

(define *body-roles*
  (list (make-agent-relationship-role #:id role:steward #:label "steward of"
                                      #:inverse-label "stewarded by"
                                      #:note "a custodian-steward of a body: a key of its quorum, a fiduciary to its purpose"
                                      #:classified-as '("body-role"))
        (make-agent-relationship-role #:id role:member #:label "member of"
                                      #:inverse-label "has member"
                                      #:note "a member of a body, or a body that is a member of a scope"
                                      #:classified-as '("body-role"))
        (make-agent-relationship-role #:id role:officer #:label "officer of"
                                      #:inverse-label "has officer"
                                      #:note "an officer the law names"
                                      #:classified-as '("body-role"))))

(define (body-role-ids) (map agent-relationship-role-id *body-roles*))

(define (seed-body-roles! agent-store)
  "Every body role stands in AGENT-STORE; one that already does is left alone."
  (for-each (lambda (r)
              (unless ($ agent-store 'get-role (agent-relationship-role-id r))
                ($ agent-store 'add-role r)))
            *body-roles*)
  (body-role-ids))
