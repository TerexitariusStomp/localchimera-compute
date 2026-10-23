#!/usr/bin/env bash
# promote.sh — promote a signed commit to canonical main on the box.
#
#   bash deploy/scripts/promote.sh <commit-ish> [agent-name]
#
# Encodes the whole dance that was previously done by hand (and the
# traps hit while doing so — see reference_ci_deploy_pipeline memory):
#
#   1. FRESH fetch of canonical main (other agents move it between
#      your fetches; never promote against a stale tip).
#   2. Fast-forward check: the commit must contain the fresh tip. If
#      not, STOP — re-parent or merge first; this script does not
#      guess on your behalf.
#   3. Push to a per-agent transfer ref (incoming-<agent>, NEVER the
#      shared incoming-main — two agents collided on it 2026-06-06);
#      the box's pre-receive hook authenticates the signed chain.
#   4. On-box: ff main, drop the transfer ref ONLY after the
#      ff succeeded, rad push.
#
# Tor-only: every remote touch is Tor-routed. By default we wrap ssh/git/scp in
# `torsocks` (for a PLAYNET_BOX like root@<ip-or-onion> with no ProxyCommand).
# BUT if PLAYNET_BOX is an ssh *alias* that already tunnels through Tor via a
# ProxyCommand (e.g. `nc -X 5 -x 127.0.0.1:9050 %h %p`), torsocks would
# DOUBLE-tor it — torsocks intercepts the local :9050 connect and rejects it.
# In that case set PROMOTE_TORSOCKS= (empty) to let the ssh config do the Tor
# routing:   PROMOTE_TORSOCKS= PLAYNET_BOX=playnet-server bash promote.sh <sha>
set -euo pipefail

COMMIT="${1:?usage: promote.sh <commit-ish> [agent-name]}"
AGENT="${2:-claude}"
BOX="${PLAYNET_BOX:?set PLAYNET_BOX=root@<host-or-onion> (not hardcoded — opsec)}"
# Unset → "torsocks"; set (even to empty) → used verbatim.
TS="${PROMOTE_TORSOCKS-torsocks}"
CO=/var/lib/playnet/radicle/checkout
REF="incoming-$AGENT"

SHA=$(git rev-parse --verify "$COMMIT^{commit}")

# PROMOTE_REWRITE=1 — the history under canonical was rewritten (docs/history/
# identity-scrub-*.tsv): $SHA does not descend from the old tip, and every step
# that fast-forwards becomes a forced move. The box's recorded guix introduction
# (git config guix.authentication.introduction-commit in $CO) must already name
# the rewritten one, or the box's pre-push guard blocks the push.
REWRITE="${PROMOTE_REWRITE:-}"
FORCE=""; [ -n "$REWRITE" ] && FORCE="+"

echo "[promote] verifying signature on $SHA"
sig=$(git log --format='%G?' -1 "$SHA")
[ "$sig" = "G" ] || { echo "[promote] ERROR: commit not GPG-signed (got '$sig')"; exit 1; }

echo "[promote] fetching fresh canonical main"
$TS git fetch "ssh://$BOX$CO" main:refs/heads/canonical-main -f

tip=$(git rev-parse canonical-main)
if [ -z "$REWRITE" ] && ! git merge-base --is-ancestor "$tip" "$SHA"; then
    echo "[promote] ERROR: canonical moved ($(git log --oneline -1 canonical-main))"
    echo "          $SHA does not contain it — re-parent/merge onto the fresh tip first."
    exit 1
fi

# The wasm artifact (browser/day-boot.wasm) is a
# gitignored build product: the box builds them on deploy
# (radicle-ci-hook.sh build_browser_wasm, triggered by browser/ and hoot/
# changes) and the rsync P-filters keep the last-built copies in
# DEPLOY_DIR. A promotion carries only sources — the served wasm always
# corresponds to the shipped .scm because the same push that lands it
# triggers the on-box rebuild.

