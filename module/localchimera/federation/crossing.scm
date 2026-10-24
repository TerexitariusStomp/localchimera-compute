;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/crossing.scm — the master's side of one good, as arithmetic.
;;;
;;; A good has one MASTER among the scopes that share it. It holds the good's
;;; state — an EXCHANGE of one good (solve/admm-link.scm): each participant's signed
;;; agreed flow and the one pull — with its penalty weight ρ, a VERSION that
;;; counts the centres published, and for every participant (itself first) a
;;; MEMBER: who it is, the centre last published to it, the flow last heard
;;; from it and the version that flow answered, its refined flow, and the flow
;;; it is held to. Every flow is signed: above nothing the member supplies the
;;; good, below it draws, and which it does is what its solve answered.
;;;
;;; This module is what the master DOES with that state, and nothing about how
;;; messages travel (federation/async.scm): the step on the members' flows
;;; (exchange-step!, damped and accelerated by the same accelerator the rounds
;;; use), the balancing of ρ against the residuals (rho-balance), deciding
;;; whether the next version is worth publishing, and sharing what is
;;; supplied among those that draw once every member has refined. Each
;;; procedure mutates the crossing it is handed and answers what happened.
;;;
;;; The knobs are one TUNING (`make-tuning`), the same for every good of a peer.

(define-module (localchimera federation crossing)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (localchimera solve admm-link)
  #:export (make-tuning
            member-name member-pub
            member-y set-member-y! member-tag set-member-tag!
            member-refd set-member-refd! member-cap
            make-crossing crossing-link crossing-rho crossing-v crossing-members
            crossing-stepped crossing-residual crossing-since set-crossing-since!
            crossing-self crossing-others crossing-member crossing-pending? crossing-quiet?
            crossing-agreed crossing-pull crossing-centre
            crossing-advance! crossing-publish! crossing-allocate!
            crossing-snapshot crossing-restore! *flow-form*))

;; ── the knobs ────────────────────────────────────────────────────────────────
;; ALPHA the over-relaxation (1 = plain ADMM); DAMPING η ∈ (0,1] the fraction of
;; each step taken; ACCEL, with history MMAX, Anderson acceleration of the
;; crossing's own iterates; ADAPT whether ρ is rescaled by 2 when one residual
;; exceeds ADAPT-RATIO times the other, at most ADAPT-MAX times; EPS the centre
;; movement below which nothing is published; TOL the flow disagreement taken
;; as agreement; CALM how many steps in a row must agree before publication
;; stops.
(define-record-type <tuning>
  (make-tuning alpha damping accel mmax adapt adapt-ratio adapt-max eps tol calm)
  tuning?
  (alpha tuning-alpha) (damping tuning-damping) (accel tuning-accel) (mmax tuning-mmax)
  (adapt tuning-adapt) (adapt-ratio tuning-adapt-ratio) (adapt-max tuning-adapt-max)
  (eps tuning-eps) (tol tuning-tol) (calm tuning-calm))

