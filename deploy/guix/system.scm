;;; deploy/guix/system.scm — operating-system for guix system reconfigure
;;;
;;; Usage (on the server):
;;;   guix system reconfigure -L /path/to/deploy/guix system.scm
;;;
;;; This file returns the bare operating-system, suitable for
;;; `guix system reconfigure`.  machines.scm wraps it in a (machine …)
;;; for `guix deploy`.

(load (string-append (dirname (or (current-filename)
                                  (canonicalize-path "deploy/guix/system.scm")))
                     "/machines.scm"))

%guix-x86
