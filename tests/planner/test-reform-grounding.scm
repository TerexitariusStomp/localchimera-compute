;;; test-reform-grounding.scm — (L,I,D) derived from real ValueFlows recipes.
;;;
;;; The reform layer's L/I/D are no longer hand-typed atom sets: each legal aspect
;;; is a <process-specification>, a recipe PERFORMS an aspect via process-conforms-
;;; to, and L = the law's required aspects, I = our actual recipe's aspects, D =
;;; our desired recipe's aspects. Duress (transform = L−D) falls out — the old
;;; *reform-duress* table is gone. A fourth region appears: (L−D)∩I, the duress we
;;; reproduce-without-wanting. This test pins the derivation, the regression
;;; (derived output equals the old authored output), and the new region.
;;;
;;; Run (bare guile, no libsodium):
;;;   guile -L module/playnet/planner tests/planner/test-reform-grounding.scm

(add-to-load-path (string-append (getcwd) "/module/playnet/planner"))
(add-to-load-path (string-append (getcwd) "/module"))
(define here (string-append (getcwd) "/module/playnet/planner"))
(define (rel p) (string-append here "/" p))
;; schemas is a module now, so import it — `load` would define the module and
;; leave this file's namespace without the records. The fragments below stay
;; `load`ed: they still define into whoever loads them.
(use-modules (playnet planner vf schemas))
(use-modules (playnet planner legal crossings))   ; free-food-distribution + activities register their own
(use-modules (playnet planner facts places))   ; …and the nations they register into
(use-modules (playnet planner legal registry))
(use-modules (playnet planner legal reform))
(use-modules (playnet planner knowledge law aspects))
(use-modules (playnet planner knowledge catalogues us-states-fips))
(use-modules (playnet planner knowledge law context-pack))  ; the jurisdiction packs it reads off disk
(use-modules (playnet planner knowledge worlds free-food-distribution))
(use-modules (playnet planner knowledge law activities))
(use-modules (playnet planner knowledge law reform-mirrors))
(use-modules (playnet planner knowledge law structural-demands))
(use-modules (srfi srfi-1) (ice-9 format))

