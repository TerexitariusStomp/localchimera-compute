;;; federation/peer.scm — a commune as a PEER of the federated solve, on the
;;; wire: the coordinator-free, round-free ADMM of federation/async.scm behind
;;; a Goblins capability, every message signed under the commune's KERI AID.
;;;
;;; federation/wire.scm runs the pull solve as a coordinator that calls each
;;; commune once per round. Here nobody conducts. A commune holds references
;;; to the commune at the far end of each of its links, hands each message to
;;; that reference as it arises, and acts on the ones it is handed — the state
;;; machine is federation/async's `make-peer`; this is its shell, and it adds
;;; what the machine leaves out: who said it, and where it goes.
;;;
;;; WHO SAID IT. A message travels as the text of its payload and an Ed25519
;;; signature under the sender's AID (the wire's `signed-reply`); the payload
;;; names the sender. The receiving end pins the AID it expects on that link
;;; when it is connected, out of band as a membership credential would name it,
;;; and verifies before it reads. An end may be connected by its AID before
;;; there is a reference to it — the roster says who speaks on a link before
;;; the far side is reachable — so a neighbour's first word is read on
;;; arrival. A message whose signature fails, that speaks under another AID
;;; than the link's, or that names a link with no end for it is REFUSED and
;;; counted, and dropped: the state machine is idempotent under loss, so a
;;; refusal costs the forger nothing and an honest sender a retry at its next
;;; tick.
;;;
;;; WHAT IT SAYS OF ITSELF. `attest` answers the peer's standing, signed, and
;;; with TELL the shell hands that standing to TELL (`hear`) after every
;;; change. `^attestation-fold` is what hears: the latest word of every
;;; commune it expects, verified, and the certificate read off them —
;;; whether the words were told or asked for (`gather-attestations`).
;;;
;;; WHERE IT GOES. Each end of a link is a reference and the AID it must speak
;;; under. Every send is one-way (`<-np`) and waits for nothing: a neighbour
;;; that is down is a message that goes nowhere, and the state machine is
;;; idempotent under loss. A session that has severed is the host's to notice
;;; (Goblins' `on-sever`, federation/host.scm) and to connect again.
;;;
;;; WHEN. The shell owns no clock. The host calls `tick` on a cadence — the
;;; deadline after which a master publishes a stalled version again, and an
;;; participant with no centre asks for one — and `start-ticker!` is that clock,
;;; an actor in the vat that wakes on Goblins' `timeout`. Whatever here takes a
;;; vat's turn says so and is called inside one. `ping` measures a
;;; round trip, and `deadline!` sets the peer's deadline from one. A commune
;;; that restarts resumes from what KEEP last received (the state machine's
;;; `snapshot`, handed over after every change), or passes a larger EPOCH to
;;; its peer and starts over.

(define-module (playnet federation peer)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib cell)
  #:use-module (goblins actor-lib timers)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet federation async)
                #:select (make-peer message-link message-heading message-from message-to assemble-attestations))
  #:use-module ((playnet federation wire) #:select (signed-reply verify-signed make-key-ledger signer-of signer-aid))
  #:export (^commune-peer start-ticker! now-seconds
            ^attestation-fold
            wait-vow call-from-thread gather-attestations))

(define (now-seconds) (let ((t (gettimeofday))) (+ (car t) (/ (cdr t) 1e6))))

