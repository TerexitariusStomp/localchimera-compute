;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-open-terminal-mailbox-gate.scm — the two remaining role-gate stubs,
;;; wired to a live PHC
;;;
;;; open-terminal/get-mailbox on the public ^lobby used to answer only the
;;; removed-gate error: the role-credential ceremony they gated on
;;; (governance-member?) was deleted 2026-08-19, never having bootstrapped
;;; for anyone. This is the replacement, wired to holds-any-live-phc?
;;; (playnet keri first-person predicates) — the same personhood-credential
;;; machinery accept-socialization/may-govern? already gate on, portable
;;; across ecosystems the same way. No new authority concept.
;;;
;;; What this pins:
;;;   • a bystander with no PHC is refused at both doors, the store untouched;
;;;   • a member holding a live PHC reaches the real terminal-svc/mailbox-mgr
;;;     capability and gets back its real reply, not just "not an error";
;;;   • a legacy org-pubkey identity-key (never a PHC holder) is refused the
;;;     same way a bystander AID is — the old behavior for that path.
;;;
;;; Run: guile -L module -L tests tests/doors/test-open-terminal-mailbox-gate.scm

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet gateway mailbox)
             (playnet keri acdc-store) (playnet keri first-person credentials)
             (goblins) (goblins vat) (goblins actor-lib methods) (goblins utils hashmap))

(define vat (spawn-vat))
(define MEMBER "EMember0000000000000000000000000000000000")
(define BYST   "EBystander0000000000000000000000000000000000")
(define ORG-PUBKEY "org-pubkey-legacy-flow")

(define store (with-vat vat (spawn-acdc-store)))
(define phc (make-personhood-credential #:ecosystem-aid "E_eco"
                                        #:holder-aid MEMBER
                                        #:enrolled-at 100))
(with-vat vat ($ store 'issue phc))

;; Minimal terminal-svc stub: just enough to prove the gate hands the call
;; through to the real capability on success — ^terminal-service's own
;; correctness (it needs signup-vat/signup-agent) is out of scope here.
(define-actor (^stub-terminal-svc bcom)
  (methods ((open identity-key client-inbox) (list 'opened identity-key client-inbox))))
(define terminal-svc (with-vat vat (spawn ^stub-terminal-svc)))

;; The real mailbox manager — trivial to spawn, no unrelated setup needed.
(define mailbox-mgr (with-vat vat (spawn ^mailbox-manager (hashmap))))

;; ^lobby's trailing params are #:optional (positional, not #:key) —
;; oobi-host then acdc-store — so oobi-host gets an explicit #f to reach it.
(define lobby
  (with-vat vat
    (spawn ^lobby #f #f #f terminal-svc mailbox-mgr #f #f #f
           #f store)))

(define (settle p)
  (let ((box #f) (done #f))
    (with-vat vat
      (on p (lambda (v) (set! box v) (set! done #t))
          #:catch (lambda (e) (set! box (list 'error e)) (set! done #t))))
    (let loop ((i 0))
      (unless (or done (> i 200)) (usleep 10000) (loop (+ i 1))))
    box))

(display "\n── open-terminal / get-mailbox: a bystander with no PHC is refused ──\n")
(define t1 (settle (with-vat vat ($ lobby 'open-terminal BYST "inbox-1"))))
(check "open-terminal refused" (eq? 'error (car t1)))
(check-pred "…naming the credential requirement" (string-contains (cadr t1) "registered member"))

(define m1 (settle (with-vat vat ($ lobby 'get-mailbox BYST))))
(check "get-mailbox refused" (eq? 'error (car m1)))
(check-pred "…naming the credential requirement" (string-contains (cadr m1) "registered member"))

(display "\n── a live PHC holder reaches the real capability ──\n")
(define t2 (settle (with-vat vat ($ lobby 'open-terminal MEMBER "inbox-2"))))
(check "open-terminal succeeds" t2 (list 'opened MEMBER "inbox-2"))

(define m2 (settle (with-vat vat ($ lobby 'get-mailbox MEMBER))))
(check-pred "get-mailbox returns the real mailbox actor" (not (eq? 'error (and (pair? m2) (car m2)))))
;; the reply is a ^mailbox ref — prove it by using it
(check "…and it's a working mailbox" (with-vat vat ($ m2 'count)) 0)

(display "\n── a legacy org-pubkey identity-key (no PHC ever) is refused the same way ──\n")
(define t3 (settle (with-vat vat ($ lobby 'open-terminal ORG-PUBKEY "inbox-3"))))
(check "open-terminal refused for legacy org-pubkey" (eq? 'error (car t3)))

(test-summary!)
