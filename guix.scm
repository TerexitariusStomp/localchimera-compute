(use-modules (guix packages)
             (guix gexp)
             (guix build-system copy)
             (gnu packages base)
             (gnu packages guile)
             (gnu packages guile-xyz)
             ((guix licenses) #:prefix license:))

(package
  (name "meta-org")
  (version "0.1.0-HEAD")
  (source (local-file "." "meta-org-checkout" #:recursive? #t))
  (build-system copy-build-system)
  (arguments
   (list #:install-plan
         #~'(("module" "share/meta-org/module")
             ("server" "share/meta-org/server")
             ("key-pool" "share/meta-org/key-pool")
             ("deploy" "share/meta-org/deploy")
             ("browser" "share/meta-org/browser")
             ("docs" "share/meta-org/docs")
             ("Makefile" "share/meta-org/Makefile"))
         #:phases
         #~(modify-phases %standard-phases
             (add-after 'install 'create-wrappers
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 (let* ((out (assoc-ref outputs "out"))
                        (bin (string-append out "/bin"))
                        (base (string-append out "/share/meta-org"))
                        (guile-bin (search-input-file inputs "bin/guile")))
                   (mkdir-p bin)
                   ;; REPL wrapper
                   (let ((wrapper (string-append bin "/meta-org-repl")))
                     (with-output-to-file wrapper
                       (lambda ()
                         (display
                          (string-append
                           "#!/bin/sh\nexec " guile-bin
                           " \\\n  -L " base "/module"
                           " \\\n  " base "/server/repl.scm \"$@\"\n"))))
                     (chmod wrapper #o555))
                   ;; Relay wrapper
                   (let ((wrapper (string-append bin "/meta-org-relay")))
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
                     (chmod wrapper #o555))))))))
  (inputs (list guile-next guile-hoot gnu-make guile-json-4 guile-goblins))
  (home-page "https://github.com/interplaynetary/meta-org")
  (synopsis "meta-org desktop REPL")
  (description "A bundled release of the meta-org terminal REPL.")
  (license license:agpl3))
