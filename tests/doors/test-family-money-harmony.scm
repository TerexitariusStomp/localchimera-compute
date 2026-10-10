;;; test-family-money-harmony.scm — a family spreads a scarce purse across its
;;; members' needs by harmony, each need entering as its KIND.
;;;
;;; (playnet doors family solve): four people — Alice, Bob, Christine, Dennis — and the
;;; household they share state a week of needs as they ARE, each with a kind
;;; (floor | held | des) and an attached voice — the row's total tension mass.
;;; The purse is a finite stock of euros; income is the household's own Pfand
;;; run, living pinned to one week.
;;;
;;;   (1) a purse below the floors has NO plan — the solve says so rather than
;;;       shaving a right;
;;;   (2) a scarce purse (€250 over a €593 ask) meets every floor in full,
;;;       meets every held need PARTLY and none at zero, and sets every want
;;;       aside — the kind decides who can be zeroed;
;;;   (3) among the held needs and among the wants the voice decides the
;;;       order: satisfaction is monotone in voice within a kind;
;;;   (4) the uniform run (every attachment read as one voice) keeps the
;;;       kinds: floors whole, held never zero, the wants spread rather than
;;;       ordered;
;;;   (5) an ample purse meets everyone, and the purse is never exceeded:
;;;       spent ≤ purse + Pfand income in every feasible run.
;;;
;;; Run:  guile --no-auto-compile -L module tests/doors/test-family-money-harmony.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format))
(use-modules (playnet doors family solve))


