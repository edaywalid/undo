#!/usr/bin/env bash
# End-to-end test: arms the shim the same way the zsh hook does, wrecks a
# directory tree, then checks that `undo` puts everything back.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UNDO=$ROOT/bin/undo
LIB=$ROOT/build/libundo.so
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export UNDO_DATA_DIR=$WORK/store
# run_armed does what a shell hook does, so declare the hook active:
# doctor treats a missing hook as a failure, since nothing gets recorded
export UNDO_HOOK=e2e
PLAY=$WORK/play

fail() { echo "FAIL: $*" >&2; exit 1; }

run_armed() {
    local id
    id=$(date +%s%N | cut -c1-16)
    local sess=$UNDO_DATA_DIR/sessions/$id
    mkdir -p "$sess/data"
    echo "$*" >"$sess/cmd"
    env UNDO_SESSION="$sess" LD_PRELOAD="$LIB" bash -c "$*"
    sleep 0.01 # keep session ids strictly ordered
}

make_tree() {
    rm -rf "$PLAY"
    mkdir -p "$PLAY/docs/sub"
    echo "report v1" >"$PLAY/docs/report.txt"
    echo "deep note" >"$PLAY/docs/sub/note.txt"
    echo "top file" >"$PLAY/top.txt"
    ln -s top.txt "$PLAY/lnk"
    chmod 640 "$PLAY/docs/report.txt"
}

echo "== case 1: rm -rf a tree"
make_tree
cp -a "$PLAY" "$WORK/expected"
run_armed "rm -rf $PLAY/docs"
[[ ! -e $PLAY/docs ]] || fail "rm -rf did not run"
"$UNDO" -y
diff -r "$PLAY" "$WORK/expected" || fail "tree not restored after rm -rf"
[[ $(stat -c %a "$PLAY/docs/report.txt") == 640 ]] || fail "mode lost"

echo "== case 2: clobbered by redirection"
run_armed "echo garbage > $PLAY/top.txt"
[[ $(cat "$PLAY/top.txt") == garbage ]] || fail "redirect did not run"
"$UNDO" -y
[[ $(cat "$PLAY/top.txt") == "top file" ]] || fail "content not restored"

echo "== case 3: mv over an existing file"
run_armed "mv $PLAY/top.txt $PLAY/docs/report.txt"
[[ $(cat "$PLAY/docs/report.txt") == "top file" ]] || fail "mv did not run"
"$UNDO" -y
[[ $(cat "$PLAY/top.txt") == "top file" ]] || fail "moved file not back"
[[ $(cat "$PLAY/docs/report.txt") == "report v1" ]] || fail "target not back"

echo "== case 4: created files and dirs are removed"
run_armed "mkdir -p $PLAY/junk && touch $PLAY/junk/a.txt $PLAY/stray.txt"
"$UNDO" -y
[[ ! -e $PLAY/junk && ! -e $PLAY/stray.txt ]] || fail "creations not removed"

echo "== case 5: deleted symlink comes back"
run_armed "rm $PLAY/lnk"
"$UNDO" -y
[[ $(readlink "$PLAY/lnk") == top.txt ]] || fail "symlink not restored"

echo "== case 6: undone sessions are skipped, dry run touches nothing"
run_armed "rm $PLAY/top.txt"
"$UNDO" -n >/dev/null
[[ ! -e $PLAY/top.txt ]] || fail "dry run restored the file"
"$UNDO" -y
[[ -e $PLAY/top.txt ]] || fail "file not restored"
out=$("$UNDO" -y 2>&1 || true)
grep -q "nothing to undo" <<<"$out" || fail "expected nothing to undo, got: $out"

echo "== case 7: refuses to clobber without --force"
run_armed "rm $PLAY/top.txt"
echo "newer content" >"$PLAY/top.txt"
"$UNDO" -y 2>&1 | grep -q "skipped" || fail "expected a skip warning"
[[ $(cat "$PLAY/top.txt") == "newer content" ]] || fail "clobbered without force"

echo "== case 8: undo run arms the shim without a hook"
export UNDO_LIB=$LIB
"$UNDO" run -- rm "$PLAY/top.txt" 2>&1 | grep -q "captured 1 change" || fail "run did not capture"
[[ ! -e $PLAY/top.txt ]] || fail "run did not execute rm"
"$UNDO" -y
[[ $(cat "$PLAY/top.txt") == "newer content" ]] || fail "run session not undoable"

