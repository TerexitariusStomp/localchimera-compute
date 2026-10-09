;;; module/playnet/governance/enrollment-ceremony.scm — moved to (playnet identity enrollment) (module/playnet/identity/enrollment.scm).
;;; A re-export shim: importers name the new module; the shim goes once
;;; every importer in every tree does (identity centralization, step 4).

(define-module (playnet governance enrollment-ceremony)
  #:use-module (playnet identity enrollment)
  #:re-export (enrollment-statement-said spawn-enrollment-ceremony enroll-ceremony-for-candidate enroll-asks enrollment-record witness-recent-enrollments expire-stale-enrollments! rehydrate-enrollment-ceremonies! current-enroll-announcer *self-request-evidence*))
