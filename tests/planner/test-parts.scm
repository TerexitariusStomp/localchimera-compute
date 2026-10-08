;;; test-parts.scm — the one selector, on closed-form terms.
;;;
;;; What parts.scm claims and this suite holds (voice-in-lean.md, Parts.lean):
;;;   - a part is a conjunction: `part-meet` refuses two nodes of one kind
;;;     (theorem 9 `parts_inf`: covers (meet a b) c ⇔ covers a c ∧ covers b c);
;;;   - a union has no name: no value of make-part covers a column two ways
;;;     (theorem 8′ `union_carries_hours`, by construction — checked here as:
;;;     a part covers a column only when EVERY stated term holds);
;;;   - refinement is pointwise (π ≤ π'), and a narrower part covers no more;
;;;   - every rung released from a cell's terms covers that cell (theorem 11
;;;     `rung_covers_origin`);
;;;   - the string form round-trips and is SAID-stable (kinds in one order);
;;;   - a part covering nothing is the symbol `nothing`, and compile-parts SAYS it;
;;;   - the engine's `key-terms` reads every key shape it emits, and a part
;;;     naming a process/place/period names the same column `pin-cell` builds.
;;;
;;; Run:  guile -q -L module tests/planner/test-parts.scm

(use-modules (playnet test harness) (srfi srfi-1) (ice-9 format)
             (playnet planner facts parts)
             ((playnet planner solve engine) #:select (key-terms key-prefix key-process key-arc column-terms)))

(define (raises? thunk) (catch #t (lambda () (thunk) #f) (lambda _ #t)))

(format #t "~%=== a part is a conjunction ===~%")
(define W (cons "2026-01-05T00:00:00Z" "2026-01-11T23:59:59Z"))
(define bake-town (make-part #:process "bake" #:place "town"))
(define bake-night (make-part #:process "bake" #:window W))
(define mill (make-part #:process "mill"))
(define oven (make-part #:means "wood-oven"))

(check "meet of compatible parts states both"
       (equal? (part-terms (part-meet bake-town oven))
               '((process . "bake") (means . "wood-oven") (place . "town"))))
(check "meet refuses two nodes of one kind" (not (part-meet bake-town mill)))
(check "meet of windows is their intersection"
       (equal? (part-node (part-meet bake-night (make-part #:window (cons "2026-01-07T00:00:00Z" "2026-02-01T00:00:00Z"))) 'window)
               (cons "2026-01-07T00:00:00Z" "2026-01-11T23:59:59Z")))
(check "disjoint windows have no meet"
       (not (part-meet bake-night (make-part #:window (cons "2026-03-01T00:00:00Z" "2026-03-02T00:00:00Z")))))
(check "the empty part is the widest" (part-empty? (make-part)))
(check "a node may not carry the separators" (raises? (lambda () (make-part #:process "a;b"))))

(format #t "~%=== covers?: every stated term holds ===~%")
(define T1 '((prefix . "p") (process . "bake") (place . "town") (period . 3)
             (window . ("2026-01-06T00:00:00Z" . "2026-01-06T23:59:59Z"))
             (skill . ("baker" "helper")) (means . ("wood-oven"))))
(define T2 '((tag . "p") (process . "bake") (place . "farm") (period . 3)
             (window . ("2026-01-06T00:00:00Z" . "2026-01-06T23:59:59Z"))
             (skill . ("baker")) (means . ("gas-oven"))))
(check "process+place covers the matching column" (covers? bake-town T1))
(check "…and not the other place" (not (covers? bake-town T2)))
(check "a window covers by inclusion" (and (covers? bake-night T1) (covers? bake-night T2)))
(check "a means matches by membership" (and (covers? oven T1) (not (covers? oven T2))))
(check "a skill matches by membership" (covers? (make-part #:skill "helper") T1))
(check "the empty part covers everything" (and (covers? (make-part) T1) (covers? (make-part) T2)))
(check "a missing term never matches" (not (covers? (make-part #:scope "uc") T1)))
(check "meet covers ⇔ both cover (parts_inf)"
       (every (lambda (t)
                (let ((m (part-meet bake-town oven)))
                  (eq? (covers? m t) (and (covers? bake-town t) (covers? oven t)))))
              (list T1 T2)))
(check "a narrower part covers no more (hours_antitone, the cover half)"
       (let ((narrow (part-meet bake-town oven)))
         (and (part-refines? narrow bake-town)
              (every (lambda (t) (or (not (covers? narrow t)) (covers? bake-town t))) (list T1 T2)))))

(format #t "~%=== rungs: every subset of a cell's terms covers the cell (theorem 11) ===~%")
(let ((rungs (rungs-of T1)))
  (check "2^n rungs for n stated single-valued terms (process place window means)" (= (length rungs) 16))
  (check "every rung covers its origin cell" (every (lambda (r) (covers? r T1)) rungs))
  (check "the origin rung is the narrowest" (every (lambda (r) (part-refines? (terms->part T1) r)) rungs))
  (check "a multi-valued skill is released, never picked" (not (part-stated? (terms->part T1) 'skill))))

(format #t "~%=== the string form ===~%")
(let* ((p (make-part #:window W #:process "bake" #:scope "berlin" #:place "town"))
       (s (part->string p)))
  (check "kinds are stated in one order whatever the constructor saw"
         (equal? s "scope=berlin;process=bake;place=town;window=2026-01-05T00:00:00Z/2026-01-11T23:59:59Z"))
  (check "round-trip" (part-equal? p (string->part s)))
  (check "the empty part is the empty string" (and (equal? "" (part->string (make-part))) (part-empty? (string->part ""))))
  (check "an unknown kind is refused" (raises? (lambda () (string->part "colour=red"))))
  (check "a kind stated twice is refused" (raises? (lambda () (string->part "process=a;process=b")))))

(format #t "~%=== compile: nothing is a symbol, and it is said ===~%")
(let* ((vec (vector T1 T2)) (said '()))
  (check "indices of the covered columns" (equal? (compile-part bake-night vec) '(0 1)))
  (check "a part covering nothing is `nothing`" (eq? 'nothing (compile-part mill vec)))
  (check "a caller that walks `nothing` raises" (raises? (lambda () (for-each identity (compile-part mill vec)))))
  (let ((r (compile-parts (list bake-town mill oven) vec #:say (lambda (π) (set! said (cons (part->string π) said))))))
    (check "compile-parts keeps the covering parts" (equal? (map cdr r) '((0) (0))))
    (check "…and says the one that covered nothing, once" (equal? said '("process=mill")))))

(format #t "~%=== a hand ===~%")
(check "a hand parses to (part . portion)"
       (let ((h (validate-hand '(("process=bake" . -0.5) ("" . 1)))))
         (and (= 2 (length h)) (part-equal? (caar h) (make-part #:process "bake")) (= -0.5 (cdar h)))))
(check "a portion outside [-1,1] is refused" (raises? (lambda () (validate-hand '(("process=bake" . 1.5))))))
(check "an unparsable key is refused" (raises? (lambda () (validate-hand '(("oven" . 1))))))

(format #t "~%=== the engine's one key reader ===~%")
(check "p|proc|cell" (equal? (key-terms "p|bake|town@3") '((prefix . "p") (process . "bake") (cell . "town@3") (place . "town") (period . 3))))
(check "p|proc|a|b (an arc) keeps the origin's place and period"
       (let ((t (key-terms "p|haul|town@3|farm@3")))
         (and (equal? (assq-ref t 'process) "haul") (equal? (assq-ref t 'arc) '("town@3" . "farm@3"))
              (equal? (assq-ref t 'place) "town") (= 3 (assq-ref t 'period)))))
(check "m|good|a|b" (equal? (assq-ref (key-terms "m|flour|town@3|town@4") 'good) "flour"))
(check "w|id|skill|cell" (equal? (key-terms "w|ada|baker|town@3")
                                 '((prefix . "w") (worker . "ada") (skill . "baker") (cell . "town@3") (place . "town") (period . 3))))
(check "wr|id|skill|cell" (equal? (assq-ref (key-terms "wr|ada|baker|town@3") 'worker) "ada"))
(check "r|id|spec|cell" (equal? (assq-ref (key-terms "r|coop|oven|town@3") 'means) "oven"))
(check "acq|row" (equal? (key-terms "acq|flour#town@3") '((prefix . "acq") (row . "flour#town@3"))))
(check "an unknown shape keeps its prefix alone" (equal? (key-terms "z|x|y|z|w") '((prefix . "z"))))
(check "the three readings: prefix, process, arc"
       (and (equal? (key-prefix "wr|ada|baker|town@3") "wr")
            (not (key-process "m|flour|town@3|town@4"))
            (equal? (key-arc "p|haul|farm@3|town@4") '("farm@3" . "town@4"))
            (not (key-arc "p|bake|town@3"))))
(check "key-process on a claim column is its second segment, as before"
       (equal? (key-process "p|claim~bread~ada|town@3") "claim~bread~ada"))
(check "column-terms reads skills, means and delivered goods off the flows"
       (let ((t (column-terms (list "p|bake|town@3"
                                    '(("Lab|baker|town@3" . -2.0) ("Svc|wood-oven#town@3" . -1.0)
                                      ("flour#town@3" . -1.5) ("bread#town@3" . 10.0))
                                    0.0 "town@3"))))
         (and (equal? (assq-ref t 'skill) '("baker")) (equal? (assq-ref t 'means) '("wood-oven"))
              (equal? (assq-ref t 'delivers) '(("bread" . 10.0)))
              (equal? (assq-ref t 'consumes) '(("flour" . 1.5))))))
(check "a tag is a kind: it round-trips, it meets, and it covers the acts that carry it"
       (let ((π (string->part "process=bake;tag=tag:wood-oven-way")))
         (and (equal? (part-tag π) "tag:wood-oven-way")
              (equal? (part->string π) "process=bake;tag=tag:wood-oven-way")
              (covers? (make-part #:tag "tag:wood-oven-way") '((process . "bake") (tag . ("tag:wood-oven-way" "tag:bread"))))
              (not (covers? (make-part #:tag "tag:wood-oven-way") '((process . "bake") (tag . ("tag:bread")))))
              (not (covers? (make-part #:tag "tag:wood-oven-way") '((process . "bake"))))
              (not (part-meet (make-part #:tag "a") (make-part #:tag "b"))))))
(check "a part naming process and place covers the column a pin names (accepts.scm pin-cell: p|proc|place@period)"
       (let ((t (key-terms (string-append "p|" "bake" "|" "town" "@" (number->string 3)))))
         (and (covers? (make-part #:process "bake" #:place "town") t)
              (not (covers? (make-part #:process "bake" #:place "farm") t)))))

(test-summary!)
(exit (if (= FAIL 0) 0 1))
