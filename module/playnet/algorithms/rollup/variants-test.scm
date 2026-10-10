;;; rollup/variants-test.scm — exercises the alternative joint-production rollups
;;; against a hand-built technology, with results checked by hand.
;;;
;;; Run:  guile -L module module/playnet/algorithms/rollup/variants-test.scm
;;;
;;; Technology (a classic joint-production toy — a flock yields wool AND mutton):
;;;   R-flock  : work 100h, consume pasture (raw) → produce wool 60, mutton 40
;;;              (JOINT; primary-output = wool)
;;;   R-shear  : work  20h                        → produce wool 30   (wool alone)
;;;   R-hunt   : work  50h                        → produce mutton 25 (mutton alone)
;;;
;;; Ride-free (current): all 100h → wool ⇒ wool 100/60 = 1.667, mutton 0.
;;; Relative-SNLT (3): anchors wool=20/30=0.667, mutton=50/25=2.0;
;;;   weights wool 60·0.667=40, mutton 40·2.0=80, W=120; E=100
;;;   ⇒ wool 100·40/120 / 60 = 0.5556,  mutton 100·80/120 / 40 = 1.6667.
;;; Marginal adjoint (4b) over {wool,mutton}, 3 procs / 2 goods ⇒ least squares
;;;   B=[[60,40],[30,0],[0,25]], l=[100,20,50] ⇒ wool≈0.4903, mutton≈1.8307.

(use-modules (srfi srfi-1))

