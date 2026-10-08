# ~/.bash_logout: executed by bash(1) when login shell exits.

# Save Feather ringdb to Persistent
if [ -f /home/amnesia/Persistent/feather_data/save-feather-ringdb.sh ]; then
    bash /home/amnesia/Persistent/feather_data/save-feather-ringdb.sh 2>/dev/null || true
fi

# Save Guix state to Persistent
if [ -f /home/amnesia/Persistent/guix-store/save-guix-state.sh ]; then
    bash /home/amnesia/Persistent/guix-store/save-guix-state.sh 2>/dev/null || true
fi

# Save Radicle data to Persistent
if [ -d ~/.radicle ]; then
    mkdir -p /home/amnesia/Persistent/radicle-data
    cp -a ~/.radicle/* /home/amnesia/Persistent/radicle-data/ 2>/dev/null || true
fi

# Save OpenCode session data to Persistent
if [ -f /home/amnesia/Persistent/opencode/save-opencode-data.sh ]; then
    bash /home/amnesia/Persistent/opencode/save-opencode-data.sh 2>/dev/null || true
fi

# Save Radicle keys back to vault if mounted
VAULT="/home/amnesia/Persistent/vault"
if mountpoint -q "$VAULT" 2>/dev/null && [ -d ~/.radicle/keys ]; then
    mkdir -p "$VAULT/radicle-keys"
    cp -a ~/.radicle/keys/* "$VAULT/radicle-keys/" 2>/dev/null || true
fi

# Unmount encrypted vault (must be last - after all saves)
if [ -f /home/amnesia/Persistent/scripts/unmount-vault.sh ]; then
    bash /home/amnesia/Persistent/scripts/unmount-vault.sh 2>/dev/null || true
fi
