;;; federation-wire-host.scm — one commune, in its own process, on the wire.
;;;
;;; A commune moored behind a websocket netlayer at a berth, keeping its
;;; sturdyref and AID where the other process reads them, up until killed.
;;; The other half of test-federation-wire-procs.scm (a ^commune-solver the
;;; coordinator questions) and of test-federation-peer-procs.scm (with `peer`:
;;; the commune as a peer of the coordinator-free solve, through the gateway's
;;; door — federation/federate.scm — exactly as a gateway puts its founding
;;; commune on the wire). The commune this process holds never sees the
;;; other commune's records.
;;;
;;; With `peer`, STATE-DIR keeps the berth and the peer's state, so a process
;;; started again with the same directory is the same commune: the same
;;; sturdyref, resumed at the versions it was at. SPEC-FILE is what a gateway
;;; keeps as federation.scm — the federation's AID and the sturdyref of its
;;; desk, `((federation . aid) (desk . sturdyref))`, or the spec written out —
;;; and is waited for.
;;;
;;; Usage: guile --no-auto-compile -q -L module tests/federation/federation-wire-host.scm \
;;;          A|B <sref-file> <seed-byte> [peer <state-dir> <spec-file>]

(use-modules (playnet test harness)
             (playnet federation wire)
             (playnet federation host)
             (playnet federation federate)
             ((playnet solve engine) #:select (make-boundary-oracle))
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid))
             (goblins) (goblins vat)
             (fibers)
             (ice-9 format) (srfi srfi-1))

(setvbuf (current-output-port) 'line)
(use-modules (playnet test planner federation-wire-fixture))

(define args (cdr (command-line)))
(define (arg i) (and (> (length args) i) (list-ref args i)))
(define which (arg 0))
(define sref-path (arg 1))
(define seed-byte (string->number (arg 2)))
(define peer? (equal? (arg 3) "peer"))
(define state-dir (arg 4))
(define spec-path (arg 5))
(define identity (make-keri-identity (fx-seed seed-byte)))
(define aid (keri-identity-aid identity))
(define rec (if (string=? which "A") (fx-commune-a) (fx-commune-b)))

;; the berth, kept when there is a directory for it
(define berth-path (and state-dir (string-append state-dir "/berth")))
(when (and state-dir (not (file-exists? state-dir))) (mkdir state-dir))
(define berth (or (and berth-path (read-kept berth-path))
                  (let ((b (make-berth (pick-free-port))))
                    (when berth-path (keep! berth-path b))
                    b)))

(define (kept-sref! sref)
  (keep! sref-path (list sref aid))
  (format #t "[host ~a] at 127.0.0.1:~a, sref kept~%" which (assq-ref berth 'port)))

(run-fibers
 (lambda ()
   (define vat (spawn-vat #:name (string-append "commune-" which)))
   (define moored (with-vat vat (moor! berth)))
   (define nl (assq-ref moored 'netlayer))
   (define mycapn (assq-ref moored 'mycapn))
   (if peer?
       ;; through the gateway's door, as a gateway boots: the berth's
       ;; sturdyref kept before the peer stands, since the spec that builds
       ;; the peer is issued against it; the spec waited for here, on no
       ;; vat's turn; then the one boot
       (begin
         (with-vat vat (on (berth-sturdyref nl (assq-ref berth 'swiss)) kept-sref!))
         (let ((spec (or (read-kept spec-path #:wait 300) (error "the spec never came" spec-path))))
           (with-vat vat
             (on (federation-boot! (lambda (spec) rec) identity mycapn nl state-dir spec
                                   #:census '("flour")
                                   #:log (lambda (m) (format #t "[host ~a] ~a~%" which m)))
                 (lambda (fed)
                   (on (assq-ref fed 'joined)
                       (lambda (joined) (format #t "[host ~a] started, joined ~a~%" which (length joined)))))
                 #:catch (lambda (e) (format #t "[host ~a] the boot failed: ~a~%" which e))))))
       (with-vat vat
         (on (berth-register! mycapn nl (spawn ^commune-solver (make-boundary-oracle rec) identity #:name which)
                              (assq-ref berth 'swiss))
             kept-sref!)))
   (let loop () (sleep 3600) (loop)))
 #:drain? #f)
