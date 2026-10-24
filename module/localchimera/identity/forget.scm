;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/identity/forget.scm — erasure of a member, as one act
;;;
;;; Article 17, in the shape docs/legal/gdpr-analysis.md §3.1 and
;;; §5 prescribe: what is erased is the LINK between an AID and a person,
;;; together with every record of our own that is keyed by that AID. The
;;; AID's key log, the credentials it holds and the anchors in the scope's
;;; log stay — they are signed, digest-chained data about a pseudonym, and
;;; the KERI specification is explicit that erasing them would expose the
;;; controller to replay of the erased data (docs/keri/OOBI.md §"deletion
;;; attack": "only copies of the digest or signature of the data need to be
;;; kept"). What survives is data nobody here can resolve to a person.
;;;
;;; THE LEDGER IS NOT TOUCHED. Nothing the observer or the planner reads is
;;; opened here: not the acdc-store, not the hash-chained observation
;;; event-log, not a plan-store or scope row (claims, work events,
;;; commitments, credit, home, skills). The AID stays in every one of them as
;;; the pseudonymous agent it always was, so balances, attribution and SAID
;;; chains are as they were, and every signature is verified at its own
;;; time: a root key's against the key of its day (`key-in-force-at`), a
;;; device key's against the device registry's window for it
;;; (`device-keys-at`) — which is why a forget RETIRES the person's devices
;;; (their authorizations close now and stay, each a signed credential)
;;; rather than erasing the registry: a vouch a phone made while authorized
;;; stays the person's. This module imports
;;; no planner, governance, observation or KERI-store module —
;;; tests/gateway/test-forget.scm holds that as a check — so it cannot reach a
;;; ledger by construction. The files it does erase are the gateway's custody
;;; of the member's OWN things (identity/user-files.scm), read by no planner.
;;;
;;; One mechanism, one contract. Every store that holds something of the
;;; member's has a `forget` of its own — ensure-absent, idempotent, replying
;;; how many of its things went — and this module runs them in ONE ORDER:
;;;
;;;   0. the AID is MARKED forgotten here, at once, so every live session of
;;;      it — this one, a phone's, a second tab's — refuses from this turn
;;;      on (`forgotten-gated`, which every session's dispatch passes
;;;      through); a seat proven afresh clears the mark;
;;;   1. what the member record is needed to find (the presence name);
;;;   2. every side-store: bindings, push subscriptions, the desk, the
;;;      devices (retired), the cards, the user files, the folds, the mesh
;;;      and offline mailboxes, the mail spool;
;;;   3. LAST, the member record and the AID→handle index.
;;;
;;; The order is the invariant: a crash midway leaves a person who can still
;;; sign in and run it again (the link is still there), and never a record
;;; whose link is gone while a session of theirs could still write. The reply
;;; is a RECEIPT — what went, by kind and count, and what stays and why — so
;;; the person reads an account of the act rather than a word; a store that
;;; refuses midway turns the receipt into the one message that names the
;;; stage and says signing in again finishes it.

(define-module (localchimera identity forget)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera identity devices) #:select (devices-retire!))
  #:use-module ((localchimera identity cards) #:select (cards-forget!))
  #:use-module ((localchimera identity user-files) #:select (user-files-forget!))
  #:export (forget-member! forgotten? forgotten-gated unmark-forgotten!))

;; What a forget leaves standing, named in every receipt. The key log is the
;; AID's own; the credentials are signed facts whose digests the scope's log
;; anchors; the scope's records are the planner's (gdpr-analysis.md Phase 2 —
;; blinding and shredding — is where their contents become erasable without
;; a hole in the chain).
(define %kept-by-design '(key-log credentials scope-records))

;;; ── the mark: every live session of a forgotten AID refuses ──────────────
;;; Sessions are closures over an AID with no per-call seat check, and they
;;; live only in this process (a plain vat, nothing persistent). So a table
;;; in this vat of the AIDs forgotten since boot is, by construction, the
;;; set every live session of them consults. The asking session is marked
;;; in the door's own turn, before any store is touched.

(define %forgotten (make-hash-table))
(define (forgotten? aid) (hash-ref %forgotten aid #f))
(define (mark-forgotten! aid) (hash-set! %forgotten aid #t))
(define (unmark-forgotten! aid)
  "A seat proven afresh (a session spawned after has-seat?) is a person who
   is a member again: their sessions act."
  (hash-remove! %forgotten aid))

(define %refusal
  (list 'error "this identity was forgotten here — nothing more can be done as it"))

(define (forgotten-gated aid behaviour)
  "BEHAVIOUR (a session's dispatch), refusing every message once AID is
   marked forgotten."
  (lambda (method . args)
    (if (forgotten? aid) %refusal (apply behaviour method args))))

;;; ── the act ───────────────────────────────────────────────────────────────

(define (count-of n)
  "A store's reply as a count. A store that answers anything else has broken
   its contract: the receipt must not under-report, so this breaks the act
   (the stage message names it) rather than reading 0."
  (if (number? n) n (error "a store answered no count" n)))

(define* (forget-member! aid
                         #:key signup-agent registry push-store presence (presence-names '())
                         desk mailbox-mgr pins folksonomy mesh-mailbox (mesh-dests '())
                         cards-dir mail-forget)
  "Forget the member AID from every store of this gateway's own, in the one
   order the module header states; → a promise of the receipt

     ((dropped . ((member . n) (bindings . n) (push . n) (contact-points . n)
                  (devices . n) (cards . n) (files . n) (mesh . n)
                  (mailbox . n) (mail . n)))
      (kept . (key-log credentials scope-records)))

   or (error …) naming the stage a store refused at.

   SIGNUP-AGENT and MAILBOX-MGR live in vats of their own and are asked
   with `<-`; PINS and FOLKSONOMY (the scope's fold-aggregates, where the
   pins and taxonomy files were also folded) are told to drop the AID with
   no reply awaited — a restart re-folds from the files, which are gone;
   every other store is this vat's and is asked with `$`. A store that is
   #f is simply not there (0 of its kind). PRESENCE-NAMES are the names the
   session announced itself under (presence keys by name); the profile's
   display name and handle, and the AID the room rosters hold, are left by
   as well, and a name presence never held is a no-op there. MESH-DESTS are
   the destinations the AID's anchored key derives. MAIL-FORGET erases the
   spooled mail to a list of addresses and replies how many went: the email
   adapter's `mail-spool-forget!` over its spool, handed in by the door, since
   the spool is the adapter's; #f, and no mail is there to forget."
  (mark-forgotten! aid)
  (define (drop-bindings)
    ;; the row goes, and what each binding pointed at follows from it
    (let* ((bs (if registry ($ registry 'forget aid) '()))
           (push-ids (filter-map (lambda (b) (and (eq? (car b) 'push) (cadr b))) bs))
           (addresses (filter-map (lambda (b) (and (eq? (car b) 'email) (cadr b))) bs)))
      (when push-store (for-each (lambda (id) ($ push-store 'unregister id)) push-ids))
      (values (length bs)
              (length push-ids)
              (if mail-forget (mail-forget addresses) 0))))
  (define (drop-mesh)
    (if mesh-mailbox
        (fold (lambda (dest n) (+ n (length ($ mesh-mailbox 'drain! dest)))) 0 mesh-dests)
        0))
  (define (receipt member bindings push points devices cards files mesh mailbox mail)
    `((dropped . ((member . ,member) (bindings . ,bindings) (push . ,push)
                  (contact-points . ,points) (devices . ,devices) (cards . ,cards)
                  (files . ,files) (mesh . ,mesh) (mailbox . ,mailbox) (mail . ,mail)))
      (kept . ,%kept-by-design)))
  ;; Where the act stands, for the one message a failure midway produces:
  ;; every session of the AID is already a refusal by then, so the person is
  ;; told what stopped and that signing in again finishes it (the link is
  ;; still there until the last step, by the order above).
  (define stage "reading the profile")
  (define (stopped e)
    (list 'error (format #f "forgetting stopped while ~a — sign in again to finish it (~a)"
                         stage e)))
  (on (on (if signup-agent (<- signup-agent 'profile aid) #f)
          (lambda (profile)
            ;; 1. the presence entry, by the name it was announced under and by
            ;;    the AID the room rosters hold
            (set! stage "leaving presence")
            (when presence
              (let ((field (lambda (k) (and (pair? profile) (assq-ref profile k)))))
                (for-each (lambda (name)
                            (when (and (string? name) (not (string-null? name)))
                              ($ presence 'leave name)))
                          (delete-duplicates
                           (append presence-names
                                   (list (field 'display-name) (field 'username) aid))))))
            ;; 2. every side-store
            (set! stage "dropping the side-stores")
            (when pins (<-np pins 'drop-aid aid))
            (when folksonomy (<-np folksonomy 'drop-aid aid))
            (call-with-values drop-bindings
              (lambda (bindings push mail)
                (let ((points  (if desk (count-of (desk 'forget aid)) 0))
                      (devices (devices-retire! aid (current-time)))
                      (cards   (if cards-dir (cards-forget! cards-dir aid) 0))
                      (files   (user-files-forget! aid))
                      (mesh    (drop-mesh)))
                  (set! stage "dropping the mailbox")
                  (on (if mailbox-mgr (<- mailbox-mgr 'forget aid) 0)
                      (lambda (mailbox)
                        ;; 3. last, the link itself
                        (set! stage "erasing the member record")
                        (on (if signup-agent (<- signup-agent 'forget! aid) 0)
                            (lambda (member)
                              (receipt (count-of member) bindings push points devices
                                       cards files mesh (count-of mailbox) mail))
                            #:promise? #t))
                      #:promise? #t)))))
          #:promise? #t)
      (lambda (r) r)
      #:catch stopped
      #:promise? #t))
