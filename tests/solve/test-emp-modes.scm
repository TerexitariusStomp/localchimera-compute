;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-emp-modes.scm — EMP congestion mode (total vs pool) + skill-time preference
;;;
;;; The egalitarian default spreads work, but there are two readings of "equal"
;;; and a worker may declare a preference. A multi-skilled worker (ada: bake+mill)
;;; competing with a single-skill one (bob: bake) for the bake pool exposes both.

(use-modules (playnet test harness) (srfi srfi-1))
;; load the engine directly (it provides the VF records via its schema-load).
;; The engine is a library and prints nothing; its demos live in demo.scm.
(use-modules (playnet solve engine) (playnet test planner worked-example) (playnet solve world)
             (playnet solve solver))
(set! *backend* 'native-c)

(define* (setup #:key (emp-mode 'total))
  (declare-world! #:places '("town") #:templates *base-templates* #:emp-mode emp-mode
                  #:workers
                    (list (list "f1" '("farm") "town@0" 200.0)
                          (list "ada" '("bake" "mill") "town@0" 60.0)    ; multi-skilled
                          (list "bob" '("bake") "town@0" 60.0)))     ; single-skill
  (hash-set! *cap* (lg "soil" "town@0") 1000.0)
  (hash-set! *proc-skill* "grow" "farm") (hash-set! *proc-skill* "mill" "mill") (hash-set! *proc-skill* "bake" "bake")
  (hash-set! *demand* (lg "bread" "town@0") 20.0))
(define (bake-split)   ; -> (ada-bake . bob-bake)
  (call-with-values build-located (lambda (forms lf ncol cols goods raws idx)
    (let ((x (call-with-values (lambda () (solve forms lf (located-warm cols ncol idx))) (lambda (x . _) x))))
      (define (h key) (let ((c (find (lambda (c) (equal? (col-key c) key)) cols))) (if c (vector-ref x (hash-ref idx (col-key c))) 0.0)))
      (cons (h "w|ada|bake|town@0") (h "w|bob|bake|town@0"))))))

(setup)                  (define tot (bake-split))
(setup #:emp-mode 'pool) (define pl  (bake-split))
(setup) (set-worker-pref! "ada" "bake" -0.5) (define eager (bake-split))
(setup) (set-worker-pref! "ada" "bake"  0.5) (define reluc (bake-split))
;; the who rail's bound (engine *pref-bound*, voice-follows-work.md open item 6)
(setup) (set-worker-pref! "ada" "bake" -1.0)  (define at-bound (bake-split))
(setup) (set-worker-pref! "ada" "bake" -50.0) (define past-bound (bake-split))
(setup) (set-worker-pref! "ada" "bake" 0.5) (set-worker-pref! "ada" "mill" 0.5) (set-worker-pref! "bob" "bake" 0.5)
(define all-reluctant (bake-split))
(setup) (set-worker-pref! "bob" "bake" 0.5) (define bob-alone (bake-split))

(display "\n── EMP modes + skill-time preference ──\n")
(check "total mode: multi-skilled ada bakes LESS than single-skill bob (equal total burden)"
       (< (car tot) (cdr tot)))
(check "pool mode: ada and bob bake about EQUALLY (uniform per skill pool)"
       (< (abs (- (car pl) (cdr pl))) 0.5))
(check "pool mode lets ada bake more than total mode (her milling no longer counts against her bake share)"
       (> (car pl) (car tot)))
(check "eager preference: ada bakes MORE than neutral"
       (> (car eager) (car tot)))
(check "reluctant preference: ada bakes LESS than neutral"
       (< (car reluc) (car tot)))
(check "a preference past the bound reads as the bound: the same plan"
       (and (< (abs (- (car at-bound) (car past-bound))) 1e-6) (< (abs (- (cdr at-bound) (cdr past-bound))) 1e-6)))
(check "equal reluctance all round cancels exactly: every assignment where it was"
       (and (< (abs (- (car all-reluctant) (car tot))) 1e-6) (< (abs (- (cdr all-reluctant) (cdr tot))) 1e-6)))
(check "a single-skilled person's preference is centred away: it says nothing about how much they work"
       (and (< (abs (- (car bob-alone) (car tot))) 1e-6) (< (abs (- (cdr bob-alone) (cdr tot))) 1e-6)))
(check "default emp-mode is 'total (a fresh world's)"
       (begin (reset-world!) (eq? *emp-mode* 'total)))

(test-summary!)
