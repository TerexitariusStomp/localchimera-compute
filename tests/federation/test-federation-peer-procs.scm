;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federation-peer-procs.scm — the coordinator-free federated solve across
;;; TWO PROCESSES, each commune put on the wire through the gateway's door
;;; (federation/federate.scm), joined from credentials, and one of them restarted.
;;;
;;; Commune B is hosted by a child process (federation-wire-host.scm … peer);
;;; commune A lives here. Each has a netlayer and a mycapn as a gateway has
;;; them, and enters the federation as a gateway's founding commune would:
;;; `federate!` over its record and the roster, `federation-join!` from the
;;; sturdyref credentials a federation scope F issued when it admitted them.
;;; F answers for itself on the wire (`serve-federation!`): B keeps only F's
;;; AID and the sturdyref of F's desk, asks the desk for the spec, and boots
;;; on the answer — the roster it runs on derived from F's signed credentials.
;;; From there the communes talk to each other directly — F's fold hears
;;; their signed attestations as they change. B's records never leave the
;;; child.
;;;
;;;   1. A credential from another issuer, or with its content edited, is refused.
;;;   2. Through the door, the two settle with no coordinator: the coordinator's
;;;      met and pull; the deadline set from the round trip; nothing refused.
;;;   3. B is killed and started again with the same state directory: the same
;;;      sturdyref, the state it kept. A's session to it severs, A connects it
;;;      again from the sturdyref, B speaks to the fold again, and the
;;;      federation is final at the versions it was at, read from words said
;;;      since the restart.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/federation/test-federation-peer-procs.scm
;;; With LOCALCHIMERA_FED_REMOTE=<ssh target> B runs on that machine (the fixture:
;;; a checkout there, the crypto libraries on its path, one ssh session
;;; carrying the wire both ways), and the round trips are that network's.