echo "[promote] pushing $SHA → $REF (hook authenticates)"
$TS git push "ssh://$BOX$CO" "+$SHA:refs/heads/$REF"

# --- Canonical propagation across the gossip partition ----------------------
# The box advances TWO things: the live-site checkout (ff below) and the
# Radicle *canonical* (refs/heads/main — what the Explorer at /radicle serves).
# Canonical is computed from a quorum of delegate-signed refs. The box's seed
# node and the home node sit in DIFFERENT gossip clusters that don't relay
# (see reference_ci_deploy_pipeline), so the delegate ref that advances
# canonical — ops's signed main — never reaches the box on its own and
# the Explorer freezes weeks behind the live site (root-caused 2026-06-28).
#
# Fix: carry ops's signed namespace to the box ourselves over the SSH
# we already use — plain signed git, no networked pseudonym node (opsec-safe).
# With threshold=1 and ops a recognized delegate, its main@$SHA alone lets the
# box hold canonical = $SHA. The box already has the $SHA *objects* (it ff'd
# above), so we ship only ops's tiny identity/sigref refs (~80 KB) and set its
# main + the canonical head to $SHA on the far side. Requires the home ops
# push (`git push rad main` as ops) to have advanced home canonical to
# $SHA first; if not, we warn and skip — the live site still deploys.
# Same env-override-with-today's-default pattern as cdn.scm, merge-patch.sh,
# canonicalize-keyring-ref.sh, playnet-sync.sh — every other deploy/ script
# naming the RID. This one was the odd one out, hardcoded with no override at
# all, which makes it the single file a RID transition would silently miss.
RID_DIR="${PLAYNET_RID_BARE:-z27dFkN28LQAsSsG3DVHcfBqYAArQ}"
OPS="${PLAYNET_OPS_DID:-z6MkhFnFe4dPHjHfZb4YAoYGf48AiaLAZHDj53yZBzfCJKVf}"
STORE=/var/lib/playnet/radicle/.radicle/storage/$RID_DIR
HS="${RAD_HOME:-$HOME/.radicle}/storage/$RID_DIR"
NS="refs/namespaces/$OPS"
BUNDLE=""
home_ops=$(git -C "$HS" rev-parse --verify "$NS/refs/heads/main" 2>/dev/null || echo "")
if [ "$home_ops" != "$SHA" ]; then
    # Sign $SHA as ops so the delegate ref advances — the board's
    # canonical is a QUORUM of delegate-signed mains, so without ops's
    # ref moving too, the Explorer freezes behind (root-caused 2026-07-03).
    # Push $SHA itself, not whatever local `main` happens to be. merge-patch
    # re-parents each change onto the box's tip, so local main is a different
    # commit (often carrying other sessions' unmerged work), and the old gate
    # "local main must equal $SHA" meant this never signed: ops's signed main
    # sat six merges behind canonical. $SHA contains the box's canonical tip
    # (checked above), so this fast-forwards ops's signed main; git refuses a
    # diverged one, and the note below reports it.
    echo "[promote] signing $SHA as ops (git push rad $SHA:refs/heads/main)"
    # Auth for the ops key comes from RAD_OMAR_PASSPHRASE (fed by
    # `make ship` from the age-encrypted secrets) — NOT the ambient
    # RAD_PASSPHRASE, which is the *box seed* key's passphrase and, if it
    # leaks into this env, overrides the unlocked radicle agent with the
    # wrong key → "invalid passphrase" (the silent-canonical-lag bug,
    # root-caused 2026-07-21). With RAD_OMAR_PASSPHRASE unset we fall back
    # to the agent (`rad auth`), never to the box passphrase.
    if [ -n "${RAD_OMAR_PASSPHRASE:-}" ]; then
        RAD_PASSPHRASE="$RAD_OMAR_PASSPHRASE" git push rad "${FORCE}$SHA:refs/heads/main" 2>&1 | tail -3 || true
    else
        env -u RAD_PASSPHRASE git push rad "${FORCE}$SHA:refs/heads/main" 2>&1 | tail -3 || true
    fi
    home_ops=$(git -C "$HS" rev-parse --verify "$NS/refs/heads/main" 2>/dev/null || echo "")
