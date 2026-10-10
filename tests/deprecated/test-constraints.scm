;;; test-constraints.scm — tests for (playnet deprecated kanren-constraints)
;;; Run: guile --no-auto-compile -q -L module tests/test-constraints.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet test harness))
(use-modules (playnet deprecated kanren-constraints)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────
(define ns #f)  ;; no netter for pure logic tests
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Core miniKanren (backward compat with kanren-planning)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Core miniKanren ──\n")

(check "== unifies"
       (run-plan* ns (q) (== q 42))
       '(42))

(check "fresh"
       (run-plan* ns (q) (fresh (x) (== x 'hello) (== q x)))
       '(hello))

(check "conde"
       (run-plan* ns (q) (conde ((== q 1)) ((== q 2)) ((== q 3))))
       '(1 2 3))

(check "run-plan bounded"
       (run-plan 2 ns (q) (conde ((== q 'a)) ((== q 'b)) ((== q 'c))))
       '(a b))

(check "reification"
       (run-plan* ns (q) succeed)
       '(_.0))

(check "project"
       (run-plan* ns (q)
         (fresh (x) (== x '(a b c)) (project (x) (== q (length x)))))
       '(3))

(check "in-list-o"
       (run-plan* ns (q) (in-list-o q '(x y z)))
       '(x y z))

(check "in-list-o pattern"
       (run-plan* ns (q)
         (fresh (a b)
           (in-list-o `(pair ,a ,b) '((pair 1 2) (pair 3 4)))
           (== q (list a b))))
       '((1 2) (3 4)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Disequality (=/=)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Disequality ──\n")

(check "=/= eliminates equal"
       (run-plan* ns (q) (== q 5) (=/= q 5))
       '())

(check "=/= allows different"
       (run-plan* ns (q) (== q 5) (=/= q 6))
       '(5))

(check "=/= filters conde branches"
       (run-plan* ns (q)
         (conde ((== q 1)) ((== q 2)) ((== q 3)))
         (=/= q 2))
       '(1 3))

(check "=/= before binding"
       (run-plan* ns (q)
         (fresh (x)
           (=/= x 'bad)
           (conde ((== x 'good)) ((== x 'bad)))
           (== q x)))
       '(good))

(check "=/= with pairs"
       (run-plan* ns (q)
         (fresh (x y)
           (== x '(a b))
           (=/= x '(a b))
           (== q x)))
       '())

(check "=/= structural: different pairs ok"
       (run-plan* ns (q)
         (fresh (x)
           (== x '(a c))
           (=/= x '(a b))
           (== q x)))
       '((a c)))

(check "=/= two vars must differ"
       (length (run-plan* ns (q)
                 (fresh (x y)
                   (conde ((== x 1)) ((== x 2)))
                   (conde ((== y 1)) ((== y 2)))
                   (=/= x y)
                   (== q (list x y)))))
       2)  ;; (1 2) and (2 1), not (1 1) or (2 2)
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Type constraints (numbero, symbolo)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Type constraints ──\n")

(check "numbero: ground number passes"
       (run-plan* ns (q) (== q 42) (numbero q))
       '(42))

(check "numbero: ground symbol fails"
       (run-plan* ns (q) (== q 'hello) (numbero q))
       '())

(check "numbero: ground string fails"
       (run-plan* ns (q) (== q "str") (numbero q))
       '())

(check "symbolo: ground symbol passes"
       (run-plan* ns (q) (== q 'hello) (symbolo q))
       '(hello))

(check "symbolo: ground number fails"
       (run-plan* ns (q) (== q 42) (symbolo q))
       '())

(check "numbero + symbolo on same var: fails"
       (run-plan* ns (q)
         (fresh (x)
           (numbero x)
           (symbolo x)
           (== q x)))
       '())

(check "numbero filters non-numbers from conde"
       (run-plan* ns (q)
         (fresh (x)
           (numbero x)
           (conde ((== x 1)) ((== x 'a)) ((== x 2)))
           (== q x)))
       '(1 2))

(check "symbolo filters non-symbols from conde"
       (run-plan* ns (q)
         (fresh (x)
           (symbolo x)
           (conde ((== x 1)) ((== x 'a)) ((== x 'b)))
           (== q x)))
       '(a b))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Absento
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Absento ──\n")

(check "absento: atom not in atom (different)"
       (run-plan* ns (q) (== q 'a) (absento 'b q))
       '(a))

(check "absento: atom in atom (same) — fails"
       (run-plan* ns (q) (== q 'a) (absento 'a q))
       '())

(check "absento: atom not in list"
       (run-plan* ns (q) (== q '(b c)) (absento 'a q))
       '((b c)))

(check "absento: atom in list — fails"
       (run-plan* ns (q) (== q '(a b c)) (absento 'a q))
       '())

(check "absento: atom in nested list — fails"
       (run-plan* ns (q) (== q '(b (a) c)) (absento 'a q))
       '())

(check "absento filters conde branches"
       (run-plan* ns (q)
         (conde
           ((== q '(wheat flour)))
           ((== q '(corn flour)))
           ((== q '(rice starch))))
         (absento 'wheat q))
       '((corn flour) (rice starch)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Combined constraints
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Combined ──\n")

(check "=/= + numbero"
       (run-plan* ns (q)
         (fresh (x)
           (numbero x)
           (=/= x 2)
           (conde ((== x 1)) ((== x 2)) ((== x 3)))
           (== q x)))
       '(1 3))

(check "absento + =/= together"
       (run-plan* ns (q)
         (conde
           ((== q '(a 1)))
           ((== q '(b 2)))
           ((== q '(a 3))))
         (absento 'a q)
         (=/= q '(b 2)))
       '())  ;; (b 2) excluded by =/=, the others by absento

(check "absento on plan-like structure"
       (run-plan* ns (q)
         (conde
           ((== q '(produce spec-bread recipe-bread 1
                     ((spec-flour (produce spec-flour recipe-mill 1
                       ((spec-wheat (satisfied spec-wheat 10 ())))))))))
           ((== q '(purchase spec-bread 20))))
         (absento 'spec-wheat q))
       '((purchase spec-bread 20)))  ;; only the purchase plan survives
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Fact queries with constraints
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Fact queries ──\n")

(define test-facts
  '((recipe bread-recipe "Bread" spec-bread)
    (recipe flour-recipe "Flour" spec-flour)
    (flow mill input spec-wheat 10 kg consume)
    (flow mill output spec-flour 8 kg produce)
    (flow oven input spec-flour 8 kg consume)
    (flow oven output spec-bread 20 each produce)))

(check "fact query: what recipes exist?"
       (run-plan* ns (q)
         (fresh (rid name output)
           (in-list-o `(recipe ,rid ,name ,output) test-facts)
           (== q rid)))
       '(bread-recipe flour-recipe))

(check "fact query + =/=: recipes except flour"
       (run-plan* ns (q)
         (fresh (rid name output)
           (in-list-o `(recipe ,rid ,name ,output) test-facts)
           (=/= output 'spec-flour)
           (== q rid)))
       '(bread-recipe))

(check "fact query + absento: flows without wheat"
       (run-plan* ns (q)
         (fresh (pid dir spec qty unit action)
           (in-list-o `(flow ,pid ,dir ,spec ,qty ,unit ,action) test-facts)
           (absento 'spec-wheat (list pid dir spec))
           (== q (list pid dir spec))))
       '((mill output spec-flour) (oven input spec-flour) (oven output spec-bread)))

(check "fact query + numbero: qty is a number"
       (run-plan* ns (q)
         (fresh (pid dir spec qty unit action)
           (in-list-o `(flow ,pid ,dir ,spec ,qty ,unit ,action) test-facts)
           (numbero qty)
           (== q qty)))
       '(10 8 8 20))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. CLP(FD) — finite domain constraints
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── CLP(FD) ──\n")

;; infd: basic domain constraint
(check "infd: ground value in domain"
       (run-plan* ns (q) (== q 3) (infd q '(1 2 3 4 5)))
       '(3))

(check "infd: ground value NOT in domain"
       (run-plan* ns (q) (== q 6) (infd q '(1 2 3 4 5)))
       '())

(check "infd: singleton domain binds variable"
       (run-plan* ns (q) (infd q '(42)))
       '(42))

(check "infd: domain intersection + labelfd"
       (run-plan* ns (q)
         (infd q '(1 2 3 4 5))
         (infd q '(3 4 5 6 7))
         (labelfd q))
       '(3 4 5))

;; Wait — that last one should produce multiple results via labelfd.
;; Without labeling, a variable with a 3-element domain stays unground.
;; Let me fix: use labelfd to enumerate.

(check "infd + labelfd: enumerate domain"
       (run-plan* ns (q)
         (infd q '(1 2 3))
         (labelfd q))
       '(1 2 3))

(check "infd + labelfd: intersected domain"
       (run-plan* ns (q)
         (infd q '(1 2 3 4 5))
         (infd q '(3 4 5 6 7))
         (labelfd q))
       '(3 4 5))

;; rangeo
(check "rangeo + labelfd"
       (run-plan* ns (q)
         (rangeo q 1 5)
         (labelfd q))
       '(1 2 3 4 5))

;; +fd: relational addition
(check "+fd: all ground, correct"
       (run-plan* ns (q) (+fd 3 4 7) (== q 'yes))
       '(yes))

(check "+fd: all ground, wrong"
       (run-plan* ns (q) (+fd 3 4 8) (== q 'yes))
       '())

(check "+fd: compute sum"
       (run-plan* ns (q) (+fd 3 4 q))
       '(7))

(check "+fd: compute difference (backward)"
       (run-plan* ns (q) (+fd q 4 7))
       '(3))

(check "+fd: compute other operand"
       (run-plan* ns (q) (+fd 3 q 7))
       '(4))

(check "+fd: all unknown with domains"
       (sort (run-plan* ns (q)
               (fresh (x y)
                 (infd x '(1 2))
                 (infd y '(10 20))
                 (rangeo q 1 100)
                 (+fd x y q)
                 (labelfd x) (labelfd y) (labelfd q)))
             <)
       '(11 12 21 22))

;; -fd
(check "-fd: compute difference"
       (run-plan* ns (q) (-fd 10 3 q))
       '(7))

(check "-fd: backward"
       (run-plan* ns (q) (-fd q 3 7))
       '(10))

;; *fd
(check "*fd: all ground"
       (run-plan* ns (q) (*fd 3 4 q))
       '(12))

(check "*fd: backward division"
       (run-plan* ns (q) (*fd q 4 12))
       '(3))

(check "*fd: with domains"
       (sort (run-plan* ns (q)
               (fresh (x y)
                 (infd x '(1 2 3))
                 (infd y '(10 20))
                 (rangeo q 1 100)
                 (*fd x y q)
                 (labelfd x) (labelfd y) (labelfd q)))
             <)
       '(10 20 20 30 40 60))

;; <fd
(check "<fd: ground true"
       (run-plan* ns (q) (<fd 3 5) (== q 'yes))
       '(yes))

(check "<fd: ground false"
       (run-plan* ns (q) (<fd 5 3) (== q 'yes))
       '())

(check "<fd: narrows domain"
       (run-plan* ns (q)
         (rangeo q 1 10)
         (<fd q 5)
         (labelfd q))
       '(1 2 3 4))

;; <=fd
(check "<=fd: narrows domain"
       (run-plan* ns (q)
         (rangeo q 1 10)
         (<=fd q 5)
         (labelfd q))
       '(1 2 3 4 5))

;; distinctfd
(check "distinctfd: eliminates duplicates"
       (length (run-plan* ns (q)
                 (fresh (x y)
                   (rangeo x 1 3)
                   (rangeo y 1 3)
                   (distinctfd x y)
                   (labelfd x) (labelfd y)
                   (== q (list x y)))))
       6)  ;; 3*3 - 3 = 6 pairs where x != y

;; Planning-relevant: scale computation
(check "CLP(FD): what scale produces 40 from batches of 20?"
       (run-plan* ns (q)
         (fresh (scale)
           (*fd scale 20 40)
           (== q scale)))
       '(2))

(check "CLP(FD): what quantities can scale 1-3 produce from batch 20?"
       (sort (run-plan* ns (q)
               (fresh (scale)
                 (rangeo scale 1 3)
                 (rangeo q 1 100)
                 (*fd scale 20 q)
                 (labelfd scale) (labelfd q)))
             <)
       '(20 40 60))

;; The question project couldn't answer:
;; "What scale factors between 1 and 5 produce between 30 and 80 units
;;  from a recipe that outputs 20 per batch?"
(check "CLP(FD): scale range → output range (bidirectional)"
       (run-plan* ns (q)
         (fresh (scale output)
           (rangeo scale 1 5)
           (rangeo output 1 100)
           (*fd scale 20 output)
           (rangeo output 30 80)
           (labelfd scale) (labelfd output)
           (== q (list scale output))))
       '((2 40) (3 60) (4 80)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Constraint propagation through ==
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Constraint propagation through == ──\n")

(check "symbolo + == + numbero → fail"
       (run-plan* ns (q) (fresh (x y) (symbolo x) (== x y) (numbero y)))
       '())

(check "numbero propagates through == to ground symbol → fail"
       (run-plan* ns (q) (fresh (x) (numbero x) (== x q) (== q 'hello)))
       '())

(check "symbolo survives chain x→y→z"
       (run-plan* ns (q) (fresh (x y z) (symbolo x) (== x y) (== y z) (== z 42)))
       '())

(check "=/= propagates through =="
       (run-plan* ns (q) (fresh (x y) (=/= x 5) (== x y) (== y 5)))
       '())

(check "=/= propagates through chain x→y→z"
       (run-plan* ns (q) (fresh (x y z) (=/= x 4) (== x y) (== y z) (== z 4)))
       '())

(check "absento propagates through =="
       (run-plan* ns (q) (fresh (x y) (absento 'a x) (== x y) (== y '(1 a 3))))
       '())

(check "absento propagates through chain x→y→z"
       (run-plan* ns (q) (fresh (x y z) (absento 'b x) (== x y) (== y z) (== z '(b))))
       '())

(check "type conflict from two directions via =="
       (run-plan* ns (q) (fresh (x y) (numbero x) (symbolo y) (== x y)))
       '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; =/= with two vars
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── =/= bidirectional ──\n")

(check "=/= two vars, bind both to same → fail"
       (run-plan* ns (q) (fresh (x y) (=/= x y) (== x 5) (== y 5)))
       '())

(check "=/= two vars, bind both to different → succeed"
       (run-plan* ns (q) (fresh (x y) (=/= x y) (== x 5) (== y 6) (== q (list x y))))
       '((5 6)))

(check "=/= two vars then unify them → fail"
       (run-plan* ns (q) (fresh (x y) (=/= x y) (== x y)))
       '())

(check "=/= pair structure, partial binding triggers fail"
       (run-plan* ns (q) (fresh (x) (=/= (cons x 1) (cons 2 1)) (== x 2)))
       '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; Absento + pair structure
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Absento propagation ──\n")

(check "absento pushes into cons, then car violates"
       (run-plan* ns (q) (fresh (x y) (== q (cons x y)) (absento 'a q) (== x 'a)))
       '())

(check "absento on var, then unify with nested pair containing atom"
       (run-plan* ns (q) (fresh (x) (absento 'z x) (== x '(1 (2 z) 3))))
       '())

(check "absento atom not in pair → succeed"
       (run-plan* ns (q) (fresh (x y) (absento 'a (cons x y)) (== x 'b) (== y 'c) (== q (list x y))))
       '((b c)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Combined constraints
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Combined constraints (advanced) ──\n")

(check "multiple =/= then labelfd excludes all"
       (run-plan* ns (q) (=/= q 1) (=/= q 2) (=/= q 3) (rangeo q 1 4) (labelfd q))
       '(4))

(check "FD + =/= interaction"
       (run-plan* ns (q) (rangeo q 1 5) (=/= q 3) (labelfd q))
       '(1 2 4 5))

(check "FD propagates through =="
       (run-plan* ns (q) (fresh (x y) (infd x '(1 2 3)) (== x y) (infd y '(2 3 4)) (labelfd y) (== q y)))
       '(2 3))

(check "distinctfd with ground after =="
       (run-plan* ns (q) (fresh (x y) (infd x '(1 2 3)) (infd y '(1 2 3))
                           (distinctfd x y) (== x 1) (labelfd y) (== q y)))
       '(2 3))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Integration: miniature planning scenario
;;;
;;; Models the real planner's pattern: given a demand, allocate from inventory,
;;; then if insufficient, find a recipe, compute scale via CLP(FD), recurse
;;; on inputs. This is the engine's raison d'être.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Planning integration ──\n")

;; Domain: a bakery commune
;;   inventory: 50kg flour, 200kg wheat
;;   recipe "mill":  10kg wheat → 8kg flour
;;   recipe "bake":  5kg flour  → 10 bread
;;   demand: 20 bread

;; Relational queries over fact lists — the pattern the real planner uses
(define (inventory-o spec qty)
  (conde
    ((== spec 'wheat) (== qty 200))
    ((== spec 'flour) (== qty 50))
    ((== spec 'bread) (== qty 0))))

(define (recipe-o name in-spec in-qty out-spec out-qty)
  (conde
    ((== name 'mill)  (== in-spec 'wheat) (== in-qty 10)
     (== out-spec 'flour) (== out-qty 8))
    ((== name 'bake)  (== in-spec 'flour) (== in-qty 5)
     (== out-spec 'bread) (== out-qty 10))))

(check "plan: what recipe+scale produces 20 bread?"
       (run-plan 1 ns (q)
         (fresh (rname in-spec in-qty out-spec out-qty scale total)
           (recipe-o rname in-spec in-qty out-spec out-qty)
           (== out-spec 'bread)
           (rangeo scale 1 10)
           (*fd scale out-qty total)
           (<=fd 20 total)
           (labelfd scale)
           (== q (list rname scale))))
       '((bake 2)))

(check "plan: what inputs does baking at scale 2 need?"
       (run-plan* ns (q)
         (fresh (rname in-spec in-qty out-spec out-qty input-needed)
           (recipe-o rname in-spec in-qty out-spec out-qty)
           (== rname 'bake)
           (*fd 2 in-qty input-needed)
           (== q (list in-spec input-needed))))
       '((flour 10)))

(check "plan: can we satisfy 10kg flour from inventory?"
       (run-plan* ns (q)
         (fresh (avail)
           (inventory-o 'flour avail)
           (<=fd 10 avail)
           (== q avail)))
       '(50))

;; Full chain: 20 bread → bake@2 → 10kg flour → from inventory
(check "plan: 20 bread via bake then flour from inventory"
       (run-plan 1 ns (q)
         (fresh (rname in-spec in-qty out-spec out-qty
                 scale total input-needed avail)
           (recipe-o rname in-spec in-qty out-spec out-qty)
           (== out-spec 'bread)
           (rangeo scale 1 10)
           (*fd scale out-qty total)
           (<=fd 20 total)
           (labelfd scale)
           (*fd scale in-qty input-needed)
           (inventory-o in-spec avail)
           (<=fd input-needed avail)
           (== q (list 'produce out-spec rname scale
                       (list 'from in-spec input-needed)))))
       '((produce bread bake 2 (from flour 10))))

;; 2-step chain: 120 bread → bake@12 → 60kg flour, only 50 available
;; → mill wheat to cover the 10kg gap
(check "plan: 2-step chain — bread → flour → wheat"
       (run-plan 1 ns (q)
         (fresh (scale1 total1 flour-needed
                 scale2 total2 wheat-needed
                 flour-avail wheat-avail flour-gap)
           (rangeo scale1 1 20)
           (*fd scale1 10 total1)
           (<=fd 120 total1)
           (labelfd scale1)
           (*fd scale1 5 flour-needed)
           (inventory-o 'flour flour-avail)
           (-fd flour-needed flour-avail flour-gap)
           (rangeo scale2 1 20)
           (*fd scale2 8 total2)
           (<=fd flour-gap total2)
           (labelfd scale2)
           (*fd scale2 10 wheat-needed)
           (inventory-o 'wheat wheat-avail)
           (<=fd wheat-needed wheat-avail)
           (== q (list 'bake scale1 'then 'mill scale2))))
       '((bake 12 then mill 2)))

;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
