;;; tests/integration/test-multi-gateway-driver.scm
;;;
;;; Driver for the two-gateway subprocess smoke test.
;;; Invoked by run-multi-gateway-smoke.sh after two gateways boot:
;;;
;;;   guile -L module -s tests/integration/test-multi-gateway-driver.scm \
;;;     <sturdyref-A> <sturdyref-B>
;;;
;;; Exit 0  → both gateways live + enlivenable + remote-refr?
;;; Exit 1  → assertion failed or timeout

(use-modules (goblins) (goblins vat)
             (goblins actor-lib on)
             (goblins ocapn captp)
             (goblins ocapn ids)
             (goblins ocapn netlayer websocket)
             (goblins utils crypto)
             (fibers)
             (fibers channels)
             (ice-9 format)
             (playnet test harness)
             (playnet deprecated vat-federation))

(define (log* fmt . args)
  (apply format (current-error-port)
         (string-append "driver: " fmt "\n") args)
  (force-output (current-error-port)))

(define (done! ch val) (put-message ch val) 'done)

(define args (cdr (command-line)))

(unless (= 2 (length args))
  (format (current-error-port) "usage: ~a <sref-A> <sref-B>\n"
          (car (command-line)))
  (primitive-exit 1))

(define sref-a-str (car args))
(define sref-b-str (cadr args))

(format #t "driver: enlivening A=~a...~%"
        (substring sref-a-str 0 (min 50 (string-length sref-a-str))))
(format #t "driver: enlivening B=~a...~%"
        (substring sref-b-str 0 (min 50 (string-length sref-b-str))))

(define result-ch (make-channel))

(run-fibers
 (lambda ()
   (log* "spawning coord vat")
   (define coord-vat (spawn-vat #:name "coord"))
   (with-vat coord-vat
     (log* "generating designator key + netlayer")
     (define coord-key (generate-key-pair))
     (define port (pick-free-port))
     (log* "  port=~a" port)
     (define netlayer
       (spawn ^websocket-netlayer
              #:host "127.0.0.1"
              #:port port
              #:encrypted? #f
              #:designator-key coord-key))
     (define mycapn (spawn-mycapn netlayer))

     (define sref-a (string->ocapn-id sref-a-str))
     (define sref-b (string->ocapn-id sref-b-str))
     (log* "parsed sturdyrefs, enlivening both via vow-all")

     (on (vow-all (list (<- mycapn 'enliven sref-a)
                        (<- mycapn 'enliven sref-b)))
         (lambda (refs)
           (let* ((ref-a (car refs))
                  (ref-b (cadr refs))
                  (a-remote? (remote-refr? ref-a))
                  (b-remote? (remote-refr? ref-b))
                  (distinct? (not (eq? ref-a ref-b))))
             (log* "enliven resolved: a-remote?=~a b-remote?=~a distinct?=~a"
                   a-remote? b-remote? distinct?)
             (done! result-ch
                    (list a-remote? b-remote? distinct?))))
         #:catch
         (lambda (err)
           (log* "enliven error: ~a" err)
           (done! result-ch (list #f #f #f)))
         #:promise? #t)))
 #:drain? #f)

(log* "waiting for result-ch")
(define result (get-message result-ch))
(log* "got result: ~a" result)

(let ((a-remote? (list-ref result 0))
      (b-remote? (list-ref result 1))
      (distinct? (list-ref result 2)))
  (format #t "  ref-a remote-refr?: ~a~%" a-remote?)
  (format #t "  ref-b remote-refr?: ~a~%" b-remote?)
  (format #t "  refs distinct:      ~a~%" distinct?)
  (let ((ok? (and a-remote? b-remote? distinct?)))
    (format #t "driver: ~a~%" (if ok? "PASS" "FAIL"))
    (primitive-exit (if ok? 0 1))))
