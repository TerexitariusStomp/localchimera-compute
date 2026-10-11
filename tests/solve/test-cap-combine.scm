;;; test-cap-combine.scm — caps on one located good from two pools ADD.
;;;
;;; ingest takes eco-caps from several independent sources appended by the
;;; caller — the UC allocation, socialized means, a what-if — and the
;;; constraint matrix must carry their lawful combine: a second POOL on the
;;; same located good adds (the means fold's own monoid), the first policy cap
;;; overrides a stock-derived one, and a caller's what-if replaces a standing
;;; cap by filtering it out before the append (service.scm plan-fn).
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/solve/test-cap-combine.scm

(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet test harness)
             (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet vf schemas))

(define place (place* "shop"))
(define (cap good t v) (cons (lg good (cell "shop" t)) v))

(display "\n── two pools on one located good add ──\n")
(set-templates! (compile-recipe '() '()))
(ingest-located! '() '() (list place)
  #:eco-caps (list (cap "Svc|lathe" 0 10) (cap "Svc|lathe" 0 5)))
(check "10 + 5 = 15 — the UC share and the lent lathe both stand"
       (hash-ref *cap* (lg "Svc|lathe" (cell "shop" 0))) 15)

(display "\n── a single cap stands alone ──\n")
(ingest-located! '() '() (list place)
  #:eco-caps (list (cap "Svc|lathe" 0 7)))
(check "one source: 7" (hash-ref *cap* (lg "Svc|lathe" (cell "shop" 0))) 7)

(display "\n── distinct located goods never touch ──\n")
(ingest-located! '() '() (list place)
  #:eco-caps (list (cap "Svc|lathe" 0 7) (cap "Svc|lathe" 1 3) (cap "Svc|kiln" 0 2)))
(check "keys keep apart"
       (list (hash-ref *cap* (lg "Svc|lathe" (cell "shop" 0)))
             (hash-ref *cap* (lg "Svc|lathe" (cell "shop" 1)))
             (hash-ref *cap* (lg "Svc|kiln" (cell "shop" 0))))
       '(7 3 2))

(test-summary!)
