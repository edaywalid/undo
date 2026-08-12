# undo.nu - arm the undo shim around every interactive command.
# Source from your config.nu:
#   source ~/.local/share/undo/undo.nu
#
# Put it near the top. This file re-execs nu once with the shim preloaded,
# so anything above it in your config runs twice.

# nushell's own `cp` cannot be recorded, so hand the name to coreutils.
#
# Every other built-in reaches the filesystem through libc, where the shim
# is waiting. `cp` does not: it goes straight to the kernel, so an
# LD_PRELOAD shim never sees it. Verified by tracing every libc open
# during a copy and finding none. `cp over an existing file` therefore
# destroyed the target and journaled nothing at all, which is the one
# outcome undo must not have.
#
# This has to sit at the top level. An alias defined inside the `if`
# below stays inside it and never reaches your prompt.
#
# The flags line up (coreutils is the superset), and nushell expands
# globs before the external ever sees them. Delete this line if you would
# rather keep nushell's cp, and accept that copies are not undoable.
alias cp = ^cp

$env.UNDO_DATA_DIR = ($env.UNDO_DATA_DIR?
    | default $"(($env.XDG_DATA_HOME? | default $"($env.HOME)/.local/share"))/undo")
$env.UNDO_KEEP = ($env.UNDO_KEEP? | default "30")

if ($env.UNDO_LIB? | is-empty) {
    let from_path = (which undo | get --optional 0.path)
    let candidates = ([$"($env.HOME)/.local/lib/undo/libundo.so"]
        | append (if ($from_path | is-empty) { [] } else {
            [($from_path | path dirname | path join ".." "lib" "undo" "libundo.so")]
        })
        | append ["/usr/local/lib/undo/libundo.so" "/usr/lib/undo/libundo.so"])
    let found = ($candidates | where {|l| ($l | path exists) } | get --optional 0)
    if ($found | is-not-empty) { $env.UNDO_LIB = $found }
}

# Without the shim there is nothing to arm, so leave the hooks unset
# rather than paying for them on every command.
if ($env.UNDO_LIB? | is-not-empty) and ($env.UNDO_LIB | path exists) {

# ---------------------------------------------------------------------
# Everything the shim reads has to be settled before the exec below.
#
# nushell runs rm, mv, cp, mkdir and save inside its own process, so there
# is no child for LD_PRELOAD to catch: the shim has to live in nu itself.
# Where zsh treats preloading the shell as the optional UNDO_CAPTURE_SHELL
# extra, here it is the only way to record the commands people want back.
#
# The catch is that `$env.X = ...` does not change the environment of the
# running nu. It only builds the environment handed to processes nu
# starts, and the shim reads the real one with getenv. So every UNDO_*
# the shim consumes is set here, and the exec is what makes them real.
# ---------------------------------------------------------------------

# backups may hold copies of sensitive files: keep the store private
^mkdir -p $"($env.UNDO_DATA_DIR)/sessions"
^chmod 700 $env.UNDO_DATA_DIR $"($env.UNDO_DATA_DIR)/sessions"

$env.UNDO_IGNORE_FILE = ($env.UNDO_IGNORE_FILE?
    | default $"(($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config"))/undo/ignore")
let user_pats = (if ($env.UNDO_IGNORE? | is-not-empty) {
    $env.UNDO_IGNORE | split row ":"
} else if ($env.UNDO_IGNORE_FILE | path exists) {
    open --raw $env.UNDO_IGNORE_FILE | lines
        | where {|l| ($l | str trim) != "" and not ($l | str trim | str starts-with "#") }
} else { [] })

# Riding inside nu means the shim also sees the files nu writes for
# itself. Left alone, every session records nushell rewriting its own
# history, and `undo` after a plain `ls` offers to put an older history
# file back. The store is on the list for the same reason: the hooks
# rewrite the session pointer while the shim is still armed, which would
# otherwise journal undo's own bookkeeping.
$env.UNDO_IGNORE = ([$env.UNDO_DATA_DIR $nu.default-config-dir $nu.data-dir
    $nu.cache-dir]
    | where {|p| ($p | describe) == "string" and $p != "" }
    | append $user_pats | uniq | str join ":")

