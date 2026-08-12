#!/bin/sh
# undo installer: fetches the latest release and installs to ~/.local
# (no root needed). Usage:  curl -fsSL <url>/install.sh | sh
set -eu

REPO="edaywalid/undo"
PREFIX="${PREFIX:-$HOME/.local}"

fail() { echo "install.sh: $*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "undo is Linux-only (LD_PRELOAD based)"

case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) fail "unsupported architecture: $(uname -m). Build from source: make install" ;;
esac

if ldd --version 2>&1 | grep -qi musl; then
    echo "note: musl libc detected. The prebuilt shim targets glibc;" >&2
    fail "build from source instead: git clone https://github.com/$REPO && cd undo && make install"
fi

# fetch fully before parsing: piping straight into grep -m1 closes the pipe
# early and makes curl print a confusing "(23) Failure writing output" error
api=$(curl -fsSL --retry 3 --retry-delay 1 "https://api.github.com/repos/$REPO/releases/latest") ||
    fail "could not query latest release"
tag=$(printf '%s\n' "$api" | grep '"tag_name"' | head -n1 | cut -d'"' -f4)
[ -n "$tag" ] || fail "could not parse the latest release tag"
ver=${tag#v}
url="https://github.com/$REPO/releases/download/$tag/undo_${ver}_linux_${arch}.tar.gz"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading undo $tag (linux/$arch)..."
curl -fsSL --retry 3 --retry-delay 1 "$url" | tar -xz -C "$tmp" ||
    fail "download failed: $url"

# The binary and the shim may be running or mapped right now (this is
# also how `undo upgrade` reinstalls), and writing over those fails with
# "Text file busy". Land them beside the target, then rename into place:
# rename is atomic and leaves existing processes on the old inode.
replace() { # replace <src> <dst> <mode>
    install -Dm"$3" "$1" "$2.new" || fail "could not write $2.new"
    mv -f "$2.new" "$2" || fail "could not replace $2"
}
replace "$tmp/undo" "$PREFIX/bin/undo" 755
replace "$tmp/build/libundo_${arch}.so" "$PREFIX/lib/undo/libundo.so" 755
install -Dm644 "$tmp/shell/undo.zsh" "$PREFIX/share/undo/undo.zsh"
install -Dm644 "$tmp/shell/undo.bash" "$PREFIX/share/undo/undo.bash"
install -Dm644 "$tmp/shell/undo.fish" "$PREFIX/share/undo/undo.fish"
# The nushell hook arrived after v0.3.0, and this script installs whatever
# the latest release holds. Skip it rather than abort when an older
# release has no such file.
if [ -f "$tmp/shell/undo.nu" ]; then
    install -Dm644 "$tmp/shell/undo.nu" "$PREFIX/share/undo/undo.nu"
fi
install -Dm644 "$tmp/completions/_undo" "$PREFIX/share/zsh/site-functions/_undo"
install -Dm644 "$tmp/completions/undo.bash" "$PREFIX/share/bash-completion/completions/undo"
install -Dm644 "$tmp/completions/undo.fish" "$PREFIX/share/fish/vendor_completions.d/undo.fish"

echo
echo "installed undo $tag to $PREFIX"
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "note: $PREFIX/bin is not on your PATH" ;;
esac

# undo does nothing until its hook is loaded, so an install that stops at
# "here is a line to paste" leaves people with a tool that silently records
# nothing. But a shell rc is the user's file, so we ask before touching it
# and never write without an answer.
hook_line=""
path_line=""
rc=""
# ${SHELL##*/} alone aborts under set -u when SHELL is unset, which happens
# in containers, cron jobs and some CI runners
shell_name=${SHELL:-}
shell_name=${shell_name##*/}
case "$shell_name" in
    zsh)  rc="$HOME/.zshrc";                  hook_line="source $PREFIX/share/undo/undo.zsh" ;;
    bash) rc="$HOME/.bashrc";                 hook_line="source $PREFIX/share/undo/undo.bash" ;;
    fish) rc="$HOME/.config/fish/config.fish"; hook_line="source $PREFIX/share/undo/undo.fish" ;;
    nu)   rc="$HOME/.config/nushell/config.nu"; hook_line="source $PREFIX/share/undo/undo.nu" ;;
