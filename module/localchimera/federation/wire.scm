;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/wire.scm — the federated solve across a vat boundary: a commune
;;; as an actor that answers the boundary oracle's questions under its own AID,
;;; and the coordinator that runs the consensus loop over such actors, near or
;;; far, verifying every reply.
;;;
;;; Rung 3 of docs/planning/federation/FEDERATED-SOLVE.md. The economics are the engine's
;;; (solve/federation-oracle.scm: `make-boundary-oracle`, `solve-consensus`); this
;;; module is the wire — Goblins messages and KERI signatures, nothing else.
;;;
;;; WHAT CROSSES. Into a commune, per round: a prox centre per crossing good (the
;;; agreed flow less the commune's scaled dual — the pull the coordinator has
;;; settled on for that column) and the weight ρ. Out of it: the flow it puts
;;; on each crossing good and its fill percentage. At the finish, the same shape
;;; once more with the converged pulls, and a cap per flow that draws. A commune's
;;; forms, columns, records and plan stay in its own vat; the coordinator's
;;; reports carry flows and a certificate, never a plan.
;;;
;;; WHO SAID IT. Every reply is the s-expression text of its payload and an
;;; Ed25519 signature over that text under the commune's KERI AID (citizen-sig
;;; `sign-bytes-under-aid`, the same primitive that signs a credential SAID).
;;; The payload carries the round id the coordinator minted — a nonce and a
;;; counter — so a reply answers one question once. The coordinator verifies
;;; before it reads: a reply whose signature does not check under the AID the
;;; caller expects, or whose round id is not the one asked, breaks the solve
;;; rather than entering it. A fork of this codebase that lies about its stock
;;; or its demand can still lie — dual decomposition pulls what a scope ASKS,
;;; and asking is the scope's own business — but it lies under its own name,
;;; and no third party can put words in its mouth.
;;;
;;; The AID a commune answers under is pinned at `hello`: given by the caller
;;; when known out of band (the membership credential names it), otherwise
;;; taken from the first signed reply and held for the rest of the solve.

(define-module (localchimera federation wire)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib joiners)
  #:use-module (ice-9 threads)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module ((localchimera solve federation-oracle) #:select (make-boundary-oracle solve-consensus))
  #:use-module ((localchimera keri citizen-sig)
                #:select (keri-identity-aid keri-identity-keypair
                          sign-bytes-under-aid verify-bytes-under-aid verify-said-signature-under-key))
  #:use-module ((localchimera keri key-state) #:select (events->key-state state-key state-sn state-said rotation-count))
  #:use-module ((localchimera keri crypto-primitives) #:select (keri-crypto-random-bytes))
  ;; installs the server crypto backend at load
  #:use-module (localchimera keri signify)
  #:export (^commune-solver
            federated-solve-wire
            make-signer signer? signer-aid signer-sign signer-kel signer-of
            make-key-ledger key-ledger? signer-rotated-kel
            signed-reply verify-signed verify-signed-reply))

;; ── who signs ────────────────────────────────────────────────────────────────
;; A SIGNER is an AID and a procedure that signs a string's UTF-8 bytes under
;; it: a keri-identity held here, or a scope actor that signs through its
;; `sign-said` and keeps its key to itself. A signer whose key has rotated
;; also has a KEL, a thunk of its key event log: the key that signs for its AID
;; is the one the log says is in force, so every word it speaks carries the log
;; (`signed-reply`) and a verifier that holds nothing but the AID reads the key
;; off it (`verify-signed`; keri/key-state.scm).
(define-record-type <signer>
  (%make-signer aid sign kel)
  signer?
  (aid signer-aid) (sign signer-sign) (kel signer-kel))

