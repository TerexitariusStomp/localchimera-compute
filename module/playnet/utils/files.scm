;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/utils/files.scm — writing state files, naming them safely
;;;
;;; Two things every module that keeps a file on disk needs:
;;;
;;;   write-atomically!  the file is either its old content or its new
;;;                      content, never a torn one: written beside itself,
;;;                      then renamed over. MODE is set before the rename,
;;;                      so a private file is private from its first byte.
;;;
;;;   path-component     a name that came from outside (a host name, a swap
;;;                      key) as ONE component of a path: it names a file in
;;;                      the directory it is put in, and nothing else.

(define-module (playnet utils files)
  #:export (write-atomically!
            path-component
            mkdir-private!))

(define* (write-atomically! file writer #:key (mode #f))
  "Call WRITER with a port; FILE then holds what it wrote. MODE, when
given, is the file's permission bits (e.g. #o600)."
  (let ((tmp (string-append file ".tmp"))
        (old-umask (umask (if mode (logxor #o777 (logand mode #o777)) (umask)))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (call-with-output-file tmp writer)
        (when mode (chmod tmp mode))
        (rename-file tmp file))
      (lambda () (umask old-umask)))))

(define (path-component name)
  "NAME with every character outside [A-Za-z0-9._-] replaced by _, and the
names that mean a directory (\"\", \".\", \"..\") replaced whole."
  (if (member name '("" "." ".."))
      "_"
      (string-map (lambda (c)
                    (if (or (char-alphabetic? c) (char-numeric? c)
                            (memv c '(#\- #\_ #\.)))
                        c
                        #\_))
                  name)))

(define (mkdir-private! dir)
  "DIR exists, with its missing ancestors, each made 0700."
  (unless (file-exists? dir)
    (mkdir-private! (dirname dir))
    (mkdir dir #o700)))
