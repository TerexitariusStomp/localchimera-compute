;;; deploy/guix/playnet-keys.scm — operator public keys (not secrets).
;;;
;;; Single source of truth for SSH pubkeys used across the deploy story:
;;;   - deploy/playnet-iso.scm     (custom ISO build)
;;;   - deploy/machines.scm              (production OS via guix deploy)
;;;
;;; These are public keys, safe to commit. Rotate by editing this file
;;; and rebuilding the ISO + re-running guix deploy.
;;;
;;; Multi-workstation access: %operator-ssh-public-key is the
;;; authorized_keys *file contents* — one ssh-ed25519 line per
;;; workstation, separated by newlines. SSH accepts all of them.

(define-module (playnet-keys)
  #:export (%operator-ssh-public-key
            %ci-ssh-public-key))

;; Per-workstation pubkeys. Add one line per machine you want to ssh
;; from. Comments stripped to prevent fingerprinting across systems.
(define %operator-pubkeys
  '(;; Provider deploy key — a dedicated operational identity that talks to
    ;; the VPS provider's VMs. The private key lives only on removable media
    ;; and never touches the operator's main workstation.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOjfiPk6KT+t/DK9+DXLxh/ra19WNNHuGu0ZdrTS6Us3"

    ;; Operator workstation key (~/.ssh/id_ed25519) — kept so the same
    ;; ISO can also be booted in qemu on the workstation for testing.
    ;; Fingerprint: SHA256:oDcK/+IbGKBsOzdxgwUtwQQgxmQ4pzAFbbtlffRkhQ0
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTLO20IW4Ej9qhXYGnfy0yc8RlvMLEkR+MG39nyK5mq"

    ;; Operator workstation key (~/.ssh/playnet) — backup workstation
    ;; key for the make qemu / local debugging flow.
    ;; Fingerprint: SHA256:W1FASwixNHx08EFobPgoNC/MdZr4kDQPUBr4F/XrcWY
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICYH2N5wuAtP4vt2Vhgasl0237imk09s7xVBB8/nevhU"

    ;; Tails Persistent — generate with `ssh-keygen -t ed25519 -f
    ;; ~/.ssh/playnet -N "" -C ""` on Tails (after enabling Persistent
    ;; Storage + SSH Client feature), then paste the .pub line here and
    ;; rebuild the ISO. Uncomment when ready:
    ;; "ssh-ed25519 AAAA…TAILS_KEY_HERE"
    ))

;; Operator pubkeys joined into one authorized_keys-format string.
;; Consumed by playnet-iso.scm and machines.scm as a single plain-file.
;; Trailing newline is required: machines.scm passes multiple plain-file
;; entries per user (operator + ci) to openssh-configuration's
;; authorized-keys, and Guix concatenates them without inserting a
;; separator. Without the \n, the last operator key fuses with the
;; following CI key on a single malformed line and sshd rejects both.
(define %operator-ssh-public-key
  (string-append (string-join %operator-pubkeys "\n") "\n"))

;; CI / automated-deploy key — used by GitHub Actions / Radicle CI.
;; Trailing newline for the same reason as %operator-ssh-public-key.
(define %ci-ssh-public-key
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN3Bhkk/WiuQY0O7sk8Ek/sVqOfkP7NXy3gJEstXWm+x\n")
