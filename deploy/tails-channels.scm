;;; deploy/tails-channels.scm — channels for tails.scm with WiFi firmware
;;;
;;; **Tails-only.** This file is consumed by `guix time-machine` when
;;; building the operator's Tails-style live USB image (see deploy/tails.scm).
;;; It is NEVER loaded on a deployed server — the server uses
;;; deploy/channels.scm directly, which has no nonguix dependency.
;;;
;;; This file extends channels.scm with the `nonguix` channel, which
;;; provides linux + linux-firmware + microcode-initrd needed for most
;;; laptop WiFi/Bluetooth chips. The base Guix and playnet pins are
;;; inherited from channels.scm so there is a single source of truth for
;;; the Guix commit and the playnet introduction.
;;;
;;; The clearnet GitLab URL below is acceptable here because the build
;;; runs on a Tails system whose entire network stack is Tor-only.
;;; If you ever extend a deployed-host service to load this file, the
;;; clearnet pull becomes a leak — switch the nonguix URL to a Tor-
;;; reachable mirror or rebuild the image on Tails first.
;;;
;;; Usage:
;;;   1. Uncomment the kernel/initrd/firmware lines in tails.scm
;;;   2. Uncomment the (use-modules (nongnu ...)) lines in tails.scm
;;;   3. Build with:
;;;      guix time-machine -C deploy/tails-channels.scm \
;;;        -- system image -t iso9660 deploy/tails.scm

(append
 (load (string-append (dirname (or (current-filename)
                                   (canonicalize-path "deploy/tails-channels.scm")))
                      "/channels.scm"))
 (list
  ;; Nonguix — non-free kernel + firmware
  ;; https://gitlab.com/nonguix/nonguix
  (channel
   (name 'nonguix)
   (url "https://gitlab.com/nonguix/nonguix")
   (branch "master")
   (introduction
    (make-channel-introduction
     "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
     (openpgp-fingerprint
      "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))))
