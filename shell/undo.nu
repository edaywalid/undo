# undo.nu - arm the undo shim around every interactive command.
# Source from your config.nu:
#   source ~/.local/share/undo/undo.nu

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

# backups may hold copies of sensitive files: keep the store private
^mkdir -p $"($env.UNDO_DATA_DIR)/sessions"
^chmod 700 $env.UNDO_DATA_DIR $"($env.UNDO_DATA_DIR)/sessions"

# extra ignore patterns from the config file, colon-joined for the shim.
# The shim always ignores node_modules/.cache/__pycache__/.git on top.
$env.UNDO_IGNORE_FILE = ($env.UNDO_IGNORE_FILE?
    | default $"(($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config"))/undo/ignore")
if ($env.UNDO_IGNORE? | is-empty) and ($env.UNDO_IGNORE_FILE | path exists) {
    let pats = (open --raw $env.UNDO_IGNORE_FILE | lines
        | where {|l| ($l | str trim) != "" and not ($l | str trim | str starts-with "#") })
    if ($pats | is-not-empty) { $env.UNDO_IGNORE = ($pats | str join ":") }
}

# lets `undo doctor` tell an inactive hook from a missing install
$env.UNDO_HOOK = "nu"

# Hooks are closures with their own scope, so a plain `$env.X = ...` inside
# one is discarded when it returns. load-env and hide-env are the two that
# reach the caller, which is why the arming below goes through them.
$env.config.hooks.pre_execution = ($env.config.hooks?.pre_execution? | default [] | append {
    let cmd = (commandline | str trim)
    if $cmd != "undo" and not ($cmd | str starts-with "undo ") {
        # nanoseconds since the epoch, the same id the other hooks build
        # with `date +%s%N`. nushell has no %N in format date, but an int
        # date is already nanoseconds.
        let id = (date now | into int | into string | str substring 0..<16)
        let dir = $"($env.UNDO_DATA_DIR)/sessions/($id)"
        ^mkdir -p $"($dir)/data"
        if ($dir | path exists) {
            $cmd | save --force $"($dir)/cmd"
            $nu.pid | into string | save --force $"($dir)/pid"

            # drop any other libundo.so first: two loaded copies both
            # intercept, duplicating entries and recording each other
            let prev = ($env.LD_PRELOAD? | default "")
            let keep = ($prev | split row ":"
                | where {|p| $p != "" and not ($p | str ends-with "libundo.so") })
            let preload = ([$env.UNDO_LIB] | append $keep | str join ":")

            load-env {
                UNDO_SESSION: $dir
                LD_PRELOAD: $preload
                _UNDO_PREV_PRELOAD: $prev
            }
        }
    }
})

$env.config.hooks.pre_prompt = ($env.config.hooks?.pre_prompt? | default [] | append {
    if ($env.UNDO_SESSION? | is-not-empty) {
        let dir = $env.UNDO_SESSION
        let prev = ($env._UNDO_PREV_PRELOAD? | default "")

        # the marker is what tells `undo` the command finished, so write it
        # before anything below can fail
        "" | save --force $"($dir)/done"

        if $prev == "" {
            hide-env --ignore-errors LD_PRELOAD
        } else {
            load-env { LD_PRELOAD: $prev }
        }
        hide-env --ignore-errors UNDO_SESSION
        hide-env --ignore-errors _UNDO_PREV_PRELOAD

        if (which undo | is-not-empty) {
            ^undo gc --auto
        } else {
            # fallback: drop empty sessions, prune the oldest beyond UNDO_KEEP
            let all = (ls $"($env.UNDO_DATA_DIR)/sessions"
                | where type == dir | get name | sort)
            let live = ($all | where {|d|
                let j = ($d | path join "journal")
                let alive = (($j | path exists) and (($j | path expand | ls $in | get 0.size) > 0b))
                if not $alive { ^rm -rf $d }
                $alive
            })
            let keep = ($env.UNDO_KEEP | into int)
            if ($live | length) > $keep {
                $live | first (($live | length) - $keep) | each {|d| ^rm -rf $d } | ignore
            }
        }
    }
})

}
