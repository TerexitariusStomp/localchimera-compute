;;; federation/crossing-custody.scm — what a settled crossing leaves as a record.
;;;
;;; The goods in the federation's pool are common: a scope that gives a good
;;; hands its custody to the federation, and a scope that draws one receives
;;; custody from it. So a settled crossing is two legs per participant and
;;; never a pairing of supplier with drawer:
;;;
;;;   a scope whose signed flow on a good is positive  →  scope ⇒ federation
;;;   a scope whose signed flow on a good is negative  →  federation ⇒ scope
;;;
;;; Each leg is written by the party that RECEIVES it, as the occurrence it
;;; witnessed, and signed by that party; the giver's side stands in its own
;;; signed final attestation. This module is the pure half — the legs a set of
;;; final attestations leaves, with deterministic ids; the credentials they
;;; become are made where governance is in reach (federation/federate.scm).
;;;
;;; A leg appears only for a commune whose peer is FINAL, and its quantity is
;;; the commune's own signed flow at the final plan, rounded to the quantum
;;; (rounding is what lets every gateway name the same number), so the supplier's
;;; gateway, the drawer's gateway and the federation's gateway each derive the
;;; same ids and the same quantities from the same attestations.

(define-module (playnet federation crossing-custody)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (crossing-legs leg-id leg-good leg-provider leg-receiver leg-qty
            legs-of-party))

(define (leg-id l) (assq-ref l 'id))
(define (leg-good l) (assq-ref l 'good))
(define (leg-provider l) (assq-ref l 'provider))
(define (leg-receiver l) (assq-ref l 'receiver))
(define (leg-qty l) (assq-ref l 'qty))

(define (quantise q quantum)
  (* quantum (inexact->exact (round (/ q quantum)))))

(define* (crossing-legs attested federation-aid day #:key (quantum 1/1000))
  "The legs the final attestations ATTESTED ((aid . attestation) …) leave, for the
   federation FEDERATION-AID on DAY (an ISO date): a list of alists
   ((id . \"cross|good|aid|day\") (good . g) (provider . aid) (receiver . aid)
   (qty . q)). A commune that is not final leaves none; a flow that rounds to
   nothing at QUANTUM leaves none."
  (append-map
   (lambda (a)
     (let ((aid (car a)) (att (cdr a)))
       (if (not (eq? (assq-ref att 'stage) 'final))
           '()
           (filter-map
            (lambda (row)
              (let* ((good (assq-ref row 'link)) (y (assq-ref row 'plan))
                     (q (and (string? good) (real? y) (quantise (abs y) quantum))))
                (and q (> q 0)
                     `((id . ,(string-join (list "cross" good aid day) "|"))
                       (good . ,good)
                       (provider . ,(if (> y 0) aid federation-aid))
                       (receiver . ,(if (> y 0) federation-aid aid))
                       (qty . ,(exact->inexact q))))))
            (or (assq-ref att 'links) '())))))
   attested))

(define (legs-of-party legs who)
  "(values given received): the legs WHO provides and the legs WHO receives."
  (values (filter (lambda (l) (equal? (leg-provider l) who)) legs)
          (filter (lambda (l) (equal? (leg-receiver l) who)) legs)))
