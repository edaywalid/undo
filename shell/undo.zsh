# undo.zsh - arm the undo shim around every interactive command.
# Source from ~/.zshrc:  source ~/.local/share/undo/undo.zsh

zmodload zsh/datetime 2>/dev/null

: ${UNDO_DATA_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/undo}
: ${UNDO_KEEP:=30}

# locate the shim: explicit override, user install, next to the undo
# binary (homebrew), then system paths
if [[ -z ${UNDO_LIB-} ]]; then
    for _undo_l in $HOME/.local/lib/undo/libundo.so \
        ${commands[undo]:+${commands[undo]:h}/../lib/undo/libundo.so} \
        /usr/local/lib/undo/libundo.so /usr/lib/undo/libundo.so; do
        [[ -r $_undo_l ]] && { typeset -g UNDO_LIB=$_undo_l; break }
    done
    unset _undo_l
fi
[[ -r ${UNDO_LIB-} ]] || return 0

# backups may hold copies of sensitive files: keep the store private
command mkdir -p -- $UNDO_DATA_DIR/sessions 2>/dev/null
command chmod 700 -- $UNDO_DATA_DIR $UNDO_DATA_DIR/sessions 2>/dev/null

# extra ignore patterns from the config file, colon-joined for the shim.
# The shim always ignores node_modules/.cache/__pycache__/.git on top.
: ${UNDO_IGNORE_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/undo/ignore}
if [[ -z ${UNDO_IGNORE-} && -r $UNDO_IGNORE_FILE ]]; then
    local -a _undo_pats
    _undo_pats=(${(f)"$(command grep -vE '^[[:space:]]*(#|$)' $UNDO_IGNORE_FILE 2>/dev/null)"})
    (( ${#_undo_pats} )) && export UNDO_IGNORE=${(j.:.)_undo_pats}
    unset _undo_pats
fi

# Optional: re-exec zsh with the shim preloaded so redirections done by the
# shell itself (echo x > file) are captured too. Set UNDO_CAPTURE_SHELL=1
# before sourcing. Without it, only child processes are covered.
if [[ ${UNDO_CAPTURE_SHELL-} == 1 && -o interactive \
      && ":${LD_PRELOAD-}:" != *":$UNDO_LIB:"* ]]; then
    export LD_PRELOAD=$UNDO_LIB${LD_PRELOAD:+:$LD_PRELOAD}
    exec zsh
fi

_undo_preexec() {
    local cmd=${1##[[:space:]]#}
    # never instrument undo itself
    [[ $cmd == undo(|' '*) ]] && return 0

    local id=${EPOCHREALTIME/./}    # sortable: seconds + microseconds
    local dir=$UNDO_DATA_DIR/sessions/$id
    command mkdir -p -- $dir/data 2>/dev/null || return 0
    print -r -- $1 >| $dir/cmd
    print -r -- $$ >| $dir/pid

    typeset -g _undo_session=$dir
    export UNDO_SESSION=$dir
    if [[ ":${LD_PRELOAD-}:" != *":$UNDO_LIB:"* ]]; then
        typeset -g _undo_saved_preload=${LD_PRELOAD-__undo_unset__}
        # drop any other libundo.so first: two loaded copies both intercept,
        # duplicating journal entries and recording each other's backups
        local -a _undo_pre
        _undo_pre=(${(s.:.)LD_PRELOAD})
        _undo_pre=(${_undo_pre:#*libundo.so})
        export LD_PRELOAD=${(j.:.)${(@)_undo_pre}}
        export LD_PRELOAD=$UNDO_LIB${LD_PRELOAD:+:$LD_PRELOAD}
    fi
}

_undo_precmd() {
    [[ -n ${_undo_session-} ]] || return 0
    unset UNDO_SESSION
    if [[ ${_undo_saved_preload-} == __undo_unset__ ]]; then
        unset LD_PRELOAD
    elif [[ -n ${_undo_saved_preload-} ]]; then
        export LD_PRELOAD=$_undo_saved_preload
    fi
    unset _undo_saved_preload

    # The shim gives up when it would otherwise fill the disk. Say so:
    # precmd runs once per session, so this warns exactly once, and it is
    # the only chance the user gets to hear about it.
    [[ -s $_undo_session/degraded ]] &&
        print -ru2 -- "undo: $(<$_undo_session/degraded)"

    # the store can be removed underneath a running command, by gc or by
    # hand. A hook has no business erroring at the prompt when it is.
    [[ -d $_undo_session ]] && : >| $_undo_session/done 2>/dev/null
    unset _undo_session

    # prune: the CLI enforces count and size budgets; fall back to a
    # count-only prune when undo is not in PATH
    if (( $+commands[undo] )); then
        command undo gc --auto 2>/dev/null
    else
        local -a sessions
        sessions=($UNDO_DATA_DIR/sessions/*(N/On))
        local d
        local -i n=0
        for d in $sessions; do
            if [[ ! -s $d/journal ]] || (( ++n > UNDO_KEEP )); then
                command rm -rf -- $d
            fi
        done
    fi
}

# lets `undo doctor` tell an inactive hook from a missing install
export UNDO_HOOK=zsh

autoload -Uz add-zsh-hook
add-zsh-hook preexec _undo_preexec
add-zsh-hook precmd _undo_precmd
