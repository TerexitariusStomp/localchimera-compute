;;; tests/keri/integration/test-witness-receipts.scm — LIVE witnessed
;;; inception with receipt collection: the end of the witness-receipt chain.
;;;
;;; Runs against the harness's POOL witness (run-integration.sh), the only
;;; witness here whose OOBI advertises a /loc/scheme endpoint (its keripy
;;; config carries `curls`; the demo six serve a bare icp and can never be
;;; receipted-to). The flow this proves, every link of which used to stall:
;;;
;;;   1. KERIA resolves the witness OOBI → KEL + /loc/scheme verified →
;;;      endpoint lands in db.locs.
;;;   2. A witnessed AID incepts (toad=1, b=[pool witness]); KERIA queues
;;;      it on the Witnesser; the receiptor's hab.fetchUrls now ANSWERS.
;;;   3. The receiptor submits the icp to the witness's /receipts endpoint,
;;;      collects the receipt, and the witness.* operation COMPLETES —
;;;      previously it spun forever on "no http endpoint".

(use-modules (playnet test harness)
             (playnet test keri-integration)
             (playnet keri bridge)
             (playnet keri inception)
             ((playnet keri receiptor) #:select (receipt-event!
                                                 witness-base-url))
             ((playnet keri signify-portable)
              #:select (scm->json-canonical cesr-stream-event))
             (ice-9 format)
             (ice-9 popen)
             (ice-9 textual-ports)
             (ice-9 regex)
             ((srfi srfi-13) #:select (string-trim-right string-null?
                                       string-contains))
             (srfi srfi-1))

(define-values (%admin %boot %pass) (keri-integration-bring-up!))
(define %wit-aid  (getenv "KERI_POOLWIT_AID"))
(define %wit-oobi (getenv "KERI_POOLWIT_OOBI"))

