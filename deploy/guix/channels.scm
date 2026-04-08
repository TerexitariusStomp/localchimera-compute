;;; deploy/guix/channels.scm — pinned channels
;;;
;;; Get the current commit with: guix describe --format=channels
;;; Copy the output here. Commit when updating Guix.

(list
 (channel
  (name 'guix)
  (url "https://git.savannah.gnu.org/git/guix.git")
  (branch "master")
  (commit "1bfc951376ebb55830d7e7daba483c77fe8bee0c")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