# The shim cannot be handed the session in the environment, for the
# reason above, so it reads this file and the hooks rewrite it around
# every command. One path per shell, so two nu windows do not overwrite
# each other. exec keeps the pid, so the name computed here is the one
# the new image wants.
$env.UNDO_SESSION_PTR = $"($env.UNDO_DATA_DIR)/current.($nu.pid)"
"" | save --force $env.UNDO_SESSION_PTR

# lets `undo doctor` tell an inactive hook from a missing install
$env.UNDO_HOOK = "nu"

if not ($env.LD_PRELOAD? | default "" | split row ":" | any {|p| $p == $env.UNDO_LIB }) {
    # drop any other libundo.so first: two loaded copies both intercept,
    # duplicating journal entries and recording each other's backups
    $env.LD_PRELOAD = ([$env.UNDO_LIB]
        | append ($env.LD_PRELOAD? | default "" | split row ":"
            | where {|p| $p != "" and not ($p | str ends-with "libundo.so") })
        | str join ":")
    exec $nu.current-exe
}

# ---------------------------------------------------------------------
# Past the exec: the shim is loaded and reading the pointer.
#
# Hooks are closures with their own scope, so a plain `$env.X = ...`
# inside one is discarded when it returns. load-env and hide-env are the
# two that reach the caller.
# ---------------------------------------------------------------------

$env.config.hooks.pre_execution = ($env.config.hooks?.pre_execution? | default [] | append {
    let cmd = (commandline | str trim)
    if $cmd != "undo" and not ($cmd | str starts-with "undo ") {
        # nanoseconds since the epoch, cut to seconds plus microseconds so
        # the id sorts and parses like the ones the other hooks build
        let id = (date now | into int | into string | str substring 0..<16)
        let dir = $"($env.UNDO_DATA_DIR)/sessions/($id)"
        ^mkdir -p $"($dir)/data"
        if ($dir | path exists) {
            $cmd | save --force $"($dir)/cmd"
            $nu.pid | into string | save --force $"($dir)/pid"

            # written last, because this is what arms the shim: until the
            # pointer lands, nothing above it is recorded
            $dir | save --force $env.UNDO_SESSION_PTR

            # children are told the ordinary way. UNDO_SESSION wins over
            # the pointer in the shim, so an external that outlives the
            # command keeps writing to the session it started in.
            load-env { UNDO_SESSION: $dir }
        }
    }
})

$env.config.hooks.pre_prompt = ($env.config.hooks?.pre_prompt? | default [] | append {
    if ($env.UNDO_SESSION? | is-not-empty) {
        let dir = $env.UNDO_SESSION

        # disarm first: everything below writes files, and an armed shim
        # would record undo's own bookkeeping into the session
        "" | save --force $env.UNDO_SESSION_PTR
        hide-env --ignore-errors UNDO_SESSION

        # the store can be removed underneath a running command, by gc or
        # by hand, and a hook has no business erroring at the prompt for it
        if ($dir | path exists) {
            "" | save --force $"($dir)/done"

            # the shim gives up when it would otherwise fill the disk, and
            # this is the one chance the user gets to hear about it
            let degraded = $"($dir)/degraded"
            if ($degraded | path exists) {
                print -e $"undo: (open --raw $degraded | str trim)"
            }
        }

        if (which undo | is-not-empty) {
            ^undo gc --auto
        } else {
            # fallback: drop empty sessions, prune the oldest beyond UNDO_KEEP
            let sessions = (ls $"($env.UNDO_DATA_DIR)/sessions"
                | where type == dir | get name | sort)
            # a filter that deletes as a side effect is a filter you cannot
            # reason about, so decide first and delete after
            let empty = ($sessions | where {|d|
                let j = ($d | path join "journal")
                not (($j | path exists) and ((ls $j | get 0.size) > 0b))
            })
            for d in $empty { ^rm -rf $d }
            let kept = ($sessions | where {|d| $d not-in $empty })
            let keep = ($env.UNDO_KEEP | into int)
            if ($kept | length) > $keep {
                for d in ($kept | first (($kept | length) - $keep)) { ^rm -rf $d }
            }
        }
    }
})

}