esac

# an install that leaves `undo` unrunnable is not an install
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *)
        case "$shell_name" in
            fish) path_line="fish_add_path $PREFIX/bin" ;;
            zsh | bash) path_line="export PATH=\"$PREFIX/bin:\$PATH\"" ;;
            # nushell's hook goes to the top of the file, and PATH set
            # above it would be prepended twice by the re-exec
            nu) path_line="" ;;
        esac
        ;;
esac

manual_instructions() {
    echo "undo is installed but not armed yet. Add the hook for your shell:"
    echo "  zsh:   echo 'source $PREFIX/share/undo/undo.zsh'  >> ~/.zshrc"
    echo "  bash:  echo 'source $PREFIX/share/undo/undo.bash' >> ~/.bashrc"
    echo "  fish:  echo 'source $PREFIX/share/undo/undo.fish' >> ~/.config/fish/config.fish"
    echo "  nu:    add 'source $PREFIX/share/undo/undo.nu' at the TOP of ~/.config/nushell/config.nu"
    echo
    echo "then open a new terminal. 'undo doctor' will confirm it is active."
}

# Ask before editing the rc. curl | sh means stdin is the script, so read
# the answer from the terminal directly. With no terminal (CI, piped) we
# never write: silence is not consent.
ask_rc() {
    [ -n "${UNDO_MODIFY_RC-}" ] && return 0
    [ -n "${UNDO_NO_MODIFY_RC-}" ] && return 1
    # Under `curl | sh` stdin is the script, but stdout still points at the
    # user's terminal, so that is what tells us whether anyone is there to
    # answer. Testing /dev/tty instead is not safe: the node exists in a
    # container and even tests readable, while opening it fails, and a
    # failed redirection kills the shell outright.
    [ -t 1 ] || return 1
    printf '\nadd this line to %s?\n  %s\n' "$rc" "$hook_line"
    [ -n "$path_line" ] && printf '  %s\n' "$path_line"
    printf '[Y/n] '
    # read inside a subshell so that if /dev/tty still cannot be opened,
    # the redirection failure dies there instead of taking the install
    # down with it
    reply=$( { read -r r </dev/tty && printf '%s' "$r"; } 2>/dev/null ) ||
        return 1
    case "$reply" in
        [Nn]*) return 1 ;;
        *) return 0 ;;
    esac
}

echo
if [ -z "$rc" ]; then
    manual_instructions
elif [ -f "$rc" ] && grep -qF "$hook_line" "$rc"; then
    echo "hook already set up in $rc"
elif ! ask_rc; then
    echo
    manual_instructions
else
    mkdir -p "$(dirname "$rc")"
    if [ "$shell_name" = nu ]; then
        # undo.nu re-execs nu with the shim preloaded, so config lines
        # above it run a second time. Appending would rerun the whole
        # file, and a config that prepends to PATH would do it twice.
        tmp_rc="$rc.undo-new"
        {
            printf '# undo: revert what the last command did (undo.edaywalid.com)\n'
            printf '%s\n\n' "$hook_line"
            [ -f "$rc" ] && cat "$rc"
        } >"$tmp_rc" && mv "$tmp_rc" "$rc"
    else
        {
            printf '\n# undo: revert what the last command did (undo.edaywalid.com)\n'
            [ -n "$path_line" ] && printf '%s\n' "$path_line"
            printf '%s\n' "$hook_line"
        } >>"$rc"
    fi
    echo "hook added to $rc"
    [ -n "$path_line" ] && echo "added $PREFIX/bin to your PATH there too"
    echo "('undo uninstall' takes these lines back out)"
fi

echo
echo "open a new terminal, then try it (undo needs its own line):"
echo "  touch x"
echo "  rm x"
echo "  undo"
