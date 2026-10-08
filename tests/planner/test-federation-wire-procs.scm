;;; test-federation-wire-procs.scm — the federated solve across TWO PROCESSES.
;;;
;;; Commune B is hosted by a child process (federation-wire-host.scm) behind a
;;; websocket netlayer; commune A and the coordinator live here. The
;;; coordinator enlivens B's sturdyref and runs the pull consensus over a
;;; near ref and a far one, verifying every reply under the AID each commune
;;; is expected to answer with — the AIDs known out of band, as a membership
;;; credential would name them. B's records never leave the child.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-federation-wire-procs.scm

(use-modules (playnet test harness)
             (playnet planner federation wire)
             ((playnet planner solve engine) #:select (make-boundary-oracle))
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid))
             (goblins) (goblins vat)
             (goblins actor-lib on)
             (goblins ocapn captp) (goblins ocapn ids)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (fibers)
             ((playnet planner federation host) #:select (read-kept))
             (ice-9 threads) (ice-9 format)
             (srfi srfi-1))

(setvbuf (current-output-port) 'line)
(use-modules (playnet test planner federation-wire-fixture))

(define sref-path (string-append (or (getenv "TMPDIR") "/tmp")
                                 "/playnet-fed-wire-" (number->string (getpid)) ".sref"))
(when (file-exists? sref-path) (delete-file sref-path))

;; ── the in-process reference, before any finish settles the kernel floor ──
(define ref (fx-reference (fx-commune-a) (fx-commune-b)))

;; ── commune B: a child process ──
(define id-a (make-keri-identity (fx-seed 1)))
(define id-b (make-keri-identity (fx-seed 2)))
(define host-pid (fx-spawn-host "B" sref-path 2))
(define-values (sref-uri host-aid) (fx-host-sturdyref sref-path host-pid))
(format #t "   host B up: ~a~%   host B answers as ~a~%" sref-uri host-aid)
(check "the host answers under the AID its seed derives" host-aid (keri-identity-aid id-b))

;; ── the coordinator and commune A, on a fibers thread; the solve on this one ──
(define mtx (make-mutex)) (define cv (make-condition-variable))
(define ready #f)                                  ; (vat-c ref-a ref-b) once enlivened, or (error . e)
(define (deliver! v) (with-mutex mtx (set! ready v) (signal-condition-variable cv)) 'done)

(call-with-new-thread
 (lambda ()
   (run-fibers
    (lambda ()
      (define vat-a (spawn-vat #:name "commune-A"))
      (define vat-c (spawn-vat #:name "coordinator"))
      (define ref-a (with-vat vat-a (spawn ^commune-solver (make-boundary-oracle (fx-commune-a)) id-a #:name "Granary")))
      (define netlayer
        (with-vat vat-c (spawn ^websocket-netlayer #:host "127.0.0.1" #:port (pick-free-port)
                               #:encrypted? #f #:designator-key (generate-key-pair))))
      (define mycapn (with-vat vat-c (spawn-mycapn netlayer)))
      (with-vat vat-c
        (on (<- mycapn 'enliven (string->ocapn-id sref-uri))
            (lambda (ref-b) (deliver! (list vat-c ref-a ref-b)))
            #:catch (lambda (e) (deliver! (cons 'error e)))))
      (let loop () (sleep 3600) (loop)))
    #:drain? #f)))

(define setup
  (with-mutex mtx (let lp () (if ready ready (begin (wait-condition-variable cv mtx) (lp))))))
(check "enlivened the host's commune" (not (eq? (car setup) 'error)))

(define result
  (if (eq? (car setup) 'error) (list 'error (cdr setup))
      (catch #t
        (lambda ()
          (call-with-values
              (lambda () (federated-solve-wire (car setup) (list (cadr setup) (caddr setup))
                                               #:aids (list (keri-identity-aid id-a) (keri-identity-aid id-b))))
            (lambda (reports met rounds pulls) (list met rounds (hash-ref pulls "flour" 0.0) reports))))
        (lambda (k . a) (list 'error k a)))))

(check "the solve across two processes completed" (not (eq? (car result) 'error)))
(when (eq? (car result) 'error) (format #t "   error: ~s~%" (cdr result)))
(unless (eq? (car result) 'error)
  (let ((met (list-ref result 0)) (rounds (list-ref result 1)) (pull (list-ref result 2))
        (reports (list-ref result 3))
        (cert (module-ref (resolve-module '(playnet planner solve engine)) '*last-certificate*)))
    (format #t "   two processes: met ~,2f rounds ~a λ(flour) ~,6f   (in-process: met ~,2f rounds ~a λ ~,6f)~%"
            met rounds pull (car ref) (cadr ref) (caddr ref))
    (format #t "   certificate: ~s~%" cert)
    (check "B's demand met by A's flour, across processes" (> met 98.0))
    (check "the same rounds as in-process" rounds (cadr ref))
    (check "the same pull as in-process" (< (abs (- pull (caddr ref))) 1e-9))
    (check "every commune's floors close" (assq-ref cert 'feasible?) #t)
    (check "the plan is executable" (assq-ref cert 'coupling-feasible?) #t)
    (check "the far commune answered under its AID" (assq-ref (cadr reports) 'aid) host-aid)
    (check "the far commune is named" (assq-ref (cadr reports) 'name) "B")
    (check "what A supplies is what B draws"
           (< (abs (+ (assoc-ref (assq-ref (car reports) 'flows) "flour")
                      (assoc-ref (assq-ref (cadr reports) 'flows) "flour")))
              1e-3))))

;; ── cleanup ──
(fx-stop-host! host-pid)
(when (file-exists? sref-path) (delete-file sref-path))
(test-summary!)
