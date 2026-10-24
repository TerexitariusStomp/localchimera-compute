;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation-gateways-driver.scm — the federation between two gateways.
;;;
;;; Given the two gateways' data directories, each holding what its founding
;;; commune published at its berth (federation-sref.txt: its peer's sturdyref
;;; and the AID it speaks under): a signed federation scope admits both as
;;; remote members (the wire fixture's `fx-federation!`; each gateway tells its
;;; own census when it boots) and answers for itself on the wire — its desk and its fold
;;; (`fx-serve-federation!`). Each gateway is handed its federation.scm: its
;;; own demand, the federation's AID, and where the federation's desk
;;; answers. Nothing of the spec is written out; each gateway asks.
;;;
;;;   `specs-written`   both federation.scm are out
;;;   `settled`         the fold read a final certificate (the run's figures) and
;;;                     the federation recorded the crossing (what the scopes gave it)
;;;   `stopped`         waited for: the script has stopped gateway B
;;;   `noted`           what B had said by then is noted
;;;   `restarted`       waited for: B is up again on the same state
;;;
;;; After `restarted` the fold is read again: B has spoken since, the
;;; federation is final, and B stands at the version it kept.
;;;
;;; Usage: guile -L module -s tests/integration/federation-gateways-driver.scm <dir-A> <dir-B>

(use-modules (localchimera test planner federation-wire-fixture)
             (localchimera federation peer)
             ((localchimera federation host) #:select (read-kept keep! make-berth moor!))
             ((localchimera keri citizen-sig) #:select (keri-identity-aid))
             ((localchimera keri acdc) #:select (cred-claim cred-holder cred-revoked?))
             ((localchimera test harness) #:select (pick-free-port))
             (goblins) (goblins vat)
             (fibers)
             (ice-9 format) (ice-9 match) (ice-9 threads) (srfi srfi-1))

(setvbuf (current-output-port) 'line)
(define args (cdr (command-line)))
(define dir-a (list-ref args 0)) (define dir-b (list-ref args 1))
(define (berth-of dir) (read-kept (string-append dir "/federation-sref.txt")))
(define-values (sref-a aid-a) (apply values (berth-of dir-a)))
(define-values (sref-b aid-b) (apply values (berth-of dir-b)))
(define aid-f (keri-identity-aid (fx-identity 3)))
(format #t "driver: A ~a at ~a~%driver: B ~a at ~a~%" aid-a sref-a aid-b sref-b)
(unless (and (string? aid-a) (string? aid-b))
  (format #t "driver: a gateway published no AID to speak under~%")
  (primitive-exit 1))

;; the federation, moored here: its scope, its desk, its fold, in one vat
(define mtx (make-mutex)) (define cv (make-condition-variable)) (define ready #f)
(call-with-new-thread
 (lambda ()
   (run-fibers
    (lambda ()
      (define vat (spawn-vat #:name "federation"))
      (with-vat vat
        (let ((moored (moor! (make-berth (pick-free-port)))))
          (call-with-values (lambda () (fx-federation! aid-a sref-a aid-b sref-b))
            (lambda (fed spec)
              (with-mutex mtx
                (set! ready `((vat . ,vat) (spec . ,spec) (fed . ,fed)
                              (served . ,(fx-serve-federation! fed (assq-ref moored 'mycapn) (assq-ref moored 'netlayer)
                                                               (string-append dir-a "/federation-served")))))
                (signal-condition-variable cv))))))
      (let loop () (sleep 3600) (loop)))
    #:drain? #f)))
(with-mutex mtx (let lp () (unless ready (wait-condition-variable cv mtx) (lp))))
(define vat (assq-ref ready 'vat))
(define served (wait-vow vat (assq-ref ready 'served)))
(define fold (assq-ref served 'fold))
(define desk (assq-ref served 'sturdyref))

;; each gateway's own word: its demand, the federation it answers to, where that answers
(define (hand! dir demand)
  (keep! (string-append dir "/federation.scm") `((demand . ,demand) (federation . ,aid-f) (desk . ,desk))))
(hand! dir-a '("bread#venue-granary@0" . 5.0))
(hand! dir-b '("bread#venue-table@0" . 40.0))
(keep! (string-append dir-a "/specs-written") #t)
(format #t "driver: the federation ~a answers at ~a~%driver: roster ~a~%"
        aid-f desk (assq-ref (assq-ref ready 'spec) 'roster))

(define (final! leg)
  "The certificate once the federation is final, its figures said; or exit 1."
  (let ((cert (fx-final-certificate vat fold #:wait (or (and=> (getenv "FED_WAIT") string->number) 600)
                                    #:say (lambda (s) (apply format #t "driver: ~as, heard ~a, settled ~a, final ~a~%" s)))))
    (unless cert
      (format #t "driver: ~a: the federation never became final; what each commune last said:~%" leg)
      (for-each (lambda (a) (format #t "driver:   ~s~%" a))
                (assq-ref (call-from-thread vat fold 'certificate) 'attestations))
      (primitive-exit 1))
    (format #t "driver: ~a: FINAL met ~,2f  λ(flour) ~,4f  consensus ~,5f  feasible ~a~%"
            leg (assq-ref cert 'met) (cdr (assoc "flour" (assq-ref cert 'pulls)))
            (assq-ref cert 'consensus) (assq-ref cert 'feasible?))
    (unless (and (assq-ref cert 'feasible?) (< (assq-ref cert 'consensus) 1e-3))
      (primitive-exit 1))
    cert))
(define (words-of aid) (fx-words-of vat fold aid))
(define (version-of aid)                  ; the version AID's end of flour stands at, as the fold heard it
  (assq-ref (car (assq-ref (assoc-ref (call-from-thread vat fold 'heard) aid) 'links)) 'v))

(define cert-1 (final! "federated"))

;; the federation's record of the crossing: what the scopes gave it, as the
;; occurrence it witnessed, held by the giver and signed by the federation
(let* ((recorder (assq-ref served 'recorder))
       (store (call-from-thread vat (assq-ref ready 'fed) 'acdc-store)))
  (define (records)
    (filter (lambda (c) (and (not (cred-revoked? c)) (eq? (cred-claim c 'action) 'transfer-custody)))
            (call-from-thread vat store 'by-issuer aid-f)))
  (unless (fx-until (lambda () (and (pair? (call-from-thread vat recorder 'legs)) (pair? (records)))) 120)
    (format #t "driver: the federation recorded no crossing~%")
    (primitive-exit 1))
  (format #t "driver: the federation recorded ~a crossing(s): ~a~%" (length (records))
          (map (lambda (c) (list (cred-claim c 'resource-conforms-to) (cred-claim c 'qty))) (records)))
  (unless (every (lambda (c) (member (cred-holder c) (list aid-a aid-b))) (records))
    (format #t "driver: a crossing record names someone who is no member~%")
    (primitive-exit 1)))
(keep! (string-append dir-a "/settled") #t)

;; gateway B stopped and started again, by the script; what it had said is
;; counted while it is down, so a word heard later is one it said since
(define (await! mark what)
  (unless (read-kept (string-append dir-a "/" mark) #:wait (or (and=> (getenv "FED_WAIT") string->number) 600))
    (format #t "driver: ~a~%" what)
    (primitive-exit 1)))
(await! "stopped" "gateway B was never stopped")
(define words-before (words-of aid-b))
(define version-before (version-of aid-b))
(keep! (string-append dir-a "/noted") #t)
(await! "restarted" "gateway B never came back")
(unless (fx-until (lambda () (> (words-of aid-b) words-before)) 300)   ; B speaks again once it has reached the fold
  (format #t "driver: B has said nothing since its restart~%")
  (primitive-exit 1))
(define cert-2 (final! "after B's restart"))
(define pull (lambda (c) (cdr (assoc "flour" (assq-ref c 'pulls)))))
(format #t "driver: B spoke ~a time(s) since; version ~a (before ~a); λ ~,4f (before ~,4f)~%"
        (- (words-of aid-b) words-before) (version-of aid-b) version-before (pull cert-2) (pull cert-1))
(primitive-exit
 (if (and (= (version-of aid-b) version-before)
          (< (abs (- (pull cert-2) (pull cert-1))) 1e-3))
     0 1))
