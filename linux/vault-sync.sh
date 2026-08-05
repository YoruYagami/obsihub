#!/usr/bin/env bash
#
# vault-sync.sh — two-way sync for an Obsidian vault backed by git
#
#   local commit  ->  fetch  ->  merge  ->  push
#
# On conflict it aborts the merge, leaves the repository clean, and warns
# the user. Nothing is ever lost.
#
# Usage:  vault-sync.sh [--verbose]
# Env:    VAULT=/path/to/vault   (default: ~/Vault)
#
set -uo pipefail

VAULT="${VAULT:-$HOME/Vault}"
ERR="/tmp/vault-sync.err"
LOCK="/tmp/vault-sync.lock"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

log() { [ "$VERBOSE" -eq 1 ] && echo "  $*"; return 0; }

notify() {
    local urgency="$1" title="$2" body="$3"
    export DISPLAY="${DISPLAY:-:0}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
    command -v notify-send >/dev/null && notify-send -u "$urgency" "$title" "$body" 2>/dev/null
    if [ "$urgency" = "critical" ]; then
        echo "[ERROR] $title — $body" >&2
    else
        log "$title — $body"
    fi
}

# One sync at a time: stops the timer and a manual run from colliding
exec 9>"$LOCK"
if ! flock -n 9; then
    log "sync already running, exiting"
    exit 0
fi

cd "$VAULT" 2>/dev/null || {
    notify critical "Vault not found" "The folder $VAULT does not exist."
    exit 1
}

git rev-parse --git-dir >/dev/null 2>&1 || {
    notify critical "Vault is not a git repository" "$VAULT contains no git repo."
    exit 1
}

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null) || {
    notify critical "Vault: detached HEAD" \
        "The repository is not on a branch. Fix it manually: cd $VAULT && git checkout main"
    exit 1
}

# A merge left half-finished by an earlier run would block everything
if [ -d "$(git rev-parse --git-path rebase-merge)" ] || \
   [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
    notify critical "Vault: unfinished merge" \
        "A merge was left incomplete. Fix it with: cd $VAULT && git status"
    exit 1
fi

# ── 1. Commit local changes ──────────────────────────────────────────────────
git add -A
if ! git diff --cached --quiet; then
    COUNT=$(git diff --cached --name-only | wc -l)
    git commit -q -m "vault: $(date '+%F %T') [$(hostname -s)]"
    log "committed $COUNT file(s)"
fi

# ── 2. Fetch remote state ────────────────────────────────────────────────────
if ! git fetch -q origin "$BRANCH" 2>"$ERR"; then
    notify critical "Vault: fetch failed" "$(tail -2 "$ERR")"
    exit 1
fi

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")
BASE=$(git merge-base HEAD "origin/$BRANCH")

# ── 3. Reconcile local and remote ────────────────────────────────────────────
if [ "$LOCAL" = "$REMOTE" ]; then
    log "already in sync with origin/$BRANCH"
    exit 0

elif [ "$LOCAL" = "$BASE" ]; then
    # Remote is ahead only: fast-forward, no risk
    if ! git merge -q --ff-only "origin/$BRANCH" 2>"$ERR"; then
        notify critical "Vault: update failed" "$(tail -2 "$ERR")"
        exit 1
    fi
    N=$(git rev-list --count "$LOCAL".."$REMOTE")
    notify normal "Vault updated" "$N change(s) pulled from another machine."
    exit 0

elif [ "$REMOTE" = "$BASE" ]; then
    log "local changes only, moving on to push"

else
    # Histories diverged: both machines have changes
    if ! git merge -q --no-edit "origin/$BRANCH" >"$ERR" 2>&1; then
        FILES=$(git diff --name-only --diff-filter=U | head -5)
        git merge --abort 2>/dev/null
        notify critical "Vault: CONFLICT" \
"The same notes were edited on two machines.
The repository is clean and nothing was lost.

Fix it with:  cd $VAULT && git pull --no-rebase
then edit the files and run:  git add -A && git commit

Conflicting files:
$FILES"
        exit 1
    fi
    notify normal "Vault merged" "Changes from two machines merged automatically."
fi

# ── 4. Push ──────────────────────────────────────────────────────────────────
if ! git push -q origin "$BRANCH" 2>"$ERR"; then
    notify critical "Vault NOT saved to GitHub" \
"The push failed. Your changes are safe locally
but they are not on GitHub yet.

$(tail -3 "$ERR")"
    exit 1
fi

log "push complete"
exit 0
