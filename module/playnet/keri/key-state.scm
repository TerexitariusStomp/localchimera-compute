;;; key-state.scm — which key speaks for an identifier, read off its key log.
;;;
;;; An identifier's AID names its INCEPTION. After a rotation the key that
;;; signs for it is another one, and what says so is the identifier's own key
;;; event log (KEL): an inception, rotations that each reveal a key committed
;;; to by the event before, interactions that anchor data. A verifier that holds
;;; the log reads the key in force from it — and needs no one's word, because
;;; the log is self-certifying: each event names its predecessor by SAID, each
;;; rotation reveals the key the last one committed to by digest, and each
;;; event is signed by the key in force when it was made.
;;;
;;; One reader, shared by every verifier that has to answer "is this signature
;;; this identifier's":
;;;
;;;   `check-rotation`   one rotation against the state before it (the browser
;;;                      citizen's signup, gateway/signup-agent.scm)
;;;   `events->states`   a whole log, event by event: the state after each
;;;   `events->key-state` the state after the last
;;;   `key-in-force-at`  the key in force when an event SEALED a SAID (an ixn
;;;                      anchoring a credential): a credential is signed by the
;;;                      key of its day, and stays that key's after a rotation
;;;
;;; A state is ((identifier . i) (sn . n) (key . qb64) (said . d) (next . digest)).
;;; Events are KEL entries as the stores keep them: an alist with the event
;;; under "icp", "rot" or "ixn" and its signatures under "sigs".

(define-module (playnet keri key-state)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet keri signify-portable)
                #:select (recompute-event-said event-first-key event-first-next-digest
                          event-sn next-key-digest scm->json-canonical))
  #:use-module ((playnet keri citizen-sig) #:select (verify-bytes-under-aid aid-prefix->pubkey))
  #:export (verify-sig-on-event check-rotation check-icp rotation-count
            events->states events->key-state key-in-force-at key-for-credential
            state-key state-sn state-said state-next))

