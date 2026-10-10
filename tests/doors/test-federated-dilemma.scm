;;; test-federated-dilemma.scm — the two horns, read off the folds by quantity.
;;;
;;; A federated run that hits its round cap is one of two things, and the
;;; folds name which before any round runs: HORN A, how much must cross for
;;; the stated need (the deficit of the communes that lack the good); HORN B,
;;; how much can (the stock of those that hold it). need > stock is a
;;; shortfall — no allocation exists —
;;; and need ≤ stock is a surplus nobody claimed. The 2026-08-08 attempt
;;; derived the requirement from an uncapped solve and read 843 kg for a
;;; 6.25 kg need; the folds state a bound, not a forecast. Where a commune
;;; states only reproduction floors (nutrient units — kilograms of the good
;;; are a solve away) the dilemma says `floors-only` rather than pretend.
;;;
;;; Run:  guile --no-auto-compile -q -L module -L tests tests/doors/test-federated-dilemma.scm

(use-modules (playnet test harness) (playnet knowledge recipes federation-demo) (playnet scope root) (playnet vf schemas) (playnet scope live)
             (playnet doors service)
             (playnet knowledge recipes federation-demo)
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (dilemma-for svc granary-stock)
  (let ((a (spawn-scope-root "Granary")) (b (spawn-scope-root "Table")))
    (seed-fed-commune! a "fed" "commune-granary" "Granary" "venue-granary" 42.70 23.32 granary-stock)
    (seed-fed-commune! b "fed" "commune-table"   "Table"   "venue-table"   42.75 23.40 0.0)
    (let ((ga (string-append "G" (number->string granary-stock)))
          (tb (string-append "T" (number->string granary-stock))))
      ($ svc 'add-scope! ga a) ($ svc 'add-scope! tb b)
      (let ((r ($ svc 'federated-plan "flour"
                  (list (list ga (cons "bread#venue-granary@0" 5.0))
                        (list tb (cons "bread#venue-table@0" 40.0))))))
        (assoc-ref (assq-ref (cdr r) 'dilemma) "flour")))))

(with-vat (spawn-vat)
  (let ((svc (spawn ^planner-service (hashmap))))

    (display "\n── abundance: the stock covers the stated need — covered ──\n")
    (let ((d (dilemma-for svc 300.0)))
      (format #t "   ~s~%" d)
      (check "need = the table's 40 kg of bread at 1 kg flour each"
             (assq-ref d 'need) 40.0)
      (check "stock = the granary's 300 kg" (assq-ref d 'stock) 300.0)
      (check "verdict: covered" (assq-ref d 'verdict) 'covered)
      (check "nothing missing" (assq-ref d 'missing) 0.0))

    (display "\n── scarcity: the need exceeds what exists — shortfall, by quantity ──\n")
    (let ((d (dilemma-for svc 20.0)))
      (format #t "   ~s~%" d)
      (check "verdict: shortfall — no allocation exists"
             (assq-ref d 'verdict) 'shortfall)
      (check "and the horn is named: 20 kg missing"
             (assq-ref d 'missing) 20.0))))

;; a floors-only commune — shaped as federated-repro-test shapes the Kiez:
;; a record naming a crossing and repro-floors with no demand-tuples. The
;; dilemma is a read over the record's own fields, so a record built by hand
;; in that shape asks exactly the question.
(display "\n── floors only: the horn the fold cannot name is named as unnamed ──\n")
(let* ((farm-res (list (make-economic-resource #:id "g" #:conforms-to "grain" #:classified-as '()
                         #:accounting-quantity (make-measure 8.0 "kg") #:onhand-quantity (make-measure 8.0 "kg")
                         #:current-location "farm")))
       (kiez `((scope-id . "kiez") (crossings . ((3 "grain" -1 . 0)))
               (demand-tuples . ()) (repro-floors . (("energy|ada#kiez@0" . 2500.0)))))
       (farm `((scope-id . "farm") (crossings . ((2 "grain" 1 . 0)))
               (demand-tuples . ()) (repro-floors . ())))
       (d (assoc-ref (federated-dilemma (list farm kiez)
                                        (lambda (sid) (if (equal? sid "farm") farm-res '())))
                     "grain")))
  (format #t "   ~s~%" d)
  (check "the stock is read (8 kg)" (assq-ref d 'stock) 8.0)
  (check "the verdict is floors-only — not a false 'covered'"
         (assq-ref d 'verdict) 'floors-only))

(test-summary!)
