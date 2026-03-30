(use-modules (guix packages)
             (guix gexp)
             (guix build-system copy)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages guile-xyz)
             ((guix licenses) #:prefix license:))

(package
  (name "playnet")
  (version "0.1.0-HEAD")
  (source (local-file "." "playnet-checkout"
                      #:recursive? #t
                      #:select? (lambda (file stat)
                                  ;; Exclude .git, node_modules, etc.
                                  (not (or (string-suffix? "/.git" file)
                                           (string-contains file "/.git/")
                                           (string-suffix? "/node_modules" file)
                                           (string-contains file "/node_modules/"))))))
  (build-system copy-build-system)
  (arguments
   (list #:install-plan
         #~'(("module" "share/playnet/module")
             ("planner" "share/playnet/planner")
             ("server" "share/playnet/server")
             ("key-pool" "share/playnet/key-pool")
             ("deploy" "share/playnet/deploy")
             ("browser" "share/playnet/browser")
             ("tests" "share/playnet/tests")
             ("docs" "share/playnet/docs")
             ("RELATIONS.md" "share/playnet/RELATIONS.md")
             ("Makefile" "share/playnet/Makefile"))
         #:phases
         #~(modify-phases %standard-phases
             (add-before 'install 'check
               (lambda* (#:key inputs #:allow-other-keys)
                 (let ((guile (search-input-file inputs "bin/guile")))
                   ;; Knowledge tests (kanren, knowledge, system-kb)
                   (invoke guile "--no-auto-compile" "-q"
                           "-L" "module"
                           "tests/test-knowledge.scm")
                   ;; Relational planner tests
                   (with-directory-excursion "planner"
                     (invoke guile "--no-auto-compile" "-q"
                             "-L" "../module"
                             "-l" "load-all.scm"
                             "-l" "tests/relational-planner.scm")))))
             (add-after 'install 'create-wrappers
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 (let* ((out (assoc-ref outputs "out"))
                        (bin (string-append out "/bin"))
                        (base (string-append out "/share/playnet"))
                        (guile-bin (search-input-file inputs "bin/guile")))
                   (mkdir-p bin)
                   ;; REPL wrapper
                   (let ((wrapper (string-append bin "/playnet-repl")))
                     (with-output-to-file wrapper
                       (lambda ()
                         (display
                          (string-append
                           "#!/bin/sh\nexec " guile-bin
                           " \\\n  -L " base "/module"
                           " \\\n  " base "/server/repl.scm \"$@\"\n"))))
                     (chmod wrapper #o555))
                   ;; Planner wrapper
                   (let ((wrapper (string-append bin "/playnet-planner")))
                     (with-output-to-file wrapper
                       (lambda ()
                         (display
                          (string-append
                           "#!/bin/sh\ncd " base "/planner\n"
                           "exec " guile-bin
                           " \\\n  --no-auto-compile"
                           " \\\n  -L " base "/module"
                           " \\\n  -l load-all.scm"
                           " \\\n  \"$@\"\n"))))
                     (chmod wrapper #o555))
                   ;; Relay wrapper
                   (let ((wrapper (string-append bin "/playnet-relay")))
                     (with-output-to-file wrapper
                       (lambda ()
                         (display
                          (string-append
                           "#!/bin/sh\ncd " base "\n"
                           "exec " guile-bin
                           " \\\n  -L " base "/module"
                           " \\\n  -L " base "/key-pool"
                           " \\\n  -L " base "/deploy"
                           " \\\n  " base "/server/relay.scm \"$@\"\n"))))
                     (chmod wrapper #o555))
                   ;; OCapN gateway wrapper
                   (let ((wrapper (string-append bin "/playnet-gateway")))
                     (with-output-to-file wrapper
                       (lambda ()
                         (display
                          (string-append
                           "#!/bin/sh\ncd " base "\n"
                           "exec " guile-bin
                           " \\\n  -L " base "/module"
                           " \\\n  -L " base "/key-pool"
                           " \\\n  -L " base "/deploy"
                           " \\\n  " base "/server/gateway.scm \"$@\"\n"))))
                     (chmod wrapper #o555))))))))
  (inputs (list guile-next guile-hoot gnu-make guile-json-4 guile-goblins
                guile-fibers))
  (home-page "https://github.com/interplaynetary/playnet")
  (synopsis "Communal computer — relational planning over capability-secure actors")
  (description
   "Playnet is a commons computer built on Spritely Goblins.  It provides
relational economic planning (miniKanren over ValueFlows), capability-secure
governance (actors, facets, revocation), and mesh networking (Reticulum).
Facts are plain S-expression tuples queried via unification.  Every
allocation is reversible, every inference is traceable, every capability
is unforgeable.")
  (license license:agpl3))