;; which end of a link a message concerns: the master's end is named `master`,
;; a participant's by its name, the one anonymous counterpart by #f
(define (to-whom m)                            ; where a message goes
  (if (eq? (message-heading m) 'master) 'master (let ((to (message-to m))) (if (eq? to 'other) #f to))))
(define (from-whom m)                          ; where one came from: the master names nobody
  (if (eq? (message-heading m) 'participant) 'master (message-from m)))

;; one end of a link: who is there, the reference, the AID it must speak under
(define-record-type <end>
  (make-end who ref aid)
  end?
  (who end-who) (ref end-ref) (aid end-aid set-end-aid!))

(define* (^commune-peer bcom peer identity #:key (name "commune") (clock now-seconds) (keep #f) (key-ledger #f))
  "A commune's peer behind a capability, speaking under IDENTITY (a signer of
   federation/wire — a keri-identity held here, or a scope that signs through
   its own methods). PEER is `make-peer` over the commune's own boundary oracle,
   built and held on this side; KEEP, when given, receives the peer's
   `snapshot` after every change. Methods:
     (tell ref)             REF hears this commune's signed attestation
                            (`hear text sig`) after every change
     (connect link who ref aid)
                            an end of LINK is REF (#f: expected, with nothing
                            to send to yet), speaking under AID (#f: take it
                            from its first message). WHO is who is there: #f
                            for the one counterpart of a two-party good; on a
                            good with several participants, the participant's
                            name as the master knows it, or `master` from a
                            participant's side. Connecting again replaces the
                            end.
     (start)                begin: publish the centres this commune masters
     (tick)                 the host's clock: what has waited past its deadline
     (ping t)               → T: a round trip
     (deadline) (deadline! s)
                            the seconds a master waits on a version; raised to S
     (deliver text sig)     a signed message from the far end of a link
     (snapshot)             the peer's state, what a restart resumes from
     (attest)               → signed: this commune's standing
     (refused)              → how many messages were refused"
  (define aid (signer-aid (signer-of identity)))
  (define ends (make-hash-table))                 ; link → (<end> …); who #f: the sole far end
  ;; the end for WHO on LINK, or the only one there is
  (define (entry link who)
    (let ((es (hash-ref ends link '())))
      (cond ((and who (find (lambda (e) (equal? (end-who e) who)) es)))
            ((and (pair? es) (null? (cdr es))) (car es))
            (else #f))))
  (define (connect! link who ref pinned)
    (hash-set! ends link (cons (make-end who ref pinned)
                               (remove (lambda (e) (equal? (end-who e) who)) (hash-ref ends link '())))))
  (define refused 0)
  ;; the key states read off the far ends' words: an AID seen rotated speaks with its log or not at all
  (define ledger (or key-ledger (make-key-ledger)))
  (define (say kvs) (signed-reply identity (cons (cons 'aid aid) kvs)))
  (define (attestation) (say `((attestation . ,(peer 'attest)))))
  ;; what is handed over when it has moved: the state to KEEP, the standing to TELL
  (define (hand-over what give)
    (let ((last #f))
      (lambda () (let ((now (peer what))) (unless (equal? now last) (set! last now) (give now))))))
  (define keep! (hand-over 'snapshot (or keep (lambda (s) #f))))
  (define tell #f)
  (define tell! (hand-over 'attest (lambda (a) (when tell (apply <-np tell 'hear (attestation))))))
  (define (changed! r) (keep!) (tell!) r)
  (define (send! msgs)
    (for-each
     (lambda (m)
       (let ((e (entry (message-link m) (to-whom m))))
         (when (and e (end-ref e)) (apply <-np (end-ref e) 'deliver (say m)))))
     msgs)
    'ok)
  (methods
   ((connect link who ref pinned) (connect! link who ref pinned) 'ok)
   ((tell ref) (set! tell ref) (set! tell! (hand-over 'attest (lambda (a) (apply <-np tell 'hear (attestation))))) (changed! 'ok))
   ((start) (changed! (send! (peer 'start (clock)))))
   ((tick) (changed! (send! (peer 'tick (clock)))))
   ((ping t) t)
   ((deadline) (peer 'deadline))
   ((deadline! s) (peer 'deadline! s))
   ((deliver text sig)
    ;; the signature checks under the AID the payload names, the payload is a
    ;; message for a link with an end for its sender, and that AID is the one
    ;; pinned on the end — a first contact pins it
    (catch #t
      (lambda ()
        (call-with-values (lambda () (verify-signed (list text sig) #f #:ledger ledger))
          (lambda (payload aid*)
            (let ((e (entry (message-link payload) (from-whom payload))))
              (unless e (error "federation-peer: a message for a link with no such end" (message-link payload)))
              (unless (member (end-aid e) (list #f aid*))
                (error "federation-peer: a message under another AID than the end's" aid*))
              (set-end-aid! e aid*)
              (changed! (send! (peer 'deliver payload (clock))))))))
      (lambda _ (set! refused (+ refused 1)) 'refused)))
   ((snapshot) (peer 'snapshot))
   ((attest) (attestation))
   ((refused) refused)))

;; ── the federation's standing, as its peers tell it ──────────────────────────
(define* (^attestation-fold bcom aids #:key (key-ledger #f))
  "A fold of the communes' attestations: it expects the AIDS given and those
   `expect`ed later, hears each commune's signed standing — told by the shell,
   or asked for — verified under an expected AID, and answers the certificate
   from the latest word of each. Methods:
     (expect aid)           → an AID whose word is heard
     (ping t)               → T: a round trip, as every far end answers
     (hear text sig)        → `heard`, `refused`
     (heard)                → ((aid . attestation) …), the latest of each
     (words)                → ((aid . n) …), how many words of each were heard
     (certificate [tol])    → the alist of `assemble-attestations` over them,
                            with `attestations` the payloads read"
  (define expected aids)
  (define ledger (or key-ledger (make-key-ledger)))  ; the key states read off the words heard
  (define latest '())                             ; (aid . attestation), the newest first
  (define words '())                              ; (aid . how many heard)
  (methods
   ((expect aid) (set! expected (lset-adjoin equal? expected aid)) 'ok)
   ((ping t) t)
   ((hear text sig)
    (catch #t
      (lambda ()
        (call-with-values (lambda () (verify-signed (list text sig) #f #:ledger ledger))
          (lambda (payload aid*)
            (unless (member aid* expected) (error "federation-peer: a word from an AID not expected" aid*))
            (set! latest (cons (cons aid* (assq-ref payload 'attestation))
                               (remove (lambda (p) (equal? (car p) aid*)) latest)))
            (set! words (cons (cons aid* (+ 1 (or (assoc-ref words aid*) 0)))
                              (remove (lambda (p) (equal? (car p) aid*)) words)))
            'heard)))
      (lambda _ 'refused)))
   ((heard) latest)
   ((words) words)
   ((certificate . tol)
    (let ((attests (map cdr latest)))
      (cons (cons 'attestations attests)
            (assemble-attestations attests #:tol (if (pair? tol) (car tol) 1e-3)))))))

;; ── the host's clock ─────────────────────────────────────────────────────────
;; an actor that wakes every SECONDS (Goblins' `timeout`, a promise — no
;; thread, nothing blocked) and ticks each ref, until told to stop
(define (^ticker bcom refs seconds)
  (define running (spawn ^cell #t))
  (define (wake!)
    (on (timeout seconds)
        (lambda _ (when ($ running) (for-each (lambda (r) (<-np r 'tick)) refs) (wake!)))))
  (wake!)
  (methods
   ((stop) ($ running #f) 'ok)))

(define (start-ticker! refs seconds)
  "Tick every one of REFS every SECONDS; in a turn of their vat. → the ticker,
   which `stop`s when told."
  (spawn ^ticker refs seconds))

;; ── from a plain thread ──────────────────────────────────────────────────────
(define (wait-vow vat vow)
  "VOW's value, waited for from a plain thread that is no vat's — a test's
   main thread; its handlers run in VAT. Raises when it breaks."
  (let ((mtx (make-mutex)) (cv (make-condition-variable)) (box #f))
    (define (put! v) (with-mutex mtx (set! box v) (signal-condition-variable cv)) 'done)
    (with-vat vat (on vow (lambda (r) (put! (cons 'ok r))) #:catch (lambda (e) (put! (cons 'err e)))))
    (let ((r (with-mutex mtx (let lp () (or box (begin (wait-condition-variable cv mtx) (lp)))))))
      (if (eq? (car r) 'ok) (cdr r) (error "federation-peer: the vow broke" (cdr r))))))

(define (call-from-thread vat ref method . args)
  "One question to REF, asked in VAT and waited for from a plain thread."
  (wait-vow vat (with-vat vat (apply <- ref method args))))

(define* (gather-attestations vat refs aids #:key (tol 1e-3))
  "The certificate from every peer's signed attestation, asked for from a
   plain thread and heard by a fold expecting AIDS: the fold's `certificate`."
  (let ((fold (with-vat vat (spawn ^attestation-fold aids))))
    (for-each (lambda (ref) (apply call-from-thread vat fold 'hear (call-from-thread vat ref 'attest))) refs)
    (call-from-thread vat fold 'certificate tol)))
