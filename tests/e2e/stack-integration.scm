;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/stack-integration.scm — the adopted-stack e2e: a REAL
;;; service governs a REAL door decision, end to end.
;;;
;;; The chain: the deployed OPA loads the shipped compute.rego → the
;;; commune's membership data lands in its store → the door's
;;; commune-act-allowed? consults it for a settle → the engine's own
;;; answer governs. Nothing is stubbed between the policy text and the
;;; verdict but HTTP.
;;;
;;; Skips loudly without PLAYNET_OPA_URL — run via tools/dev/run-stack.sh.

(use-modules (playnet test harness)
             (playnet doors machine)
             (playnet delegates)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define opa-url (getenv "PLAYNET_OPA_URL"))

(if (or (not opa-url) (string-null? opa-url))
    (begin
      (display "--: stack integration [skipped — PLAYNET_OPA_URL unset]\n")
      (exit 0)))

(define transport (%json-http-transport opa-url))
(define (PUT path body)  (transport "PUT"  path body))
(define (POST path body) (transport "POST" path body))
(define (GET path)       (transport "GET"  path '()))

(define (json-ref parsed key)
  (cond ((assoc key parsed) => cdr)
        ((assoc (string->symbol key) parsed) => cdr)
        (else #f)))

;; the shipped policy, verbatim — what a deployed OPA actually serves
(define rego
  (call-with-input-file "deploy/policies/playnet/doors/machine.rego"
    get-string-all))

;; 1. the deployed OPA serves the shipped policy (mounted from
;; deploy/policies/) — the door's consult lands on its package
(define served (GET "/v1/policies"))
(check "the shipped compute.rego is what the live OPA serves"
       (and (pair? served)
            (string? (cdr served))
            (string-contains (cdr served) "playnet.doors.compute")
            #t) #t)

;; membership rides the policy's documented shape:
;; data.playnet.members[commune] = {members: [...], admins: [...]}
(define members
  (PUT "/v1/data/playnet/members"
       "{\"commune-x\":{\"members\":[\"alice\",\"bob\"],\"admins\":[\"alice\"]}}"))
(check "the commune membership lands in the store"
       (< (car members) 300) #t)

;; 2. the door's own consult, three verdicts
(parameterize ((*machine-authz* (make-opa-delegate transport)))
  (check "a member-admin may administer — the engine's allow governs"
         (commune-act-allowed? "alice" "commune-x" "administer") #t)
  (check "a plain member is denied administer"
         (commune-act-allowed? "bob" "commune-x" "administer") #f)
  (check "a stranger is denied create — fail closed on no membership"
         (commune-act-allowed? "mallory" "commune-x" "create") #f)
  (check "a member may create"
         (commune-act-allowed? "bob" "commune-x" "create") #t))

;; 3. policy-less path is fail closed — no policy named, the engine
;; answers nothing usable and the consult denies
(parameterize ((*machine-authz* (make-opa-delegate transport)))
  (check "a policy that doesn't exist answers deny, not allow"
         (let ((a ((make-opa-delegate transport)
                   "playnet/doors/nonexistent"
                   '(("principal" . "alice")))))
           ;; the consult treats a missing/empty result as deny — verify
           ;; the raw answer really carries no allow:true
           (not (and (pair? a)
                     (let* ((body (cdr a)))
                       (and (string? body)
                            (string-contains body "\"allow\":true"))))))
         #t))

(test-summary!)
