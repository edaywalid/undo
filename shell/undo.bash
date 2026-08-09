# undo.bash - arm the undo shim around every interactive command.
# Source from ~/.bashrc:  source ~/.local/share/undo/undo.bash
# Needs bash >= 5 (EPOCHREALTIME).

[[ -n ${EPOCHREALTIME-} ]] || return 0
: "${UNDO_DATA_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/undo}"
: "${UNDO_KEEP:=30}"

if [[ -z ${UNDO_LIB-} ]]; then
    _undo_bin=$(command -v undo 2>/dev/null)
    for _undo_l in "$HOME/.local/lib/undo/libundo.so" \
        ${_undo_bin:+"${_undo_bin%/*}/../lib/undo/libundo.so"} \
        /usr/local/lib/undo/libundo.so /usr/lib/undo/libundo.so; do
        [[ -r $_undo_l ]] && { UNDO_LIB=$_undo_l; break; }
    done
    unset _undo_bin _undo_l
fi
[[ -r ${UNDO_LIB-} ]] || return 0

# backups may hold copies of sensitive files: keep the store private
mkdir -p -- "$UNDO_DATA_DIR/sessions" 2>/dev/null
chmod 700 -- "$UNDO_DATA_DIR" "$UNDO_DATA_DIR/sessions" 2>/dev/null

# extra ignore patterns from the config file, colon-joined for the shim.
# The shim always ignores node_modules/.cache/__pycache__/.git on top.
: "${UNDO_IGNORE_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/undo/ignore}"
if [[ -z ${UNDO_IGNORE-} && -r $UNDO_IGNORE_FILE ]]; then
    _undo_ig=$(grep -vE '^[[:space:]]*(#|$)' "$UNDO_IGNORE_FILE" 2>/dev/null | paste -sd: -)
    [[ -n $_undo_ig ]] && export UNDO_IGNORE=$_undo_ig
    unset _undo_ig
fi

_undo_at_prompt=1

_undo_preexec() {
    [[ -n $_undo_at_prompt ]] || return 0
    _undo_at_prompt=
    local cmd=$BASH_COMMAND
    case $cmd in undo | 'undo '*) return 0 ;; esac

    local id=${EPOCHREALTIME/./}
    local dir=$UNDO_DATA_DIR/sessions/$id
    mkdir -p "$dir/data" 2>/dev/null || return 0
    printf '%s\n' "$cmd" >| "$dir/cmd"
    printf '%s\n' "$$" >| "$dir/pid"

    _undo_session=$dir
    export UNDO_SESSION=$dir
    if [[ ":${LD_PRELOAD-}:" != *":$UNDO_LIB:"* ]]; then
        _undo_saved_preload=${LD_PRELOAD-__undo_unset__}
        # drop any other libundo.so first: two loaded copies both intercept,
        # duplicating journal entries and recording each other's backups
        local _undo_keep= _undo_p
        local -a _undo_parts
        IFS=: read -ra _undo_parts <<<"${LD_PRELOAD-}"
        for _undo_p in "${_undo_parts[@]}"; do
            [[ -z $_undo_p || $_undo_p == *libundo.so ]] && continue
            _undo_keep="${_undo_keep:+$_undo_keep:}$_undo_p"
        done
        export LD_PRELOAD="$UNDO_LIB${_undo_keep:+:$_undo_keep}"
    fi
}

_undo_precmd() {
    _undo_at_prompt=1
    [[ -n ${_undo_session-} ]] || return 0
    unset UNDO_SESSION
    if [[ ${_undo_saved_preload-} == __undo_unset__ ]]; then
        unset LD_PRELOAD
    elif [[ -n ${_undo_saved_preload-} ]]; then
        export LD_PRELOAD=$_undo_saved_preload
    fi
    # The shim gives up when it would otherwise fill the disk. Say so:
    # precmd runs once per session, so this warns exactly once, and it is
    # the only chance the user gets to hear about it.
    if [[ -s $_undo_session/degraded ]]; then
        printf 'undo: %s\n' "$(<"$_undo_session/degraded")" >&2
    fi

    # the store can be removed underneath a running command, by gc or by
    # hand. A hook has no business erroring at the prompt when it is.
    [[ -d $_undo_session ]] && : >| "$_undo_session/done" 2>/dev/null
    unset _undo_saved_preload _undo_session

    if command -v undo >/dev/null 2>&1; then
        command undo gc --auto 2>/dev/null
        return 0
    fi
    # fallback: drop empty sessions, prune the oldest beyond UNDO_KEEP
    local d
    for d in "$UNDO_DATA_DIR"/sessions/*/; do
        [[ -d $d ]] || continue
        [[ -s $d/journal ]] || rm -rf -- "$d"
    done
    local -a all=("$UNDO_DATA_DIR"/sessions/*/)
    local n=${#all[@]} i
    if [[ -d ${all[0]-} ]] && ((n > UNDO_KEEP)); then
        for ((i = 0; i < n - UNDO_KEEP; i++)); do
            rm -rf -- "${all[i]}"
        done
    fi
}

# lets `undo doctor` tell an inactive hook from a missing install
export UNDO_HOOK=bash

trap '_undo_preexec' DEBUG
# run our precmd last so the at-prompt flag is set after other hooks
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_undo_precmd"