;; ── the records ──────────────────────────────────────────────────────────────
;; THE FORM every flow here is spoken in — in a message, in a snapshot: `signed`,
;; a participant's flow on a good with its direction, above nothing supplied and
;; below it drawn. What is kept and what is sent says its form, so a number
;; written under another reading is set aside and never read as this one.
(define *flow-form* 'signed)

(define-record-type <member>
  (make-member name pub y tag refd cap)
  member?
  (name member-name)
  (pub member-pub set-member-pub!)            ; the centre last published to it
  (y member-y set-member-y!)                  ; its flow as last heard
  (tag member-tag set-member-tag!)            ; the version y answers; -1 before it has spoken
  (refd member-refd set-member-refd!)         ; (flow . version), or #f
  (cap member-cap set-member-cap!))           ; the flow it is held to, or #f until every member has refined

(define-record-type <crossing>
  (make-crossing* link v members ex acc stepped residual since calm adapts lean)
  crossing?
  (link crossing-link)
  (v crossing-v set-crossing-v!)                  ; the version of the published centres
  (members crossing-members)
  (ex crossing-ex)                              ; the exchange of this one good
  (acc crossing-acc)                            ; its accelerator
  (stepped crossing-stepped set-crossing-stepped!) ; the flows last stepped on
  (residual crossing-residual set-crossing-residual!) ; Σ y: what the crossing is out of balance
  (since crossing-since set-crossing-since!)      ; when the current version was published
  (calm crossing-calm set-crossing-calm!)         ; steps in a row that ended in agreement
  (adapts crossing-adapts set-crossing-adapts!)   ; how many times ρ has been rescaled
  (lean crossing-lean set-crossing-lean!))        ; (factor . steps): which way the residuals have leaned, and for how long

(define (make-crossing link rho v names z0 t)
  "The good LINK among NAMES, mastered by the first of them; Z0 the signed
   flows to start it at, one per name and summing to nothing, or #f for no
   flow; T the tuning. Every member has yet to speak."
  (let* ((ex (make-exchange (list (cons link (length names))) (if z0 (list (cons link z0)) '()) #:rho rho))
         (members (map (lambda (name pos)
                         (make-member name (exchange-centre ex link pos) 0.0 -1 #f #f))
                       names (iota (length names)))))
    (make-crossing* link v members ex
                  (make-exchange-accelerator ex #:mmax (tuning-mmax t) #:on (tuning-accel t))
                  #f 0.0 0.0 0 0 (cons #f 0))))

(define (crossing-rho m) (exchange-rho (crossing-ex m)))
(define (crossing-self m) (car (crossing-members m)))
(define (crossing-others m) (cdr (crossing-members m)))
(define (crossing-member m from)                ; the other participant named FROM
  (find (lambda (p) (equal? (member-name p) from)) (crossing-others m)))
(define (position m p) (list-index (lambda (q) (eq? q p)) (crossing-members m)))
(define (crossing-agreed m p)                     ; the signed flow agreed for P
  (exchange-flow (crossing-ex m) (crossing-link m) (position m p)))
(define (crossing-centre m p)                   ; what P solves against
  (exchange-centre (crossing-ex m) (crossing-link m) (position m p)))
(define (crossing-pull m)                      ; the good's pull, ρ·u: one number for every member
  (exchange-pull (crossing-ex m) (crossing-link m)))
(define (crossing-pending? m)                   ; some member has not answered the current version
  (any (lambda (p) (not (= (member-tag p) (crossing-v m)))) (crossing-members m)))
(define (crossing-quiet? m t)                   ; every flow answered, stepped on, and in balance
  (and (not (crossing-pending? m))
       (equal? (crossing-stepped m) (map member-y (crossing-members m)))
       (<= (abs (crossing-residual m)) (* 10.0 (tuning-tol t)))))

;; ── the step ─────────────────────────────────────────────────────────────────
(define (crossing-advance! m t)
  "The master's step, when every member's flow answers the current version and
   is not the set it last stepped on: the exchange's step, accelerated, and ρ
   balanced against the residuals. → `idle` (nothing to step), `stepped`, or
   `rescaled` (stepped, and ρ moved)."
  (let* ((ps (crossing-members m)) (ys (map member-y ps)) (ex (crossing-ex m)) (k (crossing-link m)))
    (if (or (crossing-pending? m) (equal? (crossing-stepped m) ys))
        'idle
        (let ((zs0 (map (lambda (p) (crossing-agreed m p)) ps)))
          ((crossing-acc m) 'begin!)
          (call-with-values (lambda () (exchange-step! ex k ys (tuning-alpha t) #:damping (tuning-damping t)))
            (lambda (imbalance prim dual)
              ((crossing-acc m) 'end!)
              (set-crossing-stepped! m ys)
              (set-crossing-residual! m imbalance)
              (let* ((moved (apply max (map (lambda (p z) (abs (- (crossing-agreed m p) z))) ps zs0)))
                     ;; the residual-balancing rule reads a PERSISTENT imbalance: one step
                     ;; out of balance — a member back from an outage, a fresh version —
                     ;; is a transient, and rescaling on it pins the flows to z so hard
                     ;; that an abundant good's pull is no longer read off them
                     (way (and (tuning-adapt t)
                               (> (max prim dual) (tuning-tol t))
                               (rho-balance prim dual #:ratio (tuning-adapt-ratio t))))
                     (lean (if (and way (eqv? way (car (crossing-lean m))))
                               (cons way (+ 1 (cdr (crossing-lean m))))
                               (cons way (if way 1 0))))
                     (factor (and way (>= (cdr lean) 2)
                                  (< (crossing-adapts m) (tuning-adapt-max t))
                                  way)))
                (set-crossing-lean! m (if factor (cons #f 0) lean))
                (set-crossing-calm! m (if (and (<= (abs imbalance) (tuning-tol t)) (<= moved (tuning-tol t)))
                                        (+ 1 (crossing-calm m))
                                        0))
                ;; the iterate has changed scale, so the acceleration starts over
                (when factor
                  (exchange-rescale! ex factor)
                  (set-crossing-adapts! m (+ 1 (crossing-adapts m)))
                  ((crossing-acc m) 'reset!))
                (if factor 'rescaled 'stepped))))))))

(define (crossing-publish! m t now rescaled)
  "Publish the next version if the centres have moved (or ρ has) and the
   crossing is not yet calm. → #t when a new version stands, its centres in the members'
   `pub`, and what was refined or capped under the old one forgotten."
  (let* ((ps (crossing-members m))
         (pub* (map (lambda (p) (crossing-centre m p)) ps)))
    (and (< (crossing-calm m) (tuning-calm t))
         (or rescaled
             (> (apply max (map (lambda (p c) (abs (- c (member-pub p)))) ps pub*)) (tuning-eps t)))
         (begin
           (set-crossing-v! m (+ 1 (crossing-v m)))
           (set-crossing-since! m now)
           (for-each (lambda (p c) (set-member-pub! p c) (set-member-refd! p #f) (set-member-cap! p #f))
                     ps pub*)
           #t))))

;; ── sharing what is supplied ─────────────────────────────────────────────────
(define (crossing-allocate! m t)
  "Once every member has refined at this version: the flow each is held to.
   Those that supply keep what they refined; those that draw keep theirs, cut
   back pro rata when together they draw more than is supplied. → #f until
   every member has refined, else the members whose cap is new or has moved."
  (let ((ps (crossing-members m)))
    (and (every (lambda (p) (let ((r (member-refd p))) (and r (= (cdr r) (crossing-v m))))) ps)
         (let ((old (map member-cap ps)))
           (for-each set-member-cap! ps (allocate-caps (map (lambda (p) (car (member-refd p))) ps)))
           (filter-map (lambda (p o)
                         (and (or (not o) (> (abs (- (member-cap p) o)) (tuning-eps t))) p))
                       ps old)))))

;; ── what a master keeps across a restart ─────────────────────────────────────
(define (crossing-snapshot m)
  "The good's state as atoms, what `crossing-restore!` takes it back from: the
   form its flows are spoken in and its members' names, then the version, the
   flows last stepped on, the residual, when the version was published, the
   calm, ρ and its rescalings, the exchange's flows and dual, each member's
   centre, flow, tag, refined flow and cap, and the leaps the accelerator has
   taken. The accelerator's history stays out: acceleration starts over on a
   restart, with the leaps it has left."
  (let ((ex (crossing-ex m)))
    (list *flow-form* (map member-name (crossing-members m))
          (crossing-v m) (crossing-stepped m) (crossing-residual m) (crossing-since m)
          (crossing-calm m) (crossing-adapts m) (crossing-lean m)
          (exchange-rho ex) (vector->list (exchange->vector ex))
          (map (lambda (p) (list (member-pub p) (member-y p) (member-tag p) (member-refd p) (member-cap p)))
               (crossing-members m))
          ((crossing-acc m) 'leaps))))

(define (crossing-restore! m s)
  "M as it stood when S (`crossing-snapshot`) was taken. → M, or #f — M left as
   it was made — when S speaks its flows in another form or names other
   members than M has: a good whose participants have changed begins again."
  (and (pair? s) (eq? (car s) *flow-form*)
       (equal? (cadr s) (map member-name (crossing-members m)))
       (apply (lambda* (v stepped residual since calm adapts lean rho vec mems #:optional (leaps 0))
                (let ((ex (crossing-ex m)))
                  ((crossing-acc m) 'leaps! leaps)
                  (set-crossing-v! m v) (set-crossing-stepped! m stepped) (set-crossing-residual! m residual)
                  (set-crossing-since! m since) (set-crossing-calm! m calm) (set-crossing-adapts! m adapts)
                  (set-crossing-lean! m lean)
                  (exchange-rescale! ex (/ rho (exchange-rho ex)))
                  (exchange-load! ex (list->vector vec))
                  (for-each (lambda (p e)
                              (apply (lambda (pub y tag refd cap)
                                       (set-member-pub! p pub) (set-member-y! p y) (set-member-tag! p tag)
                                       (set-member-refd! p refd) (set-member-cap! p cap))
                                     e))
                            (crossing-members m) mems)
                  m))
              (cddr s))))
