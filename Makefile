all: browser/day-boot.wasm

# The wasm toolchain's identity stamp (rule and rationale at HOOT_TOOLCHAIN_ID).
# A rule's prerequisites expand where the rule is READ, so the name is defined
# here, above every wasm rule.
HOOT_TOOLCHAIN_STAMP = .hoot-toolchain

# The wasm prerequisite lists. The import closures are GENERATED (tools/wasm-deps.mk,
# `make wasm-deps-emit`, checked by check-wasm-deps-fresh); each bundle adds by hand,
# in *_WASM_EXTRA, what a static walk cannot see. Prerequisites expand where a rule is
# read, so the include stands above every wasm rule.
include tools/wasm-deps.mk

# ── The machine node ─────────────────────────────────────────────────────────
# browser/node.html is CANONICAL — edited in place, served as-is, no build
# step. A browser tab is a machine-resource node: it signs in (KERI), offers
# capacity, claims work, executes it in the sandboxed executor and returns
# receipts.

# The node's capability spine: a SLIM Hoot program — gateway CapTP,
# KERI unlock/authenticate, machine offer/claim/execute/receipt — loaded by
# day-boot.js into the same page.
# Its prerequisites are the import closure of hoot/day-boot.scm (tools/wasm-deps.mk).
DAY_BOOT_WASM_EXTRA =
DAY_BOOT_WASM_DEPS = $(DAY_BOOT_WASM_CLOSURE) $(DAY_BOOT_WASM_EXTRA)

browser/day-boot.wasm: hoot/day-boot.scm $(DAY_BOOT_WASM_DEPS) $(HOOT_TOOLCHAIN_STAMP)
	$(HOOT_BUILD_DEV) \
	  guild compile-wasm -L module -L $(FIBERS_LOAD_PATH) \
	    -L $(GOBLINS_LOAD_PATH) \
	    --bundle -o browser/day-boot.wasm hoot/day-boot.scm
	./tools/dev/patch-reflect-mime.sh

# Goblins and fibers come from their own pinned prefixes: the toolchain
# profile's whole site directory would also expose Hoot's host-side modules
# (hoot/primitives.scm is `#:declarative? #f`), which the library-group linker
# refuses to load as a wasm library.

# Feature flags are the minimum the hoot output needs; --all-features must NOT
# be used (it lets passes emit stringref ops today's engines don't take).
WASM_OPT ?= wasm-opt
WASM_OPT_FEATURES = --enable-gc --enable-exception-handling --enable-tail-call \
  --enable-reference-types --enable-bulk-memory --enable-multivalue \
  --enable-sign-ext --enable-mutable-globals


# ── Git hooks (versioned, install via symlinks) ─────────────────────────────
# Hooks live under deploy/scripts/git-hooks/ so they ride in the repo.
# .git/hooks/ is per-clone and never tracked; symlinks bridge the gap.
# The guix-git-authenticate-installed pre-push/post-merge hooks live
# elsewhere and are not touched.
.PHONY: install-hooks
install-hooks:
	@for h in pre-commit prepare-commit-msg pre-push; do \
	  ln -sf "$$(pwd)/deploy/scripts/git-hooks/$$h" ".git/hooks/$$h"; \
	  echo "installed hook: $$h"; \
	done

# ── Satellite pins (deploy/satellites.scm) ──────────────────────────────────
# The core's HEAD is the only input to the deployed system: every other repo
# is consumed at the commit + nar hash pinned in deploy/satellites.scm.
# `make bump SAT=<name>` moves one pin to ../playnet-<name>'s HEAD; the
# pre-push hook runs `check-satellite-pins` so a pin that does not resolve is
# a push refused. Plan: docs/planning/identity/repo-split-and-protocol-doors.md
check-satellite-pins:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm check

bump:
	@[ -n "$(SAT)" ] || { echo "usage: make bump SAT=<name>   (names: deploy/satellites.scm)"; exit 2; }
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm bump "$(SAT)"
	@echo "now: git add deploy/satellites.scm && git commit"

# Place every pinned satellite tree into this checkout (browser/radicle for
# the explorer) from the sibling clones, hash-verified. `make serve` needs it
# once for /radicle/ to answer locally; a no-op while the stamp matches.
satellites:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm place "$(CURDIR)"

# On a machine that holds the clones: each landing directory becomes a symlink
# to ../playnet-<name>, so there is one copy of every satellite file and an
# edit under browser/radicle, server/rns-bridge, … is an edit in that
# satellite's own repo. The pin still decides what ships; `make
# check-satellite-pins` says how far each clone stands past its pin, and
# `make satellites` puts the pinned copies back.
link-satellites:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm link "$(CURDIR)"

# The one command that gives every checkout of the core the same shape:
# clone each satellite beside the core when it is not there (from the mirror
# the box serves; PLAYNET_MIRROR, PLAYNET_GIT_PREFIX=torsocks to override),
# then link it in. SAT="explorer rns-bridge" limits it to those.
workspace:
	@GUILE_AUTO_COMPILE=0 deploy/scripts/satellite-pins.scm workspace "$(CURDIR)" $(SAT)

# Carry a satellite's Radicle storage to the box over SSH (the two nodes do
# not gossip; see deploy/scripts/carry-satellite.sh). Same box/Tor convention
# as `make ship`. Run once per new satellite and after any pin bump whose
# commit the box has not seen.
carry:
	@[ -n "$(SAT)" ] || { echo "usage: make carry SAT=<name>"; exit 2; }
	@PROMOTE_TORSOCKS= PLAYNET_BOX="$${PLAYNET_BOX:-playnet-server}" \
	  bash deploy/scripts/carry-satellite.sh "$(SAT)"

# ── OpenVTC parity (docs/planning/identity/openvtc-parity.md) ────────────────────────
# Our credential/trust layer is hand-ported from OpenVTC, not vendored — so
# there's no satellite pin to gate a build, just a "how far we've read" pin
# on their commit history. `make check-openvtc-parity` fetches upstream into
# a sibling cache (../openvtc-upstream, override PLAYNET_OPENVTC_CACHE) and
# lists commits since the pin that touch credential/trust-relevant paths.
# Read-only; never moves the pin.
.PHONY: check-openvtc-parity
check-openvtc-parity:
	@bash tools/lint/openvtc-parity-check.sh

# ── KERI + OpenVTC library (docs/planning/identity/keri-openvtc-library-split.md) ────
# lint-keri-lib holds the import boundary of module/playnet/keri (First Person included);
# keri-lib-cut builds the standalone playnet-keri repository from committed
# history (local only — publishing it is a separate, deliberate step).
.PHONY: lint-keri-lib keri-lib-cut
lint-keri-lib:
	@guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm

keri-lib-cut: lint-keri-lib
	@bash tools/dev/publish-keri-lib.sh

# Every suite the cut ships, in a PURE shell built from the library's own
# manifest — the proof that a stranger with Guix and the playnet-keri repo has
# all it takes. The same command runs from inside the cut.
KERI_LIB_ENV = guix shell --pure -m deploy/manifests/keri-lib-manifest.scm --
.PHONY: test-keri-lib
test-keri-lib: lint-keri-lib
	@tests="$$(guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm --manifest | grep '^tests/')"; \
	$(KERI_LIB_ENV) $(OWN_CCACHE) sh -c 'fail=0; for t in '"$$(echo $$tests)"'; do \
	  if guile --no-auto-compile -q -L module $$t >/tmp/keri-lib-test.log 2>&1; \
	  then echo "ok   $$t"; else echo "FAIL $$t"; tail -5 /tmp/keri-lib-test.log; fail=1; fi; done; exit $$fail'

# Carry a contributor's commits from playnet-keri into the core: held to the
# library's paths, proven in a scratch worktree (gate + every shipped suite),
# landed under their author.  usage: make keri-lib-take RANGE=main..patch/<id>
.PHONY: keri-lib-take
keri-lib-take:
	@[ -n "$(RANGE)" ] || { echo "usage: make keri-lib-take RANGE=main..patch/<id>   (a range in ../playnet-keri)"; exit 2; }
	@bash tools/dev/keri-lib-take.sh "$(RANGE)"

# Publish a cut the way every satellite moves: cut from committed history,
# sign the tip with the key the core's commits carry (filter-repo writes
# unsigned commits; a signed tag over the tip commits to the whole history
# under it), push to Radicle, carry the storage to
# the box (the two nodes do not gossip), move the pin. Then commit
# deploy/satellites.scm and `make ship`.
.PHONY: keri-lib-publish
keri-lib-publish: keri-lib-cut
	@cd ../playnet-keri && tag="cut-$$(git -C $(CURDIR) rev-parse --short=12 HEAD)" && \
	  { git rev-parse -q --verify "refs/tags/$$tag" >/dev/null || git -c user.signingkey="$$(git -C $(CURDIR) config user.signingkey)" -c user.name="$$(git -C $(CURDIR) config user.name)" -c user.email="$$(git -C $(CURDIR) config user.email)" tag -s "$$tag" -m "playnet-keri cut from core $$(git -C $(CURDIR) rev-parse HEAD)"; } && \
	  git push rad HEAD:main keyring && git push rad "refs/tags/$$tag"
	@$(MAKE) --no-print-directory bump SAT=keri
	@$(MAKE) --no-print-directory carry SAT=keri
	@echo "now: git add deploy/satellites.scm && git commit && make ship"

# ── Laptop-side secret backups (three-tier redundancy) ──────────────────────
# Tier 1: USB    — deploy/.age-key.txt + deploy/secrets.scm.age  (working copy)
# Tier 2: laptop — ~/.playnet-secrets/playnet.age-key.txt + .secrets.scm
# Tier 3: vault  — ~/.playnet-secrets/playnet-vault.kdbx attachments
#
# `make backup-laptop` refreshes tier 2 from tier 1 (no interaction).
# `make backup-vault` updates tier 3 from tier 2 (prompts for vault pw once).
# `make backup-all` does both.
PLAYNET_HOME_SECRETS = $(HOME)/.playnet-secrets
.PHONY: backup-laptop backup-vault backup-all
backup-laptop:
	@mkdir -p "$(PLAYNET_HOME_SECRETS)"
	@chmod 700 "$(PLAYNET_HOME_SECRETS)"
	@cp -f deploy/.age-key.txt "$(PLAYNET_HOME_SECRETS)/playnet.age-key.txt"
	@chmod 600 "$(PLAYNET_HOME_SECRETS)/playnet.age-key.txt"
	@age -d -i deploy/.age-key.txt deploy/secrets.scm.age \
	  > "$(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"
	@chmod 600 "$(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"
	@echo "tier 2 refreshed:"
	@echo "  $(PLAYNET_HOME_SECRETS)/playnet.age-key.txt"
	@echo "  $(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"

backup-vault:
	bash deploy/scripts/backup-to-vault.sh

backup-all: backup-laptop backup-vault

CHANNELS = deploy/channels.scm

# ── Bootable ISO (Path B of the confidential-VPS provider deploy story) ─────
# Builds a minimal Guix System ISO with the operator SSH key baked in.
# See deploy/playnet-iso.scm (provider-specific guide — kept in the private
# ops vault, not in the public repo).
#
#   make iso         → iso9660 image (for the provider's "Custom ISO" upload)
#   make iso-raw     → raw disk image (for providers that dd onto disk)
#
# Both targets create a stable symlink (./result-iso, ./result-iso-raw)
# that doubles as a Guix GC root — the built image survives `guix gc`
# between iterations. Cookbook §3.3 (System Image API).
.PHONY: iso iso-raw
iso:
	guix time-machine -C $(CHANNELS) -- \
	  system image --root=result-iso -t iso9660 -L deploy/guix \
	  deploy/playnet-iso.scm

iso-raw:
	guix time-machine -C $(CHANNELS) -- \
	  system image --root=result-iso-raw -t mbr-hybrid-raw -L deploy/guix \
	  deploy/playnet-iso.scm

# Build the ISO and publish it to IPFS so the VPS provider (or any provider that
# requires an HTTPS URL) can fetch from a public gateway. Writes the CID
# to deploy/iso-cid.txt for downstream consumers. CI runs this on push
# to main; commits the updated cid file back with [skip ci].
#
#   make publish-iso
#
# Requires `ipfs` (Kubo) installed and daemon running. Optional remote
# pinning service via PUBLISH_ISO_PIN_SERVICE=pinata|web3storage.
# See deploy/scripts/publish-iso.sh for full env-var docs.
.PHONY: publish-iso
publish-iso:
	bash deploy/scripts/publish-iso.sh

