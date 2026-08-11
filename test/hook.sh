#!/usr/bin/env bash
# Smoke test for a shell hook: source it in an isolated interactive shell,
# delete a file, and check a session was recorded and is undoable.
#
#   test/hook.sh zsh|bash|fish|nu
#
# This runs the hook the way a user gets it, through the shell's own
# preexec/postexec machinery, which is the part e2e.sh cannot reach: it
# arms the shim itself and never loads a hook at all.
set -euo pipefail

sh=${1:?usage: hook.sh <zsh|bash|fish|nu>}
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
nu)
    # nushell runs rm, mv and save inside its own process, so undo.nu
    # preloads the shim into nu rather than around it. That makes the
    # coverage below worth asserting: it depends on nushell internals,
    # and a nushell release could take any of it away silently.
    mkdir -p "$WORK/rcdir/nushell"
    cat >"$WORK/rcdir/nushell/config.nu" <<EOF
\$env.UNDO_DATA_DIR = "$WORK/store"
\$env.UNDO_LIB = "$ROOT/build/libundo.so"
\$env.PATH = (\$env.PATH | prepend "$ROOT/bin")
source $ROOT/shell/undo.nu
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

# The last two lines pull the store out from under a live session: precmd
# used to write its done marker unconditionally and spent the rest of the
# session shouting at the prompt about a directory that was gone.
#
# It removes its own session directory and nothing else, so the earlier
# sessions this test checks below survive. The shell expands
# $UNDO_SESSION, then env clears it so the shim is disarmed for the rm:
# armed, it backs each deleted file up into the very directory being
# deleted and recreates it as fast as rm unlinks it.
cmds=$(printf 'rm %s/play/file.txt\nundo -y\ncat %s/play/file.txt\nenv -u UNDO_SESSION rm -rf "$UNDO_SESSION"\ntrue\nexit\n' \
    "$WORK" "$WORK")

# nushell needs its own list: the point is its built-ins, and the syntax
# for the disarmed rm differs. undo reverts the most recent session, so
# the clobbering save goes last.
if [[ $sh == nu ]]; then
    echo "old copy" >"$WORK/play/dest.txt"
    echo "original" >"$WORK/play/over.txt"
    cmds=$(printf 'rm %s/play/file.txt\ncp %s/play/over.txt %s/play/dest.txt\n"clobbered" | save --force %s/play/over.txt\nundo -y\nexit\n' \
        "$WORK" "$WORK" "$WORK" "$WORK")
fi

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
nu)
    # reedline asks the terminal for the cursor position and blocks until
    # it answers. A pipe never does, so nu loops on the prompt and drops
    # every command; pty-drive.py answers it.
    out=$(printf '%s\n' "$cmds" |
        "${clean_env[@]}" XDG_CONFIG_HOME="$WORK/rcdir" \
        python3 "$ROOT/test/pty-drive.py" 40 nu -i 2>&1 || true) ;;
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

if [[ $sh == nu ]]; then
    # Assert on the store, not on stdout: a pty redraws the line for every
    # keystroke, so the transcript is not something to grep for content.
    #
    # One session per command, each checked for the entry its command
    # should have produced. This is the regression guard for the coverage
    # undo.nu depends on.
    want_op() { # want_op <cmd prefix> <op> <what>
        local d found=
        for d in "$WORK"/store/sessions/*/; do
            [[ -f $d/cmd ]] || continue
            [[ $(cat "$d/cmd") == $1* ]] || continue
            found=yes
            cut -f1 "$d/journal" 2>/dev/null | grep -qx "$2" ||
                fail "nushell $3 recorded no $2 entry (journal: $(cut -f1 "$d/journal" 2>/dev/null | tr '\n' ' '))"
        done
        [[ -n $found ]] || fail "no session recorded for nushell $3"
    }
    want_op "rm "   unlink "built-in rm"
    want_op "cp "   mod    "cp over an existing file"
    want_op '"clob' mod    "save over an existing file"

    # undo reverts the most recent session, which is the save
    [[ $(cat "$WORK/play/over.txt") == original ]] ||
        fail "undo did not restore the file nushell's save clobbered"

    # the shim rides inside nu, so nushell's own history must not be
    # journaled as if the user had changed it
    for d in "$WORK"/store/sessions/*/; do
        grep -q "history" "$d/journal" 2>/dev/null &&
            fail "nushell's own history file was recorded as a change"
    done
else
    grep -q "precious data" <<<"$out" || fail "file not restored"

    grep -qi "no such file or directory" <<<"$out" &&
        fail "hook complained at the prompt after the store was removed"
fi

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
