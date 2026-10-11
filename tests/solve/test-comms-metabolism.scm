;;; test-comms-metabolism.scm — the comms campaign INSIDE the located solve.
;;;
;;; All four Stage-1 quantities derive from ONE solve, not four bolt-ons. Two
;;; scenarios:
;;;   A. fragility + scheduling — a rented channel (frag on its Svc good) and a
;;;      sovereign one over a 2-period horizon: the solve ROUTES reach onto the
;;;      sovereign channel and SCHEDULES publish per period against Svc capacity.
;;;   B. selection — two needs competing for scarce sovereign capacity: the
;;;      derived good-price duals RANK them and the solve serves the higher one more.
;;;
;;; compose → post-draft; publish `use`s a channel (→ Svc consume) + consumes the
;;; draft → produces reach; a demand on reach is the need.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner \
;;;         tests/solve/test-comms-metabolism.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver)
             (playnet vf schemas))
;; comms/metabolism.scm is a fragment over the engine's world: it loads into
;; this module and reads the engine through the imports above.
(primitive-load (%search-load-path "playnet/comms/metabolism.scm"))

(define fails 0)
(define (check* label pass?) (unless pass? (set! fails (+ fails 1)))
  (format #t "  ~a: ~a~%" (if pass? "ok" "FAIL") label))

;; ── recipes ────────────────────────────────────────────────────────────────
(define (mk-publish proc chan)
  (car (compile-recipe (list (rp proc (string-append "Publish-" proc)))
         (list (in (string-append proc "-in") "post-draft" 1.0 proc)
               (out (string-append proc "-out") "reach" 1.0 proc)
               (use* (string-append proc "-use") chan proc 1.0 #:qty 1.0)))))
(define compose-tpl
  (car (compile-recipe (list (rp "compose" "Compose"))
         (list (out "c1" "post-draft" 1.0 "compose") (wrk "c2" 0.5 "compose")))))
(define pubx-tpl (mk-publish "pubx" "chan-x"))   ; rented (fragile)
(define pubm-tpl (mk-publish "pubm" "chan-m"))   ; sovereign (capacity only)

;;; ════ Scenario A : fragility routing + per-period scheduling ════════════════
(display "\n── A. rented channel is fragile; 2-period horizon ──\n")
(declare-world! #:places '(("town" 0.0 0.0)) #:periods '(0 1)
                #:templates (list compose-tpl pubx-tpl pubm-tpl))
(for-each (lambda (p)
            (hash-set! *A* (cell "town" p) 1000.0)
            (hash-set! *cap* (lg "Svc|chan-x" (cell "town" p)) 100.0)
            (hash-set! *cap* (lg "Svc|chan-m" (cell "town" p)) 100.0)
            (hash-set! *frag-cap* (lg "Svc|chan-x" (cell "town" p)) (list 8.0 12.0 0.5 1.0))
            (hash-set! *demand* (lg "reach" (cell "town" p)) 10.0))   ; need reach 10 EACH period
          '(0 1))

(call-with-values comms-solve
  (lambda (x t cols idx report)
    (let* ((pubx (process-schedule x idx "pubx" "town" '(0 1)))
           (pubm (process-schedule x idx "pubm" "town" '(0 1)))
           (dual-of (comms-dual-of report))
           (reach-p0 (+ (cdr (assv 0 pubx)) (cdr (assv 0 pubm))))
           (reach-p1 (+ (cdr (assv 1 pubx)) (cdr (assv 1 pubm)))))
      (format #t "  pubx(rented)  = ~a~%  pubm(sovereign)= ~a~%" pubx pubm)
      (format #t "  reach: p0=~,2f  p1=~,2f~%" reach-p0 reach-p1)
      (format #t "  dual(reach@0)=~,5f  dual(Svc|chan-x@0)=~,5f  dual(Svc|chan-m@0)=~,5f~%"
              (dual-of (lg "reach" (cell "town" 0)))
              (dual-of (lg "Svc|chan-x" (cell "town" 0)))
              (dual-of (lg "Svc|chan-m" (cell "town" 0))))
      ;; selection (endogenous): the need is met in both periods
      (check* "the reach need is met in period 0" (> reach-p0 8.0))
      (check* "the reach need is met in period 1" (> reach-p1 8.0))
      ;; fragility (derived in-solve): the solve routes reach to the sovereign channel
      (check* "period 0 reach routes to the sovereign channel (pubm ≫ pubx)"
              (> (cdr (assv 0 pubm)) (* 5.0 (cdr (assv 0 pubx)))))
      (check* "period 1 reach routes to the sovereign channel (pubm ≫ pubx)"
              (> (cdr (assv 1 pubm)) (* 5.0 (cdr (assv 1 pubx)))))
      ;; scheduling: sovereign publish activity happens in BOTH periods
      (check* "publish is scheduled in both periods (per-period Svc capacity)"
              (and (> (cdr (assv 0 pubm)) 1.0) (> (cdr (assv 1 pubm)) 1.0)))
      ;; dual-of (derived): the rented channel carries a far hotter pull than sovereign
      (check* "the rented channel's fragility dual ≫ the sovereign's capacity dual"
              (> (dual-of (lg "Svc|chan-x" (cell "town" 0)))
                 (* 10.0 (dual-of (lg "Svc|chan-m" (cell "town" 0))))))
      (check* "the reach need carries a positive shadow price (the selection dual)"
              (> (dual-of (lg "reach" (cell "town" 0))) 0.0))
      ;; the service bridge: an intent-id → its need's dual (what rank consumes)
      (let ((idual (comms-intent-dual-of
                    report (lambda (iid) (if (string=? iid "need:reach")
                                             (lg "reach" (cell "town" 0)) "?")))))
        (check* "comms-intent-dual-of maps an intent-id to its need's solved dual"
                (> (idual "need:reach") 0.0))))))

;;; ════ Scenario B : a met need vs a starved need → the dual is the priority ══
;;; The selection signal IS the shortfall: a fully-met need has shadow price ≈ 0
;;; (nothing to advertise), an under-satisfied one carries a positive dual. So
;;; ranking under-satisfied intents by their derived good-price surfaces exactly
;;; the gaps that most need the megaphone — Stage 1, from the solver's arithmetic.
(display "\n── B. a met need vs a starved need: the dual is the priority ──\n")
(define (mk-publish2 proc chan good)   ; publish to CHAN, producing GOOD
  (car (compile-recipe (list (rp proc (string-append "Publish-" proc)))
         (list (in (string-append proc "-in") "post-draft" 1.0 proc)
               (out (string-append proc "-out") good 1.0 proc)
               (use* (string-append proc "-use") chan proc 1.0 #:qty 1.0)))))
(define pub-a (mk-publish2 "puba" "chan-a" "reach-a"))   ; the MET need's channel (ample)
(define pub-b (mk-publish2 "pubb" "chan-b" "reach-b"))   ; the STARVED need's channel (scarce)

(declare-world! #:places '(("town" 0.0 0.0))
                #:templates (list compose-tpl pub-a pub-b))
(hash-set! *A* (cell "town" 0) 1000.0)
(hash-set! *cap* (lg "Svc|chan-a" (cell "town" 0)) 100.0)    ; AMPLE  → need-a met
(hash-set! *cap* (lg "Svc|chan-b" (cell "town" 0)) 15.0)     ; SCARCE → need-b starved
(hash-set! *demand* (lg "reach-a" (cell "town" 0)) 10.0)     ; met need
(hash-set! *demand* (lg "reach-b" (cell "town" 0)) 30.0)     ; starved need (only 15 possible)

;; The clean scarcity signal is the CAPACITY dual on each need's serving channel:
;; a binding (scarce) channel's Svc good spikes; an ample one's is ~0. So a need
;; that is HARD TO SERVE is flagged by its channel's capacity shadow price — the
;; derived amplifier on Stage-0's deterministic shortfall.
(call-with-values comms-solve
  (lambda (x t cols idx report)
    (let* ((dual-of (comms-dual-of report))
           (a  (cdr (car (process-schedule x idx "puba" "town" '(0)))))
           (b  (cdr (car (process-schedule x idx "pubb" "town" '(0)))))
           (ca (dual-of (lg "Svc|chan-a" (cell "town" 0))))   ; ample channel pull
           (cb (dual-of (lg "Svc|chan-b" (cell "town" 0)))))  ; scarce channel pull
      (format #t "  reach-a(met)=~,2f  reach-b(starved)=~,2f~%" a b)
      (format #t "  capacity dual: ample chan-a=~,6f   scarce chan-b=~,6f~%" ca cb)
      (check* "the starved need's channel capacity binds (reach-b ≈ 15)"
              (and (> b 14.0) (< b 16.0)))
      (check* "the SCARCE channel carries a far higher capacity shadow price"
              (> cb (* 10.0 ca)))
      (check* "the ample channel's capacity pull is ~0 (that need is easy to serve)"
              (< ca 0.01))
      ;; close the loop: ranking needs by the DERIVED dual is exactly the (key →
      ;; number) signature rank-comm-intents (comms/plan.scm) consumes — selection is
      ;; now the solver's own arithmetic, not a lookup table.
      (let* ((needs (list (cons "reach-a" (lg "Svc|chan-a" (cell "town" 0)))
                          (cons "reach-b" (lg "Svc|chan-b" (cell "town" 0)))))
             (ranked (sort needs (lambda (p q) (> (dual-of (cdr p)) (dual-of (cdr q)))))))
        (check* "ranking needs by the derived dual puts the scarce need first"
                (equal? (map car ranked) '("reach-b" "reach-a")))))))

(format #t "~%=== comms-metabolism: ~a failure(s) ===~%" fails)
(exit (if (zero? fails) 0 1))
