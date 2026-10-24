;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; scope/ballot-store.scm — per-scope persistent registry of ballots and tallies
;;;
;;; Stand-alone module — depends only on Goblins, so the scope root (for its
;;; wiring) and the voice modules import it without a cycle.
;;;
;;; Three pieces of state per proposal:
;;;   - meta `((opened-at . t) (kind . k) (domain . d) (description . s)
;;;     (franchise . f) (subject . "kind:id"))` — what a proposal IS beyond
;;;     its tally. Written at `record`, kept through `forget` and close, so a
;;;     decided thread still reads its question after the actor is gone.
;;;   - ballot-actor (live ^ballot ref) — present while the ballot is open
;;;   - tally-record `((tally . hashmap) (abstain . n) (timestamp . t))`
;;;     — recorded at close, used by downstream readers (planner, audit)
;;;     even after the ballot actor is gc'd.

(define-module (localchimera scope ballot-store)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (^ballot-store spawn-ballot-store ballot-store-env))


(define-actor (^ballot-store bcom
                             ballots    ;; hashmap proposal-id → ballot-actor (LIVE, never persisted)
                             tallies    ;; hashmap proposal-id → tally-record
                             meta)      ;; hashmap proposal-id → meta alist

  ;; The portrait persists `tallies` and `meta`. `ballots` holds live ^ballot refs,
  ;; which are deliberately NOT serialized:
  ;;   - a ^ballot closes over its verifier/credential-check closures, which
  ;;     have no encoder — persisting one raises &persistence-error
  ;;     "Don't know how to persist ^ballot" and, because this store lives in
  ;;     the persistent scope-root vat, that would abort the whole snapshot
  ;;     (e.g. after any cast).
  ;;   - a ballot is an ephemeral projection of its stance-ACDC log anyway:
  ;;     recover-ballots-into-scope! (governance recovery) rebuilds every
  ;;     still-open ballot from its snapshot + stance ACDCs on restart, and
  ;;     closed ballots keep their durable `tally-record` here in `tallies`.
  #:portrait
  (lambda () (list tallies meta))

  #:version 3

  #:restore
  ;; Goblins calls (restore version . portrait-values). `ballots` always comes
  ;; back empty (repopulated by recovery); `tallies` and `meta` carry across.
  (lambda (version . vals)
    (case version
      ;; v1 persisted (ballots tallies). A non-empty `ballots` could never have
      ;; been portraited (no ^ballot encoder), so any v1 snapshot that exists
      ;; already had an empty ballots map — safe to drop and read tallies.
      ((1) (spawn ^ballot-store (hashmap) (cadr vals) (hashmap)))
      ((2) (spawn ^ballot-store (hashmap) (car vals) (hashmap)))
      ((3) (spawn ^ballot-store (hashmap) (car vals) (cadr vals)))
      (else (error "Unknown ^ballot-store version" version))))

  (methods

    ;; --- Reads ---
    ((get proposal-id)        (hashmap-ref ballots proposal-id #f))
    ((get-tally proposal-id)  (hashmap-ref tallies proposal-id #f))
    ((meta proposal-id)       (hashmap-ref meta proposal-id '()))

    ((list-proposals)
     ;; Returns ((proposal-id . status) ...) where status is
     ;; 'open (ballot present, no tally) or 'closed (tally recorded).
     (let ((open-list
             (hashmap-fold (lambda (k _v acc) (cons (cons k 'open) acc))
                           '() ballots))
           (closed-list
             (hashmap-fold (lambda (k _v acc) (cons (cons k 'closed) acc))
                           '() tallies)))
       ;; Closed wins over open in case of overlap.
       (let ((closed-ids (map car closed-list)))
         (append closed-list
                 (filter (lambda (p) (not (member (car p) closed-ids)))
                         open-list)))))

    ;; --- Writes ---
    ;; FIELDS, optional: meta entries to set. An `opened-at` already held is
    ;; kept — recovery re-records a ballot after a restart, and the proposal
    ;; opened once.
    ((record proposal-id ballot-actor . fields)
     (let* ((had  (hashmap-ref meta proposal-id '()))
            (new  (if (and (pair? fields) (list? (car fields))) (car fields) '()))
            (kept (filter (lambda (e) (or (not (assq (car e) new))
                                          (and (eq? (car e) 'opened-at) (assq 'opened-at had))))
                          had))
            (add  (filter (lambda (e) (not (assq (car e) kept))) new)))
       (bcom (^ballot-store bcom
                            (hashmap-set ballots proposal-id ballot-actor)
                            tallies
                            (if (or (pair? kept) (pair? add))
                                (hashmap-set meta proposal-id (append kept add))
                                meta)))))

    ((record-tally proposal-id tally-map abstain timestamp)
     (let ((rec (list (cons 'tally     tally-map)
                      (cons 'abstain   abstain)
                      (cons 'timestamp timestamp))))
       (bcom (^ballot-store bcom
                            ballots
                            (hashmap-set tallies proposal-id rec)
                            meta))))

    ((forget proposal-id)
     ;; Drop the live ballot ref but keep the tally and the meta. Useful after close.
     (bcom (^ballot-store bcom
                          (hashmap-remove ballots proposal-id)
                          tallies
                          meta)))))


(define (spawn-ballot-store)
  "Create an empty ballot-store. Must be called within a vat."
  (spawn ^ballot-store (hashmap) (hashmap) (hashmap)))


(define ballot-store-env
  (make-persistence-env
    `((((localchimera scope ballot-store) ^ballot-store) ,^ballot-store))))
