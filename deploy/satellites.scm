;;; deploy/satellites.scm — the repos the core pins by commit + content hash
;;;
;;; The core repo's HEAD is the only input to the deployed system. Every other
;;; repo listed here is consumed at exactly the commit below, and its content
;;; is checked against the nar hash below (the same hash `guix hash -x
;;; --serializer=nar` prints for the checkout, and the same one a Guix
;;; `git-fetch` origin verifies). A push to a satellite changes nothing until a
;;; commit here moves its pin.
;;;
;;; Move a pin:            make bump SAT=<name>
;;; Verify every pin:      make check-satellite-pins   (also runs pre-push)
;;; Plan:                  docs/planning/identity/repo-split-and-protocol-doors.md
;;;
;;; Fields:
;;;   name    the satellite's short name; its clone sits beside this repo as
;;;           ../playnet-<name> (override: PLAYNET_SATELLITES_DIR)
;;;   rid     the Radicle RID ("rad:z…"); #f until the repo is initialized.
;;;           The clearnet mirror the box serves is
;;;           https://<domain>/<rid without "rad:">.git — the same
;;;           %playnet-git-mirror-locations route the core uses (deploy/os.scm
;;;           lists the satellite RIDs for that in %playnet-satellite-rids-bare).
;;;   commit  the pinned commit, full sha1
;;;   sha256  nar hash of the tree at that commit, base32 as guix prints it
;;;   lands   where the tree is placed inside this repo's served tree, or #f
;;;           for a repo the box serves and pins without placing (keri)

(list
 ;; The built Radicle Explorer site the box serves at /radicle/. Upstream's
 ;; build output, unchanged. 3,780 files, 3,690 of them twemoji.
 '((name   . "explorer")
   (rid    . "rad:z24QKokm5rkbGJDxBXVGEcfVVarrW")
   (commit . "c45d13238fa4321af8aa205aaa692f30fddd8fd0")
   (sha256 . "0wbccbnv57rskzpd6ij4nk9jnxg0whnbi6ncsnibs1pbi4nrdkzw")
   (lands  . "browser/radicle"))
 ;; The browser Reticulum crate. Placed at rns-wasm/ so build-rns-wasm.sh
 ;; builds it on the box exactly as before (a guix shell with rust + std
 ;; sources + lld, wasm-bindgen-cli cached beside the crate; two products
 ;; into browser/). Subtree-split from the core with its history, re-signed.
 '((name   . "rns-wasm")
   (rid    . "rad:z4PbxPfxbFVEjY3nZp8k61NabfH9C")
   (commit . "a17559d87b5d7107d40ab9c926fd9ee9206147c9")
   (sha256 . "07g5qhrh5q60gn217k7f7a59jncdx00f81fdk48bzvkxz0g9ki7c")
   (lands  . "rns-wasm"))
 ;; The Reticulum bridge daemon. Placed at server/rns-bridge/ for local cargo
 ;; work and the mesh smoke test; the Guix package (deploy/guix/rns-bridge.scm)
 ;; builds it from this pin through satellite-source.scm, so reconfigure
 ;; never reads the placed tree.
 '((name   . "rns-bridge")
   (rid    . "rad:z4CkmFXepKGVon1rt9prxzXjjyrKz")
   (commit . "c4d48e9e6c1a58c0ed1529a42872067f17f009df")
   (sha256 . "1zc4lcv2l4349nb8q2q8aqv7ip6vd11b5amhbqwr4kkasbh3by31")
   (lands  . "server/rns-bridge"))
 ;; The Capacitor Android shell and wear relay. Not consumed by the box;
 ;; placed at app/ for whoever builds the APK. Split with its history.
 '((name   . "app")
   (rid    . "rad:z3AjcdHzdqXJ2wcvaPzRgroyg6Anr")
   (commit . "aced80d2c89643e7a15d58d606eb5ebae7d3ad63")
   (sha256 . "1myfsl3dar34xcwx4iqw2zj7shrdyxkxasxlscp439aj6dg6rydy")
   (lands  . "app"))
 ;; Editor support for wisp: emacs-wisp, tree-sitter-wisp, wisp-vscode.
 ;; Not consumed by the box; placed at tooling/ so the Makefile's vsix and
 ;; editor targets keep their paths.
 '((name   . "tooling")
   (rid    . "rad:z2rZTGoeCkfin4invSVEKxFvmV6xc")
   (commit . "6e116cf80f3b21d4813046635cc291d056665d5a")
   (sha256 . "17vlczzf01hnjpl51swn7mfkjk8cqfa4z0az4c2lx7c32gs3j8ml")
   (lands  . "tooling"))
 ;; The KERI / ACDC / Signify library and the First Person (OpenVTC)
 ;; credentials over it. A cut OUT of the core — tools/dev/publish-keri-lib.sh
 ;; derives it from module/playnet/keri and their tests — so the box
 ;; serves, seeds and pins it for the KERI and OpenVTC communities and places
 ;; nothing: the core already holds those files.
 '((name   . "keri")
   (rid    . "rad:z3qCP3JyrjAMMXTd2Zq7EFyaNWMTN")
   (commit . "10a1416e70f43289687d7ef611acfb41fbdce12b")
   (sha256 . "14y6a768psvca139x729r9v3hr177c8zwn0xd518skkkqdkz5v49")
   (lands  . #f)))
