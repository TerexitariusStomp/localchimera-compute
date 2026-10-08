;;; deploy/manifests/sms-wall-manifest.scm — SMS Wall portable environment
;;;
;;; Declarative environment for the sms-verify tool, suitable for `guix pack`.
;;; Includes the playnet package (which bundles the tool + module) plus
;;; Node.js and Playwright for browser-based account registration.
;;;
;;; Usage (Docker):
;;;   guix pack -f docker -C gzip -S /bin=bin -S /share=share \
;;;     -m deploy/manifests/sms-wall-manifest.scm
;;;
;;; Usage (tarball):
;;;   guix pack -f tarball -C gzip \
;;;     -m deploy/manifests/sms-wall-manifest.scm
;;;
;;; Usage (dev shell):
;;;   guix shell -m deploy/manifests/sms-wall-manifest.scm -- \
;;;     sms-verify --service telegram --country 12 --amount 1.00 --manual

(specifications->manifest
 '("playnet"                    ;; sms-verify tool + playnet modules
   "guile-json-4"               ;; JSON parsing for the WALLS.RIP API
   "nss-certs"                  ;; TLS certificates for HTTPS
   "node"                       ;; For Playwright-based registration
   "node-playwright-core"       ;; Playwright library
   "ungoogled-chromium"))       ;; Headless browser for automation
