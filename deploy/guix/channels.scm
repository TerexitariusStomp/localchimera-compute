;;; deploy/guix/channels.scm — pinned channels
;;;
;;; Get the current commit with: guix describe --format=channels
;;; Copy the output here. Commit when updating Guix.

(list
 (channel
  (name 'guix)
  (url "https://codeberg.org/guix/guix")
  (branch "master")
  (commit "3ec53494a0f9c49e6cbc6864eedb102820915075")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
