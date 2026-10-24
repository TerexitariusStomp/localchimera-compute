#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# reconfigure-restarts.sh — the followup `guix system reconfigure` never
# does for you: the restarts, and closing out what it just applied. Run
# right after `make reconfigure` (or a raw `guix system reconfigure`), on
# the box, as root.
#
#   sudo PROVIDER=/root/provider-1.scm make reconfigure && \
#     sudo bash deploy/scripts/reconfigure-restarts.sh
#
# `guix system reconfigure` unloads services that no longer exist and starts
# ones newly added, but a service that was ALREADY RUNNING and still exists
# in the new generation keeps running on its OLD definition, however much its
# configuration changed. Not a gap specific to this box: Guix computes which
# already-running services COULD be restarted
# (gnu/services/shepherd.scm's `shepherd-service-upgrade`, the `to-restart`
# value) and then never acts on it — `guix/scripts/system/reconfigure.scm`'s
# `upgrade-services-program` (~line 161) takes `to-restart` as an argument
# and only splices `to-unload` and `to-start` into the program it runs. The
# manual's own advice for `guix deploy` says as much: restarting is the
# operator's job (`guix deploy FILE -x -- herd restart SERVICE`). Read
# directly from the pinned Guix source (deploy/channels.scm's commit),
# 2026-09-22 — this file is the record of that finding.
#
# This restarts the services on THIS box known to need it — add a name below
# the next time a reconfigure silently leaves one on stale config, rather
# than restarting every service on every reconfigure (that would bounce
# radicle-node mid-sync, monero-wallet-rpc mid-request, tor mid-circuit, the
# very ssh session running this).
#
# Deliberately NOT here: radicle-httpd, radicle-http-api, radicle-ci. Guix
# bug #23170 (Shepherd never cascade-restarts a dependent when its
# requirement restarts) already has a fix for them in radicle-service.scm —
# a backgrounded herd-start fired from radicle-node's OWN start gexp,
# covering boot, a crash respawn, and an explicit `herd restart
# radicle-node`. That is a different trigger from this script (which fires
# once per reconfigure, regardless of whether radicle-node itself restarted)
# and duplicating it here would restart them on every routine reconfigure
# even when nothing about them changed — including mid radicle-ci fetch.
set -euo pipefail

RESTART=(nginx)
START=(radicle-configure)   # a one-shot: it exits once it runs; `start` re-triggers it, `restart` is a no-op on a stopped one-shot

for s in "${RESTART[@]}"; do
  echo "[reconfigure-restarts] herd restart $s"
  herd restart "$s" || echo "[reconfigure-restarts] WARNING: herd restart $s failed — check herd status $s"
done
for s in "${START[@]}"; do
  echo "[reconfigure-restarts] herd start $s"
  herd start "$s" || echo "[reconfigure-restarts] WARNING: herd start $s failed — check herd status $s"
done

# ── close out the pending-reconfigure queue ─────────────────────────────────
# radicle-ci-hook.sh appends every infra-touching push's changed files to
# this file (it cannot reconfigure itself — no setuid sudo for the localchimera
# user, by design) and nothing has ever read or cleared it since: it was
# meant to answer "is a reconfigure pending", but an append-only file that's
# never trimmed can't, once entries from months ago sit beside a genuinely
# new one. A reconfigure that reaches this line just applied the checkout AS
# IT STANDS RIGHT NOW — every path ever logged here, however old — so
# whatever was pending is now applied. Archived, not deleted, matching the
# one time an operator did this by hand (queue.applied-1780637643, 2026-06-05,
# never repeated since): the file answers "what's pending" again, and the
# history of what got reconfigured when survives beside it.
QUEUE=/var/lib/localchimera/pending-reconfigure/queue
if [ -s "$QUEUE" ]; then
  mv "$QUEUE" "$QUEUE.applied-$(date +%s)"
  echo "[reconfigure-restarts] pending-reconfigure queue archived (this reconfigure applied everything in it)"
fi
