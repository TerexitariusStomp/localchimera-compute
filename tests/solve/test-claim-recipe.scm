;;; test-claim-recipe.scm — the claim is a recipe between the pool and the body.
;;;
;;;   bake:  2 h work            → bread 1            (the scope's good)
;;;   claim: bread 1 + credit|ada 2 h → bread~ada 1   (custody moves; the certificate is drawn)
;;;   eat:   bread~ada 1         → energy|ada 500     (the form reduced to the substance)
;;;
;;; with a hard floor of 1500 energy on ada (a deficit on her nutrient's on-hand,
;;; as apply-repro-bands! lays it). The properties:
;;;   • the floor is met THROUGH the claim: bread~ada is produced, never bread eaten raw;
;;;   • the claim draws credit at the good's crystallized SNLT and the plan tallies it —
;;;     solve-report `credit-drawn` = 2 h × loaves claimed;
;;;   • credit is bookkeeping, never a wall: ada holds no credit on hand and the floor
;;;     is still met — a need is a need.
;;;
;;; Run:  guile -L module tests/solve/test-claim-recipe.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver))

(define recipes
  (compile-recipe
    (list (rp "bake" "Bake") (rp "claim~bread~ada" "Claim bread for ada") (rp "eat~bread~ada" "Eat"))
    (list (wrk "b0" 2.0 "bake") (out "b1" "bread" 1.0 "bake")
          (in "c0" "bread" 1.0 "claim~bread~ada") (in "c1" "credit|ada" 2.0 "claim~bread~ada")
          (out "c2" "bread~ada" 1.0 "claim~bread~ada")
          (in "e0" "bread~ada" 1.0 "eat~bread~ada") (out "e1" "energy|ada" 500.0 "eat~bread~ada"))))

(declare-world! #:places '(("town" 0.0 0.0)) #:templates recipes)
(hash-set! *init* (lg "energy|ada" (cell "town" 0)) -1500.0)   ; the floor: 1500 energy, as a deficit
(hash-set! *A* (cell "town" 0) 10000.0)

(define report
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((res (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list))
             (x (car res)) (t (cadr res))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (list (V "p|bake|town@0") (V "p|claim~bread~ada|town@0") (V "p|eat~bread~ada|town@0")
              (solve-report x cols idx t)
              (member "credit|ada#town@0" raws))))))

(define baked   (first report))
(define claimed (second report))
(define eaten   (third report))
(define rep     (fourth report))
(define credit-raw? (and (fifth report) #t))
(define drawn (or (assoc-ref (assq-ref rep 'credit-drawn) "ada") 0.0))
(define claims (assq-ref rep 'claims))

(format #t "~%── the claim: pool → certificate → body ──~%")
(format #t "  baked ~,3f · claimed ~,3f · eaten ~,3f loaves~%" baked claimed eaten)
(format #t "  credit drawn by ada: ~,3f h   (claims: ~s)~%" drawn claims)

(let* ((c1 (>= eaten 2.999))                                   ; floor 1500 / 500 per loaf = 3 loaves
       (c2 (< (abs (- claimed eaten)) 0.05))                   ; every loaf eaten was claimed first (interior-point slack aside)
       (c3 (< (abs (- drawn (* 2.0 claimed))) 1e-6))           ; the certificate drawn = SNLT × loaves, exactly
       (c4 credit-raw?)                                        ; credit is bookkeeping: a structural raw, never a wall
       (c5 (and (pair? claims) (equal? (take (car claims) 2) '("ada" "bread"))))
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] the floor is met through the claim (3 loaves)~%" (if c1 "✓" "✗"))
  (format #t "  [~a] claimed = eaten: the eat recipe consumes the claimed form only~%" (if c2 "✓" "✗"))
  (format #t "  [~a] credit drawn = crystallized SNLT × loaves (~,3f h)~%" (if c3 "✓" "✗") drawn)
  (format #t "  [~a] credit is a structural raw — drawn and tallied, never a wall~%" (if c4 "✓" "✗"))
  (format #t "  [~a] the plan reports the claim per citizen and good~%" (if c5 "✓" "✗"))
  (format #t "~%~a~%" (if ok "PASS" "FAIL"))
  (exit (if ok 0 1)))
