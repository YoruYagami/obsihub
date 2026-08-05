# Obsidian Vault Sync

Automatic **two-way** synchronization of an Obsidian vault through a private git repository, on **Linux** and **Windows**.

It exists because of a concrete failure mode: the `obsidian-git` plugin only runs while Obsidian is open, and when a push fails it says so in a toast that disappears in three seconds. The result is that months of notes can pile up locally, never reaching GitHub, without anyone noticing.

This project fixes that in three ways:

| | Behaviour |
|---|---|
| **Independent of Obsidian** | system timer (systemd / Task Scheduler), runs with the editor closed |
| **Two-way** | `commit → fetch → merge → push`, so it works across multiple machines |
| **Loud on failure** | critical desktop notification **and** a warning in every new terminal |

---

## Installation

### Linux (Kali, Debian, Ubuntu)

```bash
git clone <this-repo> obsidian-vault-sync
cd obsidian-vault-sync/linux
chmod +x setup.sh vault-sync.sh
./setup.sh
```

### Windows 10 / 11

```powershell
git clone <this-repo> obsidian-vault-sync
cd obsidian-vault-sync\windows
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

Both installers are **idempotent**: re-run them freely, they skip whatever is already in place.

---

## What the installer does

Nine steps, only two of which need a human:

| # | Step | Automatic |
|---|---|---|
| 1 | Dependencies (git, ssh, notifications) | ✅ |
| 2 | Repository URL | 🧑 **you** |
| 3 | Git identity | ✅ (asks only if missing) |
| 4 | SSH key without passphrase | ✅ |
| 5 | Public key onto GitHub | 🧑 **you** |
| 6 | Vault clone | ✅ |
| 7 | `.gitignore` and `.gitattributes` | ✅ |
| 8 | Timer + `vs` alias + shell warning | ✅ |
| 9 | Real end-to-end push test | ✅ |

Step 9 is not cosmetic: it creates a file, commits it, actually pushes it, then cleans up. If it fails, the installer stops with an error. That is exactly the check that usually gets skipped.

---

## Day-to-day use

None. Write in Obsidian, the timer handles the rest.

When you want an immediate push — before shutting down, say:

```
vs
```

Available in bash/zsh and in PowerShell alike.

---

## Multiple machines

The script handles four cases by comparing `HEAD`, `origin/<branch>` and their common ancestor:

| Situation | Action |
|---|---|
| In sync | exits quietly |
| Remote ahead only | fast-forward + "Vault updated" notification |
| Local ahead only | push |
| Both have changes | automatic merge |

If the automatic merge fails — same note, same lines, two machines — the script runs `git merge --abort`, **leaves the repository clean with your commits intact**, and fires a critical notification listing the files. You resolve it whenever you like:

```bash
cd ~/Vault && git pull --no-rebase
```

A half-finished merge is never left behind for the next cycle to crash into.

Commit messages include the hostname, so `git log` shows which machine each change came from.

---

## Linux ↔ Windows compatibility

Three things the installer takes care of:

**Line endings.** `.gitattributes` with `* text=auto eol=lf`, plus `core.autocrlf false` on Windows. Without them every file would show as modified on every commit and conflicts would be constant.

**`workspace.json` ignored.** It changes every time you move a pane and produces conflicts with no upside. The rest of `.obsidian` stays tracked, so themes and plugins follow you across machines.

**Characters in filenames.** Windows rejects `: * ? " < > |` in names. A note created on Linux with a colon in the title cannot be checked out on Windows. That's a filesystem limit, not a script limit — avoid those characters in titles.

---

## Checking and troubleshooting

**Linux**

```bash
systemctl --user list-timers vault-sync.timer     # next run
journalctl --user -u vault-sync.service -n 20     # logs
vault-sync.sh --verbose                           # run with details
```

**Windows**

```powershell
Get-ScheduledTaskInfo ObsidianVaultSync           # last result
& "$env:LOCALAPPDATA\ObsidianVaultSync\vault-sync.ps1" -Verbose
```

A `LastTaskResult` other than `0` means a failure.

---

## Design decisions

**SSH key without a passphrase.** Mandatory: an automated process cannot type one, and the push would fail silently. If your threat model demands a passphrase, you need `ssh-agent` with `keychain` at session start — but then silent failure becomes possible again.

**Merge rather than rebase.** With frequent auto-commits, a conflicted rebase forces you to resolve commit by commit. A merge concentrates everything into one place.

**Lock file.** `flock` on Linux, an exclusive file lock on Windows: keeps the timer and a manual run from overlapping.

**Lingering (Linux).** Without `loginctl enable-linger`, systemd terminates user services at logout and the timer stops without saying so.

**VBS wrapper (Windows).** Scheduled tasks that launch PowerShell flash a black console window on every run. The wrapper removes it.

---

## Known limitations

**It is not real-time.** The cycle is 15 minutes by default. Editing the same note on two machines within one interval will still conflict. Rule of thumb: run `vs` before switching machines.

**Git does not protect you from yourself.** If you delete half a note and the timer commits it, the good version is still in history (`git log -p -- path/to/note.md`) but it is awkward to recover. That's why you should enable **File recovery** in Obsidian (Settings → File recovery, 5-minute interval): per-note local snapshots, independent of git.

**In a VM, git alone is not enough.** Reverting a snapshot destroys anything not yet pushed. Consider pairing this with **Syncthing** to the host: continuous replication, outside the guest, independent of git.

---

## Defence in depth

| Layer | Tool | Covers |
|---|---|---|
| Continuous | Syncthing (optional) | VM crash or snapshot revert |
| Every 15 min | this project | versioned history, off-site |
| Per-note | File recovery (core plugin) | accidental deletions |

Three channels that fail for different reasons. That's the point.

---

## Uninstalling

**Linux**

```bash
systemctl --user disable --now vault-sync.timer
rm ~/.config/systemd/user/vault-sync.{timer,service}
rm ~/.local/bin/vault-sync.sh
# remove the block between the obsidian-vault-sync markers in ~/.zshrc
```

**Windows**

```powershell
Unregister-ScheduledTask -TaskName ObsidianVaultSync -Confirm:$false
Remove-Item "$env:LOCALAPPDATA\ObsidianVaultSync" -Recurse -Force
# remove the block between the obsidian-vault-sync markers in $PROFILE
```

Your vault and git repository are left untouched.
