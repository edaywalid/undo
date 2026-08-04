# Contributing

## Building and testing

```
make          # builds bin/undo and build/libundo.so
make test     # unit tests + end-to-end suite
```

The e2e suite (`test/e2e.sh`) arms the shim the same way the shell hooks
do and exercises real deletions, overwrites, renames, undo, redo, and
gc against a temp directory. `test/hook.sh <shell>` smoke-tests a real
hook in an isolated interactive shell, for zsh, bash and fish; it skips
itself when that shell is not installed. fish is driven through a pty,
since it raises `fish_preexec` only for a command typed at a terminal.

Anything touching the shim (`shim/undo_shim.c`) should come with an e2e
case. The shim runs inside every process a user launches: no output on
the happy path, no aborts, fail open (let the real call through) when
anything goes wrong.

## Layout

- `shim/` - the LD_PRELOAD library (C)
- `cmd/undo/`, `internal/` - the CLI (Go)
- `shell/` - per-shell hooks
- `test/` - end-to-end suites

## Releasing

Releases are cut by pushing a tag:

```
git tag v0.x.y && git push origin v0.x.y
```

CI cross-builds the shim for amd64/arm64 and runs goreleaser, which
publishes archives, deb/rpm/archlinux packages, and pushes a formula to
edaywalid/homebrew-tap. The tap push needs a `TAP_GITHUB_TOKEN` secret
(a PAT with push access to the tap repo) configured on this repository.
