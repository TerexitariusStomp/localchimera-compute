#!/usr/bin/env bash
# claimable-by-products.sh — the set of goods a citizen may claim, after a plan, in a
# scope whose people eat.
#
#   tools/probes/claimable-by-products.sh
#
# tests/planner/test-claim-means.scm plans a scope (a baker, Ada, an oven, wheat) and
# prints `claimable-specs`, the specs the rail reads as individually claimable: a good
# some process makes and no process uses up. The people's metabolism makes those
# true of its by-products too (faeces, co2, urea, h2o-g, ambient-heat) and of each
# person's nutrient pools (energy|ada, protein|baker …), and a held skill resource
# (skill-bake) nothing consumes reads the same way, so they are listed as goods a
# person may claim. A claim still needs a claim commitment the plan mints for a stated
# want, and the pool holds none of them; the set is wider than the goods it means.
cd "$(dirname "$0")/../.."
guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
  bash tools/own-ccache.sh env LC_ALL=C.UTF-8 guile --no-auto-compile -q -L module tests/planner/test-claim-means.scm 2>&1 \
  | grep -a "claimable set:" | sed 's/^  claimable set: (//; s/)$//; s/" "/\n/g; s/"//g' | sort | awk '
      /\|/ { n++; next }
      { goods = goods " " $0 }
      END { print "goods:     " goods; print "per-person nutrient pools: " n }'
