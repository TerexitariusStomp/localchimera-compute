;;; manifest.scm — one-shot dev shell for the playnet repo.
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

;; Make `(hoot-fix)` resolvable so we get the patched guile-hoot. The
;; same trick lives in deploy/guix/machines.scm — we never want to
;; force operators to remember -L flags.
(eval-when (expand load eval)
  (add-to-load-path
   (string-append (dirname (or (current-filename) "manifest.scm"))
                  "/deploy/packages")))

(use-modules (guix)
             (guix packages)
             (gnu packages base)
             (gnu packages emacs)
             (gnu packages emacs-xyz)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages linux)         ; inotify-tools
             (gnu packages version-control)
             (hoot-fix))                  ; guile-hoot/fixed

(packages->manifest
 (list ;; ── Core Guile + build ────────────────────────────────────────
       guile-next
       gnu-make

       ;; ── Wasm toolchain (live hacking + production builds) ─────────
       ;; Patched Hoot is needed for `guild compile-wasm` (the upstream
       ;; mutable-bytevector? regression). Plain hoot would be enough
       ;; for the dev REPL itself, but bundling the patched one means
       ;; one shell does both jobs.
       guile-hoot/fixed
       guile-fibers          ; required by (hoot web-server)
       guile-websocket       ; required by (hoot web-server) /repl proxy

       ;; ── Server-side runtime deps ───────────────────────────────────
       guile-goblins         ; actor model used everywhere
       guile-json-4          ; weave / planner JSON I/O
       guile-gcrypt          ; crypto helpers (signatures, persistence)

       ;; ── Live-hacking tooling ───────────────────────────────────────
       inotify-tools         ; tools/live-watch.sh inotifywait loop

       ;; ── Editor + Geiser ────────────────────────────────────────────
       emacs-no-x
       emacs-geiser
       emacs-geiser-guile
       emacs-geiser-hoot     ; M-x connect-to-hoot for the in-wasm REPL
       emacs-smartparens
       emacs-rainbow-delimiters

       ;; ── Misc ──────────────────────────────────────────────────────
       git))
