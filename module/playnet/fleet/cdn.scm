;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/fleet/cdn.scm — the CDN protocol
;;;
;;; A clearnet face sits behind a CDN: the edge terminates TLS, caches the
;;; heavy assets, and is the only party that reaches the origin. Which CDN
;;; that is belongs to a deployment, the same way its hosting provider does,
;;; so everything here speaks of "the CDN" and finds the adapter by NAME.
;;;
;;; A CDN is an alist of 4 closures:
;;;
;;;   ensure-zone    : (name origin-url) → zone   (created when absent)
;;;   set-origin     : (zone-id origin-url) → #t
;;;   ensure-no-cache: (zone-id origin-url paths) → ((path . status) ...)
;;;                    status: 'exists | 'added | 'failed
;;;   purge          : (zone-id) → #t
;;;
;;; A zone is an alist: (id . "…") (hostname . "…") (origin . "…").
;;;
;;; The adapter for NAME is the module (playnet fleet cdn NAME), which
;;; exports `make-cdn : (credential #:key http) → cdn`. It is resolved at
;;; run time, so adding an adapter is adding a file.
;;;
;;; A deployment states its CDN in one file (os.scm writes it from the
;;; provider config's `cdn` entry), an alist:
;;;
;;;   ((adapter . "NAME") (zone . "ID") (origin . "https://example.org")
;;;    (key-file . "/run/secrets/cdn-api-key"))

(define-module (playnet fleet cdn)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:export (cdn-call
            make-cdn-by-name
            %cdn-config-file
            load-cdn-config
            cdn-config-ref
            cdn-from-config
            zone-ref))

(define (cdn-call cdn op . args)
  "Call operation OP on CDN with ARGS."
  (let ((pair (assq op cdn)))
    (unless pair
      (error "cdn: unknown operation" op))
    (apply (cdr pair) args)))

(define (zone-ref zone key)
  (assq-ref zone key))

(define (make-cdn-by-name name credential . rest)
  "The CDN whose adapter module is (playnet fleet cdn NAME)."
  (let* ((mod (resolve-module `(playnet fleet cdn ,(string->symbol name))
                              #:ensure #f))
         (make (and mod (module-variable mod 'make-cdn))))
    (unless make
      (error "cdn: no adapter named" name))
    (apply (variable-ref make) credential rest)))

;;; ── A deployment's CDN ────────────────────────────────────────────────────

(define %cdn-config-file
  (or (getenv "PLAYNET_CDN_CONFIG") "/etc/playnet/cdn.conf"))

(define* (load-cdn-config #:optional (file %cdn-config-file))
  "The deployment's CDN alist, or #f on a box that has none."
  (and (file-exists? file)
       (let ((v (call-with-input-file file read)))
         (and (pair? v) v))))

(define (cdn-config-ref config key)
  (assq-ref config key))

(define (cdn-from-config config . rest)
  "The CDN CONFIG names, holding the credential its key-file carries.
#f when the key file is absent or empty."
  (let* ((key-file (cdn-config-ref config 'key-file))
         (key (and key-file (file-exists? key-file)
                   (string-trim-both
                    (call-with-input-file key-file get-string-all)))))
    (and key (not (string-null? key))
         (apply make-cdn-by-name (cdn-config-ref config 'adapter) key rest))))
