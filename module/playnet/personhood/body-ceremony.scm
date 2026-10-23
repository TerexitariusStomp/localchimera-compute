;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; personhood/body-ceremony.scm — a body's AID: the k-of-n group of its stewards' dial AIDs
;;;
;;; STAGING beside the identity core (codebase-organization.md §7): a body is
;;; its VF records, and this module's route is stated here. On close it
;;; writes exactly two things — a KEL into the oobi-host (the body's own
;;; inception, later its rotations) and, through the `close!` thunk the
;;; caller supplies, the VF records the planner side keeps (make-body and
;;; the steward relationships, (playnet legal bodies)). It holds no
;;; store of its own: a ceremony's durable record under <witness-dir> is
;;; the ask's own self, as an enrollment's is.
;;;
;;; The ritual. A steward declares a body and names its custodian-stewards;
;;; each steward is a dial AID with a KEL the oobi-host holds. The ceremony
;;; builds ONE inception from their keys — `k` = each steward's current key
;;; in roster order, `n` = each steward's committed next-key digest, `kt` =
;;; `nt` = k — and its SAID is the body's AID. Each steward signs the
;;; inception from their own browser; at k signatures the ceremony orders
;;; them by member index, verifies the whole log with the one key-log
;;; reader every verifier shares (keri/key-state.scm `events->states`, the
;;; threshold-aware one) and lands it in the oobi-host, then calls `close!`
;;; with the body's AID. A steward's signature IS their
;;; acceptance: there is no separate accept step.
;;;
;;; What a steward signs: the canonical JSON of the event (`json` in the
;;; preimage), as every KEL signature is made. The browser signs those
;;; bytes as itself (a bare `0B` signature, `sign-as-self!`) or already
;;; indexed (`sign-event/indexed`); the ceremony verifies the bytes under
;;; the steward's current key and emits the signature at the steward's
;;; member index, the form the threshold reader (keri/key-state.scm
;;; `check-sigs/threshold`) reads.
;;;
;;; Rotation and the pre-rotation constraint. `rotate cuts adds k2` builds
;;; the rotation from the body's standing state: `k` = the continuing
;;; stewards' current keys, `n` = the next-key digests of the continuing
;;; and the added stewards, `kt` = `nt` = k2, `br`/`ba` = the cut and added
;;; steward AIDs (build-rot's #:cuts/#:adds), and opens a second collection
;;; on the same `sign` path, signed by k2 continuing stewards. KERI reveals
;;; at a rotation only keys the prior event committed to, so a continuing
;;; steward's revealed key is their committed next key: EACH CONTINUING
;;; STEWARD ROTATES THEIR DIAL AID FIRST, and an added steward's key is
;;; committed by this rotation and revealed — signed from — by the one
;;; after it.
;;;
;;; The collector is this module's own: `^attestation-ceremony`
;;; (personhood/attestation-ceremony.scm) verifies a `0B` signature over a
;;; statement SAID under the witness's AID, and a KEL signature is over the
;;; event's bytes at a member index, so its `attest` hook does not fit; the
;;; shape (collecting → published, eligible?, duplicates refused, a durable
;;; record rewritten on every transition) is copied from it.
;;;
;;; KERIA path. With `#:create-group` (a thunk over
;;; `governance-create-group!`, keri/inception.scm) the stewards are
;;; KERIA-managed names: the thunk makes the group AID and the ceremony
;;; closes at once; there is no browser round.
;;;
;;; The actor reads and writes the oobi-host with `$`, so it lives in the
;;; oobi-host's vat (the lobby's).

