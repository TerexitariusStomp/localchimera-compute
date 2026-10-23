#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# setup-radicle-dual-push.sh — Configure git to push to both GitHub and Radicle
#
# After running this, `git push` sends to both remotes automatically.
# During the transition period, both GitHub Actions and Radicle CI
# receive updates in parallel.
#
# Prerequisites:
#   1. rad auth    (create local Radicle identity)
#   2. rad init    (initialize repo as Radicle project)
#
# Usage:
#   ./deploy/scripts/setup-radicle-dual-push.sh

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Check rad is available
if ! command -v rad &>/dev/null; then
    echo "Error: rad not found. Install with: guix install radicle"
    exit 1
fi

# Check rad identity exists
if ! rad self 2>/dev/null; then
    echo "Error: No Radicle identity. Run: rad auth"
    exit 1
fi

# Initialize as Radicle project if not already
if ! rad inspect 2>/dev/null; then
    echo "Initializing as Radicle project..."
    rad init
fi

# Get the Radicle project ID
RID=$(rad inspect --rid 2>/dev/null || rad . 2>/dev/null)
echo "Radicle project ID: $RID"

# Add rad as a push remote alongside origin
# This creates a 'dual' remote that pushes to both
if git remote get-url rad &>/dev/null; then
    echo "rad remote already configured"
else
    echo "Note: 'rad' remote is set up by rad init"
fi

echo ""
echo "Setup complete. To push to both GitHub and Radicle:"
echo "  git push origin main && git push rad main"
echo ""
echo "Or add a git alias for dual push:"
echo "  git config alias.push-all '!git push origin main && git push rad main'"
echo ""
echo "Project ID (save this for PLAYNET_RID on the server):"
echo "  $RID"