echo "== case 9: redo re-applies, then undo works again"
run_armed "rm $PLAY/top.txt"
"$UNDO" -y
[[ -e $PLAY/top.txt ]] || fail "undo failed"
"$UNDO" redo -y
[[ ! -e $PLAY/top.txt ]] || fail "redo did not re-delete"
"$UNDO" -y
[[ $(cat "$PLAY/top.txt") == "newer content" ]] || fail "second undo failed"

echo "== case 10: mod entries toggle both ways without losing either version"
echo "original" >"$PLAY/toggle.txt"
run_armed "echo overwritten > $PLAY/toggle.txt"
"$UNDO" -y
[[ $(cat "$PLAY/toggle.txt") == "original" ]] || fail "undo lost original"
"$UNDO" redo -y
[[ $(cat "$PLAY/toggle.txt") == "overwritten" ]] || fail "redo lost new version"
"$UNDO" -y
[[ $(cat "$PLAY/toggle.txt") == "original" ]] || fail "second undo failed"

echo "== case 11: interactive cherry-pick restores only selected entries"
echo "one" >"$PLAY/f1.txt"
echo "two" >"$PLAY/f2.txt"
run_armed "rm $PLAY/f1.txt $PLAY/f2.txt"
printf '1\n1\ny\n' | "$UNDO" -i >/dev/null
[[ -e $PLAY/f1.txt && ! -e $PLAY/f2.txt ]] || fail "cherry-pick restored wrong set"
"$UNDO" -y 2>/dev/null
[[ -e $PLAY/f1.txt && -e $PLAY/f2.txt ]] || fail "full undo after cherry-pick failed"

echo "== case 12: diff shows content changes"
echo "alpha" >"$PLAY/d.txt"
run_armed "echo beta > $PLAY/d.txt"
out=$("$UNDO" diff)
grep -q -- "-alpha" <<<"$out" || fail "diff missing removed line"
grep -q -- "+beta" <<<"$out" || fail "diff missing added line"

echo "== case 13: chmod is journaled and reversible"
chmod 644 "$PLAY/d.txt"
run_armed "chmod 600 $PLAY/d.txt"
[[ $(stat -c %a "$PLAY/d.txt") == 600 ]] || fail "chmod did not run"
"$UNDO" -y
[[ $(stat -c %a "$PLAY/d.txt") == 644 ]] || fail "mode not restored"
"$UNDO" redo -y
[[ $(stat -c %a "$PLAY/d.txt") == 600 ]] || fail "mode redo failed"

echo "== case 14: refuses to undo a session whose command may be running"
run_armed "rm $PLAY/f2.txt"
last=$(ls "$UNDO_DATA_DIR/sessions" | sort | tail -1)
echo $$ >"$UNDO_DATA_DIR/sessions/$last/pid"
rm -f "$UNDO_DATA_DIR/sessions/$last/done"
out=$("$UNDO" -y 2>&1 || true)
grep -q "still be running" <<<"$out" || fail "live session not refused"
[[ ! -e $PLAY/f2.txt ]] || fail "live session was restored anyway"
touch "$UNDO_DATA_DIR/sessions/$last/done"
"$UNDO" -y
[[ -e $PLAY/f2.txt ]] || fail "undo failed after done marker"

echo "== case 15: gc removes empty sessions, purge empties the store"
mkdir -p "$UNDO_DATA_DIR/sessions/1111111111111111/data"
"$UNDO" gc | grep -q "removed" || fail "gc did not report"
[[ ! -d $UNDO_DATA_DIR/sessions/1111111111111111 ]] || fail "empty session survived gc"
"$UNDO" purge -y >/dev/null
[[ -z $(ls "$UNDO_DATA_DIR/sessions" 2>/dev/null) ]] || fail "purge left sessions"
out=$("$UNDO" -y 2>&1 || true)
grep -q "nothing to undo" <<<"$out" || fail "store not empty after purge"

