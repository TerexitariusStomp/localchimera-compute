;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/site.scm — where this gateway keeps its state, and what its environment says.
;;;
;;; The one reading of the environment the boot shares: a path under the data
;;; directory (LOCALCHIMERA_DATA_DIR, else /var/lib/localchimera), the boot log line, the
;;; law packs, the founders, the gates on durable scopes and the demo seed, and
;;; the one-line files the boot keeps for the static server. Every module of
;;; boot/ reads these; nothing below boot/ does. server/gateway.scm lists the
;;; environment keys.

(define-module (localchimera boot site)
  #:use-module ((localchimera utils common) #:select (env-flag? non-empty-lines))
  #:use-module ((localchimera utils paths) #:select (durable-default? localchimera-data-dir))
  #:use-module ((ice-9 rdelim) #:select (read-line))
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:export (data-path log! law-packs founders scopes-durable? oobi-auto-mirror? seed-demo?
            keep-line! kept-line))

(define (data-path filename)
  "FILENAME under the data directory."
  (string-append (localchimera-data-dir) "/" filename))

;; The data directory exists from the first load: syrup stores need it at
;; creation time.
(catch #t (lambda () (mkdir (localchimera-data-dir))) (lambda args #f))

(define (log! fmt . args)
  "A boot log line on stderr, flushed at once: a log write may be the next
thing that fails."
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

;; The laws every scope born here starts under: a folder of rule-packs
;; (legal-registry.scm `load-rule-packs`), read into each new root's
;; ^legal-registry at spawn and persisted with it. Unset ⇒ no law.
(define (law-packs) (getenv "LOCALCHIMERA_LAW_PACKS"))

;; Founders: LOCALCHIMERA_FOUNDERS env (comma-sep) + /var/lib/localchimera/
;; founders.txt (one AID per line). They are seeded founder PHCs AND
;; act as the bootstrap governors (so they can verify newcomers) —
;; write founders.txt + restart to ACTIVATE First-Person; no reconfigure.
(define (founders)
  (let ((env  (non-empty-lines (or (getenv "LOCALCHIMERA_FOUNDERS") "") #\,))
        (file (let ((ff (data-path "founders.txt")))
                (if (file-exists? ff)
                    (catch #t
                      (lambda () (non-empty-lines (call-with-input-file ff get-string-all)))
                      (lambda _ '()))
                    '()))))
    (append env file)))

;; LOCALCHIMERA_SCOPES_DURABLE set to anything but "0": scopes restore from disk and
;; the UC, the founding commune and the seeded communes stand.
(define scopes-durable? durable-default?)

;; LOCALCHIMERA_OOBI_AUTO_MIRROR=0 opts out of the key-log mirrors every durable
;; scope publishes through.
(define (oobi-auto-mirror?)
  (not (equal? (getenv "LOCALCHIMERA_OOBI_AUTO_MIRROR") "0")))

;; Demo seed only in dev (LOCALCHIMERA_SEED_DEMO=1). Production starts CLEAN.
(define (seed-demo?) (env-flag? "LOCALCHIMERA_SEED_DEMO"))

(define (keep-line! path line)
  "LINE kept at PATH as its one line, written whole: a reader sees the old
file or the new. The static server reads these."
  (let ((tmp (string-append path ".tmp")))
    (call-with-output-file tmp (lambda (p) (display line p) (newline p)))
    (rename-file tmp path)
    line))

(define (kept-line path)
  "The line kept at PATH, trimmed, or #f when the file is absent or empty."
  (catch #t
    (lambda ()
      (and (file-exists? path)
           (let ((s (call-with-input-file path (lambda (p) (string-trim-both (read-line p))))))
             (and (string? s) (not (string=? s "")) s))))
    (lambda _ #f)))
