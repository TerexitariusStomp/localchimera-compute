;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; rad-issues.scm — the repository's Radicle issues, read through `rad`.
;;;
;;; The I/O half of the development loop's reading: shell out to `rad cob`,
;;; hand back each issue as (OID . JSON-ALIST). What an issue states is read
;;; off that pair by (localchimera dev priorities), which is pure.
;;; tools/dev/dev-signal-cycle.scm, tools/dev/dev-plan.scm and tools/dev/dev-loop-close.scm
;;; read the issues through this one door.

(define-module (localchimera dev rad-issues)
  #:use-module ((localchimera utils common) #:select (capture non-empty-lines))
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (rad-self-rid rad-cob-list rad-cob-show rad-issue-pairs))

(define (rad-self-rid)
  (or (getenv "LOCALCHIMERA_RID")
      (let ((out (capture (list "rad" "."))))
        (and out (string-trim-both out)))))

(define (rad-cob-list rid)
  (let ((out (capture (list "rad" "cob" "list" "--repo" rid
                            "--type" "xyz.radicle.issue"))))
    (if (not out) '() (non-empty-lines out))))

(define (rad-cob-show rid oid)
  (let ((out (capture (list "rad" "cob" "show" "--repo" rid
                            "--type" "xyz.radicle.issue"
                            "--object" oid "--format" "json"))))
    (and out
         (catch #t (lambda () (json-string->scm out)) (lambda _ #f)))))

(define (rad-issue-pairs)
  "Every issue's (OID . JSON-ALIST), open and ended, skipping any single OID
   `rad cob show` fails to answer for (a corrupt/unreadable COB leaves the
   rest standing). The readers filter by state off the JSON itself."
  (let ((rid (rad-self-rid)))
    (if (not rid)
        '()
        (filter-map (lambda (oid)
                      (let ((json (rad-cob-show rid oid)))
                        (and json (cons oid json))))
                    (rad-cob-list rid)))))
