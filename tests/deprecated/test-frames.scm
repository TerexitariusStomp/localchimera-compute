;;; test-frames.scm — A tour of relational frame semantics
;;;
;;; Run via:
;;;   cd planner && guile --no-auto-compile -q -L ../module \
;;;     -l tests/test-frames.scm
;;;
;;; Or via the full test runner (./run-tests.sh).
;;;
;;; Each query in this file runs a miniKanren goal and prints its results.
;;; The output is meant to be read top to bottom — each section illustrates
;;; one capability of the underlying frame semantics.

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (playnet deprecated kanren-constraints)
             (ice-9 format))

(let ((dir (dirname (current-filename))))
  (use-modules (playnet deprecated planner relational frames)))

(define ns '())
;;; ══════════════════════════════════════════════════════════════════════════
;;; Display helpers
;;; ══════════════════════════════════════════════════════════════════════════

(define (line c n) (make-string n c))

(define (banner str)
  (newline)
  (display (line #\═ 78)) (newline)
  (display "  ") (display str) (newline)
  (display (line #\═ 78)) (newline))

(define (section str)
  (newline)
  (let ((pad (max 1 (- 73 (string-length str)))))
    (display "── ") (display str) (display " ") (display (line #\─ pad))
    (newline)))

(define query-count 0)

(define-syntax q
  (syntax-rules ()
    ((_ label (vars ...) goals ...)
     (let* ((results (run-plan* ns (vars ...) goals ...))
            (rendered (cond
                        ((null? results) "(none)")
                        (else (format #f "~s" results)))))
       (set! query-count (+ query-count 1))
       (format #t "  ~58@a  →  ~a~%" label rendered)))))
(define-syntax expect
  (syntax-rules ()
    ((_ label expected (vars ...) goals ...)
     (let ((results (run-plan* ns (vars ...) goals ...)))
       (cond
         ((equal? results expected)
          (set! pass-count (+ pass-count 1))
          (format #t "  ✓  ~a~%" label))
         (else
          (set! fail-count (+ fail-count 1))
          (format #t "  ✗  ~a~%      expected: ~s~%      got:      ~s~%"
                  label expected results)))))))
;;; ══════════════════════════════════════════════════════════════════════════
;;;  The tour
;;; ══════════════════════════════════════════════════════════════════════════

(banner "Frame semantics, distilled into relational miniKanren")
(section "Class hierarchy — everything ISA entity")

(q "wheat ISA crop"             (r) (== r 'yes) (classified-as-o 'wheat 'crop))
(q "wheat ISA food"             (r) (== r 'yes) (classified-as-o 'wheat 'food))
(q "wheat ISA physical-object"  (r) (== r 'yes) (classified-as-o 'wheat 'physical-object))
(q "wheat ISA entity"           (r) (== r 'yes) (classified-as-o 'wheat 'entity))
(q "wrench ISA food (false)"    (r) (== r 'yes) (classified-as-o 'wrench 'food))
(q "everything classified-as food"     (e) (classified-as-o e 'food))
(q "everything classified-as tool"     (e) (classified-as-o e 'tool))
(q "everything classified-as sentient" (e) (classified-as-o e 'sentient))
(section "Frame structure — core, peripheral, restrictions")

(q "core FEs of producing"          (fe) (core-fe-o 'producing fe))
(q "peripheral FEs of producing"    (fe) (peripheral-fe-o 'producing fe))
(q "all FEs of commerce-buy"        (fe) (fe-of-o 'commerce-buy fe))
(q "restriction on producing.agent" (c) (fe-restriction-o 'producing 'agent c))
(q "restriction on producing.recipe"(c) (fe-restriction-o 'producing 'recipe c))
(q "restriction on consuming.input" (c) (fe-restriction-o 'consuming 'input c))
(section "Frame inheritance — transitive, both directions")

(q "ancestors of producing"         (a) (frame-isa-o 'producing a))
(q "ancestors of commerce-buy"      (a) (frame-isa-o 'commerce-buy a))
(q "descendants of event"           (d) (frame-isa-o d 'event))
(q "descendants of intentionally-create" (d) (frame-isa-o d 'intentionally-create))
(q "FEs available on producing (incl. inherited)" (fe) (inherits-fe-o 'producing fe))
(q "FEs available on commerce-buy (incl. inherited)" (fe) (inherits-fe-o 'commerce-buy fe))
(section "Lexical units — words evoke frames")

(q "frame evoked by 'bake'"        (f) (evokes-o "bake" f))
(q "frame evoked by 'buy'"         (f) (evokes-o "buy" f))
(q "frame evoked by 'sell'"        (f) (evokes-o "sell" f))
(q "frame evoked by 'eat'"         (f) (evokes-o "eat" f))
(q "all words evoking producing"   (w) (evokes-o w 'producing))
(q "all words evoking commerce-buy"(w) (evokes-o w 'commerce-buy))
(q "all words evoking consuming"   (w) (evokes-o w 'consuming))
(q "all words evoking transfer"    (w) (evokes-o w 'transfer))
(section "Perspective — same frame, different syntax→FE mapping")

(q "FE at SUBJECT of 'buy'"     (fe) (fe-of-syn-o "buy" 'subject fe))
(q "FE at SUBJECT of 'sell'"    (fe) (fe-of-syn-o "sell" 'subject fe))
(q "FE at SUBJECT of 'purchase'"(fe) (fe-of-syn-o "purchase" 'subject fe))
(q "FE at OBJECT of 'buy'"      (fe) (fe-of-syn-o "buy" 'object fe))
(q "FE at OBJECT of 'sell'"     (fe) (fe-of-syn-o "sell" 'object fe))
(q "syn position for BUYER in 'buy'"  (s) (syn-of-fe-o "buy" 'buyer s))
(q "syn position for BUYER in 'sell'" (s) (syn-of-fe-o "sell" 'buyer s))
(q "syn position for SELLER in 'buy'" (s) (syn-of-fe-o "buy" 'seller s))
(q "syn position for SELLER in 'sell'" (s) (syn-of-fe-o "sell" 'seller s))
(section "Frame filling — vincent bakes bread for the commune in the oven")

(define vincent-bakes
  '((subject . vincent)
    (object  . bread)
    (in      . oven)
    (for     . commune)))

(q "agent of vincent-bakes"      (f) (filled-o "bake" vincent-bakes 'agent f))
(q "product of vincent-bakes"    (f) (filled-o "bake" vincent-bakes 'product f))
(q "instrument of vincent-bakes" (f) (filled-o "bake" vincent-bakes 'instrument f))
(q "recipient of vincent-bakes"  (f) (filled-o "bake" vincent-bakes 'recipient f))
(q "quantity of vincent-bakes"   (f) (filled-o "bake" vincent-bakes 'quantity f))
(section "The same situation expressed two ways: buy vs sell")

(define vincent-buys
  '((subject . vincent) (object . bread) (from . bakery) (for . dollars)))

(define bakery-sells
  '((subject . bakery) (object . bread) (to . vincent) (for . dollars)))

(q "buyer of vincent-buys (via 'buy')"     (f) (filled-o "buy" vincent-buys 'buyer f))
(q "seller of vincent-buys (via 'buy')"    (f) (filled-o "buy" vincent-buys 'seller f))
(q "buyer of bakery-sells (via 'sell')"    (f) (filled-o "sell" bakery-sells 'buyer f))
(q "seller of bakery-sells (via 'sell')"   (f) (filled-o "sell" bakery-sells 'seller f))
(q "goods of vincent-buys"                 (f) (filled-o "buy" vincent-buys 'goods f))
(q "goods of bakery-sells"                 (f) (filled-o "sell" bakery-sells 'goods f))
(section "Completeness — which core FEs are unfilled?")

(q "missing core (full filling)"     (fe) (missing-core-o "bake" vincent-bakes fe))
(q "missing core (subject only)"     (fe) (missing-core-o "bake" '((subject . vincent)) fe))
(q "missing core (no constituents)"  (fe) (missing-core-o "bake" '() fe))
(q "missing core for 'buy' (no constituents)" (fe) (missing-core-o "buy" '() fe))
(section "Type checking against restrictions")

(q "well-typed: vincent bakes bread (oven, commune)"
   (r) (== r 'yes) (well-typed-fill-o "bake" vincent-bakes))
(q "well-typed: bread bakes vincent (subject ill-typed)"
   (r) (== r 'yes) (well-typed-fill-o "bake" '((subject . bread) (object . vincent))))
(q "well-typed: vincent bakes wrench (product ok — phys-obj)"
   (r) (== r 'yes) (well-typed-fill-o "bake" '((subject . vincent) (object . wrench))))
(q "well-typed: vincent eats wheat"
   (r) (== r 'yes) (well-typed-fill-o "eat" '((subject . vincent) (object . wheat))))
(q "well-typed: vincent eats wrench (input must be food)"
   (r) (== r 'yes) (well-typed-fill-o "eat" '((subject . vincent) (object . wrench))))
(q "well-typed: vincent buys bread from bakery for dollars"
   (r) (== r 'yes) (well-typed-fill-o "buy" vincent-buys))
(q "well-typed: vincent buys bread from bread for dollars (seller ill-typed)"
   (r) (== r 'yes) (well-typed-fill-o "buy"
                      '((subject . vincent) (object . bread)
                        (from . bread) (for . dollars))))
(section "Bidirectional generation — find verbs that fit a constituent pattern")

;; Note: well-typed-fill-o checks the constituents against the verb's frame
;; restrictions, but it's still up to the caller to constrain WHICH frame
;; the verb evokes. Without a frame constraint, any verb whose subject FE
;; accepts a sentient and whose object FE accepts a physical-object will
;; pass — which is most of them. Adding (frame-isa-o frame ...) narrows.

(q "PRODUCING verbs: vincent + bread"
   (word)
   (fresh (frame)
     (evokes-o word frame)
     (frame-isa-o frame 'producing)
     (well-typed-fill-o word '((subject . vincent) (object . bread)))))

(q "any verbs accepting subject=vincent, object=bread"
   (word)
   (well-typed-fill-o word '((subject . vincent) (object . bread))))

(q "verbs accepting vincent buying bread from bakery for dollars"
   (word)
   (well-typed-fill-o word '((subject . vincent) (object . bread)
                             (from . bakery) (for . dollars))))

(q "verbs accepting bakery selling bread to vincent for dollars"
   (word)
   (well-typed-fill-o word '((subject . bakery) (object . bread)
                             (to . vincent) (for . dollars))))

(q "CONSUMING verbs accepting vincent eating wheat"
   (word)
   (fresh (frame)
     (evokes-o word frame)
     (frame-isa-o frame 'consuming)
     (well-typed-fill-o word '((subject . vincent) (object . wheat)))))

(q "CONSUMING verbs accepting vincent eating wrench (wrench isn't food)"
   (word)
   (fresh (frame)
     (evokes-o word frame)
     (frame-isa-o frame 'consuming)
     (well-typed-fill-o word '((subject . vincent) (object . wrench)))))
(section "Cross-frame discovery — shared frame elements")

(q "FEs shared by commerce-buy and transfer"
   (fe) (shared-fe-o 'commerce-buy 'transfer fe))

(q "frames sharing 'agent' with producing"
   (f) (shared-fe-o 'producing f 'agent))

(q "frames sharing 'time' with consuming"
   (f) (shared-fe-o 'consuming f 'time))

(q "frames sharing 'instrument' with producing"
   (f) (shared-fe-o 'producing f 'instrument))
(section "ValueFlows event translation")

(q "VF event type for producing"     (et) (fresh (m) (vf-translation-o 'producing et m)))
(q "VF event type for commerce-buy"  (et) (fresh (m) (vf-translation-o 'commerce-buy et m)))
(q "VF event type for consuming"     (et) (fresh (m) (vf-translation-o 'consuming et m)))
(q "VF event type for working"       (et) (fresh (m) (vf-translation-o 'working et m)))
(q "VF param for producing.product"  (vf) (vf-param-of-o 'producing 'product vf))
(q "VF param for producing.agent"    (vf) (vf-param-of-o 'producing 'agent vf))
(q "VF param for commerce-buy.seller"(vf) (vf-param-of-o 'commerce-buy 'seller vf))
(q "VF param for commerce-buy.buyer" (vf) (vf-param-of-o 'commerce-buy 'buyer vf))
(section "End-to-end — vincent bakes bread → VF produce event")

;; Walk the layers explicitly:
;;   word     → "bake"
;;   frame    → producing
;;   filled   → for each FE, find its filler in the constituents
;;   VF param → for each FE, find its VF parameter name
;;   event    → assemble (produce :provider vincent :resource bread ...)

(let* ((word    "bake")
       (cs      vincent-bakes)
       (frame   (car (run-plan* ns (f) (evokes-o word f))))
       (event-t (car (run-plan* ns (et) (vf-event-type-o frame et))))
       (rows    (run-plan* ns (q)
                  (fresh (fe filler vf-param)
                    (filled-o word cs fe filler)
                    (vf-param-of-o frame fe vf-param)
                    (== q (list fe filler vf-param))))))
  (format #t "  word        :  ~s~%" word)
  (format #t "  constituents:  ~s~%" cs)
  (format #t "  evokes      :  ~s~%" frame)
  (format #t "  VF event    :  ~s~%" event-t)
  (newline)
  (display "  Filled FEs and their VF parameters:") (newline)
  (for-each
    (lambda (row)
      (format #t "    ~12@a = ~10@a   →   :~a~%"
              (list-ref row 0) (list-ref row 1) (list-ref row 2)))
    rows)
  (newline)
  (display "  Reconstructed VF event:") (newline)
  (let ((args (apply append
                (map (lambda (row)
                       (let ((vf     (list-ref row 2))
                             (filler (list-ref row 1)))
                         (list (string->symbol
                                 (string-append ":" (symbol->string vf)))
                               filler)))
                     rows))))
    (format #t "    (~a~{ ~s~})~%" event-t args)))
;;; ══════════════════════════════════════════════════════════════════════════
;;; Regression assertions (compared exactly)
;;; ══════════════════════════════════════════════════════════════════════════

(section "Regression assertions")

(expect "wheat ISA food"            '(yes) (r) (== r 'yes) (classified-as-o 'wheat 'food))
(expect "wheat ISA entity"          '(yes) (r) (== r 'yes) (classified-as-o 'wheat 'entity))
(expect "wrench is not food"        '()    (r) (== r 'yes) (classified-as-o 'wrench 'food))

(expect "core FEs of producing"
        '(agent product)
        (fe) (core-fe-o 'producing fe))

(expect "ancestors of producing"
        '(producing intentionally-create event)
        (a) (frame-isa-o 'producing a))

(expect "frame evoked by 'bake'"
        '(producing)
        (f) (evokes-o "bake" f))

(expect "buy.subject = buyer"        '(buyer)  (fe) (fe-of-syn-o "buy" 'subject fe))
(expect "sell.subject = seller"      '(seller) (fe) (fe-of-syn-o "sell" 'subject fe))
(expect "buy.object = goods"         '(goods)  (fe) (fe-of-syn-o "buy" 'object fe))
(expect "sell.object = goods"        '(goods)  (fe) (fe-of-syn-o "sell" 'object fe))

(expect "agent of vincent-bakes"
        '(vincent)
        (f) (filled-o "bake" vincent-bakes 'agent f))

(expect "missing core for empty 'bake' filling"
        '(agent product)
        (fe) (missing-core-o "bake" '() fe))

(expect "vincent eats wheat: well-typed"
        '(yes)
        (r) (== r 'yes) (well-typed-fill-o "eat" '((subject . vincent) (object . wheat))))

(expect "vincent eats wrench: ill-typed"
        '()
        (r) (== r 'yes) (well-typed-fill-o "eat" '((subject . vincent) (object . wrench))))

(expect "vincent baking bread: which producing-frame verbs fit?"
        '("bake" "produce" "grow" "forge" "make")
        (word)
        (fresh (frame mapping)
          (lexical-unit-o word frame mapping)
          (frame-isa-o frame 'producing)
          (well-typed-fill-o word '((subject . vincent) (object . bread)))))

(expect "VF event for producing"
        '(produce)
        (et) (fresh (m) (vf-translation-o 'producing et m)))

(expect "VF param for producing.product"
        '(resource)
        (vf) (vf-param-of-o 'producing 'product vf))
;;; ══════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ══════════════════════════════════════════════════════════════════════════

(section "Summary")
(format #t "  ~a queries shown~%" query-count)
(format #t "  ~a assertions passed, ~a failed~%" pass-count fail-count)
(newline)

(if (> fail-count 0)
    (exit 1)
    (exit 0))
