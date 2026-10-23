;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; playnet-repl.scm — Two-tier REPL entry point for playnet
;;; Run with:  guile playnet-repl.scm
;;;
;;; Outer REPL: full Guile Scheme with readline, history, tab completion.
;;; Use (enter! org) to drop into an org's inner REPL.

(add-to-load-path "module")

(use-modules (ice-9 readline)
             (playnet org gplay))

(activate-readline)

;;; ── Banner ─────────────────────────────────────────────────────────────────

(display "\
 ___  ___  ____  _____  ____       ___   ____    ___
|   \\/   ||  __||_   _||  _ \\    / _ \\ |  _ \\  / __|
| |\\  /| || |_    | |  | |_| |  | | | || |_| || | _
| | \\/ | ||  _|   | |  |  _ |   | | | ||    / | |_| |
|_|    |_||____| |___| |_| |_|   \\___|/|_|\\_\\  \\___|

  Two-tier REPL for playnet

  Outer REPL commands:
    (make-org \"name\")      -- create a new org
    (enter! org)            -- drop into an org's inner REPL
    (list-orgs)             -- show all created orgs
    (org-bindings org)      -- inspect an org's bindings
    (org-history org)       -- inspect an org's history

  Inside an org:
    (modify! 'name value)   -- governed binding
    (define name value)     -- governed binding (familiar syntax)
    (exit!)                 -- return to outer REPL
    ,help                   -- show inner REPL commands

")

;;; ── Start the outer REPL ───────────────────────────────────────────────────

(use-modules (system repl repl))
(start-repl)
