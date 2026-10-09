;;; module/playnet/gateway/device-registry.scm — moved to (playnet identity devices) (module/playnet/identity/devices.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 1).

(define-module (playnet gateway device-registry)
  #:use-module (playnet identity devices)
  #:re-export (device-registry-dir device-wire->cred device-credential-verdict device-enroll! device-revoke! devices-retire! devices-of device-keys-at device-entry-live-at? device-entry device-entry-live? live-device-keys device-owner-of device-entry-doors device-entry->wire-alist))
