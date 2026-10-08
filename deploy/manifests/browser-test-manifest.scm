;;; deploy/guix/browser-test-manifest.scm — Browser UX test environment
;;;
;;; Declarative environment for running Playwright browser tests.
;;;
;;; Usage:
;;;   guix shell -m deploy/manifests/browser-test-manifest.scm -- \
;;;     sh tests/ux/ux-test.sh
;;;
;;; Or via Makefile:
;;;   make test-browser
;;;
;;; Bypasses `guix time-machine` (and the playnet channel pin) for the
;;; same reason as deploy/manifests/keri-test-manifest.scm: the rad HTTPS
;;; gateway only canonicalizes the project's defaultBranch (main), so
;;; the (introduction)'s keyring branch isn't reachable as origin/keyring.
;;; Production deploys still go through the pin via `guix deploy` where
;;; bit-for-bit reproducibility actually matters; dev test envs accept
;;; per-host drift in exchange for being buildable at all.
;;;
;;; Playwright uses chromium from the system or from `playwright install`.
;;; The PLAYWRIGHT_BROWSERS_PATH env var can point to a pre-installed browser.

(specifications->manifest
 '("node"
   "python"                    ;; http.server for static file serving
   "node-playwright-core"      ;; Playwright library (no bundled browser)
   "ungoogled-chromium"        ;; Browser binary — Playwright launches via executablePath
   "nss-certs"))               ;; TLS certificates for any HTTPS needs
