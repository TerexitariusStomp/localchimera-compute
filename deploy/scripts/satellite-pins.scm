#!/usr/bin/env -S guile -L module
!#
;;; deploy/scripts/satellite-pins.scm — verify and move the satellite pins
;;;
;;;   satellite-pins.scm check            every pin in deploy/satellites.scm
;;;                                       resolves in its local clone and its
;;;                                       tree hashes to the pinned sha256
;;;   satellite-pins.scm bump <name>      rewrite <name>'s pin to the clone's
;;;                                       HEAD and its hash, then check
;;;   satellite-pins.scm place <dir>      for every pin with a `lands`, put the
;;;                                       pinned tree at <dir>/<lands> (hash
;;;                                       verified; a no-op when the stamp
;;;                                       there already names the commit)
;;;   satellite-pins.scm link <dir>       on a machine that holds the clones,
;;;                                       make <dir>/<lands> a symlink to each
;;;                                       clone: one copy, edited in place
;;;   satellite-pins.scm workspace <dir> [name …]
;;;                                       clone what is missing from the mirror,
;;;                                       then link: every checkout the same shape
;;;   satellite-pins.scm list             one TSV line per pin
;;;
;;; The local clone of satellite NAME is $PLAYNET_SATELLITES_DIR/playnet-NAME,
;;; default ../playnet-NAME beside this repo; when that is absent and RAD_HOME
;;; is set, the node's own bare storage $RAD_HOME/storage/<rid-bare> is used
;;; (the box seeds every satellite, so `place` needs no clone there). The hash is what Guix computes
;;; for a git-fetch origin: the nar of the tree with no .git inside. We export
;;; the pinned commit with `git archive` into a scratch dir and hash that, so
;;; an unclean working tree in the clone never leaks into the pin.
;;;
;;; Exit status is the verdict: 0 all pins good, 1 otherwise. Output is one
;;; line per satellite so the pre-push hook can print it as is.

(use-modules (ice-9 popen) (ice-9 rdelim) (ice-9 match) (ice-9 format) (ice-9 regex)
             (srfi srfi-1))

(define here (dirname (dirname (dirname (canonicalize-path (car (command-line)))))))
(define pins-file (string-append here "/deploy/satellites.scm"))

(define (aref a k) (let ((p (assq k a))) (and p (cdr p))))

