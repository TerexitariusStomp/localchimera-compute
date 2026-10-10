;;; reform.scm — the reform program as the diff of legal / internal / desired specs.
;;; @defines reform
;;;
;;; Design: docs/legal/legal-crossings.md §"Dual power — reform as the diff".
;;; Pairs with legal/registry.scm: each binding DEMAND (obtain / pay / tell) is
;;; mirrored by what the federation INTERNALLY verifies (I) and what it DESIRES
;;; (D), beside the LEGAL spec (L). The reform program is the diff over (L,I,D).
;;;
;;; Two regimes, one diff:
;;;   spec-bearing demands (permit / competence licence) carry an inspectable
;;;   standard, so the diff yields THREE regions:
;;;     L∩D∩I  wanted & absorbed   → REDUNDANT-CHECK (demand recognition, withdraw)
;;;     (L∩D)−I wanted, not absorbed→ ABSORB-FIRST   (build the inspection first)
;;;     L−D    unwanted (duress)   → TRANSFORM-LAW   (advocate L→D)
;;;   non-spec demands (levy / disclosure) cannot be self-verified (I is empty),
;;;   so the diff degenerates to TWO regions:
;;;     L∩D    accepted            → KEEP   (we pay / disclose because we accept it)
;;;     L−D    unwanted (duress)   → TRANSFORM-LAW
;;;   existence wrappers (entity / registration) carry no spec — the doorkeeper
;;;   floor, not a reform target.
;;;
;;; The worked example (seven mirrors, one of each kind) is tests/planner/reform-example-mirrors.scm.

;; vf-record-type stays #:select'ed — a type is its name, the same object on
;; both sides of the seam. The legal vocabulary it diffs against is a module now.
(define-module (playnet planner legal reform)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-accessor vf-record-constructor vf-record-predicate vf-record-type))
  #:use-module (playnet planner legal registry)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (%make-spec-mirror
            spec-mirror
            has-spec?
            spec-kind?
            reform-regions
            reform-entry
            reform-move
            move-rank
            reform-program))

;;; ─── SpecMirror : a legal spec beside the federation's internal & desired ─
;;; kind ∈ permit | licence (spec-bearing) | levy | disclosure (non-spec)
;;;        | registration | entity (existence).
;;; legal/internal/desired : SETS of atoms (clauses). legal = '()/#f ⇒ existence.
(define-vf-record <spec-mirror> SpecMirror
  (name kind legal internal desired))
(define %make-spec-mirror (vf-record-constructor <spec-mirror>))
(define* (spec-mirror name #:key (kind 'permit) (legal '()) (internal '())
                      (desired '()))
  (%make-spec-mirror name kind legal internal desired))

(define (has-spec? m) (let ((L (spec-mirror-legal m))) (and (list? L) (pair? L))))
(define (spec-kind? k) (and (memq k '(permit licence)) #t))   ; inspectable standard

;;; ─── the three regions of L = the diff (L, I, D) ─────────────────────────
(define (reform-regions m)
  (let* ((L (or (spec-mirror-legal m) '()))
         (I (or (spec-mirror-internal m) '()))
         (D (or (spec-mirror-desired m) '()))
         (wanted    (lset-intersection eq? L D))
         (redundant (lset-intersection eq? wanted I))   ; wanted & absorbed
         (absorb    (lset-difference   eq? wanted I))    ; wanted, not yet absorbed
         (transform (lset-difference   eq? L D)))         ; unwanted — the duress-gap
    (values redundant absorb transform)))

;;; ─── the move : what the diff says to do ────────────────────────────────
;;; The four cells are categories, not quantities: the clauses are not
;;; commensurable units over a common denominator, so no ratio of them is taken.
;;; What follows from the cells is a MOVE, by a plain reading of which are empty:
;;;
;;;   wither    we provide all we want of it → demand the state's version wither
;;;   absorb    something we want of it is still to build → build it first
;;;   transform only the shell is left (we reject it, or bear it) → press to change it
;;;   keep      nothing to press: we accept it, or it is an existence wrapper
(define (reform-move e)
  (let ((red  (or (assq-ref e 'redundant) '()))
        (abs  (or (assq-ref e 'absorb-first) '()))
        (bear (or (assq-ref e 'reproduce-unwanted) '()))
        (tr   (or (assq-ref e 'transform-law) '())))
    (cond ((and (pair? red) (null? abs)) 'wither)
          ((pair? abs) 'absorb)
          ((or (pair? bear) (pair? tr)) 'transform)
          (else 'keep))))

;;; ─── the per-demand reform entry ─────────────────────────────────────────
(define (reform-entry m)
  (let ((kind (spec-mirror-kind m)))
    (cond
     ((not (has-spec? m))                       ; existence wrapper — not a target
      `((name . ,(spec-mirror-name m)) (kind . ,kind) (stance . interface-floor)))
     ((spec-kind? kind)                         ; permit / licence — three regions
      (call-with-values (lambda () (reform-regions m))
        (lambda (red absorb transform)
          ;; The four regions tile L as a 2×2 of (do? × want?). reform-regions
          ;; returns transform = L−D (do+¬do); split it by I so the regions are
          ;; DISJOINT: reproduce-unwanted = (L−D)∩I (we DO it, don't want it) and
          ;; transform = (L−D)−I (we neither do nor want it). reform-regions keeps
          ;; its 3-value arity (back-compat); the split lives here.
          (let* ((I (or (spec-mirror-internal m) '()))
                 (reproduce-unwanted (lset-intersection eq? transform I))
                 (pure-transform     (lset-difference   eq? transform I)))
            `((name . ,(spec-mirror-name m)) (kind . ,kind)
              (redundant         . ,red)             ; do · want    → wither
              (absorb-first      . ,absorb)          ; ¬do · want   → build
              (reproduce-unwanted . ,reproduce-unwanted) ; do · ¬want → resist (bear)
              (transform-law     . ,pure-transform))))))   ; ¬do · ¬want  → reject
     (else                                      ; levy / disclosure — keep or transform
      (let* ((L (or (spec-mirror-legal m) '()))
             (D (or (spec-mirror-desired m) '()))
             (accept    (lset-intersection eq? L D))
             (transform (lset-difference   eq? L D)))
        `((name . ,(spec-mirror-name m)) (kind . ,kind)
          (accept        . ,accept)
          (transform-law . ,transform)))))))

(define (move-rank e)                   ; the move we can make now leads
  (case (reform-move e) ((wither) 0) ((absorb) 1) ((transform) 2) (else 3)))
(define (reform-program mirrors)
  (sort (map reform-entry mirrors)
        (lambda (a b) (< (move-rank a) (move-rank b)))))