(define-module (playnet personhood body-ceremony)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (rnrs bytevectors)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))
  #:use-module ((playnet keri signify-portable)
                #:select (build-icp build-rot scm->json-canonical event-sn))
  #:use-module ((playnet keri cesr)
                #:select (cesr-qb64->bytes cesr-bytes->qb64 %b64url-alphabet))
  #:use-module ((playnet keri citizen-sig) #:select (verify-bytes-under-aid))
  #:use-module ((playnet keri key-state) #:select (indexed-sig-index events->states))
  #:use-module ((playnet identity oobi-host) #:select (oobi-entry-last-event))
  #:use-module ((playnet utils paths) #:select (playnet-state-dir))
  #:export (spawn-body-ceremony ^body-ceremony
            body-ceremony-record body-ceremony-records-dir
            body-ceremony-sign-bytes))

;;; ── the record — a ceremony's durable self ──────────────────────────────────

(define (body-ceremony-records-dir)
  "Where ceremonies keep their records when the caller names no dir."
  (string-append (playnet-state-dir) "/witness/bodies"))

(define (safe-name s)
  (string-map (lambda (c)
                (if (or (char-alphabetic? c) (char-numeric? c)
                        (char=? c #\-) (char=? c #\_))
                    c #\_))
              s))

(define (ensure-dir! path)
  (let loop ((p path))
    (unless (file-exists? p)
      (loop (dirname p))
      (catch #t (lambda () (mkdir p)) (lambda _ #f)))))

(define (record-path dir said) (string-append dir "/" (safe-name said) ".scm"))

(define (write-record! dir rec)
  "Write REC atomically under its SAID: a half-written file is never read."
  (let* ((path (record-path dir (assq-ref rec 'said)))
         (tmp  (string-append path ".tmp")))
    (ensure-dir! dir)
    (call-with-output-file tmp (lambda (port) (write rec port)))
    (rename-file tmp path)))

(define (body-ceremony-record dir said)
  "The durable record of the ceremony whose inception SAID is SAID (the
   body's AID), under DIR, or #f."
  (let ((path (record-path dir said)))
    (and (file-exists? path)
         (catch #t (lambda () (call-with-input-file path read)) (lambda _ #f)))))

;;; ── signatures: bytes in, an indexed signature out ──────────────────────────

(define (sig-raw-bytes sig)
  "The 64 signature bytes of SIG — a bare `0B` signature or an indexed `A?`
   one — or #f."
  (catch #t
    (lambda ()
      (let ((bv (cesr-qb64->bytes
                 (if (indexed-sig-index sig) (string-append "AA" (substring sig 2)) sig))))
        (and (bytevector? bv) (= 64 (bytevector-length bv)) bv)))
    (lambda _ #f)))

(define (indexed-sig raw index)
  (cesr-bytes->qb64 (string #\A (string-ref %b64url-alphabet index)) raw))

(define (body-ceremony-sign-bytes json)
  "The bytes a steward signs for an event whose canonical JSON is JSON."
  (string->utf8 json))

;;; ── the actor ───────────────────────────────────────────────────────────────
;;;
;;; State, one alist: stage ('collecting | 'published), what ('inception |
;;; 'rotation), event, json, said, members ((aid . key) … in event order),
;;; need, sigs ((aid . indexed-sig) …), body (the AID once published),
;;; stewards (the roster the body stands with), roster (the roster the
;;; collecting rotation installs), k.

(define (st-ref st key) (assq-ref st key))
(define (st-set st . kvs)
  (let loop ((st st) (kvs kvs))
    (if (null? kvs) st
        (loop (cons (cons (car kvs) (cadr kvs))
                    (filter (lambda (p) (not (eq? (car p) (car kvs)))) st))
              (cddr kvs)))))

(define (member-index members aid)
  (list-index (lambda (m) (equal? (car m) aid)) members))

(define (ordered-sigs members sigs)
  "The signatures gathered, as a vector in member order."
  (list->vector
   (filter-map (lambda (m) (assoc-ref sigs (car m))) members)))

(define (round-preimage st caller)
  (let ((members (st-ref st 'members)))
    `((what . ,(symbol->string (st-ref st 'what)))
      (said . ,(st-ref st 'said))
      (index . ,(and caller (member-index members caller)))
      (json . ,(st-ref st 'json))
      (fields . ,(st-ref st 'event)))))

(define (current-key-of oobi-host aid)
  (or ($ oobi-host 'current-key aid)
      (error "body-ceremony: a steward's key log is not held here" aid)))

(define (current-next-of oobi-host aid)
  (or ($ oobi-host 'current-next-digest aid)
      (error "body-ceremony: a steward's key log commits to no next key" aid)))

(define (^body-ceremony bcom st oobi-host close! dir)
  (define (record! st)
    (let ((prior (or (body-ceremony-record dir (st-ref st 'said-icp)) '()))
          (now (instant->unix (clock-now))))
      (write-record!
       dir
       `((said . ,(st-ref st 'said-icp))
         (body . ,(st-ref st 'body))
         (scope . ,(st-ref st 'scope))
         (initiator . ,(st-ref st 'initiator))
         (stewards . ,(st-ref st 'stewards))
         (k . ,(st-ref st 'k))
         (opened-at . ,(or (assq-ref prior 'opened-at) now))
         (state . ,(st-ref st 'stage))
         (what . ,(st-ref st 'what))
         (round-said . ,(st-ref st 'said))
         (signatures . ,(map (lambda (p)
                               (let ((old (find (lambda (a) (and (equal? (car a) (car p))
                                                                 (equal? (cadr a) (cdr p))))
                                                (or (assq-ref prior 'signatures) '()))))
                                 (list (car p) (cdr p) (if old (caddr old) now))))
                             (st-ref st 'sigs)))
         (rotations . ,(st-ref st 'rotations))))))

  (define (rebuild new-st)
    (record! new-st)
    (^body-ceremony bcom new-st oobi-host close! dir))

  (define (summary st)
    `((have . ,(length (st-ref st 'sigs)))
      (need . ,(st-ref st 'need))
      (published . ,(and (eq? 'published (st-ref st 'stage)) (st-ref st 'body)))))

  (define (verified! aid icp icp-sigs rotations what)
    "The log {icp, rotations} for AID read through the key-log reader;
     raises when it does not verify."
    (let ((v (events->states aid (cons `(("icp" . ,icp) ("sigs" . ,icp-sigs))
                                       (map (lambda (r) `(("rot" . ,(car r)) ("sigs" . ,(cdr r))))
                                            rotations)))))
      (when (string? v) (error (string-append "body-ceremony: the " what " does not verify") v))))

  (define (publish st)
    "The round's log into the oobi-host, verified as every key log is;
     the state after. Raises when the log does not verify."
    (let* ((event (st-ref st 'event))
           (sigs (ordered-sigs (st-ref st 'members) (st-ref st 'sigs)))
           (what (st-ref st 'what)))
      (case what
        ((inception)
         (let ((aid (assoc-ref event "i")))
           (verified! aid event sigs '() "inception")
           (let ((r ($ oobi-host 'put! aid event sigs)))
             (unless (eq? r 'ok) (error "body-ceremony: the oobi-host refused the inception" r)))
           (close! aid)
           (st-set st 'stage 'published 'body aid)))
        ((rotation)
         (let* ((aid (st-ref st 'body))
                (entry ($ oobi-host 'get aid))
                (stored (or (assq-ref entry 'rotations) '())))
           (verified! aid (assq-ref entry 'icp) (assq-ref entry 'sigs)
                      (append stored (list (cons event sigs))) "rotation")
           (let ((r ($ oobi-host 'append-rotation! aid event sigs)))
             (unless (eq? r 'ok) (error "body-ceremony: the oobi-host refused the rotation" r)))
           (st-set st 'stage 'published
                   'stewards (st-ref st 'roster) 'k (st-ref st 'need)
                   'rotations (+ 1 (st-ref st 'rotations)))))
        (else (error "body-ceremony: nothing to publish" what)))))

  (methods
    ((status)
     `((stage . ,(st-ref st 'stage))
       (what . ,(st-ref st 'what))
       (body . ,(st-ref st 'body))
       (said . ,(st-ref st 'said))
       (have . ,(length (st-ref st 'sigs)))
       (need . ,(st-ref st 'need))
       (signed . ,(map car (st-ref st 'sigs)))
       (members . ,(map car (st-ref st 'members)))
       (stewards . ,(st-ref st 'stewards))
       (k . ,(st-ref st 'k))
       (scope . ,(st-ref st 'scope))
       (rotations . ,(st-ref st 'rotations))))

    ((body-aid) (st-ref st 'body))

    ;; what a steward signs: the round's event, its SAID, its canonical
    ;; JSON (the signed bytes), and the caller's member index when given
    ((preimage . caller)
     (and (st-ref st 'event)
          (round-preimage st (and (pair? caller) (car caller)))))

    ;; one steward's signature over the round's event; at `need` the round
    ;; publishes. Raises on a non-steward, a duplicate, a signature that does
    ;; not verify under the steward's current key, or a closed round.
    ((sign aid sig)
     (unless (eq? 'collecting (st-ref st 'stage))
       (error "body-ceremony: no round is collecting" (st-ref st 'stage)))
     (let* ((members (st-ref st 'members))
            (index (member-index members aid)))
       (unless index (error "body-ceremony: not a steward of this round" aid))
       (when (assoc aid (st-ref st 'sigs))
         (error "body-ceremony: this steward has signed already" aid))
       (let ((raw (sig-raw-bytes sig))
             (named (indexed-sig-index sig)))
         (unless raw (error "body-ceremony: not a signature" aid))
         (when (and named (not (= named index)))
           (error "body-ceremony: the signature's index is not the steward's" aid named index))
         (unless (verify-bytes-under-aid (body-ceremony-sign-bytes (st-ref st 'json))
                                         (cesr-bytes->qb64 "0B" raw)
                                         (cdr (list-ref members index)))
           (error "body-ceremony: the signature does not verify under the steward's current key" aid))
         (let* ((sigs (append (st-ref st 'sigs) (list (cons aid (indexed-sig raw index)))))
                (st1 (st-set st 'sigs sigs))
                (st2 (if (>= (length sigs) (st-ref st 'need)) (publish st1) st1)))
           (bcom (rebuild st2) (summary st2))))))

    ;; a rotation round: CUTS leave, ADDS join (their keys revealed by the
    ;; rotation after this one), K2 the threshold from here on. Signed by
    ;; K2 of the continuing stewards, from their rotated dial AIDs.
    ((rotate cuts adds k2)
     (unless (eq? 'published (st-ref st 'stage))
       (error "body-ceremony: the body is not published" (st-ref st 'stage)))
     (let* ((stewards (st-ref st 'stewards))
            (continuing (filter (lambda (a) (not (member a cuts))) stewards))
            (roster (append continuing
                            (filter (lambda (a) (not (member a continuing))) adds)))
            (aid (st-ref st 'body))
            (last (oobi-entry-last-event ($ oobi-host 'get aid))))
       (unless (and (exact-integer? k2) (<= 1 k2 (length continuing)))
         (error "body-ceremony: the threshold must be between 1 and the continuing stewards" k2))
       (unless last (error "body-ceremony: the body's log is not held here" aid))
       (let ((keys (map (lambda (a) (current-key-of oobi-host a)) continuing))
             (nexts (map (lambda (a) (current-next-of oobi-host a)) roster)))
         (call-with-values
             (lambda ()
               (build-rot aid (assoc-ref last "d")
                          #:keys keys #:nkeys nexts
                          #:sn (+ 1 (event-sn last))
                          #:isith k2 #:nsith k2
                          #:cuts cuts #:adds adds))
           (lambda (json said rot)
             (let ((st1 (st-set st 'stage 'collecting 'what 'rotation
                                'event rot 'json json 'said said
                                'members (map cons continuing keys)
                                'need k2 'sigs '() 'roster roster)))
               (bcom (rebuild st1) (round-preimage st1 #f))))))))))

(define* (spawn-body-ceremony #:key scope-aid initiator-aid steward-aids k
                              oobi-host close! (witness-dir #f) (create-group #f))
  "Open the ceremony that makes a body's AID in SCOPE-AID: the k-of-n
   group of STEWARD-AIDS (dial AIDs whose key logs OOBI-HOST holds),
   INITIATOR-AID among them, K the threshold. The ceremony holds ONE
   inception built from the stewards' current keys and next-key digests;
   `preimage` hands it out, `sign` gathers signatures, and at K the log
   lands in OOBI-HOST and `(close! body-aid)` runs — the planner side's
   records are the caller's. The record lives under WITNESS-DIR (the
   state dir's witness/bodies when #f). With CREATE-GROUP (a thunk →
   group AID, the KERIA path) the body is made and closed at once.
   Spawn it in the oobi-host's vat."
  (unless (and (list? steward-aids) (pair? steward-aids) (every string? steward-aids))
    (error "spawn-body-ceremony: steward-aids must be a non-empty list of AIDs"))
  (unless (= (length steward-aids) (length (delete-duplicates steward-aids)))
    (error "spawn-body-ceremony: a steward is named twice"))
  (unless (and (exact-integer? k) (<= 1 k (length steward-aids)))
    (error "spawn-body-ceremony: k must be between 1 and the number of stewards" k))
  (unless (member initiator-aid steward-aids)
    (error "spawn-body-ceremony: the initiator is not a steward" initiator-aid))
  (unless (procedure? close!)
    (error "spawn-body-ceremony: close! must be a procedure"))
  (let ((dir (or witness-dir (body-ceremony-records-dir)))
        (base `((scope . ,scope-aid) (initiator . ,initiator-aid)
                (stewards . ,steward-aids) (k . ,k) (sigs . ()) (rotations . 0)
                (roster . ,steward-aids))))
    (if create-group
        (let ((aid (create-group)))
          (unless (string? aid) (error "spawn-body-ceremony: create-group gave no AID" aid))
          (close! aid)
          (let ((st (st-set base 'stage 'published 'what 'inception
                            'event #f 'json #f 'said aid 'said-icp aid
                            'members '() 'need k 'body aid)))
            (write-record! dir `((said . ,aid) (body . ,aid) (scope . ,scope-aid)
                                 (initiator . ,initiator-aid) (stewards . ,steward-aids)
                                 (k . ,k) (opened-at . ,(instant->unix (clock-now)))
                                 (state . published) (what . inception)
                                 (round-said . ,aid) (signatures . ()) (rotations . 0)))
            (spawn ^body-ceremony st oobi-host close! dir)))
        (let ((keys (map (lambda (a) (current-key-of oobi-host a)) steward-aids))
              (nexts (map (lambda (a) (current-next-of oobi-host a)) steward-aids)))
          (call-with-values
              (lambda () (build-icp #:keys keys #:nkeys nexts #:isith k #:nsith k))
            (lambda (json said icp)
              (let* ((st (st-set base 'stage 'collecting 'what 'inception
                                 'event icp 'json json 'said said 'said-icp said
                                 'members (map cons steward-aids keys)
                                 'need k 'body #f))
                     (ceremony (spawn ^body-ceremony st oobi-host close! dir)))
                ;; the record from the first moment: an ask that stands
                (write-record! dir `((said . ,said) (body . #f) (scope . ,scope-aid)
                                     (initiator . ,initiator-aid) (stewards . ,steward-aids)
                                     (k . ,k) (opened-at . ,(instant->unix (clock-now)))
                                     (state . collecting) (what . inception)
                                     (round-said . ,said) (signatures . ()) (rotations . 0)))
                ceremony)))))))
