;;; server/planner-loader.scm — load the planner files into top-level
;;;
;;; The planner is not a Guile module: planner/load-all.scm uses
;;; (load "lib/...") with relative paths, so the caller's cwd must be
;;; planner/ for the chain to resolve. We chdir, primitive-load, and
;;; restore the original cwd.
;;;
;;; Override the planner location with PLAYNET_PLANNER_DIR if needed.

(define %planner-loader-original-cwd (getcwd))

(define %planner-root
  (or (getenv "PLAYNET_PLANNER_DIR")
      (string-append %planner-loader-original-cwd "/planner")))

(unless (file-exists? (string-append %planner-root "/load-all.scm"))
  (error "planner-loader: cannot find load-all.scm in" %planner-root
         "— set PLAYNET_PLANNER_DIR or run gateway from project root"))

;; Resolve any RELATIVE entries in %load-path against the original cwd
;; BEFORE we chdir into planner/. Otherwise -L module from the gateway
;; invocation becomes planner/module/ after chdir and modules vanish.
(define (absolutize-load-path-entry p)
  (if (or (string=? p "")
          (char=? (string-ref p 0) #\/))
      p
      (string-append %planner-loader-original-cwd "/" p)))

(set! %load-path (map absolutize-load-path-entry %load-path))

;; planner/load-all.scm uses (load "lib/...") which searches %load-path,
;; not the current directory. Push the planner root onto the load path
;; for the duration of the load, then chdir + primitive-load and restore.
(set! %load-path (cons %planner-root %load-path))
(chdir %planner-root)
(primitive-load "load-all.scm")
(chdir %planner-loader-original-cwd)
(set! %load-path (cdr %load-path))
