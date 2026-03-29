;;; deploy/guix/reticulum-manifest.scm — Reticulum environment
;;;
;;; Usage:
;;;   guix shell -m deploy/guix/reticulum-manifest.scm
;;;
;;; Or pin for full reproducibility:
;;;   guix describe -f channels > deploy/guix/reticulum-channels.scm
;;;   guix time-machine -C deploy/guix/reticulum-channels.scm -- \
;;;     shell -m deploy/guix/reticulum-manifest.scm
;;;
;;; On the server, install as a profile:
;;;   guix package -m deploy/guix/reticulum-manifest.scm -p /opt/reticulum
;;;   source /opt/reticulum/etc/profile
;;;   pip install --prefix /opt/reticulum-pip rns

(specifications->manifest
 '("python"
   "python-cryptography"
   "python-pyserial"))
