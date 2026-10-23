;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; law/pack-dir.scm — where the law packs stand on disk.
;;;
;;; The packs are the law's text, one file per jurisdiction or regime, in
;;; docs/legal/contexts/ beside the legal guidance. This module finds that
;;; directory from its own file's place: up the tree to the first directory that
;;; holds it, so a checkout, a scratch copy and a relative load path resolve alike.

(define-module (playnet knowledge law pack-dir)
  #:export (%contexts-dir))

(define %packs-relative "docs/legal/contexts")

(define %contexts-dir
  (cond-expand
   (guile
    (let ((file (or (current-filename)
                    (%search-load-path "playnet/knowledge/law/pack-dir.scm"))))
      (or (and file
               (let up ((d (dirname file)))
                 (let ((candidate (string-append d "/" %packs-relative)))
                   (cond ((file-exists? candidate) candidate)
                         ((string=? d (dirname d)) #f)
                         (else (up (dirname d)))))))
          %packs-relative)))
   ;; a page has no files: the directory is named, and holds nothing there
   (else %packs-relative)))
