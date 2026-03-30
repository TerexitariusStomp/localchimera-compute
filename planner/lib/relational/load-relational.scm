;;; load-relational.scm — Load relational planner modules in dependency order

(use-modules (playnet kanren-constraints))

(let ((dir (dirname (current-filename))))
  (load (string-append dir "/planning-facts.scm"))
  (load (string-append dir "/allocation.scm"))
  (load (string-append dir "/signals.scm"))
  (load (string-append dir "/ddmrp.scm"))
  (load (string-append dir "/sne.scm"))
  (load (string-append dir "/demand-relation.scm"))
  (load (string-append dir "/plan-relation.scm"))
  (load (string-append dir "/federation.scm")))