(define (state-key s) (assq-ref s 'key))
(define (state-sn s) (assq-ref s 'sn))
(define (state-said s) (assq-ref s 'said))
(define (state-next s) (assq-ref s 'next))

(define (verify-sig-on-event pubkey-qb64 event-alist sig-qb64)
  "#t when SIG-QB64 verifies over the canonical JSON of EVENT-ALIST under
   PUBKEY-QB64 (a D/B-prefix key), else a descriptive error string — so a caller
   can fold the verdict into its own."
  (cond
   ((verify-bytes-under-aid (string->utf8 (scm->json-canonical event-alist))
                            sig-qb64 pubkey-qb64)
    #t)
   (else "signature does not verify under decoded pubkey")))

(define (rotation-count entries)
  "How many rotations the log ENTRIES holds: the depth a restart derives its keys at."
  (length (filter (lambda (e) (assoc-ref e "rot")) entries)))

(define (sig0 sigs)
  (cond ((vector? sigs) (and (positive? (vector-length sigs)) (vector-ref sigs 0)))
        ((pair? sigs) (car sigs))
        (else #f)))

(define (key-digest-of qb64)
  (catch #t (lambda () (next-key-digest (aid-prefix->pubkey qb64))) (lambda _ #f)))

(define (check-rotation identifier prior rot-alist sigs)
  "#t when ROT-ALIST is a valid rotation of IDENTIFIER after the state PRIOR
   (anything with `sn`, `said` and `next` — a state, or what a store's last
   entry reads as), else an error string. Checks:
     a) rot.t = 'rot' and rot.i = IDENTIFIER
     b) rot.s is exactly prior.s + 1
     c) rot.p == prior SAID
     d) the recomputed SAID of rot == rot.d
     e) the key rot.k[0] reveals hashes to the digest prior committed to
     f) the first signature verifies under that revealed key over the event"
  (let ((t  (assoc-ref rot-alist "t"))
        (i  (assoc-ref rot-alist "i"))
        (p  (assoc-ref rot-alist "p"))
        (d  (assoc-ref rot-alist "d"))
        (k0 (event-first-key rot-alist)))
    (cond
     ((not (and (string? t) (string=? t "rot"))) "rot.t must be 'rot'")
     ((not (equal? identifier i)) "rot.i must equal the AID prefix")
     ((not (and (string? d) (= 44 (string-length d)))) "rot.d must be a 44-char SAID")
     ((not (= (+ 1 (state-sn prior)) (event-sn rot-alist)))
      (string-append "rot.s expected " (number->string (+ 1 (state-sn prior)) 16)
                     " got " (number->string (event-sn rot-alist) 16)))
     ((not (equal? (state-said prior) p)) "rot.p does not match prior event's SAID")
     ((not (string=? (recompute-event-said rot-alist) d)) "rot.d does not match recomputed SAID")
     ((not (and (string? k0) (= 44 (string-length k0)))) "rot.k[0] must be a 44-char qb64 D-prefix")
     ((not (let ((digest (key-digest-of k0)) (committed (state-next prior)))
             (and digest (string? committed) (string=? committed digest))))
      "revealed key does not hash to prior next-key digest")
     (else (verify-sig-on-event k0 rot-alist (sig0 sigs))))))

(define (check-ixn identifier prior key ixn-alist sigs)
  (let ((t (assoc-ref ixn-alist "t")) (i (assoc-ref ixn-alist "i"))
        (p (assoc-ref ixn-alist "p")) (d (assoc-ref ixn-alist "d")))
    (cond
     ((not (and (string? t) (string=? t "ixn"))) "ixn.t must be 'ixn'")
     ((not (equal? identifier i)) "ixn.i must equal the identifier")
     ((not (= (+ 1 (state-sn prior)) (event-sn ixn-alist))) "ixn.s is not the next sequence number")
     ((not (equal? (state-said prior) p)) "ixn.p does not match prior event's SAID")
     ((not (and (string? d) (string=? (recompute-event-said ixn-alist) d))) "ixn.d does not match recomputed SAID")
     (else (verify-sig-on-event key ixn-alist (sig0 sigs))))))

(define (check-icp aid icp-alist sigs)
  "#t when ICP-ALIST is a valid inception that AID names: the AID is its
   identifier (self-addressing: i = d) or the inception key itself (the D
   prefix a scope is known by), signed by that key."
  (let ((k0 (event-first-key icp-alist)) (d (assoc-ref icp-alist "d")) (i (assoc-ref icp-alist "i")))
    (cond
     ((not (and (string? k0) (= 44 (string-length k0)))) "icp.k[0] must be a 44-char qb64 key")
     ((not (and (string? d) (string? i))) "icp.d and icp.i must be strings")
     ((not (or (equal? aid i) (equal? aid k0))) "the log is not this AID's")
     ((not (or (string=? i d) (string=? i k0))) "icp.i is neither self-addressing nor the inception key")
     ((not (string=? (recompute-event-said icp-alist) d)) "icp.d does not match recomputed SAID")
     (else (verify-sig-on-event k0 icp-alist (sig0 sigs))))))

(define (anchored-saids event)
  "The SAIDs EVENT seals: the `d` of every seal in its `a` block."
  (let ((a (assoc-ref event "a")))
    (filter-map (lambda (seal) (and (pair? seal) (assoc-ref seal "d")))
                (cond ((vector? a) (vector->list a)) ((list? a) a) (else '())))))

(define (inception-state icp)
  `((identifier . ,(assoc-ref icp "i")) (sn . 0) (key . ,(event-first-key icp))
    (said . ,(assoc-ref icp "d")) (next . ,(event-first-next-digest icp))))

(define (step identifier state entry)
  "The state after ENTRY (a rotation or an interaction) and the SAIDs it seals,
   as (state . sealed); or an error string."
  (let ((rot (assoc-ref entry "rot")) (ixn (assoc-ref entry "ixn")) (sigs (assoc-ref entry "sigs")))
    (cond
     (rot
      (let ((v (check-rotation identifier state rot sigs)))
        (if (eq? v #t)
            (cons `((identifier . ,identifier) (sn . ,(event-sn rot)) (key . ,(event-first-key rot))
                    (said . ,(assoc-ref rot "d")) (next . ,(event-first-next-digest rot)))
                  (anchored-saids rot))
            v)))
     (ixn
      (let ((v (check-ixn identifier state (state-key state) ixn sigs)))
        (if (eq? v #t)
            (cons `((identifier . ,identifier) (sn . ,(event-sn ixn)) (key . ,(state-key state))
                    (said . ,(assoc-ref ixn "d")) (next . ,(state-next state)))
                  (anchored-saids ixn))
            v)))
     (else "an event that is neither a rotation nor an interaction"))))

(define (events->states aid entries)
  "The states of the log ENTRIES for AID, one per event, in order: a list of
   (state . sealed-saids), or an error string at the first event that does not
   verify. AID is the identifier the log is of, or its inception key."
  (let* ((icp (and (pair? entries) (assoc-ref (car entries) "icp")))
         (verdict (cond ((null? entries) "the log is empty")
                        ((not icp) "the log does not begin with an inception")
                        (else (check-icp aid icp (assoc-ref (car entries) "sigs"))))))
    (if (not (eq? verdict #t))
        verdict
        (let ((i (assoc-ref icp "i")))
          (let loop ((rest (cdr entries)) (state (inception-state icp))
                     (acc (list (cons (inception-state icp) (anchored-saids icp)))))
            (if (null? rest)
                (reverse acc)
                (let ((r (step i state (car rest))))
                  (if (string? r)
                      r
                      (loop (cdr rest) (car r) (cons r acc))))))))))

(define (events->key-state aid entries)
  "The state after the last of ENTRIES, or an error string."
  (let ((states (events->states aid entries)))
    (if (string? states) states (car (last states)))))

(define (key-for-credential aid entries said)
  "The key a credential SAID by AID is checked under: the key in force when the
   log sealed it, or — a credential the log never sealed — the key in force now.
   Raises when the log does not verify."
  (or (key-in-force-at aid entries said)
      (let ((state (events->key-state aid entries)))
        (when (string? state) (error "key-for-credential: the key log does not verify" aid state))
        (state-key state))))

(define (key-in-force-at aid entries said)
  "The key in force when an event of ENTRIES sealed SAID: the key of the state
   at the first event that anchors it. #f when no event does (the credential was
   never sealed). Raises when the log does not verify."
  (let ((states (events->states aid entries)))
    (when (string? states) (error "key-in-force-at: the key log does not verify" aid states))
    (let ((hit (find (lambda (s) (member said (cdr s))) states)))
      (and hit (state-key (car hit))))))
