;;; nac.scm --- Network of Apprenticeship & Craft (NAC) agent/world layer
;;;
;;; SPECIFICATION
;;; =============
;;; Source: docs/evr/NAC_sepv2.nlogo (a.k.a. NAC_sepv2.html, identical body).
;;;
;;; This module hosts the parts of the NetLogo prototype that are *not*
;;; pure scoring math: the member and review-link records, the one-tick
;;; link memory, the spatial pull used for the social-clustering layout,
;;; the per-opportunity participation counter, and the setup-time
;;; initialiser. The scoring math itself stays in (docs evr algorithms
;;; culcus).
;;;
;;; --- Member initialisation (NetLogo `setup`) ----------------------------
;;;   local-public-rep    = 50 + uniform-int(0, starting-rep-variation)
;;;   culcus              = 50
;;;   bad-actor?          = (uniform(0,1) < 0.2)         ; vestigial — see note
;;;   true-aptitude       ~ N(50, starting-aptitude-variation)
;;;   true-disposition    ~ N(50, starting-disp-variation)
;;;   reviewed-aptitude   = 50
;;;   reviewed-disposition= 50
;;;   opportunity-count   = 0
;;;
;;; Note on `bad-actor?`: the NetLogo source sets this on ~20% of agents
;;; at setup but never reads it elsewhere. We retain the field for
;;; faithful conformance and future use, with the caveat that it has no
;;; current dynamical effect.
;;;
;;; --- Review-link aging (NetLogo `decay-links`) --------------------------
;;;   age'  = age + 1
;;;   alive = age' ≤ 1     ; one-tick memory: a link survives the tick it
;;;                          ; is created on, and dies on the next.
;;; Returns #f when the link should be removed.
;;;
;;; --- Spatial pull (NetLogo `pull-toward-review-partners`) --------------
;;;   pull   = (d-score − 50) / 50            ; ∈ [−1, +1]
;;;   if pull > 0:
;;;     pos' = pos + (target − pos) · 0.03 · pull
;;;   else:
;;;     pos' = pos                             ; negative pull is a no-op
;;; Sources are pulled toward targets they reviewed positively on
;;; disposition; the link is iterated as `(source, target)` pairs.
;;;
;;; --- Opportunity-count update (NetLogo `simulate-opportunity` tail) ----
;;;   for every member in `participants`: opportunity-count += 1.

(define-module (docs evr algorithms nac)
  #:use-module (srfi srfi-9)
  #:use-module ((docs evr algorithms culcus) #:prefix culcus:)
  #:export (make-member member?
            member-rep         set-member-rep
            member-culcus      set-member-culcus
            member-bad-actor?
            member-true-aptitude     set-member-true-aptitude
            member-true-disposition  set-member-true-disposition
            member-reviewed-aptitude    set-member-reviewed-aptitude
            member-reviewed-disposition set-member-reviewed-disposition
            member-opportunity-count    increment-opportunity-count

            initial-member

            make-review-link review-link?
            review-link-source review-link-target
            review-link-aptitude-score review-link-disposition-score
            review-link-age age-link

            pull-step))

;;; ---------------------------------------------------------------------
;;; Member record
;;; ---------------------------------------------------------------------

(define-record-type <member>
  (%make-member rep culcus bad-actor?
                true-aptitude true-disposition
                reviewed-aptitude reviewed-disposition
                opportunity-count)
  member?
  (rep                  member-rep                  set-member-rep!)
  (culcus               member-culcus               set-member-culcus!)
  (bad-actor?           member-bad-actor?)
  (true-aptitude        member-true-aptitude        set-member-true-aptitude!)
  (true-disposition     member-true-disposition     set-member-true-disposition!)
  (reviewed-aptitude    member-reviewed-aptitude    set-member-reviewed-aptitude!)
  (reviewed-disposition member-reviewed-disposition set-member-reviewed-disposition!)
  (opportunity-count    member-opportunity-count    set-member-opportunity-count!))

(define make-member %make-member)

;; Functional aliases — return a fresh record with one field replaced.
;; Cheaper to read in tests than mutation; the simulator may use either.
(define (set-member-rep m v)
  (%make-member v (member-culcus m) (member-bad-actor? m)
                (member-true-aptitude m) (member-true-disposition m)
                (member-reviewed-aptitude m) (member-reviewed-disposition m)
                (member-opportunity-count m)))
