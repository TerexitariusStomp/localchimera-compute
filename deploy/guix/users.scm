;;; deploy/guix/users.scm — dynamically provisioned user accounts
;;;
;;; Managed by provision-user.scm — do not hand-edit.
;;; Each entry: (cons "username" "ssh-pubkey-string")
;;;
;;; After editing, redeploy:
;;;   guix deploy deploy/guix/machines.scm

(list
  (cons "sapient-os"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJV+LYZkxdAYfUmHMehHuPGdUk2u32CW4zVpi9k+zmj AGICorp.eth@icloud.com")
  (cons "karan"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClNUonCa4xStMOhaobXEGPcJp7Ij+usvCvKM+15Bv2D k-with-claude@vm")
)
