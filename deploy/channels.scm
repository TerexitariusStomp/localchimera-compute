;;; deploy/channels.scm — pinned, authenticated channels
;;;
;;; Refresh the Guix pin with: guix describe --format=channels
;;; Refresh the playnet pin with: git rev-parse HEAD (after each release).
;;; The Guix manual mandates `commit` + `introduction` for every channel
;;; that ships code into builds (Cookbook §17.5). Without them, `guix
;;; pull` cannot verify the chain of signed commits and the channel URL
;;; becomes a supply-chain entry point.

(list
 (channel
  (name 'guix)
  (url "https://git.savannah.gnu.org/git/guix.git")
  (branch "master")
  ;; Bumped 2026-05-20 to match the production gateway's guix pin
  ;; (server's `guix describe` reports the same commit). Previous pin
  ;; shipped guile-goblins 0.17.0, which uses the pre-init:peer-auth
  ;; WebSocket handshake; this commit ships 0.18.0 (the gateway's
  ;; runtime version). Without the bump, repl.wasm compiled here
  ;; speaks the old handshake and every connection fails with
  ;; "WebSocket designator verification failed".
  (commit "5f42ab7d46cf22b19844521b2385a7890faf274b")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
 ;; Playnet channel — this repository itself.
 ;; Radicle RID: rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ
 ;;
 ;; The URL is the project's own clearnet domain — the box mirrors its own
 ;; repo over ordinary git-smart-HTTP (deploy/os.scm's
 ;; %playnet-git-mirror-locations: two exact-match nginx locations, nothing
 ;; else under .git/ is reachable). `guix pull` shells out to git, which
 ;; does not speak rad://, and every third-party Radicle↔git gateway
 ;; checked (2026-08-04) served the same commit — one this repo's own
 ;; history does not contain at all. `rad node status` showed this node's
 ;; connection to the previously-pinned gateway stuck at "attempted", never
 ;; connected: the wider gateway layer had not received a push in a long
 ;; time. Self-hosting removes the dependency on a party whose sync state
 ;; this project cannot see or fix.
 ;;
 ;; NOT the onion, though the SAME mirror is exposed there too (for anyone
 ;; using an ordinary git client over Tor — confirmed working:
 ;; `git -c http.proxy=socks5h://127.0.0.1:9050 ls-remote` against the
 ;; onion returned the right commit). `guix pull`'s own git implementation
 ;; (libgit2) resolves hostnames via ordinary DNS before any proxy is even
 ;; consulted — confirmed directly, a getaddrinfo-shaped failure, not a
 ;; connection one — so a bare .onion URL can never work here, no matter
 ;; how the proxy is configured. The clearnet route reaches the same
 ;; self-hosted mirror over ordinary HTTPS instead, wrapped in torsocks for
 ;; the fetch itself (reconfigure.sh's existing pattern). Exposes nothing
 ;; new: the RID is already public in this file and already served
 ;; read-only by the existing /api/v1 and /raw/ routes, on this exact
 ;; server block.
 ;;
 ;; The (introduction) below makes any tampering by the mirror detectable —
 ;; `guix pull` refuses commits not signed by a key listed in
 ;; .guix-authorizations, and verifies the intro commit's OWN signature too
 ;; (unlike `guix git authenticate`, which only checks commits after it).
 ;;
 ;; RE-ROOTED 2026-08-04: the prior introduction root (511945e…) does not
 ;; exist on any reachable copy of this repo's history, local or remote —
 ;; not stale, absent. The likely cause is the documented opsec history
 ;; rewrite (project_opsec_history_rewrite): rewriting history changes every
 ;; commit hash downstream of the rewrite point, including a prior re-root
 ;; commit whose new hash was never carried back into this file. Re-rooting
 ;; to the current tip is the documented procedure for exactly this
 ;; situation (.guix-authorizations §Bootstrap, step 5) — not a key
 ;; rotation, same operator key throughout, confirmed against every
 ;; recently-signed commit before this pin was written.
 ;;
 ;; Refresh the (commit …) pin on each release with
 ;;   git rev-parse HEAD
 ;; — only move the introduction itself when rotating the operator key (see
 ;; .guix-authorizations) or re-rooting past another unauthenticated or
 ;; unreachable history slice, as here.
 ;; Operator pubkey: deploy/keys/CAFF2F2BB5CFDFE22FBFB9386A548079D6177B2F.asc
 ;; Pin history: d156881 → e2ceb77c → 16b1374 → 6555e03 → 511945e (orphaned
 ;; by the history rewrite, never resolved) → 75900ae2 (re-rooted; introduction
 ;; stays here) → 8cbaa461 (clearnet-hosted, live-verified: a real
 ;; `guix time-machine -C this-file -- describe`, wrapped in torsocks,
 ;; authenticated the full signed chain end to end and resolved both
 ;; channels — not merely reachable, actually used by the tool this pin
 ;; exists for) → 8848fc92 (RE-ROOTED 2026-08-23) → dcebccc9 (RE-ROOTED
 ;; 2026-08-27, slim rewrite) → c2251e91 (RE-ROOTED 2026-09-21, identity
 ;; rewrite) → d679134b (RE-ROOTED 2026-10-07, intent-content scrub).
 ;;
 ;; RE-ROOT 2026-08-23: two commits, 438b3124 and d0ce6d17 (both
 ;; 2026-08-15, author playnet-ops), landed UNSIGNED mid-chain — committed
 ;; with the operator key unavailable, the exact failure the pre-push
 ;; Guard 2 exists to catch and which slipped past it once. A signature
 ;; can't be added to an existing commit without rewriting every SHA after
 ;; it (which would break canonical, clones and Radicle), so the fix is to
 ;; re-root the introduction PAST them: 8848fc92 is the first signed commit
 ;; that descends both, is signed by the operator key CAFF…7B2F, and
 ;; carries the same .guix-authorizations — so authentication walks
 ;; 8848fc92 → pin and never meets an unsigned commit. The old pin 8cbaa461
 ;; predates the unsigned pair, so `guix pull` was correct until the pin
 ;; advanced past 2026-08-15; this re-root is what lets it advance safely.
 ;;
 ;; STORAGE PREREQUISITE, easy to lose if this box's Radicle storage is
 ;; ever rebuilt from scratch: `guix pull` needs a plain `refs/heads/keyring`
 ;; (carrying the operator's pubkey as a .key file) to authenticate at all,
 ;; but Radicle only auto-materialises a plain top-level ref for the repo's
 ;; CONFIGURED DEFAULT BRANCH (main here) — every other branch, keyring
 ;; included, exists only under refs/namespaces/<peer>/refs/heads/keyring.
 ;; No `rad` command creates additional canonical branches (checked: the
 ;; repo identity's xyz.radicle.project has exactly one such field,
 ;; defaultBranch). The fix is `git update-ref refs/heads/keyring <hash>`
 ;; directly in the bare storage, additive and safe (confirmed it survives
 ;; a real `rad sync --fetch` from a live peer) — see
 ;; deploy/scripts/canonicalize-keyring-ref.sh.
 ;; RE-ROOT 2026-08-27: the slim rewrite (docs/history/resign-2026-08-27.tsv)
 ;; drops literature PDFs, typeset outputs, wasm build products and test
 ;; screenshots from history — 606 MiB → 53 MiB of pack, which is what
 ;; lets an anonymous `rad clone` over Tor finish inside heartwood's
 ;; 2-minute fetch window — and re-signs every commit with the operator
 ;; key, so for the first time the WHOLE chain is signed. dcebccc9 is the
 ;; resign-map commit itself; same operator key CAFF…7B2F, same
 ;; .guix-authorizations.
 ;;
 ;; RE-ROOT 2026-09-21: a content review (docs/history/identity-scrub-
 ;; 2026-09-21.tsv) re-made the 1,994 commits from 2026-05-12 onward and
 ;; every descendant — as playnet-ops, same trees, same parents, each signed
 ;; by the operator key CAFF…7B2F with the same .guix-authorizations.
 ;; dcebccc9 became c2251e91: the resign-map commit again, one slice further
 ;; along the same chain.
 ;;
 ;; RE-ROOT 2026-10-07: a content review re-made every commit — same
 ;; operator key CAFF…7B2F, same .guix-authorizations throughout. c2251e91
 ;; became d679134b: the last commit of the review itself, picked as the
 ;; new anchor the same way every prior re-root picked one.
 (channel
  (name 'playnet)
  (url "https://playnet.earth/z27dFkN28LQAsSsG3DVHcfBqYAArQ.git")
  (branch "main")
  (commit "d679134b00995eb3204fb5de79df0c2ca2f7687b")
  (introduction
   (make-channel-introduction
    "d679134b00995eb3204fb5de79df0c2ca2f7687b"
    (openpgp-fingerprint
     "CAFF 2F2B B5CF DFE2 2FBF  B938 6A54 8079 D617 7B2F")))))