(use-modules (localchimera solve federation-solve))
(use-modules (localchimera test harness)
             (localchimera federation peer)
             (localchimera federation host)
             (localchimera federation federate)
             ((localchimera solve federation-oracle) #:select (make-boundary-oracle solve-consensus))
             ((localchimera keri citizen-sig) #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
             ((localchimera credentials membership) #:select (make-federation-sturdyref-credential))
             ((localchimera federation sturdyref-credential) #:select (sturdyref-credential-end))
             (goblins actor-lib joiners) (goblins actor-lib timers)
             (goblins) (goblins vat)
             (goblins actor-lib on)
             (goblins ocapn captp) (goblins ocapn ids)
             (goblins ocapn netlayer websocket) (goblins utils crypto)
             (fibers)
             (ice-9 threads) (ice-9 format)
             (srfi srfi-1))

(setvbuf (current-output-port) 'line)
(use-modules (localchimera test planner federation-wire-fixture))

(define tmp (or (getenv "TMPDIR") "/tmp"))
(define run-id (string-append "localchimera-fed-peer-" (number->string (getpid))))
(define state-a (string-append tmp "/" run-id ".state-a"))
(define state-f (string-append tmp "/" run-id ".state-f"))
;; what B keeps, and what the two keep for each other: on B's machine
(define sref-path (fx-host-path (string-append run-id ".sref")))
(define state-b (fx-host-path (string-append run-id ".state-b")))
(define spec-path (fx-host-path (string-append run-id ".spec")))
(define slow (if fx-remote 5 1))                 ; the waits, stretched for a far network
(define (clean!)
  (fx-host-rm! sref-path spec-path state-b)
  (for-each (lambda (d) (system* "rm" "-rf" d)) (list state-a state-f)))
(clean!)
(mkdir state-a)
(define port-a (pick-free-port))
(define port-b (pick-free-port))

;; the coordinator's answer on the same economy, before any finish settles the kernel floor
(define ref (let ((oracles (list (make-boundary-oracle (fx-commune-a-scarce)) (make-boundary-oracle (fx-commune-b)))))
              (call-with-values
                  (lambda () (solve-consensus (map (lambda (o) (o 'links)) oracles)
                                              (lambda (centres rho*) (map (lambda (o c) (o 'solve! c rho*)) oracles centres))))
                (lambda (reports met rounds pulls) (list met rounds (hash-ref pulls "flour" 0.0))))))

(define id-a (fx-identity 1))
(define id-b (fx-identity 2))
(define id-f (fx-identity 3))                            ; the federation, which issues
(define id-x (fx-identity 4))                            ; somebody else
(define aid-a (keri-identity-aid id-a))
(define aid-b (keri-identity-aid id-b))
(define aid-f (keri-identity-aid id-f))
(define roster                                 ; participants by AID, as a federation's spec orders them
  `(("flour" ,@(sort (list aid-a aid-b) string<?))))
(define a-masters? (string<? aid-a aid-b))     ; a good's master is its first participant by AID
(define (credential-for issuer aid name sref)   ; a credential from another issuer than the federation
  (make-federation-sturdyref-credential #:issuer-group-aid (keri-identity-aid issuer)
                                        #:commune-aid aid
                                        #:commune-id name
                                        #:sturdyref-uri sref
                                        #:netlayer 'websocket
                                        #:registered-at "2026-09-27T00:00:00Z"
                                        #:signing-keypair (keri-identity-keypair issuer)))

;; ── commune A, through the door, here; the vat on a fibers thread, the reading on this one ──
(define mtx (make-mutex)) (define cv (make-condition-variable))
(define setup #f)
(define fold-log '())
(call-with-new-thread
 (lambda ()
   (run-fibers
    (lambda ()
      (define host (spawn-vat #:name "commune-A"))
      (with-vat host
        (let* ((moored (moor! (make-berth port-a)))
               (nl (assq-ref moored 'netlayer)) (mycapn (assq-ref moored 'mycapn))
               (fed (federate! (fx-commune-a-scarce) id-a mycapn nl state-a roster)))
          (with-mutex mtx
            (set! setup `((host . ,host) (mycapn . ,mycapn) (netlayer . ,nl) (fed . ,fed)))
            (signal-condition-variable cv))))
      (let loop () (sleep 3600) (loop)))
    #:drain? #f)))
(with-mutex mtx (let lp () (unless setup (wait-condition-variable cv mtx) (lp))))
(define host (assq-ref setup 'host)) (define mycapn (assq-ref setup 'mycapn))
(define ref-a (assq-ref (assq-ref setup 'fed) 'ref))
(define ends-a (assq-ref (assq-ref setup 'fed) 'ends))
(define sref-a (wait-vow host (assq-ref (assq-ref setup 'fed) 'sturdyref)))
(check "commune A is on the wire through the door" (string? sref-a))
(check "flour is mastered by its first participant by AID, and A has B's end to connect"
       ends-a (if a-masters? `(("flour" ,aid-b ,aid-b)) `(("flour" master ,aid-b))))

;; B: on another machine its berth is chosen here, so the wire can be carried
;; both ways; it moors, keeps its sturdyref, and waits for its spec
(when fx-remote (fx-host-keep! (string-append state-b "/berth") (make-berth port-b)))
(define close-tunnel! (fx-tunnel! port-a port-b))
(define (spawn-b!) (fx-spawn-host "B" sref-path 2 "peer" state-b spec-path))
(define host-pid (spawn-b!))
(define-values (sref-b aid-b*) (fx-host-sturdyref sref-path host-pid #:wait (* 120 slow)))
(check "the host answers under the AID its seed derives" aid-b* aid-b)

;; F admits both, with what crosses for them, and answers for itself: its desk and
;; its fold on the wire. A, beside F here, reads F's word off its store and
;; tells F's fold; B keeps F's AID and where its desk answers
(define federation
  (with-vat host (call-with-values (lambda () (fx-federation! aid-a sref-a aid-b sref-b
                                                                   #:census (list (cons id-a '("flour")) (cons id-b '("flour")))))
                       cons)))
(define spec (cdr federation))
(check "the federation's spec is the roster this side runs on" (assq-ref spec 'roster) roster)
(define served
  (wait-vow host (with-vat host (fx-serve-federation! (car federation) mycapn (assq-ref setup 'netlayer) state-f))))
(define fold (assq-ref served 'fold))
(with-vat host ($ ref-a 'tell fold))
(check "the federation answers at a desk, and its fold at a sturdyref of its own"
       (and (string? (assq-ref served 'sturdyref)) (string? (assq-ref served 'tell))
            (not (equal? (assq-ref served 'sturdyref) (assq-ref served 'tell)))))
(fx-host-keep! spec-path `((federation . ,aid-f) (desk . ,(assq-ref served 'sturdyref))))

;; the two Goblins open a session, or nothing else is worth waiting for
;; ── 1. what a credential must be ──
(display "\n── 1. a far commune enters from a credential, and only a good one ──\n")
(define cred-b (assoc-ref (assq-ref spec 'credentials) aid-b))
(check "the federation's credential names B and its sturdyref"
       (call-with-values (lambda () (sturdyref-credential-end cred-b #:issuer aid-f))
         (lambda (aid uri) (and (equal? aid aid-b) (equal? uri sref-b)))))
(check-error "a credential issued by somebody else is refused"
             (lambda () (sturdyref-credential-end (credential-for id-x aid-b "B" sref-b) #:issuer aid-f)))
(check-error "a credential whose sturdyref was edited after issue is refused"
             (lambda ()
               (sturdyref-credential-end
                (map (lambda (p) (if (eq? (car p) 'claims)
                                     (cons 'claims (map (lambda (c) (if (eq? (car c) 'sturdyref-uri) (cons 'sturdyref-uri sref-a) c)) (cdr p)))
                                     p))
                     cred-b)
                #:issuer aid-f)))
(check-error "a credential of another kind is refused"
             (lambda () (sturdyref-credential-end (map (lambda (p) (if (eq? (car p) 'schema) (cons 'schema "other/v1") p)) cred-b)
                                                  #:issuer aid-f)))

;; ── 2. joined, settled ──
(display "\n── 2. two processes joined through the door, settled with no coordinator ──\n")
(define said '())                                 ; what A's joins say: (link who what …)
(define (mends) (count (lambda (m) (eq? (caddr m) 'ok)) said))
;; the join is the guard: a far end on another Goblins never answers, and the
;; wait is bounded instead of being the suite's every timeout in turn
(define joined
  (wait-vow host (with-vat host
                   (race (federation-join! mycapn ref-a ends-a (assq-ref spec 'credentials) #:issuer aid-f
                                           #:log (lambda (m) (set! said (cons m said))))
                         (timeout (* 120 slow) 'no-session)))))
(check "A joined B's end: both ends speak the channel pin's Goblins" joined ends-a)
(when (eq? joined 'no-session)
  (fx-stop-host! host-pid) (close-tunnel!) (clean!)
  (error "the two Goblins never opened a session; nothing else is worth waiting for"))
(define join-report (find (lambda (m) (eq? (caddr m) 'joined)) said))
(format #t "   round trip to B ~,4fs; A's deadline ~,2fs~%" (list-ref join-report 3) (list-ref join-report 4))
(check "the round trip was measured" (> (list-ref join-report 3) 0.0))
(check "the deadline is several round trips, and at least the floor"
       (let ((d (call-from-thread host ref-a 'deadline)))
         (and (>= d 1.0) (>= d (* 8 (list-ref join-report 3))))))

(define (settled-cert waited-max) (fx-final-certificate host fold #:wait waited-max))
(define (say-sides!)                            ; what each side says, when they never settled
  (format #t "   A's joins said: ~a~%" (reverse said))
  (for-each (lambda (h) (format #t "   heard from ~a: ~a~%" (substring (car h) 0 8)
                                (map (lambda (k) (cons k (assq-ref (cdr h) k))) '(met settled? stage links))))
            (call-from-thread host fold 'heard)))
(define cert (settled-cert (* 120 slow)))
(check "the two processes settled, with no coordinator" (and cert #t))
(unless cert (say-sides!))
(define (link-version aid)               ; the version AID's end of flour stands at, as the fold heard it
  (let ((a (assoc-ref (call-from-thread host fold 'heard) aid)))
    (assq-ref (car (assq-ref a 'links)) 'v)))
(define pull-1 #f)
(when cert
  (let ((pull (cdr (assoc "flour" (assq-ref cert 'pulls)))))
    (set! pull-1 pull)
    (format #t "   two processes: met ~,2f (in-process ~,2f)  λ ~,4f (in-process ~,4f)  consensus ~,5f  v ~a~%"
            (assq-ref cert 'met) (car ref) pull (caddr ref) (assq-ref cert 'consensus) (link-version aid-b))
    (check "the demand met is the coordinator's" (< (abs (- (assq-ref cert 'met) (car ref))) 0.5))
    (check "the pull is the coordinator's" (< (abs (- pull (caddr ref))) 0.5))
    (check "the flows agree across the link" (< (assq-ref cert 'consensus) 1e-3))
    (check "each commune made its exact local solve and its floors close"
           (and (assq-ref cert 'final?) (assq-ref cert 'feasible?)))
    (check "both communes kept their state"
           (and (read-kept (string-append state-a "/kept")) (fx-host-read (string-append state-b "/kept")) #t))
    (check "A refused nothing: B's first word came before A had reached it, from the AID the roster expects"
           (call-from-thread host ref-a 'refused) 0)))

;; ── 3. B restarted at the same berth ──
(display "\n── 3. B killed and started again: the same sturdyref, the state it kept ──\n")
(define v-before (and cert (link-version aid-b)))
(define mends-before (mends))
(fx-stop-host! host-pid)
(define words-before (fx-words-of host fold aid-b))    ; B is down: what it had said
(fx-host-rm! sref-path)
(define host-pid-2 (spawn-b!))
(define-values (sref-b2 aid-b2) (fx-host-sturdyref sref-path host-pid-2 #:wait (* 120 slow)))
(check "B is reachable at the same sturdyref" sref-b2 sref-b)
(check "B has spoken to the fold since its restart"
       (fx-until (lambda () (> (fx-words-of host fold aid-b) words-before)) (* 120 slow)))
(check "the severed session was noticed and B connected again from its sturdyref"
       (fx-until (lambda () (>= (- (mends) mends-before) 1)) (* 120 slow)))
(define cert-2 (settled-cert (* 120 slow)))
(check "the federation is final again after B's restart" (and cert-2 #t))
(unless cert-2 (say-sides!))
(when (and cert cert-2)
  (format #t "   after restart: λ ~,4f  consensus ~,5f  v ~a (before ~a)  mends ~a~%"
          (cdr (assoc "flour" (assq-ref cert-2 'pulls))) (assq-ref cert-2 'consensus) (link-version aid-b) v-before
          (- (mends) mends-before))
  (check "B resumed at the version it was at, with no epoch jump" (link-version aid-b) v-before)
  (check "the pull stands" (< (abs (- (cdr (assoc "flour" (assq-ref cert-2 'pulls))) pull-1)) 1e-3))
  (check "the flows still agree" (< (assq-ref cert-2 'consensus) 1e-3))
  (check "A refused nothing across the restart" (call-from-thread host ref-a 'refused) 0))

;; ── cleanup ──
(fx-stop-host! host-pid-2)
(close-tunnel!)
(clean!)
(test-summary!)