(define (set-member-culcus m v)
  (%make-member (member-rep m) v (member-bad-actor? m)
                (member-true-aptitude m) (member-true-disposition m)
                (member-reviewed-aptitude m) (member-reviewed-disposition m)
                (member-opportunity-count m)))
(define (set-member-true-aptitude m v)
  (%make-member (member-rep m) (member-culcus m) (member-bad-actor? m)
                v (member-true-disposition m)
                (member-reviewed-aptitude m) (member-reviewed-disposition m)
                (member-opportunity-count m)))
(define (set-member-true-disposition m v)
  (%make-member (member-rep m) (member-culcus m) (member-bad-actor? m)
                (member-true-aptitude m) v
                (member-reviewed-aptitude m) (member-reviewed-disposition m)
                (member-opportunity-count m)))
(define (set-member-reviewed-aptitude m v)
  (%make-member (member-rep m) (member-culcus m) (member-bad-actor? m)
                (member-true-aptitude m) (member-true-disposition m)
                v (member-reviewed-disposition m)
                (member-opportunity-count m)))
(define (set-member-reviewed-disposition m v)
  (%make-member (member-rep m) (member-culcus m) (member-bad-actor? m)
                (member-true-aptitude m) (member-true-disposition m)
                (member-reviewed-aptitude m) v
                (member-opportunity-count m)))
(define (increment-opportunity-count m)
  (%make-member (member-rep m) (member-culcus m) (member-bad-actor? m)
                (member-true-aptitude m) (member-true-disposition m)
                (member-reviewed-aptitude m) (member-reviewed-disposition m)
                (+ 1 (member-opportunity-count m))))

;;; ---------------------------------------------------------------------
;;; Initial member (mirrors NetLogo `setup`)
;;; ---------------------------------------------------------------------

(define* (initial-member #:key
                         (starting-rep-variation       0)
                         (starting-aptitude-variation  30)
                         (starting-disp-variation      30)
                         (bad-actor-rate               0.2)
                         (uniform-real  (lambda () (error "supply uniform-real")))
                         (uniform-int   (lambda (n)  (error "supply uniform-int")))
                         (gaussian      (lambda (μ σ) (error "supply gaussian"))))
  "Construct a member as NetLogo `setup` would.

Samplers are injected so tests can pin a seed. Defaults match the
NetLogo slider initial values."
  (%make-member (+ 50 (uniform-int starting-rep-variation))   ; rep
                50                                            ; culcus
                (< (uniform-real) bad-actor-rate)             ; bad-actor?
                (gaussian 50 starting-aptitude-variation)     ; true-aptitude
                (gaussian 50 starting-disp-variation)         ; true-disposition
                50                                            ; reviewed-aptitude
                50                                            ; reviewed-disposition
                0))                                           ; opportunity-count

;;; ---------------------------------------------------------------------
;;; Review-link record + aging
;;; ---------------------------------------------------------------------

(define-record-type <review-link>
  (make-review-link source target aptitude-score disposition-score age)
  review-link?
  (source             review-link-source)
  (target             review-link-target)
  (aptitude-score     review-link-aptitude-score)
  (disposition-score  review-link-disposition-score)
  (age                review-link-age))

(define (age-link link)
  "Return LINK with age incremented, or #f if it should die.

Per NetLogo: `set age age + 1; if age > 1 [ die ]`. A link created
this tick has age=0; after `age-link` it becomes age=1 (alive); after
the next call it would be age=2, which is > 1, so we return #f."
  (let ((age* (+ 1 (review-link-age link))))
    (and (<= age* 1)
         (make-review-link (review-link-source link)
                           (review-link-target link)
                           (review-link-aptitude-score link)
                           (review-link-disposition-score link)
                           age*))))

;;; ---------------------------------------------------------------------
;;; Spatial pull
;;; ---------------------------------------------------------------------

(define pull-step-size 0.03)

(define (pull-step source-pos target-pos d-score)
  "Return SOURCE-POS' after one pull step toward TARGET-POS.

Positions are 2-element lists (x y). Negative or zero pull yields no
movement. Per NetLogo `pull-toward-review-partners`."
  (let ((pull (/ (- d-score 50.0) 50.0)))
    (if (<= pull 0)
        source-pos
        (let* ((sx (car  source-pos)) (sy (cadr source-pos))
               (tx (car  target-pos)) (ty (cadr target-pos))
               (k  (* pull-step-size pull)))
          (list (+ sx (* (- tx sx) k))
                (+ sy (* (- ty sy) k)))))))