(define* (make-signer aid sign #:optional (kel #f))
  (%make-signer aid sign kel))

(define (signer-of who)
  "WHO as a signer: a signer as it is, a keri-identity by its keypair."
  (if (signer? who)
      who
      (make-signer (keri-identity-aid who)
                   (lambda (text) (sign-bytes-under-aid (string->utf8 text) (keri-identity-keypair who))))))

;; ── the key state a verifier has seen ────────────────────────────────────────
;; A LEDGER keeps, per AID, the latest key state a verifier has READ off a log:
;; once an AID is seen to have rotated, the key its inception named speaks for
;; it no more — a word from it that carries no log, or a shorter one, is refused
;; rather than read under the key the AID started with. A ledger can be KEPT:
;; each state read is handed to a keeper (the whole ledger, ((aid . state) …)),
;; and a restart RESUMEs from what was kept, so a retired key stays retired.
(define-record-type <key-ledger>
  (%make-key-ledger table keep)
  key-ledger?
  (table ledger-table)
  (keep ledger-keep))

(define* (make-key-ledger #:key (resume '()) (keep #f))
  (let ((table (make-hash-table)))
    (for-each (lambda (p) (hash-set! table (car p) (cdr p))) resume)
    (%make-key-ledger table keep)))

(define (ledger-ref ledger aid) (hash-ref (ledger-table ledger) aid #f))

(define (ledger-pin! ledger aid state)
  (hash-set! (ledger-table ledger) aid state)
  (when (ledger-keep ledger)
    ((ledger-keep ledger) (hash-map->list cons (ledger-table ledger)))))

(define (essential-kel entries)
  "ENTRIES (a key event log as a store keeps it) reduced to what a verifier
   needs: each event and its signatures."
  (map (lambda (e)
         (filter (lambda (kv) (member (car kv) '("icp" "rot" "ixn" "sigs"))) e))
       entries))

(define (rotated? entries) (> (rotation-count entries) 0))

(define (signer-rotated-kel who)
  "WHO's key event log, reduced to what a verifier reads, when its key has
   rotated; #f otherwise (the AID alone says which key speaks)."
  (let* ((s (signer-of who))
         (entries (and (signer-kel s) ((signer-kel s)))))
    (and (pair? entries) (rotated? entries) (essential-kel entries))))

;; ── signed replies ───────────────────────────────────────────────────────────
(define (signed-reply who payload)
  "PAYLOAD (an alist of atoms and lists) → (text sig): the payload's written
   form and a CESR qb64 Ed25519 signature over its UTF-8 bytes under WHO (a
   signer, or a keri-identity). A signer whose key has rotated adds its log as
   `kel`, inside the signed text."
  (let* ((s (signer-of who))
         (kel (signer-rotated-kel s))
         (payload (if kel (append payload `((kel . ,kel))) payload))
         (text (object->string payload)))
    (list text ((signer-sign s) text))))

(define* (verify-signed reply aid #:key (ledger #f))
  "The payload of REPLY, once its signature checks under AID. Raises otherwise
   — words that cannot be attributed never enter the solve. AID #f verifies
   against the AID the payload itself names (the first-contact pin); the AID
   used is returned as a second value.

   The key that signs for an AID is the one its key log says is in force. A
   payload that carries its log (`kel`) is read against it: the log must verify
   from the inception the AID names, and the signature must check under the key
   it leaves in force — the inception key no longer speaks once the log has
   rotated. LEDGER, when given, remembers the latest state read per AID and
   refuses a later word from an AID seen rotated that does not carry a log at
   least as far on."
  (unless (and (list? reply) (= 2 (length reply)) (string? (car reply)) (string? (cadr reply)))
    (error "federation-wire: malformed reply" reply))
  (let* ((text (car reply)) (sig (cadr reply))
         (payload (catch #t (lambda () (call-with-input-string text read))
                    (lambda _ (error "federation-wire: unreadable reply" text))))
         (aid* (or aid (and (list? payload) (assq-ref payload 'aid))))
         (kel (and (list? payload) (assq-ref payload 'kel)))
         (seen (and ledger (string? aid*) (ledger-ref ledger aid*))))
    (unless (string? aid*) (error "federation-wire: reply names no AID" text))
    (cond
     ((pair? kel)
      (let ((state (events->key-state aid* kel)))
        (when (string? state) (error "federation-wire: the key log does not verify" aid* state))
        (when (and seen (< (state-sn state) (state-sn seen)))
          (error "federation-wire: a key log behind the one already read" aid*))
        (when (and seen (= (state-sn state) (state-sn seen)) (not (equal? (state-said state) (state-said seen))))
          (error "federation-wire: a key log that forks the one already read" aid*))
        (unless (verify-said-signature-under-key text sig (state-key state))
          (error "federation-wire: signature does not verify under the key in force" aid*))
        (when ledger (ledger-pin! ledger aid* state))))
     ((and seen (> (state-sn seen) 0))
      (error "federation-wire: an AID seen rotated speaks without its key log" aid*))
     (else
      (unless (verify-bytes-under-aid (string->utf8 text) sig aid*)
        (error "federation-wire: signature does not verify under" aid*))))
    (values payload aid*)))

(define (verify-signed-reply reply aid rid)
  "As `verify-signed`, and the payload must answer round RID — one question,
   one answer."
  (call-with-values (lambda () (verify-signed reply aid))
    (lambda (payload aid*)
      (unless (equal? (assq-ref payload 'rid) rid)
        (error "federation-wire: reply answers a different round" (assq-ref payload 'rid) rid))
      (values payload aid*))))

;; ── the commune, as an actor ─────────────────────────────────────────────────
(define* (^commune-solver bcom oracle identity #:key (name "commune"))
  "A commune's boundary oracle behind a capability, answering under IDENTITY
   (a keri-identity). ORACLE is `make-boundary-oracle` over the commune's own
   scope-record, built and held on this side. Methods take the coordinator's
   round id first and return signed replies:
     (hello rid)                → aid name links
     (round rid centres rho)    → flows met
     (refine rid z pulls rho)  → flows met feasible? gap-bound refined?
     (clamp rid caps)           → flows met feasible? gap-bound clamped?"
  (define aid (signer-aid (signer-of identity)))
  (define (reply rid kvs) (signed-reply identity (cons (cons 'rid rid) kvs)))
  (methods
   ((hello rid)
    (reply rid `((aid . ,aid) (name . ,name) (links . ,(oracle 'links)))))
   ((round rid centres rho)
    (reply rid (oracle 'solve! centres rho)))
   ((refine rid z pulls rho)
    (reply rid (oracle 'refine! z pulls rho)))
   ((clamp rid caps)
    (reply rid (oracle 'clamp! caps)))))

;; ── the coordinator ──────────────────────────────────────────────────────────
(define (bytes->hex bv)
  (string-concatenate (map (lambda (i) (format #f "~2,'0x" (bytevector-u8-ref bv i)))
                           (iota (bytevector-length bv)))))

(define (deadline->abstime seconds)
  "The absolute (secs . usecs) SECONDS from now."
  (let* ((now (gettimeofday))
         (us (+ (cdr now) (inexact->exact (round (* seconds 1e6)))))
         (secs (+ (car now) (quotient us 1000000))))
    (cons secs (remainder us 1000000))))

(define (list-set-at lst i v)
  (map (lambda (x j) (if (= i j) v x)) lst (iota (length lst))))

(define* (federated-solve-wire vat communes
                               #:key (aids #f) (finish? #t)
                                     (rho 4.0) (iters 120) (tol 1e-4) (alpha 1.6)
                                     (accel #t) (mmax 8) (met-eps 0.05) (met-stall 3)
                                     (z0 '()) (deadline #f) (max-stale 5))
  "The federated solve over COMMUNES — refs to ^commune-solver actors, near or
   far — messaged from VAT. AIDS, when given, is the AID each commune must
   answer under, aligned with COMMUNES; absent, each is pinned from its hello.
   DEADLINE, in seconds, bounds each round's wait: a commune that has not
   answered by then sits the round out and the solve carries its last reply
   (`solve-consensus`, MAX-STALE). Absent, every round waits for every commune.
   Blocks per round on the replies, so call it from a plain thread — the main
   thread, or one of its own — never from inside a vat turn or a fiber.
   Returns (values reports met rounds pulls) as solve-consensus does, each
   report carrying the commune's (aid . …) and (name . …)."
  (define nonce (bytes->hex (keri-crypto-random-bytes 8)))
  (define counter 0)
  (define pinned (or aids (map (lambda (_) #f) communes)))
  (define (rid!) (set! counter (+ counter 1)) (format #f "~a:~a" nonce counter))
  ;; one question to every commune: fan out in VAT's turn, block here until each
  ;; has answered or the deadline has passed. A late reply lands in a box
  ;; nobody reads any more, so it can never be taken for a later round's.
  ;; The wait is a mutex and a condition variable, never a fibers channel: the
  ;; callbacks run inside a vat turn and must not suspend the vat's fiber, and
  ;; the caller is a plain thread that has no fiber to suspend.
  ;; → per commune its verified payload, or #f for one that is absent: past
  ;; the deadline, or (with a deadline set) unreachable. A reply that fails
  ;; its signature is not an absence; it raises.
  (define (ask method args-per-commune)
    (let* ((n (length communes)) (rid (rid!))
           (mtx (make-mutex)) (cv (make-condition-variable))
           (slots (make-vector n #f)) (left n)
           (due (and deadline (deadline->abstime deadline))))
      (define (settle! i v)
        (with-mutex mtx
          (unless (vector-ref slots i)
            (vector-set! slots i v) (set! left (- left 1))
            (signal-condition-variable cv)))
        'done)
      (with-vat vat
        (for-each (lambda (c args i)
                    (on (apply <- c method rid args)
                        (lambda (r) (settle! i (cons 'ok r)))
                        #:catch (lambda (e) (settle! i (cons 'err e)))))
                  communes args-per-commune (iota n)))
      (with-mutex mtx
        (let lp ()
          (when (and (> left 0)
                     (if due (wait-condition-variable cv mtx due)
                         (begin (wait-condition-variable cv mtx) #t)))
            (lp))))
      (let ((got (with-mutex mtx (vector->list slots))))
        (map (lambda (slot i)
               (cond ((and slot (eq? (car slot) 'ok))
                      (call-with-values
                          (lambda () (verify-signed-reply (cdr slot) (list-ref pinned i) rid))
                        (lambda (payload aid)
                          (set! pinned (list-set-at pinned i aid))
                          payload)))
                     ((and slot (not due))
                      (error "federated-solve-wire: a commune did not answer" (cdr slot)))
                     (else #f)))
             got (iota n)))))
  ;; the questions every commune must answer: hello and the finish
  (define (ask-all method args-per-commune)
    (let ((replies (ask method args-per-commune)))
      (unless (every values replies)
        (error "federated-solve-wire: a commune did not answer in time" method))
      replies))
  (let* ((hellos (ask-all 'hello (map (lambda (_) '()) communes)))
         (link-tables (map (lambda (h) (assq-ref h 'links)) hellos)))
    (call-with-values
        (lambda ()
          (solve-consensus
           link-tables
           (lambda (centres rho*) (ask 'round (map (lambda (c) (list c rho*)) centres)))
           #:finish! (and finish?
                          (lambda (phase args rho*)
                            (case phase
                              ((refine) (ask-all 'refine (map (lambda (a) (list (car a) (cadr a) rho*)) args)))
                              ((clamp)  (ask-all 'clamp (map list args)))
                              (else (error "federated-solve-wire: unknown finish phase" phase)))))
           #:rho rho #:iters iters #:tol tol #:alpha alpha #:accel accel #:mmax mmax
           #:met-eps met-eps #:met-stall met-stall #:z0 z0 #:max-stale max-stale))
      (lambda (reports met rounds pulls)
        (values (map (lambda (r aid h) (cons (cons 'aid aid) (cons (cons 'name (assq-ref h 'name)) r)))
                     reports pinned hellos)
                met rounds pulls)))))
