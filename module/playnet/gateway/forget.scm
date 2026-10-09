;;; module/playnet/gateway/forget.scm — erasure of a member, as one act
;;;
;;; Article 17, in the shape docs/planning/legal/gdpr-analysis.md §3.1 and
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
;;; chains are as they were, and `key-in-force-at` still verifies every old
;;; signature against the key of its day. This module imports no planner,
;;; governance, observation or KERI-store module — tests/keri/test-forget.scm
;;; holds that as a check — so it cannot reach a ledger by construction. The
;;; files it does erase are the gateway's custody of the member's OWN things
;;; (their contact book, captain's log, sealed credential backup, pins,
;;; taxonomy cut, allotment reads, recovery shares), read by no planner.
;;;
;;; One mechanism, one contract. Every store that holds something of the
;;; member's has a `forget` of its own — ensure-absent, idempotent, replying
;;; how many of its things went — and this module runs them in ONE ORDER:
;;;
;;;   1. what the member record is needed to find (the presence name);
;;;   2. every side-store: bindings, push subscriptions, the desk, the
;;;      devices, the cards, the user files, the mesh and offline mailboxes,
;;;      the mail spool;
;;;   3. LAST, the member record and the AID→handle index.
;;;
;;; The order is the invariant: a crash midway leaves a person who can still
;;; sign in and run it again, and never a record whose link is gone while
;;; copies of its contents remain. The reply is a RECEIPT — what went, by
;;; kind and count, and what stays and why — so the person reads an account
;;; of the act rather than a word.
;;;
;;; The session that asked becomes a refusal (`forgotten-session`): a cap
;;; that could still write a user file after the link is gone would
;;; resurrect what was erased.

(define-module (playnet gateway forget)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet gateway device-registry) #:select (device-forget!))
  #:use-module ((playnet gateway cards) #:select (cards-forget!))
  #:use-module ((playnet interface adapters email) #:select (mail-spool-forget!))
  #:export (forget-member! forgotten-session %kept-by-design))

;; What a forget leaves standing, named in every receipt. The key log is the
;; AID's own; the credentials are signed facts whose digests the scope's log
;; anchors; the planner's rows are the scope's records (gdpr-analysis.md
;; Phase 2 — blinding and shredding — is where their contents become
;; erasable without a hole in the chain).
(define %kept-by-design '(key-log credentials scope-records))

(define (forgotten-session)
  "The behaviour a session takes once its member is forgotten: every
   message is refused with the one reason."
  (lambda _ (list 'error "this identity was forgotten here — nothing more can be done as it")))

(define (count-of n) (if (number? n) n 0))

(define* (forget-member! aid
                         #:key signup-agent registry push-store presence (presence-names '())
                         desk mailbox-mgr pins folksonomy mesh-mailbox (mesh-dests '())
                         (user-files '()) cards-dir mail-dir)
  "Forget the member AID from every store of this gateway's own, in the one
   order the module header states; → a promise of the receipt

     ((dropped . ((member . n) (bindings . n) (push . n) (contact-points . n)
                  (devices . n) (cards . n) (files . n) (mesh . n)
                  (mailbox . n) (mail . n)))
      (kept . (key-log credentials scope-records)))

   SIGNUP-AGENT and MAILBOX-MGR live in vats of their own and are asked
   with `<-`; PINS and FOLKSONOMY (the scope's fold-aggregates, where the
   pins and taxonomy files were also folded) are told to drop the AID with
   no reply awaited; every other store is this vat's and is asked with `$`.
   A store that is #f is simply not there (0 of its kind). PRESENCE-NAMES
   are the names the session announced itself under (presence keys by
   name); the profile's display name and handle, and the AID the room
   rosters hold, are left by as well. USER-FILES are the paths of the
   per-AID files the lobby keeps; MESH-DESTS the destinations the AID's
   anchored key derives; MAIL-DIR the spool."
  (define (drop-user-files)
    (count (lambda (f)
             (and (file-exists? f) (begin (delete-file f) #t)))
           user-files))
  (define (drop-bindings)
    ;; the row goes, and what each binding pointed at follows from it
    (let* ((bs (if registry ($ registry 'forget aid) '()))
           (push-ids (filter-map (lambda (b) (and (eq? (car b) 'push) (cadr b))) bs))
           (addresses (filter-map (lambda (b) (and (eq? (car b) 'email) (cadr b))) bs)))
      (when push-store (for-each (lambda (id) ($ push-store 'unregister id)) push-ids))
      (values (length bs)
              (length push-ids)
              (mail-spool-forget! mail-dir addresses))))
  (define (drop-mesh)
    (if mesh-mailbox
        (fold (lambda (dest n) (+ n (length ($ mesh-mailbox 'drain! dest)))) 0 mesh-dests)
        0))
  (define (receipt member bindings push points devices cards files mesh mailbox mail)
    `((dropped . ((member . ,member) (bindings . ,bindings) (push . ,push)
                  (contact-points . ,points) (devices . ,devices) (cards . ,cards)
                  (files . ,files) (mesh . ,mesh) (mailbox . ,mailbox) (mail . ,mail)))
      (kept . ,%kept-by-design)))
  (on (if signup-agent (<- signup-agent 'profile aid) #f)
      (lambda (profile)
        ;; 1. the presence entry, by the name it was announced under and by
        ;;    the AID the room rosters hold
        (when presence
          (let ((field (lambda (k) (and (pair? profile) (assq-ref profile k)))))
            (for-each (lambda (name)
                        (when (and (string? name) (not (string-null? name)))
                          ($ presence 'leave name)))
                      (append presence-names
                              (list (field 'display-name) (field 'username) aid)))))
        ;; 2. every side-store
        (when pins (<-np pins 'drop-aid aid))
        (when folksonomy (<-np folksonomy 'drop-aid aid))
        (call-with-values drop-bindings
          (lambda (bindings push mail)
            (let ((points  (if desk (count-of (desk 'forget aid)) 0))
                  (devices (device-forget! aid))
                  (cards   (if cards-dir (cards-forget! cards-dir aid) 0))
                  (files   (drop-user-files))
                  (mesh    (drop-mesh)))
              (on (if mailbox-mgr (<- mailbox-mgr 'forget aid) 0)
                  (lambda (mailbox)
                    ;; 3. last, the link itself
                    (on (if signup-agent (<- signup-agent 'forget! aid) 0)
                        (lambda (member)
                          (receipt (count-of member) bindings push points devices
                                   cards files mesh (count-of mailbox) mail))
                        #:promise? #t))
                  #:promise? #t)))))
      #:promise? #t))
