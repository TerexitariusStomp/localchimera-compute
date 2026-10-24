;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/server-1/gateway-manifest.scm — runtime env for the OCapN gateway
;;;
;;; Consumed by user-shepherd on server-1 (Debian host, not Guix System).
;;; Mirrors the package set that machines.scm wires into
;;; localchimera-gateway-service-type, minus the activation machinery that only
;;; exists under Guix System.
;;;
;;; Usage (from shepherd-init.scm):
;;;
;;;   guix shell -L $REPO/deploy/guix \
;;;     -m $REPO/deploy/server-1/gateway-manifest.scm \
;;;     -- guile --no-auto-compile -L $REPO/module \
;;;        -s $REPO/server/gateway.scm --port 9090
;;;
;;; `-L deploy/guix` is required for (localchimera-hoot) — the Hoot the wasm
;;; toolchain runs lives there, identical to what the pure-Guix deploy resolves.

(use-modules (guix profiles)
             (gnu packages)
             (localchimera-hoot))              ; -L deploy/guix provides this

(packages->manifest
 (append
  (map specification->package
       '("guile-next"
         "guile-goblins"
         "guile-fibers"
         "guile-websocket"
         "guile-gcrypt"
         "guile-json"
         "libsodium"
         "torsocks"                       ;; OCapN client peers reach over Tor
         "coreutils"
         "bash"))
  (list guile-hoot/localchimera)))
