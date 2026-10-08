;;; deploy/guix/users.scm — dynamically provisioned user accounts
;;;
;;; Managed by provision-user.scm — do not hand-edit.
;;; Each entry: (cons "username" "ssh-pubkey-string")
;;;
;;; After editing, redeploy:
;;;   guix deploy deploy/guix/machines.scm

(list
  ;; Key comments are stripped to avoid leaking hostnames / dev-machine
  ;; identifiers in authorized_keys. See deploy/machines.scm:104-106.
  (cons "priya"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClNUonCa4xStMOhaobXEGPcJp7Ij+usvCvKM+15Bv2D")
)
