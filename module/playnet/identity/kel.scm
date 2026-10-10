;;; module/playnet/identity/kel.scm — the key log in hand
;;;
;;; A person's KERI key event log as the browser keeps it, and the passcode
;;; that opens it: the accessors over the stored shape, a passcode's chain of
;;; keys and where that chain begins in a log, the log's own verification
;;; (the same checks the gateway's reader makes, keri/key-state.scm), the key
;;; a card is sealed to, and the rotation that retires the identity. Every
;;; procedure here is pure over a KEL value — no global, no storage, no
;;; network — so Guile tests it natively (tests/identity/test-kel-in-hand.scm)
;;; and Hoot bundles it into browser/day-boot.wasm, where hoot/day-boot.scm
;;; keeps the stateful half: loading and saving the log, the seat, the sends.
;;;
;;; The stored shape, also the recovery file:
;;;   {"icp": <event>, "sigs": [..], "rotations": [{"rot": <event>, "sigs": [..]}, …]}
;;; Field order inside an event is the event: SAID and signature are both
;;; over the serialized bytes, so the store round-trips through
;;; scm->json-canonical / json-read-ordered and nothing else.

(define-module (playnet identity kel)
  #:use-module ((srfi srfi-1) #:select (last))
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-ed25519-verify ed25519-keypair-public))
  #:use-module ((playnet keri signify-portable)
                #:select (bran->signing-keypair bran->rotation-keypair
                          public-key->aid-prefix next-key-digest build-rot
                          event-sn event-first-next-digest event-first-key
                          sign-event scm->json-canonical recompute-event-said))
  #:use-module ((playnet keri reticulum-binding) #:select (kel-reticulum-pub))
  #:use-module ((playnet keri cesr) #:select (cesr-qb64->bytes))
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module ((playnet wire rows) #:select (alist-ref))
  #:export (kel-icp kel-aid kel-k0 kel-rotations kel-depth kel-last-event
            make-kel entry->kel kel-well-formed? kel-events
            passcode-keypair keypair-key passcode-base kel-current-keypair
            passcode-opens?
            signed-by? said-holds? inception-verifies? rotations-verify? kel-verifies?
            anchored-key-hex receipt->json retirement-rotation))

(define (kel-icp kel)       (and (pair? kel) (assoc-ref kel "icp")))
(define (kel-aid kel)       (let ((icp (kel-icp kel))) (and (pair? icp) (assoc-ref icp "i"))))
(define (kel-k0 kel)        (let ((icp (kel-icp kel))) (and (pair? icp) (event-first-key icp))))
(define (kel-rotations kel)
  ;; as a list of (rot . sigs), sn order — the shape the wire carries
  (let ((v (and (pair? kel) (assoc-ref kel "rotations"))))
    (if (vector? v)
        (map (lambda (r) (cons (assoc-ref r "rot") (assoc-ref r "sigs")))
             (vector->list v))
        '())))
(define (kel-depth kel) (length (kel-rotations kel)))
(define (kel-last-event kel)
  (let ((rots (kel-rotations kel)))
    (if (null? rots) (kel-icp kel) (car (last rots)))))

(define (make-kel icp sigs rotations)
  `(("icp" . ,icp) ("sigs" . ,sigs)
    ("rotations" . ,(list->vector
                     (map (lambda (r) `(("rot" . ,(car r)) ("sigs" . ,(cdr r))))
                          rotations)))))