echo "== case 16: default ignores skip build noise, real files still tracked"
mkdir -p "$PLAY/node_modules/pkg" "$PLAY/.cache" "$PLAY/src"
echo junk >"$PLAY/node_modules/pkg/i.js"
echo blob >"$PLAY/.cache/x"
echo real >"$PLAY/src/keep.c"
run_armed "rm $PLAY/node_modules/pkg/i.js $PLAY/.cache/x $PLAY/src/keep.c"
last=$(ls "$UNDO_DATA_DIR/sessions" | sort | tail -1)
j="$UNDO_DATA_DIR/sessions/$last/journal"
[[ $(grep -c . "$j") == 1 ]] || fail "expected 1 journal entry, got $(grep -c . "$j")"
grep -q "src/keep.c" "$j" || fail "real file not journaled"
grep -q "node_modules\|.cache/x" "$j" && fail "ignored path was journaled"
"$UNDO" -y >/dev/null
[[ -e $PLAY/src/keep.c ]] || fail "real file not restored"

echo "== case 17: UNDO_IGNORE adds custom patterns"
echo data >"$PLAY/scratch.tmp"
id=$(date +%s%N | cut -c1-16); sess="$UNDO_DATA_DIR/sessions/$id"
mkdir -p "$sess/data"; echo "rm scratch" >"$sess/cmd"
env UNDO_IGNORE="scratch.tmp" UNDO_SESSION="$sess" LD_PRELOAD="$LIB" bash -c "rm $PLAY/scratch.tmp"
[[ ! -s $sess/journal ]] || fail "custom UNDO_IGNORE pattern was not honored"

echo "== case 18: repeated writes to one file keep a single backup"
echo original >"$PLAY/churn.txt"
run_armed "for i in 1 2 3 4 5; do echo edit\$i > $PLAY/churn.txt; done"
last=$(ls "$UNDO_DATA_DIR/sessions" | sort | tail -1)
sd="$UNDO_DATA_DIR/sessions/$last"
[[ $(grep -c "churn.txt" "$sd/journal") == 1 ]] || fail "expected 1 mod entry, got $(grep -c churn.txt "$sd/journal")"
[[ $(ls "$sd/data" | wc -l) == 1 ]] || fail "expected 1 backup, got $(ls "$sd/data" | wc -l)"
"$UNDO" -y >/dev/null
[[ $(cat "$PLAY/churn.txt") == original ]] || fail "dedup broke restore, got $(cat "$PLAY/churn.txt")"

echo "== case 19: truncate is caught even from a large-file build"
# anything compiled with _FILE_OFFSET_BITS=64 calls truncate64, which is
# most software; missing that symbol meant silent, unrecoverable truncation
printf 'keep me\n' >"$PLAY/trunc.txt"
cat >"$WORK/tr.c" <<'CEOF'
#include <unistd.h>
int main(int c, char **v) { (void)c; return truncate(v[1], 0); }
CEOF
if cc -D_FILE_OFFSET_BITS=64 -o "$WORK/tr64" "$WORK/tr.c" 2>/dev/null; then
    run_armed "$WORK/tr64 $PLAY/trunc.txt"
    [[ ! -s $PLAY/trunc.txt ]] || fail "truncate did not run"
    "$UNDO" -y >/dev/null
    [[ $(cat "$PLAY/trunc.txt") == "keep me" ]] || fail "truncate64 not restored"
else
    echo "   (no cc, skipped)"
fi

echo "== case 20: a failed rmdir does not stop the rest of the command being recorded"
mkdir -p "$PLAY/full/x" "$PLAY/gone"
run_armed "rmdir $PLAY/full $PLAY/gone || true"
[[ -d $PLAY/full && ! -d $PLAY/gone ]] || fail "rmdir did not run as expected"
"$UNDO" -y >/dev/null
[[ -d $PLAY/gone ]] || fail "second rmdir was not journaled after the first failed"

# One long-lived process writing the same file under two sessions in a
# row: what UNDO_CAPTURE_SHELL=1 does, where the shim is loaded into the
# shell itself rather than into a fresh child per command.
if command -v python3 >/dev/null 2>&1; then
    echo "== case 21: one process spanning two sessions backs up in both"
    f=$PLAY/shared.txt
    echo v0 >"$f"
    s1=$UNDO_DATA_DIR/sessions/$(date +%s%N | cut -c1-16); mkdir -p "$s1/data"
    echo "write v1" >"$s1/cmd"; sleep 0.01
    s2=$UNDO_DATA_DIR/sessions/$(date +%s%N | cut -c1-16); mkdir -p "$s2/data"
    echo "write v2" >"$s2/cmd"
    LD_PRELOAD="$LIB" python3 -c "