# Boot the ISO locally in QEMU with port-forwarded SSH (host 2222 → guest 22).
# Smoke test the operator key + installer before uploading to the provider.
# Builds the ISO first if needed. See deploy/scripts/qemu-test-iso.sh.
#
#   make qemu                # build + boot, fresh 10GB disk each time
#   KEEP_DISK=1 make qemu    # preserve the disk between runs
#
# In another terminal:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#     root@localhost
.PHONY: qemu
qemu:
	guix shell qemu ovmf -- bash deploy/scripts/qemu-test-iso.sh

# ── Workstation → server: apply production OS via guix deploy ───────────────
# Runs from your workstation against a host that's been installed by the ISO
# (or the provider's prebuilt Guix). Pinned via channels.scm.
#
#   make deploy PROVIDER=deploy/providers/provider-1.scm
#
# Optional: DEPLOY_SSH_IDENTITY=~/.ssh/id_ed25519 (read by machines.scm).
.PHONY: deploy
deploy:
ifndef PROVIDER
	$(error PROVIDER is required, e.g. make deploy PROVIDER=deploy/providers/provider-1.scm)
endif
	PLAYNET_PROVIDER=$(PROVIDER) \
	  guix time-machine -C $(CHANNELS) -- \
	  deploy -L deploy/guix -L module deploy/machines.scm

# ── Server-side reconfigure (run ON the server, not laptop) ─────────────────
# Smaller closure delta because the server's local store already has the
# deps — only what changed in our config gets built. Preferred over `make
# deploy` from laptop, which transfers laptop↔server divergence (often
# 500 MB+ if laptop's guix is newer).
#
#   sudo PROVIDER=deploy/providers/provider-1.scm make reconfigure
#
# Prereq once: `sudo guix pull` to bound the closure delta.
#
# guix system reconfigure loads the new generation but leaves every
# already-running service on its OLD one, config changes included — Guix
# computes which running services could restart and never acts on that list
# (reference_guix_reconfigure_no_restart memory; the manual's own guix
# deploy advice says restarting is the operator's job). reconfigure-restarts.sh
# is that job, done: nginx and the radicle-configure one-shot, the two this
# box has actually needed it for.
.PHONY: reconfigure
reconfigure:
ifndef PROVIDER
	$(error PROVIDER is required, e.g. PROVIDER=deploy/providers/provider-1.scm)
endif
	PLAYNET_PROVIDER=$(PROVIDER) \
	  guix system reconfigure -L deploy/guix deploy/os.scm
	@bash deploy/scripts/reconfigure-restarts.sh

# Mint a fresh First-Person founder identity (fallback path — prefer signing
# up on the dial so the key never leaves the browser). Prints a passcode +
# AID; activate with `bash deploy/scripts/add-founder.sh <AID>`.
.PHONY: founder
founder:
	$(TEST_ENV) \
	  guile --no-auto-compile -q -L module deploy/scripts/mk-founder.scm

# ── Multi-developer flow (see CONTRIBUTING.md) ──────────────────────────────
# contributor: one-command onboarding — mint a local Radicle identity. Needs
# NO infra access. After this, `rad clone $$PLAYNET_RID --seed <seed>` (get the
# seed from a maintainer; it is intentionally not committed — opsec) then
# `rad patch open` to contribute.
.PHONY: contributor
contributor:
	@command -v rad >/dev/null || { echo "rad CLI not found — install Radicle 1.7+ (https://radicle.xyz)"; exit 1; }
	@rad auth
	@echo ""
	@echo "Identity minted. Next:"
	@echo "  export PLAYNET_RID=rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ"
	@echo "  export PLAYNET_SEED='<node-id>@<seed-host>:<port>'   # ask a maintainer"
	@echo "  rad clone \$$PLAYNET_RID --seed \$$PLAYNET_SEED"
	@echo "Then: hack → make test → git commit -S → rad patch open. See CONTRIBUTING.md."

# merge-patch: DELEGATE action — promote a reviewed patch to canonical + deploy.
# Contributors never run this.  usage: make merge-patch PATCH=<patch-id>
.PHONY: merge-patch
merge-patch:
	@test -n "$(PATCH)" || { echo "usage: make merge-patch PATCH=<patch-id>"; exit 1; }
	bash deploy/scripts/merge-patch.sh $(PATCH)