(define NEEDS %family-demo-needs)
(define ASK (fold + 0.0 (map (lambda (n) (* (need-cost n) (need-want n))) NEEDS)))
(define FLOORS (need-total-by-kind NEEDS 'floor))

(define (rows r) (assq-ref r 'needs))
(define (of-kind r k) (filter (lambda (row) (eq? (assq-ref row 'kind) k)) (rows r)))
(define (met row) (assq-ref row 'met))
(define (budget-ok? r) (<= (assq-ref r 'spent) (+ (assq-ref r 'purse) (assq-ref r 'income) 0.5)))
;; more PULL ⇒ not less met (5% slack). Pull is mass per euro asked — the
;; doc's own derivation (family-budget.typ §The sacrifice spreads): at the
;; optimum every need trades where (1/c)·∂T/∂s = −μ, so the fraction met
;; rises with w/(c·q). Mass, not voice: a voice is a share of its own
;; person's hand (solve/emphasis.scm), compared across people only once scaled.
(define (pull row) (/ (assq-ref row 'mass) (* (assq-ref row 'cost) (assq-ref row 'want))))
(define (monotone-in-pull? rs)
  (every (lambda (a) (every (lambda (b) (or (<= (pull a) (pull b))
                                            (>= (met a) (- (met b) 0.05)))) rs)) rs))
(define (show title r)
  (format #t "~%  ~a — feasible ~a, spent €~,2f of €~,2f + Pfand €~,2f~%" title (assq-ref r 'feasible?)
          (assq-ref r 'spent) (assq-ref r 'purse) (assq-ref r 'income))
  (for-each (lambda (row) (format #t "    ~6a ~16a ~5a v ~4a m ~6,1f  ~5,2f / ~a  (~3d%)~%"
                                  (assq-ref row 'person) (assq-ref row 'what) (assq-ref row 'kind)
                                  (assq-ref row 'voice) (assq-ref row 'mass)
                                  (assq-ref row 'got) (assq-ref row 'want) (inexact->exact (round (* 100 (met row))))))
            (rows r)))

(format #t "~%=== Family purse by kind: ask €~,2f, floors €~,2f ===~%" ASK FLOORS)

;; (1) below the floors: no plan — but best-effort shows the purse's best use
(let* ((r (family-split NEEDS 100))
       (be (assq-ref r 'best-effort)))
  (check "€100 < floors → no plan (feasible? #f)" (not (assq-ref r 'feasible?)))
  (check "no plan → nothing bought" (< (assq-ref r 'spent) 0.01))
  (check "best-effort is present and itself feasible" (and be (assq-ref be 'feasible?)))
  (check "best-effort spends close to the purse (+Pfand)" (budget-ok? be))
  ;; a demoted floor reads 'held in best-effort's own rows (demote-floors
  ;; relabels it before the re-solve), so match back to NEEDS by (person . what)
  (define (row-of rs person what)
    (find (lambda (r) (and (equal? (assq-ref r 'person) person) (equal? (assq-ref r 'what) what))) rs))
  (check "best-effort still leaves a demoted floor short (they are the whole problem)"
         (any (lambda (n) (and (eq? (need-kind n) 'floor)
                               (< (met (row-of (rows be) (need-person n) (need-what n))) 0.99)))
              NEEDS)))

;; below the floors on the SAME needs, a floor-free ledger has no best-effort
;; to offer (nothing to demote) — but it is also never infeasible from a
;; missing floor, so this only exercises the guard, not the ordinary path.
(let ((r (family-split (filter (lambda (n) (not (eq? (need-kind n) 'floor))) NEEDS) 1)))
  (check "no-floor ledger's best-effort is absent even if scarce"
         (or (assq-ref r 'feasible?) (not (assq-ref r 'best-effort)))))

;; (2)+(3) scarce, weighted
(let ((r (family-split NEEDS 250)))
  (show "€250, weighted" r)
  (check "€250 → a plan" (assq-ref r 'feasible?))
  (check "floors met in full" (every (lambda (row) (> (met row) 0.99)) (of-kind r 'floor)))
  (check "held needs all partly met (> 25%)" (every (lambda (row) (> (met row) 0.25)) (of-kind r 'held)))
  (check "held needs none in full (< 95%)" (every (lambda (row) (< (met row) 0.95)) (of-kind r 'held)))
  (check "every want set aside (< 5%)" (every (lambda (row) (< (met row) 0.05)) (of-kind r 'des)))
  (check "held: monotone in pull (mass per euro asked)" (monotone-in-pull? (of-kind r 'held)))
  (check "purse respected" (budget-ok? r)))

;; (3) less scarce: wants come in by voice, needs nearly whole
(let ((r (family-split NEEDS 400)))
  (show "€400, weighted" r)
  (check "€400 → held needs nearly whole (> 85%)" (every (lambda (row) (> (met row) 0.85)) (of-kind r 'held)))
  (check "€400 → some wants met, the one-voice ones not"
         (and (any (lambda (row) (> (met row) 0.3)) (of-kind r 'des))
              (every (lambda (row) (< (met row) 0.05))
                     (filter (lambda (row) (= 1 (assq-ref row 'voice))) (of-kind r 'des)))))
  ;; among wants the voice orders the split up to the FRACTIONAL-GAP pricing:
  ;; a €10 single item at 10 voice buys its fraction cheaper than five €5
  ;; lunches at 22, so neighbouring rungs can cross. The coarse claim holds:
  ;; the loudest want (swimming, 100) beats every want at 10 voice or less —
  ;; an order of magnitude down the ladder.
  (check "wants: the loudest beats every want an order of magnitude quieter"
         (let ((top (find (lambda (row) (= 100 (assq-ref row 'voice))) (of-kind r 'des))))
           (every (lambda (row) (> (met top) (met row)))
                  (filter (lambda (row) (<= (assq-ref row 'voice) 10)) (of-kind r 'des)))))
  (check "purse respected" (budget-ok? r)))

;; (4) uniform: kinds hold, order among wants dissolves
(let ((r (family-split NEEDS 400 #:weighted? #f)))
  (show "€400, uniform" r)
  (check "uniform → floors met in full" (every (lambda (row) (> (met row) 0.99)) (of-kind r 'floor)))
  (check "uniform → held never zero (> 25%)" (every (lambda (row) (> (met row) 0.25)) (of-kind r 'held)))
  (check "uniform → the one-voice wants now get something (> 10%)"
         (every (lambda (row) (> (met row) 0.1))
                (filter (lambda (row) (= 1 (assq-ref row 'voice))) (of-kind r 'des))))
  (check "purse respected" (budget-ok? r)))

;; (5) ample
(let ((r (family-split NEEDS 1000)))
  (check "€1000 → everyone met (all ≥ 95%)" (every (lambda (row) (> (met row) 0.95)) (rows r)))
  (check "purse respected" (budget-ok? r)))

;; (6) the externality display: what each held/des ask moved from the others —
;;     leave-one-out re-solves of the same split. Floors are never priced; an
;;     ask that received nothing moved nothing; a big held ask moved real euros;
;;     by convexity a withdrawn ask can only free resources (moved >= -noise).
(let ((r (family-externalities NEEDS 250)))
  (check "externalities computed on a feasible purse" (assq-ref r 'feasible?))
  (let ((rws (assq-ref r 'rows)))
    (format #t "~%  externalities at 250, per ask (moved to others):~%")
    (for-each (lambda (row) (format #t "    ~10a ~16a ~5a v ~a  moved ~7,2f~%"
                                    (assq-ref row 'person) (assq-ref row 'what)
                                    (assq-ref row 'kind) (assq-ref row 'voice) (assq-ref row 'moved)))
              rws)
    (check "floors are not priced"
           (not (any (lambda (row) (eq? (assq-ref row 'kind) 'floor)) rws)))
    (check "every held/des row is priced"
           (= (length rws) (count (lambda (n) (memq (need-kind n) (quote (held des)))) NEEDS)))
    (check "no ask moved a negative amount (convexity, 0.5 noise)"
           (every (lambda (row) (> (assq-ref row 'moved) -0.5)) rws))
    (check "a want that received nothing moved nothing (videogame)"
           (every (lambda (row) (< (abs (assq-ref row 'moved)) 0.5))
                  (filter (lambda (row) (equal? (assq-ref row 'what) "videogame")) rws)))
    (check "a big held ask moved real euros (physio > 5)"
           (> (assq-ref (find (lambda (row) (equal? (assq-ref row 'what) "physio")) rws) 'moved) 5.0)))
  (let ((ps (assq-ref r 'persons)))
    (check "each declaring person is totalled" (= (length ps) 5))
    (check "dennis's asks moved real euros to the others"
           (> (assq-ref (find (lambda (pr) (equal? (assq-ref pr 'person) "dennis")) ps) 'moved) 5.0))))

;; below the floors there is nothing to price
(let ((r (family-externalities NEEDS 100)))
  (check "no plan -> no externalities (feasible? #f, empty rows)"
         (and (not (assq-ref r 'feasible?)) (null? (assq-ref r 'rows)))))

;; (7) the household is a scope like any other: MEMBERS lets consumer voice
;;     differentiate (playnet.typ §The credit identity) instead of reading
;;     flat. Two rows, identical in everything but their owner, so the
;;     owner's own simplex-share (each has exactly one need — their whole
;;     hand) cannot confound the comparison: any mass gap is family-voice-of
;;     alone. Undeclared MEMBERS keeps the historic equal split; declaring a
;;     contributing adult and a non-contributing, lower-capacity child (the
;;     spec's own example, §Governance: "Everyone — workers, children, the
;;     elderly, the unable — carries weight") tilts the mass toward the
;;     adult while the child's own mass, and their own need, stay real.
(let* ((~=       (lambda (a b) (< (abs (- a b)) 1e-6)))
       (synth    (list (list "adult" "gadget" 10.0 1.0 50 'held)
                       (list "child" "toy"    10.0 1.0 50 'held)))
       (members  (list (list "adult" 1.0 20.0) (list "child" 0.15 0.0)))
       (flat     (family-split synth 8))
       (diff     (family-split synth 8 #:members members))
       (mass-of  (lambda (res person)
                   (assq-ref (find (lambda (row) (equal? (assq-ref row 'person) person)) (rows res)) 'mass)))
       (met-of   (lambda (res person)
                   (met (find (lambda (row) (equal? (assq-ref row 'person) person)) (rows res))))))
  (check "undeclared members: two identical rows split the mass equally"
         (~= (mass-of flat "adult") (mass-of flat "child")))
  (check "declared members: the contributing adult now outweighs the non-contributing child"
         (> (mass-of diff "adult") (mass-of diff "child")))
  (check "…and the child's mass stays strictly positive — solidarity + citizenship, never zero"
         (> (mass-of diff "child") 0))
  (check "the child's own need is still served, not zeroed by their own low capacity"
         (> (met-of diff "child") 0)))

(test-summary!)
