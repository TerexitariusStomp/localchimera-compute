;;; module/playnet/identity/user-files.scm — the per-AID files a gateway keeps
;;;
;;; A member's own things, synced from their device and held in custody here:
;;; the contact book, the captain's log, the sealed credential backup, the
;;; pin book, the taxonomy cut, the week's allotment reads, the recovery
;;; shares. One file per kind per AID, `<data-dir>/<kind>-<aid16>.scm`, read
;;; by the session's sync doors (doors/lobby.scm) and by nothing the
;;; planner or observer folds history from: the pin and taxonomy files are
;;; re-folded at boot into the scope's live aggregates (`%seed-user-docs!`),
;;; the contact book is read for whom a person knows NOW (server/gateway.scm
;;; make-knows). Erasure of a member deletes every kind in one call
;;; (`user-files-forget!`, identity/forget.scm); the kinds are listed once,
;;; here, so a new kind is a one-line addition that the forget follows.

(define-module (playnet identity user-files)
  #:use-module ((playnet vf facts limits) #:select (%max-user-data-bytes))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((rnrs bytevectors) #:select (bytevector? bytevector-length string->utf8))
  #:use-module ((srfi srfi-1) #:select (count))
  #:export (%data-dir %user-file %user-file-kinds
            %read-user-data %write-user-data! %seed-user-docs!
            user-files-forget!))

(define (%data-dir)
  (or (getenv "PLAYNET_DATA_DIR")
      (string-append (or (getenv "HOME") "/tmp")
                     "/.local/state/playnet")))

(define (%user-file kind aid-prefix)
  (string-append (%data-dir) "/" kind "-"
                 (substring aid-prefix 0 (min 16 (string-length aid-prefix)))
                 ".scm"))

;; every kind of per-AID file the session keeps — what a forget erases
(define %user-file-kinds
  '("contacts" "credentials" "taxonomy" "log" "pins" "allotment" "shamir"))

(define (user-files-forget! aid-prefix)
  "Delete every kind of per-AID file AID-PREFIX has; reply how many stood.
   Idempotent: none stood replies 0."
  (count (lambda (kind)
           (let ((f (%user-file kind aid-prefix)))
             (and (file-exists? f) (begin (delete-file f) #t))))
         %user-file-kinds))

;; Per-AID sync payloads funnel through %write-user-data!, which holds each to
;; %max-user-data-bytes (vf/facts/limits.scm).

(define (%user-data-size data)
  "Byte size of a sync payload: the bytevector length for an encrypted blob,
   else the serialised length."
  (if (bytevector? data)
      (bytevector-length data)
      (bytevector-length
       (string->utf8 (call-with-output-string (lambda (p) (write data p)))))))

(define (%write-user-data! file data)
  (let ((sz (%user-data-size data)))
    (when (> sz %max-user-data-bytes)
      (error "sync payload exceeds cap" sz %max-user-data-bytes)))
  (let ((dir (dirname file)))
    (unless (file-exists? dir)
      (catch 'system-error (lambda () (mkdir dir)) (lambda _ #f)))
    (call-with-output-file file
      (lambda (p) (write data p) (newline p)))))

(define (%read-user-data file)
  (if (file-exists? file) (call-with-input-file file read) '()))

;; the one scanner the boot seeds share (doors/lobby.scm seed-pins!,
;; seed-taxonomy-docs!): every aid-wrapped PREFIX file in the data dir,
;; handed to CONTRIBUTE! as (aid doc); a bad file is skipped
(define (%seed-user-docs! prefix contribute!)
  (let ((dir (%data-dir)))
    (for-each
     (lambda (f)
       (catch #t
         (lambda ()
           (let ((v (%read-user-data (string-append dir "/" f))))
             (when (and (list? v) (assq 'aid v) (assq 'doc v))
               (contribute! (cdr (assq 'aid v)) (cdr (assq 'doc v))))))
         (lambda _ #f)))
     (filter (lambda (f) (string-prefix? prefix f))
             (or (scandir dir) '())))))
