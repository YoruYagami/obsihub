#!/usr/bin/env bash
#
# setup.sh — guided installer for Obsidian Vault Sync on Kali / Debian / Ubuntu
#
# Automates everything except the steps that genuinely need a human:
#   * pasting the public key into GitHub
#   * confirming the repository URL
#
# Idempotent: re-run it as often as you like.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_VAULT="$HOME/Vault"
INTERVAL_DEFAULT=15

B=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'
YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'; RST=$'\e[0m'

STEP=0
step()  { STEP=$((STEP+1)); echo; echo "${BLU}${B}[$STEP/9] $*${RST}"; }
ok()    { echo "   ${GRN}✔${RST} $*"; }
warn()  { echo "   ${YLW}!${RST} $*"; }
info()  { echo "   ${DIM}$*${RST}"; }
die()   { echo; echo "   ${RED}✘ $*${RST}" >&2; echo; exit 1; }

human() {
    echo
    echo "   ${YLW}${B}┌─ YOUR INPUT NEEDED ───────────────────────────────────┐${RST}"
    while IFS= read -r line; do printf "   ${YLW}${B}│${RST} %s\n" "$line"; done <<< "$1"
    echo "   ${YLW}${B}└───────────────────────────────────────────────────────┘${RST}"
    echo
}

ask() {  # ask "question" "default" -> prints the answer
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -r -p "   ${CYN}?${RST} $prompt ${DIM}[$default]${RST}: " reply </dev/tty
        echo "${reply:-$default}"
    else
        read -r -p "   ${CYN}?${RST} $prompt: " reply </dev/tty
        echo "$reply"
    fi
}

confirm() {
    local reply
    read -r -p "   ${CYN}?${RST} $1 ${DIM}[y/N]${RST}: " reply </dev/tty
    [[ "$reply" =~ ^[yY]$ ]]
}

clear
cat <<BANNER
${B}${CYN}
   ╔═══════════════════════════════════════════════════╗
   ║        Obsidian Vault Sync  ·  Linux setup        ║
   ╚═══════════════════════════════════════════════════╝
${RST}${DIM}   Automatic two-way backup of your vault over git.
   You'll only be asked where a human is genuinely needed.${RST}

BANNER

# ═══ 1. Dependencies ═════════════════════════════════════════════════════════
step "System dependencies"

MISSING=()
for pkg in git openssh-client libnotify-bin util-linux; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    info "to install: ${MISSING[*]}"
    sudo apt-get update -qq || die "apt update failed"
    sudo apt-get install -y -qq "${MISSING[@]}" || die "installation failed"
fi
ok "git, ssh, notify-send, flock available"

if ! command -v obsidian >/dev/null && ! ls /opt/Obsidian* &>/dev/null; then
    warn "Obsidian doesn't appear to be installed"
    info "grab the .deb from https://obsidian.md/download, then: sudo apt install ./obsidian_*.deb"
    info "not a blocker: syncing works regardless"
fi

# ═══ 2. Repository ═══════════════════════════════════════════════════════════
step "Vault repository"

if [ -d "$DEFAULT_VAULT/.git" ]; then
    REPO=$(git -C "$DEFAULT_VAULT" remote get-url origin 2>/dev/null)
    VAULT="$DEFAULT_VAULT"
    ok "vault already present: $VAULT"
    info "origin: $REPO"
else
    human "I need the SSH URL of your private GitHub repository.
Find it on GitHub -> green Code button -> SSH tab.
It looks like:  git@github.com:user/repo.git"
    REPO=$(ask "Repository SSH URL")
    [ -z "$REPO" ] && die "no URL given"
    if [[ "$REPO" == https://* ]]; then
        warn "that's an HTTPS URL — converting it to SSH"
        REPO=$(echo "$REPO" | sed -E 's#https://github.com/#git@github.com:#; s#/?$#.git#; s#\.git\.git$#.git#')
        info "-> $REPO"
    fi
    VAULT=$(ask "Local vault folder" "$DEFAULT_VAULT")
fi

# ═══ 3. Git identity ═════════════════════════════════════════════════════════
step "Git identity"

GIT_NAME=$(git config --global user.name  || true)
GIT_MAIL=$(git config --global user.email || true)
[ -z "$GIT_NAME" ] && GIT_NAME=$(ask "Name for commits" "$USER")
[ -z "$GIT_MAIL" ] && GIT_MAIL=$(ask "Email for commits")
ok "$GIT_NAME <$GIT_MAIL>"

# ═══ 4. SSH key ══════════════════════════════════════════════════════════════
step "SSH key"

KEY="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [ -f "$KEY" ]; then
    ok "key already present: $KEY"
    if ssh-keygen -y -P "" -f "$KEY" &>/dev/null; then
        ok "no passphrase (correct for automated pushes)"
    else
        warn "the key has a passphrase"
        info "automated pushes will fail because nothing can type it"
        if confirm "Generate a new key without a passphrase?"; then
            mv "$KEY" "$KEY.backup.$(date +%s)"
            mv "$KEY.pub" "$KEY.pub.backup.$(date +%s)" 2>/dev/null
            ssh-keygen -t ed25519 -C "$(hostname -s)-obsidian" -N "" -f "$KEY" -q
            ok "new key generated (the old one was renamed to .backup)"
        fi
    fi
else
    ssh-keygen -t ed25519 -C "$(hostname -s)-obsidian" -N "" -f "$KEY" -q \
        || die "key generation failed"
    ok "key created without a passphrase"
fi

touch "$HOME/.ssh/known_hosts"
grep -q "^github.com " "$HOME/.ssh/known_hosts" 2>/dev/null \
    || ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
ok "GitHub host key registered"

# ═══ 5. Authentication ═══════════════════════════════════════════════════════
step "GitHub authentication"

check_auth() {
    ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        git@github.com 2>&1 | grep -q "successfully authenticated"
}

ATTEMPT=0
until check_auth; do
    ATTEMPT=$((ATTEMPT+1))
    [ "$ATTEMPT" -gt 5 ] && die "authentication failed after 5 attempts"

    human "Add this public key to your GitHub account.

1. Copy the whole line below
2. Open  https://github.com/settings/ssh/new
3. Title: something like '$(hostname -s)'
4. Paste into the Key field and save"

    echo "${GRN}$(cat "${KEY}.pub")${RST}"
    echo
    read -r -p "   ${CYN}?${RST} Press ENTER once you've added it..." </dev/tty
done
ok "$(ssh -T git@github.com 2>&1 | head -1)"

# ═══ 6. Clone ════════════════════════════════════════════════════════════════
step "Local vault"

if [ -d "$VAULT/.git" ]; then
    ok "already present at $VAULT"
    git -C "$VAULT" fetch -q origin 2>/dev/null && ok "remote state refreshed"
elif [ -e "$VAULT" ] && [ -n "$(ls -A "$VAULT" 2>/dev/null)" ]; then
    die "$VAULT exists, isn't empty, and isn't a git repo. Move it or pick another path."
else
    git clone -q "$REPO" "$VAULT" || die "clone failed — is the URL correct?"
    ok "cloned into $VAULT"
fi

git -C "$VAULT" config user.name  "$GIT_NAME"
git -C "$VAULT" config user.email "$GIT_MAIL"
# Without this, a manual 'git pull' on diverged histories fails with
# "Need to specify how to reconcile divergent branches"
git -C "$VAULT" config pull.rebase false

# Vault opened on the wrong folder: the classic nested-repo mistake
if [ -d "$VAULT/.obsidian" ]; then
    NESTED=$(find "$VAULT" -mindepth 2 -maxdepth 3 -type d -name ".obsidian" 2>/dev/null | head -3)
    if [ -n "$NESTED" ]; then
        warn "found a nested .obsidian config:"
        echo "$NESTED" | while read -r n; do info "$n"; done
        info "this usually means Obsidian was opened on a subfolder"
        info "open the vault at $VAULT, not at a folder inside it"
    fi
fi

# ═══ 7. gitignore and gitattributes ══════════════════════════════════════════
step "Repository configuration"

cd "$VAULT" || die "cannot enter $VAULT"
CHANGED=0

for entry in \
    ".obsidian/workspace*.json" \
    ".obsidian/cache" \
    ".obsidian/plugins/obsidian-git/" \
    ".trash/" \
    ".DS_Store" \
    "Thumbs.db"
do
    grep -qxF "$entry" .gitignore 2>/dev/null || { echo "$entry" >> .gitignore; CHANGED=1; }
done

# Without this, Windows and Linux fight over line endings on every commit
if [ ! -f .gitattributes ] || ! grep -q "text=auto" .gitattributes 2>/dev/null; then
    printf '# Consistent line endings across Windows and Linux\n* text=auto eol=lf\n*.png binary\n*.jpg binary\n*.pdf binary\n' >> .gitattributes
    CHANGED=1
fi

git rm -r --cached --quiet .obsidian/workspace.json 2>/dev/null && CHANGED=1

if [ "$CHANGED" -eq 1 ]; then
    git add -A && git commit -q -m "chore: sync configuration" && ok ".gitignore and .gitattributes updated"
else
    ok "already configured"
fi

# ═══ 8. Automation ═══════════════════════════════════════════════════════════
step "Automatic syncing"

INTERVAL=$(ask "Sync every how many minutes" "$INTERVAL_DEFAULT")
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=$INTERVAL_DEFAULT

mkdir -p "$HOME/.local/bin"
if [ -f "$SCRIPT_DIR/vault-sync.sh" ]; then
    cp "$SCRIPT_DIR/vault-sync.sh" "$HOME/.local/bin/vault-sync.sh"
else
    die "vault-sync.sh not found next to setup.sh"
fi
chmod +x "$HOME/.local/bin/vault-sync.sh"
ok "~/.local/bin/vault-sync.sh"

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/vault-sync.service" <<EOF
[Unit]
Description=Obsidian vault sync
After=network-online.target

[Service]
Type=oneshot
Environment=VAULT=$VAULT
ExecStart=%h/.local/bin/vault-sync.sh
EOF

cat > "$HOME/.config/systemd/user/vault-sync.timer" <<EOF
[Unit]
Description=Sync the Obsidian vault every $INTERVAL minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now vault-sync.timer -q 2>/dev/null
ok "systemd timer active (every $INTERVAL minutes)"

# Without lingering, systemd kills user services at logout
if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
    ok "lingering already enabled"
elif sudo loginctl enable-linger "$USER" 2>/dev/null; then
    ok "lingering enabled (the timer survives logout)"
else
    warn "lingering not enabled: the timer stops at logout"
fi

# Alias plus a warning on every shell start
MARKER="# >>> obsidian-vault-sync >>>"
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    grep -qF "$MARKER" "$rc" && { ok "$(basename "$rc"): already configured"; continue; }
    cat >> "$rc" <<EOF

$MARKER
export PATH="\$HOME/.local/bin:\$PATH"
alias vs='VAULT="$VAULT" vault-sync.sh --verbose'
if [ -d "$VAULT/.git" ]; then
  _vu=\$(git -C "$VAULT" log --oneline @{u}..HEAD 2>/dev/null | wc -l)
  [ "\$_vu" -gt 0 ] && echo "⚠  Vault: \$_vu commit(s) not on GitHub yet — run: vs"
  unset _vu
fi
# <<< obsidian-vault-sync <<<
EOF
    ok "$(basename "$rc"): 'vs' alias and warning added"
done

# ═══ 9. End-to-end check ═════════════════════════════════════════════════════
step "Verification"

cd "$VAULT" || die "cd failed"
echo "selftest $(date '+%F %T') $(hostname -s)" > .vault-selftest
git add .vault-selftest && git commit -q -m "test: sync verification"

if git push -q origin HEAD 2>/tmp/vault-test.err; then
    rm -f .vault-selftest
    git add -A && git commit -q -m "test: cleanup" && git push -q origin HEAD
    ok "push verified: the channel to GitHub works"
else
    git reset -q --hard HEAD~1; rm -f .vault-selftest
    die "PUSH FAILED: $(tail -3 /tmp/vault-test.err)
     No note is safe until this works."
fi

if VAULT="$VAULT" "$HOME/.local/bin/vault-sync.sh" --verbose; then
    ok "sync script working"
else
    warn "the script returned an error, check above"
fi

command -v notify-send >/dev/null && \
    notify-send "Obsidian Vault Sync" "Setup complete on $(hostname -s)" 2>/dev/null

# ═══ Summary ═════════════════════════════════════════════════════════════════
cat <<EOF

${GRN}${B}   ╔═══════════════════════════════════════════════════╗
   ║                  Setup complete                   ║
   ╚═══════════════════════════════════════════════════╝${RST}

   Vault           ${B}$VAULT${RST}
   Syncs           every $INTERVAL minutes, even with Obsidian closed
   On failure      desktop notification + warning in every terminal

   ${B}Commands${RST}
     vs                                            sync right now
     systemctl --user list-timers vault-sync.timer timer status
     journalctl --user -u vault-sync.service -n 20 logs

EOF

human "Three things left to do by hand:

1. Open a new terminal tab (to load the 'vs' alias)

2. In Obsidian: 'Open folder as vault' and pick
   $VAULT
   CAREFUL: that folder, not a subfolder inside it.

3. In Obsidian: Settings -> File recovery
   interval 5 minutes, retention at maximum.
   It covers notes overwritten by mistake, which git does not.

Recommended: take a VM snapshot named
'vault configured and verified'."

echo
