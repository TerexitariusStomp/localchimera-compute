;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; manifest.scm — one-shot dev shell for the localchimera repo.
;;;
;;; Drop into a shell with everything needed to build, run, test, and
;;; live-hack the entire codebase:
;;;
;;;   guix time-machine -C deploy/guix/channels.scm -- shell -m manifest.scm
;;;
;;; The Make targets in `Makefile` use granular per-target package sets
;;; through the `*_RUN` variables — they're typically faster on first
;;; use because they pull fewer derivations. This manifest is the
;;; convenience option: one shell, every dep, no surprises.
;;;
;;; To extend: add to the list at the bottom. Keep granular sets in
;;; the Makefile in sync if the new dep is needed by a build target.

;; Make `(localchimera-hoot)` resolvable so we get the repo's guile-hoot. The
;; same trick lives in deploy/guix/machines.scm — we never want to
;; force operators to remember -L flags.
(eval-when (expand load eval)
  (add-to-load-path
   (string-append (dirname (or (current-filename) "manifest.scm"))
                  "/deploy/guix")))

(use-modules (guix)
             (guix packages)
             (gnu packages base)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages gnupg)         ; guile-gcrypt
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages lean)
             (gnu packages linux)         ; inotify-tools
             (gnu packages version-control)
             (localchimera-hoot))              ; guile-hoot/localchimera

(packages->manifest
 (list ;; ── Core Guile + build ────────────────────────────────────────
       guile-next
       gnu-make

       ;; ── Wasm toolchain (live hacking + production builds) ─────────
       ;; Hoot 0.9.0 plus the upstream number->string fixes
       ;; (deploy/guix/localchimera-hoot.scm): `guild compile-wasm` and the dev
       ;; REPL's (hoot web-server) come from one package.
       guile-hoot/localchimera
       guile-fibers          ; required by (hoot web-server)
       guile-websocket       ; required by (hoot web-server) /repl proxy

       ;; ── Server-side runtime deps ───────────────────────────────────
       guile-goblins         ; actor model used everywhere
       guile-json-4          ; planner / relay JSON I/O
       guile-gcrypt          ; crypto helpers (signatures, persistence)

       ;; ── Live-hacking tooling ───────────────────────────────────────
       inotify-tools         ; tools/dev/live-watch.sh inotifywait loop

       ;; ── Editor + Geiser ────────────────────────────────────────────
       emacs-no-x
       emacs-geiser
       emacs-geiser-guile
       emacs-geiser-hoot     ; M-x connect-to-hoot for the in-wasm REPL
       emacs-smartparens
       emacs-rainbow-delimiters
       guile-wisp            ; the wisp language + wisp-mode.el (.w highlighting,
                             ; tab-cycle indent, rainbow-indent minor mode)
       emacs-lean4-mode      ; .lean highlighting + interactive goal-state display

       ;; ── Misc ──────────────────────────────────────────────────────
       git
       lean4))