fi
# Whether canonical advanced is decided at the END, from what the box reports,
# never from this early check. The box's own `git push rad main` (on-box step
# below) also moves canonical, so a missing ops signature is not by
# itself a failure. It was reported as one for weeks, and every merge printed
# "canonical did NOT advance" while canonical had in fact advanced. The lag it
# was written to catch (root-caused 2026-07-21: the Explorer freezing behind the
# live site) is still caught, by comparing the box's canonical head to $SHA.
OPS_SIGNED=1
if [ "$home_ops" != "$SHA" ]; then
    OPS_SIGNED=0
    echo "[promote] NOTE: ops's signed main is not at $SHA, so its delegate ref is"
    echo "          not carried to the box. The box's own push can still advance canonical;"
    echo "          the result is read back from the box below."
    echo "          To sign it too: unlock the key with 'rad auth', or set RAD_OMAR_PASSPHRASE"
    echo "          in the age secrets (deploy/secrets.scm.age) so 'make ship' feeds it."
else
    BUNDLE=$(mktemp /tmp/ops-canon.XXXXXX.bundle)
    # Every ops ref EXCEPT main; --not $SHA keeps it thin (the identity/COB/
    # sigref histories aren't reachable from $SHA, so they ship whole — a few KB).
    mapfile -t ops_refs < <(git -C "$HS" for-each-ref --format='%(refname)' "$NS/" \
                               | grep -v '/refs/heads/main$')
    if git -C "$HS" bundle create "$BUNDLE" "${ops_refs[@]}" --not "$SHA" >/dev/null 2>&1; then
        echo "[promote] carrying ops canonical $SHA to box ($(du -h "$BUNDLE" | cut -f1) bundle)"
        $TS scp -q "$BUNDLE" "$BOX:/tmp/ops-canon.bundle"
    else
        echo "[promote] WARN: could not build delegate bundle — canonical not propagated"
        rm -f "$BUNDLE"; BUNDLE=""
    fi
fi

echo "[promote] on-box: ff main + rad push"
ONBOX_LOG=$(mktemp /tmp/promote-onbox.XXXXXX.log)
$TS ssh "$BOX" "
  # The checkout IS main: nothing else may live in its index or tree. A ship
  # whose SSH leg was cut mid-merge (2026-09-13) left the index carrying the
  # incoming files while HEAD stayed put, and every later ff refused to
  # overwrite them. Placed satellite trees and built wasm are gitignored, so
  # a hard reset costs nothing they hold.
  # Root git use inside the checkout (a reconfigure run from that directory)
  # leaves root-owned reflogs and objects that block the playnet user's own
  # ff and the CI fetch. This leg runs as root: give the tree back to its
  # owner, the way the top directory is owned.
  chown -R --reference=$CO $CO/.git
  sudo -u playnet git -C $CO reset -q --hard main
  if [ -n '$REWRITE' ]; then sudo -u playnet git -C $CO reset -q --hard $REF || exit 1
  else sudo -u playnet git -C $CO merge --ff-only $REF || exit 1; fi
  sudo -u playnet git -C $CO branch -D $REF
  sudo -u playnet env RAD_PASSPHRASE=\"\$(cat /run/secrets/rad-passphrase)\" \
    RAD_HOME=/var/lib/playnet/radicle/.radicle \
    git -C $CO push ${REWRITE:+-f} rad main 2>&1 | tail -1
  git -C $CO log --oneline -1 main
  if [ -f /tmp/ops-canon.bundle ]; then
    echo '[box] advancing Radicle canonical (ops delegate ref + set-head)'
    chown playnet /tmp/ops-canon.bundle
    if sudo -u playnet git -C $STORE cat-file -e $SHA 2>/dev/null \
       && sudo -u playnet git -C $STORE fetch -q /tmp/ops-canon.bundle \"+$NS/*:$NS/*\"; then
      sudo -u playnet git -C $STORE update-ref $NS/refs/heads/main $SHA
      sudo -u playnet git -C $STORE update-ref refs/heads/main $SHA
      herd restart radicle-httpd  >/dev/null 2>&1 || true
      herd restart radicle-http-api >/dev/null 2>&1 || true
      echo \"[box] canonical refs/heads/main = \$(sudo -u playnet git -C $STORE rev-parse refs/heads/main)\"
    else
      echo '[box] WARN: delegate-ref propagation failed — canonical NOT advanced (Explorer will lag)'
    fi
    rm -f /tmp/ops-canon.bundle
  fi
  echo \"[box] CANONICAL=\$(sudo -u playnet git -C $STORE rev-parse refs/heads/main 2>/dev/null)\"
