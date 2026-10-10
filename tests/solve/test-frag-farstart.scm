;;; test-frag-farstart.scm — the interior-point core recovers from a far warm start (no divergence).
;;;
;;; REGRESSION GUARD for the fraction-to-the-boundary fix. A warm start far past a barrier (bar OR
;;; frag) used to send the line search roaming to ±billions (no step cap). With fraction-to-boundary,
;;; the iterate can never cross a wall, so the solve recovers the SAME optimum from any feasible-region
;;; start. Checked on BOTH the Scheme reference (solve-native) and the C kernel (solve-native-c), since
;;; the fix lives in both.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-farstart.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve solver))

(define want 9.0839543)   ; the known optimum (desire→20, frag tip 10, fixed w 50)
(define starts (list 0.5 9.0 50.0 200.0 1000.0 100000.0))
(define (rig) (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 20.0 1000.0)
                    (mk-frag 10.0 (list (cons 0 -1.0)) 50.0)
                    (mk-bar 0.0 '((0 . 1.0)))))
;; ALSO a plain hard BAR cap — the same vulnerability, the same fix
(define (rig-bar) (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 20.0 1000.0)
                        (mk-bar 10.0 (list (cons 0 -1.0)))
                        (mk-bar 0.0 '((0 . 1.0)))))
(define want-bar 9.9996)  ; the hard bar rides closer to the wall

(define (xstar solver forms x0) (call-with-values (lambda () (solver forms '() (vector x0)))
                                  (lambda (x t . _) (vector-ref x 0))))
(define (recovers? solver forms target) (every (lambda (x0) (< (abs (- (xstar solver forms x0) target)) 0.05)) starts))

(define sn-frag   (recovers? solve-native (rig) want))
(define sn-bar    (recovers? solve-native (rig-bar) want-bar))
;; the feasibility GUARD: solve-native retries from a tiny start, so even ABSURD overshoots (1e9, 1e12)
;; — past what the step cap alone can close in budget — still recover rather than return garbage.
(define guard-ok  (every (lambda (x0) (< (abs (- (xstar solve-native (rig) x0) want)) 0.05)) (list 1e9 1e12)))
(define have-kern (kern-available?))
(define snc-frag  (or (not have-kern) (recovers? solve-native-c (rig) want)))
(define snc-bar   (or (not have-kern) (recovers? solve-native-c (rig-bar) want-bar)))

(format #t "~%── far-start recovery (fraction-to-the-boundary) ──~%")
(format #t "  starts: ~a~%" starts)
(format #t "  Scheme  frag→~,3f bar→~,3f   C-kernel ~a~%"
        (xstar solve-native (rig) 1000.0) (xstar solve-native (rig-bar) 1000.0)
        (if have-kern (format #f "frag→~,3f bar→~,3f" (xstar solve-native-c (rig) 1000.0) (xstar solve-native-c (rig-bar) 1000.0)) "(unavailable)"))

(let ((ok (and sn-frag sn-bar snc-frag snc-bar guard-ok)))
  (format #t "~%  [~a] Scheme solve-native recovers the optimum from every start (frag & bar)~%" (if (and sn-frag sn-bar) "✓" "✗"))
  (format #t "  [~a] C kernel solve-native-c recovers likewise~a~%" (if (and snc-frag snc-bar) "✓" "✗") (if have-kern "" " (kernel unavailable — skipped)"))
  (format #t "  [~a] the feasibility guard recovers absurd overshoots (1e9, 1e12) too~%" (if guard-ok "✓" "✗"))
  (format #t "~%  ~a a far warm start no longer diverges — fraction-to-the-boundary, in both implementations~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
