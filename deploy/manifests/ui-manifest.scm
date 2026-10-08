;;; deploy/manifests/ui-manifest.scm — the TypeScript checker/emitter env
;;;
;;; `ui/` holds TypeScript sources whose emitted JavaScript is committed
;;; under `browser/`. tsc is the only tool that reads or writes either, so
;;; it gets its own small manifest rather than a line in
;;; dev-test-manifest.scm: every Scheme suite would otherwise pull a Node
;;; toolchain it never calls.
;;;
;;; Bypasses `guix time-machine` for the same reason as the other dev
;;; manifests — see dev-test-manifest.scm's header for the Radicle-seed /
;;; libgit2 explainer and the reproducibility trade.
;;;
;;; ── Usage ───────────────────────────────────────────────────────────────────
;;;
;;;   guix shell --pure -m deploy/manifests/ui-manifest.scm -- tsc -p tsconfig.json
;;;
;;; Invoked by the Makefile's `ui`, `ui-check`, `ui-watch` and
;;; `check-ui-fresh` targets via $(UI_ENV).

(specifications->manifest
 '("node-typescript"                  ;; tsc itself (5.8.3)
   ;; check-ui-fresh emits to a scratch dir and diffs it against the
   ;; committed output, so the gate needs the same shell utilities the
   ;; other gates name rather than inheriting them from the host.
   "coreutils"
   "sed"                              ;; the gate indents tsc's log when it fails
   "diffutils"
   "findutils"
   "bash"
   ;; …and git, for `check-ui-fresh --staged`: the pre-commit hook asks
   ;; whether the COMMIT is self-consistent, not the working tree, so the
   ;; gate materialises the index into a scratch tree and checks that.
   "git-minimal"))
