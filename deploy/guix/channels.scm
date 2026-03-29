;;; deploy/guix/channels.scm — pinned channels
;;;
;;; Get the current commit with: guix describe --format=channels
;;; Copy the output here. Commit when updating Guix.

(list
 (channel
  (name 'guix)
  (url "https://git.savannah.gnu.org/git/guix.git")
  (branch "master")
  (commit "21946173a05869dd40a38012e65b9e35dc47a9fc")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
