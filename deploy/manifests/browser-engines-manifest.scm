;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/manifests/browser-engines-manifest.scm — every engine the layout
;;; matrix runs under, all from guix, nothing vendored:
;;;
;;;   ungoogled-chromium   Playwright over CDP          (the default engine)
;;;   icecat               Gecko, over WebDriver BiDi   (tests/ux/ux-engines.mjs)
;;;   webkitgtk            WebKit, over WebDriver — its WebKitWebDriver +
;;;                        MiniBrowser, under xvfb-run for a display
;;;
;;; A superset of browser-test-manifest.scm; the same caveat about bypassing
;;; the channel pin applies (see there).
;;;
;;;   make test-responsive-engines-ux
(specifications->manifest
 '("node"
   "node-playwright-core"
   "ungoogled-chromium"
   "icecat"
   "webkitgtk"
   "xvfb-run"
   "nss-certs"))
