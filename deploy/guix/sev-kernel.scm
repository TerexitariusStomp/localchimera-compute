;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/sev-kernel.scm — linux-libre with AMD SEV-SNP guest support.
;;;
;;; WHY: stock guix linux-libre ships `# CONFIG_AMD_MEM_ENCRYPT is not set`,
;;; so it CANNOT boot as an AMD SEV-SNP confidential guest — the guest kernel
;;; can't handle hypervisor-encrypted memory and crash-poweroffs at boot.
;;; This was the root cause of the 2026-06-02 brick: SEV-SNP was enabled at
;;; the VPSBG plan level on a stock-kernel guest. This package re-enables the
;;; required guest options:
;;;   CONFIG_AMD_MEM_ENCRYPT=y  — SEV/SME guest memory-encryption (the fix)
;;;   CONFIG_SEV_GUEST=m        — /dev/sev-guest, for snpguest attestation
;;; (CONFIG_X86_MEM_ENCRYPT, UNACCEPTED_MEMORY, TSM_* are already on in stock.)
;;;
;;; NOT yet referenced by os.scm. Wiring `(kernel linux-libre-sev)` in and
;;; rebooting is step 2 (supervised; SEV stays OFF until the kernel is proven
;;; to boot, then enabled at the VPSBG panel with recovery ready).
;;;
;;; NOTE on slimming: a headless VM needs none of the generic wifi/media/sound/
;;; infiniband/CAN drivers, and dropping them would cut the ~1-2h build to
;;; minutes + shrink attack surface. But `customize-linux` strict-checks the
;;; final .config against the defconfig, and disabling umbrella subsystems
;;; cascade-disables hundreds of dependent options -> "Mismatching
;;; configurations" build failure. Slimming therefore needs a FULL custom
;;; #:defconfig (generated offline), not incremental #:configs. Deferred.

(define-module (sev-kernel)
  #:use-module (gnu packages linux)
  #:export (linux-libre-sev))

(define linux-libre-sev
  (customize-linux
   #:name "linux-libre-sev"
   #:linux linux-libre
   #:extra-version "sev"
   #:configs "\
CONFIG_AMD_MEM_ENCRYPT=y
CONFIG_SEV_GUEST=m
"))
