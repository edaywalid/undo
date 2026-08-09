# undo.fish - arm the undo shim around every interactive command.
# Source from ~/.config/fish/config.fish:
#   source ~/.local/share/undo/undo.fish

set -q UNDO_DATA_DIR; or set -g UNDO_DATA_DIR (set -q XDG_DATA_HOME; and echo $XDG_DATA_HOME; or echo $HOME/.local/share)/undo
set -q UNDO_KEEP; or set -g UNDO_KEEP 30

if not set -q UNDO_LIB
    set -l bin (command -v undo 2>/dev/null)
    set -l candidates $HOME/.local/lib/undo/libundo.so
    if test -n "$bin"
        set -a candidates (dirname $bin)/../lib/undo/libundo.so
    end
    set -a candidates /usr/local/lib/undo/libundo.so /usr/lib/undo/libundo.so
    for l in $candidates
        if test -r $l
            set -g UNDO_LIB $l
            break
        end
    end
end

# needs fish >= 3.4 for top-level return
test -r "$UNDO_LIB"; or return

# backups may hold copies of sensitive files: keep the store private
command mkdir -p $UNDO_DATA_DIR/sessions 2>/dev/null
command chmod 700 $UNDO_DATA_DIR $UNDO_DATA_DIR/sessions 2>/dev/null

# extra ignore patterns from the config file, colon-joined for the shim.
# The shim always ignores node_modules/.cache/__pycache__/.git on top.
set -q UNDO_IGNORE_FILE; or set -g UNDO_IGNORE_FILE (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo $HOME/.config)/undo/ignore
if not set -q UNDO_IGNORE; and test -r "$UNDO_IGNORE_FILE"
    set -l pats (command grep -vE '^[[:space:]]*(#|$)' $UNDO_IGNORE_FILE 2>/dev/null)
    test (count $pats) -gt 0; and set -gx UNDO_IGNORE (string join : $pats)
end

# lets `undo doctor` tell an inactive hook from a missing install
set -gx UNDO_HOOK fish

function _undo_preexec --on-event fish_preexec
    set -l cmd (string trim -- $argv[1])
    string match -q 'undo' -- $cmd; and return
    string match -q 'undo *' -- $cmd; and return

    set -l id (date +%s%N | string sub -l 16)
    set -l dir $UNDO_DATA_DIR/sessions/$id
    command mkdir -p $dir/data 2>/dev/null; or return
    printf '%s\n' $argv[1] >$dir/cmd
    printf '%s\n' $fish_pid >$dir/pid

    set -g _undo_session $dir
    set -gx UNDO_SESSION $dir
    if not string match -q "*:$UNDO_LIB:*" ":$LD_PRELOAD:"
        if set -q LD_PRELOAD
            set -g _undo_saved_preload $LD_PRELOAD
            # drop any other libundo.so first: two loaded copies both
            # intercept, duplicating entries and recording each other
            set -l keep
            for p in (string split : -- $LD_PRELOAD)
                test -z "$p"; and continue
                string match -q '*libundo.so' -- $p; and continue
                set -a keep $p
            end
            if test (count $keep) -gt 0
                set -gx LD_PRELOAD "$UNDO_LIB:"(string join : $keep)
            else
                set -gx LD_PRELOAD $UNDO_LIB
            end
        else
            set -g _undo_saved_preload __undo_unset__
            set -gx LD_PRELOAD $UNDO_LIB
        end
    end
end

function _undo_postexec --on-event fish_postexec
    set -q _undo_session; or return
    set -e UNDO_SESSION
    if set -q _undo_saved_preload
        if test "$_undo_saved_preload" = __undo_unset__
            set -e LD_PRELOAD
        else
            set -gx LD_PRELOAD $_undo_saved_preload
        end
        set -e _undo_saved_preload
    end
    # The shim gives up when it would otherwise fill the disk. Say so:
    # precmd runs once per session, so this warns exactly once, and it is
    # the only chance the user gets to hear about it.
    if test -s $_undo_session/degraded
        printf 'undo: %s\n' (cat $_undo_session/degraded) >&2
    end

    # the store can be removed underneath a running command, by gc or by
    # hand. A hook has no business erroring at the prompt when it is.
    if test -d $_undo_session
        true >$_undo_session/done 2>/dev/null
    end
    set -e _undo_session

    if command -q undo
        command undo gc --auto 2>/dev/null
        return
    end
    # fallback: drop empty sessions, prune the oldest beyond UNDO_KEEP
    set -l all
    for d in $UNDO_DATA_DIR/sessions/*/
        if not test -s $d/journal
            command rm -rf -- $d
        else
            set -a all $d
        end
    end
    set -l n (count $all)
    if test $n -gt $UNDO_KEEP
        command rm -rf -- $all[1..(math $n - $UNDO_KEEP)]
    end
end
