;;; deploy/guix/system.scm — operating-system for guix system reconfigure
;;;
;;; Usage (on the server):
;;;   guix system reconfigure -L /path/to/deploy/guix system.scm
;;;
;;; This file returns the bare operating-system, suitable for
;;; `guix system reconfigure`.  machines.scm wraps it in a (machine …)
;;; for `guix deploy`.
;;;
;;; Note: current-filename returns #f when loaded by guix internals, so we
;;; resolve machines.scm relative to this file's directory using %load-path,
;;; which is set by the -L flag passed to guix system reconfigure.

(let ((machines (search-path %load-path "machines.scm")))
  (if machines
      (load machines)
      (error "machines.scm not found — pass -L /path/to/deploy/guix")))

%guix-x86
