;;; bench-real-vf.scm — the REAL national I-O table, solved through the VF-records path.
;;;
;;; Where bench-real.scm builds convex forms straight off the A-matrix, this feeds
;;; the engine the way the live observer does: real ValueFlows records (built by
;;; io-to-vf.scm) handed to `plan-from-records` — the genuine public entrypoint
;;; (compile-recipe → ingest-located! → build-located → solve → VF commitments).
;;; Same data, same answer, but now it travels the schema, not a bespoke loader.
;;;
;;; Run (smoke, one country):  REGION=AUS guile --no-auto-compile -q -L module \
;;;                              module/playnet/planner/bench-real-vf.scm
;;; Run (full closed world):   guile --no-auto-compile -q -L module \
;;;                              module/playnet/planner/bench-real-vf.scm [path.sexp]

(use-modules (srfi srfi-1) (srfi srfi-13) (ice-9 format) (ice-9 match))
;; planner.scm + io-to-vf.scm live in the planner dir (this script sits in bench/);
;; find the dir that actually holds them, whether run from bench/ or the repo root.
(use-modules (playnet planner solve engine))
(use-modules (playnet planner bench io-to-vf))

(define (secs th) (let ((t0 (get-internal-run-time)))
  (call-with-values th (lambda a (cons (/ (- (get-internal-run-time) t0)
                                          (* 1.0 internal-time-units-per-second)) a)))))

(define DATA   (let ((a (cdr (command-line)))) (if (pair? a) (car a) "docs/data/wiod/wiod2014.sexp")))
(define REGION (let ((r (getenv "REGION"))) (and r (> (string-length r) 0) r)))
(define IO     (call-with-input-file DATA read))

(format #t "~%==== convex planner on REAL I-O via VF RECORDS (~a~a) ====~%"
        DATA (if REGION (format #f ", region=~a" REGION) ""))

;; 1. build the ValueFlows records from the I-O table
(define V (io->vf IO #:region REGION))
(define (g k) (assq-ref V k))
(format #t "  records: ~a specs/sectors, ~a recipe-flows, ~a stock resources, Σhours=~,3g~%"
        (g 'n-kept) (g 'n-flows) (length (g 'resources)) (g 'tot-hours))

;; 2. solve through the genuine entrypoint — generous labour so it should reach ~100%
(define HRS (* 1.05 (g 'tot-hours)))
(define R
  (secs (lambda ()
    (call-with-values
      (lambda ()
        (plan-from-records (g 'resources) (g 'agents) (g 'spatials)
                           (g 'recipe-procs) (g 'recipe-flows)
                           #:periods '(0)
                           #:demand (g 'demand)
                           #:agent-hours (lambda (a t) HRS)
                           #:agent-skills (lambda (a) '("general"))
                           ;; per-agent? #t: skill-resolved labour SUPPLY columns, so the
                           ;; plan emits VF work intents + commitments (the full round-trip).
                           ;; #f = one aggregate labour pool (the honest model for a national
                           ;; table); both reach ~100% now that the EMP/warm-start scale at size.
                           #:per-agent? #t
                           #:backend 'native-c))
      list))))

;; secs ⇒ (elapsed (ints coms material fill cols x idx ntot report)) — name them all
(let ((t (car R)))
  (apply (lambda (ints coms material fill cols x idx ntot report)
           (format #t "  solved in ~,1fs   activities=~a   demand met=~,1f%~%" t (length cols) (* 100.0 fill))
           (format #t "  VF output: ~a work intents, ~a work commitments, ~a material flows~%"
                   (length ints) (length coms) (length material))
           (let ((cert (assq 'certificate report)))
             (when cert (format #t "  certificate (gap ≤ m·t): ~a~%" (cdr cert))))
           (force-output))
         (cadr R)))
(newline)
