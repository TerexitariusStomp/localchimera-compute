;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/personhood/two-box/box1.scm — the WORKER's box.
;;;
;;; Own process, own LOCALCHIMERA_STATE_DIR, own static server. It waits for the
;;; witness's AID (the roster entry memberships would carry in prod), opens
;;; the ceremony through the SAME door ^planner-service consumes — which
;;; publishes the ask — then polls box2's served /witness/attests until the
;;; co-signature lands, and checks the credential strengthened in place to
;;; its k-of-n multisig form.

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera personhood witness-relay)
             (localchimera credentials work) (localchimera keri acdc) (localchimera keri first-person credentials) (localchimera personhood enrollment) (localchimera keri acdc) (localchimera keri acdc-store) (localchimera keri first-person credentials) (localchimera keri first-person predicates)
             (localchimera vf schemas) (srfi srfi-1)
             (goblins)
             (ice-9 format)
             (ice-9 rdelim)
             (srfi srfi-1))

(define peer   (getenv "WITNESS_PEER"))     ; box2's static base URL
(define shared (getenv "WITNESS_SHARED"))

;; the roster entry, from the choreography dir
(define w-aid
  (let loop ((tries 0))
    (let ((f (string-append shared "/witness-aid")))
      (cond
       ((file-exists? f)
        (call-with-input-file f read-line))
       ((> tries 120) (format #t "[box1] FAIL: no witness aid~%") (exit 1))
       (else (usleep 500000) (loop (+ tries 1)))))))
(format #t "[box1] witnessing peer: ~a~%" w-aid)

(define (work-ev)
  (make-economic-event #:id "e-2box-1" #:action 'work #:output-of "p-2box" #:resource-conforms-to "skill-bake"
    #:provider "EAdaFar" #:effort-quantity (make-measure 3.0 %effort-unit)
    #:has-point-in-time "2026-08-17T10:00:00Z"))

(define vat (spawn-vat))
(define store #f)
(define said
  (with-vat vat
    (set! store (spawn-acdc-store))
    (let* ((door (make-federated-witness-door #:store-of (lambda (_) store)))
           (open (assq-ref door 'open)))
      (open "EScope2Box" (work-ev) (list w-aid "EAdaFar")))))
(unless (string? said)
  (format #t "[box1] FAIL: ceremony did not open~%") (exit 1))
(format #t "[box1] ceremony open, ask published: ~a~%" said)

;; poll box2 until the co-signature lands and finalizes
(let loop ((tries 0))
  (let ((r (poll-peer-witness! peer
             #:in-vat (lambda (th) (with-vat vat (th))))))
    (cond
     ((positive? (cdr r)))              ; landed — fall through to the checks
     ((> tries 120)
      (format #t "[box1] FAIL: no attest landed~%") (exit 1))
     (else (usleep 500000) (loop (+ tries 1))))))

(let ((we (with-vat vat
            (find (lambda (c) (equal? "e-2box-1" (cred-claim c 'event-id)))
                  (non-revoked-by-schema store *schema-localchimera-work-event*)))))
  (unless (and we (pair? (cred-signature we))
               (cred-multisig-valid? we (list w-aid) 1))
    (format #t "[box1] FAIL: credential not strengthened: ~s~%" (and we #t))
    (exit 1))
  (format #t "[box1] the credential strengthened to its witnessed form~%"))

;; ── the ENROLLMENT leg: a candidate vouched for from the other box ─────────
;; Same rails, other ceremony kind. The ecosystem already recognises the
;; sponsor and the remote witness — their PHCs sit in THIS box's store (in
;; prod they enrolled earlier); the candidate is new. Spawning publishes the
;; ask; box2's poll surfaces it as kind=enroll, its vouch crosses home, and
;; the candidate's PHC issues carrying the remote witness as an edge.
(define candidate "ECandidate2Box0000000000000000000000000000")
(with-vat vat
  ($ store 'issue (make-personhood-credential #:ecosystem-aid "EScope2Box"
                                              #:holder-aid "EAdaFar"
                                              #:enrolled-at (current-time)))
  ($ store 'issue (make-personhood-credential #:ecosystem-aid "EScope2Box"
                                              #:holder-aid w-aid
                                              #:enrolled-at (current-time)))
  (spawn-enrollment-ceremony "EScope2Box" candidate "evidence:2box"
                             "EAdaFar" 1 store))
(format #t "[box1] enrollment open, ask published for ~a~%" candidate)

(let loop ((tries 0))
  (let ((r (poll-peer-witness! peer
             #:in-vat (lambda (th) (with-vat vat (th))))))
    (cond
     ((positive? (cdr r)))              ; the vouch landed
     ((> tries 120)
      (format #t "[box1] FAIL: no enrollment vouch landed~%") (exit 1))
     (else (usleep 500000) (loop (+ tries 1))))))

(let ((phc (with-vat vat
             (find (lambda (c) (equal? candidate (cred-holder c)))
                   (non-revoked-by-schema store *schema-localchimera-personhood*)))))
  (cond
   ((and phc
         (assq (string->symbol (string-append "witness-" w-aid))
               (cred-edges phc)))
    (format #t "[box1] candidate PHC issued, carrying the remote vouch edge~%")
    (exit 0))
   (else
    (format #t "[box1] FAIL: candidate PHC missing or edge-less: ~s~%" (and phc #t))
    (exit 1))))
