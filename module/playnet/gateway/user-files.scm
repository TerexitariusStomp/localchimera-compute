;;; module/playnet/gateway/user-files.scm — moved to (playnet identity user-files) (module/playnet/identity/user-files.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 1).

(define-module (playnet gateway user-files)
  #:use-module (playnet identity user-files)
  #:re-export (%data-dir %user-file %user-file-kinds %read-user-data %write-user-data! %seed-user-docs! user-files-forget!))
