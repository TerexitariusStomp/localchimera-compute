#!/bin/bash
# setup-self-improving-loop.sh — One-time server setup for the self-improving loop
#
# Run after `guix deploy` lands the dev-bridge service and dev-checkout activation.
# Must be run as the deploy user (wheel/sudo) on the server:
#
#   ssh deploy@SERVER_IP
#   bash /home/playnet/playnet-repo/deploy/guix/setup-self-improving-loop.sh
#
# This script:
#   1. Installs Claude Code CLI
#   2. Configures git push access for the playnet user
#   3. Installs and configures gh CLI
#   4. Verifies the dev-checkout and MQTT broker
#   5. Prints next steps for API key and activation

set -e

SERVER_USER="playnet"
DEV_CHECKOUT="/home/$SERVER_USER/dev-checkout"
REPO_URL="git@github.com:interplaynetary/xorg.git"

echo "== Self-Improving Loop Setup =="
echo ""

# ── 1. Install Claude Code CLI ──────────────────────────────────────────────

echo "--- Step 1: Claude Code CLI ---"
if command -v claude >/dev/null 2>&1; then
    echo "Claude Code already installed: $(claude --version 2>&1 | head -1)"
else
    echo "Installing Claude Code..."
    if command -v npm >/dev/null 2>&1; then
        sudo npm install -g @anthropic-ai/claude-code
    else
        echo "npm not found. Install Node.js first:"
        echo "  guix install node"
        echo "  Then re-run this script."
        exit 1
    fi
    echo "Installed: $(claude --version 2>&1 | head -1)"
fi
echo ""

# ── 2. Verify dev-checkout exists ───────────────────────────────────────────

echo "--- Step 2: Dev checkout ---"
if [ -d "$DEV_CHECKOUT/.git" ]; then
    echo "Dev checkout exists: $DEV_CHECKOUT"
    echo "  Branch: $(sudo -u $SERVER_USER git -C $DEV_CHECKOUT branch --show-current)"
    echo "  Remote: $(sudo -u $SERVER_USER git -C $DEV_CHECKOUT remote get-url origin)"
else
    echo "Dev checkout missing. Creating..."
    sudo -u $SERVER_USER git clone "$REPO_URL" "$DEV_CHECKOUT"
fi

# Switch remote to SSH for push access
CURRENT_REMOTE=$(sudo -u $SERVER_USER git -C $DEV_CHECKOUT remote get-url origin 2>/dev/null || echo "")
if echo "$CURRENT_REMOTE" | grep -q "https://"; then
    echo "Switching remote from HTTPS to SSH for push access..."
    sudo -u $SERVER_USER git -C $DEV_CHECKOUT remote set-url origin "$REPO_URL"
    echo "  New remote: $REPO_URL"
fi
echo ""

# ── 3. SSH key for git push ─────────────────────────────────────────────────

echo "--- Step 3: SSH key for git push ---"
PLAYNET_KEY="/home/$SERVER_USER/.ssh/id_ed25519"
if [ -f "$PLAYNET_KEY" ]; then
    echo "SSH key exists: $PLAYNET_KEY"
else
    echo "Generating SSH key for $SERVER_USER..."
    sudo -u $SERVER_USER ssh-keygen -t ed25519 -f "$PLAYNET_KEY" -N "" -C "playnet-agent@$(hostname)"
fi
echo ""
echo "  Add this deploy key (read-write) to the GitHub repo:"
echo "  https://github.com/interplaynetary/xorg/settings/keys/new"
echo ""
echo "  Public key:"
sudo cat "${PLAYNET_KEY}.pub"
echo ""

# ── 4. Install gh CLI ───────────────────────────────────────────────────────

echo "--- Step 4: GitHub CLI ---"
if command -v gh >/dev/null 2>&1; then
    echo "gh CLI installed: $(gh --version | head -1)"
else
    echo "Installing gh CLI..."
    if command -v guix >/dev/null 2>&1; then
        guix install gh
    else
        # Fallback: download from GitHub
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt update && sudo apt install gh -y
    fi
fi

# Check if gh is authenticated for the playnet user
if sudo -u $SERVER_USER gh auth status >/dev/null 2>&1; then
    echo "gh is authenticated for $SERVER_USER"
else
    echo ""
    echo "  gh needs authentication. Run as playnet user:"
    echo "    sudo -u $SERVER_USER gh auth login"
    echo "  Choose: GitHub.com → SSH → Use existing key → Paste a PAT"
fi
echo ""

# ── 5. Verify MQTT broker ──────────────────────────────────────────────────

echo "--- Step 5: MQTT broker ---"
if sudo herd status mosquitto 2>/dev/null | grep -q running; then
    echo "Mosquitto is running"
else
    echo "Mosquitto is not running. Starting..."
    sudo herd start mosquitto || echo "  Failed — check: sudo herd log mosquitto"
fi
echo ""

# ── 6. API key reminder ────────────────────────────────────────────────────

echo "--- Step 6: Anthropic API key ---"
ENV_FILE="/home/$SERVER_USER/.config/claude/.env"
if [ -f "$ENV_FILE" ] && grep -q "ANTHROPIC_API_KEY" "$ENV_FILE"; then
    echo "API key configured in $ENV_FILE"
else
    echo "  Claude Code needs an API key. Set it up:"
    echo ""
    echo "    sudo -u $SERVER_USER mkdir -p /home/$SERVER_USER/.config/claude"
    echo "    sudo -u $SERVER_USER sh -c 'echo \"ANTHROPIC_API_KEY=sk-ant-...\" > $ENV_FILE'"
    echo ""
    echo "  Or run Claude Code interactively once to set it up:"
    echo "    sudo -u $SERVER_USER -i"
    echo "    cd $DEV_CHECKOUT && claude"
fi
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────

echo "== Setup Summary =="
echo ""
echo "Automated:"
echo "  [$(command -v claude >/dev/null && echo 'x' || echo ' ')] Claude Code CLI installed"
echo "  [$([ -d $DEV_CHECKOUT/.git ] && echo 'x' || echo ' ')] Dev checkout at $DEV_CHECKOUT"
echo "  [$([ -f $PLAYNET_KEY ] && echo 'x' || echo ' ')] SSH key generated"
echo "  [$(command -v gh >/dev/null && echo 'x' || echo ' ')] gh CLI installed"
echo "  [$(sudo herd status mosquitto 2>/dev/null | grep -q running && echo 'x' || echo ' ')] Mosquitto running"
echo ""
echo "Manual steps remaining:"
echo "  1. Add the SSH public key as a deploy key on GitHub (read-write)"
echo "  2. Run: sudo -u $SERVER_USER gh auth login"
echo "  3. Set ANTHROPIC_API_KEY (see Step 6 above)"
echo ""
echo "Once complete, activate the loop:"
echo "  sudo herd start dev-bridge"
echo ""
echo "Then seed the planner and trigger a cycle:"
echo "  sudo herd start playnet-repl"
echo "  /home/$SERVER_USER/bin/repl-eval '(display \"planner ready\")'"
