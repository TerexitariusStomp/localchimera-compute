;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/did.scm — did:keri ↔ AID conversion
;;;
;;; Tiny helpers for surfacing KERI AIDs as W3C `did:keri` method
;;; identifiers. The DID method-specific identifier IS the AID prefix
;;; — no transformation, just a `did:keri:` prefix.
;;;
;;; The HTTP resolver (returning the DID Document) lives in
;;; server/serve-static.scm at `/.well-known/did/keri/{aid}` so that
;;; any DID-aware client can resolve a playnet identity via HTTP.

(define-module (playnet keri did)
  #:use-module ((srfi srfi-13) #:select (string-prefix?))
  #:export (aid->did-keri
            did-keri->aid
            did-keri?))

(define %did-keri-prefix "did:keri:")
(define %prefix-len      (string-length %did-keri-prefix))

(define (did-keri? str)
  "True iff STR begins with did:keri: and has at least one more char."
  (and (string? str)
       (string-prefix? %did-keri-prefix str)
       (> (string-length str) %prefix-len)))

(define (aid->did-keri aid)
  "Wrap AID prefix as did:keri:<aid>. Raises if AID isn't a string."
  (unless (string? aid)
    (error "aid->did-keri: aid must be a string" aid))
  (string-append %did-keri-prefix aid))

(define (did-keri->aid did)
  "Strip the did:keri: prefix. Raises if DID isn't a did:keri: string."
  (unless (did-keri? did)
    (error "did-keri->aid: not a did:keri: identifier" did))
  (substring did %prefix-len))
