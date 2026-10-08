;;; module/playnet/utils/paths.scm — where a deployment keeps its state.
;;;
;;; One answer to "where does this file live", because the question was
;;; being answered independently in a dozen places. The expression
;;;
;;;     (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet")
;;;
;;; was written out in the lobby, both chat bridges, the static server
;;; twice, and the gateway's boot path — and in the planner service it was
;;; written with a DIFFERENT default ("data"), which nobody chose and
;;; nothing documents. Restating a convention is how it stops being one.
;;;
;;; This module knows about deployment layout and nothing else. It has no
;;; idea what a provider, a credential or a token is; callers name their
;;; own files. Anything that needs to know which file belongs to which
;;; subsystem belongs a layer up — see (playnet fleet paths) for the
;;; provider credentials, which is the shape to copy.
;;;
;;; Resolution, most specific first:
;;;
;;;   an explicit override passed by the caller  — a --data-dir flag, a
;;;                                                boot parameter, a test
;;;   PLAYNET_DATA_DIR                           — the deployment says
;;;   /var/lib/playnet                           — the packaged default
;;;
;;; PROCEDURES, NOT CONSTANTS, and this is load-bearing. A constant is
;;; captured when its module initialises, so whether an override takes
;;; effect depends on setenv running before the module loads — a rule that
;;; can be written in a comment and enforced nowhere. Reading the
;;; environment at call time makes load order stop mattering. That
;;; distinction cost a test-suite failure that read as a race.

(define-module (playnet utils paths)
  #:export (playnet-data-dir
            state-file))

(define %default-data-dir "/var/lib/playnet")

(define* (playnet-data-dir #:optional override #:key default)
  "The deployment's persistent state directory. OVERRIDE wins when given,
then PLAYNET_DATA_DIR, then DEFAULT, then the packaged default.

DEFAULT is for a component that must stay runnable with nothing
configured — a relative directory a developer can write to without root.
It applies ONLY when nothing else is set, so a deployment that exports
PLAYNET_DATA_DIR still gets one answer everywhere. Pass it deliberately:
an unexplained per-caller default is how three of them appeared."
  (or override
      (getenv "PLAYNET_DATA_DIR")
      default
      %default-data-dir))

(define* (state-file name #:key data-dir env default)
  "Absolute path to NAME inside the deployment's state directory.

ENV, when given, names an environment variable holding the exact path to
this one file; it outranks every directory-level setting, which is what
lets a single file be redirected without moving the whole deployment.
DATA-DIR is the caller's own directory, for a component that was handed
one rather than reading the environment. DEFAULT is passed through to
`playnet-data-dir'."
  (or (and env (getenv env))
      (string-append (playnet-data-dir data-dir #:default default)
                     "/" name)))
