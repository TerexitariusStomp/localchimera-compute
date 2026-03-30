;;; load-relational.scm — Load relational planner modules in dependency order

(use-modules (playnet kanren-planning))

(let ((dir (dirname (current-filename))))
  (load (string-append dir "/netter-goals.scm"))
  (load (string-append dir "/planning-facts.scm"))
  (load (string-append dir "/demand-relation.scm"))
  (load (string-append dir "/plan-relation.scm")))
