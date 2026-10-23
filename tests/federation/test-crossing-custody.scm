;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-crossing-custody.scm — a settled crossing leaves a record.
;;;
;;; The goods in the federation's pool are common: a scope that gives hands its
;;; custody to the federation, a scope that draws receives it from the
;;; federation — two legs per participant, never a pairing of supplier and
;;; drawer (planner/federation/crossing-custody.scm). Each leg is written by the party that
;;; RECEIVES it, as the occurrence it witnessed (federation/federate.scm), and
;;; signed by that party:
;;;
;;;   • the legs are a function of the final attestations: a supplier's flow is a
;;;     leg to the federation, a drawer's a leg from it; a peer not yet final
;;;     leaves none; a flow that rounds to nothing leaves none;
;;;   • the ids are deterministic (good, scope, day), and the legs balance where
;;;     the flows do;
;;;   • each record is a credential its receiver issues and holds for the
;;;     provider; the same settlement again is the same record; a settlement
;;;     that moves the quantity on the same day replaces it;
;;;   • the federation records what the scopes gave it and a scope what it drew,
;;;     and neither writes the other's.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/federation/test-crossing-custody.scm

(use-modules (playnet test harness)
             ((playnet test planner federation-wire-fixture) #:select (fx-identity))
             (playnet federation crossing-custody)
             (playnet federation federate)
             (playnet boot scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig)
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
             (goblins) (goblins vat)
             (rnrs bytevectors) (srfi srfi-1))

(define FED "EFederation") (define A "EGranary") (define B "ETable") (define C "EMill")
(define (att stage . rows)
  `((stage . ,stage) (links . ,(map (lambda (r) `((link . ,(car r)) (plan . ,(cdr r)))) rows))))

(display "\n── the legs a set of final attestations leaves ──\n")
(define settled (list (cons A (att 'final '("flour" . 30.0)))
                      (cons B (att 'final '("flour" . -20.0)))
                      (cons C (att 'final '("flour" . -10.0)))))
(define legs (crossing-legs settled FED "2026-10-02"))
(check "a leg per participant: three" (length legs) 3)
(check "the supplier gives to the federation"
       (let ((l (find (lambda (l) (equal? (leg-receiver l) FED)) legs)))
         (list (leg-provider l) (leg-good l) (leg-qty l)))
       (list A "flour" 30.0))
(check "the drawers receive from it, one each"
       (sort (map (lambda (l) (list (leg-receiver l) (leg-qty l)))
                  (filter (lambda (l) (equal? (leg-provider l) FED)) legs))
             (lambda (x y) (string<? (car x) (car y))))
       (list (list C 10.0) (list B 20.0)))
(check "the ids name the good, the scope and the day"
       (sort (map leg-id legs) string<?)
       (sort (list "cross|flour|EGranary|2026-10-02" "cross|flour|ETable|2026-10-02" "cross|flour|EMill|2026-10-02") string<?))
(check "what is given equals what is drawn, where the flows balance"
       (list (apply + (map leg-qty (filter (lambda (l) (equal? (leg-receiver l) FED)) legs)))
             (apply + (map leg-qty (filter (lambda (l) (equal? (leg-provider l) FED)) legs))))
       '(30.0 30.0))
(check "a peer not yet final leaves no leg"
       (length (crossing-legs (list (cons A (att 'refined '("flour" . 30.0)))) FED "2026-10-02")) 0)
(check "a flow that rounds to nothing leaves none"
       (length (crossing-legs (list (cons A (att 'final '("flour" . 0.0002)))) FED "2026-10-02")) 0)
(check "the quantity is rounded to the quantum, the same from every gateway"
       (leg-qty (car (crossing-legs (list (cons A (att 'final '("flour" . 19.99996)))) FED "2026-10-02"))) 20.0)

(display "\n── the records ──\n")
(define vat (spawn-vat))
(define id-f (fx-identity 3))
(define id-a (fx-identity 1))
(define aid-f (keri-identity-aid id-f)) (define aid-a (keri-identity-aid id-a))
(define aid-b (keri-identity-aid (fx-identity 2)))
(define (unit-of good) "kg")
(with-vat vat
  (let* ((fed-store (spawn-acdc-store)) (b-store (spawn-acdc-store))
         (fed (spawn-scope "Valley" #:kind 'federation #:scope-aid aid-f
                           #:keypair (keri-identity-keypair id-f) #:acdc-store fed-store)))
    (define (recorded store who)
      (filter (lambda (c) (and (not (cred-revoked? c)) (equal? (cred-issuer c) who)))
              ($ store 'by-issuer who)))
    ;; the federation's gateway reads A and B as the fold heard them
    (define fed-rec
      (spawn ^custody-recorder fed-store fed aid-f aid-f
             (lambda () (list (cons aid-a (att 'final '("flour" . 30.0)))
                              (cons aid-b (att 'final '("flour" . -30.0)))))
             unit-of))
    ;; B's gateway reads its own
    (define b-rec
      (spawn ^custody-recorder b-store #f aid-b aid-f
             (lambda () (list (cons aid-b (att 'final '("flour" . -30.0)))))
             unit-of))
    ($ fed-rec 'tick)
    ($ b-rec 'tick)
    (check "the federation records what A gave it: one record, issued by the federation, held by A"
           (map (lambda (c) (list (cred-holder c) (cred-claim c 'qty) (cred-claim c 'resource-conforms-to)
                                  (cred-claim c 'action)))
                (recorded fed-store aid-f))
           (list (list aid-a 30.0 "flour" 'transfer-custody)))
    (check "it is signed by the federation" (every (lambda (c) (and (cred-signature c) #t)) (recorded fed-store aid-f)) #t)
    (check "B records what it drew: issued by B, held by the federation"
           (map (lambda (c) (list (cred-holder c) (cred-claim c 'qty))) (recorded b-store aid-b))
           (list (list aid-f 30.0)))
    (check "the federation records nothing of B's draw: B writes its own receipt"
           (length (filter (lambda (c) (equal? (cred-holder c) aid-b)) (recorded fed-store aid-f))) 0)
    (check "the same settlement ticked again is the same record"
           (begin ($ fed-rec 'tick) (length (recorded fed-store aid-f))) 1)
    (check "the legs seen are kept" (length ($ fed-rec 'legs)) 2)))

(display "\n── a settlement that moves on the same day replaces the record ──\n")
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (flows (list 30.0))
         (rec (spawn ^custody-recorder store #f aid-f aid-f
                     (lambda () (list (cons aid-a (att 'final (cons "flour" (car flows))))))
                     unit-of)))
    (define (live) (filter (lambda (c) (not (cred-revoked? c))) ($ store 'by-issuer aid-f)))
    ($ rec 'tick)
    (set! flows (list 45.0))
    ($ rec 'tick)
    (check "one record stands" (length (live)) 1)
    (check "at the later quantity" (cred-claim (car (live)) 'qty) 45.0)
    (check "the earlier is revoked, not erased"
           (length (filter cred-revoked? ($ store 'by-issuer aid-f))) 1)))

(test-summary!)
