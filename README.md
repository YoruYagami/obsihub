# Obsidian Vault Sync

Automatic **two-way** synchronization of an Obsidian vault through a private GitHub repository, on **Linux**.

It exists because of a concrete failure mode: the `obsidian-git` plugin only runs while Obsidian is open, and when a push fails it says so in a toast that disappears in three seconds. The result is that months of notes can pile up locally, never reaching GitHub, without anyone noticing.

This project fixes that in three ways:

| | Behaviour |
|---|---|
| **Independent of Obsidian** | a systemd timer, runs with the editor closed |
| **Two-way** | `commit → fetch → merge → push`, so it works across multiple machines |
| **Loud on failure** | critical desktop notification **and** a warning in every new terminal |

Everything — setup, sync and diagnostics — is a single script: `vault-sync`.

---

## Installation

```bash
git clone https://github.com/YoruYagami/obsihub
obsihub/vault-sync configure
```

It works on any Linux with systemd. On Debian-based systems (Kali, Debian, Ubuntu) the setup installs missing dependencies by itself.

The setup installs the script to `~/.local/bin/vault-sync`, so the cloned folder isn't needed afterwards.

---

## The guided setup

`vault-sync configure` — `vsetup` once installed — is a wizard in the style of `p10k configure`: one page per question, one key per answer. **Enter keeps the current value**, `r` starts over, `q` quits without saving anything.

| Step | Question | Default |
|---|---|---|
| 1 | Where is the vault? | detected from Obsidian's own config |
| 2 | Which GitHub repository? | the vault's current `origin` |
| 3 | Which SSH key? | a **dedicated deploy key**, valid for this repository only |
| 4 | How often to sync? | every 15 minutes |
| 5 | Which desktop notifications? | errors and updates |
| 6 | Terminal shortcuts? | yes: `vs`, `vsetup`, warning at shell start |
| 7 | Summary | `y` applies everything and syncs |

The only step that needs a human is the key. If GitHub doesn't accept it yet, the wizard shows the public key, copies it to the clipboard, opens the right GitHub page (the repository's *Deploy keys*, or your account's *SSH keys*) and checks again when you press Enter.

Once you confirm, it:

- clones the vault, or creates the repository, or — if the folder already holds notes and GitHub already holds a vault — merges the two without losing either side;
- installs itself to `~/.local/bin/vault-sync`;
- configures git in the vault: `origin`, the key (also used by manual `git` commands), an identity if none is set, `pull.rebase false`;
- adds the [ignore rules](#what-stays-out-of-git) to `.gitignore`;
- installs the systemd timer and enables lingering;
- adds `vs`, `vsetup` and the shell warning to `~/.zshrc` (or `~/.bashrc`);
- runs a first real sync, then proves that GitHub accepts **pushes** from the key, not just reads.

That last check is not cosmetic: a deploy key added without *Allow write access* can read the repository, so everything looks fine — until the first push.

**When something breaks, run `vsetup` again.** Every page starts from the current value: it's Enter, Enter, … and only the broken step needs attention.

Settings live in `~/.config/vault-sync/config`. You can also edit that file by hand and then run `vault-sync apply`.

---

## Day-to-day use

None. Write in Obsidian, the timer handles the rest.

| Command | |
|---|---|
| `vs` | sync right now — before shutting down, say |
| `vault-sync status` | vault, key, GitHub access, pending commits, timer, last sync |
| `vsetup` | reopen the guided setup |

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
cd ~/Vault && git merge origin/main     # then fix the conflicting notes
git commit -a && vs
```

A half-finished merge is never left behind for the next cycle to crash into, and while you are resolving one by hand the script refuses to run, so conflict markers never get committed by accident.

Commit messages include the hostname, so `git log` shows which machine each change came from.

---

## When something goes wrong

Every failure is reported in plain words, together with the fix:

| Situation | What happens |
|---|---|
| GitHub rejects the key | `GitHub rejects SSH key ~/.ssh/… → vsetup` |
| Deploy key without write access | `the deploy key is read-only: on GitHub tick "Allow write access"` |
| Offline | silence, unless it lasts more than a day |
| Same note edited on two machines | `CONFLICT in note.md: nothing is lost. To resolve: …` |
| Merge or rebase left half-done | the sync stops instead of committing conflict markers |
| A file over 100 MB | kept out of the commit (GitHub would refuse it and block every later push); everything else syncs |
| A git repository inside the vault | reported: git would store only a pointer to it, not its files |

An error is notified once, then at most every 4 hours while it lasts — not every 15 minutes. The warning at shell start always shows the current problem, and `vault-sync status` gives the full picture.

To dig deeper:

```bash
vault-sync status                                 # the whole picture, including GitHub access
vs                                                # sync now, showing each step
journalctl --user -u vault-sync.service -n 20     # logs of the automatic runs
```

---

## What stays out of git

The setup adds these rules to the vault's `.gitignore`:

| Rule | Why |
|---|---|
| `**/.obsidian/workspace.json`, `**/.obsidian/workspace-mobile.json` | Obsidian's UI state: it changes every time you move a pane and produces conflicts with no upside |
| `**/.obsidian/cache` | regenerated by Obsidian |
| `**/.obsidian/plugins/obsidian-git/` | this project replaces the plugin |
| `.trash/` | Obsidian's own bin |

The rules start with `**/`, so they also match when the Obsidian vault is a subfolder of the repository. The rest of `.obsidian` stays tracked, so themes and plugins follow you across machines.

---

## Design decisions

**SSH key without a passphrase.** Mandatory: an automated process cannot type one, and the push would fail silently. If your threat model demands a passphrase, you need `ssh-agent` with `keychain` at session start — but then silent failure becomes possible again.

**A deploy key by default.** It can reach the vault repository and nothing else, so a key sitting unencrypted on disk exposes your notes, not every repository you own.

**Pinned GitHub host key.** The setup adds GitHub's published host key instead of trusting whatever answers the first connection.

**Merge rather than rebase.** With frequent auto-commits, a conflicted rebase forces you to resolve commit by commit. A merge concentrates everything into one place.

**Lock file.** `flock` keeps the timer and a manual run from overlapping.

**Lingering.** Without `loginctl enable-linger`, systemd terminates user services at logout and the timer stops without saying so. The setup enables it, or tells you the command if it can't.

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

## Updating

```bash
cd obsihub && git pull && ./vault-sync apply
```

`apply` reinstalls the script and re-applies the saved settings, without asking anything.

Coming from the old `setup.sh` + `vault-sync.sh`: run `./vault-sync configure`. It replaces `~/.local/bin/vault-sync.sh` and removes the old `obsidian-vault-sync` block from your shell rc files.

---

## Uninstalling

```bash
systemctl --user disable --now vault-sync.timer
rm ~/.config/systemd/user/vault-sync.{timer,service} ~/.local/bin/vault-sync
rm -r ~/.config/vault-sync ~/.local/state/vault-sync
# remove the block between the vault-sync markers in ~/.zshrc
```

Your vault and git repository are left untouched.
