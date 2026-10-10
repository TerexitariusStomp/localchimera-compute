;;; module/playnet/governance/keri/witnesses-federation.scm — bootstrap a peer's
;;; KERIA witness pool from federation-issued ACDC assignments.
;;;
;;; A new peer joining a federation doesn't know which witnesses to
;;; trust. The federation's witness-assignment ACDCs are the source of
;;; truth: each names a witness AID + OOBI URL operated by some
;;; federation member. This module reads those credentials and resolves
;;; their OOBIs into the local KERIA agent so the peer's KERI
;;; operations (ICP, ROT, IXN, KEL retrieval) participate in the same
;;; witness pool the rest of the federation uses.
;;;
;;; The credential schema, constructor, and auditor live in
;;; (playnet governance) — see make-witness-assignment-credential and
;;; audit-witness-quorum-independence in
;;; module/playnet/governance/credentials.scm.
;;;
;;; This module composes those data-layer helpers with the runtime
;;; OOBI resolver from (playnet keri bridge).

(define-module (playnet governance keri witnesses-federation)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)            ;; count
  #:use-module ((goblins) #:select ($))   ; the acdc-store is an actor
  #:use-module (playnet keri bridge)
  #:use-module (playnet credentials keys)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri acdc)
  #:export (federation-bootstrap-witness-pool!))

(define (log! fmt . args)
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

(define (try-resolve-assignment! cred)
  "Resolve one assignment's OOBI into the local KERIA. Logs outcome.
   Returns #t on success, #f on missing-data or KERIA error."
  (let ((aid  (cred-claim cred 'witness-aid))
        (oobi (cred-claim cred 'witness-oobi)))
    (and aid oobi
         (catch #t
           (lambda ()
             (keri-resolve-oobi oobi)
             (log! "[fed-witnesses] resolved ~a~%" aid)
             #t)
           (lambda (key . args)
             (log! "[fed-witnesses] FAIL ~a: ~a ~a~%" aid key args)
             #f)))))

(define (federation-bootstrap-witness-pool! federation-aid acdc-store)
  "Resolve every non-revoked witness-assignment ACDC for FEDERATION-AID
   into the local KERIA agent via keri-resolve-oobi. Idempotent —
   keri-resolve-oobi de-duplicates against the agent's iurls config,
   so calling on every gateway boot is safe.

   ACDC-STORE is the live ^acdc-store ref. Returns an alist with
   'attempted, 'resolved, 'failed counts."
  (let* ((assignments (witness-assignments-for-federation
                       federation-aid ($ acdc-store 'all)))
         (outcomes    (map try-resolve-assignment! assignments)))
    `((attempted . ,(length outcomes))
      (resolved  . ,(count identity outcomes))
      (failed    . ,(count not outcomes)))))
