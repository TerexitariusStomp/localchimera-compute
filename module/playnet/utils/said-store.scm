;;; said-store.scm — a content-addressed-by-SAID disk store.
;;;
;;; The shared body beneath three append-only KERI stores that had each grown
;;; their own copy: governance/acdc-store (credentials), governance/kel-store
;;; (KEL events), and planner/observation/event-log (the portable event stream).
;;; Every one of them keeps records at:
;;;
;;;   <dir>/<said[0:2]>/<said>.scm        one Guile-readable s-expr per record
;;;
;;; Content addressing means two stores' directories can be merged by file copy
;;; (rsync / Syncthing / Radicle) and the union is still a valid store — equal
;;; SAIDs are the same file. This module owns ONLY that content-addressed body;
;;; each store layers its own sidecar/index (`_revoked.log`, `index.log`,
;;; `_head`, `_checkpoint`) and its own load ORDER on top.

(define-module (playnet utils said-store)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:export (said-prefix
            said-store-path
            said-store-ensure-dir!
            said-store-write!
            said-store-delete!
            said-store-scan))

(define (said-prefix said)
  "The 2-char shard a SAID lands in (its own first two characters)."
  (if (>= (string-length said) 2) (substring said 0 2) "__"))

(define (said-store-path dir said)
  (string-append dir "/" (said-prefix said) "/" said ".scm"))

(define (said-store-ensure-dir! dir)
  (unless (file-exists? dir) (mkdir dir)))

(define (said-store-write! dir said record)
  "Write RECORD (any writable s-expr) to its content-addressed path under DIR.
   No-op when DIR is #f (a pure in-memory store)."
  (when dir
    (said-store-ensure-dir! dir)
    (said-store-ensure-dir! (string-append dir "/" (said-prefix said)))
    (call-with-output-file (said-store-path dir said)
      (lambda (port) (write record port) (newline port)))))

(define (said-store-delete! dir said)
  "Remove SAID's file if present (used by compaction/pruning)."
  (when dir
    (let ((p (said-store-path dir said)))
      (when (file-exists? p) (delete-file p)))))

(define (said-store-scan dir)
  "Read every content-addressed record under DIR — descending only into its
   2-char shard directories, so top-level sidecar/index files are ignored.
   Returns the records in unspecified order; the caller imposes any ordering."
  (if (not (and dir (file-exists? dir))) '()
      (append-map
       (lambda (shard)
         (let ((sub (string-append dir "/" shard)))
           (if (and (not (string-prefix? "_" shard))
                    (eq? 'directory (stat:type (stat sub))))
               (filter-map
                (lambda (f)
                  (and (string-suffix? ".scm" f)
                       (call-with-input-file (string-append sub "/" f) read)))
                (scandir sub (lambda (f) (not (member f '("." ".."))))))
               '())))
       (scandir dir (lambda (f) (not (member f '("." "..")))))))
)