;; locate this script (current-filename is #f under some run modes)
(define %here (dirname (or (current-filename)
                           (find (lambda (p) (and (string? p) (string-suffix? "variants-test.scm" p)))
                                 (command-line))
                           "module/playnet/algorithms/rollup/variants-test.scm")))

;; Load the engine, then CONTINUE INSIDE its module so the variant files (and the
;; test body) resolve its bindings (rp-duration-ms, recipe-flow accessors, …) and
;; share its record types.
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet vf schemas))
(set-current-module (resolve-module '(playnet boot prelude)))
(use-modules (ice-9 format) (goblins) (goblins actor-lib methods) (goblins utils hashmap))
(define here (@@ (guile-user) %here))
(define (sib rel) (string-append here "/" rel))
;; common.scm is a module; relative-snlt.scm and marginal-dual.scm below are
;; still fragments and read its names out of the current module, so import first.
(use-modules (playnet algorithms rollup common))
(use-modules (playnet algorithms rollup relative-snlt))
(primitive-load (sib "marginal-dual.scm"))

;; A minimal in-line store actor, defined in THIS loaded instance so its records
;; share the engine's <recipe>/<recipe-flow> types (importing recipe-library via
;; use-modules would re-instantiate (playnet planner) and split the types).
;; defs :: list of (recipe procs flows). Answers the 4-message read subset.
(define-actor (^toy-store bcom defs)
  (define (find-def id) (find (lambda (d) (equal? (recipe-id (car d)) id)) defs))
  (methods
    ((all-recipes) (map car defs))
    ((get-recipe id) (and=> (find-def id) car))
    ((get-process-chain id) (let ((d (find-def id))) (if d (cadr d) '())))
    ((flows-for-process pid)
     (let ((all (append-map caddr defs)))
       (cons (filter (lambda (f) (equal? (recipe-flow-recipe-input-of f) pid)) all)
             (filter (lambda (f) (equal? (recipe-flow-recipe-output-of f) pid)) all))))))
(define (spawn-toy-store defs) (spawn ^toy-store defs))

;; ── tiny record builders ─────────────────────────────────────────────────────
(define (hrs x) (make-measure x "hour"))
(define (qty x) (make-measure x "unit"))
(define fid (let ((n 0)) (lambda () (set! n (+ n 1)) (format #f "f~a" n))))
(define (mk-work pid h)
  (make-recipe-flow #:id (fid) #:action 'work #:effort-quantity (hrs h) #:recipe-input-of pid))
(define (mk-consume pid spec q)
  (make-recipe-flow #:id (fid) #:action 'consume #:resource-conforms-to spec
                    #:resource-quantity (qty q) #:recipe-input-of pid))
(define (mk-produce pid spec q)
  (make-recipe-flow #:id (fid) #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (qty q) #:recipe-output-of pid))
(define (mk-proc pid name)
  (make-recipe-process #:id pid #:name name))
(define (mk-recipe id name primary pids)
  (make-recipe #:id id #:name name #:primary-output primary #:recipe-processes pids))

;; ── the technology ───────────────────────────────────────────────────────────
(define flock-p (mk-proc "flock-p" "raise flock"))
(define shear-p (mk-proc "shear-p" "shear sheep"))
(define hunt-p  (mk-proc "hunt-p"  "hunt game"))

(define defs
  (list
    (list (mk-recipe "R-flock" "flock (joint)" "wool" (list "flock-p"))
                (list flock-p)
                (list (mk-work    "flock-p" 100)
                      (mk-consume "flock-p" "pasture" 50)
                      (mk-produce "flock-p" "wool" 60)
                      (mk-produce "flock-p" "mutton" 40)))
    (list (mk-recipe "R-shear" "shear (wool only)" "wool" (list "shear-p"))
                (list shear-p)
                (list (mk-work    "shear-p" 20)
                      (mk-produce "shear-p" "wool" 30)))
    (list (mk-recipe "R-hunt" "hunt (mutton only)" "mutton" (list "hunt-p"))
                (list hunt-p)
                (list (mk-work    "hunt-p" 50)
                      (mk-produce "hunt-p" "mutton" 25)))))

;; ── run ──────────────────────────────────────────────────────────────────────
(define *fail* 0)
(define (about= a b) (< (abs (- a b)) 1e-3))
(define (check label got want)
  (let ((ok (about= got want)))
    (unless ok (set! *fail* (+ *fail* 1)))
    (format #t "    ~a  ~8,4f  (want ~8,4f)  ~a~%" label got want (if ok "✓" "✗ MISMATCH"))))

(define vat (spawn-vat))
(with-vat vat
  (define store (spawn-toy-store defs))

  (format #t "~%════ joint-production rollup variants — R-flock (wool + mutton) ════~%")
  (format #t "  gross effort E = ~a h ; net outputs = ~a~%"
          (recipe-gross-effort store "R-flock")
          (recipe-net-outputs store "R-flock"))

  (format #t "~%(0) ride-free baseline (primary=wool, co-products free):~%")
  (check "wool  " (/ 100.0 60.0) 1.6667)
  (check "mutton" 0.0 0.0)

  (format #t "~%(3) relative-SNLT allocation (anchored to standalone recipes):~%")
  (let* ((r (rollup-relative-snlt store "R-flock"))
         (outs (assq-ref r 'outputs))
         (snlt (lambda (s) (assq-ref (cdr (assoc s (map (lambda (o) (cons (assq-ref o 'spec) o)) outs))) 'snlt))))
    (format #t "    anchored-fraction = ~a ; Σeffort = ~,2f~%"
            (assq-ref r 'anchored-fraction)
            (apply + (map (lambda (o) (assq-ref o 'effort)) outs)))
    (check "wool  " (snlt "wool")   0.5556)
    (check "mutton" (snlt "mutton") 1.6667))

  (format #t "~%(4b) marginal adjoint over {wool,mutton} (3 procs/2 goods ⇒ least-sq):~%")
  (let* ((m (marginal-snlt-adjoint store '("wool" "mutton")))
         (v (assq-ref m 'values)))
    (format #t "    regime=~a  procs=~a goods=~a  any-negative?=~a  residual=~,3f~%"
            (assq-ref m 'regime) (assq-ref m 'processes) (assq-ref m 'goods)
            (assq-ref m 'any-negative?) (assq-ref m 'residual))
    (check "wool  " (cdr (assoc "wool" v))   0.4903)
    (check "mutton" (cdr (assoc "mutton" v)) 1.8307))

  (format #t "~%(4b) DETERMINED check — same goods, only flock+shear in scope:~%")
  (let* ((store2 (spawn-toy-store (list (car defs) (cadr defs))))   ; drop R-hunt
         (m (marginal-snlt-adjoint store2 '("wool" "mutton")))
         (v (assq-ref m 'values)))
    (format #t "    regime=~a  procs=~a goods=~a~%"
            (assq-ref m 'regime) (assq-ref m 'processes) (assq-ref m 'goods))
    (check "wool  " (cdr (assoc "wool" v))   0.6667)
    (check "mutton" (cdr (assoc "mutton" v)) 1.5000))

  (format #t "~%(4a) faithful dual projector — synthetic engine good-pulls:~%")
  (let ((mu (marginal-snlt-from-duals
              '(("wool@town" . 0.49) ("wool@port" . 0.55) ("mutton@town" . 1.83))
              #:key->spec (lambda (k) (car (string-split k #\@))))))
    (check "wool   (max over locations)" (cdr (assoc "wool" mu))   0.55)
    (check "mutton (max over locations)" (cdr (assoc "mutton" mu)) 1.83))

  (format #t "~%════ ~a ════~%~%"
          (if (= *fail* 0) "ALL CHECKS PASS ✓" (format #f "~a CHECK(S) FAILED ✗" *fail*))))

(exit (if (= *fail* 0) 0 1))
