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
  (source (local-file "." "playnet-checkout" #:recursive? #t))
  (build-system copy-build-system)
  (arguments
   (list #:install-plan
         #~'(("module" "share/playnet/module")
             ("server" "share/playnet/server")
             ("key-pool" "share/playnet/key-pool")
             ("deploy" "share/playnet/deploy")
             ("browser" "share/playnet/browser")
             ("docs" "share/playnet/docs")
             ("Makefile" "share/playnet/Makefile"))
         #:phases
         #~(modify-phases %standard-phases
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
                   ;; Relay wrapper (legacy, kept during transition)
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
  (synopsis "playnet desktop REPL")
  (description "A bundled release of the playnet terminal REPL.")
  (license license:agpl3))
