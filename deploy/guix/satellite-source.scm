;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/satellite-source.scm — a satellite pin as a Guix package source
;;;
;;; deploy/satellites.scm pins every repo the core consumes by commit and nar
;;; hash, and `satellite-pins.scm place` puts each pinned tree at its `lands`
;;; path inside this checkout, hash-verified, with a `.satellite-pin` stamp
;;; naming the commit. A Guix package that builds a satellite (rns-bridge)
;;; takes its source from that placed tree through `satellite-source`, which
;;; refuses to lower unless the stamp names the pinned commit. So a
;;; reconfigure builds exactly the commit the core names, and a checkout whose
;;; tree was never placed, or was placed at another pin, stops before any build.
;;;
;;; Why a local file and not a git-fetch origin: the daemon fetches origins
;;; inside an isolated build environment that sees neither this checkout, nor
;;; a sibling clone, nor the node's Radicle storage, and the box's egress is
;;; Tor-only, which the daemon's fetcher cannot use. Verified 2026-09-12: a
;;; file:// origin fails with "does not appear to be a git repository" from
;;; inside the builder. The hash check therefore happens at placement, on
;;; the host, where the bytes are.

(define-module (satellite-source)
  #:use-module (guix gexp)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 popen)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (satellite-pin satellite-source))

(define %here
  ;; -L deploy/guix puts this module on the load path (os.scm, machines.scm,
  ;; the reconfigure recipe all do); current-filename is #f once compiled.
  (dirname (or (search-path %load-path "satellite-source.scm")
               (current-filename)
               (error "satellite-source: cannot locate deploy/guix on the load path"))))

(define %checkout (canonicalize-path (string-append %here "/../..")))
(define %pins-file (string-append %checkout "/deploy/satellites.scm"))

(define (read-pins)
  (call-with-input-file %pins-file
    (lambda (p)
      (let loop ((form (read p)) (last #f))
        (if (eof-object? form)
            (eval last (current-module))
            (loop (read p) form))))))

(define (aref a k) (let ((p (assq k a))) (and p (cdr p))))

(define (satellite-pin name)
  "The pin alist for satellite NAME, or an error naming the file."
  (or (find (lambda (pin) (string=? (aref pin 'name) name)) (read-pins))
      (error "satellite-source: no satellite named" name %pins-file)))

(define (linked-head dir)
  "The commit DIR's clone stands at, when DIR is a symlink to a clean clone
(a checkout made by `make workspace`); else #f. A clean clone at the pinned
commit holds exactly the pinned tree, so it stands in for the placed copy."
  (and (eq? (stat:type (lstat dir)) 'symlink)
       (let* ((run (lambda (. args)
                     (let* ((p (apply open-pipe* OPEN_READ "git" "-C" dir args))
                            (out (string-trim-both (read-string p))))
                       (and (zero? (status:exit-val (close-pipe p))) out))))
              (head (run "rev-parse" "HEAD"))
              (dirty (run "status" "--porcelain")))
         (and head dirty (string-null? dirty) head))))

(define (placed-tree name)
  "The placed tree of satellite NAME as a recursive local-file, only when its
stamp names the pinned commit. Build products and the stamp stay out."
  (let* ((pin (satellite-pin name))
         (lands (or (aref pin 'lands)
                    (error "satellite-source: satellite does not land in the tree" name)))
         (dir (string-append %checkout "/" lands))
         (stamp-file (string-append dir "/.satellite-pin"))
         (stamp (or (and (file-exists? stamp-file)
                         (string-trim-both
                          (call-with-input-file stamp-file read-string)))
                    (and (file-exists? dir) (linked-head dir))))
         (commit (aref pin 'commit)))
    (unless (and stamp (string=? stamp commit))
      (error (string-append
              "satellite-source: " lands " is not placed at the pinned commit "
              (substring commit 0 8) " — run `make satellites` (laptop), or let the "
              "CI hook place it (box); a linked clone counts when it is clean and "
              "at the pin; found: " (or stamp "no stamp"))))
    (local-file dir (string-append name "-" (substring commit 0 8) "-checkout")
                #:recursive? #t
                #:select? (lambda (file stat)
                            (not (or (string-suffix? "/.satellite-pin" file)
                                     (string-suffix? "/.git" file)
                                     (string-suffix? "/target" file)
                                     (string-suffix? "/pkg" file)
                                     (string-suffix? "/vendor" file)))))))

;; The check runs when Guix lowers the tree to a derivation, the first moment
;; anything needs the bytes. Loading this module, and every module that imports
;; it, stays free of effects, so a tool that scans deploy/guix (`guix shell -L`)
;; loads it whether or not the satellite is placed. A reconfigure or `guix
;; build` of the package still stops at the same message.
(define-record-type <satellite-tree>
  (satellite-tree name)
  satellite-tree?
  (name satellite-tree-name))

(define-gexp-compiler (satellite-tree-compiler (tree <satellite-tree>)
                                               system target)
  (lower-object (placed-tree (satellite-tree-name tree))
                system #:target target))

(define (satellite-source name)
  "A package source for satellite NAME, checked against its pin at lowering."
  (satellite-pin name)                  ; an unknown name fails here, at load
  (satellite-tree name))
