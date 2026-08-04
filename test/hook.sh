#!/usr/bin/env bash
# Smoke test for a shell hook: source it in an isolated interactive shell,
# delete a file, and check a session was recorded and is undoable.
#
#   test/hook.sh zsh|bash|fish
#
# This runs the hook the way a user gets it, through the shell's own
# preexec/postexec machinery, which is the part e2e.sh cannot reach: it
# arms the shim itself and never loads a hook at all.
set -euo pipefail

sh=${1:?usage: hook.sh <zsh|bash|fish>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/store" "$WORK/play"
echo "precious data" >"$WORK/play/file.txt"

command -v "$sh" >/dev/null || { echo "$sh not installed, skipped"; exit 0; }

# A developer running this already has undo in their own shell, and every
# UNDO_* it exports would be inherited and tested instead of the repo.
clean_env=(env -u LD_PRELOAD -u UNDO_SESSION -u UNDO_LIB -u UNDO_DATA_DIR
    -u UNDO_HOOK -u UNDO_IGNORE -u UNDO_KEEP)

# posix shells and fish disagree on everything about assignment, so the rc
# is written per shell rather than shared
case $sh in
zsh | bash)
    mkdir -p "$WORK/rcdir"
    # zsh only reads $ZDOTDIR/.zshrc, bash takes any name via --rcfile
    cat >"$WORK/rcdir/.zshrc" <<EOF
export UNDO_DATA_DIR=$WORK/store
export UNDO_LIB=$ROOT/build/libundo.so
export PATH=$ROOT/bin:\$PATH
source $ROOT/shell/undo.$sh
EOF
    ;;
fish)
    mkdir -p "$WORK/rcdir/fish"
    cat >"$WORK/rcdir/fish/config.fish" <<EOF
set -gx UNDO_DATA_DIR $WORK/store
set -gx UNDO_LIB $ROOT/build/libundo.so
set -gx PATH $ROOT/bin \$PATH
source $ROOT/shell/undo.fish
EOF
    ;;
*)
    echo "unknown shell: $sh" >&2
    exit 2
    ;;
esac

cmds=$(printf 'rm %s/play/file.txt\nundo -y\ncat %s/play/file.txt\nexit\n' \
    "$WORK" "$WORK")

# The exit status is the last command's, not a verdict on the hook, and
# fish hands back non-zero where the others do not. Judge the store and the
# output below instead of dying here with nothing to show.
case $sh in
zsh)
    out=$(printf '%s\n' "$cmds" |
        "${clean_env[@]}" ZDOTDIR="$WORK/rcdir" zsh -i 2>&1 || true) ;;
bash)
    out=$(printf '%s\n' "$cmds" |
        "${clean_env[@]}" bash --rcfile "$WORK/rcdir/.zshrc" -i 2>&1 || true) ;;
fish)
    # fish only raises fish_preexec for a command typed at a terminal. Fed
    # from a pipe it runs the command and the event never fires, so the
    # hook looks broken when it is the test that is. script(1) gives it a
    # pty and forwards our stdin into it, which is close enough to typing.
    command -v script >/dev/null ||
        { echo "script(1) not installed, skipped"; exit 0; }
    out=$(printf '%s\n' "$cmds" |
        "${clean_env[@]}" XDG_CONFIG_HOME="$WORK/rcdir" \
        script -qec "fish -i" /dev/null 2>&1 || true) ;;
esac

fail() {
    echo "FAIL ($sh hook): $*" >&2
    echo "--- shell output ---" >&2
    echo "$out" >&2
    exit 1
}

grep -q "precious data" <<<"$out" || fail "file not restored"

# The store proves which half of the hook ran. A session directory means
# preexec fired; the done marker means postexec did, which is what puts
# LD_PRELOAD back. Checking $LD_PRELOAD from a command cannot see this:
# preexec has already armed it again by the time the command runs.
shopt -s nullglob
sessions=("$WORK"/store/sessions/*/)
((${#sessions[@]} > 0)) || fail "no session recorded, preexec never fired"

# The session for the last command stays open by design: the shell exits
# out from under it and postexec never gets to run. Any earlier one closing
# is enough to show the second half of the hook works.
closed=0
for s in "${sessions[@]}"; do
    [[ -f "$s/done" ]] && closed=$((closed + 1))
done
((closed > 0)) || fail "no session got a done marker, postexec never fired"

echo "$sh hook smoke test passed ($closed/${#sessions[@]} sessions closed)"
