;;; deploy/guix/browser-test-manifest.scm — Browser UX test environment
;;;
;;; Declarative environment for running Playwright browser tests.
;;;
;;; Usage:
;;;   guix time-machine -C deploy/guix/channels.scm -- \
;;;     shell -m deploy/guix/browser-test-manifest.scm -- \
;;;     sh tests/ux-test.sh
;;;
;;; Or via Makefile:
;;;   make test-browser
;;;
;;; Playwright uses chromium from the system or from `playwright install`.
;;; The PLAYWRIGHT_BROWSERS_PATH env var can point to a pre-installed browser.

(specifications->manifest
 '("node"
   "python"                    ;; http.server for static file serving
   "node-playwright-core"      ;; Playwright library (no bundled browser)
   "nss-certs"))               ;; TLS certificates for any HTTPS needs