;; a server entry (fetch-icp) as a KEL — how a device that signed up
;; before the browser kept its log comes to hold one
(define (entry->kel entry)
  (make-kel (alist-ref entry 'icp) (alist-ref entry 'sigs)
            (let ((rots (alist-ref entry 'rotations)))
              (if (pair? rots) rots '()))))

(define (kel-well-formed? kel)
  (and (pair? kel)
       (string? (kel-aid kel)) (string? (kel-k0 kel))
       (vector? (assoc-ref kel "sigs"))
       (vector? (assoc-ref kel "rotations"))))


;; A passcode's own chain of keys: index 0 is the first key it derives,
;; index n the n-th after it.
(define (passcode-keypair bran n)
  (if (zero? n) (bran->signing-keypair bran) (bran->rotation-keypair bran n)))
(define (keypair-key kp) (public-key->aid-prefix (ed25519-keypair-public kp)))

;; the log's events in order, inception first
(define (kel-events kel) (cons (kel-icp kel) (map car (kel-rotations kel))))

;; Where a passcode's chain begins in a log: the sequence number of the event
;; that carries the passcode's first key. The inception, for the passcode the
;; identity was made with; a rotation, for a passcode it was changed to
;; (change-passcode! below). #f when the log carries that key nowhere.
(define (passcode-base kel bran)
  (let ((first (keypair-key (passcode-keypair bran 0))))
    (let loop ((es (kel-events kel)) (sn 0) (found #f))
      (if (null? es)
          found
          (loop (cdr es) (+ sn 1)
                (if (equal? first (event-first-key (car es))) sn found))))))

;; the key that signs right now: as far into the passcode's chain as the log
;; has moved since that chain began
(define (kel-current-keypair kel bran)
  (let ((base (passcode-base kel bran)))
    (and base (passcode-keypair bran (- (kel-depth kel) base)))))

;; a passcode opens a log when the key it derives for the log's present
;; depth is the key in force
(define (passcode-opens? kel bran)
  (let ((kp (kel-current-keypair kel bran)))
    (and kp (equal? (keypair-key kp) (event-first-key (kel-last-event kel))))))

;; ── the log verifies itself ──
;; The same checks the gateway's reader makes (keri/key-state.scm), made here
;; on a log the gateway hands over: an inception whose identifier is its own
;; digest (or its key) and which its key signed; rotations that each name
;; their predecessor, reveal the key the predecessor committed to, and are
;; signed by that key. A log that passes is the identifier's own whoever
;; served it — nobody else holds the keys it was signed with.
(define (signed-by? key event sigs)
  (let ((sig (cond ((and (vector? sigs) (positive? (vector-length sigs))) (vector-ref sigs 0))
                   ((pair? sigs) (car sigs))
                   (else #f))))
    (and (string? key) (string? sig) (pair? event)
         (with-exception-handler (lambda (e) #f)
           (lambda ()
             (and (keri-crypto-ed25519-verify
                   (cesr-qb64->bytes key)
                   (string->utf8 (scm->json-canonical event))
                   (cesr-qb64->bytes sig))
                  #t))
           #:unwind? #t))))
(define (said-holds? event)
  (let ((d (assoc-ref event "d")))
    (and (string? d)
         (equal? d (with-exception-handler (lambda (e) #f)
                     (lambda () (recompute-event-said event)) #:unwind? #t)))))
(define (inception-verifies? kel)
  (let* ((icp (kel-icp kel))
         (i   (and (pair? icp) (assoc-ref icp "i")))
         (k0  (and (pair? icp) (event-first-key icp))))
    (and (string? i) (string? k0)
         (or (string=? i k0)
             (and (equal? i (assoc-ref icp "d")) (said-holds? icp)))
         (signed-by? k0 icp (assoc-ref kel "sigs")))))
;; ROTS, (rot . sigs) in order, continue the log of AID from the event PRIOR
(define (rotations-verify? aid prior rots)
  (let loop ((prior prior) (rs rots))
    (or (null? rs)
        (let* ((rot  (car (car rs)))
               (sigs (cdr (car rs)))
               (k    (and (pair? rot) (event-first-key rot))))
          (and (pair? rot) (string? k)
               (equal? "rot" (assoc-ref rot "t"))
               (equal? aid (assoc-ref rot "i"))
               (equal? (assoc-ref prior "d") (assoc-ref rot "p"))
               (= (event-sn rot) (+ 1 (event-sn prior)))
               (said-holds? rot)
               (equal? (event-first-next-digest prior)
                       (with-exception-handler (lambda (e) #f)
                         (lambda () (next-key-digest (cesr-qb64->bytes k))) #:unwind? #t))
               (signed-by? k rot sigs)
               (loop rot (cdr rs)))))))
(define (kel-verifies? kel)
  (and (kel-well-formed? kel)
       (inception-verifies? kel)
       (rotations-verify? (kel-aid kel) (kel-icp kel) (kel-rotations kel))))

;; ── the key a card is sealed to ──
(define (anchored-key-hex entry aid)
  ;; the LATEST key the log anchors: a passcode change anchors a new one
  (let ((kel (and (pair? entry) (entry->kel entry))))
    (and kel
         (equal? aid (kel-aid kel))
         (kel-verifies? kel)
         (let ((pub (kel-reticulum-pub (kel-events kel))))
           (and pub (bv->hex pub))))))

;; ── the forget receipt, as the page reads it ──
(define (receipt->json r)
  (scm->json-canonical
   `(("dropped" . ,(map (lambda (kv) (cons (symbol->string (car kv)) (cdr kv)))
                        (or (alist-ref r 'dropped) '())))
     ("kept" . ,(list->vector (map symbol->string (or (alist-ref r 'kept) '())))))))


;; ── retiring the identity ──
;; The rotation that closes the log for good: it reveals the key the last
;; event committed to and commits to NO next key (`n: []`, `nt: 0`) — the
;; KERI abandonment, after which the reader (keri/key-state.scm
;; check-rotation) refuses every later rotation, so no recovery and no
;; takeover; the revealed key still signs, so the retirement itself and any
;; last receipt are the person's. Returns the rotations with the terminal one
;; appended, and the closed log ready to keep.
(define (retirement-rotation kel bran)
  (let* ((aid   (kel-aid kel))
         (depth (kel-depth kel))
         (kp    (passcode-keypair bran (+ 1 (- depth (passcode-base kel bran)))))
         (prior (kel-last-event kel)))
    (call-with-values
     (lambda ()
       (build-rot aid (assoc-ref prior "d")
                  #:keys (list (keypair-key kp)) #:nkeys '() #:nsith 0
                  #:sn (+ depth 1)))
     (lambda (json _said rot)
       (let ((rots (append (kel-rotations kel)
                           (list (cons rot (vector (sign-event json kp)))))))
         (values rots (make-kel (kel-icp kel) (assoc-ref kel "sigs") rots)))))))
