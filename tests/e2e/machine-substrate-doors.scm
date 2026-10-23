;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-substrate-doors.scm — the declared substrate still answers.
;;;
;;; The browser product was stripped to the machine node, but the KERI /
;;; identity / federation substrate underneath it stayed live — a machine
;;; node's AID, its OOBI replies, its credential chain all ride these doors.
;;; This suite holds the honest line: every declared substrate door still
;;; answers through the layer that serves it. "Answers" means a reply —
;;; (ok . _), (error …), or a value — never "no such door": a head the
;;; dispatch no longer carries.
;;;
;;; Session doors go through ^lobby-session (the AID is closed over);
;;; governance-layer doors take the AID as their first argument.
;;;
;;; Run: guile --no-auto-compile -q -L module -L tests tests/e2e/machine-substrate-doors.scm

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet boot governance)
             (goblins) (goblins vat)
             (ice-9 format))

(define vat (spawn-vat))
(define ALICE "did:keri:DAlice")

(define svc
  (with-vat vat
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f))))

(define session
  (with-vat vat (spawn ^lobby-session ALICE #f #f svc #f)))

;; A door answers: a value, an (ok . _) / (error …) pair, or a raised
;; domain error all count — the head exists and spoke. What fails the
;; contract is the dispatch itself shrugging: "no such door" or goblins'
;; unhandled-message.
(define (answered? target door . args)
  (catch #t
    (lambda ()
      (with-vat vat (apply $ target door args))
      'answered)
    (lambda (k . a)
      (let ((msg (format #f "~a" a)))
        (if (or (string-contains msg "no such door")
                (string-contains msg "unhandled"))
            (begin (format #t "   unanswered: ~s~%" a) #f)
            'answered)))))

;; ("door-name" args…) — session layer: the AID is the session's own.
;; Door names are strings so the coverage lint sees each declared name
;; spelled in a test; the suite resolves them to symbols when calling.
(define session-doors
  '(("fetch-icp" "EABC0000000000000000000000000000000000")
    ("find-icp" "evt-1")
    ("fp-grant" "scope-1" "did:keri:ECandidate")
    ("fp-my-ceremony" "scope-1")
    ("fp-open-ceremony" "scope-1" "did:keri:ECandidate" 1)
    ("fp-pending" "scope-1")
    ("fp-request-enroll" "scope-1")
    ("fp-vouch" "scope-1" "did:keri:ESubject" "knows")
    ("fp-vouch-preimage" "scope-1" "did:keri:ESubject" "knows" "2026-01-01T00:00:00Z")
    ("fp-vouch-signed" "scope-1" "did:keri:ESubject" "knows" "2026-01-01T00:00:00Z" "sig")
    ("fp-withdraw-vouch" "scope-1" "did:keri:ESubject")
    ("my-phc")
    ("profile")
    ("list-log")
    ("list-delegations")
    ("list-uc-proposals")
    ("register-oobi-replies" "EABC" ())
    ("sync-log" ())
    ("update-profile" "Alice" "alice@example.org")))

;; ("door-name" args…) — governance layer: the AID leads the argument list.
(define gov-doors
  '(("admit-body" "did:keri:EHome" "did:keri:EBody")
    ("fp-my-phc")))

(display "\n── session-layer doors ──\n")
(for-each
 (lambda (row)
   (check (format #f "session door ~a answers" (car row))
          (apply answered? session (string->symbol (car row)) (cdr row)) 'answered))
 session-doors)

(display "\n── governance-layer doors ──\n")
(for-each
 (lambda (row)
   (check (format #f "door ~a answers" (car row))
          (apply answered? svc (string->symbol (car row)) ALICE (cdr row)) 'answered))
 gov-doors)

(test-summary!)
