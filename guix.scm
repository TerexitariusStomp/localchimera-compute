(use-modules (guix packages)
             (guix gexp)
             (guix build-system copy)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages guile-xyz)
             ((guix licenses) #:prefix license:))

(package
  (name "xorg")
  (version "0.1.0-HEAD")
  (source (local-file "." "xorg-checkout" #:recursive? #t))
  (build-system copy-build-system)
  (arguments
   (list #:install-plan
         #~'(("module" "share/xorg/module")
             ("server" "share/xorg/server")
             ("key-pool" "share/xorg/key-pool")
             ("deploy" "share/xorg/deploy")
             ("browser" "share/xorg/browser")
             ("docs" "share/xorg/docs")
             ("Makefile" "share/xorg/Makefile"))
         #:phases
         #~(modify-phases %standard-phases
             (add-after 'install 'create-wrappers
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 (let* ((out (assoc-ref outputs "out"))
                        (bin (string-append out "/bin"))
                        (base (string-append out "/share/xorg"))
                        (guile-bin (search-input-file inputs "bin/guile")))
                   (mkdir-p bin)
                   ;; REPL wrapper
                   (let ((wrapper (string-append bin "/xorg-repl")))
                     (with-output-to-file wrapper
                       (lambda ()
                         (display
                          (string-append
                           "#!/bin/sh\nexec " guile-bin
                           " \\\n  -L " base "/module"
                           " \\\n  " base "/server/repl.scm \"$@\"\n"))))
                     (chmod wrapper #o555))
                   ;; Relay wrapper (legacy, kept during transition)
                   (let ((wrapper (string-append bin "/xorg-relay")))
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
                   (let ((wrapper (string-append bin "/xorg-gateway")))
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
  (home-page "https://github.com/interplaynetary/xorg")
  (synopsis "xorg desktop REPL")
  (description "A bundled release of the xorg terminal REPL.")
  (license license:agpl3))
