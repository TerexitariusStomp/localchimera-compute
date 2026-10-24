;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/fleet/paths.scm — where a provider's credential lives.
;;;
;;; The fleet's providers are reached through one interface ((localchimera
;;; fleet provider)), and their credentials should be found the same way:
;;; by provider NAME, not by knowing which module implements it. This is
;;; the module the gateway's boot path and the reconciler both consult,
;;; so neither has to import a particular provider's API client to learn
;;; where a file sits on disk.
;;;
;;; That import was the previous arrangement and it inverted the layering:
;;; (localchimera fleet sporestack) is an HTTP client for one vendor's API, and
;;; deployment layout is not its business. Boot code depending on it for a
;;; pathname meant general infrastructure could not be read, tested or
;;; moved without a vendor module coming along.
;;;
;;; The env-var override is DERIVED from the provider name rather than
;;; listed, so a new provider gets one without editing this file:
;;;
;;;     sporestack  →  LOCALCHIMERA_SPORESTACK_TOKEN_FILE
;;;     vpsbg       →  LOCALCHIMERA_VPSBG_TOKEN_FILE
;;;
;;; Only SporeStack keeps a token file today: its token is prepaid and
;;; anonymous, so it is minted, funded and rotated at runtime and has to
;;; survive a restart on disk. VPSBG's key is a long-lived secret set once
;;; at deploy time and read from the environment. A file for it is
;;; therefore unused rather than unavailable — the naming holds if that
;;; ever changes, which is the point of deriving it.

(define-module (localchimera fleet paths)
  #:use-module (srfi srfi-13)
  #:use-module (localchimera utils paths)
  #:export (provider-token-file))

(define (token-file-env provider)
  "LOCALCHIMERA_<PROVIDER>_TOKEN_FILE — the per-provider path override."
  (string-append "LOCALCHIMERA_"
                 (string-upcase (string-map (lambda (c)
                                              (if (char=? c #\-) #\_ c))
                                            provider))
                 "_TOKEN_FILE"))

(define* (provider-token-file provider #:optional data-dir)
  "Absolute path to PROVIDER's on-disk token, e.g. \"sporestack\" →
/var/lib/localchimera/sporestack-token.txt. DATA-DIR is the caller's own state
directory when it was handed one; the per-provider environment variable
outranks it. See (localchimera utils paths) for the full resolution order."
  (state-file (string-append provider "-token.txt")
              #:data-dir data-dir
              #:env (token-file-env provider)))
