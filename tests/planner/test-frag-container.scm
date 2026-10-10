;;; test-frag-container.scm — a possibility-tension on a CONTAINER, via contained-in.
;;;
;;; Ecological agents are containers: the Amazon contains its trees. A `tree` EconomicResource whose
;;; contained-in is "amazon" is placed there (resource-place = container) AND registered as one of the
;;; Amazon's contents (the *contained* map, built at ingest). A fragility on the container then reads
;;; draws on EVERYTHING contained in it — so logging trees stresses the Amazon's tipping point, with no
;;; hand-wired coupling: the contained-in hierarchy gives the aggregation for free.
;;;
;;; A `log` recipe draws trees (1000 in stock) to make timber, demanded far past what the forest bears.
;;; Proves: (a) ingest builds *contained*[amazon] = (tree) from the record; (b) with the Amazon
;;; fragility (tip 100), logging eases off below it; (c) without it, logging runs to the stock — so the
;;; container barrier, not the tree's own cap, is what holds the line.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/planner/test-frag-container.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

(define amazon-tip 100.0)   ; quantile_0.5(80,120)
;; a TREE resource, contained-in the Amazon: its place IS the Amazon, and it is one of the Amazon's contents
(define (tree-stock) (er "tree-1" "tree" #f #:place #f #:qty 1000.0 #:unit "kg" #:contained-in "amazon"))
(define (log-recipe)
  (compile-recipe (list (rp "log" "Log"))
                  (list (out "o1" "timber" 1.0 "log") (wrk "o2" 0.01 "log") (in "o3" "tree" 1.0 "log"))))

(define (run container?)
  (set-templates! (log-recipe))
  (ingest-located! (list (tree-stock)) '() (list (place* "amazon"))
    #:periods '(0)
    #:eco-container (if container? (list (cons "amazon" (list 80.0 120.0 0.5 50.0))) '())   ; the Amazon's fragility, tip 100
    #:demand (list (cons (lg "timber" (cell "amazon" 0)) 1000.0)))                          ; want to log far past it
  (hash-set! *A* (cell "amazon" 0) 1000000.0)                                               ; labour (aggregate), set after reset!
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (V "p|log|amazon@0")))))                                                            ; trees logged = timber produced

(define free (run #f))                                   ; no Amazon fragility
(define capd (run #t))                                   ; Amazon fragility, tip 100
(define contained (hash-ref *contained* "amazon" '()))   ; the containment map ingest built from the record

(format #t "~%── possibility-tension on the Amazon (a container), via contained-in ──~%")
(format #t "  *contained*[amazon] = ~a   (built from the tree resource's contained-in)~%" contained)
(format #t "  logging without the Amazon fragility: ~,2f trees~%" free)
(format #t "  logging WITH it (tip ~a):           ~,2f trees~%" amazon-tip capd)

(let* ((c1 (member "tree" contained))                    ; ingest mapped the tree into the Amazon
       (c2 (< capd amazon-tip))                          ; the Amazon fragility holds the line
       (c3 (> (- amazon-tip capd) 0.1))                  ; …eased off before the tip (real margin)
       (c4 (> free (* 2.0 amazon-tip)))                  ; without it, logging runs far past the tip (to the stock)
       (c5 (> capd 1.0))                                 ; still logs something — a limit, not a shutoff
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] ingest built the containment map from contained-in (tree ∈ amazon)~%" (if c1 "✓" "✗"))
  (format #t "  [~a] logging trees stresses the AMAZON's fragility — eases off below the tip (~,1f < ~a)~%" (if (and c2 c3) "✓" "✗") capd amazon-tip)
  (format #t "  [~a] without the container fragility, logging runs far past it (~,1f)~%" (if c4 "✓" "✗") free)
  (format #t "  [~a] the Amazon still yields timber — a limit, not a shutoff~%" (if c5 "✓" "✗"))
  (format #t "~%  ~a a tension on a container rolls up draws on its contents — the contained-in hierarchy, respected~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
