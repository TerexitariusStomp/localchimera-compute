;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/channels.scm — pinned, authenticated channels
;;;
;;; Refresh the Guix pin with: guix describe --format=channels
;;; Refresh the localchimera pin with: git rev-parse HEAD (after each release).
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
 ;; LocalChimera channel — this repository itself.
 ;; Radicle RID: rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ
 ;;
 ;; The URL is the project's own clearnet domain — the box mirrors its own
 ;; repo over ordinary git-smart-HTTP (deploy/os.scm's
 ;; %localchimera-git-mirror-locations: two exact-match nginx locations, nothing
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
 ;; rewrite) → d679134b (RE-ROOTED 2026-10-07, content review,
 ;; abandoned same day — disjoint from canonical, see below) →
 ;; c1b48262 (RE-ROOTED 2026-10-07, anchor-splice) → e14de9cb (RE-ROOTED
 ;; 2026-10-08, prose correction) → 66703caa (RE-ROOTED 2026-10-08, two
 ;; self-naming gitignore entries/kept files renamed, three generic
 ;; pricing modules brought back) → 3cfd16c6 (RE-ROOTED 2026-10-08, a
 ;; generated dependency-graph artifact regenerated) → 13db1c8e
 ;; (RE-ROOTED 2026-10-08, one more dangling doc reference reworded).
 ;;
 ;; RE-ROOT 2026-08-23: two commits, 438b3124 and d0ce6d17 (both
 ;; 2026-08-15, author localchimera-ops), landed UNSIGNED mid-chain — committed
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
 ;; every descendant — as localchimera-ops, same trees, same parents, each signed
 ;; by the operator key CAFF…7B2F with the same .guix-authorizations.
 ;; dcebccc9 became c2251e91: the resign-map commit again, one slice further
 ;; along the same chain.
 ;;
 ;; RE-ROOT 2026-10-07: a content review re-made every commit — same
 ;; operator key CAFF…7B2F, same .guix-authorizations throughout. c2251e91
 ;; became d679134b: the last commit of the review itself, picked as the
 ;; new anchor the same way every prior re-root picked one.
 ;;
 ;; RE-ROOT 2026-10-07 (same day, supersedes the above): the d679134b
 ;; rewrite resigned every commit from genesis (RESIGN_ALL), so it shares
 ;; no commit with the long-lived canonical still on the box and every
 ;; synced peer — `rad`'s own push path refuses this outright (no merge
 ;; base between the two tips, checked against a plain content push, a
 ;; raw ref write and a delegate-only `rad id update`, all three, before
 ;; concluding it's the protocol's ancestry requirement and not a local
 ;; mistake). bab7b7d49 (2026-04-09) is the last commit, walking back from
 ;; canonical's real history, that predates the content review above in
 ;; its entirety — checked by diff and by message across all 217 commits
 ;; from root to there, not just this one. c1b48262 is a single new
 ;; commit on top of it, same operator key, whose tree is the fully
 ;; reviewed scrubbed state — everything after bab7b7d49 in the old
 ;; canonical is gone from this chain's reachable history, squashed
 ;; rather than replayed commit-by-commit, which is what finally gives
 ;; this chain a real merge-base with canonical again: bab7b7d49 itself.
 ;;
 ;; RE-ROOT 2026-10-08: c1b48262 and the channels-reroot commit that
 ;; followed it both carried identifying detail about the content review
 ;; in their own comments and commit messages — a mistake, since this file
 ;; and every commit reaching it are exactly the public, synced content
 ;; this project is trying not to make a finding-aid for. e14de9cb rebuilt
 ;; c1b48262 with the same tree otherwise and corrected prose; this
 ;; commit did the same for the channels-reroot step.
 ;;
 ;; RE-ROOT 2026-10-08 (same day, second pass): e14de9cb's own tree still
 ;; had a couple of gitignore lines and two kept local files named after
 ;; the specific thing being kept quiet, plus a dangling reference from a
 ;; brought-back module to a doc that itself isn't tracked. 66703caa
 ;; rebuilt e14de9cb once more — renamed entries, generic module content —
 ;; same operator key, same .guix-authorizations.
 ;;
 ;; RE-ROOT 2026-10-08 (same day, third pass): 66703caa's tree still
 ;; carried a stale generated artifact (a dependency graph the build
 ;; script walks the filesystem for, not git's tracked-file list) naming
 ;; a removed module. 3cfd16c6 rebuilt 66703caa once more with that
 ;; artifact regenerated — same operator key, same .guix-authorizations.
 ;;
 ;; RE-ROOT 2026-10-08 (same day, fourth pass): a pre-existing module
 ;; (correlation.scm, untouched by every earlier pass) pointed at the
 ;; same untracked spec doc option-composition.scm used to, by filename
 ;; rather than by a category word, so the word-sweep that checked the
 ;; earlier passes missed it. 13db1c8e rebuilds 3cfd16c6 once more with
 ;; that reference reworded — same operator key, same
 ;; .guix-authorizations. This commit redoes the pin update on top of
 ;; that.
 (channel
  (name 'localchimera)
  (url "https://localchimera.earth/z27dFkN28LQAsSsG3DVHcfBqYAArQ.git")
  (branch "main")
  (commit "13db1c8e0d4a7f3f61ddca9d2aa4c53284fb6aa1")
  (introduction
   (make-channel-introduction
    "13db1c8e0d4a7f3f61ddca9d2aa4c53284fb6aa1"
    (openpgp-fingerprint
     "CAFF 2F2B B5CF DFE2 2FBF  B938 6A54 8079 D617 7B2F")))))