(format #t "=== Live witnessed inception + receipt collection ===~%")
(format #t "  pool witness : ~a~%" (or %wit-aid "(unset!)"))
(format #t "  witness OOBI : ~a~%" (or %wit-oobi "(unset!)"))

(check-call "pool witness env present (harness exports)"
  (lambda () (and %wit-aid %wit-oobi)))

(catch #t (lambda () (keri-boot! "receipts-agent" %pass)) (lambda _ #t))
(keri-connect! %pass)

;;; 1. Resolve the pool witness — its OOBI body carries the /loc/scheme
;;;    reply, so this is the step that teaches KERIA WHERE the witness is.

(check-call "resolve pool witness OOBI (carries /loc/scheme)"
  (lambda ()
    (let ((op (keri-resolve-oobi %wit-oobi #:alias "poolwit")))
      (when (and (pair? op) (assoc-ref op "name"))
        (keri-wait-operation op #:timeout 30))
      #t)))

;;; 2-3. Witnessed inception: KERIA must now reach the witness, submit the
;;;      icp for receipting, and complete the witness.* operation.

(define create-op #f)

(check-call "incept witnessed AID (toad=1, backer = pool witness)"
  (lambda ()
    (set! create-op
          (keri-create-aid "wrtest" #:toad 1 #:witnesses (list %wit-aid)))
    (format #t "  → op: ~a~%" (and (pair? create-op)
                                   (assoc-ref create-op "name")))
    (and (pair? create-op) (assoc-ref create-op "name") #t)))

(check-call "witness.* operation COMPLETES (receipts collected)"
  (lambda ()
    (let ((done (keri-wait-operation create-op #:timeout 90)))
      (format #t "  → done=~a~%" (assoc-ref done "done"))
      (and (assoc-ref done "done") #t))))

(check-call "AID key state carries the backer"
  (lambda ()
    (let* ((data  (keri-get-aid "wrtest"))
           (state (assoc-ref data "state"))
           (b     (and state (assoc-ref state "b"))))
      (format #t "  → b: ~a~%" b)
      (and (vector? b)
           (= 1 (vector-length b))
           (equal? %wit-aid (vector-ref b 0))))))

;;; ── 4. LOCALLY-BUILT witnessed inception (the Scheme receiptor) ─────────────
;;; Scope AIDs are built in the Scheme stack, not KERIA — until now they
;;; HAD to stay toad=0 (a bt>0 KEL served without receipts is escrowed by
;;; every resolver). The receiptor closes that: collect receipts from the
;;; pool witness's HTTP /receipts endpoint at mint time, serve the rct
;;; streams after the KEL, and prove with keripy that the bt=1 inception
;;; is ACCEPTED (enters kevers — escrowed events never do).

(format #t "~%-- 4. locally-built witnessed scope inception --~%")

(define %scope-rec #f)

(check-call "witnessed scope inception collects receipts at mint"
  (lambda ()
    (set! %scope-rec
          (governance-create-scope-aid!
           #:witnesses (list %wit-aid)
           #:toad 1
           #:witness-oobis (list %wit-oobi)
           #:endpoint-url "http://gateway.example:8420/"))
    (let* ((body     (scope-inception-signed-icp %scope-rec))
           (receipts (assoc-ref body "receipts")))
      (format #t "  → receipts: ~a stream(s)~%"
              (and (vector? receipts) (vector-length receipts)))
      (and (vector? receipts)
           (= 1 (vector-length receipts))
           ;; The stream is the witness's rct message.
           (string-contains (vector-ref receipts 0) "\"t\":\"rct\"")))))

(check-call "receipt-less witnessed mint REFUSES (escrow guard)"
  (lambda ()
    (catch #t
      (lambda ()
        (governance-create-scope-aid! #:witnesses (list %wit-aid) #:toad 1)
        #f)  ; minting without witness-oobis must raise
      (lambda _ #t))))

;;; keripy is the authority on escrow: feed it the served body (KEL +
;;; receipts + replies) and require the AID in kevers.

(define (run-capture cmd)
  (let* ((port (open-input-pipe (string-append cmd " 2>&1")))
         (out  (get-string-all port))
         (code (status:exit-val (close-pipe port))))
    (cons code out)))

(check-call "keripy ACCEPTS the bt=1 KEL (receipts beat escrow)"
  (lambda ()
    (let* ((body  (scope-inception-signed-icp %scope-rec))
           (icp   (assoc-ref body "icp"))
           (aid   (assoc-ref icp "i"))
           (served (apply string-append
                          (cesr-stream-event (scm->json-canonical icp)
                                             (assoc-ref body "sigs"))
                          (append
                           (vector->list (or (assoc-ref body "receipts") #()))
                           (vector->list (or (assoc-ref body "replies") #())))))
           (tmp   (string-append (or (getenv "TMPDIR") "/tmp")
                                 "/witnessed-scope-body.cesr")))
      (call-with-output-file tmp (lambda (p) (display served p)))
      (let* ((kli   (let ((r (run-capture "command -v kli")))
                      (and (zero? (car r))
                           (string-trim-right (cdr r)))))
             (wrapper (call-with-input-file kli get-string-all))
             (grab  (lambda (rx)
                      (let ((m (string-match rx wrapper)))
                        (and m (match:substring m 1)))))
             (pypath (grab "GUIX_PYTHONPATH=\"([^\"]+)\""))
             (real   (grab "\"(/gnu/store/[^\"]+\\.kli-real)\""))
             (pyline (substring (call-with-input-file real
                                  (lambda (p) (get-line p))) 2)))
        (setenv "PYTHONPATH" pypath)
        (let ((r (run-capture
                  (string-append pyline
                                 " tests/keri/verify-oobi-replies.py "
                                 tmp " " aid
                                 " http://gateway.example:8420/"))))
          (format #t "~a" (cdr r))
          (delete-file tmp)
          (zero? (car r)))))))

(test-summary!)
