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

## Cheat sheet

Day to day there is nothing to do: write in Obsidian, the timer handles the rest.

```bash
vs                    # sync now (before shutting down, before switching machines)
vault-sync status     # is everything OK? key, GitHub access, pending commits, timer, last sync
vsetup                # change a setting, or fix whatever broke: Enter keeps the current value

vault-sync apply      # after editing ~/.config/vault-sync/config by hand
journalctl --user -u vault-sync.service -n 20     # what the automatic runs did
cd obsihub && git pull && ./vault-sync apply      # update to the latest version
```

**In the guided setup:** a number or letter picks an option · **Enter** keeps the current value · **r** starts over · **q** quits without saving.

**When it tells you something** — at shell start, in a notification or after `vs`:

| Message | Fix |
|---|---|
| `GitHub rejects SSH key …` | `vsetup`, Enter up to step 3, add the key it shows on GitHub, Enter to check again |
| `the deploy key is read-only` | GitHub → repository → Settings → Deploy keys: delete the key, then `vsetup` shows it again to add with **Allow write access** ticked |
| `… has no permission to push to it` | that account can only read the repository: use the dedicated deploy key (`vsetup`, step 3) |
| `repository … does not exist or the key cannot access it` | check the name in `vsetup` step 2; a deploy key works for one repository only |
| `SSH key … does not exist` | `vsetup` creates a new one |
| `github.com did not show GitHub's official host key` | try another network; if it happens everywhere, GitHub changed its key: update vault-sync |
| `CONFLICT in note.md` | `cd ~/Vault && git merge origin/main`, fix the notes in Obsidian, then `vs` |
| `conflict markers still in note.md` | remove the `<<<<<<<` … `>>>>>>>` blocks left in those notes, then `vs` |
| `a rebase or cherry-pick was left half-done` | `cd ~/Vault && git status` says how to finish or abort it, then `vs` |
| `there are unresolved conflicts` | fix the files `git status` lists, `git add` them, then `vs` |
| `you are not on a branch (detached HEAD)` | `cd ~/Vault && git switch main`, then `vs` |
| `on GitHub the vault is on branch main, here on master` | `cd ~/Vault && git branch -m master main`, then `vs` |
| `… have nothing in common` | make sure the repository really is this vault; if it is: `cd ~/Vault && git merge --allow-unrelated-histories origin/main`, fix any conflict, then `vs` |
| `refusing to sync ~` · `is not a git repository of its own` | `vsetup`, and pick the vault's own folder |
| `files too big for GitHub (over 100 MB)` | move the file out of the vault, or add it to `.gitignore` |
| `… because it is a nested git repository` | move that folder out of the vault, or delete its `.git` folder |
| `git is locked by a leftover file` | if no other git is running on the vault: delete the file it names |
| `GitHub unreachable` · `another git is working on the vault` · `… retrying next round` · `the sync was interrupted` | nothing: the next round retries by itself |
| `automatic sync is off` | `vault-sync apply` |
| `N commit(s) not on GitHub yet` | `vs` |

**Where things live:**

| Path | What |
|---|---|
| `~/.local/bin/vault-sync` | the script |
| `~/.config/vault-sync/config` | settings |
| `~/.config/vault-sync/github_known_hosts` | GitHub's official host key |
| `~/.local/state/vault-sync/state` | outcome of the last sync |
| `~/.config/systemd/user/vault-sync.{service,timer}` | the timer |
| `~/.ssh/vault_ed25519` | the dedicated deploy key |

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

That check covers **writing**, not just reading: a deploy key added without *Allow write access* can read the repository, so everything would look fine — until the first push.

The wizard also keeps you from the mistakes that leak data:

- it refuses your home folder, the folders above it, and any folder holding SSH or GPG keys: syncing them would push your keys to GitHub;
- it asks before turning a folder that sits inside another git repository into the vault, because that means syncing the whole repository;
- it warns you if the GitHub repository is **public**, before anything is pushed.

Once you confirm, it:

