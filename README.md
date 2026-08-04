# undo

**Revert what the last shell command did to the filesystem.**

[![CI](https://github.com/edaywalid/undo/actions/workflows/ci.yml/badge.svg)](https://github.com/edaywalid/undo/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/edaywalid/undo?sort=semver)](https://github.com/edaywalid/undo/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Website: [undo.edaywalid.com](https://undo.edaywalid.com)

![undo reverting an accidental rm -rf](assets/demo.gif)

Works for the classic mistakes: `rm` / `rm -rf`, `mv` over a file you
needed, truncating with `>`, an accidental `chmod -R`, files and
directories created by a script that ran amok. Changed your mind again?
`undo redo` re-applies. Undo never deletes anything permanently, only
parks it in the session store, so a session toggles between undone and
applied as many times as you like.

**Contents**

- [Why](#why)
- [How it works](#how-it-works)
- [Install](#install)
- [Usage](#usage)
- [Storage and disk space](#storage-and-disk-space) - what it keeps, for
  how long, and what it costs you
- [Ignoring build noise](#ignoring-build-noise)
- [Configuration](#configuration) - every environment variable
- [What it cannot catch](#what-it-cannot-catch)
- [Secure deletion](#secure-deletion) - read this before `shred`
- [Platform support](#platform-support)
- [Upgrading](#upgrading) and [Uninstalling](#uninstalling)
- [Development](#development)

## Why

The shell has never had an undo, and the usual advice is that once data
is overwritten it is gone. The tools that do exist ask you to change
your habits first: alias `rm` to a trash command, or set up btrfs/zfs
snapshots before the accident. undo asks for nothing. You keep typing
`rm`, and the safety net is already under you, even when the deletion
happens three processes deep inside a build tool where no alias could
reach.

It is command-granular, not time-granular: it reverts exactly what *that
one command* touched, on any filesystem, without root. That is the
difference from a snapshot, which rolls the whole tree back to a point in
time and takes your good work with it.

## How it works

There is no snapshotting and no daemon. Nothing runs between your
commands.

1. **Hook.** A shell hook (zsh, bash, fish) arms a small `LD_PRELOAD`
   library, `libundo.so`, around every command you run.
2. **Journal.** While armed, the library intercepts destructive libc
   calls (`unlink`, `rename`, `open` with write flags, `rmdir`, `mkdir`,
   `chmod`, ...). Before each one goes through, it saves the affected
   file into a per-command session and appends a line to a journal.
   Deletions are saved by **hardlink**, so `rm -rf` on gigabytes copies
   no data and costs almost nothing.
3. **Replay.** `undo` reads the last session's journal and replays it in
   reverse: relink deleted files, move renames back, swap truncated
   files with their backups, remove accidental creations, recreate
   directories with their original modes.

Each command that changed something gets one session directory. The
whole storage format is plain files you can inspect:

```
~/.local/share/undo/sessions/        (mode 0700)
└── 1784718280691946/
    ├── cmd        rm -rf thesis/          the command line, for `undo list`
    ├── journal    one line per change     replayed in reverse
    ├── pid, done  liveness markers        so undo won't touch a running command
    └── data/
        ├── 48211-1   = thesis/draft.md    (hardlink, no data copied)
        └── 48211-2   = thesis/refs.bib
```

The last 30 sessions are kept, within a 1 GiB budget; both are
configurable, and `undo purge` wipes the store. The most recent session
is always kept, even if it alone exceeds the budget, since that is the
one `undo` reverts.

## Install

### 1. Get the binary

Any distro, no root, nothing to configure:

```sh
curl -fsSL https://undo.edaywalid.com/install.sh | sh
```

That installs into `~/.local`, then **asks** whether to add the hook line
to your shell rc, showing you the exact line first. Say no and it prints
the instructions instead; it never edits anything when there is no
terminal to ask at (a CI run, a piped install). `UNDO_MODIFY_RC=1`
answers yes for scripted installs, `UNDO_NO_MODIFY_RC=1` answers no.

Prefer a package manager?

| Channel | Command |
| --- | --- |
| Homebrew (Linux) | `brew install edaywalid/tap/undo` |
| Debian / Ubuntu | `.deb` from [releases](https://github.com/edaywalid/undo/releases), then `sudo dpkg -i undo_*.deb` |
| Fedora / openSUSE | `.rpm` from [releases](https://github.com/edaywalid/undo/releases), then `sudo rpm -i undo_*.rpm` |
| Arch | `yay -S undo-cli-bin` (AUR), or `.pkg.tar.zst` from [releases](https://github.com/edaywalid/undo/releases) |
| Nix | `nix run github:edaywalid/undo` (flake, experimental) |
| From source | `make install` (needs gcc + go, installs to `~/.local`) |

### 2. Turn it on

If you let the installer do it, open a new terminal and skip to step 3.
After a **package install**, or if you declined, add the line for your
shell:

**zsh**

```sh
echo 'source /usr/share/undo/undo.zsh' >> ~/.zshrc && exec zsh
```

**bash** (5 or newer)

```sh
echo 'source /usr/share/undo/undo.bash' >> ~/.bashrc && exec bash
```

**fish** (3.4 or newer)

```fish
echo 'source /usr/share/undo/undo.fish' >> ~/.config/fish/config.fish && exec fish
```

Those paths are for a distro package. The hooks land somewhere else for
the other channels:

| Installed with | Hook directory |
| --- | --- |
| `.deb`, `.rpm`, AUR | `/usr/share/undo/` |
| the one-liner, `make install` | `~/.local/share/undo/` |
| Homebrew | `$(brew --prefix)/share/undo/` |

For Homebrew, let the shell resolve the prefix as you write the line, so
your rc ends up with a plain path:

```sh
echo "source $(brew --prefix)/share/undo/undo.bash" >> ~/.bashrc && exec bash
```

Use double quotes there. Left unexpanded, that runs `brew` on every
shell startup, and it is a Ruby program.

### 3. Check it works

```console
$ undo doctor
```

`doctor` verifies the install and then actually deletes and restores a
canary file, so you get a real answer rather than a guess. Then try it
for yourself:

```console
$ touch x
$ rm x
$ undo
```

Run `undo` on its own line, not chained with `&&`. A chained line is a
single command to the shell, so `undo` would be running inside the very
session it is being asked to revert, before that command has finished.

No hook, or a script / CI context? Arm a single command instead, no
setup required:

```sh
undo run -- ./sketchy-cleanup.sh
```

Requires Linux (amd64 or arm64) with glibc 2.6 or newer, which is every
distribution still in use. See [platform support](#platform-support) for
musl, macOS and WSL.

## Usage

```
undo              revert the most recent command that changed files
undo -i           pick a session, cherry-pick individual entries to restore
undo redo [id]    re-apply an undone session
undo diff [id]    show what a session changed, with content diffs
undo run -- cmd   run one command with the shim armed, no hook needed
undo list         recent sessions, newest first
undo show [id]    what a session changed
undo apply <id>   revert a specific session
undo gc           prune old, empty, and oversized sessions
undo purge        delete all stored sessions and backups
undo doctor       check the install and run a live capture/restore test
undo upgrade      update to the latest release
undo uninstall    remove undo (--purge also deletes backups)
```

## Storage and disk space

The honest version, because it is the question everyone asks second.

**Deleting costs no new disk, but it does defer freeing the old.** When
you `rm` a file, undo makes a **hardlink** to it before the delete runs.
A hardlink is a second name for the same data, not a copy, which is why
`rm -rf` on gigabytes is instant and adds nothing. The catch: Linux only
frees a file's blocks when its *last* name disappears, and undo is still
holding one. So the space is not reclaimed until that backup is pruned.
If you deleted something specifically to free disk, run `undo purge`.

**Overwriting a file in place does cost disk.** A hardlink cannot
preserve content that is about to be rewritten, so for `>` truncation,
editors, and `shred`, undo copies the previous version. That copy is real
new space, capped per file by `UNDO_MAX_BYTES` (256 MiB default).

**Nothing grows without bound.** After every command undo prunes the
store:

| Limit | Default | Meaning |
| --- | --- | --- |
| `UNDO_KEEP` | 30 | how many **commands** are kept, not files. One `rm -rf` of 10,000 files is a single session and one `undo` restores all of them. |
| `UNDO_MAX_STORE` | 1 GiB | total size budget for the whole store. Oldest sessions are dropped first. |

The **most recent session is never pruned**, even if it alone exceeds the
budget, since that is the one plain `undo` reverts. Older sessions that
bust the budget are dropped almost immediately, so a very large delete
stays undoable only until the next command unless you raise the limits.

Commands that changed nothing leave no session at all. `undo gc` prunes
on demand, `undo purge` empties the store completely.

## Secure deletion

If you are deleting something because it must be **gone**, know that undo
works against you by default: for an in-place overwrite it copies the
original bytes into its store *before* `shred` rewrites them, so a
readable copy survives. `undo purge` unlinks that copy but does not
overwrite it either.

Exclude the path first, then shred:

```sh
echo '/home/you/secrets' >> ~/.config/undo/ignore
shred -u ~/secrets/tax-return.pdf
```

`sudo shred` also works, since sudo strips `LD_PRELOAD` and undo never
loads. Note that `shred` is itself unreliable on journaling filesystems
and SSDs, which its own man page explains.

## Ignoring build noise

A command that rewrites thousands of files (a package install, a build)
would otherwise flood `undo list` and the store with churn you will never
revert. The shim always skips `node_modules`, `.cache`, `__pycache__`,
and `.git`, and collapses repeated writes to the same file within one
command down to a single backup. Add your own patterns in
`~/.config/undo/ignore` (see [`examples/ignore`](examples/ignore)):

```
target              # any path component named target, at any depth
dist
/home/you/scratch   # an absolute path and everything under it
```

Set `UNDO_DEFAULT_IGNORE=0` to turn the built-ins off, or `UNDO_IGNORE`
to a colon-separated list to override the config file.

## Configuration

Environment variables, set before sourcing the hook:

| Variable | Default | Meaning |
| --- | --- | --- |
| `UNDO_KEEP` | `30` | how many commands are kept (see [storage](#storage-and-disk-space)) |
| `UNDO_MAX_STORE` | 1 GiB | total store size budget in bytes; oldest pruned first |
| `UNDO_MAX_BYTES` | 256 MiB | largest file the shim will copy for an in-place overwrite; deletions are hardlinked with no size limit |
| `UNDO_DATA_DIR` | `~/.local/share/undo` | where sessions live |
| `UNDO_IGNORE` | from config file | colon-separated ignore patterns, overrides `~/.config/undo/ignore` |
| `UNDO_IGNORE_FILE` | `~/.config/undo/ignore` | where the ignore list is read from |
| `UNDO_DEFAULT_IGNORE` | on | set to `0` to stop skipping `node_modules`, `.cache`, `__pycache__`, `.git` |
| `UNDO_CAPTURE_SHELL` | off | zsh only: set to `1` to re-exec once at startup with the shim preloaded, so the shell's own redirections (`echo x > file`) are captured too |
| `UNDO_LIB` | auto-detected | explicit path to `libundo.so` |

Installer-only variables, for `install.sh`:

| Variable | Meaning |
| --- | --- |
| `PREFIX` | install location, default `~/.local` |
| `UNDO_MODIFY_RC` | set to `1` to add the hook line without being asked (for scripted installs) |
| `UNDO_NO_MODIFY_RC` | set to `1` to never touch your shell rc |

## What it cannot catch

`LD_PRELOAD` only reaches dynamically linked programs that go through
libc. undo does **not** see:

- static binaries and programs that make raw syscalls (Go programs)
- `sudo` and setuid programs; the loader strips `LD_PRELOAD`
- plain writes through a descriptor opened before the session, mmap writes
  (`ftruncate` on such a descriptor **is** covered)
- `chown` and other metadata beyond mode (`chmod` **is** covered)
- anything run outside the hooked shell (use `undo run` there)

Coreutils and your shell are glibc-dynamic, which is exactly where the
everyday accidents happen. **This is a safety net, not a backup.** Keep
backups.

## Platform support

- **Linux, amd64 and arm64.** Any glibc distro (Debian, Ubuntu, Fedora,
  Arch, openSUSE, ...). WSL2 counts, it is Linux.
- **Alpine / musl**: build from source (`make install`, CI-tested); the
  prebuilt shim in releases targets glibc.
- **Shells**: zsh, bash 5+, fish 3.4+ for the automatic hook. Any shell
  works with `undo run`. The fish hook is currently untested.
- **macOS**: not supported. SIP blocks library injection into system
  binaries, so a port could not cover `rm` and friends.
- **Windows**: use it inside WSL2.
- **Snap / Flatpak**: never; sandboxing and an `LD_PRELOAD` hook are
  architecturally incompatible. Use a package or the installer.

## Upgrading

```console
$ undo upgrade           # or: undo upgrade --check, to only look
```

That updates a copy installed by the one-liner or `make install`, in
place. If undo came from a package manager it will not fight it, and
prints the right command for your system instead (`brew upgrade undo`,
`sudo pacman -Syu undo-cli-bin`, and so on). Open a new shell afterwards
so the updated hook is loaded.

## Uninstalling

```console
$ undo uninstall            # keeps your backups
$ undo uninstall --purge    # deletes the session store too
```

It shows what it will remove and asks first, then takes out the binary,
the shim, the hooks and the completions, and removes the lines it added
to your shell rc. Your session store is left alone unless you pass
`--purge`. A package-managed copy is not touched: it prints your package
manager's remove command instead.

Flags: `-n` dry run, `-y` skip the confirmation prompt, `--force`
overwrite files that changed again after the session.

undo asks before reverting, refuses to clobber a path that was recreated
after the session unless you pass `--force`, and refuses to touch a
session whose command may still be running in another terminal. `undo
list` marks undone sessions with a leading `u`.

If nothing seems to happen after installing, run `undo doctor`: it
locates the shim, checks the store, and deletes then restores a canary
file end to end, so you get a concrete diagnosis instead of silence.

## Development

```sh
make        # build bin/undo and build/libundo.so
make test   # go unit tests + end-to-end suite
```

The end-to-end suite (`test/e2e.sh`) arms the shim exactly as the hooks
do and exercises real deletions, overwrites, renames, undo, redo, ignore
rules, and `gc` against a temp directory. See
[CONTRIBUTING.md](CONTRIBUTING.md) for layout and the release process.

## Star history

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/star-history-dark.svg" />
  <source media="(prefers-color-scheme: light)" srcset="assets/star-history-light.svg" />
  <img alt="Star history for edaywalid/undo" src="assets/star-history-light.svg" width="700" />
</picture>

<sub>Redrawn weekly by
[`.github/workflows/star-history.yml`](.github/workflows/star-history.yml).
GitHub closed the stargazers endpoint to anonymous callers, so the usual
third-party chart embeds no longer render.</sub>

## License

MIT. See [LICENSE](LICENSE).
