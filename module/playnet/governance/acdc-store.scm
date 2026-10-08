;;; acdc-store.scm — playnet's name for the credential store
;;;
;;; The store itself is (playnet keri acdc-store). This module gives it the
;;; identity playnet's durable state knows it by — the persistence-env label
;;; ((playnet governance) ^acdc-store), which every saved vat on disk carries —
;;; and re-exports the store's interface for governance's importers.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.

(define-module (playnet governance acdc-store)
  #:use-module (playnet keri acdc-store)
  #:use-module (goblins)
  #:re-export (index-add-cred hashmap-count index-lookup durable-revoked-path
               durable-ensure-dir! durable-write-cred! durable-append-revoke!
               durable-load-creds apply-import-pair durable-load-revokes ^acdc-store
               credentials-of-schema in-ts-range? timestamp-sorted
               non-revoked-by-schema spawn-acdc-store)
  #:export (acdc-store-env))

(define acdc-store-env
  (make-persistence-env
    `((((playnet governance) ^acdc-store) ,^acdc-store))))