- clones the vault, or creates the repository, or — if the folder already holds notes and GitHub already holds a vault — merges the two: where a note differs, GitHub's version stays and yours is kept next to it as `note (local).md`, while Obsidian's settings come from GitHub;
- installs itself to `~/.local/bin/vault-sync`;
- configures git in the vault: `origin`, the key (also used by manual `git` commands), an identity if none is set, `pull.rebase false`;
- adds the [ignore rules](#what-stays-out-of-git) to `.gitignore`;
- installs the systemd timer and enables lingering;
- adds `vs`, `vsetup` and the shell warning to `~/.zshrc` (or `~/.bashrc`);
- runs a first real sync.

**When something breaks, run `vsetup` again.** Every page starts from the current value: it's Enter, Enter, … and only the broken step needs attention.

Settings live in `~/.config/vault-sync/config`. You can also edit that file by hand and then run `vault-sync apply`.

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
cd ~/Vault && git merge origin/main     # the conflicting notes now show both versions
# fix them in Obsidian, then:
vs                                      # completes the merge once no conflict markers are left
```

A half-finished merge is never left behind for the next cycle to crash into, and while you are resolving one by hand the sync waits: as long as a conflicting note still has conflict markers it refuses to commit, so they never reach GitHub by accident.

A new machine set up on an empty folder downloads the vault on its first sync. If the local branch name differs from GitHub's (`master` here, `main` there), the script stops and tells you how to rename it, instead of pushing a second branch that the other machines would never see.

Commit messages include the hostname, so `git log` shows which machine each change came from.

---

## When something goes wrong

Every failure is reported in plain words, together with its fix (see the [cheat sheet](#cheat-sheet)). Some are prevented outright:

- **conflict markers are never committed**: the sync waits while a conflict is being resolved, and refuses to run during a half-done rebase;
- **a file over 100 MB is kept out of the commit**, because GitHub would refuse it and block every later push — everything else still syncs;
- **a git repository inside the vault is kept out and reported**, because git would store only a pointer to it, not its files (with a `.gitmodules`, submodules are left alone);
- **your home folder, or a vault that is part of another repository, is never synced**;
- **passing trouble is silent** — offline, the lid closed mid-sync, another git busy on the vault — unless it lasts more than a day.

An error is notified once, then at most every 4 hours while it lasts — not every 15 minutes. A new error replaces the previous notification instead of piling up, and when the sync works again the error notification turns into a short *✔ Vault synced again*, so a stale alarm never stays on screen. The warning at shell start always shows the current problem, and `vault-sync status` gives the full picture.

---

## What stays out of git

The setup adds these rules to the vault's `.gitignore`:

| Rule | Why |
|---|---|
| `**/.obsidian/workspace.json`, `**/.obsidian/workspace-mobile.json` | Obsidian's UI state: it changes every time you move a pane and produces conflicts with no upside |
| `**/.obsidian/cache` | regenerated by Obsidian |
| `**/.obsidian/plugins/obsidian-git/` | this project replaces the plugin |
| `.trash/` | Obsidian's own bin |

The rules start with `**/`, so they also match when the Obsidian vault is a subfolder of the repository. A `workspace.json` that was already tracked is removed from the repository (the file stays on disk); the other rules only apply to new files. The rest of `.obsidian` stays tracked, so themes and plugins follow you across machines.

---

## Design decisions

**SSH key without a passphrase.** Mandatory: an automated process cannot type one, and the push would fail silently. If your threat model demands a passphrase, you need `ssh-agent` with `keychain` at session start — but then silent failure becomes possible again.

**A deploy key by default.** It can reach the vault repository and nothing else, so a key sitting unencrypted on disk exposes your notes, not every repository you own.

**Pinned GitHub host key, private ssh settings.** GitHub's published host key lives in a file of its own, and ssh runs with `-F /dev/null`: nothing in `~/.ssh/config` — a `Host *` with `StrictHostKeyChecking no`, an extra `IdentityFile` — can weaken the check or swap in another key. The flip side: host aliases and proxies from `~/.ssh/config` don't apply to the sync.

**Independent of your git setup.** Git runs in English (its messages are parsed), and the sync overrides the settings that would break it unattended: `merge.ff=only`, commit signing, detached `gc`.

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

If the setup enabled lingering and nothing else needs it: `loginctl disable-linger`. Your vault and git repository are left untouched.