" | tee "$ONBOX_LOG"
[ -n "$BUNDLE" ] && rm -f "$BUNDLE"
box_canon=$(sed -n 's/^\[box\] CANONICAL=//p' "$ONBOX_LOG" | tail -1)
rm -f "$ONBOX_LOG"
if [ "$box_canon" != "$SHA" ]; then
    echo "[promote] FAILED: the live site was deployed to $SHA, but the Radicle"
    echo "          canonical/Explorer did NOT advance: the box reports canonical at"
    echo "          ${box_canon:-<unreadable>}. Fix the cause above and re-run 'make ship'."
    exit 1
fi
[ "$OPS_SIGNED" = 1 ] || echo "[promote] NOTE: canonical is at $SHA on the box (advanced by its own push); ops's delegate ref was not signed."
echo "[promote] done — canonical = $SHA; backstop deploys within ≤300s"

# "done" means canonical moved. It does not mean the site is up: a commit whose
# gateway cannot boot deploys cleanly and then crash-loops (2026-10-01: nine
# hours, unnoticed). So wait for the box to deploy $SHA, then for the gateway to
# serve. PROMOTE_VERIFY=0 skips this; PROMOTE_VERIFY_SEC bounds it (default 900).
if [ "${PROMOTE_VERIFY:-1}" = 1 ]; then
    short=$(printf %.8s "$SHA")
    boxsh() { $TS ssh -o BatchMode=yes -o ConnectTimeout=40 "$BOX" "$@" 2>/dev/null; }
    deadline=$((SECONDS + ${PROMOTE_VERIFY_SEC:-900}))
    echo "[promote] verifying: the box deploys $short, then the gateway serves (PROMOTE_VERIFY=0 skips)"
    deployed=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        deployed=$(boxsh 'cut -c1-8 /home/playnet/playnet-repo/.deployed-sha')
        [ "$deployed" = "$short" ] && break
        sleep 20
    done
    if [ "$deployed" != "$short" ]; then
        echo "[promote] WARNING: the box has not deployed $short yet (it reports ${deployed:-<unreadable>});"
        echo "          canonical moved and the hook may still be building. Check again before trusting the site."
        exit 2
    fi
    # the hook restarts the gateway within seconds of writing .deployed-sha;
    # let that begin, so an old process still answering cannot pass for the new one
    sleep 30
    ok=0; code=000
    while [ "$SECONDS" -lt "$deadline" ]; do
        code=$(boxsh 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8080/entry-points.json')
        if [ "$code" = 200 ]; then ok=$((ok + 1)); [ "$ok" -ge 2 ] && break; else ok=0; fi
        sleep 15
    done
    if [ "$ok" -lt 2 ]; then
        echo "[promote] FAILED: $short is deployed but the gateway is not serving (entry-points.json: ${code:-?})."
        echo "          ssh $BOX 'herd status playnet-gateway; tail -30 /var/log/playnet/gateway.log'"
        exit 1
    fi
    echo "[promote] verified — $short deployed and the gateway is serving"
fi