(define (read-pins)
  (call-with-input-file pins-file
    (lambda (p)
      ;; the file is comments + one (list …) form; evaluate it
      (let loop ((form (read p)) (last #f))
        (if (eof-object? form) (eval last (current-module))
            (loop (read p) form))))))

(define (clone-dir name . rid)
  "The sibling clone, else the node's bare storage for RID when RAD_HOME is set."
  (let ((sibling (string-append (or (getenv "PLAYNET_SATELLITES_DIR") (dirname here))
                                "/playnet-" name))
        (rid (and (pair? rid) (car rid))))
    (cond
     ((file-exists? sibling) sibling)
     ((and rid (getenv "RAD_HOME"))
      (string-append (getenv "RAD_HOME") "/storage/"
                     (if (string-prefix? "rad:" rid) (substring rid 4) rid)))
     (else sibling))))

(define (run . args)
  "Run ARGS, return (status . trimmed-stdout)."
  (let* ((port (apply open-pipe* OPEN_READ args))
         (out (read-string port))
         (st (close-pipe port)))
    (cons (status:exit-val st) (string-trim-both out))))

(define (git dir . args) (apply run "git" "-C" dir args))

(define (tree-hash dir commit)
  "nar hash of DIR's tree at COMMIT, exported without .git."
  (let* ((tmp (string-append (or (getenv "TMPDIR") "/tmp")
                             "/satellite-pin-" (number->string (getpid))))
         (_ (mkdir tmp))
         (st (system (format #f "git -C ~s archive ~a | tar -x -C ~s" dir commit tmp)))
         (h (and (zero? (status:exit-val st))
                 (run "guix" "hash" "-r" "--serializer=nar" tmp))))
    (system (string-append "rm -rf " tmp))
    (and h (zero? (car h)) (cdr h))))

(define (check-one pin)
  "Return #t when PIN is good; print one verdict line either way."
  (let* ((name (aref pin 'name)) (dir (clone-dir name (aref pin 'rid)))
         (commit (aref pin 'commit)) (want (aref pin 'sha256)))
    (cond
     ((not (file-exists? dir))
      (format #t "~a: no clone at ~a (PLAYNET_SATELLITES_DIR)~%" name dir) #f)
     ((not (zero? (car (git dir "cat-file" "-e" (string-append commit "^{commit}")))))
      (format #t "~a: pinned commit ~a is not in ~a~%" name commit dir) #f)
     (else
      (let ((have (tree-hash dir commit)))
        (cond
         ((not have) (format #t "~a: could not hash ~a at ~a~%" name dir commit) #f)
         ((not (string=? have want))
          (format #t "~a: hash mismatch at ~a~%   pinned ~a~%   tree   ~a~%"
                  name commit want have) #f)
         (else
          (format #t "~a: ok ~a~a~%" name (substring commit 0 8)
                  (if (aref pin 'rid) "" "  (rid #f: not yet on Radicle — no route, no seed)"))
          (report-drift name dir commit)
          #t)))))))

(define (report-drift name dir commit)
  "Say how the clone's working state stands against the pin. The pin is what
ships; a linked checkout (`link`) runs the clone, so the distance is worth a line."
  (let ((ahead (git dir "rev-list" "--count" (string-append commit "..HEAD")))
        (dirty (git dir "status" "--porcelain")))
    (when (and (zero? (car ahead)) (not (string=? (cdr ahead) "0")))
      (format #t "   ~a commit(s) past the pin in ~a — ships after: make bump SAT=~a~%"
              (cdr ahead) dir name))
    (when (and (zero? (car dirty)) (not (string-null? (cdr dirty))))
      (format #t "   uncommitted changes in ~a~%" dir))))

(define (check)
  (let ((ok (every-verdict (map check-one (read-pins)))))
    (exit (if ok 0 1))))

(define (every-verdict vs) (every identity vs))

(define (bump name)
  (let* ((pins (read-pins))
         (pin (find (lambda (p) (string=? (aref p 'name) name)) pins)))
    (unless pin
      (format #t "no satellite named ~a in ~a~%" name pins-file) (exit 1))
    (let* ((dir (clone-dir name))
           (head (git dir "rev-parse" "HEAD"))
           (dirty (git dir "status" "--porcelain")))
      (unless (zero? (car head))
        (format #t "~a: no clone at ~a~%" name dir) (exit 1))
      (unless (string-null? (cdr dirty))
        (format #t "~a: clone at ~a has uncommitted changes; commit them first~%" name dir)
        (exit 1))
      (let* ((commit (cdr head))
             (hash (tree-hash dir commit))
             (rid (let ((r (git dir "config" "--get" "remote.rad.url")))
                    (and (zero? (car r))
                         (let ((m (string-match "rad://([A-Za-z0-9]+)" (cdr r))))
                           (and m (string-append "rad:" (match:substring m 1))))))))
        (unless hash (format #t "~a: could not hash~%" name) (exit 1))
        ;; textual rewrite: the file is hand-commented, so only the three
        ;; fields move and every comment stays
        (let* ((src (call-with-input-file pins-file read-string))
               (block-start (string-contains src (string-append "(name   . \"" name "\")")))
               (block-end (or (string-contains src "(name   . " (+ block-start 1))
                              (string-length src)))
               (block (substring src block-start block-end))
               ;; keeps the column alignment: only the value moves
               (sub (lambda (s key val)
                      (let ((m (string-match (string-append "(\\(" key " +\\. )[^)]*\\)") s)))
                        (if m
                            (string-append (substring s 0 (match:end m 1))
                                           val ")"
                                           (substring s (match:end m)))
                            s))))
               (block* (sub (sub (sub block "commit" (format #f "~s" commit))
                                 "sha256" (format #f "~s" hash))
                            ;; a clone made from the mirror has no rad remote to
                            ;; read the RID from; the pin already names it
                            "rid" (cond (rid (format #f "~s" rid))
                                        ((aref pin 'rid) (format #f "~s" (aref pin 'rid)))
                                        (else "#f")))))
          (call-with-output-file pins-file
            (lambda (p) (display (string-append (substring src 0 block-start)
                                                block*
                                                (substring src block-end))
                                 p)))
          (format #t "~a: pinned ~a ~a~a~%" name (substring commit 0 8) hash
                  (if (or rid (aref pin 'rid)) "" "  (rid still #f)")))))
    (check)))

(define (list-pins)
  (for-each (lambda (pin)
              (format #t "~a\t~a\t~a\t~a\t~a~%" (aref pin 'name) (or (aref pin 'rid) "-")
                      (aref pin 'commit) (aref pin 'sha256) (or (aref pin 'lands) "-")))
            (read-pins)))

(define (place root)
  "Put every landing satellite's pinned tree at ROOT/<lands>, hash-verified.
A stamp file <lands>/.satellite-pin holding the commit makes a repeat a no-op."
  (let ((ok #t))
    (for-each
     (lambda (pin)
       (let* ((name (aref pin 'name)) (lands (aref pin 'lands))
              (commit (aref pin 'commit)) (want (aref pin 'sha256))
              (dir (clone-dir name (aref pin 'rid))))
         (when lands
           (let* ((dest (string-append root "/" lands))
                  (stamp (string-append dest "/.satellite-pin"))
                  (placed (and (file-exists? stamp)
                               (string=? (string-trim-both
                                          (call-with-input-file stamp read-string))
                                         commit))))
             (cond
              (placed (format #t "~a: in place at ~a (~a)~%" name lands (substring commit 0 8)))
              ((not (file-exists? dir))
               (format #t "~a: no source for ~a (clone or RAD_HOME storage)~%" name commit)
               (set! ok #f))
              ((not (zero? (car (git dir "cat-file" "-e" (string-append commit "^{commit}")))))
               (format #t "~a: commit ~a is not in ~a (seed not synced yet?)~%" name commit dir)
               (set! ok #f))
              (else
               (let* ((tmp (string-append dest ".incoming-" (number->string (getpid))))
                      (_ (system (string-append "rm -rf " tmp)))
                      (_ (mkdir tmp))
                      (st (system (format #f "git -C ~s archive ~a | tar -x -C ~s" dir commit tmp)))
                      (have (and (zero? (status:exit-val st))
                                 (let ((h (run "guix" "hash" "-r" "--serializer=nar" tmp)))
                                   (and (zero? (car h)) (cdr h))))))
                 (cond
                  ((not have)
                   (format #t "~a: export or hash failed~%" name)
                   (system (string-append "rm -rf " tmp)) (set! ok #f))
                  ((not (string=? have want))
                   (format #t "~a: hash mismatch — pinned ~a, got ~a; NOT placed~%" name want have)
                   (system (string-append "rm -rf " tmp)) (set! ok #f))
                  (else
                   ;; the hash is over the bare tree; the stamp goes in after
                   (call-with-output-file (string-append tmp "/.satellite-pin")
                     (lambda (p) (display commit p) (newline p)))
                   (system (format #f "rm -rf ~s.old; [ -e ~s ] && mv ~s ~s.old; mv ~s ~s; rm -rf ~s.old"
                                   dest dest dest dest tmp dest dest))
                   (format #t "~a: placed ~a at ~a~%" name (substring commit 0 8) lands))))))))))
     (read-pins))
    (exit (if ok 0 1))))

;; ── link: a development checkout runs the clones themselves ─────────────────
;; `place` copies the pinned tree in, which is what the box serves. On a
;; machine that holds the clones, `link` makes ROOT/<lands> a symlink to
;; ../playnet-<name> instead: one copy of every file, an edit under <lands> is
;; an edit in the satellite's own repo (its `git status` shows it), and build
;; products land in the clone. The pin still decides what ships — `check`
;; says how far each clone stands past its pin — and `place` puts the pinned
;; copy back (a Guix build of a satellite package reads only a placed tree).

(define (symlink-at? path)
  (let ((st (false-if-exception (lstat path))))
    (and st (eq? (stat:type st) 'symlink))))

(define (link-target root lands dir)
  "DIR as the symlink at ROOT/LANDS names it: relative while the clone is the
sibling of ROOT, so the pair moves together; absolute otherwise."
  (if (and (not (getenv "PLAYNET_SATELLITES_DIR"))
           (string=? (canonicalize-path root) here))
      (string-append (string-join (map (const "..") (string-split lands #\/)) "/")
                     "/" (basename dir))
      dir))

(define (carry-build-products! dest dir)
  "Move what a build left in the placed copy (target/, pkg/, …) into the clone,
and keep it out of the clone's `git status` through .git/info/exclude."
  (for-each
   (lambda (entry)
     (unless (or (member entry '("." ".." ".satellite-pin"))
                 (false-if-exception (lstat (string-append dir "/" entry))))
       (rename-file (string-append dest "/" entry) (string-append dir "/" entry))
       (let* ((exclude (string-append dir "/.git/info/exclude"))
              (line (string-append "/" entry))
              (have (if (file-exists? exclude)
                        (string-split (call-with-input-file exclude read-string) #\newline)
                        '())))
         (unless (member line have)
           (let ((p (open-file exclude "a")))
             (display line p) (newline p) (close-port p))))
       (format #t "   carried ~a into ~a~%" entry dir)))
   (let ((d (opendir dest)))
     (let loop ((e (readdir d)) (acc '()))
       (if (eof-object? e) (begin (closedir d) acc)
           (loop (readdir d) (cons e acc)))))))

(define (edits-only-here dest dir stamp commit)
  "The files under DEST that differ both from the tree it was placed from and
from the clone's working copy — edits that exist nowhere else — or #f."
  (let* ((from (if (file-exists? stamp)
                   (string-trim-both (call-with-input-file stamp read-string))
                   commit))
         (changed (run "git" "--git-dir" (string-append dir "/.git") "--work-tree" dest
                       "diff" "--name-only" from "--"))
         (only (filter (lambda (f)
                         (not (zero? (system* "cmp" "-s" (string-append dest "/" f)
                                              (string-append dir "/" f)))))
                       (remove string-null? (string-split (cdr changed) #\newline)))))
    (and (pair? only) only)))

(define (link root names)
  "Link every landing satellite (only NAMES, when non-empty) to its clone."
  (let ((ok #t))
    (for-each
     (lambda (pin)
       (let* ((name (aref pin 'name)) (lands (aref pin 'lands))
              (dir (clone-dir name)))
         (when (and lands (or (null? names) (member name names)))
           (let* ((dest (string-append root "/" lands))
                  (stamp (string-append dest "/.satellite-pin")))
             (cond
              ((symlink-at? dest)
               (format #t "~a: ~a → ~a~%" name lands (readlink dest)))
              ((not (file-exists? (string-append dir "/.git")))
               (format #t "~a: no clone at ~a to link~%" name dir) (set! ok #f))
              ((and (file-exists? dest)
                    (edits-only-here dest dir stamp (aref pin 'commit)))
               => (lambda (files)
                    (format #t "~a: ~a holds edits found nowhere else (~a) — carry them into ~a first~%"
                            name lands (string-join files ", ") dir)
                    (set! ok #f)))
              (else
               (when (file-exists? dest)
                 (carry-build-products! dest dir)
                 (system* "rm" "-rf" dest))
               (symlink (link-target root lands dir) dest)
               (format #t "~a: ~a → ~a~%" name lands (readlink dest))))))))
     (read-pins))
    (exit (if ok 0 1))))

;; ── workspace: the clones themselves, then the links ─────────────────────────
;; The one command that gives every checkout of the core the same shape: each
;; satellite that lands in the tree is cloned beside the core when it is not
;; there yet — from the mirror the box serves, https://<host>/<rid>.git, over
;; torsocks when the host has no direct route — and linked in.

(define (mirror-base) (or (getenv "PLAYNET_MIRROR") "https://playnet.earth"))

(define (mirror-url pin)
  (let ((rid (aref pin 'rid)))
    (and rid (string-append (mirror-base) "/"
                            (if (string-prefix? "rad:" rid) (substring rid 4) rid) ".git"))))

(define (net-prefix url)
  "The command words a network git call runs under: PLAYNET_GIT_PREFIX when
set, torsocks when the host of an http(s) URL does not resolve, else none."
  (cond
   ((getenv "PLAYNET_GIT_PREFIX")
    => (lambda (p) (remove string-null? (string-split p #\space))))
   ((let ((m (string-match "^https?://([^/:]+)" url)))
      (and m (not (zero? (status:exit-val
                          (system* "getent" "hosts" (match:substring m 1)))))))
    '("torsocks"))
   (else '())))

(define (clone-missing! pin)
  "#t when PIN's clone is present afterwards."
  (let* ((name (aref pin 'name)) (dir (clone-dir name)) (url (mirror-url pin)))
    (cond
     ((file-exists? (string-append dir "/.git")) #t)
     ((not url) (format #t "~a: no RID yet, so no mirror to clone from~%" name) #f)
     (else
      (format #t "~a: cloning ~a~%" name url)
      (let ((st (status:exit-val
                 (apply system* (append (net-prefix url)
                                        (list "git" "clone" "--quiet" url dir))))))
        (cond
         ((not (zero? st)) (format #t "~a: clone failed (exit ~a)~%" name st) #f)
         ((not (zero? (car (git dir "cat-file" "-e"
                                (string-append (aref pin 'commit) "^{commit}")))))
          (format #t "~a: cloned, but the pinned commit ~a is not in it yet — the mirror lags the pin~%"
                  name (substring (aref pin 'commit) 0 8))
          #t)
         (else #t)))))))

(define (workspace root names)
  (let* ((pins (filter (lambda (p) (and (aref p 'lands)
                                        (or (null? names) (member (aref p 'name) names))))
                       (read-pins)))
         (unknown (filter (lambda (n) (not (find (lambda (p) (string=? (aref p 'name) n)) pins)))
                          names)))
    (for-each (lambda (n) (format #t "~a: not a satellite that lands in the tree~%" n)) unknown)
    (let ((ok (every identity (map clone-missing! pins))))
      (unless ok (format #t "some clones are missing; linking the ones that exist~%"))
      (link root (map (lambda (p) (aref p 'name)) pins)))))

(match (cdr (command-line))
  (("check") (check))
  (("bump" name) (bump name))
  (("place" root) (place root))
  (("link" root) (link root '()))
  (("workspace" root . names) (workspace root names))
  (("list") (list-pins))
  (_ (display "usage: satellite-pins.scm check | bump <name> | place <dir> | link <dir> | workspace <dir> [name …] | list\n") (exit 2)))
