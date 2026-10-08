;;; module/playnet/governance/keri-backend.scm — keri-backend factories for ^scope
;;;
;;; The unified ^scope actor accepts an optional `keri-backend` alist. When
;;; #f, recomposition (merge/split) uses synthetic AIDs — fast for tests.
;;; When bound, recomposition issues real KERI events anchored in the
;;; witness pool: merge → multi-sig group inception + dissolution rotations
;;; on predecessors; split → rotation cut on the parent (sub-scope AIDs
;;; created separately by the operator).
;;;
;;; The backend alist exposes these operations:
;;;
;;;   create-scope-aid : (#:anchors seals #:keypair kp) →
;;;                       (values aid keypair next-keypair signed-icp-body)
;;;       Autonomous-signer scope inception (per democracy-on-keri.md §4.1).
;;;       Single-controller AID; keypair returned to caller for bcom storage.
;;;       ANCHORS optional list of seal alists for ratification gating (§4.3).
;;;   create-group     : (member-aids threshold) → new-group-aid-prefix
;;;       Legacy multi-sig group inception. Retained only for the global
;;;       maintainer-governance AID at gateway bootstrap; per-scope inception
;;;       no longer goes through this path.
;;;   rotate-keys      : (aid-name #:cuts cuts #:adds adds) → operation
;;;   create-aid       : (name #:toad toad #:witnesses ws) → new-aid-prefix
;;;
;;; Two factories ship here:
;;;
;;;   stub-keri-backend  — records calls into a list-cell; no KERIA, no crypto.
;;;                        Pure Scheme; safe for unit tests.
;;;   live-keri-backend  — defined in (playnet governance keri-backend live);
;;;                        depends on (playnet keri bridge) and libsodium.
;;;                        Re-exported here for ergonomics.

(define-module (playnet governance keri-backend)
  #:use-module (goblins)
  #:use-module ((playnet keri inception)
                #:select (make-scope-inception))
  #:export (stub-keri-backend))

(define (stub-keri-backend events-box)
  "Build a keri-backend alist that records every call into EVENTS-BOX
   (a cons cell whose cdr is the running event log). Useful for tests
   that want to verify the dispatch path without touching KERIA."
  (define (record! event)
    (set-cdr! events-box (cons event (cdr events-box))))
  `((create-scope-aid
     . ,(lambda* (#:key (anchors '()) (bran #f)
                  (witnesses '()) (toad 0) (kel-store #f))
          (record! `(create-scope-aid #:anchors ,anchors))
          ;; Stub: synthesise a deterministic AID prefix from the event count.
          ;; Real bran/keypair derivation is in the live backend.
          (let* ((aid (string-append
                       "Dscope_stub_"
                       (number->string (length (cdr events-box)))))
                 (icp-inner (list (cons "t" "icp")
                                  (cons "d" (string-append "EICPSTUB" aid))
                                  (cons "i" aid)
                                  (cons "s" "0")
                                  (cons "a" anchors)))
                 (body (list (cons "name" (string-append "scope-" aid))
                             (cons "icp"  icp-inner)
                             (cons "sigs" #()))))
            (when kel-store ($ kel-store 'append body))
            ;; Stub returns #f bran/keypairs — tests using the stub
            ;; don't exercise signing or recovery.
            (make-scope-inception aid bran #f #f body))))
    (create-group . ,(lambda (member-aids threshold)
                       (record! `(create-group ,member-aids ,threshold))
                       (string-append "E_group_"
                                      (number->string
                                       (length (cdr events-box))))))
    (rotate-keys  . ,(lambda (aid-name . kwargs)
                       (record! `(rotate-keys ,aid-name ,@kwargs))
                       'rotated))
    (create-aid   . ,(lambda (name . kwargs)
                       (record! `(create-aid ,name ,@kwargs))
                       (string-append "E_aid_" name)))))