(define *pass* 0) (define *fail* 0)
(define (ok? name c) (if c (begin (set! *pass* (+ *pass* 1)) (format #t "  ok   ~a~%" name))
                         (begin (set! *fail* (+ *fail* 1)) (format #t "  FAIL ~a~%" name))))
(define (set= a b) (and (null? (lset-difference eq? a b)) (null? (lset-difference eq? b a))))

;; ─────────────────────────────────────────────────────────────────────────
;; 1. aspects are real ProcessSpecifications; recipe-aspects reads them off
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── 1. aspects = ProcessSpecifications, derived off recipes ──\n")
(ok? "every legal aspect is a <process-specification>"
     (every process-specification? *legal-aspects*))
(ok? "an inspection aspect is a control-point (handwashing)"
     (process-specification-is-control-point
      (find (lambda (a) (equal? (process-specification-id a) "handwashing")) *legal-aspects*)))
(ok? "the desired recipe performs the genuine core (handwashing) "
     (memq 'handwashing *desired-aspects*))
(ok? "the desired recipe OMITS the shell (no plan-review / restroom-access)"
     (and (not (memq 'plan-review *desired-aspects*))
          (not (memq 'restroom-access *desired-aspects*))))

;; ─────────────────────────────────────────────────────────────────────────
;; 2. regression: derived transform == the old *reform-duress* output
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── 2. derived transform reproduces the old duress ──\n")
(define (mirror-of name spec rides)
  (demand->mirror (obtain #:rides rides #:name name #:spec spec)))
(define (regions name spec)
  (let ((e (reform-entry (mirror-of name spec 'entity))))
    (list (assq-ref e 'redundant) (assq-ref e 'absorb-first)
          (assq-ref e 'reproduce-unwanted) (assq-ref e 'transform-law))))
(let ((r (regions "Food Service Establishment permit" '(plan-review handwashing temperature-control))))
  (ok? "NYC FSE: transform = (plan-review)" (set= (list-ref r 3) '(plan-review)))
  (ok? "NYC FSE: redundant = (handwashing temperature-control)"
       (set= (list-ref r 0) '(handwashing temperature-control))))
(let ((r (regions "Outdoor Food Distribution permit" '(restroom-access site-approval sanitation))))
  ;; the shell is still the two clauses, now split by what the federation DOES:
  ;; a member's consented-site pathway performs the site approval (borne under
  ;; duress); nobody provides a restroom on demand (rejected outright).
  (ok? "FL Outdoor: the shell = (restroom-access site-approval), borne or rejected"
       (set= (append (list-ref r 2) (list-ref r 3)) '(restroom-access site-approval)))
  (ok? "FL Outdoor: site-approval is borne — a running pathway performs it"
       (set= (list-ref r 2) '(site-approval)))
  (ok? "FL Outdoor: redundant = (sanitation)" (set= (list-ref r 0) '(sanitation))))
(let ((r (regions "Building permit + occupancy certificate" '(building-code fire-safety habitability))))
  (ok? "Building permit (no duress): transform = ()" (null? (list-ref r 3)))
  ;; no member runs a housing way, so the wanted functions are all still to build
  (ok? "Building permit: wanted = all three, provided or to build"
       (set= (append (list-ref r 0) (list-ref r 1)) '(building-code fire-safety habitability)))
  (ok? "Building permit: what no running way performs is to build"
       (every (lambda (c) (not (practised? c))) (list-ref r 1))))

;; ─────────────────────────────────────────────────────────────────────────
;; 3. the NEW region: (L−D)∩I = reproduce-without-wanting
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── 3. reproduce-without-wanting surfaces when we comply ──\n")
;; an ACTUAL recipe that performs a shell aspect (plan-review) we don't desire.
(define complied (grounded-mirror "Complied permit" #:kind 'permit
                   #:incumbent '(plan-review handwashing)
                   #:actual    '(plan-review handwashing)     ; we DO plan-review (under duress)
                   #:desired   '(handwashing)))               ; but don't WANT it
(let ((e (reform-entry complied)))
  ;; the regions are DISJOINT (2×2 of do?×want?): a duress we DO lands in
  ;; reproduce-unwanted (bear), NOT transform (reject) — transform is the pure
  ;; ¬do·¬want corner. So here transform is empty and plan-review is "bear".
  (ok? "transform (reject) = () — the duress we DO is not pure-reject"
       (null? (assq-ref e 'transform-law)))
  (ok? "reproduce-unwanted = (plan-review) (we DO it but don't want it → bear)"
       (set= (assq-ref e 'reproduce-unwanted) '(plan-review)))
  (ok? "redundant = (handwashing) (do · want · law)"
       (set= (assq-ref e 'redundant) '(handwashing))))
;; the standard regulatory case has an EMPTY reproduce-unwanted (we resist)
(let ((e (reform-entry (mirror-of "Food Service Establishment permit"
                                  '(plan-review handwashing temperature-control) 'entity))))
  (ok? "standard FSE: reproduce-unwanted = () (the federation resists the shell)"
       (null? (assq-ref e 'reproduce-unwanted))))

;; ─────────────────────────────────────────────────────────────────────────
;; 4. structural tier: abolitions' regions derive from their three recipes
;; ─────────────────────────────────────────────────────────────────────────
(display "\n── 4. structural abolitions grounded in incumbent/actual/desired ──\n")
(define (abolition name)
  (let ((d (find (lambda (x) (equal? (assq-ref x 'name) name)) *structural-demands*)))
    (reform-entry (assq-ref d 'mirror))))
(let ((e (abolition "Retire rent")))
  (ok? "Retire rent: redundant = (maintain coordinate-tenancy)"
       (set= (assq-ref e 'redundant) '(maintain coordinate-tenancy)))
  (ok? "Retire rent: absorb-first = (house-access) — want it, don't do it yet"
       (set= (assq-ref e 'absorb-first) '(house-access)))
  (ok? "Retire rent: transform = (extract-rent gate-by-payment evict) — the shell"
       (set= (assq-ref e 'transform-law) '(extract-rent gate-by-payment evict))))

(format #t "~%==== reform-grounding: ~a passed, ~a failed ====~%" *pass* *fail*)
(when (> *fail* 0) (exit 1))