import os, sys
for sess, body in ((sys.argv[1], 'v1'), (sys.argv[2], 'v2')):
    os.environ['UNDO_SESSION'] = sess
    with open(sys.argv[3], 'w') as fh:
        fh.write(body + '\n')
" "$s1" "$s2" "$f"
    [[ $(cat "$f") == v2 ]] || fail "writes did not run"
    grep -q "shared.txt" "$s2/journal" 2>/dev/null || fail "second session recorded nothing"
    "$UNDO" -y >/dev/null
    [[ $(cat "$f") == v1 ]] || fail "second session did not restore v1, got $(cat "$f")"
else
    echo "== case 21: skipped (no python3)"
fi

echo "== case 22: undo run reports a signal death the way a shell does"
set +e
"$UNDO" run -- sh -c 'kill -TERM $$' >/dev/null 2>&1
rc=$?
set -e
[[ $rc == 143 ]] || fail "expected 143 from a SIGTERM death, got $rc"

echo "== case 23: undo doctor passes its live self-test"
out=$("$UNDO" doctor 2>&1) || fail "doctor exited non-zero: $out"
grep -q "\[ok  \] capture" <<<"$out" || fail "doctor capture check did not pass"
grep -q "\[ok  \] restore" <<<"$out" || fail "doctor restore check did not pass"

echo "== case 24: truncating a descriptor opened before the session is caught"
# A file opened for writing is backed up by the open hook, so truncating
# that descriptor later is already covered. What is not: a descriptor that
# was opened before this session started, whose open no armed shim ever
# saw. Inherit fd 9 from outside and empty it from inside.
#
# Built both ways: _FILE_OFFSET_BITS=64 calls ftruncate64 instead, the same
# split truncate64 has.
cat >"$WORK/ftr.c" <<'CEOF'
#include <stdlib.h>
#include <unistd.h>
int main(int c, char **v)
{
    (void)c;
    return ftruncate(atoi(v[1]), 0) != 0;
}
CEOF
if cc -o "$WORK/ftr32" "$WORK/ftr.c" 2>/dev/null &&
    cc -D_FILE_OFFSET_BITS=64 -o "$WORK/ftr64" "$WORK/ftr.c" 2>/dev/null; then
    for bits in 32 64; do
        printf 'keep me\n' >"$PLAY/ftrunc.txt"
        exec 9>>"$PLAY/ftrunc.txt"
        run_armed "$WORK/ftr$bits 9"
        exec 9>&-
        [[ ! -s $PLAY/ftrunc.txt ]] || fail "ftruncate ($bits) did not run"
        "$UNDO" -y >/dev/null
        [[ $(cat "$PLAY/ftrunc.txt") == "keep me" ]] ||
            fail "ftruncate ($bits) not restored"
    done
else
    echo "   (no cc, skipped)"
fi

echo "== case 25: fchmod through an open descriptor is caught"
# chmod and fchmodat were interposed, fchmod was not, so the same mode
# change was recorded or lost depending on which one the caller reached for
cat >"$WORK/fch.c" <<'CEOF'
#include <fcntl.h>
#include <sys/stat.h>
int main(int c, char **v)
{
    (void)c;
    int fd = open(v[1], O_RDONLY);
    if (fd < 0)
        return 1;
    return fchmod(fd, 0600) != 0;
}
CEOF
if cc -o "$WORK/fch" "$WORK/fch.c" 2>/dev/null; then
    printf 'modes\n' >"$PLAY/fchm.txt"
    chmod 644 "$PLAY/fchm.txt"
    run_armed "$WORK/fch $PLAY/fchm.txt"
    [[ $(stat -c %a "$PLAY/fchm.txt") == 600 ]] || fail "fchmod did not run"
    "$UNDO" -y >/dev/null
    [[ $(stat -c %a "$PLAY/fchm.txt") == 644 ]] || fail "fchmod mode not restored"
else
    echo "   (no cc, skipped)"
fi

echo
echo "all cases passed"