# ship: DELEGATE — one command to update the board + deploy from your own main.
# Signs the current main as ops, carries the delegate ref to the box seed
# (canonical is a quorum of BOTH delegate refs — the box push alone leaves the
# Explorer frozen), advances canonical, and deploys. Uses the Tor ssh alias, no
# torsocks. Defaults to HEAD; override with SHA=<commit> and/or PLAYNET_BOX=.
.PHONY: ship
ship:
	@SECRETS="$(PLAYNET_HOME_SECRETS)/playnet.secrets.scm"; \
	OMAR=""; \
	[ -f "$$SECRETS" ] && OMAR="$$(sed -n 's/.*setenv "RAD_OMAR_PASSPHRASE" "\([^"]*\)".*/\1/p' "$$SECRETS")"; \
	if [ -z "$$OMAR" ]; then \
	  echo "note: RAD_OMAR_PASSPHRASE not set in secrets — relying on the radicle agent."; \
	  echo "      For headless/automatic canonical propagation, add it to the age secrets:"; \
	  echo "        bash deploy/scripts/secrets-decrypt.sh  # -> deploy/secrets.scm"; \
	  echo "        \$$EDITOR deploy/secrets.scm             # set (setenv \"RAD_OMAR_PASSPHRASE\" \"…\")"; \
	  echo "        bash deploy/scripts/secrets-encrypt.sh && make backup-laptop && shred -u deploy/secrets.scm"; \
	fi; \
	RAD_OMAR_PASSPHRASE="$$OMAR" PROMOTE_TORSOCKS= PLAYNET_BOX="$${PLAYNET_BOX:-playnet-server}" \
	  bash deploy/scripts/promote.sh "$(or $(SHA),$$(git rev-parse HEAD))" omar

TIME_MACHINE = guix time-machine -C $(CHANNELS) --
# The wasm toolchain: Hoot 0.9.0 of the pinned Guix commit (GUIX_CHANNEL_PIN
# below) plus the upstream fixes deploy/guix/playnet-hoot.scm carries.
# `--commit=` time-machines the guix channel alone, so the Radicle channel's
# libgit2 hang stays out of the way and every machine, the box included,
# resolves the same Hoot, Goblins, fibers and Guile. The -L path is absolute
# because `local-file` resolves the patch files against it.
HOOT_PINNED = guix time-machine --commit=$(GUIX_CHANNEL_PIN) --
HOOT_PKG = -L $(CURDIR)/deploy/guix -e '(@ (playnet-hoot) guile-hoot/playnet)'

# Every wasm bundle loads the same browser/reflect.js, which belongs to the Hoot
# that compiled the bundles: one wasm built by another Hoot cannot instantiate
# under it. A toolchain change (the Guix pin, playnet-hoot.scm, its patches) is
# therefore a rebuild-everything event that no source file records, so the stamp
# below carries it: it is rewritten only when the toolchain's identity changes,
# and every wasm rule lists it as a prerequisite.
HOOT_TOOLCHAIN_ID = $(GUIX_CHANNEL_PIN) $(shell cat deploy/guix/playnet-hoot.scm deploy/guix/patches/hoot/*.patch | sha256sum | cut -c1-16)
.PHONY: FORCE
FORCE:
$(HOOT_TOOLCHAIN_STAMP): FORCE
	@echo '$(HOOT_TOOLCHAIN_ID)' | cmp -s - $@ || echo '$(HOOT_TOOLCHAIN_ID)' > $@

# ── Two-tier runner strategy ────────────────────────────────────────────────
# The test tree runs under plain `guix shell -m dev-test-manifest.scm`
# (no time-machine) because `deploy/channels.scm` pins the `playnet` channel
# to a Radicle seed whose git HTTP bridge currently hangs `guix time-machine`'s
# libgit2 client (bare `git ls-remote` works fine — it's a guix-libgit2 bug).
# Production paths (`guix deploy`, `guix pull`, the live-hacking dev bundle)
# still use channels.scm — see deploy/manifests/*.scm headers for the
# trade-off explainer. When the seed's bridge becomes libgit2-friendly again,
# `make test-all-pinned` is the reproducibility canary that lights up.
#
#   GUILE_RUN       — vanilla server-side Guile + Goblins (REPLs, relay, server)
#                     [pinned via time-machine — production semantics]
#   GUILE_TEST      — same as GUILE_RUN; pinned. Used by test-all-pinned.
#   GUILE_TEST_DEV  — fast dev test runner; non-pinned. Used by test-all and
#                     the inner-loop test-* targets.
#   HOOT_RUN        — Hoot 0.9 + fibers + websocket (anything that imports
#                     `(hoot web-server)` / `(hoot web-repl)`) [guix-pinned]
#   HOOT_RUN_DEV    — the same environment; the dev spelling `make serve` uses.
#   HOOT_BUILD      — environment for `guild compile-wasm` (no `guile`, just the
#                     tool the wasm compiler needs) [guix-pinned]
#   HOOT_BUILD_DEV  — the same environment; the dev spelling the wasm rules use.
GUILE_RUN      = $(TIME_MACHINE) shell guile-next guile-goblins -- \
                   $(OWN_CCACHE) guile --no-auto-compile
GUILE_TEST     = $(GUILE_RUN)
# ── the one door into the test environment ──────────────────────────────────
# Every dev-manifest target goes through this, so there is a single place where
# what the suite may see is decided.
#
# --pure IS THE POINT. `guix shell` without it inherits PATH and the loader's
# search, so the environment that ran the tests was the manifest PLUS whatever
# the developer's machine happened to carry — and three separate things were
# quietly coming from the host rather than from the manifest: the C compiler
# (/usr/bin/cc, where the profile has no `cc` at all), libosqp, and GNU units.
# All three passed here and failed on CI, which is the only reason we know.
# A manifest that is not enforced is a description of an environment nobody
# runs.
#
# LC_ALL=C.UTF-8 because --pure takes the locale too and Guile then renders the
# suite's box-drawing and ✓ as `?`. C.UTF-8 is built into glibc and needs no
# locale package — glibc-locales is 972 MB, and the requirement here is UTF-8,
# not every collation on earth.
#
# OWN_CCACHE keys Guile's compiled-file cache by the guile BINARY the shell
# resolves. Two builds of one version share ~/.cache/guile/ccache/3.0-LE-8-4.7,
# and a .go one compiled kills the other ("expecting mutable bytevector",
# 117 suites red, zero regressions) — see tools/test/own-ccache.sh. Every guile
# entry point below goes through it, so the manifest's guile, the pinned
# time-machine guile and Hoot's guile-next each read only what they wrote.
OWN_CCACHE = bash tools/test/own-ccache.sh
TEST_ENV = guix shell --pure -L deploy/guix \
             -m deploy/manifests/dev-test-manifest.scm -- $(OWN_CCACHE) env LC_ALL=C.UTF-8

GUILE_TEST_DEV = $(TEST_ENV) guile --no-auto-compile

# The development scope's own tool (tools/dev/dev-plan.scm) needs `rad` on PATH
# beside the manifest's solver — NOT --pure, since `rad` lives in the host
# profile and the manifest never names it.
DEV_ENV = guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- $(OWN_CCACHE) env LC_ALL=C.UTF-8

HOOT_RUN       = $(HOOT_PINNED) shell guile-next $(HOOT_PKG) \
                   guile-goblins guile-fibers guile-websocket guile-zlib -- \
                   $(OWN_CCACHE) guile --no-auto-compile
HOOT_RUN_DEV   = $(HOOT_RUN)
HOOT_BUILD     = $(HOOT_PINNED) shell guile-next $(HOOT_PKG) guile-goblins -- $(OWN_CCACHE)
HOOT_BUILD_DEV = $(HOOT_BUILD)

# Hoot's `guild compile-wasm` resolves imports strictly from `-L` paths
# (it does NOT consult GUILE_LOAD_PATH; see hoot/scripts/compile-wasm.scm
# → library-load-path-extension). Goblins lives in the guix profile, so
# we resolve the active profile's site dir at make time and pass it via -L.
# CRITICAL: this goblins MUST match the deployed gateway's version. The
# OCapN WebSocket designator handshake changed 0.17->0.18 (designator nonce
# size + framing); a wasm built against a different goblins than the gateway
# runs is rejected at connect with "WebSocket designator verification failed"
# — every browser client silently fails. A bare `guix build guile-goblins`
# uses the build host's channel (was 0.17.0 while production ran 0.18.0 → the
# 2026-06-07 outage). PIN to the guix channel commit from deploy/channels.scm
# via a guix-only time-machine (reliable; skips the radicle playnet channel).
# Bump GUIX_CHANNEL_PIN in lockstep with deploy/channels.scm (name 'guix).
GUIX_CHANNEL_PIN = 5f42ab7d46cf22b19844521b2385a7890faf274b
GOBLINS_PREFIX = $(shell guix time-machine --commit=$(GUIX_CHANNEL_PIN) -- build guile-goblins 2>/dev/null)
GOBLINS_LOAD_PATH = $(GOBLINS_PREFIX)/share/guile/site/3.0
GOBLINS_CCACHE    = $(GOBLINS_PREFIX)/lib/guile/3.0/site-ccache

# hoot/day-boot.scm imports (fibers channels) and (fibers conditions), and
# compile-wasm reads imports ONLY from -L (see the note above the wasm
# rules). Resolve fibers from the same pin as goblins, for the same reason
# and by the same mechanism, so a checkout needs no local symlink farm to
# build the wasm bundles.
FIBERS_PREFIX = $(shell guix time-machine --commit=$(GUIX_CHANNEL_PIN) -- build guile-fibers 2>/dev/null)
FIBERS_LOAD_PATH = $(FIBERS_PREFIX)/share/guile/site/3.0

# Any process that talks OCapN to browser/*.wasm MUST use this same pinned
# Goblins. The wasm bundles are compiled against it; an ambient `guix shell
# guile-goblins` can resolve to a different version, and the OCapN websocket
# handshake is NOT compatible across versions — it fails as "WebSocket
# designator verification failed" in the browser and "invalid client
# verification message" in the gateway log. tools/dev/dev.sh reads these via `make -s print-goblins-path`.
.PHONY: print-goblins-path
print-goblins-path:
	@echo "$(GOBLINS_LOAD_PATH):$(GOBLINS_CCACHE)"

# Same idea for fibers, so a hand-run `guild compile-wasm` outside the
# Makefile can pass the same pinned -L the build rules use.
.PHONY: print-fibers-path
print-fibers-path:
	@echo "$(FIBERS_LOAD_PATH)"

# ── Local dev REPLs ──────────────────────────────────────────────────────────

repl:
	$(GUILE_RUN) -L module server/repl.scm

# ── Wasm builds ──────────────────────────────────────────────────────────────


# `serve` just runs the server — it does NOT build anything. The wasm
# (browser/day-boot.wasm) is a gitignored BUILD PRODUCT (the box builds its
# own on deploy), so a fresh clone has none until you run `make`. serve only
# CHECKS it exists and says how to build it: `make` or `make browser/day-boot.wasm`.
serve:
	@[ -f browser/day-boot.wasm ] || echo "make serve: browser/day-boot.wasm is absent (build product) — the node needs it: run \`make\`";
	@P="$(if $(PORT),$(PORT),8080)"; \
	if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$$P "; then \
	  echo "make serve: port $$P is already in use — a stray server is squatting on it."; \
	  echo "  free it:  pkill -f 'run-static-server'; pkill -f 'http.server'"; \
	  echo "  or:       PORT=8081 make serve"; \
	  exit 1; \
	fi
	PLAYNET_DEV=1 PLAYNET_FIBERS=1 $(HOOT_RUN_DEV) -L . -L module \
	  -c '((@ (server serve-static) run-static-server) #:work-dir "browser" #:oobi-dir "$(if $(OOBI_DIR),$(OOBI_DIR),data/oobi-host)" #:port $(if $(PORT),$(PORT),8080))'

# Reliable headless SCREENSHOT of a local page — via Playwright + guix
# ungoogled-chromium (UNCONFINED). The snap Firefox hangs headless under
# Wayland/snap confinement from a non-login shell, so we don't use it. Needs
# `make serve` running. Writes outside the repo by default.
#   make shot                                  # the share face → ~/playnet-dev-shots/shot.png
#   make shot URL='http://127.0.0.1:8080/node.html' OUT=/tmp/cal.png W=420 H=800
.PHONY: shot
shot:
	bash tools/dev/shot.sh "$(if $(URL),$(URL),http://127.0.0.1:8080/node.html)" \
	  "$(if $(OUT),$(OUT),$(HOME)/playnet-dev-shots/shot.png)" $(if $(W),$(W),1400) $(if $(H),$(H),900)

# The day dial, LIVE: the whole local stack in ONE command — a real gateway
# (no KERIA), the static server pointed at that gateway's own state dir, and
# the URL that joins them (?gateway=<sref> — discovery's highest-priority
# source). An already-running `make serve` is reused and left alone. State
# persists in .dev-data; identity and plan survive restarts.
#   make dev
.PHONY: dev
dev: browser/day-boot.wasm
	bash tools/dev/dev.sh

# The day dial, LIVE ON YOUR PHONE, over a throwaway .onion. A dedicated tor
# instance (own data dir, system tor untouched) maps onion:80 -> :8080, and a
# file watcher live-reloads the page. Open the printed ?dev=1 URL in Tor
# Browser / Onion Browser. Needs `make serve` running in another terminal.
#   make onion            # persistent onion (bookmarkable across restarts)
#   FRESH=1 make onion    # rotate to a brand-new onion
.PHONY: onion
onion:
	bash tools/dev/onion.sh

# ── Offline routing engine (Tier-1 Valhalla; serve-static proxies /route) ───
# Data pipeline (fetch → tzdb → calendar → config → transit → tiles) and the
# engine itself live behind tools/dev/valhalla-local.sh; see its header.
.PHONY: routing-data routing-serve routing-stop
routing-data:
	bash tools/dev/valhalla-local.sh all
routing-serve:
	bash tools/dev/valhalla-local.sh serve
routing-stop:
	bash tools/dev/valhalla-local.sh stop

# The basemap's archives: tools/emit/map-tiles.sh cuts one PMTiles file per region of
# tools/emit/regions.tsv from a Protomaps build of OpenStreetMap (a range read of
# the planet file, over Tor) into data/map/, and fetches the labels' glyphs
# into browser/assets/map/fonts/. Both are out of git; the deploy rsync ships
# the glyphs with browser/, and the box cuts its own archives.
#   make map-tiles                        every region to z15
#   REGIONS=berlin MAXZOOM=12 make map-tiles
#   MAP_DIR=/var/lib/playnet/map make map-tiles    on the box
.PHONY: map-tiles
map-tiles:
	bash tools/emit/map-tiles.sh

# test      — the FULL green baseline: every hermetic .scm test under tests/ and
#             module/**/tests/, auto-discovered (a new test file can never rot by
#             being forgotten from this Makefile), minus tests/QUARANTINE (each
#             exclusion carries its reason). Green/red is the process exit code —
#             the harness's test-summary! already exits 1 on any failure. One guix
#             shell is entered for the whole run; the runner loops guile inside it.
# test-fast  — the curated quick subset, for the tight pre-push / dev inner loop.
# ── CI's test environment, made resident ────────────────────────────────────
# `make test` enters `guix shell -m dev-test-manifest.scm`. On a machine where
# that manifest is not already in the store, the shell BUILDS it first — and on
# the box no substitute exists for blake3, so every CI run spent its whole
# budget compiling and never reached the runner. The job reported failure with
# an empty log, which read as "the tests are red" and was really "the tests
# never ran". CI had not validated a commit since the broker took over.
#
# `guix shell --root` is the fix Guix already provides: it materialises the
# environment AND registers a GC root, so the closure survives `guix gc` and
# every later shell for that manifest is a store lookup (measured on the box:
# 13 MB source build → 2.9 s).
#
# RE-RUN IT AFTER EVERY MANIFEST CHANGE. The root pins the profile it was made
# from, not the manifest, so adding a package leaves the new closure unprotected
# while the stale root still looks present and correct — which is exactly what
# happened when gcc-toolchain, osqp, units and findutils joined the manifest.
# `guix shell --root` refuses to overwrite an existing symlink, so this target
# claimed to be idempotent and errored out on its second run; the old root is
# dropped first, which is what makes the claim true.
#
#   make ci-warm                       # on the machine that runs CI
#   ssh <box> 'cd <checkout> && make ci-warm'
CI_ENV_ROOT ?= /var/lib/playnet/ci-test-env
.PHONY: ci-warm
ci-warm:
	rm -f $(CI_ENV_ROOT)
	guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm \
	  --root=$(CI_ENV_ROOT) -- true
	@echo "  ✓ test environment resident at $(CI_ENV_ROOT) (a GC root; gc will not collect it)"

# The same for the wasm toolchain. `guix shell` caches no profile and
# registers no root, so the first `guix gc` after a wasm build collects the
# patched Hoot and the next build compiles it again from source: ~10 minutes
# on the box, found 2026-09-23 the first time a gc actually ran there. This
# root is the same package set as HOOT_BUILD_DEV, so it pins exactly the
# closure that build resolves. The deploy hook runs it before every wasm build;
# re-run it by hand after a change to playnet-hoot.scm or the pinned Guix.
#
# `guix build --root` registers one root per output (HOOT_ENV_ROOT-0, -1, …)
# and exits cleanly. At the pinned Guix, `guix shell guile-next guile-hoot
# --root=…` registers its root and then aborts with a struct-vtable error in the
# error reporter (guile-next with guile-hoot is the trigger; either alone is
# fine, and the same command succeeds on Guix master of 2026-10-01).
HOOT_ENV_ROOT ?= /var/lib/playnet/hoot-env
.PHONY: hoot-warm
hoot-warm:
	rm -f $(HOOT_ENV_ROOT) $(HOOT_ENV_ROOT)-*
	$(HOOT_PINNED) build guile-next guile-goblins $(HOOT_PKG) \
	  --root=$(HOOT_ENV_ROOT) >/dev/null
	@echo "  ✓ wasm toolchain resident at $(HOOT_ENV_ROOT)-* (GC roots; gc will not collect them)"

# ── and kept fresh without anyone remembering ───────────────────────────────
# A GC root pins the profile it was made FROM, not the manifest, so it goes
# stale the moment a package is added — while still looking perfectly healthy.
# Nothing about a stale root is visible until `guix gc` collects the closure it
# was supposed to protect and CI is back to compiling blake3 from source.
#
# Hanging this off `make ship` was the obvious move and is the wrong one: ship
# runs on a laptop and the root lives on the box, so it would faithfully
# maintain a GC root on the machine that does not need one. The machine that
# needs it is the machine that runs the suite — so the suite maintains it, on
# whatever host it happens to be running, every time.
#
# Silent everywhere else: the guard is whether this host has a writable
# directory to put the root in. A developer's laptop has no /var/lib/playnet,
# so this is a no-op there and `make test` is unchanged.
.PHONY: ci-env
ci-env:
	@if [ -w "$$(dirname $(CI_ENV_ROOT))" ]; then \
	  $(MAKE) --no-print-directory ci-warm >/dev/null 2>&1 \
	    && echo "  ✓ test-env GC root refreshed → $$(readlink $(CI_ENV_ROOT))" \
	    || echo "  ! could not refresh the test-env GC root at $(CI_ENV_ROOT)" >&2; \
	fi

# ── the compiled hot loop ───────────────────────────────────────────────────
# planner.scm's `native-c` backend dlopens this, and it is a build artifact: the
# .c and the generated header are tracked, the .so is not. So a fresh checkout —
# CI's, or a new contributor's — has every source it needs and cannot run a
# single native-c solve until this rule fires. Make's own dependency is the
# honest place to say that; before it existed the suite passed only on a machine
# where someone had run the kernel's Makefile by hand, which is exactly the class
# of local-state accident that the stale-.go trap is made of.
#
# It builds INSIDE the test environment, not against the host's compiler, so the
# object and the Guile that loads it come from one manifest.
KERNEL_SO := module/playnet/solve/kernel/libplanner_kernel.so
KERNEL_SRC := module/playnet/solve/kernel/kernel.c \
              module/playnet/solve/kernel/kernel_kinds.h

.PHONY: kernel
kernel: $(KERNEL_SO)

$(KERNEL_SO): $(KERNEL_SRC) module/playnet/solve/kernel/Makefile
	$(TEST_ENV) \
	  make -C module/playnet/solve/kernel

# The source lints every gate runs, and the one way the suite is run.
LINTS = lint-parens lint-layers lint-verbs lint-ids lint-compile
SUITE = $(TEST_ENV) RED_BASELINE=$(RED_BASELINE) bash tools/test/run-scm-tests.sh

.PHONY: test test-all test-fast
# `make test RED_BASELINE=file` compares the red list by name with FILE (written on
# the first run) and fails only on a test that is red and not named there.
test test-all: $(LINTS) freshen-ccache $(KERNEL_SO) ci-env
	$(SUITE)

# ── THE GATE: what a commit passes ───────────────────────────────────────────
# One list, written once. `make gate` is the lints, the wiring and protocol
# checks, every generated file's freshness, the wasm prerequisites, and the
# suite (the same run as `make test`); `` adds the two wasm bundles, the
# slow part. `gate-local` is what needs files ignored by path (the docs, the legal
# contexts), so it runs where they are, in the shared tree. `make test` stays what
# CI runs. tools/dev/commit-clean.py --gate runs `make emit-all gate `
# in a clean worktree before it commits.
#
# FRESH_CHECKS and FRESH_LOCAL are every `check-*-fresh` target but the ones
# FRESH_EXEMPT names; check-test-wiring fails when a new one is in none of the
# three, so a generated file cannot be added without its check being in a gate.
# EMITS regenerates the portable ones in dependency order (`ui` last: tsc reads the
# .ts files the other emits write); `make emit-all` is for a clean worktree,
# where it reads that tree alone.
FRESH_CHECKS = check-protocol-fresh check-wire-types-fresh \
  check-attribution-fresh check-notice-facts-fresh \
  check-de-fresh check-fdc-fresh \
  check-wasm-deps-fresh check-keyed-fresh check-offline-fresh check-ui-fresh
# these read files ignored by path (the legal contexts, the physics register): a clean
# worktree has none, so they run where the files are, in `gate-local`
FRESH_LOCAL = check-na-fresh
# for the reader, not the gate (see module-map)
FRESH_EXEMPT = check-module-map-fresh
# fdc-snapshot needs a 6 MB cache the repo does not carry; check-fdc-fresh skips without it
EMITS = wasm-deps-emit protocol-emit keyed-emit offline-emit wire-types-emit attribution-emit \
  notice-facts-emit de-pack ui
# na-packs before : the snapshot reads the packs
EMITS_LOCAL = na-packs

.PHONY: check-fresh check-fresh-local emit-all emit-local gate gate-static gate-local print-fresh-checks
check-fresh: $(FRESH_CHECKS)
check-fresh-local: $(FRESH_LOCAL)
emit-all:
	@for t in $(EMITS); do echo "emit-all: $$t"; $(MAKE) --no-print-directory $$t || exit 1; done
emit-local:
	@for t in $(EMITS_LOCAL); do echo "emit-local: $$t"; $(MAKE) --no-print-directory $$t || exit 1; done
print-fresh-checks:
	@echo $(FRESH_CHECKS) $(FRESH_LOCAL) $(FRESH_EXEMPT)
gate-static: $(LINTS) check-test-wiring check-protocol check-fresh check-wasm-deps
gate: gate-static freshen-ccache $(KERNEL_SO) ci-env
	$(SUITE)
gate-local: lint-docs check-crossing-catalogue check-fresh-local

# run-scm-tests.sh leaves auto-compile ON because "a stale .go is worse than a
# slow run". That holds for imports and NOT for includes: an edited fragment
# never moves its includer's mtime, so auto-compile has nothing to react to and
# the engine loads stale. This drops exactly those .go files first, restoring
# the guarantee the runner already intends. ~1.6s, outside $(TEST_ENV) since it
# only reads mtimes.
.PHONY: freshen-ccache
freshen-ccache:
	@bash tools/test/freshen-ccache.sh

test-fast: lint-parens lint-docs check-wasm-deps check-ui-fresh test-gplay test-notify-registry test-notify-adapters \
 test-recipient-registry test-notify-router \
 test-keystore test-handler-bridge test-capabilities test-bytes test-keys test-store test-idb test-rns-identity test-reactive test-mesh-plan test-ice-servers test-units-fallback test-bran-derivations \
 test-contact-binding test-cards test-planner-facet test-declared-dispatch test-http-door test-mcp-door test-device-doors test-vf-lint test-issue-revoke-credential test-admit-commune-door test-delegation-scope-arg test-lobby-arg-split test-websocket-fragments test-websocket-masking test-observation-evidence test-counting test-allotment test-see-door test-contest-count test-evidence-door check-protocol check-protocol-fresh check-wire-types-fresh check-crossing-catalogue check-attribution-fresh check-notice-facts-fresh check-rid-mentions check-de-fresh check-na-fresh test-adjustment check-test-wiring check-atlas

# every generated file's freshness, from the gate's own list; and the committer's own test
test-fast: check-fresh test-commit-clean 

# Every tracked .scm reads to EOF. ~3s over ~1070 files, so it can sit in
# front of the whole suite rather than off to the side.
#
# The compiler already rejects an unbalanced form — but only in files some
# test imports. Standalone scripts under module/ and tools/ are read by
# nothing, so a broken paren in one is invisible until someone runs it by
# hand: (playnet utils parse-unit-definitions) carried a missing close paren
# from its first commit. This is the check that sees those.
#
# Runs OUTSIDE $(TEST_ENV) on purpose — the reader is plain Guile with no
# module resolution, so the pure shell buys nothing and costs a few seconds.
.PHONY: lint-parens
lint-parens:
	@LC_ALL=C.UTF-8 guile --no-auto-compile tools/lint/lint-parens.scm

# A planning map "read off the code" is a set of claims that a name lives at a
# line of a file. Every cite resolves against the tree.
LINTED_DOCS =
.PHONY: lint-docs
lint-docs:
	@LC_ALL=C.UTF-8 guile --no-auto-compile tools/lint/doc-cites.scm $(LINTED_DOCS)

# A rule that names a jurisdiction no pack places can never fire, and nothing at
# runtime will ever say so. Reads the packs without registering them, so it costs
# a second and needs no vat.
#
# Runs INSIDE $(TEST_ENV): loading the packs pulls in (playnet knowledge
# context-pack), which imports (goblins). A bare `guile` finds goblins only where
# the user's profile happens to carry it, so native CI (system profile only)
# failed here with "no code for module (goblins)".
# The spec's crossing table (docs/playnet.typ `crossing-catalogue`) names the
# crossings of the code's catalogue (legal/crossings.scm), each of the same kind.
.PHONY: check-crossing-catalogue
check-crossing-catalogue:
	@$(GUILE_TEST_DEV) -L module tools/lint/check-crossing-catalogue.scm

# Every tracked mention of the core RID (read live via `rad inspect`) or a
# satellite's (deploy/satellites.scm) — a transition checklist, not an
# enforcement gate: it only lists, never fails, since most of what it finds
# (a README clone command, a Guix channel url) is read by a human or by Guix
# itself, not by anything this repo's own env-var reading covers. The three
# places that quote the shipped attribution's own RID token (below) are the
# exception — those regenerate.
.PHONY: check-rid-mentions
check-rid-mentions:
	@tools/lint/check-rid-mentions.sh

# The OSS-inventory gates (spec/oss-inventory.md): every adopted component's
# license must be free + commercially usable, and first-party lines may only
# ratchet down toward the ≤5%-of-deployed budget.
.PHONY: check-licenses check-custom-budget check-parity sbom
check-licenses:
	@tools/lint/check-licenses.sh
check-custom-budget:
	@tools/lint/check-custom-budget.sh
check-parity:
	@tools/lint/check-parity.sh
sbom:
	@tools/sbom.sh

# The RID token in LICENSE-ADDITIONAL-TERMS.md's attribution quote and the
# bare token in both HTML footers, kept to knowledge/law/product.scm's
# `attribution` notice — only the token, never the prose around it in each
# file.
.PHONY: attribution-emit check-attribution-fresh
attribution-emit:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-attribution-notices.scm write
check-attribution-fresh:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-attribution-notices.scm check

# The figures the terms and the privacy notice quote in running prose (the
# version and date, the age floor, log rotation, the breach window, the speech
# model's size, the notice period) are stated once, in the product law's
# notices (product.scm), and written into the pages where each is marked
# `data-fact`. `make notice-facts-emit` rewrites them; the check is in test-fast.
.PHONY: notice-facts-emit check-notice-facts-fresh
notice-facts-emit:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-notice-facts.scm write
check-notice-facts-fresh:
	@LC_ALL=C.UTF-8 guile --no-auto-compile -L module tools/emit/emit-notice-facts.scm check

# Where each file of module/playnet/ is, what reaches it, and which imports point
# up the layers (docs/planning/codebase-layout.md). tools/lint/module-layout.scm is
# the layout as data, naming the tree to come; tools/lint/module-map.scm reads every
# .scm in the tree as forms and lints each file at the rank it will stand at.
# `module-map` writes module/playnet/README.md; `lint-layers` lists the upward
# imports and any file the layout does not name, and exits 1 for any: the tree
# has no upward import, and `make test` runs the lint. The map carries importer counts,
# so `check-module-map-fresh` is for the reader, not the gate. The tool imports
# no playnet module and reads 1,600 files, so it runs compiled, under its own cache.
.PHONY: module-map check-module-map-fresh lint-layers
module-map:
	@LC_ALL=C.UTF-8 tools/test/own-ccache.sh guile tools/lint/module-map.scm --write module/playnet/README.md
check-module-map-fresh:
	@LC_ALL=C.UTF-8 EMIT_CMD="tools/test/own-ccache.sh guile" tools/lint/check-emit-fresh.sh check-module-map-fresh module/playnet/README.md module-map tools/lint/module-map.scm --write
lint-layers:
	@LC_ALL=C.UTF-8 tools/test/own-ccache.sh guile tools/lint/module-map.scm --lint

# Sites that spell actions by hand instead of reading the action table
# (tools/lint/lint-verbs.scm, beyond-valueflows.md §6.2): the count per file only falls.
.PHONY: lint-verbs
lint-verbs:
	@LC_ALL=C.UTF-8 tools/test/own-ccache.sh guile tools/lint/lint-verbs.scm

# Sites that build or test an id grammar's prefix by hand instead of through its owner
# (located.scm, work-ids.scm, plan-bundle.scm, payouts.scm): tools/lint/lint-ids.sh.
.PHONY: lint-ids
lint-ids:
	@bash tools/lint/lint-ids.sh

# Every live module compiled with the unbound-variable and arity warnings: a call that
# cannot run (a name no import supplies, a wrong argument count) is refused before a test
# has to reach it. tools/lint/compile-warnings.sh explains what it counts and what it sets aside.
# One such call the compiler cannot see: `(spawn …)` in a Goblins module that takes
# `spawn` from no import reaches Guile's process spawn (tools/lint/check-goblins-spawn.scm).
# And one write it accepts that Hoot refuses: a `set!` of a binding the module imported
# (tools/lint/check-imported-set.scm), which a context cell (protocol/context.scm) replaces.
.PHONY: lint-compile
lint-compile:
	@$(TEST_ENV) tools/lint/compile-warnings.sh --check
	@$(TEST_ENV) guile --no-auto-compile tools/lint/check-goblins-spawn.scm
	@$(TEST_ENV) guile --no-auto-compile -L module tools/lint/check-imported-set.scm
	@$(TEST_ENV) guile --no-auto-compile tools/lint/check-record-exports.scm

.PHONY: warm-ccache
# every module compiled into the cache the emits and the freshness checks load from, with the
# compiler on (lint-compile compiles into a directory of its own and warms only what it imports)
warm-ccache:
	@$(TEST_ENV) guile -L module tools/lint/warm-ccache.scm

# playnet's own development, planned by the planner: every open Radicle
# issue is a want, its area a skill, its kind a recipe (module/playnet/
# planner/dev/recipes.scm). Prints the week; writes nothing,
# publishes nothing. DEV_PLAN_ARGS carries flags through, e.g.
# `make dev-plan DEV_PLAN_ARGS="--for box"`. See tools/dev/dev-plan.scm.
.PHONY: dev-plan
dev-plan:
	@$(DEV_ENV) guile -q -L module tools/dev/dev-plan.scm $(DEV_PLAN_ARGS)

# The development scope's world (an issue as a want, an area as a skill)
# and its week's plan, on a fixture scope — no `rad` needed.
test-dev-world:
	$(GUILE_TEST_DEV) -L module -L tests tests/dev/test-dev-world.scm

# The development scope's books: a plan row taken as a commitment, an
# issue solved as the work and the deliverable it fulfils.
test-dev-ledger:
	$(GUILE_TEST_DEV) -L module -L tests tests/dev/test-dev-ledger.scm

test-vf-lint:
	$(GUILE_TEST_DEV) -L module -L tests tests/scope/test-vf-lint.scm

test-issue-revoke-credential:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-issue-revoke-credential.scm

# A federation admits a commune through a governor of its gateway.
test-admit-commune-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-admit-commune-door.scm

test-delegation-scope-arg:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-delegation-scope-arg.scm

test-lobby-arg-split:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-lobby-arg-split.scm

# A fragmented WebSocket message arrives whole (UPSTREAM-ISSUES #14): the
# patched (web socket frame) in module/web/socket/frame.scm, over a socket pair.
test-websocket-fragments:
	$(GUILE_TEST_DEV) -L module -L tests tests/gateway/test-websocket-fragments.scm

# A server never masks the frames it sends (RFC 6455 §5.1): the patched (web socket)
# in module/web/socket.scm, which (hoot web-server) wraps its REPL relay with.
test-websocket-masking:
	$(GUILE_TEST_DEV) -L module -L tests tests/gateway/test-websocket-masking.scm

# The picture a photo read was made from rides the observation credential as a
# claim of its own: the golden SAIDs of a record with none, the tag grammar, and
# the bridge's issue (governance/credentials.scm, observation/evidence.scm).
test-observation-evidence:
	$(GUILE_TEST_DEV) -L module tests/scope/test-observation-evidence.scm

# The one constructor of a count's difference: the tolerance under which a
# count agrees, and the raise or lower that lands otherwise
# (planner/observation/adjustment.scm).
test-adjustment:
	$(GUILE_TEST_DEV) -L module tests/observation/test-adjustment.scm

# The Tier-2 adapter seams (module/playnet/delegates.scm): wire shapes
# pinned, fail-closed defaults refuse, injected transports answer.
test-delegates:
	$(GUILE_TEST_DEV) -L module tests/test-delegates.scm

# The parity suites — every Tier-2 module's PARITY marker names one
# (tools/lint/check-parity.sh). The invariant leg always runs; the live
# leg runs when PLAYNET_<SERVICE>_URL names the upstream.
test-parity:
	@for t in tests/parity/*.scm; do \
	  echo "== $$t"; $(GUILE_TEST_DEV) -L module $$t || exit 1; done

# ── e2e: scenario suites + the coverage gate + the live-stack run ─────────
# tests/e2e/*.scm walk whole stories through the door layer (not one act —
# the chain). keeps to in-vat suites so it runs in the dev loop;
# test-e2e-stack is the adopted-stack leg (see tests/e2e/run-stack.sh).
.PHONY: test-e2e-machine test-e2e-scenarios check-e2e-coverage test-e2e-stack

test-e2e-scenarios:
	@for t in tests/e2e/machine-*.scm; do \
	  echo "== $$t"; $(GUILE_TEST_DEV) -L module -L tests $$t || exit 1; done

# The completeness gate: every declared door named in a test, every dispatch
# handler named in a browser test, every delegate wire+parity-covered.
# Ratchet style — baseline holds the known debt, new gaps fail.
check-e2e-coverage:
	@python3 tools/lint/check-e2e-coverage.py

# The machine layer itself: adapters, receipts, the registry.
.PHONY: test-machine
test-machine:
	@for t in tests/machine/*.scm; do \
	  echo "== $$t"; $(GUILE_TEST_DEV) -L module -L tests $$t || exit 1; done

# The adopted stack, end to end: bring services up (or find them running),
# export PLAYNET_*_URL, run the parity suites plus stack-integration.scm.
test-e2e-stack:
	@bash tests/e2e/run-stack.sh

# The planned count's cadence, regime and process grammar (planner/formulas/counting.scm),
# and the schedule, the offers, the accept and the count over the real service
# (docs/observation/capture.md §4).
test-counting:
	$(GUILE_TEST_DEV) -L module tests/vf/test-counting.scm

# The week's unplanned photo reads, and a picture read at the seat: parts,
# bounds, the allotment spent and given back, a planned count drawing on the
# plan (docs/observation/capture.md §5, §9).
test-allotment:
	$(GUILE_TEST_DEV) -L module tests/gateway/test-allotment.scm

test-see-door:
	$(GUILE_TEST_DEV) -L module tests/doors/test-see-door.scm

# A count is contested the way work is, through the one door, and the whole
# family of the count goes with a void: adjustment, record, hours and cascade
# (doors/governance.scm contest-work, planner/formulas/counting.scm).
test-contest-count:
	$(GUILE_TEST_DEV) -L module tests/scope/test-contest-count.scm

# A counter's picture, attached to the contest of their count in parts, checked
# against its hash, held for the ballot's life and let go (gateway/evidence.scm).
test-evidence-door:
	$(GUILE_TEST_DEV) -L module tests/doors/test-evidence-door.scm

# tools/dev/commit-clean.py --gate: what it lands, merges, stops on and refuses, against
# throwaway repositories (tests/tools/test-commit-clean.sh).
.PHONY: test-commit-clean
test-commit-clean:
	bash tests/tools/test-commit-clean.sh

# Guard against the real rot: a test nobody runs. Asserts every
# tests/ux/*-ux.mjs has a reachable `make` target. Cheap (make -n), no browser,
# so it is in `make gate` and `make test-fast` (CI runs `make test`, which is not).
.PHONY: check-test-wiring
check-test-wiring:
	@bash tools/lint/check-test-wiring.sh

# tools/dev/atlas.txt — the regions the local routing engine knows — is well
# formed: unique file-stem names, https extracts, https feeds. A bad row would
# otherwise show only in a `fetch` over Tor.
.PHONY: check-atlas
check-atlas:
	@bash tools/lint/check-atlas.sh

# The sibling rot: a prerequisite nobody listed. Asserts each wasm entry's
# import closure is covered by its *_WASM_DEPS list, so make cannot report a
# stale bundle as up to date. The lists are now generated (wasm-deps-emit), so this
# re-proves them against the walker and notes the hand EXTRA entries. Same cost profile as check-test-wiring — no
# compile, no browser — so it rides in `make gate` and `make test-fast` with it.
.PHONY: wasm-deps-emit check-wasm-deps-fresh
wasm-deps-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/wasm-deps-emit.scm tools/wasm-deps.mk
check-wasm-deps-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-wasm-deps-fresh tools/wasm-deps.mk wasm-deps-emit tools/emit/wasm-deps-emit.scm

.PHONY: check-wasm-deps
check-wasm-deps:
	@bash tools/lint/check-wasm-deps.sh hoot/day-boot.scm "$(DAY_BOOT_WASM_DEPS)"

# ── TypeScript: ui/ → browser/ ──────────────────────────────────────────────
# Sources live OUTSIDE the document root (like hoot/ and rns-wasm/) and emit
# JavaScript INTO it. The emitted .js is COMMITTED, as reflect.js is (the
# wasm bundles are the gitignored exception — a multi-MB binary per rebuild
# is history the Tor-seeded clone can't afford; the box builds its own),
# so every consumer of browser/ — fresh clone, `make serve`, the CI
# rsync, the prod static service reading the checkout, `npm run stage` for the
# APK — sees a complete tree without a build having run. Nothing in the serve
# path learns a new step; check-ui-fresh is what keeps that honest.
#
#   make ui            emit (run after editing a .ts, then commit the .js)
#   make ui-check      types only, no emit — the fast inner check
#   make ui-watch      re-emit on save; livereload-watch.py sees the .js land
#                      and the phone reloads, so the onion loop is unchanged
#   make check-ui-fresh  the committed .js matches a fresh compile
#   make check-ui-staged the same question asked of the COMMIT (pre-commit)
UI_ENV = guix shell --pure -m deploy/manifests/ui-manifest.scm --

.PHONY: ui ui-check ui-watch check-ui-fresh check-ui-staged
ui:
	$(UI_ENV) tsc -p tsconfig.json

ui-check:
	$(UI_ENV) tsc -p tsconfig.json --noEmit

ui-watch:
	$(UI_ENV) tsc -p tsconfig.json --watch --preserveWatchOutput

# The drift a committed build product invites: edit the .ts, forget `make ui`,
# and the tree keeps serving the old code with nothing to say so. Recompiles to
# a scratch dir and diffs, rather than trusting mtimes.
check-ui-fresh:
	@$(UI_ENV) bash tools/lint/check-ui-fresh.sh

# The same check asked of the COMMIT rather than the working tree — what the
# pre-commit hook runs. Concurrent sessions share this checkout, so commits are
# path-limited; a regenerated .js can sit correct on disk and never be staged.
check-ui-staged:
	@$(UI_ENV) bash tools/lint/check-ui-fresh.sh --staged

# ── Browser test aggregates ─────────────────────────────────────────────────
# test-browser: the node page's JS suites — node, no gateway.
.PHONY: test-browser
test-browser: test-machine-executor test-machine-store test-machine-relay test-store test-keys test-bytes \
          test-idb test-keystore test-handler-bridge test-mesh-plan \
          test-capabilities test-rns-identity test-reactive 

# The browser executor — the sandbox, the cap denial, the timeout, and the
# canonical digest the Scheme verifier recomputes (browser/app/machine-executor.js).
.PHONY: test-machine-executor
test-machine-executor:
	node tests/browser/machine-executor-test.mjs

# The store kind's browser leg (browser/app/machine-store.js): the IDB
# shelf, the monotonic byte-seconds meter, the sha256(nonce ∥ content)
# challenge answer, and runStoreClaim's hold→answer→receipt lifecycle —
# fail-closed on no content source, no helia, and no IndexedDB.
.PHONY: test-machine-store
test-machine-store:
	node tests/browser/machine-store-test.mjs

# The relay kind's browser leg (browser/app/machine-relay.js): the HTTP
# leg's fetch-cap gate and in→out byte metering, the canary probe, and the
# DataChannel leg negotiated over the claim's own signal log through a fake
# peer pair — fail-closed on no grant, no RTCPeerConnection, no answer.
.PHONY: test-machine-relay
test-machine-relay:
	node tests/browser/machine-relay-test.mjs

# The IndexedDB keystore + legacy migration (browser/lib/keystore.js). Real
# WebCrypto Ed25519 with in-memory localStorage/IndexedDB mocks. Pins that a
# failed migration never destroys the only copy of a signing key.
test-keystore:
	node tests/browser/keystore-test.mjs

# The spine-handler ⇄ page-bridge seam as a checked claim: every handler the
# wasm registers (hoot/day-boot.scm) must have its wrapper on seam.handlers
# (browser/day-boot.js). The faces treat a missing wrapper as "offline", so an
# unbridged handler is a silent no-op live — this pins the parity.
test-handler-bridge:
	node tests/browser/handler-bridge-test.mjs

# The reactive core (browser/app/reactive.js). Twenty-one modules import it and
# none could see it fail: batching, dependency RE-tracking and identity dedup are
# invisible when they hold and near-impossible to debug when they do not.
.PHONY: test-reactive
test-reactive:
	node tests/browser/reactive-test.mjs

# The mesh's video budget (app/voice/mesh-plan.ts): the streams a person sends
# stay within the budget at every room size, and the ceiling is the one the
# budget gives. Plain node over the emitted module.
.PHONY: test-mesh-plan
test-mesh-plan:
	node tests/browser/mesh-plan-test.mjs

# The gateway names the ICE servers a call may use (its `ice-servers` door); the
# browser carries none. The list, its env spelling, and a source scan.
.PHONY: test-ice-servers
test-ice-servers:
	$(GUILE_TEST_DEV) -L module tests/doors/test-ice-servers.scm

# Unit conversion with and without GNU units on PATH (utils/units.scm): the box
# has none, so the program is looked for once instead of a failed fork per call.
.PHONY: test-units-fallback
test-units-fallback:
	$(GUILE_TEST_DEV) -L module tests/utils/test-units-fallback.scm

# lib/capabilities.js: the probes read the engine (a real V8 with a feature switched on and
# off), and the words and banner stay generic.
.PHONY: test-capabilities
test-capabilities:
	node tests/browser/capabilities-test.mjs

# app/bytes.ts: base64, base64url and hex round-trip every byte; hex refuses
# what is not hex.
.PHONY: test-bytes
test-bytes:
	node tests/browser/bytes-test.mjs

# app/keys.ts: the localStorage key table — its migration from former names,
# its naming convention, and the Scheme bundles and pre-paint script spelling
# the names as the table has them.
.PHONY: test-keys
test-keys:
	node tests/browser/keys-test.mjs

# app/store.ts: a refused localStorage write answers false and raises a fault
# (full store, blocked store); a refused read is the default.
.PHONY: test-store
test-store:
	node tests/browser/store-test.mjs

# app/idb.ts: an operation resolves on transaction COMPLETE, rejects on abort
# and error, and a schema's upgrade hears the version the device held.
.PHONY: test-idb
test-idb:
	node tests/browser/idb-test.mjs

# lib/rns-identity.js: the Reticulum mesh key is held sealed under the origin's
# non-extractable seal key; a key stored before sealing is sealed on first read.
.PHONY: test-rns-identity
test-rns-identity:
	node tests/browser/rns-identity-test.mjs

.PHONY: icons
icons:
	guix shell --pure librsvg font-dejavu fontconfig bash coreutils -- bash tools/emit/make-icons.sh

# Everything hanging off the bran: determinism, domain separation, and the
# rotation-independence the encrypted backup depends on.
test-bran-derivations:
	$(GUILE_TEST_DEV) -L module -L tests tests/keri/test-bran-derivations.scm

# Contact points on ^lobby-session — the path from an address to the
# notification router, and the erasure path back off it.
test-contact-binding:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-contact-binding.scm

# Cards on ^lobby-session — how to reach one person, handed to another:
# signed by the giver, sealed to the receiver, one per pair, erased on withdrawal.
test-cards:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-cards.scm

test-planner-facet:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-planner-facet.scm

test-declared-dispatch:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-declared-dispatch.scm

test-http-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-http-door.scm

test-mcp-door:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-mcp-door.scm

test-device-doors:
	$(GUILE_TEST_DEV) -L module -L tests tests/doors/test-device-doors.scm

# The protocol declaration (module/playnet/doors/protocol.scm) names the same doors
# the code answers, with the same args; its seam names are real day-boot
# handlers; its anonymous planner doors are the facet. tools/lint/protocol-lint.scm.
check-protocol:
	$(GUILE_TEST_DEV) -L module tools/lint/protocol-lint.scm
	$(GUILE_TEST_DEV) -L module tools/lint/check-bridge-arity.scm

# The emits of the declaration. browser/api/openapi.json is committed (the
# box serves it at /api/openapi.json, Swagger UI at /api/docs/); a stale
# copy is a refused push, the same gate the ui/→browser/ emit has.
protocol-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/protocol-emit.scm openapi browser/api/openapi.json
	$(GUILE_TEST_DEV) -L module tools/emit/protocol-emit.scm mcp browser/api/mcp-tools.json
	$(GUILE_TEST_DEV) -L module tools/emit/protocol-emit.scm seam ui/app/seam-wire.ts

# The page's row types, generated from the wire tables (module/playnet/wire/
# rows.scm registry): one interface per table, so the page's types are what
# the server states. ui/app/wire-rows.ts is committed like seam-wire.ts and a
# stale copy is refused the same way.
wire-types-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/wire-types-emit.scm ui/app/wire-rows.ts
check-wire-types-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-wire-types-fresh ui/app/wire-rows.ts wire-types-emit tools/emit/wire-types-emit.scm

# Germany's context pack is generated too (tools/emit/emit-de-context.scm holds its
# places, rules and words for aspects); the snapshot above folds it, so the pack
# is refreshed first when both moved.
de-pack:
	$(GUILE_TEST_DEV) -L module tools/emit/emit-de-context.scm docs/legal/contexts/de.sexp

check-de-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-de-fresh docs/legal/contexts/de.sexp de-pack tools/emit/emit-de-context.scm

# The United States, Mexico and Canada the same way: tools/emit/emit-na-context.scm
# holds each nation's places, rules, protections and words for aspects, and
# writes one pack a nation.
NA_PACKS = us mexico canada
na-packs:
	@for n in $(NA_PACKS); do \
	  $(GUILE_TEST_DEV) -L module tools/emit/emit-na-context.scm $$n docs/legal/contexts/$$n.sexp || exit 1; done

check-na-fresh:
	@ok=1; for n in $(NA_PACKS); do \
	  EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-na-fresh docs/legal/contexts/$$n.sexp na-packs tools/emit/emit-na-context.scm $$n || ok=0; \
	done; [ "$$ok" = 1 ]

# ── food composition: USDA FoodData Central (SR Legacy), sliced ─────────────
# The composition rows a food spec carries are read off the pinned SR Legacy
# release (knowledge/food-sources.scm binds spec → FDC food; the slice lives in
# knowledge/data/fdc-sr-legacy.scm). `make fdc-snapshot` fetches the archive
# (6 MB, public domain), verifies its sha256 and re-slices; the repo carries the
# slice, never the dump. check-fdc-fresh re-slices from a cached archive when
# one is present and says so when none is.
FDC_RELEASE = FoodData_Central_sr_legacy_food_csv_2018-04
FDC_URL = https://fdc.nal.usda.gov/fdc-datasets/$(FDC_RELEASE).zip
FDC_SHA256 = b80817294b8850530aaedf2e515c02593b1824f763a0ff356e5c2081643e6fd0
FDC_CACHE ?= $(HOME)/.cache/playnet/fdc
FDC_SLICE = module/playnet/knowledge/data/fdc-sr-legacy.scm
.PHONY: fdc-snapshot check-fdc-fresh
$(FDC_CACHE)/$(FDC_RELEASE)/food_nutrient.csv:
	@mkdir -p $(FDC_CACHE); cd $(FDC_CACHE) && \
	  { [ -f $(FDC_RELEASE).zip ] || curl -sSL -o $(FDC_RELEASE).zip $(FDC_URL); } && \
	  echo "$(FDC_SHA256)  $(FDC_RELEASE).zip" | sha256sum -c - && \
	  unzip -o -q $(FDC_RELEASE).zip
fdc-snapshot: $(FDC_CACHE)/$(FDC_RELEASE)/food_nutrient.csv
	$(GUILE_TEST_DEV) -L module tools/emit/fdc-snapshot.scm $(FDC_CACHE)/$(FDC_RELEASE) $(FDC_SLICE)
check-fdc-fresh:
	@if [ -f $(FDC_CACHE)/$(FDC_RELEASE)/food_nutrient.csv ]; then \
	  EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-fdc-fresh $(FDC_SLICE) fdc-snapshot tools/emit/fdc-snapshot.scm $(FDC_CACHE)/$(FDC_RELEASE); \
	else echo "check-fdc-fresh: no cached release at $(FDC_CACHE) — run: make fdc-snapshot (fetches 6 MB)"; fi

# the doors declared #:keyed (doors/protocol.scm), as the page reads them: each seam
# handler whose act carries a token minted once per act, with the token's index
keyed-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/keyed-emit.scm ui/app/keyed-doors.ts
check-keyed-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-keyed-fresh ui/app/keyed-doors.ts keyed-emit tools/emit/keyed-emit.scm

# the doors declared #:offline (doors/protocol.scm), as the page reads them: each seam
# handler the device answers with no gateway in reach, read or act, and where an act's instant stands
offline-emit:
	$(GUILE_TEST_DEV) -L module tools/emit/offline-emit.scm ui/app/offline-doors.ts
check-offline-fresh:
	@EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-offline-fresh ui/app/offline-doors.ts offline-emit tools/emit/offline-emit.scm

check-protocol-fresh:
	@ok=1; for pair in openapi:browser/api/openapi.json mcp:browser/api/mcp-tools.json seam:ui/app/seam-wire.ts; do \
	  EMIT_CMD="$(GUILE_TEST_DEV)" tools/lint/check-emit-fresh.sh check-protocol-fresh "$${pair#*:}" protocol-emit tools/emit/protocol-emit.scm "$${pair%%:*}" || ok=0; \
	done; [ "$$ok" = 1 ]

# Individual test conveniences — the full governance suite is run via
# `make test-governance` (defined below, shells into the harness
# script, tools/test/governance-suite.sh, which names each suite by its file;
# including the UC-kind + scope-graph tests added in this iteration).
test-scope-graph:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-scope-graph.scm

# Phase 2: guile-sqlite3 against a REAL corpus .db (permaculture, already
# built) — BLOB vector round-trip + FTS5 MATCH, before phase 4 wires a door.
.PHONY: test-corpus-sqlite-spike
test-corpus-sqlite-spike:
	$(GUILE_TEST_DEV) -L module -L tests tests/ai/test-corpus-sqlite-spike.scm

test-universal-commune-kind:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-universal-commune-kind.scm

test-gplay:
	$(GUILE_TEST_DEV) -L module tests/org/test-gplay.scm

# docs/playnet.pdf + docs/playnet.epub — the scroll's "the latest spec"
# download links. Both are gitignored build products; CI runs the same
# script via build_docs_epub() in radicle-ci-hook.sh before every sync.
# Content-stamped, so a re-run with an unchanged .typ is a fast no-op.
.PHONY: docs-epub
docs-epub:
	deploy/scripts/build-docs-epub.sh "$(CURDIR)"












# The federated solve across a vat boundary (Rung 3 of FEDERATED-SOLVE.md):
# the boundary oracle + signed ^commune-solver actors, in-process and across
# two processes over a websocket sturdyref.
test-federation-wire: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-wire.scm

test-federation-wire-procs: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-wire-procs.scm

# The same solve with no coordinator and no rounds (federation/async.scm): peers
# that message each other along the links, a simulated network that reorders,
# loses and repeats, and a federation settled when it falls silent; then the
# peers as signed actors in their own vats (federation/peer.scm).
test-federation-async: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-async.scm

test-federation-peer: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-peer.scm

test-federation-peer-procs: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-peer-procs.scm

# One column for a good that crosses either way (solver.scm `offset-column`,
# `give-bound`, `detach-column`), and the direction a good crosses decided by
# the solve: the stock moved, the twin economy, goods nobody can supply.
test-crossing-column: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/solve/test-crossing-column.scm

test-federation-direction: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-direction.scm

# A person's day is offered once in the solve as in the roster: overlapping
# ranges are one stretch.
test-window-union: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/solve/test-window-union.scm

# A body has one week: the pool counts a person once, deployment spends one budget
# across their skills, and a day offered twice is offered once.
test-labour-budget: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-labour-budget.scm

# The algebra the folds are summed under: join, sum, and which are idempotent.
test-fold-laws: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/pools/test-fold-laws.scm

# A settled crossing leaves a record: two legs per participant through the pool,
# written by the party that receives each.
test-crossing-custody: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-crossing-custody.scm

# A scope's key rotates and the wire follows: its words carry its key log, and a
# verifier reads the key in force off it.
test-federation-rotation: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-rotation.scm

# The federation's spec, off its own store (federation/sturdyref-credential.scm).
test-federation-spec: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-spec.scm

# The federation's desk: what a federation answers for itself, and how far a
# commune takes its word (federation/federate.scm `desk-word->spec`).
test-federation-desk: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-desk.scm

# The same two-process solve with commune B on another machine (FED_REMOTE an
# ssh target holding module/ and tests/federation/ at FED_REMOTE_ROOT, with the
# KERI backend's libraries at FED_REMOTE_LIBS), both ends on the Goblins the
# channel pin ships: here under time-machine, there its own profile.
FED_REMOTE ?= playnet-server
FED_REMOTE_ROOT ?= /tmp/fed
FED_REMOTE_LIBS ?=
test-federation-peer-remote:
	guix time-machine -C $(CHANNELS) -- shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
	  bash tools/test/own-ccache.sh env LC_ALL=C.UTF-8 \
	  PLAYNET_FED_REMOTE=$(FED_REMOTE) PLAYNET_FED_REMOTE_ROOT=$(FED_REMOTE_ROOT) PLAYNET_FED_REMOTE_LIBS=$(FED_REMOTE_LIBS) \
	  guile -L module tests/federation/test-federation-peer-procs.scm

# A good several scopes supply and several draw: one pull, settled between its
# participants (crossing-step, ρ per good), held to the monolith's optimum.
test-federation-crossing: $(KERNEL_SO)
	$(GUILE_TEST_DEV) -L module tests/federation/test-federation-crossing.scm

test-governed:
	$(GUILE_TEST_DEV) -L module tests/org/test-governed-org.scm

test-signatures:
	$(GUILE_TEST_DEV) -L module tests/org/test-history-signatures.scm

test-endorsement:
	$(GUILE_TEST_DEV) -L module tests/org/test-endorsement.scm

test-output-cap:
	$(GUILE_TEST_DEV) -L module tests/org/test-output-cap.scm

test-output-port:
	$(GUILE_TEST_DEV) -L module tests/org/test-output-port.scm

test-notify-registry:
	$(GUILE_TEST_DEV) -L module tests/notify/test-notify-registry.scm

test-notify-adapters:
	$(GUILE_TEST_DEV) -L module tests/notify/test-notify-adapters.scm

test-recipient-registry:
	$(GUILE_TEST_DEV) -L module tests/notify/test-recipient-registry.scm

test-notify-router:
	$(GUILE_TEST_DEV) -L module tests/notify/test-notify-router.scm

test-persistence:
	$(GUILE_TEST_DEV) -L module tests/org/test-persistence.scm

test-planner: $(KERNEL_SO)
	$(TEST_ENV) \
	  sh tools/test/planner-suite.sh

# Arc-time table: Valhalla priors ⊕ observed EWMA → the engine's *arc-hours*.
# Pure folds, strict-parity lock, synthetic-table injection, and a guarded
# live matrix check that skips cleanly when no engine answers on :8002.
test-arc-times:
	@for t in ewma-fold arc-time-parity arc-time-injection arc-time-recipe arc-time-matrix valhalla-live; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/test-$$t.scm || exit 1; \
	done

# The federation fold and its dual, the descent: one aggregator up, one router
# down, and the section law that ties them (re-folding a split's parts
# reconstructs the value).
# The voice field: the one selector (parts.scm) and the field on a solve
# (solve/voice-field.scm + the engine hook); docs/planning/voice/.
test-voice-field:
	@for t in parts voice-field-solve; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -q -L module tests/*/test-$$t.scm || exit 1; \
	done

test-fold-nodes:
	@for t in fold-node unfold-node; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -q -L module tests/*/test-$$t.scm || exit 1; \
	done

# The discrete layer: minimum batches and whole counts on §7's certified tree,
# reached through the records (recipes, plan-from-records, robust, movers), plus
# the engine-level fixtures it rests on.
test-discrete:
	@for t in whole-counts time-verification discrete-records doctor-rider-located; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    env PLANNER_INVARIANTS=1 guile --no-auto-compile -q -L module tests/*/test-$$t.scm || exit 1; \
	done

# Provenance loop: re-run the generator on the vendored raw and confirm the
# checked-in worlds/doon-derived.scm is byte-identical — so the planner's MECHANICAL numbers
# (scenario probabilities, Ky multipliers, yields) cannot drift from their source.
# Host python3, no guix shell needed.
# each bioregion: "LABEL|COUNTRY|CROPS" — re-generate + diff its checked-in derived file.
VERIFY_DERIVED = "doon|India|rice,maize,ragi,pulses" "cascadia|United States|wheat,potato,bean,pea" "berlin|Germany|wheat,barley,potato,maize" "bay-area|United States|tomato,potato,bean,pea"
verify-derived:
	@cd module/playnet/knowledge/data && for spec in $(VERIFY_DERIVED); do \
	  label=$${spec%%|*}; rest=$${spec#*|}; country=$${rest%%|*}; crops=$${rest#*|}; \
	  guile emit-derived.scm "$$label" "$$country" "$$crops" > /tmp/$$label-derived.check && \
	  if diff -q ../worlds/$$label-derived.scm /tmp/$$label-derived.check >/dev/null; then \
	    echo "✓ $$label-derived.scm matches the vendored raw"; \
	  else \
	    echo "✗ $$label-derived.scm DRIFTED from raw — regenerate:"; \
	    echo "    guile emit-derived.scm $$label \"$$country\" $$crops > ../worlds/$$label-derived.scm"; \
	    diff ../worlds/$$label-derived.scm /tmp/$$label-derived.check; exit 1; \
	  fi; \
	done

# Ecological possibility-tensions: the fragility (frag) barrier end-to-end —
# per-good cap, per-spec rate, cumulative budget, Leontief cascade, observed
# prior, container roll-up, far-start recovery, Scheme≡C parity, and the REAL
# planetary-boundary + climate-tipping-point catalogue (eco-catalogue.scm)
# custodied by the tension-registry, driven through a solve. Gated on the
# provenance loop so a raw/derived drift fails before the solves even run.
test-tensions: verify-derived
	@for t in tension-parity \
	          frag-cap frag-spec frag-budget frag-cascade frag-budget-cascade \
	          frag-prior frag-observe frag-container frag-container2 \
	          frag-certificate frag-integration frag-farstart \
	          frag-witness frag-catalogue frag-registry-solve \
	          reproduction-diet reproduction-live subsistence-catalogue \
	          subsistence-consumption substance-expansion \
	          robust-multiscenario robust-records doon-valley-robust navdanya-farm taleb-tail antifragile-reserve endogenous-reserve deep-time-reserve \
	          regenerating-stock soil-recurrence forest-recurrence restoration-recipe limit-roster limit-migration scale-invariance representation-parity conservation store-recipe relaxation element-closure leaf-bounds climb backend-verdict-parity monitoring-cadence scenario-tree period-aware-shocks \
	          bioregion-containment doon-shed scenario-shocks bioregion-boundary-wire cascadia; do \
	  echo "=== $$t ==="; \
	  out=$$(PLANNER_RAW_LINT=1 PLANNER_INVARIANTS=1 $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/test-$$t.scm 2>&1) \
	    || { echo "$$out"; exit 1; }; \
	  echo "$$out"; \
	  if echo "$$out" | grep -q 'RAW-LINT.*starved'; then \
	    echo "  *** $$t FAILED (RAW-LINT: a draw with no producer, stock, or barrier) ***"; exit 1; \
	  fi; \
	done

# Communications: the whole comms slice — the deterministic core (Stage 0-2 +
# entailment fence), production recipes, the live AI restyle, the publishing
# adapters (5 platforms on one sealed-bearer substrate), the one-solve derivation
# (fragility/scheduling/duals/mandate), and the platform fragility wiring. One
# load context, -L module: every test states its imports as modules now.
.PHONY: test-comms
test-comms:
	@for t in test-comms test-comms-recipes test-comms-ai test-comms-run test-demand-vf-action; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/$$t.scm || exit 1; \
	done
	@for t in test-bearer-endpoint test-platforms test-instagram test-comms-publish; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/$$t.scm || exit 1; \
	done
	@for t in comms-fragility comms-metabolism comms-mandate; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module tests/*/test-$$t.scm || exit 1; \
	done

test-governance: lint-discipline
	$(TEST_ENV) \
	  sh tools/test/governance-suite.sh

# Voice/CCF orthogonality + recomputability (Phase 5 of HARDENING.md).
# Catches discipline violations at build time, before they slip past
# review and into the system. Exit 1 on violations.
lint-discipline:
	$(TEST_ENV) \
	  guile --no-auto-compile tools/lint/lint-discipline.scm


test-netlayer:
	$(GUILE_TEST_DEV) -L module tests/gateway/test-netlayer-substitute.scm

# ── the deployed tier ────────────────────────────────────────────────────
# The static shell on Cloudflare Pages. deploy-pages ships browser/ as-is —
# run 'make' first for a FUNCTIONAL deploy (day-boot.wasm is a hoot-toolchain
# artifact; without it the node page honestly reports its wasm-error).
.PHONY: deploy-pages 
deploy-pages:
	CLOUDFLARE_ACCOUNT_ID=$${CLOUDFLARE_ACCOUNT_ID:?set in env} \
	wrangler pages deploy browser/ --project-name=$${PAGES_PROJECT:-chimera-playnet}

# ── KERI mock-based unit tests ───────────────────────────────────────────────
# Fast unit tests against an in-process mock KERIA HTTP server. Cover the
# Scheme-side wire format, dispatch, and verification logic. Do NOT exercise
# real Signify auth, KEL receipts, or witness pools — that's test-keri-
# integration's job.
test-keri-blake3:
	$(GUILE_TEST_DEV) -L module tests/keri/test-blake3.scm

test-keri-signify:
	$(GUILE_TEST_DEV) -L module tests/keri/test-signify.scm

test-keri-signify-portable:
	$(GUILE_TEST_DEV) -L module tests/keri/test-signify-portable.scm

test-keri-signup-with-icp:
	$(GUILE_TEST_DEV) -L module tests/identity/test-signup-with-icp.scm

# an identity brings its own KEL to a commune that never saw it
test-keri-signup-with-kel:
	$(GUILE_TEST_DEV) -L module tests/identity/test-signup-with-kel.scm

# a key proven is not a seat held: witnessed-only AIDs are refused a session
test-keri-lobby-seat-gate:
	$(GUILE_TEST_DEV) -L module tests/doors/test-lobby-seat-gate.scm

# PLAYNET_DISABLE_REAL_SIGNUP refuses signup/signup-with-icp/signup-with-kel/
# join, leaves witness-kel/has-seat alone — see docs/legal/gdpr-analysis.md
test-keri-signup-disabled-gate:
	$(GUILE_TEST_DEV) -L module tests/knowledge/test-signup-disabled-gate.scm

# forget-me erases every store of the gateway's own keyed by an AID, the
# AID→person link last, and leaves the key log — identity/forget.scm; a
# rotation naming no next key retires the identity for good
test-keri-forget:
	$(GUILE_TEST_DEV) -L module tests/gateway/test-forget.scm

# the key log in hand, as the browser keeps it — pure, so Guile pins it
test-identity-kel:
	$(GUILE_TEST_DEV) -L module tests/identity/test-kel-in-hand.scm

# a body's AID is the k-of-n group of its stewards' dial AIDs: the ceremony,
# the threshold reader, the rotation under the pre-rotation constraint
test-identity-body-ceremony:
	$(GUILE_TEST_DEV) -L module tests/personhood/test-body-ceremony.scm

# the body-role credential: a projection the stewards sign k of n
test-governance-body-role-credential:
	$(GUILE_TEST_DEV) -L module tests/keri/test-body-role-credential.scm

# losing your passcode is survivable when you gave pieces of it to people you
# trust — and k-1 of them learn nothing
test-recovery-share:
	$(GUILE_TEST_DEV) -L module tests/keri/test-recovery-share.scm

# AID ↔ mesh binding: advertised reticulum destination must derive from
# the icp-anchored pubkey. Authoritative ring loads the rns-wasm pkg
# under node when available.
test-keri-reticulum-binding:
	$(GUILE_TEST_DEV) -L module tests/keri/test-reticulum-binding.scm

# Mesh mailbox: ciphertext custody for offline-persona deliveries.
test-mesh-mailbox:
	$(GUILE_TEST_DEV) -L module -L tests tests/gateway/test-mesh-mailbox.scm

# LIVE mesh smoke: two rns-bridges over a local TCP hop — announce
# propagation, routed mail packet, DELIVERY on the SUBSCRIBE stream.
# Needs the cargo debug binary + node + rns-wasm pkg; skips otherwise.
test-mesh-smoke:
	timeout 120 $(GUILE_TEST_DEV) -L module -L tests tests/keri/integration/test-mesh-smoke.scm

# OKEA endpoint replies in OOBI bodies. Needs the KERI manifest (not the
# dev one): the authoritative third ring parses our served body with
# keripy itself and asserts the endpoint registers in db.locs.
test-keri-oobi-replies:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  $(OWN_CCACHE) guile --no-auto-compile -L module -L . -L tests \
	  tests/identity/test-oobi-endpoint-replies.scm

test-did-keri:
	$(GUILE_TEST_DEV) -L module tests/keri/test-did-keri.scm

test-keri-signify-integration:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-signify-integration.scm

test-keri-bridge:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-bridge.scm

test-keri-bridge-extra:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-bridge-extra.scm

test-keri-credentials:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-credentials.scm

test-keri-credentials-ipex:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-credentials-ipex.scm

test-keri-witnesses:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-witnesses.scm

test-keri-notifications:
	$(GUILE_TEST_DEV) -L module tests/keys/test-keri-notifications.scm

test-ipex-policy:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-ipex-policy.scm

test-ipex-grant-handler:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-ipex-grant-handler.scm

test-ipex-pull-flow:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-ipex-pull-flow.scm

test-scope-portability:
	$(GUILE_TEST_DEV) -L module -L tests tests/utils/test-scope-portability.scm

test-scope-exchange:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-scope-exchange.scm

test-keria-store-pending:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-keria-store-pending.scm

test-pending-grants:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-pending-grants.scm

test-pending-grants-fiber-inheritance:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-pending-grants-fiber-inheritance.scm

test-observability-endpoints:
	$(GUILE_TEST_DEV) -L module -L tests -L . tests/server/test-observability-endpoints.scm

test-playnet-scope:
	$(GUILE_TEST_DEV) -L module -L tests tests/tools/test-playnet-scope.scm

test-dev-priorities:
	$(GUILE_TEST_DEV) -L module -L tests tests/tools/test-dev-priorities.scm

test-ratification-delivery:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-ratification-delivery.scm

test-util-common:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-common.scm

test-util-keyed-id:
	$(GUILE_TEST_DEV) -L module -L tests tests/utils/test-keyed-id.scm

test-custodian-heartbeat:
	$(GUILE_TEST_DEV) -L module -L tests tests/keys/test-custodian-heartbeat.scm

test-pending-recompositions:
	$(GUILE_TEST_DEV) -L module -L tests tests/federation/test-pending-recompositions.scm

test-kel-anchoring:
	$(GUILE_TEST_DEV) -L module -L tests tests/scope/test-kel-anchoring.scm

# Deploy-time interop smoke test (curl-driven, no Node deps).
# Usage: make smoke-test GATEWAY=http://localhost:8080
smoke-test:
	@./tests/interop/smoke-test.sh $(GATEWAY)

test-keri-recovery:
	$(GUILE_TEST_DEV) -L module tests/keri/test-keri-recovery.scm

test-keri-lobby-auth:
	$(GUILE_TEST_DEV) -L module tests/doors/test-keri-lobby-auth.scm

# ── ACDC role schemas ───────────────────────────────────────────────────────
# The four playnet role-credential schemas live self-saidified in
# module/playnet/keri/schemas/. Each file's `$id` holds its own blake3-256
# SAID. `make schemas` recomputes + writes; `make test-schemas` asserts
# idempotency (CI guard against accidental edits without re-saidification).

schemas:
	$(GUILE_TEST_DEV) -L module tools/emit/saidify-schemas.scm

test-schemas:
	$(GUILE_TEST_DEV) -L module tools/emit/saidify-schemas.scm --check
	$(GUILE_TEST_DEV) -L module tests/keri/test-schemas.scm

test-keri: test-keri-blake3 test-keri-signify test-keri-signify-portable test-keri-oobi-replies test-keri-signify-integration test-keri-signup-with-icp test-keri-signup-with-kel test-keri-lobby-seat-gate test-keri-signup-disabled-gate test-keri-forget test-identity-kel test-identity-body-ceremony test-governance-body-role-credential test-recovery-share test-keri-reticulum-binding test-mesh-mailbox test-did-keri test-keri-bridge test-keri-bridge-extra test-keri-credentials test-keri-credentials-ipex test-ipex-policy test-ipex-grant-handler test-keri-witnesses test-keri-notifications test-keri-recovery test-keri-lobby-auth test-schemas

test-all: test-gplay test-governed test-signatures test-endorsement test-output-cap test-output-port test-persistence test-planner test-governance test-netlayer test-keri

# ── test-all-pinned ──────────────────────────────────────────────────────────
# Reproducibility canary. Same suite as test-all, but every guile invocation
# goes through `guix time-machine -C deploy/channels.scm` so the toolchain is
# bit-for-bit identical to production. Currently HANGS because of the
# Radicle/libgit2 issue described above the runner block. Keep it named: the
# day Radicle's git HTTP bridge gets along with libgit2, this lights up and
# CI can use it again. Don't delete because "nobody runs it" — that's the
# point, it's the canary, not the daily target.
test-all-pinned:
	$(GUILE_TEST) -L module tests/org/test-gplay.scm
	$(GUILE_TEST) -L module tests/org/test-governed-org.scm
	$(GUILE_TEST) -L module tests/org/test-history-signatures.scm
	$(GUILE_TEST) -L module tests/org/test-endorsement.scm
	$(GUILE_TEST) -L module tests/org/test-persistence.scm
	$(GUILE_TEST) -L module tests/gateway/test-netlayer-substitute.scm
	$(TIME_MACHINE) shell guile-next guile-goblins -- sh tools/test/planner-suite.sh
	$(GUILE_TEST) -L module tests/keri/test-keri-bridge.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-bridge-extra.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-credentials.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-credentials-ipex.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-witnesses.scm
	$(GUILE_TEST) -L module tests/keys/test-keri-notifications.scm
	$(GUILE_TEST) -L module tests/keri/test-keri-recovery.scm
	$(GUILE_TEST) -L module tests/doors/test-keri-lobby-auth.scm

# ── Real-KERIA integration tests ─────────────────────────────────────────────
# Spins up a real `keria start` + `kli witness demo` (6 witnesses) in $TMPDIR
# and runs tests/keri/integration/test-real-keria.scm against them.
# Each test asserts on real KERI state (KEL receipts, signed OOBIs) — not on
# mock counters. See tests/keri/integration/run-integration.sh for the trap
# EXIT teardown.
#
# Deliberately NOT in test-all: building python-keria pulls ~30 Python deps
# via Guix and startup+teardown takes 15-40s. Keeps `make test-all` fast for
# the inner dev loop. Run this manually when touching the KERI bridge, the
# KERIA service definition, or upgrading python-keri / python-keria.
#
# Uses deploy/manifests/keri-test-manifest.scm (plain guix shell, no
# time-machine) because deploy/channels.scm pins the Radicle seed, which
# is currently unreachable. See the header of that manifest for details.
test-keri-integration:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  sh tests/keri/integration/run-integration.sh

# Two-gateway subprocess smoke test. Spawns two real `guile -s
# server/gateway.scm` processes on disjoint ports + state dirs,
# waits for each to write gateway-sref.txt, then runs an OCapN driver
# in a THIRD process that enlivens both sturdyrefs and asserts they
# behave as remote-refr?. Guards against deploy-shape regressions
# (missing -L paths, env-var assumptions, register-race-conditions)
# that in-vat tests miss. Synthetic backend — no KERIA needed.
test-multi-gateway:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  bash tests/integration/run-multi-gateway-smoke.sh

# Two gateways federated on the wire: each boots as one member of the flour
# federation (PLAYNET_SEED_FED) with a scope key of its own, publishes its
# berth; a third process admits both into a signed federation scope, serves
# the federation's desk and fold, and hands each gateway the federation's AID
# and desk; the gateways boot again on the same state, ask, join and settle;
# one restarts once federated. federation/federate.scm, end to end.
# FED_KEYS=dev: scopes without a key, signing under dev identities.
test-federation-gateways:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  bash tests/integration/run-federation-gateways.sh

# Cross-gateway IPEX: full grant→admit pipeline with two mock-KERIA
# servers, scope-signed credentials, policy dispatch, pending-grants
# drain. Single-process (no subprocesses needed).
test-ipex-cross-gateway:
	guix shell -L deploy/guix -m deploy/manifests/keri-test-manifest.scm -- \
	  guile --no-auto-compile -L module -L . \
	    tests/integration/test-ipex-cross-gateway.scm

# ── Live-hacking dev bundles ─────────────────────────────────────────────────
# Dev bundles embed Hoot's runtime module system and mutable definitions
# (-fruntime-modules -fmutable-defs; -g2 adds names) so UI procedures can be
# redefined at runtime via (hoot web-repl) + Geiser. Hoot 0.9 and Hoot main
# both stop such a bundle at start-up today (UPSTREAM-ISSUES #17, #18); the
# state is in docs/dev/LIVE_HACKING.md.
#
# ── Wisp editor tooling ─────────────────────────────────────────────────────
# Syntax highlighting / indentation for .w (Wisp) files. Two targets, two
# editor camps — see tooling/README.md.
#
#   make wisp-ext         install the prebuilt VSCode/Antigravity extension
#                         from the committed vsix (offline, no npm needed).
#   make wisp-ext-build   rebuild that vsix from source (needs node + npx).
#   make wisp-ts          (re)generate + test the tree-sitter grammar.
#
# Emacs needs no target: `guile-wisp` is in manifest.scm, so wisp-mode is
# autoloaded inside the dev-shell Emacs. For a permanent setup use the Guix
# home service in tooling/emacs-wisp/wisp-home.scm.
WISP_VSIX = tooling/wisp-vscode/wisp-0.1.0.vsix
WISP_EDITOR ?= $(firstword $(foreach c,antigravity codium code,$(if $(shell command -v $(c) 2>/dev/null),$(c))))

# the public origin the extension's relative links resolve against: the
# upstream's unless you publish your own
PLAYNET_ORIGIN ?= https://playnet.earth
.PHONY: wisp-ext wisp-ext-build wisp-ts
wisp-ext:
	@test -n "$(WISP_EDITOR)" || { echo "No editor CLI (antigravity/codium/code) on PATH; set WISP_EDITOR=<cli>"; exit 1; }
	$(WISP_EDITOR) --install-extension $(WISP_VSIX) --force
	@echo "Installed. Reload the editor window (Developer: Reload Window)."

wisp-ext-build:
	cd tooling/wisp-vscode && npx --yes @vscode/vsce package --no-dependencies \
	  --allow-missing-repository --baseContentUrl $(PLAYNET_ORIGIN) \
	  --baseImagesUrl $(PLAYNET_ORIGIN) -o wisp-0.1.0.vsix

wisp-ts:
	cd tooling/tree-sitter-wisp && ./build.sh test

clean:
	rm -f browser/day-boot.wasm

# The two-box witness harness: two processes, two state dirs, two static
# tiers, HTTP-only between them — live cross-gateway witness delivery.
.PHONY: test-witness-two-box
test-witness-two-box:
	bash tests/personhood/two-box/run-two-box.sh

# The live first-citizen journey, against a RUNNING `make dev` gateway:
# browser signup → dial Berlin → offer hours → declare a need → the solve's
# schedule lands in the calendar's wire-only source. A probe, not a suite —
# it writes durable state into .dev-data on every run.
# The truth-telling arc: emphasis, externality, the audit, federated repro,
# eisenberg-gale, the demand fold, owned delivery. Kernel suites need
# libplanner_kernel (make -C module/playnet/solve/kernel).
.PHONY: test-truth-telling
test-truth-telling: $(KERNEL_SO)
	@for t in emphasis externality audit federated-repro eisenberg-gale; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module -L tests tests/*/test-$$t.scm || exit 1; \
	done
	@for t in tests/economy/test-demand-fold.scm tests/economy/test-owned-delivery.scm; do \
	  echo "=== $$t ==="; \
	  $(TEST_ENV) \
	    guile --no-auto-compile -L module -L tests $$t || exit 1; \
	done
